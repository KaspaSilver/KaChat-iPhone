import SwiftUI

/// Settings > Customization > Customize Dock: two lists ordered by dragging - the way Brave
/// arranges its menu actions.
///
/// Your Dock is the dock itself, all of it, in order: every row drags, Chats, Kaspa Hub and
/// Profile included (`AppTab.pinnedToDock` - always there, so they carry a lock instead of a
/// remove button), and the two the person picked carry Brave's red minus, which sends them to
/// Kaspa Hub. Kaspa Hub lists everything else in its grid order, also by dragging, each with a
/// green plus that moves it into the dock - shown only while the dock has room (five at most).
///
/// The arrangement is a draft until this screen is left (or the app goes to the background):
/// writing the real `dockTabs` on every move rebuilt the tab pages under this screen - which
/// lives inside the Profile tab - and threw the person out of it.
struct MenuVisibilityView: View {
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @Environment(\.scenePhase) private var scenePhase

    @State private var dock: [AppTab] = []
    @State private var hub: [AppTab] = []
    /// Guards against persisting before the draft is seeded, which would save an empty dock.
    @State private var loaded = false

    private var settings: AppSettings { settingsViewModel.settings }
    private var dockIsFull: Bool { dock.count >= AppTab.maxDockItems }

    var body: some View {
        List {
            Section {
                ForEach(dock) { tab in
                    dockRow(tab)
                }
                .onMove { source, destination in
                    Haptics.impact(.light)
                    dock.move(fromOffsets: source, toOffset: destination)
                }
            } header: {
                HStack {
                    Text("Your Dock")
                    Spacer()
                    Text(verbatim: "\(dock.count)/\(AppTab.maxDockItems)")
                }
            } footer: {
                Text(String(format: AppLocalization.string("%@, %@ and %@ always stay in your dock."),
                            AppTab.chats.label, AppTab.ecosystem.label, AppTab.profile.label))
            }

            Section {
                ForEach(hub) { tab in
                    hubRow(tab)
                }
                .onMove { source, destination in
                    Haptics.impact(.light)
                    hub.move(fromOffsets: source, toOffset: destination)
                }
            } header: {
                Text(AppTab.ecosystem.label)
            } footer: {
                Text(dockIsFull
                     ? AppLocalization.string("Your dock is full. Remove one from it to add one of these.")
                     : String(format: AppLocalization.string("In the order %@ shows them."), AppTab.ecosystem.label))
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Customize Dock")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !loaded else { return }
            dock = AppTab.visible(from: settings)
            hub = AppTab.ecosystemSections(from: settings)
            loaded = true
        }
        // Applied once this screen has finished closing: a new arrangement rebuilds the whole
        // tab bar, and rebuilding it under a closing sheet or navigation pop could leave the page
        // shown next (KaPosts, say) black until a relaunch.
        .onDisappear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { persist() }
        }
        // Backgrounding is the one way off this screen that never calls onDisappear, and an app
        // killed from the background would otherwise lose the arrangement.
        .onChange(of: scenePhase) { phase in
            if phase != .active { persist() }
        }
    }

    // MARK: - Rows

    private func dockRow(_ tab: AppTab) -> some View {
        HStack(spacing: 14) {
            if tab.isPinnedToDock {
                Image(systemName: "lock.fill")
                    .font(.system(size: 15))
                    .foregroundColor(.secondary)
                    .frame(width: 24)
                    .accessibilityLabel(Text("Always in your dock"))
            } else {
                Button {
                    removeFromDock(tab)
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .red)
                        .font(.system(size: 22))
                        .frame(width: 24)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text(String(format: AppLocalization.string("Move %@ to %@"), tab.label, AppTab.ecosystem.label)))
            }
            tabIcon(tab, size: 20)
                .frame(width: 28)
            Text(tab.label)
        }
    }

    private func hubRow(_ tab: AppTab) -> some View {
        HStack(spacing: 14) {
            if !dockIsFull {
                Button {
                    addToDock(tab)
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .green)
                        .font(.system(size: 22))
                        .frame(width: 24)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text(String(format: AppLocalization.string("Add %@ to your dock"), tab.label)))
            }
            tabIcon(tab, size: 20)
                .frame(width: 28)
            Text(tab.ecosystemTitle)
        }
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

    /// Red minus: out of the dock, to the top of Kaspa Hub where it can be seen.
    private func removeFromDock(_ tab: AppTab) {
        guard !tab.isPinnedToDock else { return }
        Haptics.impact(.light)
        withAnimation(.snappy(duration: 0.22)) {
            dock.removeAll { $0 == tab }
            hub.removeAll { $0 == tab }
            hub.insert(tab, at: 0)
        }
    }

    /// Green plus: into the dock, at its end; drag it to where it should sit.
    private func addToDock(_ tab: AppTab) {
        guard !dockIsFull else { return }
        Haptics.impact(.light)
        withAnimation(.snappy(duration: 0.22)) {
            hub.removeAll { $0 == tab }
            dock.removeAll { $0 == tab }
            dock.append(tab)
        }
    }

    /// Writes the draft to the real settings, and so rebuilds the tab bar - once, on the way out.
    private func persist() {
        guard loaded else { return }
        let dockRaw = dock.map(\.rawValue)
        let hubRaw = hub.map(\.rawValue)
        guard dockRaw != settings.dockTabs || hubRaw != settings.hubTabs else { return }
        settingsViewModel.settings.dockTabs = dockRaw
        settingsViewModel.settings.hubTabs = hubRaw
        settingsViewModel.saveSettings()
    }
}
