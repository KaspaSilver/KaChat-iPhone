import SwiftUI
import Combine
import UIKit

struct MainTabView: View {
    @State private var selectedTab = 1
    /// A local Core Data store failed to open (see `CoreDataStoreLoader.reportFailure`).
    @State private var storeLoadFailure: String?

    private var storeLoadFailureShown: Binding<Bool> {
        Binding(get: { storeLoadFailure != nil }, set: { if !$0 { storeLoadFailure = nil } })
    }

    private static func storeFailureMessage(from note: Notification) -> String {
        let store = note.userInfo?["store"] as? String ?? "store"
        let detail = note.userInfo?["message"] as? String ?? ""
        let what: String
        switch store {
        case "MessageStore": what = "your message history"
        case "GroupStore": what = "your group chats"
        default: what = "local data"
        }
        return "KaChat couldn't open \(what) on this device. Messages will not be saved until it can. Restarting the app usually fixes this; if it keeps happening, export diagnostics from Settings and contact support.\n\n\(detail)"
    }
    /// Debounces the off-chat-tab discovery pause/resume so rapid tab-flipping can't thrash it.
    @State private var tabWorkTask: Task<Void, Never>?
    @State private var showWelcomeGuide = false
    /// 4.0 "what's new" wizard: shown on every entry into the app until the user taps
    /// Don't Show Again (persisted per device).
    /// Blocking progress while the post-onboarding sync runs.
    @State private var showInitialSyncProgress = false
    /// The call screen (ringing in, ringing out, connected) sits over the whole app, whichever
    /// tab is showing - a call is not a page of the chat it started from.
    @ObservedObject private var callService = CallService.shared
    @ObservedObject private var pictureInPicture = CallPictureInPicture.shared
    @Environment(\.scenePhase) private var scenePhase
    /// Not observed. This view only CALLS into these two (start/stop polling, onboarding holds,
    /// pending routes) and renders nothing from them, but as @EnvironmentObjects every chat
    /// sync step, fetch state, conversation update and balance write re-ran the root TabView -
    /// re-applying every tab item and badge - underneath whatever screen was open.
    private var chatService: ChatService { ChatService.shared }
    private var walletManager: WalletManager { WalletManager.shared }
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    /// The address a tapped "Received" notification opened (its history, in a sheet).
    @State private var ownAddressSheet: OwnAddressSheetTarget?
    // Red dot on the Profile tab while the bell (which lives on the Profile screen)
    // holds unread notifications.
    @ObservedObject private var notifCenter = GlobalNotificationCenter.shared
    // Surfaces the Nextcloud silent auto-restore's one-line result ("Restored N messages...")
    // as a toast over whatever tab is showing - the automatic path has no modal by design.
    @ObservedObject private var nextcloudService = NextcloudService.shared

    /// The dock's TabView on its own, so `body` stays small enough for the type checker. The
    /// dock is the fixed `AppTab.dock`: Chats, Address Book, Profile, Settings.
    private var dockTabView: some View {
        TabView(selection: tabSelection) {
            ForEach(AppTab.dock) { tab in
                tabContent(for: tab)
                    .tabItem {
                        Label(tab.label, systemImage: tab.icon)
                    }
                    // Profile hosts the notification bell and shows a dot while it holds
                    // anything unread.
                    .badge(dockBadge(for: tab))
                    .tag(tab.tag)
            }
        }
        .tint(.accentColor)
    }

    var body: some View {
        dockTabView
        // the bell has something unread: Profile's dock dot, from whichever tab is showing. Its
        // own modifier: inline, these pushed the body past what the type checker can solve.
        .modifier(ProfileDockDotSync(selectedTab: selectedTab, dockTabs: AppTab.dock))
        .toast(message: nextcloudService.syncStatusToast)
        .onAppear {
            LaunchTrace.mark("main tabs on screen")
            // A hold with no guide to release it would strand the account: the branches below
            // that DON'T present a guide lift it explicitly, and this covers every other path in.
            if chatService.onboardingSyncHeld && !showWelcomeGuide && !walletManager.justCreatedNewWallet {
                chatService.releaseSyncForOnboarding()
            }
            chatService.startPolling()
            preloadProfileResources()
            // A notification tapped from a cold start routed before this view existed - replay
            // its tab switch now that there's something to switch.
            consumePendingNotificationRoute()
            if walletManager.justCreatedNewWallet {
                walletManager.justCreatedNewWallet = false
                // Persisted BEFORE presenting: justCreatedNewWallet is in-memory only, so an
                // app kill mid-wizard would otherwise never bring the guide back - the pending
                // marker makes the next launch re-present it, for a create or an import alike.
                WelcomeGuideView.markOnboardingRunPending()
                showWelcomeGuide = true
            } else if WelcomeGuideView.isOnboardingRunPending {
                // Onboarding run interrupted: re-present the full guide from the top, still as
                // an unskippable onboarding run.
                showWelcomeGuide = true
            } else {
                // No setup guide is coming, so nothing is waiting on it - lift any hold rather
                // than leaving the account permanently unsynced.
                chatService.releaseSyncForOnboarding()
            }
        }
        .fullScreenCover(isPresented: $showInitialSyncProgress) {
            InitialSyncProgressModal(onDismiss: { showInitialSyncProgress = false })
        }
        // The call screen itself is a window of its own (`CallWindowPresenter`), so no sheet up
        // here can keep it from showing.
        // A call tucked away and not floating as Picture in Picture: the green return bar.
        .overlay(alignment: .top) {
            if let call = callService.session, callService.isMinimized, !pictureInPicture.isActive {
                CallReturnBar(call: call)
                    .padding(.top, 4)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .fullScreenCover(isPresented: $showWelcomeGuide) {
            WelcomeGuideView(
                onFinished: {
                    showWelcomeGuide = false
                    // Everything the account owns starts syncing now, behind a sheet - a
                    // half-synced chat list invites taps on chats whose history has not landed.
                    if chatService.onboardingSyncHeld {
                        chatService.releaseSyncForOnboarding()
                        showInitialSyncProgress = true
                    }
                },
                // MainTabView only ever presents the guide for account onboarding (fresh
                // create/import or a kill/relaunch re-present) - Help replays live in
                // ContactsView, which leaves this false. Onboarding runs are fully unskippable.
                isOnboardingRun: true
            )
        }
        // The one thing here that reacts to the wallet: a switch of address. Subscribed to that
        // alone, rather than observing all of WalletManager for it. Uses the address the
        // publisher delivers: @Published emits before the property changes, so reading
        // `currentWallet` here would still see the previous wallet.
        .onReceive(
            WalletManager.shared.$currentWallet
                .map { $0?.publicAddress }
                .removeDuplicates()
                .dropFirst()
        ) { address in
            if let address { ProfileView.preloadQRCode(for: address) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openChat)) { _ in
            PendingTabRoute.pending = nil
            handleTabSelectionChange(AppTab.chats.tag)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openKNSProfileEditor)) { _ in
            handleTabSelectionChange(AppTab.profile.tag)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openProfile)) { _ in
            // Spending-address receipts: Profile, which shows the wallet's addresses and balances.
            PendingTabRoute.pending = nil
            handleTabSelectionChange(AppTab.profile.tag)
        }
        // Its own modifier: added to this chain inline, it pushed the body past what the type
        // checker can solve in reasonable time.
        .modifier(OwnAddressSheetPresenter(target: $ownAddressSheet, onRequest: takeOwnAddressRoute))
        // A payment request tapped or pasted anywhere: Send Kaspa with it filled in.
        .modifier(PaymentRequestSheetPresenter())
        .onReceive(NotificationCenter.default.publisher(for: .openGroup)) { _ in
            selectedTab = 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .localStoreLoadFailed)) { note in
            storeLoadFailure = Self.storeFailureMessage(from: note)
        }
        .alert("Storage problem", isPresented: storeLoadFailureShown) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(storeLoadFailure ?? "")
        }
    }

    /// The unread COUNT on the tabs that own one, and nothing on the rest.
    ///
    /// A bare dot said only "something happened". The number is the difference between
    /// deciding to look now and deciding to look later, and the dock is where that decision
    /// gets made - a badge with a space in it was the dot, and the space was the whole design.
    private func dockBadge(for tab: AppTab) -> Text? {
        AppTabBadge.dockLabel(for: tab).map { Text(verbatim: $0) }
    }


    @ViewBuilder
    private func tabContent(for tab: AppTab) -> some View {
        switch tab {
        case .chats:
            // Bare ChatListView, no ZStack, no wrappers - a permanent compositing wrapper on the
            // app's main screen was the 4.0 "lag everywhere" regression.
            ChatListView()
        case .addressBook:
            AddressBookView()
        case .profile:
            ProfileView()
        case .settings:
            SettingsView()
        }
    }

    private var tabSelection: Binding<Int> {
        Binding(
            get: { selectedTab },
            set: { newValue in
                handleTabSelectionChange(newValue)
            }
        )
    }

    private func handleTabSelectionChange(_ newValue: Int) {
        selectedTab = newValue

        // Off-chat-tab power saving, DEBOUNCED so rapidly flipping tabs can't thrash start/stop
        // (which was restarting the initial sync and freezing the UI). Only the settled tab - after
        // a short quiet period - pauses or resumes the node pool's aggressive discovery/probe loops
        // and the fallback message-poll timer. The pool + UTXO subscription stay live, so sending,
        // on-demand balance/history and push keep working; only background scanning stops.
        tabWorkTask?.cancel()
        tabWorkTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled { return }
            if newValue == AppTab.chats.tag {
                await NodePoolService.shared.resumeDiscovery()
                chatService.startPolling()
            } else {
                await NodePoolService.shared.pauseDiscovery()
                chatService.stopPollingTimerOnly()
            }
        }
    }

    // MARK: - Notification routing

    /// Cold-start replay of a notification tap's tab switch: the tap's NotificationCenter post
    /// is delivered before this view exists (the app is still on the loading/onboarding route),
    /// so its tab switch is lost while the pending target survives. The destination screens
    /// consume the target itself; this only puts the user on the tab that mounts them.
    /// Opens the address a tapped "Received" notification named, over whatever tab is showing.
    private func takeOwnAddressRoute() {
        guard let address = OwnAddressRoute.pending else { return }
        OwnAddressRoute.pending = nil
        ownAddressSheet = OwnAddressSheetTarget(address: address)
    }

    private func consumePendingNotificationRoute() {
        if OwnAddressRoute.pending != nil {
            takeOwnAddressRoute()
            return
        }
        if let tab = PendingTabRoute.pending {
            PendingTabRoute.pending = nil
            handleTabSelectionChange(tab.tag)
            return
        }
        if chatService.pendingChatNavigation != nil ||
            chatService.pendingProfileAddress != nil ||
            GroupChatService.shared.pendingGroupNavigation != nil ||
            GroupChatService.shared.pendingGroupListNavigation {
            selectedTab = AppTab.chats.tag
        }
    }

    private func preloadProfileResources() {
        guard let address = walletManager.currentWallet?.publicAddress else { return }
        ProfileView.preloadQRCode(for: address)
    }

}

#Preview {
    MainTabView()
        .environmentObject(WalletManager.shared)
        .environmentObject(ContactsManager.shared)
        .environmentObject(ChatService.shared)
        .environmentObject(SettingsViewModel())
}


// MARK: - 4.0 dock wizard (what's new popup)



// MARK: - Initial sync progress

/// Blocking progress shown once the setup wizard finishes, while the account's first full sync
/// runs. Nothing syncs during the wizard (see `ChatService.holdSyncForOnboarding`), so this is
/// where all of that work actually happens - and a half-populated chat list invites taps on
/// chats whose history has not arrived yet.
///
/// It is deliberately escapable. A sync can stall on a slow indexer or a bad network, and a
/// modal with no way out would be worse than an incomplete chat list, so "Continue anyway"
/// appears once it has been running a while.
private struct InitialSyncProgressModal: View {
    let onDismiss: () -> Void
    @EnvironmentObject var chatService: ChatService
    @State private var canSkip = false

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()

            VStack(spacing: 16) {
                if chatService.initialSyncPhase == .finished {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 38, weight: .medium))
                        .foregroundColor(.green)
                    Text("You're all set")
                        .font(.headline)
                    Text("Your chats and history are up to date.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Done", action: onDismiss)
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 4)
                } else {
                    ProgressView().controlSize(.large)
                    Text("Setting up your account")
                        .font(.headline)
                    Text(chatService.initialSyncPhase?.label ?? "Starting")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Text("Downloading everything this account has on chain. It only takes this long once.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    if canSkip {
                        Button("Continue anyway", action: onDismiss)
                            .font(.subheadline)
                            .padding(.top, 6)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 340)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.regularMaterial)
            )
            .padding(.horizontal, 24)
        }
        .interactiveDismissDisabled(true)
        .task {
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            canSkip = true
        }
    }
}

struct OwnAddressSheetTarget: Identifiable {
    let address: String
    var id: String { address }
}

/// One of your own addresses, opened from a tapped "Received" notification on its History tab:
/// the chatting address or a spending address, each on the same screen you'd reach it through
/// (Profile, Manage Addresses).
struct OwnAddressHistorySheet: View {
    let address: String
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var walletManager: WalletManager

    private enum Resolved {
        case chatting
        case spending(SpendingAddressEntry)
        case unknown
    }

    @State private var resolved: Resolved?

    var body: some View {
        NavigationStack {
            Group {
                switch resolved {
                case nil:
                    ProgressView()
                case .chatting?:
                    ChattingAddressManageView(address: address)
                case .spending(let entry)?:
                    SpendingAddressTransactionHistoryView(entry: entry)
                case .unknown?:
                    Text("This address isn't in this wallet any more.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { resolved = await resolve() }
    }

    /// Which of your addresses it is, with its balance for the screen's header.
    private func resolve() async -> Resolved {
        let target = address.lowercased()
        if walletManager.currentWallet?.publicAddress.lowercased() == target { return .chatting }
        let utxos = (try? await NodePoolService.shared.getUtxosByAddresses([address])) ?? []
        let balance = utxos.reduce(UInt64(0)) { $0 + $1.amount }
        var spending = walletManager.spendingAddresses(inRange: 0..<(max(0, walletManager.maxSpendingAddressIndex) + 1))
        if walletManager.maxQuantumAddressIndex >= 0 {
            let base = WalletManager.quantumIndexBase
            spending.merge(walletManager.spendingAddresses(inRange: base..<(base + walletManager.maxQuantumAddressIndex + 1))) { a, _ in a }
        }
        if let match = spending.first(where: { $0.value.lowercased() == target }) {
            return .spending(SpendingAddressEntry(
                index: match.key,
                address: match.value,
                balanceSompi: balance,
                isCurrent: match.key == walletManager.currentSpendingAddressIndex
            ))
        }
        return .unknown
    }
}

/// Presents a tapped "Received" notification's address (`OwnAddressHistorySheet`) over the tabs.
private struct OwnAddressSheetPresenter: ViewModifier {
    @Binding var target: OwnAddressSheetTarget?
    let onRequest: () -> Void
    @EnvironmentObject private var settingsViewModel: SettingsViewModel

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .openOwnAddress)) { _ in
                onRequest()
            }
            .sheet(item: $target) { target in
                OwnAddressHistorySheet(address: target.address)
                    .environmentObject(ChatService.shared)
                    .environmentObject(settingsViewModel)
                    .environmentObject(WalletManager.shared)
                    .environmentObject(ContactsManager.shared)
            }
    }
}

/// Keeps Profile's dock dot in step with the bell (`AppTabBadge.syncProfileDot`): when the feed
/// changes, the tab changes, the dock is rearranged, and on appear - set after the render that
/// triggered it, so it lands on the bar SwiftUI just updated.
private struct ProfileDockDotSync: ViewModifier {
    @ObservedObject private var notifCenter = GlobalNotificationCenter.shared
    let selectedTab: Int
    let dockTabs: [AppTab]

    func body(content: Content) -> some View {
        content
            .onReceive(notifCenter.objectWillChange) { _ in sync() }
            .onChange(of: selectedTab) { _ in sync() }
            .onChange(of: dockTabs) { _ in sync() }
            .onAppear { sync() }
    }

    private func sync() {
        let tabs = dockTabs
        DispatchQueue.main.async { AppTabBadge.syncProfileDot(dockTabs: tabs) }
    }
}
