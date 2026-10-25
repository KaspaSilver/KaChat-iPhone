import SwiftUI
import AVFoundation

/// Records a short voice message for a group chat, reusing the exact same Opus/WebM encoding
/// pipeline as 1:1 chat's voice messages (`WebMOpusEncoder`, `ChatDetailView.swift`) so the wire
/// format is identical - the cap keeps it well inside a single transaction's payload.
@MainActor
final class VoiceNoteRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    enum State: Equatable {
        case idle
        case recording
        case encoding
        case failed(String)
    }

    static let maxDuration: TimeInterval = 10
    private static let maxBytes = 13_000
    private static let bitrate: Int32 = 6_000
    private static let sampleRate: Double = 48_000

    @Published private(set) var state: State = .idle
    @Published private(set) var elapsedSeconds: TimeInterval = 0

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var pcmURL: URL?

    func start() {
        guard state == .idle else { return }
        Task {
            let granted = await Self.requestPermission()
            guard granted else {
                state = .failed("Microphone access denied")
                return
            }
            beginRecording()
        }
    }

    private static func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            if #available(iOS 17.0, *) {
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
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

    func cancel() {
        timer?.invalidate()
        timer = nil
        recorder?.stop()
        recorder?.delegate = nil
        recorder = nil
        if let pcmURL {
            try? FileManager.default.removeItem(at: pcmURL)
        }
        pcmURL = nil
        state = .idle
        elapsedSeconds = 0
    }

    /// Stops recording, encodes to Opus/WebM, and delivers wire-ready data. Safe to call once
    /// `elapsedSeconds` reaches `maxDuration` too (the caller drives that cutoff).
    ///
    /// `keepOriginalPCMAt`: optional destination the full-length recorded PCM (CAF) is copied to
    /// BEFORE the payload-capped WebM encode - the encode truncates to ~13KB (≈9s), so callers
    /// that upload the recording elsewhere (group chat's "Send Media via Nextcloud") need the
    /// untouched original. The copy is the CALLER's to clean up; this class still deletes its own
    /// working PCM as before. Defaulted so existing callers (public chat) are untouched.
    func stopAndEncode(keepOriginalPCMAt keepURL: URL? = nil) async throws -> (data: Data, fileName: String, mimeType: String) {
        timer?.invalidate()
        timer = nil
        guard state == .recording, let recorder, let pcmURL else {
            throw KasiaError.networkError("Not recording")
        }
        state = .encoding
        recorder.stop()
        self.recorder = nil
        if let keepURL {
            try? FileManager.default.copyItem(at: pcmURL, to: keepURL)
        }

        defer {
            try? FileManager.default.removeItem(at: pcmURL)
            self.pcmURL = nil
            if state == .encoding { state = .idle }
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("broadcast_voice_\(UUID().uuidString).webm")
        try await WebMOpusEncoder.encode(
            pcmURL: pcmURL,
            outputURL: outputURL,
            bitrate: Self.bitrate,
            sampleRate: Self.sampleRate,
            maxBytes: Self.maxBytes
        )
        let data = try Data(contentsOf: outputURL)
        try? FileManager.default.removeItem(at: outputURL)
        state = .idle
        return (data, "voice.webm", "audio/webm")
    }
}
