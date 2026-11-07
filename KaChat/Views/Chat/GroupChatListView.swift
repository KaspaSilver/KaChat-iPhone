import SwiftUI
import UIKit

/// `.navigationDestination(item:)` (iOS 17+), for the same race-free pop as
/// `ChatDetailNavigationDestination` in ChatListView.swift; iOS 16 falls back to `isPresented:`.
struct GroupChatDetailNavigationDestination: ViewModifier {
    @Binding var selectedGroup: GroupChat?

    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.navigationDestination(item: $selectedGroup) { group in
                GroupChatDetailView(group: group, onDeleted: { selectedGroup = nil })
            }
        } else {
            content.navigationDestination(isPresented: Binding(
                get: { selectedGroup != nil },
                set: { isPresented in
                    if !isPresented {
                        selectedGroup = nil
                    }
                }
            )) {
                if let group = selectedGroup {
                    GroupChatDetailView(group: group, onDeleted: { selectedGroup = nil })
                } else {
                    EmptyView()
                }
            }
        }
    }
}

/// One group in the chat list: photo, name, the latest message (or reaction) and the unread count.
struct GroupChatRow: View {
    let group: GroupChat
    @EnvironmentObject var groupChatService: GroupChatService
    @EnvironmentObject var contactsManager: ContactsManager
    @EnvironmentObject var walletManager: WalletManager

    /// Messages are stored oldest-first (loaded sorted, then appended), so the newest is the
    /// last element. This used to be a `max` scan of the whole array - evaluated several times
    /// per row body, on every one of the service's frequent publishes during a sync.
    private var lastMessage: GroupMessage? {
        groupChatService.groupMessages[group.id]?.last
    }

    /// Group mirror of ConversationRow.reactionPreviewText: a reaction newer than the last
    /// message becomes the row's preview ("Alice reacted to a message") - reactions never
    /// become messages (they render as a corner pill), so without this the row would keep
    /// showing an older message as if nothing happened. `nil` when the newest activity is a
    /// regular message.
    private var reactionPreviewText: String? {
        guard let byTarget = groupChatService.reactionsByGroupId[group.id], !byTarget.isEmpty else { return nil }
        // Pick the newest reaction purely from the reaction snapshots, then resolve its target
        // once. Resolving inside the loop meant a linear search of the group's whole message
        // array for every reaction target that briefly held the lead.
        var newestSnapshot: (snapshot: GroupStore.ReactionSnapshot, targetTxId: String)?
        for (targetTxId, snapshots) in byTarget {
            guard let candidate = snapshots.max(by: { $0.blockTime < $1.blockTime }) else { continue }
            if newestSnapshot == nil || candidate.blockTime > newestSnapshot!.snapshot.blockTime {
                newestSnapshot = (candidate, targetTxId)
            }
        }
        guard let newestSnapshot else { return nil }
        let newest = (
            snapshot: newestSnapshot.snapshot,
            targetIsMine: groupChatService.groupMessages[group.id]?
                .first(where: { $0.txId == newestSnapshot.targetTxId })?.isOutgoing == true
        )
        let reactionDate = Date(timeIntervalSince1970: TimeInterval(newest.snapshot.blockTime) / 1000.0)
        if let lastMessage, lastMessage.timestamp >= reactionDate { return nil }
        if newest.snapshot.reactorAddress == walletManager.currentWallet?.publicAddress {
            return newest.targetIsMine ? "You reacted to your message" : "You reacted to a message"
        }
        let name = resolveDisplayName(for: newest.snapshot.reactorAddress)
        return newest.targetIsMine ? "\(name) reacted to your message" : "\(name) reacted to a message"
    }

    /// Same resolution as `GroupChatDetailView.displayName(for:)`.
    private func resolveDisplayName(for address: String) -> String {
        // The app's one rule (ContactsManager.displayName): your name for them, else their
        // .kachat name on testnet (KNS elsewhere), else the short address.
        contactsManager.displayName(for: address)
    }

    var body: some View {
        HStack(spacing: 12) {
            GroupAvatar(group: group, size: 50)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(group.name)
                        .font(.headline)
                        .lineLimit(1)
                    // Silenced: no banner from this group, mentioned or not.
                    if groupChatService.silentNotifications(for: group.id) {
                        Image(systemName: "bell.slash.fill")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .accessibilityLabel("Silenced")
                    }

                    Spacer()

                    if let lastMessage {
                        Text(formatDate(lastMessage.timestamp))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                HStack {
                    if let reactionPreview = reactionPreviewText {
                        Text(reactionPreview)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    } else if let lastMessage {
                        Text(GroupMentionCodec.decodeForDisplay(LinkSafePreview.apply(to: MessageReplyCodec.previewText(for: lastMessage.content)), members: group.members, resolveDisplayName: resolveDisplayName(for:)))
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    } else {
                        Text("\(group.members.count) member\(pluralS(group.members.count))")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .italic()
                    }

                    Spacer()

                    let unreadCount = groupChatService.unreadCount(for: group)
                    if unreadCount > 0 {
                        Text("\(unreadCount)")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor)
                            .clipShape(Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func formatDate(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return SharedFormatting.chatTime.string(from: date)
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            return SharedFormatting.chatDay.string(from: date)
        }
    }
}

/// A group's photo in a circle, or the group symbol when it has none - its chat list row and
/// its pinned circle.
struct GroupAvatar: View {
    let group: GroupChat
    let size: CGFloat
    @EnvironmentObject var groupChatService: GroupChatService

    /// Decoded group photos, keyed on the group id, the hex length and the payload's tail:
    /// hex-decoding and then JPEG-decoding the photo on every body pass made each row pay for
    /// the whole image on every list refresh. A photo change always changes the hex payload
    /// (and almost always its length), so a stale entry could only survive a same-length
    /// replacement whose final bytes also match - and hashing only the tail keeps the key
    /// itself cheap for a payload that can run to hundreds of kilobytes.
    private static let groupPhotoCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 64
        return cache
    }()

    private var groupPhotoImage: UIImage? {
        guard let hex = groupChatService.groupPhotos[group.id] else { return nil }
        let cacheKey = "\(group.id)|\(hex.count)|\(hex.suffix(256).hashValue)" as NSString
        if let cached = Self.groupPhotoCache.object(forKey: cacheKey) {
            return cached
        }
        guard let data = Data(hexString: hex), let image = UIImage(data: data) else { return nil }
        Self.groupPhotoCache.setObject(image, forKey: cacheKey)
        return image
    }

    var body: some View {
        if let img = groupPhotoImage {
            Image(uiImage: img)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
        } else {
            Circle()
                .fill(Color.accentColor.opacity(0.2))
                .frame(width: size, height: size)
                .overlay(
                    Image(systemName: "person.3.fill")
                        .font(.scaled(size: size * 0.36))
                        .foregroundColor(.accentColor)
                )
        }
    }
}
