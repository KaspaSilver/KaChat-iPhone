import AVFoundation
import SwiftUI
import PhotosUI
import UIKit
import UniformTypeIdentifiers

/// What a "+"-sheet media row captures. With a Nextcloud server linked, each of these asks where
/// the media goes - on chain or via Nextcloud - every time, which is what replaced the old
/// "Send Media via Nextcloud" setting. Without one, the row goes straight to the on-chain path.
enum ComposerMediaKind: Equatable {
    case camera
    case photo
    case voice
}

enum ComposerMediaLimits {
    /// Ceiling for a voice note uploaded to Nextcloud, everywhere in the app (1:1 and groups).
    /// On-chain voice notes: 2:50 in 1:1 and 1:50 in groups, at 16 kbps, as long as 1 KAS of fees
    /// allows (`VoiceNotePolicy`, MESSAGING.md "Long voice notes (multi-part)").
    static let nextcloudVoiceSeconds: TimeInterval = 300
}

/// The "+" sheet's second step for Camera / Photo / Voice Message: on chain, or via Nextcloud.
/// Shown only while a Nextcloud server is connected.
struct ComposerMediaRouteStep: View {
    let kind: ComposerMediaKind
    /// The on-chain voice cap of the chat that opened this, in seconds: 170 in 1:1 chats, 110 in
    /// groups (`VoiceNotePolicy`). Shown as "Up to 2:50, sent on chain."
    var onChainVoiceSeconds: Int = Int(VoiceNotePolicy.oneToOne.maxSeconds)
    let onChoose: (_ viaNextcloud: Bool) -> Void
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text(LocalizedStringKey(title))
                .font(.headline)
                .padding(.top, 20)
                .padding(.bottom, 4)

            ActionSheetRow(title: onChainTitle, subtitle: onChainSubtitle, systemImage: "link") {
                onChoose(false)
            }
            ActionSheetRow(
                title: nextcloudTitle,
                subtitle: nextcloudSubtitle,
                systemImage: "externaldrive.connected.to.line.below"
            ) {
                onChoose(true)
            }

            Button("Back", action: onBack)
                .font(.subheadline.weight(.semibold))
                .padding(.top, 4)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var title: String {
        switch kind {
        case .camera: return "Camera"
        case .photo: return "Photo"
        case .voice: return "Voice Message"
        }
    }

    private var onChainTitle: String {
        switch kind {
        case .camera: return "Take On-Chain Photo"
        case .photo: return "Send Photo On-Chain"
        case .voice: return "Record On-Chain"
        }
    }

    private var onChainSubtitle: String {
        switch kind {
        case .camera: return "Take a photo and send it on chain, compressed to fit."
        case .photo: return "Pick an image and send it on chain, compressed to fit."
        case .voice:
            // Already localized (the row would otherwise look the formatted text up as a key).
            let seconds = max(0, onChainVoiceSeconds)
            let length = String(format: "%d:%02d", seconds / 60, seconds % 60)
            return String(format: AppLocalization.string("Up to %@, sent on chain."), locale: AppLocalization.locale, length)
        }
    }

    private var nextcloudTitle: String {
        switch kind {
        case .camera: return "Take Photo via Nextcloud"
        case .photo: return "Send Photo or Video via Nextcloud"
        case .voice: return "Record via Nextcloud"
        }
    }

    private var nextcloudSubtitle: String {
        switch kind {
        case .camera: return "Full quality, or a video. Uploads to your Nextcloud; the chat carries the link."
        case .photo: return "Full quality, or a video. Uploads to your Nextcloud; the chat carries the link."
        case .voice: return "Up to 5 minutes. Uploads to your Nextcloud; the chat carries the link."
        }
    }
}

/// Send-time quality for an on-chain photo, 1:1 and groups: High (up to 1 KAS), Medium (up to
/// 0.5 KAS), Low (up to 0.1 KAS) - `PhotoTier`, MESSAGING.md "Photos: quality tiers and
/// multi-part photos". Each row shows its budget until the photo has been compressed for it,
/// then the fee that photo will cost. The Nextcloud route never shows this.
struct PhotoQualitySheet: View {
    /// The fee of each tier's compressed photo, once known.
    let fees: [PhotoTier: UInt64]
    let onChoose: (PhotoTier) -> Void
    let onCancel: () -> Void

    static let height: CGFloat = 330

    var body: some View {
        VStack(spacing: 12) {
            Text("Photo Quality")
                .font(.headline)
                .padding(.top, 20)
                .padding(.bottom, 4)

            ForEach(PhotoTier.allCases) { tier in
                ActionSheetRow(title: tier.title, subtitle: subtitle(for: tier), systemImage: icon(for: tier)) {
                    onChoose(tier)
                }
            }

            Button("Cancel", action: onCancel)
                .font(.subheadline.weight(.semibold))
                .padding(.top, 4)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func icon(for tier: PhotoTier) -> String {
        switch tier {
        case .high: return "photo.fill"
        case .medium: return "photo"
        case .low: return "photo.badge.arrow.down"
        }
    }

    /// "(~1 KAS)": the tier's budget until this photo's own fee is worked out, then that fee,
    /// rounded the same way. Language-neutral, so not a localized string.
    private func subtitle(for tier: PhotoTier) -> String {
        let sompi = fees[tier] ?? tier.budgetSompi
        return KaspaUnit.label("(~\(Self.amount(sompi)) KAS)")
    }

    /// Two decimals (0.9912 -> 0.99, 0.4975 -> 0.5, 0.0977 -> 0.1); below 0.01, two significant
    /// digits, so a tiny fee never reads as 0.
    private static func amount(_ sompi: UInt64) -> String {
        let kas = Double(sompi) / 100_000_000
        let formatter = NumberFormatter()
        formatter.locale = AppLocalization.locale
        formatter.numberStyle = .decimal
        if kas > 0, kas < 0.01 {
            formatter.usesSignificantDigits = true
            formatter.maximumSignificantDigits = 2
        } else {
            formatter.minimumFractionDigits = 0
            formatter.maximumFractionDigits = 2
        }
        return formatter.string(from: NSNumber(value: kas)) ?? "\(kas)"
    }
}

/// A video picked from the photo library ("Send Photo or Video via Nextcloud"), copied to a temp
/// file the caller owns - the Nextcloud video send deletes it once uploaded.
struct PickedMovieFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent("kachat-picked-video-\(UUID().uuidString).\(ext)")
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedMovieFile(url: copy)
        }
    }
}

extension PhotosPickerItem {
    /// The library item is a video rather than a still. A Live Photo can list a movie type
    /// beside its image types; it is a photo, so anything that also offers an image is one.
    var isMovie: Bool {
        supportedContentTypes.contains { $0.conforms(to: .movie) }
            && !supportedContentTypes.contains { $0.conforms(to: .image) }
    }
}

/// A photo or video picked "via Nextcloud", waiting in the composer. Its upload starts the
/// moment it is staged, not when send is tapped, and the send button spins until the share
/// link is back - then a tap sends the link. Shared by 1:1 and group chats.
struct NextcloudStagedMedia: Identifiable, Equatable {
    enum Kind: Equatable { case image, video }
    enum Phase: Equatable {
        case uploading
        case ready(URL)
        /// Photos only: send then puts the photo on chain. A video that fails is dropped from the
        /// composer instead, since no on-chain path fits one.
        case failed
    }

    let id = UUID()
    let kind: Kind
    var phase: Phase = .uploading

    var isUploading: Bool { phase == .uploading }
}

/// The first frame of a picked or recorded video, for the composer's thumbnail.
enum VideoThumbnail {
    static func image(for fileURL: URL) async -> UIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: fileURL))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 300, height: 300)
        guard let cgImage = try? await generator.image(at: .zero).image else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
