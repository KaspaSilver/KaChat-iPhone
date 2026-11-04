import Foundation
import P256K

/// What is left in KaChat of the `.kachat` actions since the market moved to the KaChat wallet app
/// (2026-10-24): saving the address profile (`kchat:1:profile:`), listing this wallet's names, and
/// following a sent profile transaction until the registry shows it.
@MainActor
final class KachatNamesActions: ObservableObject {
    static let shared = KachatNamesActions()

    private init() {}

    private var service: KachatNamesService { KachatNamesService.shared }
    private var registry: KachatNamesRegistry { KachatNamesRegistry.shared }

    enum ActionError: LocalizedError {
        case noWallet
        case keyMismatch

        var errorDescription: String? {
            switch self {
            case .noWallet: return AppLocalization.string("No wallet is open.")
            case .keyMismatch: return AppLocalization.string("This wallet's key does not match its address.")
            }
        }
    }

    // MARK: - Wallet

    struct Signer {
        let address: String
        let privateKey: Data
        let me: Data
    }

    /// The current wallet's chatting address and key on the network the app runs on - the
    /// profile record's signer, on every network (`KachatNamesService.profilesEnabled`).
    func profileSigner() throws -> Signer {
        guard KachatNamesService.profilesEnabled else { throw KachatNamesService.ServiceError.testnetOnly }
        guard let address = WalletManager.shared.currentWallet?.publicAddress.lowercased(),
              let key = WalletManager.shared.getPrivateKey() else { throw ActionError.noWallet }
        guard NetworkType.isOnActiveNetwork(address) else { throw KachatNamesService.ServiceError.wrongAddressNetwork }
        let me = try KachatNamesService.xonlyKey(privateKey: key)
        guard let a = KaspaAddress(address: address), a.type == .pubKey, a.payload == me else { throw ActionError.keyMismatch }
        return Signer(address: address, privateKey: key, me: me)
    }

    // MARK: - Addresses an earlier build bought with

    private var marketAddressesKey: String? {
        myAddress.map { "kachat_market_addresses.\($0)" }
    }

    /// Spending addresses an earlier build bought with (the retired Buy From picker), per wallet:
    /// Your Domains still lists the names they hold next to the chatting address's. Nothing adds
    /// to it any more.
    var marketAddresses: [String] {
        guard let key = marketAddressesKey else { return [] }
        return UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    // MARK: - This wallet's keys (IOS-085 / XP-024)

    private var nameKeysCache: (key: String, at: Date, keys: [Data])?

    /// The keys worth asking the registry about (one lookup each): the chatting key, then every
    /// revealed spending address that has ever been used - a name or an offer needs KAS on its
    /// address - and the addresses Buy From was set to. The used/unused answers are cached (used
    /// is for good), so after the first time this costs no requests; the list itself is kept
    /// ten minutes.
    func ownNameKeys() async -> [Data] {
        guard let wallet = myAddress, let me = myKey else { return [] }
        let manager = WalletManager.shared
        let cacheKey = "\(wallet)|\(manager.maxSpendingAddressIndex)|\(marketAddresses.count)"
        if let cached = nameKeysCache, cached.key == cacheKey, Date().timeIntervalSince(cached.at) < 600 {
            return cached.keys
        }
        let spending = manager.spendingAddresses(inRange: 0..<(max(0, manager.maxSpendingAddressIndex) + 1))
            .sorted { $0.key < $1.key }.map(\.value)
        let hints = Set(marketAddresses)
        let chat = ChatService.shared
        var used: [String: Bool] = [:]
        var toProbe: [String] = []
        for address in spending {
            if hints.contains(address.lowercased()) { used[address] = true; continue }
            if let known = chat.cachedSpendingAddressUsedState(address) { used[address] = known } else { toProbe.append(address) }
        }
        var pending = toProbe.makeIterator()
        await withTaskGroup(of: (String, Bool?).self) { group in
            for _ in 0..<8 {
                guard let address = pending.next() else { break }
                group.addTask { (address, await chat.spendingAddressUsedState(address)) }
            }
            while let (address, answer) = await group.next() {
                used[address] = answer ?? false
                if let next = pending.next() {
                    group.addTask { (next, await chat.spendingAddressUsedState(next)) }
                }
            }
        }
        var keys = [me]
        for address in spending where used[address] == true {
            if let key = KachatNamesRegistry.keyOf(address), !keys.contains(key) { keys.append(key) }
        }
        for address in marketAddresses {
            if let key = KachatNamesRegistry.keyOf(address), !keys.contains(key) { keys.append(key) }
        }
        guard myAddress == wallet else { return [] }
        nameKeysCache = (cacheKey, Date(), keys)
        return keys
    }

    /// Every name (`includeInactive`) or held name, and every open offer, on this wallet's keys
    /// (`ownNameKeys`), asked a few at a time.
    func ownNamesAndOffers(heldOnly: Bool) async throws -> (names: [KachatNames.NameInfo], offers: [KachatNames.OfferInfo]) {
        let keys = await ownNameKeys()
        let registry = KachatNamesRegistry.shared
        var names: [KachatNames.NameInfo] = []
        var offers: [KachatNames.OfferInfo] = []
        let lookUp: @MainActor (Data) async throws -> ([KachatNames.NameInfo], [KachatNames.OfferInfo]) = { key in
            let n = heldOnly ? try await registry.heldNames(owner: key) : try await registry.names(owner: key, includeInactive: true)
            let o = try await registry.myOffers(buyer: key)
            return (n, o)
        }
        try await withThrowingTaskGroup(of: ([KachatNames.NameInfo], [KachatNames.OfferInfo]).self) { group in
            var it = keys.makeIterator()
            for _ in 0..<4 {
                guard let key = it.next() else { break }
                group.addTask { try await lookUp(key) }
            }
            while let (n, o) = try await group.next() {
                names += n
                offers += o
                if let key = it.next() { group.addTask { try await lookUp(key) } }
            }
        }
        return (names, offers)
    }

    /// The current wallet's x-only key, without touching the private key.
    var myKey: Data? {
        guard let address = WalletManager.shared.currentWallet?.publicAddress else { return nil }
        return KachatNamesRegistry.keyOf(address)
    }

    var myAddress: String? { WalletManager.shared.currentWallet?.publicAddress.lowercased() }

    // MARK: - Following a sent transaction (node only)

    /// Where a sent name transaction is: sent, waiting in a node's mempool, in a block (its output
    /// is in the UTXO set), shown (the registry has it), or dropped (no node has it).
    enum TxStage: Equatable { case sent, inMempool, accepted, shown, dropped }

    /// The stage of every transaction sent from this app this session, by txid.
    @Published private(set) var txStages: [String: TxStage] = [:]

    /// Follows `txId` until it is in a block, then refreshes the registry so the change shows. A
    /// profile save has no output of its own to look for, so only the mempool, then the REST API,
    /// can tell.
    func follow(txId: String) {
        txStages[txId] = .sent
        Task { @MainActor in
            let started = Date()
            while Date().timeIntervalSince(started) < 300 {
                if await NodePoolService.shared.getMempoolEntry(txId: txId) != nil {
                    if txStages[txId] == .sent { txStages[txId] = .inMempool }
                } else {
                    // Out of the mempool: in a block, or dropped. The REST API settles it.
                    if await KachatNamesRegistry.isAccepted(txId: txId) {
                        txStages[txId] = .accepted
                        await registry.refreshUntilIncludes(txId: txId, daa: await NodePoolService.shared.currentVirtualDaaScore())
                        txStages[txId] = .shown
                        return
                    }
                    if Date().timeIntervalSince(started) > 60 {
                        txStages[txId] = .dropped
                        return
                    }
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            txStages[txId] = .dropped
        }
    }

    // MARK: - Profile record

    /// Writes the address profile (`kchat:1:profile:`): a self-transfer, network fee only.
    @discardableResult
    /// What saving `profile` will cost: the profile record is a self-transfer from the chatting
    /// address, so the network fee is all it spends. Built (and signed) the same way the save
    /// builds it, never sent.
    func profileFee(_ profile: KachatNames.Profile) async throws -> UInt64 {
        let s = try profileSigner()
        let json = try profile.sanitized().recordJSON()
        let utxos = try await NodePoolService.shared.getUtxosByAddresses([s.address])
        let tx = try service.buildProfileRecord(address: s.address, privateKey: s.privateKey, utxos: utxos, json: json)
        let spent = tx.inputs.reduce(UInt64(0)) { total, input in
            total + (utxos.first {
                $0.outpoint.transactionId == input.previousOutpoint.transactionId && $0.outpoint.index == input.previousOutpoint.index
            }?.amount ?? 0)
        }
        let back = tx.outputs.reduce(UInt64(0)) { $0 + $1.value }
        return spent > back ? spent - back : 0
    }

    func saveProfile(_ profile: KachatNames.Profile) async throws -> String {
        let s = try profileSigner()
        let clean = profile.sanitized()
        let json = try clean.recordJSON()
        let utxos = try await NodePoolService.shared.getUtxosByAddresses([s.address])
        let txId = try await service.submitProfileRecord(address: s.address, privateKey: s.privateKey, utxos: utxos, json: json)
        registry.noteOwnProfile(clean, address: s.address, txId: txId)
        registry.refreshAfter(txId: txId)
        return txId
    }

}
