import UIKit

/// How many unseen things a tab is holding, wherever that tab is drawn.
///
/// One source for the dock and the Kaspa Hub grid. A tab's placement is the user's arrangement,
/// so the same tab has to say the same thing in either place - and when a badge was computed
/// separately at each site, moving a tab between them silently changed whether it had one.
@MainActor
enum AppTabBadge {
    static func unreadCount(for tab: AppTab) -> Int {
        switch tab {
        // The whole notification feed: Profile hosts the bell that lists it.
        case .profile: return GlobalNotificationCenter.shared.unreadCount
        // Unread messages across the chats the list shows (not Message Requests or blocked).
        case .chats: return ChatService.shared.chatListUnreadCount
        case .groupChats: return GroupChatService.shared.totalGroupUnreadCount
        default: return 0
        }
    }

    /// Capped in the LABEL, not in the stored count: the real number survives a long absence and
    /// only its rendering is abbreviated. Three characters is as wide as a badge goes before it
    /// starts crowding whatever it sits on.
    static func label(_ count: Int) -> String {
        count > 99 ? "99+" : "\(count)"
    }

    /// What the dock shows on `tab`: Profile a red dot while the bell holds anything unread (the
    /// bell itself is a dot, so the dock says the same thing), Chats and Groups their unread
    /// message count.
    static func dockLabel(for tab: AppTab) -> String? {
        let count = unreadCount(for: tab)
        guard count > 0 else { return nil }
        return tab == .profile ? dot : label(count)
    }

    /// A badge with no number: UIKit draws a small red dot for an empty badge value.
    static let dot = ""

    /// Puts every dock badge straight on the tab bar items too. SwiftUI applies a tab's `.badge`
    /// when it renders the TabView, and MainTabView deliberately doesn't re-render for new
    /// messages or bell entries, so a badge could lag until the next render; setting the UIKit
    /// items directly makes Profile's dot and the Chats and Groups counts change the moment the
    /// counts do, from any tab.
    static func syncDockBadges(dockTabs: [AppTab]) {
        let values = dockTabs.map { dockLabel(for: $0) }
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                var queue: [UIViewController] = window.rootViewController.map { [$0] } ?? []
                while let controller = queue.popLast() {
                    if let tabs = controller as? UITabBarController, let items = tabs.tabBar.items,
                       items.count == values.count {
                        for (item, value) in zip(items, values) where item.badgeValue != value {
                            item.badgeColor = .systemRed
                            item.badgeValue = value
                        }
                        return
                    }
                    queue.append(contentsOf: controller.children)
                }
            }
        }
    }
}
