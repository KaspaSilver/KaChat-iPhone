import Foundation
import CryptoKit

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
    /// The UserDefaults key the snapshot lived under until 2026-10-20 (see `dropFromUserDefaults`).
    private static let keyPrefix = "kachat_chat_list_snapshot_"
    /// The files from before they were sealed (see `removePlaintextSnapshots`).
    private static let plaintextExtension = "json"

    /// The wallet whose snapshot can be read and written, and the key that seals it - the wallet's
    /// at-rest message key, set by `WalletManager` as its private key comes and goes. Behind a
    /// lock because saves run off the main actor (`ChatService.chatListSnapshotQueue`).
    private static var sealing: (walletAddress: String, key: SymmetricKey)?
    private static let sealingLock = NSLock()

    static func setSealing(_ newValue: (walletAddress: String, key: SymmetricKey)?) {
        sealingLock.lock()
        defer { sealingLock.unlock() }
        sealing = newValue
    }

    private static func sealingKey(for walletAddress: String) -> SymmetricKey? {
        sealingLock.lock()
        defer { sealingLock.unlock() }
        guard let sealing, sealing.walletAddress == walletAddress else { return nil }
        return sealing.key
    }

    /// Where the snapshots live: one file per account under Application Support. They were in
    /// UserDefaults, where a photo or voice last message carries its whole base64 payload - one
    /// account's snapshot ran to hundreds of KB, and together with the other accounts' it pushed
    /// UserDefaults past iOS's 4 MB limit, past which iOS refuses every write the app makes.
    static var defaultDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ChatListSnapshots", isDirectory: true)
    }

    static func load(walletAddress: String, directory: URL? = defaultDirectory) -> [Conversation] {
        guard let key = sealingKey(for: walletAddress),
              let url = fileURL(walletAddress, directory),
              let sealed = try? Data(contentsOf: url),
              let data = try? CryptoUtils.decrypt(sealed, using: key),
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

    /// Writes nothing without the wallet's key: this file holds each chat's last message, so it
    /// is sealed or it isn't written.
    static func save(
        _ conversations: [Conversation],
        walletAddress: String,
        directory: URL? = defaultDirectory
    ) {
        guard let key = sealingKey(for: walletAddress) else { return }
        let cachedConversations = conversations.map { conversation in
            SnapshotConversation(
                id: conversation.id,
                contact: conversation.contact,
                lastMessage: conversation.lastMessage,
                unreadCount: conversation.unreadCount
            )
        }
        let snapshot = Snapshot(version: currentVersion, conversations: cachedConversations)
        guard let data = try? JSONEncoder().encode(snapshot),
              let sealed = try? CryptoUtils.encrypt(data, using: key) else { return }
        write(sealed, walletAddress: walletAddress, directory: directory)
    }

    static func clear(walletAddress: String, directory: URL? = defaultDirectory) {
        if let url = fileURL(walletAddress, directory) {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.deletingPathExtension().appendingPathExtension(plaintextExtension))
        }
        UserDefaults.standard.removeObject(forKey: keyPrefix + walletAddress)
    }

    /// Removes every account's snapshot still in UserDefaults. Run once at launch before anything
    /// else writes (`WalletManager.init`). They were plaintext, and rebuilt from the message store
    /// at any time, so they aren't kept. Returns how many went.
    @discardableResult
    static func dropFromUserDefaults() -> Int {
        let defaults = UserDefaults.standard
        guard let id = Bundle.main.bundleIdentifier, let domain = defaults.persistentDomain(forName: id) else { return 0 }
        var dropped = 0
        for key in domain.keys where key.hasPrefix(keyPrefix) {
            defaults.removeObject(forKey: key)
            dropped += 1
        }
        return dropped
    }

    /// Deletes the snapshot files written before they were sealed, each chat's last message in
    /// plaintext, signed-in account or not. The message store rebuilds the list on the next load.
    static func removePlaintextSnapshots(directory: URL? = defaultDirectory) {
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == plaintextExtension {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static func fileURL(_ walletAddress: String, _ directory: URL?) -> URL? {
        directory?.appendingPathComponent(walletAddress.replacingOccurrences(of: ":", with: "_") + ".sealed")
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
