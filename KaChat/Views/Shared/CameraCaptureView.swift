import AVFoundation
import SwiftUI
import UIKit

/// Wraps `UIImagePickerController`'s camera source so a photo taken in-app can feed into the same
/// staging pipeline a library-picked photo already uses (`attachImageData(_:)` in
/// `ChatDetailView.swift`, the equivalent inline block in `GroupChatDetailView.swift`) - this view
/// only ever hands back raw JPEG `Data`, it has no opinion about what happens to it afterward.
/// The composers ask for camera access first (`MediaAccess.camera`), so this only opens once
/// it's allowed: a picker opened without access shows a blank camera with no way to Settings.
struct CameraCaptureView: UIViewControllerRepresentable {
    let onCapture: (Data) -> Void
    let onCancel: () -> Void
    /// When set, the camera UI offers its native Photo/Video mode switcher and recorded clips
    /// come back here as a temp-file URL (the caller owns deleting it). Nil keeps the picker
    /// photo-only — video has no on-chain send path, so callers enable this only when the
    /// Nextcloud media-send route can carry the file.
    var onCaptureVideo: ((URL) -> Void)? = nil

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        if onCaptureVideo != nil {
            picker.mediaTypes = ["public.image", "public.movie"]
            picker.videoQuality = .typeHigh
        }
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, onCancel: onCancel, onCaptureVideo: onCaptureVideo)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let onCapture: (Data) -> Void
        private let onCancel: () -> Void
        private let onCaptureVideo: ((URL) -> Void)?

        init(onCapture: @escaping (Data) -> Void, onCancel: @escaping () -> Void, onCaptureVideo: ((URL) -> Void)?) {
            self.onCapture = onCapture
            self.onCancel = onCancel
            self.onCaptureVideo = onCaptureVideo
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            // Recorded video: the picker's media URL lives in a system temp spot that can be
            // reclaimed after dismissal — copy it into our own temp dir before handing it over.
            if let onCaptureVideo, let mediaURL = info[.mediaURL] as? URL {
                let stableURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("kachat-capture-\(UUID().uuidString).\(mediaURL.pathExtension.isEmpty ? "mov" : mediaURL.pathExtension)")
                do {
                    try FileManager.default.copyItem(at: mediaURL, to: stableURL)
                    onCaptureVideo(stableURL)
                } catch {
                    onCancel()
                }
                return
            }
            guard let image = info[.originalImage] as? UIImage else {
                onCancel()
                return
            }
            // JPEG-encoding a full-resolution camera photo (often 12MP+) is expensive enough to
            // visibly stall the dismiss animation if done synchronously on the main thread here.
            let onCapture = onCapture
            let onCancel = onCancel
            Task.detached(priority: .userInitiated) {
                guard let data = image.jpegData(compressionQuality: 0.9) else {
                    await MainActor.run { onCancel() }
                    return
                }
                await MainActor.run { onCapture(data) }
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCancel()
        }
    }
}

/// Camera and microphone access for the chat composers (1:1 and group). The first use asks with
/// the system prompt (the reasons are `NSCameraUsageDescription` / `NSMicrophoneUsageDescription`,
/// translated in each language's InfoPlist.strings). Once access is off, the composers show
/// `mediaAccessAlert`, which explains it and opens Settings, instead of a blank camera or a bare
/// error. Someone who has just tapped Don't Allow isn't told again.
enum MediaAccess: Identifiable {
    case camera
    case microphone

    var id: Self { self }

    /// Access was turned off (or is restricted): asking again shows nothing, only Settings helps.
    var isDenied: Bool {
        switch self {
        case .camera:
            let status = AVCaptureDevice.authorizationStatus(for: .video)
            return status == .denied || status == .restricted
        case .microphone:
            if #available(iOS 17.0, *) {
                return AVAudioApplication.shared.recordPermission == .denied
            }
            return AVAudioSession.sharedInstance().recordPermission == .denied
        }
    }

    /// True when allowed; asks the first time.
    func request() async -> Bool {
        switch self {
        case .camera:
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                return true
            case .notDetermined:
                return await AVCaptureDevice.requestAccess(for: .video)
            default:
                return false
            }
        case .microphone:
            return await withCheckedContinuation { continuation in
                if #available(iOS 17.0, *) {
                    AVAudioApplication.requestRecordPermission { allowed in
                        continuation.resume(returning: allowed)
                    }
                } else {
                    AVAudioSession.sharedInstance().requestRecordPermission { allowed in
                        continuation.resume(returning: allowed)
                    }
                }
            }
        }
    }

    var title: String {
        switch self {
        case .camera: return "Camera Access Required"
        case .microphone: return "Microphone Access Required"
        }
    }

    var message: String {
        switch self {
        case .camera: return "Allow camera access in Settings to take photos in chats."
        case .microphone: return "Allow microphone access in Settings to record voice messages."
        }
    }
}

extension View {
    /// "Camera Access Required" / "Microphone Access Required" with Open Settings and Not Now,
    /// while `denied` is set.
    func mediaAccessAlert(_ denied: Binding<MediaAccess?>) -> some View {
        alert(
            Text(LocalizedStringKey(denied.wrappedValue?.title ?? "")),
            isPresented: Binding(
                get: { denied.wrappedValue != nil },
                set: { if !$0 { denied.wrappedValue = nil } }
            ),
            presenting: denied.wrappedValue
        ) { _ in
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Not Now", role: .cancel) {}
        } message: { access in
            Text(LocalizedStringKey(access.message))
        }
    }
}
