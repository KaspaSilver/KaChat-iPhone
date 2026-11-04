import SwiftUI
import UserNotifications
import UIKit

struct ChatListView: View {
    @EnvironmentObject var chatService: ChatService
    @EnvironmentObject var groupChatService: GroupChatService
    @EnvironmentObject var contactsManager: ContactsManager
    @EnvironmentObject var walletManager: WalletManager
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// One row of the list: chats and groups share it, by latest activity.
    private enum ChatListEntry: Identifiable {
        case chat(Conversation)
        case group(GroupChat)

        var id: String {
            switch self {
            case .chat(let conversation): return ChatListView.entryID(conversation)
            case .group(let group): return ChatListView.entryID(group)
            }
        }
    }

    /// What the + sheet is showing: the choice, or the screen it led to.
    private enum CreateStep { case menu, chat, group }

    @State private var searchText = ""
    @State private var selectedContact: Contact?
    @State private var selectedGroup: GroupChat?
    /// Group ids pinned up into the circles row, newest pin first, saved per wallet.
    @State private var groupPins: [String] = []
    /// The pinned group whose long-press half sheet is up (list rows swipe instead).
    @State private var groupActionTarget: GroupChat?
    /// A group waiting on its delete confirmation.
    @State private var groupDeleteTarget: GroupChat?
    @State private var showMessageRequests = false
    @State private var selectedContactStartInPaymentMode = false
    /// The bottom-right +: New Chat or New Group Chat, then that screen, all in one sheet.
    @State private var showCreateSheet = false
    @State private var createStep: CreateStep = .menu
    @State private var createDetent: PresentationDetent = Self.createMenuHeight
    /// From a profile link: the person whose User Info is up.
    @State private var linkedProfileContact: Contact?
    /// What is pinned in the circles row, in order, saved per wallet: bots ("b:<address>") pinned
    /// to its front, and chats ("c:<address>") pinned up out of the list into the row. (The key
    /// once held group circles too, as "g:<groupId>"; Group Chats took those over and the row
    /// ignores them.)
    @State private var circlePins: [String] = []
    /// The circle whose long-press half sheet is up ("b:<address>").
    @State private var circleActionTarget: CircleActionTarget?
    private struct CircleActionTarget: Identifiable { let id: String }
    @State private var toastMessage: String?
    @State private var toastToken = UUID()
    @State private var toastStyle: ToastStyle = .success
    @State private var loadedConversationCount = 80
    @State private var isPaginatingConversations = false
    @State private var filteredConversationsCache: [Conversation] = []
    @State private var searchFilterTask: Task<Void, Never>?
    /// True for the duration of a pull-to-refresh. While set, conversation/contact changes DON'T
    /// rebuild the visible list — reloading the underlying List mid-spin resets the native refresh
    /// control's animation, which is what made the wheel blink/stutter. The coalesced changes are
    /// applied in one pass when the pull finishes (the spinner is dismissing then anyway).
    @State private var isPullRefreshing = false
    @State private var avatarPrefetchTask: Task<Void, Never>?
    @State private var splitColumnVisibility: NavigationSplitViewVisibility = .all
    @State private var showBulkDeleteConfirmation = false
    /// Row-level delete targets from a row's swipe or a circle's half sheet - separate from the
    /// Select-mode bulk selection state so such a delete never touches (or is blocked by) edit mode.
    /// Confirmed via their own alerts below, which reuse `deleteConversations`.
    @State private var rowDeleteContact: Contact?
    /// The pinned chat whose long-press action sheet is up (list rows swipe instead).
    @State private var conversationActionTarget: Conversation?
    /// The chat row's "Add to Contacts" tile: the contact whose entry sheet is up.
    @State private var addressBookTarget: Contact?
    @ObservedObject private var addressBook = AddressBookManager.shared
    @State private var editMode: EditMode = .inactive
    /// Select mode's chats and groups, as `entryID`s.
    @State private var selectedEntryIDs: Set<String> = []

    private let conversationPageSize = 80
    private let conversationPrefetchThreshold = 12

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
                    chatListPane
                } detail: {
                    splitDetailPane
                }
                .navigationSplitViewStyle(.balanced)
                .onAppear {
                    splitColumnVisibility = .all
                }
            } else {
                NavigationStack {
                    chatListPane
                        .modifier(ChatDetailNavigationDestination(
                            selectedContact: $selectedContact,
                            startInPaymentMode: selectedContactStartInPaymentMode
                        ))
                        .modifier(GroupChatDetailNavigationDestination(selectedGroup: $selectedGroup))
                }
            }
        }
    }

    private var chatListPane: some View {
        // Split into staged intermediate variables (rather than one long chained-modifier
        // expression) so the type checker isn't solving toolbar + searchable/refreshable/toast/
        // sheet + three `.alert`s + two custom modifiers + `.environment` all as a single
        // expression - that combination is what triggered "unable to type-check in reasonable
        // time" once the third `.alert` (bulk delete) was added.
        let withToolbar = VStack(spacing: 0) {
            PinnedListHeader(title: "Chats", search: $searchText, prompt: "Search chats")
            chatListContent
                .scrollDismissesKeyboard(.immediately)
        }
            .navigationTitle("Chats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    ConnectionStatusIndicator()
                }
                ToolbarItem(placement: .principal) {
                    balanceToolbarView
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if editMode == .active {
                        Button(isEverythingSelected ? "Deselect All" : "Select All") {
                            selectedEntryIDs = isEverythingSelected ? [] : Set(allEntries.map(\.id))
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
            .refreshable {
                isPullRefreshing = true
                await chatService.fetchNewMessages()
                await groupChatService.performCatchUpSync()
                isPullRefreshing = false
                // Apply everything that changed during the pull in a single rebuild, now that the
                // refresh control is no longer animating — so the wheel spins smoothly throughout.
                refreshFilteredConversations()
                scheduleAvatarPrefetch()
            }
            .toast(message: toastMessage, style: toastStyle)

        let withAlerts = withPresentation
            .sheet(item: $addressBookTarget) { contact in
                AddressBookEntryEditor(
                    address: contact.address,
                    suggestedName: contact.assignedName ?? contactsManager.displayName(for: contact)
                ) { _ in }
            }
            .sheet(item: $conversationActionTarget) { conversation in
            conversationRowSheet(for: conversation)
        }
        .sheet(item: $circleActionTarget) { target in
            circleActionSheet(for: target.id)
        }
        .alert(
                bulkDeleteAlertTitle,
                isPresented: $showBulkDeleteConfirmation
            ) {
                Button("Delete", role: .destructive) {
                    let contacts = selectedChats.map { $0.contact }
                    let groups = selectedGroups
                    if !contacts.isEmpty { deleteConversations(contacts) }
                    if !groups.isEmpty { deleteGroups(groups) }
                    selectedEntryIDs = []
                    editMode = .inactive
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(bulkDeleteAlertMessage)
            }

        // Single-row deletes confirm through their own alerts (same destructive-confirm
        // pattern and wording as the bulk alert above, singular) - staged as separate variables
        // for the same type-checker reason as the rest of this chain.
        let withRowDeleteAlert = withAlerts
            .alert(
                "Delete Chat?",
                isPresented: Binding(
                    get: { rowDeleteContact != nil },
                    set: { if !$0 { rowDeleteContact = nil } }
                ),
                presenting: rowDeleteContact
            ) { contact in
                Button("Delete", role: .destructive) {
                    deleteConversations([contact])
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("This permanently deletes every message in this chat from this device. This cannot be undone.")
            }

        let withGroupAlerts = withRowDeleteAlert
            .sheet(item: $groupActionTarget) { group in
                groupActionSheet(for: group)
            }
            .alert(
                "Delete Group?",
                isPresented: Binding(get: { groupDeleteTarget != nil }, set: { if !$0 { groupDeleteTarget = nil } }),
                presenting: groupDeleteTarget
            ) { group in
                Button("Delete", role: .destructive) { deleteGroups([group]) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("This removes this group and its messages from this device. This cannot be undone, and other members keep their copies.")
            }

        // Opening one closes the other, on a phone and in the iPad's detail pane.
        let withGroupRouting = withGroupAlerts
            .onChange(of: selectedContact?.address) { address in
                if address != nil { selectedGroup = nil }
            }
            .onChange(of: selectedGroup?.id) { id in
                if id != nil { selectedContact = nil }
            }
            .onReceive(NotificationCenter.default.publisher(for: .openGroup)) { notification in
                handleOpenGroupNotification(notification)
            }
            .onChange(of: groupChatService.pendingGroupNavigation) { newValue in
                if newValue != nil { checkPendingGroupNavigation() }
            }
            .onChange(of: groupChatService.pendingGroupListNavigation) { newValue in
                if newValue { groupChatService.pendingGroupListNavigation = false }
            }
            .onChange(of: groupChatService.pendingMessageRequestsOpen) { newValue in
                if newValue { openPendingMessageRequests() }
            }
            // A pending group tap that arrived before its group was created (catch-up in flight)
            // resolves the instant the group is inserted into the list.
            .onChange(of: groupChatService.groups) { _ in
                checkPendingGroupNavigation()
            }
            .onAppear {
                loadGroupPins()
                checkPendingGroupNavigation()
                groupChatService.pendingGroupListNavigation = false
                openPendingMessageRequests()
            }

        return withGroupRouting
            .environment(\EnvironmentValues.editMode, $editMode)
    }

    @ViewBuilder
    private var splitDetailPane: some View {
        if let group = selectedGroup {
            GroupChatDetailView(group: group, onDeleted: { selectedGroup = nil })
                .id(group.id)
        } else if let contact = selectedContact {
            ChatDetailView(contact: contact, startInPaymentMode: selectedContactStartInPaymentMode)
                .id(contact.id)
        } else {
            splitEmptyDetailView
        }
    }

    @ViewBuilder
    private var chatListContent: some View {
        // One list: the chats and groups, with the bots as circles above them (`ChatCirclesStrip`).
        chatsTabContent
        .onAppear {
            // Cold start from a profile link.
            if chatService.pendingProfileAddress != nil { openPendingProfile() }
        }
        .onChange(of: walletManager.currentWallet?.publicAddress) { _ in
            loadCirclePins()
            loadGroupPins()
            // An account switch keeps this view alive, so a chat open in the old account would
            // otherwise reopen in the new one. Every account starts on its own list.
            selectedContact = nil
            selectedGroup = nil
            selectedContactStartInPaymentMode = false
            linkedProfileContact = nil
            selectedEntryIDs = []
        }
        .onAppear { loadCirclePins() }
        .safeAreaInset(edge: .bottom) {
            if editMode == .active {
                selectionActionBar
            }
        }
        .overlay(alignment: .bottomTrailing) {
            // One on every page.
            if editMode != .active {
                newButton
            }
        }
        .sheet(isPresented: $showCreateSheet, onDismiss: resetCreateSheet) {
            createSheet
                .environmentObject(walletManager)
        }
        .onChange(of: editMode) { newValue in
            if newValue == .inactive {
                selectedEntryIDs = []
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openChat)) { notification in
            handleOpenChatNotification(notification)
        }
        .onAppear {
            checkPendingNavigation()
            requestNotificationPermissionIfNeeded()
            loadedConversationCount = conversationPageSize
            // Back from a chat: its fully loaded history can go now.
            chatService.trimLeftConversationIfNeeded()
            refreshFilteredConversations()
            Task { _ = try? await walletManager.refreshBalance() }
        }
        .onChange(of: searchText) { newValue in
            if newValue.isEmpty {
                loadedConversationCount = conversationPageSize
                scheduleFilteredConversationsRefresh(debounce: false)
            } else {
                scheduleFilteredConversationsRefresh(debounce: true)
            }
        }
        .onChange(of: chatService.conversations) { _ in
            // A pending chat tap whose contact didn't exist yet resolves the moment the
            // conversation (or the contact, below) is created by the catch-up sync.
            checkPendingNavigation()
            // Suppressed during a pull-to-refresh; the pull's completion handler rebuilds once.
            guard !isPullRefreshing else { return }
            scheduleFilteredConversationsRefresh(debounce: false)
            scheduleAvatarPrefetch()
        }
        .onChange(of: contactsManager.contacts) { _ in
            checkPendingNavigation()
            guard !isPullRefreshing else { return }
            scheduleFilteredConversationsRefresh(debounce: false)
        }
        // Accept / Reject / Private move chats between the list and Message Requests.
        .onChange(of: chatService.chatRequestsRevision) { _ in
            scheduleFilteredConversationsRefresh(debounce: false)
        }
        .sheet(isPresented: $showMessageRequests) {
            MessageRequestsView()
        }
        .onDisappear {
            searchFilterTask?.cancel()
            avatarPrefetchTask?.cancel()
        }
        .task {
            await contactsManager.fetchKNSDomainsForAllContacts()
            await preloadAvatarsForAllChats(forceProfileRefresh: false)
            await chatService.refreshLatestReactionPreviews()
        }
        .onChange(of: chatService.pendingChatNavigation) { newValue in
            if newValue != nil {
                checkPendingNavigation()
            }
        }
        .onChange(of: chatService.pendingProfileAddress) { newValue in
            if newValue != nil { openPendingProfile() }
        }
        .sheet(isPresented: Binding(
            get: { linkedProfileContact != nil },
            set: { if !$0 { linkedProfileContact = nil } }
        )) {
            if let contact = linkedProfileContact {
                NavigationStack {
                    ChatInfoView(
                        contact: Binding(
                            get: { linkedProfileContact ?? contact },
                            set: { linkedProfileContact = $0 }
                        )
                    )
                }
            }
        }
    }

    private func handleOpenChatNotification(_ notification: Notification) {
        guard let contactAddress = notification.userInfo?["contactAddress"] as? String else { return }
        let startInPaymentMode = notification.userInfo?["paymentMode"] as? Bool ?? false
        navigateToChat(address: contactAddress, startInPaymentMode: startInPaymentMode)
    }

    /// A profile link: that person's User Info. Someone new gets an auto-added contact, so the
    /// name and settings saved there stick. Your own link
    /// shows your own User Info from a throwaway value - you are never added as your own contact.
    private func openPendingProfile() {
        guard let address = chatService.pendingProfileAddress else { return }
        chatService.pendingProfileAddress = nil
        let contact = walletManager.currentWallet?.publicAddress.lowercased() == address.lowercased()
            ? Contact(address: address)
            : (contactsManager.getContact(byAddress: address) ?? contactsManager.getOrCreateContact(address: address))
        // A profile sheet already up (or one SwiftUI declined to present) would leave the binding
        // stuck true, and no later link could open. Close it first, then present the new one.
        if linkedProfileContact != nil {
            linkedProfileContact = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { linkedProfileContact = contact }
        } else {
            linkedProfileContact = contact
        }
    }

    private func checkPendingNavigation() {
        guard let contactAddress = chatService.pendingChatNavigation else { return }
        // Same rule as checkPendingGroupNavigation: don't consume the tap
        // until its contact actually exists locally. A notification from someone not in the address book yet (a
        // handshake, or a first message/payment whose contact the catch-up sync creates moments
        // later) is tapped on a cold start BEFORE that sync lands - consuming it here would
        // clear the target and navigate nowhere. The contacts/conversations onChange handlers
        // below re-run this the instant the contact appears.
        guard contactsManager.contacts.contains(where: { $0.address == contactAddress }) ||
                chatService.conversations.contains(where: { $0.contact.address == contactAddress }) else { return }
        chatService.pendingChatNavigation = nil
        if let open = selectedContact, open.address != contactAddress {
            // A chat is already open on top of this list, so the swap belongs to ChatDetailView's
            // own in-place handler (navigateToChat deliberately no-ops in that case). It only
            // listens for the notification, and the one this tap posted arrived before the
            // contact existed - re-post it now that it resolves.
            NotificationCenter.default.post(
                name: .openChat,
                object: nil,
                userInfo: ["contactAddress": contactAddress]
            )
            return
        }
        navigateToChat(address: contactAddress)
    }

    private func navigateToChat(address: String, startInPaymentMode: Bool = false) {
        // Find contact by address
        let contact: Contact?
        if let c = contactsManager.contacts.first(where: { $0.address == address }) {
            contact = c
        } else if let conversation = chatService.conversations.first(where: { $0.contact.address == address }) {
            contact = conversation.contact
        } else {
            contact = nil
        }
        guard let target = contact else { return }

        if shouldUseSplitLayout {
            selectedContactStartInPaymentMode = startInPaymentMode
            selectedContact = target
            return
        }

        // When a chat is already open, ChatDetailView handles the switch
        // in-place via its own .onReceive(.openChat) handler.
        if selectedContact == nil {
            selectedContactStartInPaymentMode = startInPaymentMode
            selectedContact = target
        }
    }

    /// The floating glass "+" in the bottom-right corner, opening the New sheet.
    private var newButton: some View {
        Button {
            Haptics.impact(.light)
            showCreateSheet = true
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
        .accessibilityLabel(Text("New"))
    }

    /// New Chat or New Group Chat, and then that screen at full height.
    @ViewBuilder
    private var createSheet: some View {
        Group {
            switch createStep {
            case .menu:
                createMenu
            case .chat:
                AddContactView(
                    startInGroupMode: false,
                    onAdd: { contact in
                        _ = chatService.getOrCreateConversation(for: contact)
                        selectedContactStartInPaymentMode = false
                        selectedContact = contact
                        showCreateSheet = false
                    },
                    onCancel: resetCreateSheet
                )
            case .group:
                AddContactView(
                    startInGroupMode: true,
                    onCreateGroup: { group in
                        showCreateSheet = false
                        selectedGroup = group
                    },
                    onCancel: resetCreateSheet
                )
            }
        }
        .presentationDetents([Self.createMenuHeight, .large], selection: $createDetent)
        .presentationDragIndicator(.visible)
    }

    private var createMenu: some View {
        VStack(spacing: 12) {
            Text("New")
                .font(.headline)
                .padding(.top, 20)
                .padding(.bottom, 4)
            ActionSheetRow(
                title: "New Chat",
                subtitle: "Message someone by their address or name.",
                systemImage: "bubble.left"
            ) {
                createDetent = .large
                createStep = .chat
            }
            ActionSheetRow(
                title: "New Group Chat",
                subtitle: "Start a group with the people you choose.",
                systemImage: "person.3"
            ) {
                createDetent = .large
                createStep = .group
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func resetCreateSheet() {
        createStep = .menu
        createDetent = Self.createMenuHeight
    }

    private static let createMenuHeight: PresentationDetent = .height(250)


    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.scaled(size: 60))
                .foregroundColor(.secondary)

            Text("No Conversations Yet")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Start a new chat by adding a contact")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .padding()
    }

    private var splitEmptyDetailView: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.scaled(size: 44))
                .foregroundColor(.secondary)

            Text("Select a chat")
                .font(.title3)
                .fontWeight(.semibold)

            Text("Choose a conversation on the left")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .background(Color(UIColor.systemBackground))
    }

    private var isEverythingSelected: Bool {
        let total = allEntries.count
        return total > 0 && selectedEntryIDs.count >= total
    }

    private var selectionCount: Int {
        selectedEntryIDs.count
    }

    private var selectedChats: [Conversation] {
        filteredConversationsCache.filter { selectedEntryIDs.contains(Self.entryID($0)) }
    }

    private var selectedGroups: [GroupChat] {
        groupChatService.groups.filter { selectedEntryIDs.contains(Self.entryID($0)) }
    }

    fileprivate static func entryID(_ conversation: Conversation) -> String {
        "c:\(conversation.contact.id.uuidString)"
    }

    fileprivate static func entryID(_ group: GroupChat) -> String {
        "g:\(group.id)"
    }

    /// The chats and groups matching the search, most recent message first. Pinned ones are in the
    /// circles row, not the list, except while searching.
    private var allEntries: [ChatListEntry] {
        let pinnedChats = searchText.isEmpty ? pinnedChatConversations : [:]
        let chats = pinnedChats.isEmpty
            ? filteredConversationsCache
            : filteredConversationsCache.filter { pinnedChats[Self.chatPinId($0.contact.address)] == nil }
        let groupMessages = groupChatService.groupMessages
        var dated: [(at: Date, entry: ChatListEntry)] = chats
            .map { ($0.lastMessage?.timestamp ?? Date.distantPast, ChatListEntry.chat($0)) }
        dated += displayedGroups.map { (groupMessages[$0.id]?.last?.timestamp ?? $0.createdAt, ChatListEntry.group($0)) }
        return dated.sorted { $0.at > $1.at }.map(\.entry)
    }

    // MARK: - Circles (bot chats)

    /// Every bot is always a circle in the row above the chats, with its chat when there is one. Bot chats never sit in the chat
    /// list itself.
    private var botCircles: [BotCircle] {
        KaChatBot.available.map { bot in
            let key = bot.address.lowercased()
            let conversation = chatService.conversations.first {
                $0.contact.address.lowercased() == key && !contactsManager.isAddressDeleted($0.contact.address)
            }
            return BotCircle(bot: bot, conversation: conversation)
        }
    }

    /// Opens the bot's chat, starting it the first time.
    private func openBotFromCircle(_ bot: KaChatBot) {
        guard let contact = bot.startChat() else { return }
        selectedContactStartInPaymentMode = false
        selectedContact = contact
    }

    private var circlePinsKey: String? {
        guard let address = walletManager.currentWallet?.publicAddress.lowercased() else { return nil }
        return "kachat_chat_circle_pins_\(address)"
    }

    private func loadCirclePins() {
        guard let key = circlePinsKey else { circlePins = []; return }
        circlePins = UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    /// Pin a bot to the front of the row or a chat up into it (newest pin first), or unpin it.
    private func toggleCirclePin(_ id: String) {
        if let index = circlePins.firstIndex(of: id) {
            circlePins.remove(at: index)
            showToast(AppLocalization.string("Unpinned"))
        } else {
            circlePins.insert(id, at: 0)
            showToast(AppLocalization.string(id.hasPrefix("c:") ? "Pinned to the top row" : "Pinned to the front"))
        }
        if let key = circlePinsKey { UserDefaults.standard.set(circlePins, forKey: key) }
    }

    /// A chat's id in the row's pins.
    private static func chatPinId(_ address: String) -> String { "c:\(address.lowercased())" }

    /// The chats pinned up into the row, by pin id. A deleted chat's pin finds nothing and shows
    /// nothing.
    private var pinnedChatConversations: [String: Conversation] {
        let ids = Set(circlePins.filter { $0.hasPrefix("c:") })
        guard !ids.isEmpty else { return [:] }
        var result: [String: Conversation] = [:]
        for conversation in chatService.conversations where !contactsManager.isAddressDeleted(conversation.contact.address) {
            let id = Self.chatPinId(conversation.contact.address)
            if ids.contains(id) { result[id] = conversation }
        }
        return result
    }

    /// A pinned chat's name in the row: as its list row names it.
    private func circleName(for conversation: Conversation) -> String {
        isOwnChat(conversation.contact)
            ? AppLocalization.string("Your Address")
            : contactsManager.displayName(for: conversation.contact)
    }

    private var chatsTabContent: some View {
        // Pinned chats and groups live in the circles row, not the list - except while searching,
        // when the results are the whole match, pinned or not.
        let pinnedChats = searchText.isEmpty ? pinnedChatConversations : [:]
        let pinnedGroups = pinnedGroupChats
        let entries = allEntries
        let totalCount = entries.count
        let displayed: [ChatListEntry]
        if searchText.isEmpty {
            let count = min(totalCount, max(loadedConversationCount, conversationPageSize))
            displayed = Array(entries.prefix(count))
        } else {
            displayed = entries
        }

        let showsRequestsRow = searchText.isEmpty && editMode != .active
        let requestCount = showsRequestsRow
            ? chatService.messageRequestCount + groupChatService.pendingGroupInvites.count
            : 0
        return List(selection: $selectedEntryIDs) {
            // The bot chats and the chats you pinned, as circles under the search bar - swipe
            // sideways for all of them. Tap opens, hold opens their half sheet.
            ChatCirclesStrip(
                searchText: searchText,
                pins: circlePins,
                bots: botCircles,
                pinnedChats: pinnedChats,
                pinnedGroups: pinnedGroups,
                groupUnreadCount: { groupChatService.unreadCount(for: $0) },
                onOpenGroup: { group in
                    guard groupActionTarget == nil else { return }
                    selectedGroup = group
                },
                onLongPressGroup: { groupActionTarget = $0 },
                chatName: circleName(for:),
                // The open is guarded on the hold's half sheet: the hold's touch-up still fires
                // the circle's Button (simultaneousGesture), and opened the chat behind it.
                onOpenBot: { guard circleActionTarget == nil else { return }; openBotFromCircle($0) },
                onOpenChat: { conversation in
                    guard conversationActionTarget == nil else { return }
                    selectedContactStartInPaymentMode = false
                    selectedContact = conversation.contact
                },
                onLongPress: { circleActionTarget = CircleActionTarget(id: $0) },
                // A pinned chat holds to the chat row's own half sheet (with Unpin).
                onLongPressChat: { conversationActionTarget = $0 }
            )
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            // People who wrote first and haven't been accepted - one row, always there, right
            // above the chats (NO_HANDSHAKE_MESSAGING.md).
            if showsRequestsRow {
                Button {
                    Haptics.impact(.light)
                    showMessageRequests = true
                } label: {
                    MessageRequestsRow(count: requestCount)
                }
                .buttonStyle(ChatRowPressStyle())
                .listRowBackground(Color.clear)
            }
            if !displayed.isEmpty {
                ForEach(Array(displayed.enumerated()), id: \.element.id) { index, entry in
                    Group {
                        switch entry {
                        case .chat(let conversation): chatRow(conversation)
                        case .group(let group): groupRow(group)
                        }
                    }
                    .onAppear {
                        maybeLoadMoreConversations(
                            currentIndex: index,
                            displayedCount: displayed.count,
                            totalCount: totalCount
                        )
                    }
                }

                Text("\(totalCount) chat\(pluralS(totalCount))")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .overlay(alignment: .center) {
            // Below the circles row rather than over it: only when there are no chats at all.
            if displayed.isEmpty && searchText.isEmpty && pinnedChats.isEmpty && pinnedGroups.isEmpty {
                emptyStateView
                    .padding(.top, 120)
                    .allowsHitTesting(false)
            }
        }
    }

    /// List(selection:)'s native edit-mode row-selection UI never gets a chance to see a row's tap
    /// - our own Button label already consumes it - so selection toggles here explicitly.
    private func toggleSelection(_ id: String) {
        if selectedEntryIDs.contains(id) {
            selectedEntryIDs.remove(id)
        } else {
            selectedEntryIDs.insert(id)
        }
    }

    private func chatRow(_ conversation: Conversation) -> some View {
        Button {
            if editMode == .active {
                toggleSelection(Self.entryID(conversation))
            } else {
                selectedContactStartInPaymentMode = false
                selectedContact = conversation.contact
            }
        } label: {
            ConversationRow(conversation: conversation)
        }
        .buttonStyle(ChatRowPressStyle())
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            chatSwipeLeftActions(conversation)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            chatSwipeRightActions(conversation)
        }
        .tag(Self.entryID(conversation))
        .listRowBackground(
            shouldUseSplitLayout && selectedContact?.address == conversation.contact.address
                ? Color.accentColor.opacity(0.14)
                : Color.clear
        )
    }

    private func groupRow(_ group: GroupChat) -> some View {
        Button {
            if editMode == .active {
                toggleSelection(Self.entryID(group))
            } else {
                selectedGroup = group
            }
        } label: {
            GroupChatRow(group: group)
        }
        .buttonStyle(ChatRowPressStyle())
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            groupSwipeLeftActions(group)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            groupSwipeRightActions(group)
        }
        .tag(Self.entryID(group))
        .listRowBackground(
            shouldUseSplitLayout && selectedGroup?.id == group.id
                ? Color.accentColor.opacity(0.14)
                : Color.clear
        )
    }

    // MARK: - Groups in the list

    /// The pinned groups, in pin order (newest pin first). Empty while searching: the results
    /// list them with the rest.
    private var pinnedGroupChats: [GroupChat] {
        guard searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let byId = Dictionary(groupChatService.groups.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return groupPins.compactMap { byId[$0] }
    }

    /// The unpinned groups. While searching, every group matching the group name, a member's
    /// alias or address, or message content, pinned or not.
    private var displayedGroups: [GroupChat] {
        let groupMessages = groupChatService.groupMessages
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            let pinnedIds = Set(groupPins)
            return groupChatService.groups.filter { !pinnedIds.contains($0.id) }
        }
        return groupChatService.groups.filter { group in
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

    private var groupPinsKey: String? {
        guard let address = walletManager.currentWallet?.publicAddress.lowercased() else { return nil }
        return "kachat_group_pins_\(address)"
    }

    /// The first time, the groups pinned in the old circles row (their "g:" ids in
    /// `kachat_chat_circle_pins_`) carry over, in the same order.
    private func loadGroupPins() {
        guard let key = groupPinsKey, let address = walletManager.currentWallet?.publicAddress.lowercased() else {
            groupPins = []
            return
        }
        if let saved = UserDefaults.standard.stringArray(forKey: key) {
            groupPins = saved
            return
        }
        let circlePins = UserDefaults.standard.stringArray(forKey: "kachat_chat_circle_pins_\(address)") ?? []
        groupPins = circlePins.filter { $0.hasPrefix("g:") }.map { String($0.dropFirst(2)) }
        UserDefaults.standard.set(groupPins, forKey: key)
    }

    private func toggleGroupPin(_ groupId: String) {
        if let index = groupPins.firstIndex(of: groupId) {
            groupPins.remove(at: index)
            showToast(AppLocalization.string("Unpinned"))
        } else {
            groupPins.insert(groupId, at: 0)
            showToast(AppLocalization.string("Pinned to the top row"))
        }
        if let key = groupPinsKey { UserDefaults.standard.set(groupPins, forKey: key) }
    }

    /// A pinned group's long-press half sheet: read state, pin, notifications and delete.
    private func groupActionSheet(for group: GroupChat) -> some View {
        let isSilent = groupChatService.silentNotifications(for: group.id)
        let isPinned = groupPins.contains(group.id)
        return VStack(spacing: 12) {
            Text(group.name)
                .font(.headline)
                .lineLimit(1)
                .padding(.top, 20)
                .padding(.bottom, 4)

            ActionSheetTiles {
                if groupChatService.unreadCount(for: group) > 0 {
                    ActionSheetRow(title: "Mark as Read", subtitle: "Clears the unread badge on this group.", systemImage: "envelope.open") {
                        groupActionTarget = nil
                        groupChatService.markGroupAsRead(group.id)
                    }
                } else {
                    ActionSheetRow(title: "Mark as Unread", subtitle: "Puts the unread badge back so you come across it again.", systemImage: "envelope.badge") {
                        groupActionTarget = nil
                        groupChatService.markGroupAsUnread(group.id)
                    }
                }
                ActionSheetRow(
                    title: isPinned ? "Unpin" : "Pin to Top Row",
                    subtitle: isPinned ? "Moves it back into your chats." : "Moves it into the row above your chats.",
                    systemImage: isPinned ? "pin.slash" : "pin"
                ) {
                    groupActionTarget = nil
                    toggleGroupPin(group.id)
                }
                ActionSheetRow(
                    title: isSilent ? "Unsilence" : "Silence",
                    subtitle: isSilent
                        ? "Notifications from this group resume, including mentions."
                        : "No notification from this group, mentions included.",
                    systemImage: isSilent ? "bell" : "bell.slash"
                ) {
                    groupActionTarget = nil
                    groupChatService.setSilentNotifications(!isSilent, for: group.id)
                }
                ActionSheetRow(title: "Delete", subtitle: "Removes this group and its messages from this device.", systemImage: "trash", tint: .red) {
                    groupActionTarget = nil
                    // One turn later: the alert can't present while the sheet is going down.
                    DispatchQueue.main.async { groupDeleteTarget = group }
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

    /// A group row swiped left: Delete, Silence and Pin. No full swipe, so a long swipe can't start
    /// a delete; Delete still asks first.
    @ViewBuilder
    private func groupSwipeLeftActions(_ group: GroupChat) -> some View {
        let isSilent = groupChatService.silentNotifications(for: group.id)
        let isPinned = groupPins.contains(group.id)
        Button {
            groupDeleteTarget = group
        } label: {
            Label("Delete", systemImage: "trash")
        }
        .tint(.red)
        Button {
            groupChatService.setSilentNotifications(!isSilent, for: group.id)
        } label: {
            Label(LocalizedStringKey(isSilent ? "Unsilence" : "Silence"), systemImage: isSilent ? "bell" : "bell.slash")
        }
        .tint(.orange)
        Button {
            toggleGroupPin(group.id)
        } label: {
            Label(LocalizedStringKey(isPinned ? "Unpin" : "Pin"), systemImage: isPinned ? "pin.slash" : "pin")
        }
        .tint(.accentColor)
    }

    /// A group row swiped right: Mark as Read or Mark as Unread, by its unread state.
    @ViewBuilder
    private func groupSwipeRightActions(_ group: GroupChat) -> some View {
        if groupChatService.unreadCount(for: group) > 0 {
            Button {
                groupChatService.markGroupAsRead(group.id)
            } label: {
                Label("Mark as Read", systemImage: "envelope.open")
            }
            .tint(.accentColor)
        } else {
            Button {
                groupChatService.markGroupAsUnread(group.id)
            } label: {
                Label("Mark as Unread", systemImage: "envelope.badge")
            }
            .tint(.accentColor)
        }
    }

    private func deleteGroups(_ groups: [GroupChat]) {
        guard !groups.isEmpty else { return }
        for group in groups {
            if selectedGroup?.id == group.id { selectedGroup = nil }
            groupChatService.deleteGroup(group.id)
        }
        let deleted = Set(groups.map(\.id))
        groupPins.removeAll { deleted.contains($0) }
        if let key = groupPinsKey { UserDefaults.standard.set(groupPins, forKey: key) }
        selectedEntryIDs.subtract(groups.map { Self.entryID($0) })
        showToast(groups.count == 1 ? "Group deleted." : "\(groups.count) groups deleted.")
    }

    private func handleOpenGroupNotification(_ notification: Notification) {
        // No group id is the undecryptable-push fallback (thread id "group"): this list is as
        // specific as that tap can get.
        guard let groupId = notification.userInfo?["groupId"] as? String, !groupId.isEmpty else {
            groupChatService.pendingGroupListNavigation = false
            return
        }
        navigateToGroup(groupId: groupId)
    }

    private func checkPendingGroupNavigation() {
        guard let groupId = groupChatService.pendingGroupNavigation else { return }
        // Don't consume the pending navigation until the group actually exists locally: a tap that
        // arrives before catch-up has created the group (e.g. "you were added to a group") would
        // otherwise be dropped silently. The .onChange(of: groupChatService.groups) re-runs this
        // the moment the group is inserted, so the tap resolves as soon as it lands.
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

    /// A chat row swiped left: Delete, Silence and Pin; your own chat has only Silence. No full
    /// swipe, so a long swipe can't start a delete; Delete still asks first.
    @ViewBuilder
    private func chatSwipeLeftActions(_ conversation: Conversation) -> some View {
        let contact = conversation.contact
        let isSilent = contact.notificationModeOverride == .off
        let pinId = Self.chatPinId(contact.address)
        let isPinned = circlePins.contains(pinId)
        if !isOwnChat(contact) {
            Button {
                rowDeleteContact = contact
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .tint(.red)
        }
        Button {
            setSilent(!isSilent, for: contact)
        } label: {
            Label(LocalizedStringKey(isSilent ? "Unsilence" : "Silence"), systemImage: isSilent ? "bell" : "bell.slash")
        }
        .tint(.orange)
        // your own chat is never pinned
        if !isOwnChat(contact) {
            Button {
                toggleCirclePin(pinId)
            } label: {
                Label(LocalizedStringKey(isPinned ? "Unpin" : "Pin"), systemImage: isPinned ? "pin.slash" : "pin")
            }
            .tint(.accentColor)
        }
    }

    /// A chat row swiped right: Mark as Read or Mark as Unread, by its unread state.
    @ViewBuilder
    private func chatSwipeRightActions(_ conversation: Conversation) -> some View {
        if conversation.unreadCount > 0 {
            Button {
                Task { await chatService.markConversationAsRead(conversation) }
            } label: {
                Label("Mark as Read", systemImage: "envelope.open")
            }
            .tint(.accentColor)
        } else {
            Button {
                chatService.markConversationAsUnread(conversation)
            } label: {
                Label("Mark as Unread", systemImage: "envelope.badge")
            }
            .tint(.accentColor)
        }
    }

    /// Mark read, mark unread and delete, for every selected chat.
    private var selectionActionBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                Button {
                    let chats = selectedChats
                    if !chats.isEmpty { Task { await chatService.markConversationsAsRead(chats) } }
                    groupChatService.markGroupsAsRead(selectedGroups)
                    editMode = .inactive
                } label: {
                    Image(systemName: "envelope.open")
                        .frame(maxWidth: .infinity)
                }
                .disabled(selectionCount == 0)

                Button {
                    let chats = selectedChats
                    if !chats.isEmpty { chatService.markConversationsAsUnread(chats) }
                    groupChatService.markGroupsAsUnread(selectedGroups)
                    editMode = .inactive
                } label: {
                    Image(systemName: "envelope.badge")
                        .frame(maxWidth: .infinity)
                }
                .disabled(selectionCount == 0)

                Button(role: .destructive) {
                    showBulkDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity)
                }
                .disabled(selectionCount == 0)
            }
            .font(.scaled(size: 18))
            .buttonStyle(.bordered)
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
        .background(.bar)
    }

    private var balanceToolbarView: some View {
        let sompi = walletManager.currentWallet?.balanceSompi
        let exact = sompi.map(formatKaspaExact) ?? "--"
        // Kaspa logo + bold.
        return HStack(spacing: 6) {
            Image("KaspaLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 15, height: 15)
            Text(verbatim: "\(exact) \(KaspaUnit.symbol)")
                .font(.footnote.weight(.semibold))
                .monospacedDigit()
                .foregroundColor(.secondary)
        }
        .onTapGesture {
            guard sompi != nil else { return }
            UIPasteboard.general.string = exact
            Haptics.success()
            showToast("Balance copied to clipboard.")
        }
    }

    private func formatKaspaExact(_ sompi: UInt64) -> String {
        let kas = Double(sompi) / 100_000_000.0
        return String(format: "%.8f", kas)
    }


    private func showToast(_ message: String, style: ToastStyle = .success) {
        let token = UUID()
        toastToken = token
        toastStyle = style
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

    private func scheduleFilteredConversationsRefresh(debounce: Bool) {
        searchFilterTask?.cancel()
        if debounce {
            searchFilterTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 180_000_000)
                guard !Task.isCancelled else { return }
                refreshFilteredConversations()
            }
        } else {
            refreshFilteredConversations()
        }
    }

    private func openPendingMessageRequests() {
        guard groupChatService.pendingMessageRequestsOpen else { return }
        groupChatService.pendingMessageRequestsOpen = false
        showMessageRequests = true
    }

    private func scheduleAvatarPrefetch() {
        avatarPrefetchTask?.cancel()
        avatarPrefetchTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard !Task.isCancelled else { return }
            await preloadAvatarsForAllChats(forceProfileRefresh: false)
        }
    }

    @MainActor
    private func preloadAvatarsForAllChats(forceProfileRefresh: Bool) async {
        let addresses = Array(Set(chatService.conversations.map { $0.contact.address }))
        guard !addresses.isEmpty else { return }

        let kns = KNSService.shared
        let addressesToFetch: [String]
        if forceProfileRefresh {
            addressesToFetch = addresses
        } else {
            addressesToFetch = addresses.filter { kns.profileCache[$0] == nil }
        }

        if !addressesToFetch.isEmpty {
            await fetchProfilesInBatches(for: addressesToFetch)
        }

        let avatarURLs = addresses.compactMap { address in
            kns.profileCache[address]?.avatarURL
        }
        await KNSProfileImagePrefetcher.preload(rawURLStrings: avatarURLs, maxConcurrent: 6)
    }

    @MainActor
    private func fetchProfilesInBatches(for addresses: [String]) async {
        guard !addresses.isEmpty else { return }
        // Concurrent batch refresh (KNSService's own bounded-concurrency path) instead of awaiting
        // each contact serially - the serial loop meant N sequential network round-trips, each one
        // triggering a KNSService @Published write that re-rendered every visible chat row.
        await KNSService.shared.refreshProfilesIfNeeded(for: addresses, network: AppSettings.load().networkType)
    }

    private func refreshFilteredConversations() {
        let settings = settingsViewModel.settings
        // Bot chats are reached from their circles above the list, never the chat list.
        let sourceConversations = chatService.conversations.filter { !KaChatBot.isBot($0.contact.address) }

        if searchText.isEmpty {
            filteredConversationsCache = sourceConversations
                .filter { conversation in
                    chatService.isConversationVisibleInChatList(conversation, settings: settings)
                }
                .map { (key: $0.lastMessage?.timestamp ?? Date.distantPast, value: $0) }
                .sorted { $0.key > $1.key }
                .map(\.value)
                        return
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            filteredConversationsCache = sourceConversations
                .filter { conversation in
                    chatService.isConversationVisibleInChatList(conversation, settings: settings)
                }
                .map { (key: $0.lastMessage?.timestamp ?? Date.distantPast, value: $0) }
                .sorted { $0.key > $1.key }
                .map(\.value)
                        return
        }

        filteredConversationsCache = sourceConversations.filter { conv in
            guard chatService.isConversationVisibleInChatList(conv, settings: settings) else { return false }
            if contactsManager.displayName(for: conv.contact).range(of: query, options: .caseInsensitive) != nil {
                return true
            }
            if conv.contact.address.range(of: query, options: .caseInsensitive) != nil {
                return true
            }
            return conv.messages.contains { message in
                // Same media-envelope guard as the group search above. Cross-device placeholders
                // are hidden from every surface, so a query matching their fixed text must not
                // surface the conversation either.
                !message.isHiddenPlaceholder &&
                    message.content.utf8.count <= 4096 &&
                    message.content.range(of: query, options: .caseInsensitive) != nil
            }
        }
    }

    private func isOwnChat(_ contact: Contact) -> Bool {
        guard let mine = walletManager.currentWallet?.publicAddress.lowercased() else { return false }
        return contact.address.lowercased() == mine
    }

    /// Pulled out of the `.alert(...)` call site as a plain computed property - an inline ternary
    /// nested inside string interpolation there was making the compiler unable to type-check the
    /// `.alert` expression in reasonable time.
    private var bulkDeleteAlertTitle: String {
        let chats = selectedEntryIDs.count
        return "Delete \(chats) Chat\(chats == 1 ? "" : "s")?"
    }

    private var bulkDeleteAlertMessage: String {
        AppLocalization.string("This permanently deletes every message in each selected chat from this device. This cannot be undone.")
    }

    /// Long-press half sheet for a pinned 1:1 chat's circle. Read/Unread show contextually (the
    /// relevant one only, matching Mail) and reuse the exact same service calls as the Select-mode
    /// bulk bar; Delete routes through its own confirmation alert, which then reuses
    /// `deleteConversations`. Empty while Select mode is active - the bulk bar owns actions there.
    private func conversationRowSheet(for conversation: Conversation) -> some View {
        let isSilent = conversation.contact.notificationModeOverride == .off
        let pinId = Self.chatPinId(conversation.contact.address)
        let isPinned = circlePins.contains(pinId)
        let isOwn = isOwnChat(conversation.contact)
        return VStack(spacing: 12) {
            Text(contactsManager.displayName(for: conversation.contact))
                .font(.headline)
                .lineLimit(1)
                .padding(.top, 20)
                .padding(.bottom, 4)

            ActionSheetTiles {
                if conversation.unreadCount > 0 {
                    ActionSheetRow(
                        title: "Mark as Read",
                        subtitle: "Clears the unread badge on this chat.",
                        systemImage: "envelope.open"
                    ) {
                        conversationActionTarget = nil
                        Task { await chatService.markConversationAsRead(conversation) }
                    }
                } else {
                    ActionSheetRow(
                        title: "Mark as Unread",
                        subtitle: "Puts the unread badge back so you come across it again.",
                        systemImage: "envelope.badge"
                    ) {
                        conversationActionTarget = nil
                        chatService.markConversationAsUnread(conversation)
                    }
                }

                // Up into the circles row above the list, out of the list itself.
                ActionSheetRow(
                    title: isPinned ? "Unpin" : "Pin to Top Row",
                    subtitle: isPinned
                        ? "Moves it back into your chats list."
                        : "Moves it into the row above your chats.",
                    systemImage: isPinned ? "pin.slash" : "pin"
                ) {
                    conversationActionTarget = nil
                    toggleCirclePin(pinId)
                }

                ActionSheetRow(
                    title: isSilent ? "Unsilence" : "Silence",
                    subtitle: isSilent
                        ? "Notifications from this chat resume."
                        : "No notification from this chat, whatever your app-wide setting says.",
                    systemImage: isSilent ? "bell" : "bell.slash"
                ) {
                    conversationActionTarget = nil
                    setSilent(!isSilent, for: conversation.contact)
                }

                // Save this person's address (or edit their saved entry) without leaving the list.
                if !isOwnChat(conversation.contact) {
                    let saved = addressBook.entry(for: conversation.contact.address) != nil
                    ActionSheetRow(
                        title: saved ? "Contacts" : "Add to Contacts",
                        subtitle: saved
                            ? "Edit or remove this saved address."
                            : "Save this address with a name you'll recognize.",
                        systemImage: saved ? "person.text.rectangle.fill" : "person.text.rectangle"
                    ) {
                        conversationActionTarget = nil
                        // One turn later, like Delete: a sheet cannot present while this one leaves.
                        DispatchQueue.main.async { addressBookTarget = conversation.contact }
                    }
                }

                // Your chat with yourself cannot be deleted - it is always there.
                if !isOwnChat(conversation.contact) {
                    ActionSheetRow(
                        title: "Delete",
                        subtitle: "Removes this chat and its messages from this device.",
                        systemImage: "trash",
                        tint: .red
                    ) {
                        conversationActionTarget = nil
                        // One turn later: the confirmation alert cannot present while the sheet is
                        // still on its way out.
                        DispatchQueue.main.async { rowDeleteContact = conversation.contact }
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .presentationDetents([.height(ActionSheetTileMetrics.sheetHeight(tiles: isOwn ? 3 : 5))])
        .presentationDragIndicator(.visible)
    }

    /// A bot circle's long-press half sheet - the chat row's options: read state, pin to the
    /// front, notifications and delete.
    @ViewBuilder
    private func circleActionSheet(for id: String) -> some View {
        let isPinned = circlePins.contains(id)
        VStack(spacing: 12) {
            if id.hasPrefix("b:"),
               let bot = KaChatBot.all.first(where: { "b:\($0.address.lowercased())" == id }) {
                let conversation = chatService.conversations.first { "b:\($0.contact.address.lowercased())" == id }
                let contact = contactsManager.getContact(byAddress: bot.address) ?? conversation?.contact
                let isSilent = contact?.notificationModeOverride == .off
                Text(verbatim: bot.name)
                    .font(.headline)
                    .lineLimit(1)
                    .padding(.top, 20)
                    .padding(.bottom, 4)

                ActionSheetTiles {
                    // Read state, silence and delete need the chat; a bot never written to has
                    // only its pin.
                    if let conversation, conversation.unreadCount > 0 {
                        ActionSheetRow(title: "Mark as Read", subtitle: "Clears the unread badge on this chat.", systemImage: "envelope.open") {
                            circleActionTarget = nil
                            Task { await chatService.markConversationAsRead(conversation) }
                        }
                    } else if let conversation {
                        ActionSheetRow(title: "Mark as Unread", subtitle: "Puts the unread badge back so you come across it again.", systemImage: "envelope.badge") {
                            circleActionTarget = nil
                            chatService.markConversationAsUnread(conversation)
                        }
                    }
                    circlePinRow(id: id, isPinned: isPinned)
                    if let contact, conversation != nil {
                        ActionSheetRow(
                            title: isSilent ? "Unsilence" : "Silence",
                            subtitle: isSilent ? "Notifications from this bot resume." : "No notification from this bot.",
                            systemImage: isSilent ? "bell" : "bell.slash"
                        ) {
                            circleActionTarget = nil
                            setSilent(!isSilent, for: contact)
                        }
                        ActionSheetRow(title: "Delete", subtitle: "Deletes this chat's messages from this device. The bot stays in the row.", systemImage: "trash", tint: .red) {
                            circleActionTarget = nil
                            // One turn later: the alert can't present while the sheet is going down.
                            DispatchQueue.main.async { rowDeleteContact = contact }
                        }
                    }
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

    private func circlePinRow(id: String, isPinned: Bool) -> some View {
        ActionSheetRow(
            title: isPinned ? "Unpin" : "Pin to Front",
            subtitle: isPinned ? "Goes back to its place by latest activity." : "Keeps it first in the row above your chats.",
            systemImage: isPinned ? "pin.slash" : "pin"
        ) {
            circleActionTarget = nil
            toggleCirclePin(id)
        }
    }

    /// Silencing a 1:1 chat is the existing per-contact notification override set to `.off` -
    /// the one the notification path and the push registration already consult - not a second,
    /// parallel mute flag that only some of them would honour.
    private func setSilent(_ silent: Bool, for contact: Contact) {
        var updated = contact
        updated.notificationModeOverride = silent ? .off : nil
        contactsManager.updateContact(updated)
    }

    /// Shared delete path for both Select-mode bulk deletes and single-row deletes (a row's swipe,
    /// a pinned chat's half sheet) - per-contact cleanup with one resubscribe and toast at the end.
    private func deleteConversations(_ contacts: [Contact]) {
        // Your own chat is never deleted, even when it was part of a Select All.
        let contacts = contacts.filter { !isOwnChat($0) }
        guard !contacts.isEmpty else {
            return
        }
        for contact in contacts {
            chatService.removeConversation(for: contact.address)
            contactsManager.deleteContact(contact)
        }
        // A deleted chat leaves the row too.
        let deletedPins = Set(contacts.map { Self.chatPinId($0.address) })
        if circlePins.contains(where: deletedPins.contains) {
            circlePins.removeAll { deletedPins.contains($0) }
            if let key = circlePinsKey { UserDefaults.standard.set(circlePins, forKey: key) }
        }
        chatService.checkAndResubscribeIfNeeded()
        showToast(contacts.count == 1 ? "Chat deleted." : "\(contacts.count) chats deleted.")
    }

    private func maybeLoadMoreConversations(currentIndex: Int, displayedCount: Int, totalCount: Int) {
        guard searchText.isEmpty else { return }
        guard !isPaginatingConversations else { return }
        guard loadedConversationCount < totalCount else { return }

        let triggerIndex = max(0, displayedCount - conversationPrefetchThreshold)
        guard currentIndex >= triggerIndex else { return }

        isPaginatingConversations = true
        DispatchQueue.main.async {
            loadedConversationCount = min(totalCount, loadedConversationCount + conversationPageSize)
            isPaginatingConversations = false
        }
    }

    /// Request notification permission if not yet requested
    private func requestNotificationPermissionIfNeeded() {
        // Skip if already requested
        guard !settingsViewModel.settings.notificationPermissionRequested else { return }

        // Mark as requested (will save even if user doesn't respond)
        settingsViewModel.settings.notificationPermissionRequested = true
        settingsViewModel.saveSettings()

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            DispatchQueue.main.async {
                if !granted {
                    // User denied - disable notifications in settings
                    settingsViewModel.settings.notificationsEnabled = false
                    settingsViewModel.saveSettings()
                    AppLog.log("[ChatListView] Notification permission denied by user")
                } else {
                    AppLog.log("[ChatListView] Notification permission granted")
                }
            }
        }
    }
}

/// `.navigationDestination(item:)` (iOS 17+) rather than `isPresented:` + a synthetic get/set
/// boolean: popping back via the native swipe
/// gesture toggles the synthetic boolean through a quick true→false transition that can race
/// UIKit's own pop animation, which is what produced the black screen flashing in from the right
/// when swiping back out of a chat quickly. Binding directly to the optional `Contact` item is
/// the race-free API SwiftUI provides for this; iOS 16 falls back to the older pattern since
/// `item:` isn't available there.
private struct ChatDetailNavigationDestination: ViewModifier {
    @Binding var selectedContact: Contact?
    let startInPaymentMode: Bool

    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.navigationDestination(item: $selectedContact) { contact in
                ChatDetailView(contact: contact, startInPaymentMode: startInPaymentMode)
            }
        } else {
            content.navigationDestination(isPresented: Binding(
                get: { selectedContact != nil },
                set: { isPresented in
                    if !isPresented {
                        selectedContact = nil
                    }
                }
            )) {
                if let contact = selectedContact {
                    ChatDetailView(contact: contact, startInPaymentMode: startInPaymentMode)
                } else {
                    EmptyView()
                }
            }
        }
    }
}

struct ConversationRow: View {
    let conversation: Conversation
    @EnvironmentObject var chatService: ChatService
    @EnvironmentObject var walletManager: WalletManager
    @ObservedObject private var knsService = KNSService.shared
    @ObservedObject private var kachatRegistry = KachatNamesRegistry.shared
    /// A name saved in the Address Book names the row, and the row redraws when it changes.
    @ObservedObject private var addressBook = AddressBookManager.shared
    private static let previewCache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 2048
        return cache
    }()

    private var avatarURLString: String? {
        knsService.profileCache[conversation.contact.address]?.avatarURL
    }

    /// `ContactsManager.displayName` - the name you gave the chat, else its Address Book name,
    /// else who it is on chain, else the short address - read through the observed services so
    /// the row redraws when any of them changes. The contact is the live one, not this
    /// conversation's copy of it: a rename in User Info shows at once.
    private var rowDisplayName: String {
        let contact = ContactsManager.shared.getContact(byAddress: conversation.contact.address) ?? conversation.contact
        // The chat with yourself is named for what it is; who you are on chain is the chat
        // HEADER's job (the .kachat domain, else the address - ContactsManager.displayName).
        if contact.address.lowercased() == walletManager.currentWallet?.publicAddress.lowercased() {
            return AppLocalization.string("Your Address")
        }
        if let assigned = contact.assignedName { return assigned }
        if let saved = addressBook.entry(for: contact.address)?.customName { return saved }
        // On testnet: the .kachat name (read through the observed registry, so the row redraws
        // when it lands); KNS isn't consulted there.
        if KachatNamesService.isEnabled {
            if let label = kachatRegistry.cachedIdentity(for: conversation.contact.address)?.label { return "\(label).kachat" }
            return Contact.generateDefaultAlias(from: conversation.contact.address)
        }
        if let domain = knsService.profileCache[conversation.contact.address]?.domainName, !domain.isEmpty {
            return domain
        }
        return Contact.generateDefaultAlias(from: conversation.contact.address)
    }

    var body: some View {
        let lastMessage = conversation.lastMessage

        HStack(spacing: 12) {
            // Avatar
            KNSAvatarView(
                avatarURLString: avatarURLString,
                fallbackText: rowDisplayName,
                size: 50,
                contactAddress: conversation.contact.address
            )

            // Content
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            Text(rowDisplayName)
                                .font(.headline)
                                .lineLimit(1)
                            // Silenced: no banner from this conversation, ever. Worth a mark on
                            // the row - a chat that never pings otherwise looks like a chat
                            // nobody is using.
                            if conversation.contact.notificationModeOverride == .off {
                                Image(systemName: "bell.slash.fill")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .accessibilityLabel("Silenced")
                            }
                        }
                    }

                    Spacer()

                    if let state = chatService.chatFetchStates[conversation.contact.address] {
                        switch state {
                        case .loading:
                            ProgressView()
                                .controlSize(.mini)
                                .tint(.secondary)
                        case .failed:
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundColor(.orange)
                        }
                    }

                    if let lastMessage {
                        Text(formatDate(lastMessage.timestamp))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                HStack {
                    if let lastMessage {
                        if lastMessage.isOutgoing || lastMessage.deliveryStatus == .warning {
                            let status: DeliveryStatusLabel.Status = {
                                switch lastMessage.deliveryStatus {
                                case .sent: return .sent
                                case .pending: return .pending
                                case .failed: return .failed
                                case .warning: return .warning
                                }
                            }()
                            DeliveryStatusLabel(status: status, compact: true)
                        }

                        Text(reactionPreviewText ?? formatPreview(lastMessage.content))
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    } else {
                        Text("No messages yet")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .italic()
                    }

                    Spacer()

                    if conversation.unreadCount > 0 {
                        Text("\(conversation.unreadCount)")
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
        .contentShape(Rectangle()) // Make entire row tappable
        .task(id: conversation.contact.address) {
            let address = conversation.contact.address
            if knsService.profileCache[address] == nil {
                _ = await knsService.fetchProfile(for: address)
            }
        }
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

    /// A reaction more recent than `lastMessage` gets shown instead of the message preview -
    /// reactions never become messages (they're applied as a corner pill), so without this the
    /// chat list would just silently show whatever the last real message was, even if the truly
    /// most recent activity was someone reacting to something older. `nil` when there's no
    /// reaction newer than the last message.
    private var reactionPreviewText: String? {
        guard let preview = chatService.latestReactionByContact[conversation.contact.address] else { return nil }
        let reactionDate = Date(timeIntervalSince1970: TimeInterval(preview.blockTime) / 1000.0)
        if let lastMessage = conversation.lastMessage, lastMessage.timestamp >= reactionDate {
            return nil
        }
        let myAddress = walletManager.currentWallet?.publicAddress
        let reactedByMe = preview.reactorAddress == myAddress
        let targetIsMine = preview.targetMessageIsOutgoing ?? false
        switch (reactedByMe, targetIsMine) {
        case (true, true): return "You reacted to your message"
        case (true, false): return "You reacted to their message"
        case (false, true): return "Reacted to your message"
        case (false, false): return "Reacted to their message"
        }
    }

    private func formatPreview(_ content: String) -> String {
        // Cross-device placeholders never surface anywhere (see ChatMessage.isSentPlaceholder).
        // Conversation.lastMessage already skips them; this is a defensive backstop in case a
        // placeholder's content reaches the preview through any other route.
        if ChatMessage.isHiddenPlaceholder(content) { return "" }
        // `content.utf8.count` (not `.count`, which does a full Unicode grapheme-cluster scan)
        // - a chat's last message can be a multi-MB base64 photo/audio payload, and this cache
        // key has to be computed before the cache can even be checked. With `.count` (and the
        // `.hashValue` this used to also include, an equally expensive full-string hash), every
        // row in the chat list paid two full scans of its entire last-message content on every
        // single render - including the render triggered by returning from a chat, which made
        // that transition visibly freeze for chats with large last messages.
        let key = "\(content.utf8.count)|\(content.prefix(24))" as NSString
        if let cached = Self.previewCache.object(forKey: key) {
            return cached as String
        }

        let result: String
        // Unwrap a reply envelope first, so a reply's own text (or its attachment, below) is
        // what's previewed rather than the raw `{"type":"reply",...}` JSON.
        let unwrapped = MessageReplyCodec.unwrappedText(content)

        // A message that is nothing but a link back into KaChat previews as what it OPENS
        // rather than as a raw `kachat://…` URL - matching the rich card the bubble itself
        // renders for it (see `KaChatInternalLinkCardView`).
        if let internalLink = KaChatInternalLink.match(in: unwrapped), internalLink.coversWholeMessage {
            switch internalLink.link {
            case .profile:
                result = "Shared a KaChat profile"
            case .paymentRequest(let request):
                result = KaspaUnit.label(String(format: AppLocalization.string("Payment request: %@ KAS"), request.amountText))
            }
            Self.previewCache.setObject(result as NSString, forKey: key)
            return result
        }

        // Check if content is a file JSON payload
        let trimmed = unwrapped.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}") else {
            result = LinkSafePreview.apply(to: unwrapped)
            Self.previewCache.setObject(result as NSString, forKey: key)
            return result
        }

        if let chessEnvelope = ChessCodec.parseAny(unwrapped) {
            if case .invite(let invite) = chessEnvelope, let minutes = invite.tcMinutes {
                result = "♟️ Chess game - \(minutes) | \(invite.tcIncSeconds ?? 0)"
            } else {
                result = "♟️ Chess game"
            }
            Self.previewCache.setObject(result as NSString, forKey: key)
            return result
        }

        if let callEnvelope = CallCodec.parseAny(unwrapped) {
            switch callEnvelope {
            case .request(let request): result = request.video ? "📹 Video call" : "📞 Voice call"
            case .invite(let invite): result = invite.video ? "📹 Video call" : "📞 Voice call"
            case .response(let response):
                result = response.reason == "no_host" ? "📞 Calls need Nextcloud Talk" : (response.accepted ? "📞 Call answered" : "📞 Call declined")
            case .end(let end):
                if let seconds = end.durationSeconds, seconds > 0 {
                    result = String(format: "📞 Call · %d:%02d", seconds / 60, seconds % 60)
                } else {
                    switch end.reason {
                    case "no_answer", "cancelled": result = "📞 Missed call"
                    case "declined": result = "📞 Call declined"
                    default: result = "📞 Call ended"
                    }
                }
            }
            Self.previewCache.setObject(result as NSString, forKey: key)
            return result
        }

        guard let data = unwrapped.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["type"] as? String == "file",
              let mimeType = json["mimeType"] as? String else {
            result = LinkSafePreview.apply(to: unwrapped)
            Self.previewCache.setObject(result as NSString, forKey: key)
            return result
        }

        let mime = mimeType.lowercased()
        if mime.hasPrefix("image/") {
            result = "Photo"
        } else if mime.hasPrefix("audio/") {
            result = "Voice message"
        } else if mime.hasPrefix("video/") {
            result = "Video"
        } else {
            result = "File"
        }
        Self.previewCache.setObject(result as NSString, forKey: key)
        return result
    }
}

/// The preview a link-bearing message gets in the chat and group lists: never the link itself.
///
/// A raw URL in a list row is noise at best, and for Nextcloud media it was worse - the message
/// IS a public share link, so the row showed the address of someone's photo to anyone glancing
/// at the phone. Any message carrying an http(s) link previews as an attachment instead,
/// whatever else it says. Only web links count: a message that is a `kaspa:` address must keep
/// reading as one, and the detector would otherwise take that for a URL too.
enum LinkSafePreview {
    static let sentALink = "📎 Sent a link"

    /// Keyed the same way `formatPreview`'s cache is - the group row has no cache of its own and
    /// renders its preview on every pass, and a detector scan per pass is exactly the kind of
    /// per-row cost the chat list has been shedding.
    private static let cache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 512
        return cache
    }()

    static func apply(to text: String) -> String {
        let key = "\(text.utf8.count)|\(text.prefix(24))" as NSString
        if let cached = cache.object(forKey: key) { return cached as String }
        let result = containsWebLink(text) ? sentALink : text
        cache.setObject(result as NSString, forKey: key)
        return result
    }

    private static func containsWebLink(_ text: String) -> Bool {
        guard let detector = SharedDetectors.link else { return false }
        let range = NSRange(text.startIndex..., in: text)
        var found = false
        detector.enumerateMatches(in: text, options: [], range: range) { match, _, stop in
            guard let scheme = match?.url?.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
            found = true
            stop.pointee = true
        }
        return found
    }
}

/// The pressed look of a chat or group row (Chats, Group Chats).
struct ChatRowPressStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        let overlayColor = colorScheme == .dark
            ? Color.white.opacity(0.22)
            : Color.black.opacity(0.10)

        return configuration.label
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                Rectangle()
                    .fill(configuration.isPressed ? overlayColor : .clear)
            )
            .opacity(configuration.isPressed ? 0.96 : 1.0)
            .animation(.linear(duration: 0.06), value: configuration.isPressed)
    }
}

#Preview {
    ChatListView()
        .environmentObject(ChatService.shared)
        .environmentObject(ContactsManager.shared)
        .environmentObject(WalletManager.shared)
}

/// The red unread count - on the circles above the chat list.
struct ChatsTabUnreadBadge: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Text(count > 99 ? "99+" : "\(count)")
                .font(.caption2.weight(.bold))
                .foregroundColor(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.red))
        }
    }
}

/// One bot in the circles row, with its chat when there is one.
struct BotCircle {
    let bot: KaChatBot
    let conversation: Conversation?

    /// "b:<address>", its id in the row's pins.
    var id: String { "b:\(bot.address.lowercased())" }
}

/// One circle in the row: a bot, or a chat pinned up out of the list.
private enum ChatCircleItem {
    case bot(BotCircle)
    case chat(id: String, conversation: Conversation)

    var id: String {
        switch self {
        case .bot(let bot): return bot.id
        case .chat(let id, _): return id
        }
    }
}

/// The row of circles above the chats list, under the search bar: the bot chats and the chats
/// you pinned there (Pin to Top Row on a chat's half sheet). Swipe sideways for all of them.
/// Pinned ones come first, in pin order, then the other bots by latest activity. A red count
/// shows unread messages. Tap opens; hold opens the half sheet (a bot's: read state, pin,
/// notifications, delete; a pinned chat's: its chat row's, with Unpin). Group chats have their
/// own rows in this list.
private struct ChatCirclesStrip: View {
    @Environment(\.editMode) private var editMode
    @ObservedObject private var knsService = KNSService.shared
    let searchText: String
    let pins: [String]
    /// Every bot, with its chat when there is one (`ChatListView.botCircles`).
    let bots: [BotCircle]
    /// The chats pinned into the row, by pin id ("c:<address>"). Empty while searching: the
    /// search results list them instead.
    let pinnedChats: [String: Conversation]
    /// The groups pinned into the row. Empty while searching, like the chats.
    let pinnedGroups: [GroupChat]
    let groupUnreadCount: (GroupChat) -> Int
    let onOpenGroup: (GroupChat) -> Void
    /// Hold a pinned group: its half sheet.
    let onLongPressGroup: (GroupChat) -> Void
    let chatName: (Conversation) -> String
    let onOpenBot: (KaChatBot) -> Void
    let onOpenChat: (Conversation) -> Void
    /// Hold a bot: its half sheet (read state, pin, notifications, delete), like a chat row's.
    let onLongPress: (String) -> Void
    /// Hold a pinned chat: its chat row's half sheet.
    let onLongPressChat: (Conversation) -> Void

    private var isSelecting: Bool { editMode?.wrappedValue == .active }

    private var items: [ChatCircleItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        func matches(_ bot: BotCircle) -> Bool {
            query.isEmpty || bot.bot.name.range(of: query, options: .caseInsensitive) != nil
        }
        let botsById = Dictionary(bots.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var pinned: [ChatCircleItem] = []
        for id in pins {
            if let bot = botsById[id] {
                if matches(bot) { pinned.append(.bot(bot)) }
            } else if let conversation = pinnedChats[id] {
                pinned.append(.chat(id: id, conversation: conversation))
            }
        }
        let pinnedIds = Set(pins)
        let rest = bots
            .filter { !pinnedIds.contains($0.id) && matches($0) }
            .map { (item: $0, at: $0.conversation?.lastMessage?.timestamp ?? Date.distantPast) }
            .sorted { $0.at > $1.at }
            .map { ChatCircleItem.bot($0.item) }
        return pinned + rest
    }

    var body: some View {
        let items = items
        if items.isEmpty && pinnedGroups.isEmpty {
            Color.clear.frame(height: 1)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                // A plain HStack: it measures every circle, so the row is as tall as its tallest.
                HStack(alignment: .top, spacing: 14) {
                    ForEach(pinnedGroups) { group in
                        PinnedCircleButton(
                            name: group.name,
                            unreadCount: groupUnreadCount(group),
                            showsPin: true,
                            isSelecting: isSelecting,
                            onTap: { onOpenGroup(group) },
                            onLongPress: { onLongPressGroup(group) }
                        ) {
                            GroupAvatar(group: group, size: 60)
                        }
                    }
                    ForEach(items, id: \.id) { item in
                        circle(item)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
    }

    @ViewBuilder
    private func circle(_ item: ChatCircleItem) -> some View {
        switch item {
        case .bot(let bot):
            PinnedCircleButton(
                name: bot.bot.name,
                unreadCount: bot.conversation?.unreadCount ?? 0,
                showsPin: pins.contains(bot.id),
                isSelecting: isSelecting,
                // A bot chat is deleted from its own half sheet, not in Select mode.
                onTap: { onOpenBot(bot.bot) },
                onLongPress: { onLongPress(bot.id) }
            ) {
                Circle()
                    .fill(Color.accentColor.opacity(0.2))
                    .overlay(
                        Image(systemName: bot.bot.systemImage)
                            .font(.scaled(size: 22, weight: .semibold))
                            .foregroundColor(.accentColor)
                    )
            }
        case .chat(_, let conversation):
            let name = chatName(conversation)
            PinnedCircleButton(
                name: name,
                unreadCount: conversation.unreadCount,
                showsPin: true,
                isSelecting: isSelecting,
                onTap: { onOpenChat(conversation) },
                onLongPress: { onLongPressChat(conversation) }
            ) {
                KNSAvatarView(
                    avatarURLString: knsService.profileCache[conversation.contact.address]?.avatarURL,
                    fallbackText: name,
                    size: 60,
                    contactAddress: conversation.contact.address
                )
            }
        }
    }
}

/// One circle in the row above the chat list: the avatar, the whole name
/// under it, a red unread count and, when pinned, a pin. Tap opens; hold opens its half sheet.
/// Dimmed and inert while the list is in Select mode.
struct PinnedCircleButton<Avatar: View>: View {
    let name: String
    let unreadCount: Int
    let showsPin: Bool
    let isSelecting: Bool
    let onTap: () -> Void
    let onLongPress: () -> Void
    @ViewBuilder let avatar: () -> Avatar

    var body: some View {
        Button {
            guard !isSelecting else { return }
            onTap()
        } label: {
            VStack(spacing: 6) {
                avatar()
                    .frame(width: 60, height: 60)
                    .clipShape(Circle())
                    .opacity(isSelecting ? 0.55 : 1)
                    .overlay(alignment: .topTrailing) {
                        if !isSelecting && unreadCount > 0 {
                            ChatsTabUnreadBadge(count: unreadCount)
                                .offset(x: 6, y: -4)
                        }
                    }
                    .overlay(alignment: .bottomLeading) {
                        if showsPin && !isSelecting {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.white)
                                .padding(4)
                                .background(Circle().fill(Color.accentColor))
                                .offset(x: -2, y: 2)
                        }
                    }
                // The whole name: a long one carries on underneath (up to three lines) rather than
                // being cut off. Every name reserves the three lines, so the row has one known
                // height: sized from the names, the lazy row inside the list measured too short
                // and the chat list cut the second and third lines off.
                Text(verbatim: name)
                    .font(.caption2)
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3, reservesSpace: true)
                    .frame(width: 68, alignment: .top)
            }
        }
        .buttonStyle(.plain)
        // A Button label needs simultaneousGesture (see the chat rows).
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.4).onEnded { _ in
                guard !isSelecting else { return }
                Haptics.impact(.medium)
                onLongPress()
            }
        )
        .accessibilityLabel(Text(verbatim: name))
        .accessibilityHint(Text("Hold for options"))
    }
}

// MARK: - Message Requests

/// A group you were added to, in Message Requests.
private struct GroupInviteRow: View {
    let invite: PendingGroupInvite

    var body: some View {
        HStack(spacing: 12) {
            GroupInviteAvatar(size: 50)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: invite.name)
                    .font(.headline)
                    .lineLimit(1)
                Text("Invited by \(ContactsManager.shared.displayName(for: invite.adminAddress))")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct GroupInviteAvatar: View {
    let size: CGFloat

    var body: some View {
        Image(systemName: "person.3.fill")
            .font(.scaled(size: size * 0.36, weight: .semibold))
            .foregroundColor(.accentColor)
            .frame(width: size, height: size)
            .background(Circle().fill(Color.accentColor.opacity(0.2)))
    }
}

/// What you'd be joining, with Accept and Reject. Nothing of the group exists on this device
/// beyond the invite: its messages only come in after Accept.
private struct GroupInviteRequestView: View {
    let invite: PendingGroupInvite

    @EnvironmentObject private var groupChatService: GroupChatService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                VStack(spacing: 10) {
                    GroupInviteAvatar(size: 76)
                    Text(verbatim: invite.name)
                        .font(.title3.weight(.semibold))
                        .multilineTextAlignment(.center)
                    Text("Invited by \(ContactsManager.shared.displayName(for: invite.adminAddress))")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Text("You're not in this group unless you accept. Your answer goes out as a small encrypted transaction, so the group and your other devices know.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .listRowBackground(Color.clear)
            }
            Section("Members") {
                ForEach(invite.members, id: \.self) { address in
                    HStack(spacing: 10) {
                        KNSAvatarView(avatarURLString: nil, fallbackText: "", size: 32, contactAddress: address)
                        Text(verbatim: ContactsManager.shared.displayName(for: address))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Group Invite")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 12) {
                Button(role: .destructive) {
                    groupChatService.rejectGroupInvite(invite)
                    dismiss()
                } label: {
                    Text("Reject")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)
                Button {
                    groupChatService.acceptGroupInvite(invite)
                    dismiss()
                } label: {
                    Text("Accept")
                        .font(.headline)
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }
}

/// The chat list's Message Requests row: everyone who wrote first and hasn't been accepted.
private struct MessageRequestsRow: View {
    let count: Int

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.scaled(size: 20, weight: .semibold))
                .foregroundColor(.black)
                .frame(width: 50, height: 50)
                .background(Circle().fill(Color.accentColor))
            VStack(alignment: .leading, spacing: 3) {
                Text("Message Requests")
                    .font(.headline)
                    .foregroundColor(.primary)
                Text(count > 0 ? "People and groups waiting for you" : "No new requests")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if count > 0 {
                Text(verbatim: "\(count)")
                    .font(.caption.weight(.bold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.accentColor))
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundColor(Color(.tertiaryLabel))
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

/// Chats someone else started that you haven't accepted (NO_HANDSHAKE_MESSAGING.md). Open one to
/// read everything they sent, then Accept or Reject from inside it. Their messages never notify
/// you beyond the first "New message request". Groups you were added to wait here too: you aren't
/// in one until you accept.
struct MessageRequestsView: View {
    @EnvironmentObject private var chatService: ChatService
    @EnvironmentObject private var groupChatService: GroupChatService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            let requests = chatService.messageRequests
            let invites = groupChatService.pendingGroupInvites
            List {
                if !invites.isEmpty {
                    Section("Group Invites") {
                        ForEach(invites) { invite in
                            NavigationLink {
                                GroupInviteRequestView(invite: invite)
                            } label: {
                                GroupInviteRow(invite: invite)
                            }
                        }
                    }
                }
                Section {
                    ForEach(requests) { conversation in
                        NavigationLink {
                            ChatDetailView(contact: conversation.contact, startInPaymentMode: false)
                        } label: {
                            ConversationRow(conversation: conversation)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .overlay {
                if requests.isEmpty && invites.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "tray")
                            .font(.scaled(size: 40))
                            .foregroundColor(.secondary)
                        Text("No message requests")
                            .font(.headline)
                    }
                }
            }
            .navigationTitle("Message Requests")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

