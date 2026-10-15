import SwiftUI
import Combine
import WebRTC

/// The in-app call screen, shown by `CallWindowPresenter` whenever `CallService.session` exists:
/// ringing in, ringing out, connecting, connected and the brief "Call ended" beat.
///
/// Voice calls look like the phone's own call screen: name and timer up top, big round buttons
/// with labels underneath, the red hang-up at the bottom. Video calls are two equal tiles, the
/// other person on top and you underneath, both shown exactly as the camera sees them (no
/// mirroring - the picture the other side gets is the picture you see), with a slim control
/// bar below.
struct CallView: View {
    @ObservedObject var call: CallService.ActiveCall
    @ObservedObject private var callService = CallService.shared
    @ObservedObject private var knsService = KNSService.shared
    @EnvironmentObject var contactsManager: ContactsManager
    @State private var now = Date()

    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var showsMinimize: Bool {
        switch call.phase {
        case .ringingOut, .connecting, .connected: return true
        default: return false
        }
    }

    private var isVideoLayout: Bool {
        call.video && (call.phase == .connected || call.phase == .connecting || call.phase == .ringingOut)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if isVideoLayout {
                videoLayout
            } else {
                voiceLayout
            }
        }
        // Tuck the call away: the call goes on while you use the rest of KaChat (or another
        // app - a video call follows you as Picture in Picture, like FaceTime).
        .overlay(alignment: .topLeading) {
            if showsMinimize {
                Button {
                    callService.minimize()
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.scaled(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(Color.white.opacity(0.18)))
                }
                .buttonStyle(.plain)
                .padding(.leading, 16)
                .padding(.top, 8)
            }
        }
        // "Alex declined video" and the like, for a few seconds.
        .overlay(alignment: .top) {
            if let notice = call.notice {
                Text(notice)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.white.opacity(0.2)))
                    .padding(.top, 60)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: call.notice)
        // The other side asked to switch to video: yes or no, nothing happens until answered.
        .sheet(isPresented: Binding(
            get: { call.videoRequest == .incoming },
            set: { if !$0, call.videoRequest == .incoming { callService.answerVideoRequest(accept: false) } }
        )) {
            VStack(spacing: 12) {
                Text("\(contactsManager.displayName(for: call.contact)) wants to switch to video")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .padding(.top, 24)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 4)
                ActionSheetRow(
                    title: "Switch to video",
                    subtitle: "Your camera turns on and the call moves to the speaker.",
                    systemImage: "video.fill"
                ) { callService.answerVideoRequest(accept: true) }
                ActionSheetRow(
                    title: "Stay on voice",
                    subtitle: "The call carries on as it is, and they are told.",
                    systemImage: "phone.fill"
                ) { callService.answerVideoRequest(accept: false) }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .presentationDetents([.height(250)])
            .presentationDragIndicator(.visible)
        }
        .preferredColorScheme(.dark)
        .onReceive(clock) { now = $0 }
        .onChange(of: call.phase) { phase in
            if case .ended = phase {
                Haptics.impact(.medium)
            }
        }
    }

    // MARK: - Voice (and every ringing/ended state)

    private var voiceLayout: some View {
        VStack(spacing: 0) {
            VStack(spacing: 14) {
                KNSAvatarView(
                    avatarURLString: knsService.profileCache[call.contact.address]?.avatarURL,
                    fallbackText: contactsManager.displayName(for: call.contact),
                    size: 120,
                    contactAddress: call.contact.address
                )
                .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
                Text(contactsManager.displayName(for: call.contact))
                    .font(.scaled(size: 30, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(statusText)
                    .font(.title3)
                    .foregroundColor(.white.opacity(0.7))
                    .monospacedDigit()
            }
            .padding(.top, 56)
            .padding(.horizontal, 24)

            Spacer()

            switch call.phase {
            case .ringingIn:
                incomingControls
            case .ended:
                bigButton(systemName: "xmark", tint: Color.white.opacity(0.22), size: 84, label: "Close") {
                    callService.dismissEnded()
                }
            default:
                VStack(spacing: 40) {
                    HStack(spacing: call.phase == .connected ? 28 : 44) {
                        // Off: translucent circle, plain glyph. On: solid white circle, the
                        // "slashed mic" / "waves" glyph, and the label says so - one look tells.
                        bigButton(systemName: call.isMuted ? "mic.slash.fill" : "mic.fill",
                                  tint: call.isMuted ? .white : Color.white.opacity(0.22),
                                  size: 84, label: call.isMuted ? "muted" : "mute", foreground: call.isMuted ? .black : .white) {
                            callService.toggleMute()
                        }
                        bigButton(systemName: call.isSpeakerOn ? "speaker.wave.3.fill" : "speaker.fill",
                                  tint: call.isSpeakerOn ? .white : Color.white.opacity(0.22),
                                  size: 84, label: call.isSpeakerOn ? "speaker on" : "speaker", foreground: call.isSpeakerOn ? .black : .white) {
                            callService.toggleSpeaker()
                        }
                        // Switch this call to video - both cameras come on, nobody hangs up.
                        if call.phase == .connected {
                            bigButton(systemName: "video.fill", tint: Color.white.opacity(0.22), size: 84,
                                      label: call.videoRequest == .outgoing ? "asking\u{2026}" : "video") {
                                callService.upgradeToVideo()
                            }
                            .opacity(call.videoRequest == .outgoing ? 0.5 : 1)
                            .disabled(call.videoRequest != nil)
                        }
                    }
                    bigButton(systemName: "phone.down.fill", tint: .red, size: 84, label: nil) {
                        callService.hangUp()
                    }
                }
            }
        }
        .padding(.bottom, 52)
    }

    private var incomingControls: some View {
        HStack(spacing: 96) {
            bigButton(systemName: "phone.down.fill", tint: .red, size: 84, label: "Decline") {
                callService.declineIncoming()
            }
            bigButton(systemName: call.video ? "video.fill" : "phone.fill", tint: .green, size: 84, label: "Accept") {
                callService.acceptIncoming()
            }
        }
    }

    // MARK: - Video

    private var videoLayout: some View {
        GeometryReader { proxy in
            let barHeight: CGFloat = 96
            let tileHeight = max(120, (proxy.size.height - barHeight - 12 - 8) / 2)
            VStack(spacing: 12) {
                videoTile(track: call.remoteVideoTrack,
                          name: contactsManager.displayName(for: call.contact),
                          placeholder: remotePlaceholder,
                          address: call.contact.address,
                          isPictureInPictureSource: true)
                    .frame(height: tileHeight)
                videoTile(track: call.isCameraOff ? nil : call.localVideoTrack,
                          name: "You",
                          placeholder: "Camera off",
                          address: nil,
                          // Ringing: no WebRTC track yet, so the camera itself fills the tile.
                          livePreview: !call.isCameraOff && call.localVideoTrack == nil && call.phase == .ringingOut)
                    .frame(height: tileHeight)
                videoControlBar
                    .frame(height: barHeight)
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
        }
        .ignoresSafeArea(.container, edges: .bottom)
    }

    private var remotePlaceholder: String {
        switch call.phase {
        case .ringingOut: return "calling\u{2026}"
        case .connected: return "Camera off"
        default: return call.statusDetail ?? "Connecting\u{2026}"
        }
    }

    @ViewBuilder
    private func videoTile(track: RTCVideoTrack?, name: String, placeholder: String, address: String?, livePreview: Bool = false, isPictureInPictureSource: Bool = false) -> some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(white: 0.12))
            if let track {
                RTCVideoView(track: track, isPictureInPictureSource: isPictureInPictureSource)
            } else if livePreview {
                CallCameraPreviewView()
            } else {
                VStack(spacing: 10) {
                    if let address {
                        KNSAvatarView(
                            avatarURLString: knsService.profileCache[address]?.avatarURL,
                            fallbackText: name,
                            size: 72,
                            contactAddress: address
                        )
                    } else {
                        Image(systemName: "video.slash.fill")
                            .font(.scaled(size: 34, weight: .semibold))
                            .foregroundColor(.white.opacity(0.5))
                    }
                    Text(placeholder)
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.7))
                }
            }
            HStack(spacing: 6) {
                Text(name)
                    .font(.subheadline.weight(.semibold))
                if address != nil, call.phase == .connected, let start = call.connectedAt {
                    let seconds = max(0, Int(now.timeIntervalSince(start)))
                    Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundColor(.white.opacity(0.75))
                }
            }
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.black.opacity(0.45)))
            .padding(12)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var videoControlBar: some View {
        HStack(spacing: 22) {
            smallControl(systemName: call.isMuted ? "mic.slash.fill" : "mic.fill", active: call.isMuted) {
                callService.toggleMute()
            }
            // Video calls start on the speaker; the toggle stays for whoever needs it.
            smallControl(systemName: call.isSpeakerOn ? "speaker.wave.3.fill" : "speaker.fill", active: call.isSpeakerOn) {
                callService.toggleSpeaker()
            }
            smallControl(systemName: call.isCameraOff ? "video.slash.fill" : "video.fill", active: call.isCameraOff) {
                callService.toggleCamera()
            }
            smallControl(systemName: "arrow.triangle.2.circlepath.camera.fill", active: false) {
                callService.flipCamera()
            }
            Button {
                callService.hangUp()
            } label: {
                Image(systemName: "phone.down.fill")
                    .font(.scaled(size: 24, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 60, height: 60)
                    .background(Circle().fill(Color.red))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Pieces

    private var statusText: String {
        switch call.phase {
        case .ringingOut: return "calling\u{2026}"
        case .ringingIn: return call.video ? "KaChat Video" : "KaChat Audio"
        case .connecting: return call.statusDetail ?? "connecting\u{2026}"
        case .connected:
            if let detail = call.statusDetail { return detail }
            guard let start = call.connectedAt else { return "connected" }
            let seconds = max(0, Int(now.timeIntervalSince(start)))
            return String(format: "%d:%02d", seconds / 60, seconds % 60)
        case .ended(let reason):
            switch reason {
            case "declined": return "Declined"
            case "no_host": return "One person in this chat needs Nextcloud Talk set up to make calls."
            case "no_answer":
                // A request nobody hosted rings out exactly like an unanswered call - the
                // other side never says anything on chain - so the hint rides along here.
                return call.hostsThisCall ? "No answer" : "No answer. If they don't have Nextcloud Talk, one of you needs it to make calls."
            case "missed": return "Missed call"
            case "busy": return "Busy"
            case "failed": return callService.lastError ?? "Call failed"
            default: return "Call ended"
            }
        }
    }

    private func bigButton(systemName: String, tint: Color, size: CGFloat, label: String?, foreground: Color = .white, action: @escaping () -> Void) -> some View {
        VStack(spacing: 10) {
            Button(action: action) {
                Image(systemName: systemName)
                    .font(.scaled(size: size * 0.42, weight: .semibold))
                    .foregroundColor(foreground)
                    .frame(width: size, height: size)
                    .background(Circle().fill(tint))
            }
            .buttonStyle(.plain)
            if let label {
                Text(label)
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.85))
            }
        }
    }

    private func smallControl(systemName: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.scaled(size: 20, weight: .semibold))
                .foregroundColor(active ? .black : .white)
                .frame(width: 52, height: 52)
                .background(Circle().fill(active ? Color.white : Color.white.opacity(0.22)))
        }
        .buttonStyle(.plain)
    }
}

/// A WebRTC video track on screen (Metal-backed), shown as the camera sees it - never mirrored.
struct RTCVideoView: UIViewRepresentable {
    let track: RTCVideoTrack
    /// The other person's tile: also the view the system Picture in Picture window grows out
    /// of, and the track it keeps showing once the call screen is tucked away.
    var isPictureInPictureSource: Bool = false

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView()
        view.videoContentMode = .scaleAspectFill
        view.backgroundColor = .black
        context.coordinator.attach(track, to: view)
        if isPictureInPictureSource {
            CallPictureInPicture.shared.register(sourceView: view, track: track)
        }
        return view
    }

    func updateUIView(_ uiView: RTCMTLVideoView, context: Context) {
        context.coordinator.attach(track, to: uiView)
        if isPictureInPictureSource {
            CallPictureInPicture.shared.register(sourceView: uiView, track: track)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private weak var current: RTCVideoTrack?

        func attach(_ track: RTCVideoTrack, to view: RTCMTLVideoView) {
            guard current !== track else { return }
            current?.remove(view)
            track.add(view)
            current = track
        }
    }
}


/// The green "call in progress" bar shown across the top of KaChat while a call is tucked
/// away and not floating as Picture in Picture: the person, the timer, and a tap to return.
struct CallReturnBar: View {
    @ObservedObject var call: CallService.ActiveCall
    @ObservedObject private var callService = CallService.shared
    @EnvironmentObject private var contactsManager: ContactsManager
    @State private var now = Date()
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var timerText: String {
        guard let start = call.connectedAt else { return call.phase == .ringingOut ? "calling\u{2026}" : "connecting\u{2026}" }
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    var body: some View {
        Button {
            callService.restore()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: call.video ? "video.fill" : "phone.fill")
                    .font(.subheadline.weight(.semibold))
                Text(contactsManager.displayName(for: call.contact))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(timerText)
                    .font(.subheadline)
                    .monospacedDigit()
                Spacer(minLength: 0)
                Text("Tap to return")
                    .font(.caption.weight(.semibold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Capsule().fill(Color.green))
            .padding(.horizontal, 12)
        }
        .buttonStyle(.plain)
        .onReceive(clock) { now = $0 }
    }
}

/// Shows the call screen in a window of its own, above everything - not as a sheet of the main
/// screen, which SwiftUI silently refused whenever another sheet was up (a chat, the Send sheet,
/// the sync progress, the welcome guide), while the app was still on its loading screen after a
/// launch by a VoIP push, or mid-transition; answering then "opened the app and nothing
/// happened". Up whenever a call exists and isn't tucked away, and put back when the app comes
/// to the foreground.
@MainActor
final class CallWindowPresenter {
    static let shared = CallWindowPresenter()
    private var window: UIWindow?
    private var shownCallId: String?
    private var cancellables = Set<AnyCancellable>()

    private init() {}

    func start() {
        guard cancellables.isEmpty else { return }
        let service = CallService.shared
        // @Published sends before the value changes: read it on the next turn of the run loop
        service.$session.map { _ in () }
            .merge(with: service.$isMinimized.map { _ in () })
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.update() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UIScene.didActivateNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.update() }
            .store(in: &cancellables)
    }

    private func update() {
        let service = CallService.shared
        guard let call = service.session, !service.isMinimized else {
            hide()
            return
        }
        if let window, shownCallId == call.id, window.windowScene != nil {
            if window.isHidden { window.isHidden = false }
            return
        }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        // no scene yet (a launch by a VoIP push): put up once one activates
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive })
                ?? scenes.first(where: { $0.activationState == .foregroundInactive }) else { return }
        hide()
        let host = UIHostingController(rootView: CallView(call: call).environmentObject(ContactsManager.shared))
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.rootViewController = host
        // the app's Light/Dark choice, as its own windows have it
        if let main = scene.windows.first(where: { $0 !== window && !$0.isHidden }) {
            window.overrideUserInterfaceStyle = main.overrideUserInterfaceStyle
        }
        window.makeKeyAndVisible()
        self.window = window
        shownCallId = call.id
    }

    private func hide() {
        guard let window else { return }
        let scene = window.windowScene
        window.isHidden = true
        self.window = nil
        shownCallId = nil
        // the app's own window takes the keyboard and focus back
        scene?.windows.first { !$0.isHidden && $0.windowLevel == .normal }?.makeKey()
    }
}
