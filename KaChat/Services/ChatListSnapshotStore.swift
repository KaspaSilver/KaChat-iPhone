import Foundation

enum ChatListSnapshotStore {
    private struct Snapshot: Codable {
        let version: Int
        let conversations: [SnapshotConversation]
    }

    private struct SnapshotConversation: Codable {
        let id: UUID
        let contact: Contact
        let lastMessage: ChatMessage?
        let unreadCount: Int
    }

    private static let currentVersion = 1
    /// The UserDefaults key the snapshot lived under until 2026-10-20 (see `moveOutOfUserDefaults`).
    private static let keyPrefix = "kachat_chat_list_snapshot_"

    /// Where the snapshots live: one file per account under Application Support. They were in
    /// UserDefaults, where a photo or voice last message carries its whole base64 payload - one
    /// account's snapshot ran to hundreds of KB, and together with the other accounts' it pushed
    /// UserDefaults past iOS's 4 MB limit, past which iOS refuses every write the app makes.
    static var defaultDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ChatListSnapshots", isDirectory: true)
    }

    static func load(walletAddress: String, directory: URL? = defaultDirectory) -> [Conversation] {
        guard let url = fileURL(walletAddress, directory),
              let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.version == currentVersion else {
            return []
        }

        return snapshot.conversations.map { cached in
            Conversation(
                id: cached.id,
                contact: cached.contact,
                messages: cached.lastMessage.map { [$0] } ?? [],
                unreadCount: cached.unreadCount
            )
        }
    }

    static func save(
        _ conversations: [Conversation],
        walletAddress: String,
        directory: URL? = defaultDirectory
    ) {
        let cachedConversations = conversations.map { conversation in
            SnapshotConversation(
                id: conversation.id,
                contact: conversation.contact,
                lastMessage: conversation.lastMessage,
                unreadCount: conversation.unreadCount
            )
        }
        let snapshot = Snapshot(version: currentVersion, conversations: cachedConversations)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        write(data, walletAddress: walletAddress, directory: directory)
    }

    static func clear(walletAddress: String, directory: URL? = defaultDirectory) {
        if let url = fileURL(walletAddress, directory) {
            try? FileManager.default.removeItem(at: url)
        }
        UserDefaults.standard.removeObject(forKey: keyPrefix + walletAddress)
    }

    /// Moves every account's snapshot still in UserDefaults into its file, and out of
    /// UserDefaults. Run once at launch before anything else writes (`WalletManager.init`).
    /// Returns how many moved.
    @discardableResult
    static func moveOutOfUserDefaults() -> Int {
        let defaults = UserDefaults.standard
        guard let id = Bundle.main.bundleIdentifier, let domain = defaults.persistentDomain(forName: id) else { return 0 }
        var moved = 0
        for (key, value) in domain where key.hasPrefix(keyPrefix) {
            let walletAddress = String(key.dropFirst(keyPrefix.count))
            if let data = value as? Data, let url = fileURL(walletAddress, defaultDirectory),
               !FileManager.default.fileExists(atPath: url.path) {
                write(data, walletAddress: walletAddress, directory: defaultDirectory)
            }
            defaults.removeObject(forKey: key)
            moved += 1
        }
        return moved
    }

    private static func fileURL(_ walletAddress: String, _ directory: URL?) -> URL? {
        directory?.appendingPathComponent(walletAddress.replacingOccurrences(of: ":", with: "_") + ".json")
    }

    private static func write(_ data: Data, walletAddress: String, directory: URL?) {
        guard let directory, let url = fileURL(walletAddress, directory) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        // rebuilt from the message store at any time: kept out of device backups
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var target = url
        try? target.setResourceValues(values)
    }
}
