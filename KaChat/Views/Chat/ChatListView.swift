import SwiftUI
import UserNotifications
import UIKit

struct ChatListView: View {
    @EnvironmentObject var chatService: ChatService
    @EnvironmentObject var contactsManager: ContactsManager
    @EnvironmentObject var walletManager: WalletManager
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var searchText = ""
    @State private var selectedContact: Contact?
    @State private var showMessageRequests = false
    @State private var selectedContactStartInPaymentMode = false
    /// The bottom-right + : one sheet for everything new (new chat, Kaspa, the two QR screens). Everything happens inside that one sheet - choosing an option changes what it
    /// shows rather than closing it and opening another, so there's no dismiss-then-present wait.
    @State private var showCreateSheet = false
    /// True while the sheet shows the New Chat screen. New groups start on Group Chats.
    @State private var showsCreateChat = false
    @State private var createDetent: PresentationDetent = Self.createSheetHeight
    /// The QR options leave the New sheet: it goes down and the full white QR page comes up in
    /// its own sheet, like Profile's.
    @State private var afterCreateSheet: (() -> Void)?
    @State private var qrScreen: ChatsQRScreen?
    private enum ChatsQRScreen: String, Identifiable {
        case fundChatting
        var id: String { rawValue }
    }
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
    /// Row-level delete targets from the long-press context menu - separate from the Select-mode
    /// bulk selection state so a context-menu delete never touches (or is blocked by) edit mode.
    /// Confirmed via their own alerts below, which reuse `deleteConversations`.
    @State private var rowDeleteContact: Contact?
    /// The row whose long-press action sheet is up.
    @State private var conversationActionTarget: Conversation?
    /// The chat row's "Add to Address Book" tile: the contact whose entry sheet is up.
    @State private var addressBookTarget: Contact?
    @ObservedObject private var addressBook = AddressBookManager.shared
    @State private var editMode: EditMode = .inactive
    @State private var selectedContactIDs: Set<UUID> = []

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
        let withToolbar = chatListContent
            .navigationTitle("Chats")
            .navigationBarTitleDisplayMode(.large)
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
                            if isEverythingSelected {
                                selectedContactIDs = []
                            } else {
                                selectedContactIDs = Set(filteredConversationsCache.map { $0.contact.id })
                            }
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
            // placement .always is load-bearing: the chats list used to live inside a paging
            // TabView (chatListContent), so their scrolling no longer drives the navigation
            // bar — with the default .automatic placement under a .large title, the search
            // drawer waits for a nav-bar-linked scroll to reveal it and therefore NEVER
            // appears. Pinning it keeps: bold "Chats" large title, search bar underneath.
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search chats"
            )
            .refreshable {
                isPullRefreshing = true
                // Group chats refresh on their own tab.
                await chatService.fetchNewMessages()
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
                    let contacts = filteredConversationsCache
                        .filter { selectedContactIDs.contains($0.contact.id) }
                        .map { $0.contact }
                    if !contacts.isEmpty { deleteConversations(contacts) }
                    editMode = .inactive
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(bulkDeleteAlertMessage)
            }

        // Row context-menu deletes confirm through their own alerts (same destructive-confirm
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

        return withRowDeleteAlert
            .environment(\EnvironmentValues.editMode, $editMode)
    }

    @ViewBuilder
    private var splitDetailPane: some View {
        if let contact = selectedContact {
            ChatDetailView(contact: contact, startInPaymentMode: selectedContactStartInPaymentMode)
                .id(contact.id)
        } else {
            splitEmptyDetailView
        }
    }

    @ViewBuilder
    private var chatListContent: some View {
        // One list: the chats, with the bots as circles above them (`ChatCirclesStrip`). Group
        // chats have their own tab (`GroupChatListView`).
        chatsTabContent
        .onAppear {
            // Cold start from a profile link.
            if chatService.pendingProfileAddress != nil { openPendingProfile() }
        }
        .onChange(of: walletManager.currentWallet?.publicAddress) { _ in
            loadCirclePins()
            // An account switch keeps this view alive, so a chat open in the old account would
            // otherwise reopen in the new one. Every account starts on its own list.
            selectedContact = nil
            selectedContactStartInPaymentMode = false
            linkedProfileContact = nil
            selectedContactIDs = []
        }
        .onAppear { loadCirclePins() }
        .safeAreaInset(edge: .bottom) {
            if editMode == .active {
                selectionActionBar
            }
        }
        .overlay(alignment: .bottomTrailing) {
            // One + on every page.
            if editMode != .active {
                newButton
            }
        }
        .sheet(isPresented: $showCreateSheet, onDismiss: {
            resetCreateSheet()
            let next = afterCreateSheet
            afterCreateSheet = nil
            next?()
        }) {
            createSheet
                .environmentObject(walletManager)
        }
        .sheet(item: $qrScreen) { screen in
            NavigationStack {
                Group {
                    switch screen {
                    case .fundChatting:
                        if let wallet = walletManager.currentWallet {
                            ChattingAddressQRView(address: wallet.publicAddress, balanceSompi: wallet.balanceSompi)
                        }
                    }
                }
                .navigationTitle("Chatting Address")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { qrScreen = nil }
                    }
                }
            }
            .environmentObject(walletManager)
        }
        .onChange(of: editMode) { newValue in
            if newValue == .inactive {
                selectedContactIDs = []
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
        // Same rule as GroupChatListView's checkPendingGroupNavigation: don't consume the tap
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

    /// The floating glass "+" in the bottom-right corner on every page, opening the New sheet.
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

    /// What the + offers, wherever you are in Chats - all inside this one sheet. New Chat swaps
    /// the sheet to the create screen (Cancel comes back here). It grows to full height
    /// for anything bigger than the menu.
    @ViewBuilder
    private var createSheet: some View {
        Group {
            if showsCreateChat {
                AddContactView(
                    startInGroupMode: false,
                    onAdd: { contact in
                        _ = chatService.getOrCreateConversation(for: contact)
                        selectedContactStartInPaymentMode = false
                        selectedContact = contact
                        showCreateSheet = false
                    },
                    onCancel: {
                        showsCreateChat = false
                        createDetent = Self.createSheetHeight
                    }
                )
            } else {
                createMenu
            }
        }
        .presentationDetents([Self.createSheetHeight, .large], selection: $createDetent)
        .presentationDragIndicator(.visible)
    }

    /// The New options as square tiles: New Chat and Fund Chatting Address. Send, Receive and
    /// Request Payment live on Profile's floating send / receive button.
    private var createMenu: some View {
        let columns = Array(repeating: GridItem(.fixed(Self.createTileSize), spacing: 14), count: 3)
        return VStack(spacing: 16) {
            Text("New")
                .font(.headline)
                .padding(.top, 20)

            LazyVGrid(columns: columns, spacing: 14) {
                CreateTile(title: "New Chat", hint: "Message someone by their address or name.", systemImage: "bubble.left") {
                    createDetent = .large
                    showsCreateChat = true
                }
                CreateTile(title: "Fund Chatting Address", hint: "Show the QR code to add Kaspa for sending messages.", systemImage: "qrcode") {
                    closeCreateSheet { qrScreen = .fundChatting }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    static let createTileSize: CGFloat = 104

    /// One row of tiles. New Chat opens at full height; Fund Chatting Address leaves for its own
    /// white sheet.
    static let createSheetHeight: PresentationDetent = .height(262)

    /// Closes the New sheet and runs `action` once it's gone (a sheet can't present while
    /// another is still going down).
    private func closeCreateSheet(then action: @escaping () -> Void) {
        afterCreateSheet = action
        showCreateSheet = false
    }

    private func resetCreateSheet() {
        showsCreateChat = false
        createDetent = Self.createSheetHeight
    }

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
        let total = filteredConversationsCache.count
        return total > 0 && selectedContactIDs.count >= total
    }

    private var selectionCount: Int {
        selectedContactIDs.count
    }

    // MARK: - Circles (bot chats)

    /// Every bot is always a circle in the row above the chats (since 2026-10-24 there is no
    /// Kaspa Hub page for them), with its chat when there is one. Bot chats never sit in the chat
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
        // Pinned chats live in the circles row, not the list - except while searching, when the
        // results are the whole match, pinned or not.
        let pinnedChats = searchText.isEmpty ? pinnedChatConversations : [:]
        let filtered = pinnedChats.isEmpty
            ? filteredConversationsCache
            : filteredConversationsCache.filter { pinnedChats[Self.chatPinId($0.contact.address)] == nil }
        let totalCount = filtered.count
        let displayed: [Conversation]
        if searchText.isEmpty {
            let count = min(totalCount, max(loadedConversationCount, conversationPageSize))
            displayed = Array(filtered.prefix(count))
        } else {
            displayed = filtered
        }

        let showsRequestsRow = searchText.isEmpty && editMode != .active
        let requestCount = showsRequestsRow ? chatService.messageRequestCount : 0
        return List(selection: $selectedContactIDs) {
            // The bot chats and the chats you pinned, as circles under the search bar - swipe
            // sideways for all of them. Tap opens, hold opens their half sheet.
            ChatCirclesStrip(
                searchText: searchText,
                pins: circlePins,
                bots: botCircles,
                pinnedChats: pinnedChats,
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
            // above your own chat (NO_HANDSHAKE_MESSAGING.md).
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
                ForEach(Array(displayed.enumerated()), id: \.element.id) { index, conversation in
                    Button {
                        // The hold that opened the actions half sheet ends in a touch-up, and a
                        // simultaneousGesture leaves the Button's tap alive - so the chat opened
                        // right behind the sheet. A long press always presents before the finger
                        // lifts, so the target being set IS "this touch was the hold".
                        guard conversationActionTarget == nil else { return }
                        // List(selection:)'s native edit-mode row-selection UI never gets a
                        // chance to see this tap - our own Button label already consumes it - so
                        // toggle selection here explicitly instead of relying on that.
                        if editMode == .active {
                            if selectedContactIDs.contains(conversation.contact.id) {
                                selectedContactIDs.remove(conversation.contact.id)
                            } else {
                                selectedContactIDs.insert(conversation.contact.id)
                            }
                        } else {
                            selectedContactStartInPaymentMode = false
                            selectedContact = conversation.contact
                        }
                    } label: {
                        ConversationRow(conversation: conversation)
                    }
                    .buttonStyle(ChatRowPressStyle())
                    // A sheet, not a context menu: the options each carry a line saying what
                    // they do, and "Silence" needs one - it is not obvious that it survives the
                    // app-wide notification setting.
                    //
                    // `.simultaneousGesture`, not `.onLongPressGesture`: the row's label IS a
                    // Button, and a discrete gesture attached outside it loses the race to the
                    // Button every time - the press did nothing at all. Same reason the message
                    // bubbles use simultaneousGesture for their double-tap.
                    .simultaneousGesture(
                        LongPressGesture(minimumDuration: 0.4).onEnded { _ in
                            guard editMode != .active else { return }
                            Haptics.impact(.medium)
                            conversationActionTarget = conversation
                        }
                    )
                    .tag(conversation.contact.id)
                    .listRowBackground(
                        shouldUseSplitLayout && selectedContact?.address == conversation.contact.address
                            ? Color.accentColor.opacity(0.14)
                            : Color.clear
                    )
                    .onAppear {
                        maybeLoadMoreConversations(
                            currentIndex: index,
                            displayedCount: displayed.count,
                            totalCount: totalCount
                        )
                    }
                }

                Text("\(totalCount) chat\(totalCount == 1 ? "" : "s")")
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
            if displayed.isEmpty && searchText.isEmpty && pinnedChats.isEmpty {
                emptyStateView
                    .padding(.top, 120)
                    .allowsHitTesting(false)
            }
        }
    }

    /// Mark read, mark unread and delete, for every selected chat.
    private var selectionActionBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                Button {
                    let chats = filteredConversationsCache.filter { selectedContactIDs.contains($0.contact.id) }
                    if !chats.isEmpty { Task { await chatService.markConversationsAsRead(chats) } }
                    editMode = .inactive
                } label: {
                    Image(systemName: "envelope.open")
                        .frame(maxWidth: .infinity)
                }
                .disabled(selectionCount == 0)

                Button {
                    let chats = filteredConversationsCache.filter { selectedContactIDs.contains($0.contact.id) }
                    if !chats.isEmpty { chatService.markConversationsAsUnread(chats) }
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
        // Kaspa logo + bold, matching KaPosts' balance header style.
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
            filteredConversationsCache = pinningSelfChat(filteredConversationsCache)
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
            filteredConversationsCache = pinningSelfChat(filteredConversationsCache)
            return
        }

        filteredConversationsCache = pinningSelfChat(sourceConversations.filter { conv in
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
        })
    }

    /// Your chat with yourself always sits first, whatever else was active more recently - it is
    /// the notes-to-self and landing spot for unknown senders, and should never have to be
    /// scrolled for. Everything else keeps its order.
    private func isOwnChat(_ contact: Contact) -> Bool {
        guard let mine = walletManager.currentWallet?.publicAddress.lowercased() else { return false }
        return contact.address.lowercased() == mine
    }

    private func pinningSelfChat(_ conversations: [Conversation]) -> [Conversation] {
        guard let mine = walletManager.currentWallet?.publicAddress.lowercased(),
              let index = conversations.firstIndex(where: { $0.contact.address.lowercased() == mine }),
              index > 0 else { return conversations }
        var pinned = conversations
        pinned.insert(pinned.remove(at: index), at: 0)
        return pinned
    }

    /// Pulled out of the `.alert(...)` call site as a plain computed property - an inline ternary
    /// nested inside string interpolation there was making the compiler unable to type-check the
    /// `.alert` expression in reasonable time.
    private var bulkDeleteAlertTitle: String {
        let chats = selectedContactIDs.count
        return "Delete \(chats) Chat\(chats == 1 ? "" : "s")?"
    }

    private var bulkDeleteAlertMessage: String {
        AppLocalization.string("This permanently deletes every message in each selected chat from this device. This cannot be undone.")
    }

    /// Long-press context menu for a 1:1 conversation row. Read/Unread show contextually (the
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
                        title: saved ? "Address Book" : "Add to Address Book",
                        subtitle: saved
                            ? "Edit or remove this saved address."
                            : "Save this address with a name you'll recognize.",
                        systemImage: saved ? "book.closed.fill" : "book.closed"
                    ) {
                        conversationActionTarget = nil
                        // One turn later, like Delete: a sheet cannot present while this one leaves.
                        DispatchQueue.main.async { addressBookTarget = conversation.contact }
                    }
                }

                // Your chat with yourself cannot be deleted - it is always there, first in the list.
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

    /// Shared delete path for both Select-mode bulk deletes and single-row context-menu deletes
    /// (row swipes are gone) - per-contact cleanup with one resubscribe and toast at the end.
    private func deleteConversations(_ contacts: [Contact]) {
        // Your own chat is never deleted, even when it was part of a Select All.
        let contacts = contacts.filter { !isOwnChat($0) }
        guard !contacts.isEmpty else {
            selectedContactIDs = []
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
        selectedContactIDs = []
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

/// The red unread count - on the circles above the Chats and Groups lists.
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
/// own tab (`GroupChatListView`).
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
        if items.isEmpty {
            Color.clear.frame(height: 1)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                // A plain HStack: it measures every circle, so the row is as tall as its tallest.
                HStack(alignment: .top, spacing: 14) {
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

/// One circle in a row above a list (the Chats row, the Groups row): the avatar, the whole name
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
                Text(count > 0 ? "People who wrote to you first" : "No new requests")
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
/// you beyond the first "New message request".
struct MessageRequestsView: View {
    @EnvironmentObject private var chatService: ChatService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            let requests = chatService.messageRequests
            List {
                Section {
                    ForEach(requests) { conversation in
                        NavigationLink {
                            ChatDetailView(contact: conversation.contact, startInPaymentMode: false)
                        } label: {
                            ConversationRow(conversation: conversation)
                        }
                    }
                } footer: {
                    if !requests.isEmpty {
                        Text("Open a request to read it. Accept to reply and move it to your chats; Reject deletes it and stops that address reaching you until you write to them.")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .overlay {
                if requests.isEmpty {
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

/// One square option in the Chats New sheet and Profile's Send and Receive sheet: an icon over a
/// two-line title, on glass.
struct CreateTile: View {
    let title: LocalizedStringKey
    let hint: LocalizedStringKey
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundColor(.accentColor)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            .padding(8)
            .frame(width: ChatListView.createTileSize, height: ChatListView.createTileSize)
            .background(sendKaspaGlass(cornerRadius: 18))
        }
        .buttonStyle(ChatRowPressStyle())
        .accessibilityHint(Text(hint))
    }
}

