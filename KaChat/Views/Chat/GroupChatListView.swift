import SwiftUI
import UIKit

/// Group Chats, a dock tab of its own (since 2026-10-26; from 2026-10-05 they were circles in the
/// row above the chats). Every group, pinned ones first, then the rest by latest activity. Tap
/// opens; hold opens the half sheet (read state, pin, notifications, delete); Select marks read,
/// unread or deletes several at once. The + starts a new group. A tapped group notification lands
/// here (`MainTabView` switches to this tab) and opens its group.
struct GroupChatListView: View {
    @EnvironmentObject var groupChatService: GroupChatService
    @EnvironmentObject var contactsManager: ContactsManager
    @EnvironmentObject var walletManager: WalletManager
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var searchText = ""
    @State private var selectedGroup: GroupChat?
    @State private var showCreateGroup = false
    /// Group ids pinned to the top of the list, newest pin first, saved per wallet.
    @State private var pins: [String] = []
    /// The row whose long-press half sheet is up.
    @State private var actionTarget: GroupChat?
    /// A group waiting on its delete confirmation, from that sheet.
    @State private var deleteTarget: GroupChat?
    @State private var showBulkDeleteConfirmation = false
    @State private var editMode: EditMode = .inactive
    @State private var selectedGroupIDs: Set<String> = []
    @State private var toastMessage: String?
    @State private var toastToken = UUID()
    @State private var splitColumnVisibility: NavigationSplitViewVisibility = .all

    private var shouldUseSplitLayout: Bool {
#if targetEnvironment(macCatalyst)
        true
#else
        horizontalSizeClass == .regular
#endif
    }

    var body: some View {
        Group {
            if shouldUseSplitLayout {
                NavigationSplitView(columnVisibility: $splitColumnVisibility) {
                    listPane
                } detail: {
                    splitDetailPane
                }
                .navigationSplitViewStyle(.balanced)
                .onAppear {
                    splitColumnVisibility = .all
                }
            } else {
                NavigationStack {
                    listPane
                        .modifier(GroupChatDetailNavigationDestination(selectedGroup: $selectedGroup))
                }
            }
        }
    }

    /// Staged like `ChatListView.chatListPane`, so the type checker never solves the whole
    /// modifier chain as one expression.
    private var listPane: some View {
        let withToolbar = groupList
            .navigationTitle("Groups")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    ConnectionStatusIndicator()
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if editMode == .active {
                        Button(isEverythingSelected ? "Deselect All" : "Select All") {
                            selectedGroupIDs = isEverythingSelected ? [] : Set(displayedGroups.map(\.id))
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(editMode == .active ? "Cancel" : "Select") {
                        withAnimation {
                            editMode = editMode == .active ? .inactive : .active
                        }
                    }
                }
            }

        let withPresentation = withToolbar
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search group chats"
            )
            .refreshable {
                await groupChatService.performCatchUpSync()
            }
            .toast(message: toastMessage)
            .sheet(item: $actionTarget) { group in
                actionSheet(for: group)
            }
            .sheet(isPresented: $showCreateGroup) {
                AddContactView(
                    startInGroupMode: true,
                    onCreateGroup: { group in
                        showCreateGroup = false
                        selectedGroup = group
                    },
                    onCancel: { showCreateGroup = false }
                )
                .environmentObject(walletManager)
                .presentationDragIndicator(.visible)
            }

        let withAlerts = withPresentation
            .alert(
                "Delete Group?",
                isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
                presenting: deleteTarget
            ) { group in
                Button("Delete", role: .destructive) { deleteGroups([group]) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("This removes this group and its messages from this device. This cannot be undone, and other members won't be notified.")
            }
            .alert(bulkDeleteAlertTitle, isPresented: $showBulkDeleteConfirmation) {
                Button("Delete", role: .destructive) {
                    let groups = groupChatService.groups.filter { selectedGroupIDs.contains($0.id) }
                    if !groups.isEmpty { deleteGroups(groups) }
                    editMode = .inactive
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes each selected group and its messages from this device. This cannot be undone, and other members won't be notified.")
            }

        return withAlerts
            .environment(\EnvironmentValues.editMode, $editMode)
    }

    @ViewBuilder
    private var splitDetailPane: some View {
        if let group = selectedGroup {
            GroupChatDetailView(group: group, onDeleted: { selectedGroup = nil })
                .id(group.id)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "person.3")
                    .font(.scaled(size: 44))
                    .foregroundColor(.secondary)
                Text("Select a group chat")
                    .font(.title3)
                    .fontWeight(.semibold)
                Text("Choose a group on the left")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
            .background(Color(UIColor.systemBackground))
        }
    }

    private var groupList: some View {
        let groups = displayedGroups
        return List(selection: $selectedGroupIDs) {
            ForEach(groups) { group in
                Button {
                    // The hold that opened the half sheet ends in a touch-up that still fires
                    // this Button (simultaneousGesture) - the target being set IS "this touch
                    // was the hold" (same guard as the chat rows).
                    guard actionTarget == nil else { return }
                    // Our Button consumes the tap before List(selection:) sees it, so Select
                    // mode toggles here (as in `ChatListView`).
                    if editMode == .active {
                        if selectedGroupIDs.contains(group.id) {
                            selectedGroupIDs.remove(group.id)
                        } else {
                            selectedGroupIDs.insert(group.id)
                        }
                    } else {
                        selectedGroup = group
                    }
                } label: {
                    GroupChatRow(group: group)
                        .overlay(alignment: .bottomLeading) {
                            if pins.contains(group.id) && editMode != .active {
                                Image(systemName: "pin.fill")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(4)
                                    .background(Circle().fill(Color.accentColor))
                                    .offset(x: -2, y: 0)
                                    .accessibilityLabel("Pinned")
                            }
                        }
                }
                .buttonStyle(ChatRowPressStyle())
                // A Button label needs simultaneousGesture (see the chat rows).
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.4).onEnded { _ in
                        guard editMode != .active else { return }
                        Haptics.impact(.medium)
                        actionTarget = group
                    }
                )
                .tag(group.id)
                .listRowBackground(
                    shouldUseSplitLayout && selectedGroup?.id == group.id
                        ? Color.accentColor.opacity(0.14)
                        : Color.clear
                )
            }
        }
        .listStyle(.plain)
        .overlay(alignment: .center) {
            if groups.isEmpty && searchText.isEmpty {
                emptyStateView
                    .allowsHitTesting(false)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if editMode == .active {
                selectionActionBar
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if editMode != .active {
                newButton
            }
        }
        .onAppear {
            loadPins()
            checkPendingGroupNavigation()
            checkPendingGroupListNavigation()
        }
        .onChange(of: walletManager.currentWallet?.publicAddress) { _ in
            loadPins()
            // An account switch keeps this view alive, so a group open in the old account would
            // otherwise reopen in the new one. Every account starts on its own list.
            selectedGroup = nil
            selectedGroupIDs = []
            editMode = .inactive
        }
        .onChange(of: editMode) { newValue in
            if newValue == .inactive {
                selectedGroupIDs = []
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openGroup)) { notification in
            handleOpenGroupNotification(notification)
        }
        .onChange(of: groupChatService.pendingGroupNavigation) { newValue in
            if newValue != nil {
                checkPendingGroupNavigation()
            }
        }
        .onChange(of: groupChatService.pendingGroupListNavigation) { newValue in
            if newValue { checkPendingGroupListNavigation() }
        }
        .onChange(of: groupChatService.groups) { _ in
            // A pending group tap that arrived before its group was created (catch-up in flight)
            // resolves the instant the group is inserted into the list.
            checkPendingGroupNavigation()
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "person.3")
                .font(.scaled(size: 60))
                .foregroundColor(.secondary)

            Text("No Group Chats Yet")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Start a new group from the add-chat button")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .padding()
    }

    /// The floating glass "+" in the bottom-right corner (as on Chats): straight to New Group Chat.
    private var newButton: some View {
        Button {
            Haptics.impact(.light)
            showCreateGroup = true
        } label: {
            Image(systemName: "plus")
                .font(.scaled(size: 22, weight: .semibold))
                .foregroundColor(.accentColor)
                .frame(width: 56, height: 56)
                .background(
                    Circle()
                        .fill(.regularMaterial)
                        .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 0.8))
                        .shadow(color: Color.black.opacity(0.12), radius: 10, x: 0, y: 5)
                )
        }
        .padding(.trailing, 20)
        .padding(.bottom, 16)
        .accessibilityLabel(Text("New Group Chat"))
    }

    // MARK: - Groups shown

    /// Pinned groups first (newest pin first), then the rest by latest activity - the last
    /// message, else when the group was created, so a brand-new empty group still sorts by when
    /// it was added. Filtered by search on the group name, each member's alias or address, and
    /// message content. Shared by Select All and the bulk actions so they agree on what's visible.
    private var displayedGroups: [GroupChat] {
        // Decorate-sort-undecorate: the key is computed once per group. Group message arrays are
        // kept in chronological order, so the last message carries the newest timestamp.
        let groupMessages = groupChatService.groupMessages
        let sorted = groupChatService.groups
            .map { (key: groupMessages[$0.id]?.last?.timestamp ?? $0.createdAt, value: $0) }
            .sorted { $0.key > $1.key }
            .map(\.value)
        let byId = Dictionary(sorted.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let pinned = pins.compactMap { byId[$0] }
        let pinnedIds = Set(pinned.map(\.id))
        let ordered = pinned + sorted.filter { !pinnedIds.contains($0.id) }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return ordered }
        return ordered.filter { group in
            if group.name.range(of: query, options: .caseInsensitive) != nil {
                return true
            }
            if group.members.contains(where: { member in
                if let alias = contactsManager.getContact(byAddress: member.address)?.alias,
                   alias.range(of: query, options: .caseInsensitive) != nil {
                    return true
                }
                return member.address.range(of: query, options: .caseInsensitive) != nil
            }) {
                return true
            }
            return (groupMessages[group.id] ?? []).contains { message in
                // Skip media envelopes: a photo/voice message's content is a multi-KB base64
                // blob, and substring-scanning those froze the search field on media-heavy
                // histories (nobody is searching for base64 fragments).
                message.content.utf8.count <= 4096 &&
                    message.content.range(of: query, options: .caseInsensitive) != nil
            }
        }
    }

    private var isEverythingSelected: Bool {
        let total = displayedGroups.count
        return total > 0 && selectedGroupIDs.count >= total
    }

    // MARK: - Pins

    private var pinsKey: String? {
        guard let address = walletManager.currentWallet?.publicAddress.lowercased() else { return nil }
        return "kachat_group_pins_\(address)"
    }

    /// The first time, the groups pinned in the old circles row above the chats (their "g:" ids
    /// in `kachat_chat_circle_pins_`) carry over, in the same order.
    private func loadPins() {
        guard let key = pinsKey, let address = walletManager.currentWallet?.publicAddress.lowercased() else {
            pins = []
            return
        }
        if let saved = UserDefaults.standard.stringArray(forKey: key) {
            pins = saved
            return
        }
        let circlePins = UserDefaults.standard.stringArray(forKey: "kachat_chat_circle_pins_\(address)") ?? []
        pins = circlePins.filter { $0.hasPrefix("g:") }.map { String($0.dropFirst(2)) }
        UserDefaults.standard.set(pins, forKey: key)
    }

    /// Hold a group: pin it to the top (newest pin first), or unpin it.
    private func togglePin(_ groupId: String) {
        if let index = pins.firstIndex(of: groupId) {
            pins.remove(at: index)
            showToast(AppLocalization.string("Unpinned"))
        } else {
            pins.insert(groupId, at: 0)
            showToast(AppLocalization.string("Pinned to the front"))
        }
        if let key = pinsKey { UserDefaults.standard.set(pins, forKey: key) }
    }

    // MARK: - Actions

    /// Mark read, mark unread and delete, for every selected group.
    private var selectionActionBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                Button {
                    let groups = groupChatService.groups.filter { selectedGroupIDs.contains($0.id) }
                    if !groups.isEmpty { groupChatService.markGroupsAsRead(groups) }
                    editMode = .inactive
                } label: {
                    Image(systemName: "envelope.open")
                        .frame(maxWidth: .infinity)
                }
                .disabled(selectedGroupIDs.isEmpty)

                Button {
                    let groups = groupChatService.groups.filter { selectedGroupIDs.contains($0.id) }
                    if !groups.isEmpty { groupChatService.markGroupsAsUnread(groups) }
                    editMode = .inactive
                } label: {
                    Image(systemName: "envelope.badge")
                        .frame(maxWidth: .infinity)
                }
                .disabled(selectedGroupIDs.isEmpty)

                Button(role: .destructive) {
                    showBulkDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity)
                }
                .disabled(selectedGroupIDs.isEmpty)
            }
            .font(.scaled(size: 18))
            .buttonStyle(.bordered)
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
        .background(.bar)
    }

    /// A group row's long-press half sheet: read state, pin, notifications and delete.
    private func actionSheet(for group: GroupChat) -> some View {
        let isSilent = groupChatService.silentNotifications(for: group.id)
        let isPinned = pins.contains(group.id)
        return VStack(spacing: 12) {
            Text(group.name)
                .font(.headline)
                .lineLimit(1)
                .padding(.top, 20)
                .padding(.bottom, 4)

            ActionSheetTiles {
                if groupChatService.unreadCount(for: group) > 0 {
                    ActionSheetRow(title: "Mark as Read", subtitle: "Clears the unread badge on this group.", systemImage: "envelope.open") {
                        actionTarget = nil
                        groupChatService.markGroupAsRead(group.id)
                    }
                } else {
                    ActionSheetRow(title: "Mark as Unread", subtitle: "Puts the unread badge back so you come across it again.", systemImage: "envelope.badge") {
                        actionTarget = nil
                        groupChatService.markGroupAsUnread(group.id)
                    }
                }
                ActionSheetRow(
                    title: isPinned ? "Unpin" : "Pin to Front",
                    subtitle: isPinned ? "Goes back to its place by latest activity." : "Keeps it first in your group chats.",
                    systemImage: isPinned ? "pin.slash" : "pin"
                ) {
                    actionTarget = nil
                    togglePin(group.id)
                }
                ActionSheetRow(
                    title: isSilent ? "Unsilence" : "Silence",
                    subtitle: isSilent
                        ? "Notifications from this group resume, including mentions."
                        : "No notification from this group, mentions included.",
                    systemImage: isSilent ? "bell" : "bell.slash"
                ) {
                    actionTarget = nil
                    groupChatService.setSilentNotifications(!isSilent, for: group.id)
                }
                ActionSheetRow(title: "Delete", subtitle: "Removes this group and its messages from this device.", systemImage: "trash", tint: .red) {
                    actionTarget = nil
                    // One turn later: the alert can't present while the sheet is going down.
                    DispatchQueue.main.async { deleteTarget = group }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .presentationDetents([.height(ActionSheetTileMetrics.sheetHeight(tiles: 4))])
        .presentationDragIndicator(.visible)
    }

    private var bulkDeleteAlertTitle: String {
        let count = selectedGroupIDs.count
        return "Delete \(count) Group\(count == 1 ? "" : "s")?"
    }

    private func deleteGroups(_ groups: [GroupChat]) {
        guard !groups.isEmpty else { return }
        for group in groups {
            if selectedGroup?.id == group.id { selectedGroup = nil }
            groupChatService.deleteGroup(group.id)
        }
        let deleted = Set(groups.map(\.id))
        pins.removeAll { deleted.contains($0) }
        if let key = pinsKey { UserDefaults.standard.set(pins, forKey: key) }
        selectedGroupIDs = []
        showToast(groups.count == 1 ? "Group deleted." : "\(groups.count) groups deleted.")
    }

    private func showToast(_ message: String) {
        let token = UUID()
        toastToken = token
        withAnimation(.easeOut(duration: 0.2)) {
            toastMessage = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if toastToken == token {
                withAnimation(.easeIn(duration: 0.2)) {
                    toastMessage = nil
                }
            }
        }
    }

    // MARK: - Notification routing

    private func handleOpenGroupNotification(_ notification: Notification) {
        guard let groupId = notification.userInfo?["groupId"] as? String, !groupId.isEmpty else {
            // Group notification with no group to open (the undecryptable-push fallback, thread
            // id "group"): this list is as specific as that tap can get.
            groupChatService.pendingGroupListNavigation = false
            return
        }
        navigateToGroup(groupId: groupId)
    }

    private func checkPendingGroupListNavigation() {
        guard groupChatService.pendingGroupListNavigation else { return }
        groupChatService.pendingGroupListNavigation = false
    }

    private func checkPendingGroupNavigation() {
        guard let groupId = groupChatService.pendingGroupNavigation else { return }
        // Don't consume the pending navigation until the group actually exists locally: a tap that
        // arrives before catch-up has created the group (e.g. "you were added to a group") would
        // otherwise be dropped silently. The .onChange(of: groupChatService.groups) above re-runs
        // this the moment the group is inserted, so the tap resolves as soon as it lands.
        guard groupChatService.groups.contains(where: { $0.id == groupId }) else { return }
        groupChatService.pendingGroupNavigation = nil
        navigateToGroup(groupId: groupId)
    }

    private func navigateToGroup(groupId: String) {
        guard let target = groupChatService.groups.first(where: { $0.id == groupId }) else { return }
        if groupChatService.pendingGroupNavigation == groupId {
            groupChatService.pendingGroupNavigation = nil
        }
        editMode = .inactive
        selectedGroup = target
    }
}

/// `.navigationDestination(item:)` (iOS 17+), for the same race-free pop as
/// `ChatDetailNavigationDestination` in ChatListView.swift; iOS 16 falls back to `isPresented:`.
private struct GroupChatDetailNavigationDestination: ViewModifier {
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

/// One group in Group Chats: photo, name, the latest message (or reaction) and the unread count.
struct GroupChatRow: View {
    let group: GroupChat
    @EnvironmentObject var groupChatService: GroupChatService
    @EnvironmentObject var contactsManager: ContactsManager
    @EnvironmentObject var walletManager: WalletManager
    @ObservedObject private var knsService = KNSService.shared

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
        HStack(spacing: 12) {
            if let img = groupPhotoImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 50, height: 50)
                    .clipShape(Circle())
            } else {
                Circle()
                    .fill(Color.accentColor.opacity(0.2))
                    .frame(width: 50, height: 50)
                    .overlay(
                        Image(systemName: "person.3.fill")
                            .font(.scaled(size: 18))
                            .foregroundColor(.accentColor)
                    )
            }

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
                        Text("\(group.members.count) member\(group.members.count == 1 ? "" : "s")")
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
