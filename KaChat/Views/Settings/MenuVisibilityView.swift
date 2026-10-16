import SwiftUI

/// Settings > Customization > Customize Dock: one list, ordered by dragging - the way Brave
/// arranges its menu actions.
///
/// The dock always holds Chats, Kaspa Hub and Profile (`AppTab.pinnedToDock`, its last three
/// slots), so what the person chooses is the other two and their order. The list holds everything
/// else, each row with a grip; the two rows above the "Anything below this lives in Kaspa Hub"
/// card are the dock's first two slots, top first, and the rest are Kaspa Hub's grid, in order.
/// The card itself drags too. The dock has room for two: dropping a third above the card pushes
/// the one that was second below it, into Kaspa Hub.
///
/// The arrangement is a draft until this screen is left (or the app goes to the background):
/// writing the real `dockTabs` on every move rebuilt the tab pages under this screen - which
/// lives inside the Profile tab - and threw the person out of it.
struct MenuVisibilityView: View {
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @Environment(\.scenePhase) private var scenePhase

    /// A row of the list: a tab, or the card that splits the dock from Kaspa Hub.
    private enum Row: Hashable, Identifiable {
        case tab(AppTab)
        case divider

        var id: String {
            switch self {
            case .tab(let tab): return tab.rawValue
            case .divider: return "divider"
            }
        }
    }

    @State private var rows: [Row] = []
    /// Guards against persisting before the draft is seeded, which would save an empty dock.
    @State private var loaded = false

    private var settings: AppSettings { settingsViewModel.settings }

    /// The dock's own picks (above the card), in order.
    private var picks: [AppTab] {
        guard loaded else { return Array(AppTab.visible(from: settings).filter { !$0.isPinnedToDock }) }
        let cut = rows.firstIndex(of: .divider) ?? rows.count
        return rows[..<cut].compactMap { if case .tab(let tab) = $0 { return tab } else { return nil } }
    }

    /// Kaspa Hub's grid (below the card), in order.
    private var hubTabs: [AppTab] {
        guard loaded else { return AppTab.ecosystemSections(from: settings) }
        let cut = rows.firstIndex(of: .divider).map { $0 + 1 } ?? rows.count
        return rows[cut...].compactMap { if case .tab(let tab) = $0 { return tab } else { return nil } }
    }

    private var pinned: [AppTab] { AppTab.pinnedToDock.filter { $0.isEnabled(in: settings) } }

    var body: some View {
        List {
            Section {
                ForEach(rows) { row in
                    switch row {
                    case .tab(let tab): tabRow(tab)
                    case .divider: dividerRow
                    }
                }
                .onMove(perform: move)
            } header: {
                Text("Your Dock")
            } footer: {
                Text(String(format: AppLocalization.string("Drag to choose the two you want in your dock, and their order. The top two show in your dock; everything below the card lives in %@."), AppTab.ecosystem.label))
            }

            Section {
                ForEach(pinned) { tab in
                    HStack(spacing: 14) {
                        tabIcon(tab, size: 20)
                            .frame(width: 28)
                        Text(tab.label)
                        Spacer()
                        Image(systemName: "lock.fill")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            } header: {
                Text("Always in your dock")
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Customize Dock")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            dockPreview
        }
        .onAppear {
            guard !loaded else { return }
            let dock = AppTab.visible(from: settings).filter { !$0.isPinnedToDock }
            let hub = AppTab.ecosystemSections(from: settings)
            rows = dock.map(Row.tab) + [.divider] + hub.map(Row.tab)
            loaded = true
        }
        .onDisappear { persist() }
        // Backgrounding is the one way off this screen that never calls onDisappear, and an app
        // killed from the background would otherwise lose the arrangement.
        .onChange(of: scenePhase) { phase in
            if phase != .active { persist() }
        }
    }

    // MARK: - Rows

    private func tabRow(_ tab: AppTab) -> some View {
        HStack(spacing: 14) {
            tabIcon(tab, size: 20)
                .frame(width: 28)
            Text(tab.label)
        }
    }

    /// The card that splits the list: the dock above, Kaspa Hub below. It drags like a row.
    private var dividerRow: some View {
        Text(String(format: AppLocalization.string("Anything below this lives in %@"), AppTab.ecosystem.label))
            .font(.caption.weight(.semibold))
            .textCase(.uppercase)
            .foregroundColor(.secondary)
            .padding(.vertical, 6)
    }

    // MARK: - Dock preview

    /// The dock as it will look: the two picks, then Chats, Kaspa Hub and Profile.
    private var dockPreview: some View {
        VStack(spacing: 6) {
            HStack(spacing: 0) {
                ForEach(picks + pinned) { tab in
                    VStack(spacing: 4) {
                        tabIcon(tab, size: 20)
                            .frame(height: 22)
                        Text(tab.label)
                            .font(.scaled(size: 10, weight: .medium))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity)
                    .opacity(tab.isPinnedToDock ? 0.6 : 1)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .animation(.snappy(duration: 0.22), value: picks)
    }

    @ViewBuilder
    private func tabIcon(_ tab: AppTab, size: CGFloat) -> some View {
        if tab.usesKaspaLogo {
            Image("KaspaLogo")
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        } else if tab == .chess {
            ChessTabIcon.view(side: size)
        } else if tab == .kachatNames {
            KachatTabIcon.view(side: size)
        } else {
            Image(systemName: tab.icon)
                .font(.scaled(size: size, weight: .medium))
                .foregroundStyle(Color.accentColor)
        }
    }

    // MARK: - Moves

    /// Any row, the card included, moves anywhere; then the dock is held to its two slots: if
    /// more than two sit above the card, the card moves up so the extra one falls into Kaspa Hub.
    private func move(from source: IndexSet, to destination: Int) {
        var updated = rows
        updated.move(fromOffsets: source, toOffset: destination)
        if let cut = updated.firstIndex(of: .divider), cut > AppTab.assignableDockSlots {
            updated.remove(at: cut)
            updated.insert(.divider, at: AppTab.assignableDockSlots)
        }
        Haptics.impact(.light)
        rows = updated
    }

    /// Writes the draft to the real settings, and so rebuilds the tab bar - once, on the way out.
    private func persist() {
        guard loaded else { return }
        let dock = (picks + pinned).map(\.rawValue)
        let hub = hubTabs.map(\.rawValue)
        guard dock != settings.dockTabs || hub != settings.hubTabs else { return }
        settingsViewModel.settings.dockTabs = dock
        settingsViewModel.settings.hubTabs = hub
        settingsViewModel.saveSettings()
    }
}
