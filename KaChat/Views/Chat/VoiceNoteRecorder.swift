import SwiftUI
import AVFoundation

/// Records a voice message for a group chat, reusing the exact same Opus/WebM encoding
/// pipeline as 1:1 chat's voice messages (`WebMOpusEncoder`, `ChatDetailView.swift`) so the wire
/// format is identical. It works like 1:1: Stop (or the length limit) encodes the note as it
/// will be sent and leaves it `.ready`, with a preview to play and pause; Send then sends it
/// (`takeRecording`), and the trash throws it away (`cancel`).
@MainActor
final class VoiceNoteRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate, AVAudioPlayerDelegate {
    enum State: Equatable {
        case idle
        case recording
        case encoding
        /// Stopped and encoded: the preview plays, Send sends it.
        case ready
        case failed(String)
    }

    /// What a stopped recording goes as, once encoded.
    enum Recording {
        /// On chain: the parts, in order (one part, sent untagged, when the note is that short).
        case onChain(parts: [Data])
        /// Via Nextcloud: the full-length original (a CAF the caller deletes once sent) and the
        /// one-part on-chain fallback, should the upload fail.
        case nextcloud(originalPCMURL: URL, fallback: Data)
    }

    /// The old single-note settings, now only for the Nextcloud route's on-chain fallback
    /// (`encodeFallback`): 6 kbps in 20 ms frames, at most ~13 KB.
    static let maxDuration: TimeInterval = 10
    private static let maxBytes = 13_000
    private static let bitrate: Int32 = 6_000
    private static let sampleRate: Double = 48_000

    /// On chain: 16 kbps in 60 ms frames, parts of at most 9.8 s, up to 110 s (1:50) - as long
    /// as 1 KAS of fees allows (`VoiceNotePolicy.group`, where the math is; MESSAGING.md "In
    /// group chats"). A note of one part's length or less is one untagged message. Every group
    /// voice note is sealed as the binary media frame (`GroupChatService.groupPlaintextData`).
    static let policy = VoiceNotePolicy.group
    static var maxOnChainDuration: TimeInterval { policy.maxSeconds }
    static let partBitrate: Int32 = VoiceNotePolicy.bitrate
    static let partFrameMs = VoiceNotePolicy.frameMs
    static var partMaxBytes: Int { policy.maxBytes }

    @Published private(set) var state: State = .idle
    @Published private(set) var elapsedSeconds: TimeInterval = 0

    /// Playing the preview of a `.ready` note.
    @Published private(set) var previewIsPlaying = false
    /// "00:12" for a `.ready` note, "00:04/00:12" while its preview plays (as in 1:1).
    @Published private(set) var previewLabel = "--:--"

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var pcmURL: URL?

    private var encoded: Recording?
    private var previewURL: URL?
    private var previewDuration: TimeInterval = 0
    private var previewPlayer: AVAudioPlayer?
    private var previewTimer: Timer?
    private var encodeTask: Task<Void, Never>?
    /// The stop whose encode is running: a cancel, or a new recording, makes an older one's
    /// result stale.
    private var encodeToken: UUID?

    /// The WebM size of each on-chain part of a `.ready` note, for its exact fee.
    var readyPartSizes: [Int]? {
        guard state == .ready, case .onChain(let parts) = encoded else { return nil }
        return parts.map(\.count)
    }

    func start() {
        switch state {
        case .idle, .failed: break
        default: return
        }
        Task {
            // A Don't Allow just stops: the group composer shows `mediaAccessAlert` when access
            // was already off, and someone who has only now said no isn't told again.
            guard await MediaAccess.microphone.request() else { return }
            beginRecording()
        }
    }

    private func beginRecording() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("broadcast_rec_\(UUID().uuidString).caf")
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: Self.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsFloatKey: false
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.delegate = self
            recorder.record()

            self.recorder = recorder
            self.pcmURL = url
            self.elapsedSeconds = 0
            self.state = .recording
            startTimer()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.elapsedSeconds += 1
            }
        }
    }

    /// Throws the recording away, whatever stage it's at: the trash.
    func cancel() {
        encodeTask?.cancel()
        encodeTask = nil
        encodeToken = nil
        timer?.invalidate()
        timer = nil
        recorder?.stop()
        recorder?.delegate = nil
        recorder = nil
        stopPreview()
        previewPlayer = nil
        if let previewURL, previewURL != pcmURL {
            try? FileManager.default.removeItem(at: previewURL)
        }
        if let pcmURL {
            try? FileManager.default.removeItem(at: pcmURL)
        }
        previewURL = nil
        pcmURL = nil
        encoded = nil
        previewDuration = 0
        previewLabel = "--:--"
        state = .idle
        elapsedSeconds = 0
    }

    /// Stops recording and encodes it as it will be sent, then `.ready` with a preview: the
    /// composer's Stop, or the length limit (as 1:1's `stopRecording`). On chain, parts of at
    /// most 9.8 s at `partBitrate`, and the preview is those parts decoded, so it sounds as the
    /// group will hear it. Via Nextcloud, the preview is the full-length original, which is what
    /// uploads, and a one-part fallback is encoded for a failed upload.
    func stop(viaNextcloud: Bool) {
        guard state == .recording, let recorder, let pcmURL else { return }
        timer?.invalidate()
        timer = nil
        recorder.stop()
        recorder.delegate = nil
        self.recorder = nil
        state = .encoding
        let token = UUID()
        encodeToken = token
        encodeTask = Task { [weak self] in
            var preview: URL?
            do {
                let recording: Recording
                let duration: TimeInterval
                if viaNextcloud {
                    let fallback = try await Self.encodeFallback(pcmURL: pcmURL)
                    recording = .nextcloud(originalPCMURL: pcmURL, fallback: fallback)
                    preview = pcmURL
                    duration = try AVAudioPlayer(contentsOf: pcmURL).duration
                } else {
                    let urls = try await WebMOpusEncoder.encodeParts(
                        pcmURL: pcmURL,
                        outputDirectory: FileManager.default.temporaryDirectory,
                        bitrate: Self.partBitrate,
                        sampleRate: Self.sampleRate,
                        frameMs: Self.partFrameMs,
                        partSeconds: Self.policy.partSeconds,
                        maxParts: VoicePartTag.maxParts,
                        maxBytes: Self.partMaxBytes
                    )
                    defer { for url in urls { try? FileManager.default.removeItem(at: url) } }
                    let parts = try urls.map { try Data(contentsOf: $0) }
                    let decoded = try await Task.detached(priority: .userInitiated) {
                        try WebMOpusDecoder.decodePartsToPCMFile(parts: parts)
                    }.value
                    recording = .onChain(parts: parts)
                    preview = decoded.url
                    duration = decoded.duration
                }
                guard let self, self.encodeToken == token, !Task.isCancelled else {
                    if let preview, preview != pcmURL { try? FileManager.default.removeItem(at: preview) }
                    return
                }
                if case .onChain = recording {
                    // The parts are all that's sent; the recording itself isn't needed any more.
                    try? FileManager.default.removeItem(at: pcmURL)
                    self.pcmURL = nil
                }
                self.encoded = recording
                self.previewURL = preview
                self.previewDuration = duration
                self.previewLabel = Self.clock(duration)
                self.encodeTask = nil
                self.state = .ready
            } catch {
                if let preview, preview != pcmURL { try? FileManager.default.removeItem(at: preview) }
                guard let self, self.encodeToken == token, !Task.isCancelled else { return }
                self.cancel()
                self.state = .failed("Recording failed. Please try again.")
            }
        }
    }

    /// The `.ready` note, for sending; the recorder goes back to idle. From here the caller owns
    /// a Nextcloud recording's original file.
    func takeRecording() -> Recording? {
        guard state == .ready, let encoded else { return nil }
        stopPreview()
        previewPlayer = nil
        if let previewURL, previewURL != pcmURL {
            try? FileManager.default.removeItem(at: previewURL)
        }
        previewURL = nil
        pcmURL = nil
        self.encoded = nil
        previewDuration = 0
        previewLabel = "--:--"
        encodeToken = nil
        state = .idle
        elapsedSeconds = 0
        return encoded
    }

    // MARK: - Preview

    /// Play or pause the `.ready` note's preview.
    func togglePreview() {
        if previewIsPlaying {
            stopPreview()
            return
        }
        guard state == .ready, let previewURL else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            if previewPlayer?.url != previewURL {
                previewPlayer = try AVAudioPlayer(contentsOf: previewURL)
            }
            previewPlayer?.delegate = self
            previewPlayer?.prepareToPlay()
            guard previewPlayer?.play() == true else { return }
            previewIsPlaying = true
            previewTimer?.invalidate()
            previewTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let player = self.previewPlayer, self.previewIsPlaying else { return }
                    self.previewLabel = "\(Self.clock(player.currentTime))/\(Self.clock(self.previewDuration))"
                }
            }
        } catch {
            previewIsPlaying = false
        }
    }

    private func stopPreview() {
        previewTimer?.invalidate()
        previewTimer = nil
        previewPlayer?.stop()
        previewPlayer?.currentTime = 0
        previewIsPlaying = false
        if previewURL != nil {
            previewLabel = Self.clock(previewDuration)
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.stopPreview()
        }
    }

    /// "mm:ss", as the composer shows it.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    // MARK: - Encoding

    /// Estimated WebM bytes of each part a recording of `seconds` goes as - the live fee.
    static func estimatedPartSizes(forDuration seconds: TimeInterval) -> [Int] {
        VoiceNoteLayout.partSizes(
            duration: min(seconds, maxOnChainDuration),
            partSeconds: policy.partSeconds,
            bitrate: partBitrate,
            frameMs: partFrameMs,
            maxBytes: partMaxBytes,
            sampleRate: sampleRate
        )
    }

    /// The Nextcloud route's one-part on-chain fallback: the old 6 kbps / 20 ms single note,
    /// payload-capped at ~13 KB (about 9 s), sent only when the upload fails.
    private static func encodeFallback(pcmURL: URL) async throws -> Data {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("broadcast_voice_\(UUID().uuidString).webm")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        try await WebMOpusEncoder.encode(
            pcmURL: pcmURL,
            outputURL: outputURL,
            bitrate: bitrate,
            sampleRate: sampleRate,
            maxBytes: maxBytes
        )
        return try Data(contentsOf: outputURL)
    }
}
