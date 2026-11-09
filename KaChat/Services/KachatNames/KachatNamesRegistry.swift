import Foundation
import UIKit
import UserNotifications

/// The `.kachat` registry for the screens: lookups, an owner's names, listings, lapsed names,
/// offers, history and identities, from one of two sources -
///
/// - **the names indexer** (KACHAT_NAMES_INDEXER.md Part D) at `AppSettings.kachatNamesIndexerURL`
///   (Connection Settings > Domains, separate from the message indexer), used when
///   that field is set and `GET /names/status` answers 200 for this manifest's registry id;
/// - **the chain walker** otherwise: the registry's live UTXO set (gaps and names, plus the offers
///   this device made) kept from the manifest's genesis gap forward. A refresh asks a node which
///   tracked UTXOs are still unspent, finds each spent one's spending transaction through the
///   Kaspa REST API (`GET /addresses/{p2sh}/full-transactions`), decodes the spend like the
///   indexer does (B3), verifies every new state against its output script and moves on. Cached
///   per network in Application Support.
///
/// Records from either source are only read here: nothing in this app spends them.
@MainActor
final class KachatNamesRegistry: ObservableObject {
    static let shared = KachatNamesRegistry()

    enum Source: Equatable {
        case indexer(String)
        case chain
    }

    /// The address profile this wallet last wrote (the walker cannot read anyone's profile).
    struct OwnProfile: Codable, Equatable {
        var address: String
        var profile: KachatNames.Profile
        var txId: String
        var at: Int64
    }

    @Published private(set) var source: Source?
    @Published private(set) var chainState: KachatNames.RegistryState?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastError: String?
    @Published private(set) var refreshedAt: Date?
    /// Bumped whenever registry data may have changed, so screens reload.
    @Published private(set) var revision = 0
    /// When `refresh` last bumped `revision` (see `refresh(announce:)`).
    private var revisionBumpedAt = Date.distantPast

    private var cacheNetwork: String?
    private var ownProfiles: [String: OwnProfile] = [:]
    /// Addresses with no saved own-profile file. `ownProfile(for:)` runs for every name and
    /// avatar drawn - nearly always someone else's address - and each miss was a failing file
    /// read (plus a directory create and a hash) on the main thread, on every redraw.
    private var ownProfileMisses: Set<String> = []

    /// `.kachat` identities by lowercased address, for the app's display rules (names, avatars,
    /// banners, bios everywhere - see `cachedIdentity(for:)`). Kept on disk too
    /// (`KachatProfileCache`), so people's avatars and bios show at once after a launch while a
    /// fresh copy is fetched; Settings > Storage > Cache > Profiles clears it.
    private struct CachedIdentity: Codable {
        var identity: KachatNames.Identity
        var revision: Int
        var at: Date
    }
    /// Not `@Published`: a re-check that finds the same identity only stamps it, and stamping
    /// must not redraw every avatar and name on screen. `objectWillChange` is sent by hand when
    /// an identity really changes.
    private var identities: [String: CachedIdentity] = KachatNamesRegistry.loadIdentities()
    /// One disk write for a burst of identity changes (a screen full of avatars landing at once).
    private var identitiesPersistScheduled = false
    private var identityLookups: Set<String> = []
    /// When an address's lookup last failed: it isn't asked again for five minutes, so a view
    /// body that reads `cachedIdentity` can't turn an unreachable indexer into a request loop.
    private var identityMisses: [String: Date] = [:]
    /// Set when the indexer said it doesn't serve profiles (503) - see `profileOnlyIdentity`.
    private var profilesUnavailableUntil: Date?
    /// The walk under way: a refresh and the standby walk share it rather than racing.
    private var walkTask: Task<Bool, Error>?
    /// When the chain copy was last brought up to date while the indexer was in use.
    private var standbyWalkedAt: Date?
    /// Failed indexer requests in a row, and when the last one was (`indexerOutageConfirmed`).
    private var indexerFailuresInARow = 0
    private var lastIndexerFailureAt = Date.distantPast
    /// After a failover the indexer isn't tried again before this, however its status answers:
    /// a server whose status route works and whose data routes fail would otherwise flip the
    /// registry back and forth with no pause. Doubles up to ten minutes, reset by real data.
    private var indexerRetryNotBefore: Date?
    private var failoverBackoff: TimeInterval = 60
    private var chainCopySaveTask: Task<Void, Never>?
    /// `chainProfile` lookups under way.
    private var chainProfileLookups = 0
    /// When each address's profile was last looked for on the chain (`chainProfile`).
    private var chainProfileCheckedAt: [String: Date] = [:]

    private init() {}

    private var service: KachatNamesService { KachatNamesService.shared }

    // MARK: - Setup

    /// The verified manifest, with the source picked and the walker's cache loaded.
    @discardableResult
    func prepare(forceSourceCheck: Bool = false) async throws -> KachatNames.Manifest {
        let m = try await service.loadManifest()
        // a source picked on the other network (its indexer) is never this one's
        if preparedNetwork != m.network {
            source = nil
            chainState = nil
            cacheNetwork = nil
            standbyWalkedAt = nil
            preparedNetwork = m.network
        }
        if source == nil || forceSourceCheck {
            let chosen = await chooseSource(m)
            if let was = source, was != chosen {
                AppLog.log("[KachatNames] registry source: %@", chosen == .chain ? "the chain (the indexer is behind or elsewhere)" : "the indexer")
            }
            source = chosen
        }
        if source == .chain { await loadChainCopyIfNeeded(m) }
        return m
    }

    private func loadChainCopyIfNeeded(_ m: KachatNames.Manifest) async {
        guard chainState == nil || cacheNetwork != m.network else { return }
        let saved = await Task.detached(priority: .utility) { Self.loadCache(m) }.value
        guard chainState == nil || cacheNetwork != m.network else { return }
        chainState = saved ?? .atGenesis(m)
        cacheNetwork = m.network
    }

    /// Writes in the order asked, off the main thread: the whole registry is a large JSON file.
    private func saveChainCopy(_ state: KachatNames.RegistryState) {
        let previous = chainCopySaveTask
        chainCopySaveTask = Task.detached(priority: .utility) {
            await previous?.value
            Self.saveCache(state)
        }
    }

    /// The network `prepare` last ran for.
    private var preparedNetwork: String?

    /// Forget everything in memory (network switch, logout).
    func reset() {
        preparedNetwork = nil
        source = nil
        chainState = nil
        cacheNetwork = nil
        standbyWalkedAt = nil
        chainProfileCheckedAt = [:]
        ownProfiles = [:]
        ownProfileMisses = []
        lastError = nil
        refreshedAt = nil
        revision += 1
    }

    var graceMs: Int64 { service.manifest?.params.graceMs ?? 864_000_000 }

    /// An indexer further behind the network than this (DAA scores, about a minute) isn't used:
    /// its names would be stale - a name just claimed or sold missing, a registration waiting on
    /// it - so the app walks the chain itself until the indexer catches up (its node can lag on
    /// slow hardware).
    static let maxIndexerLagDaa: UInt64 = 600

    private func chooseSource(_ m: KachatNames.Manifest) async -> Source {
        guard let base = Self.indexerBase() else { return .chain }
        if source == .chain, let notBefore = indexerRetryNotBefore, Date() < notBefore { return .chain }
        let status: KachatNames.IndexerAPI.StatusJSON
        do {
            status = try await Self.get(base, "/names/status")
        } catch {
            // One missed status check doesn't take a working indexer out of use, at launch
            // included, and a phone with no connection says nothing about it.
            if source != .chain, !Self.indexerIsDown(error) || !indexerOutageConfirmed() { return .indexer(base) }
            return .chain
        }
        guard status.registryCovenantId?.lowercased() == KachatNames.hex(m.registryCovenantId),
              status.synced != false else {
            return .chain
        }
        // Without a network position to compare with, the indexer's own "synced" is trusted.
        if let indexed = status.indexedDaa, let dag = try? await NodePoolService.shared.currentDagPoint(),
           dag.virtualDaaScore > indexed + Self.maxIndexerLagDaa {
            return .chain
        }
        return .indexer(base)
    }

    static func indexerBase() -> String? {
        let raw = AppSettings.load().kachatNamesIndexerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        return raw.hasSuffix("/") ? String(raw.dropLast()) : raw
    }

    // MARK: - Refresh

    /// Walks the chain forward (no indexer) or just marks fresh data (indexer). Safe to call often.
    /// Every refresh re-checks the source, so an indexer that fell behind is dropped and one that
    /// caught up is used again.
    ///
    /// `announce: false` (the automatic `refreshIfStale`) bumps `revision` - which reloads every
    /// screen keyed on it and re-checks identities - only when something may have changed: the
    /// walk applied a transaction, the source changed, the last refresh had failed, or the last
    /// bump is five minutes old (an indexer can't say whether anything changed). Pull to refresh
    /// and read-your-writes always announce.
    func refresh(announce: Bool = true) async {
        guard KachatNamesService.isLaunched else { return }
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let previousError = lastError
        let previousSource = source
        do {
            let m = try await prepare(forceSourceCheck: true)
            var walkedChanges = false
            if source == .chain {
                walkedChanges = try await walkShared(m)
            } else {
                walkStandbyCopyIfDue(m)
            }
            lastError = nil
            refreshedAt = Date()
            let quiet = !announce && !walkedChanges && source == previousSource && previousError == nil
                && Date().timeIntervalSince(revisionBumpedAt) < 300
            if !quiet {
                revision += 1
                revisionBumpedAt = Date()
            }
            // No name-event check any more: offers, sales and renewal news for your names are
            // the KaChat wallet app's since the .kachat market left this app (2026-10-24).
        } catch {
            let message = error.localizedDescription
            lastError = message
            // A failed refresh counts as an attempt too: `refreshIfStale` waits `maxAge` before
            // the next one, and screens that reload on `revision` (and refresh from there) are
            // only nudged when the error changed - a refusal can't turn into a refresh loop.
            refreshedAt = Date()
            if message != previousError {
                if !KachatNamesService.isRegistryUpgrading(error) {
                    AppLog.log("[KachatNames] registry refresh failed: %@", message)
                }
                revision += 1
            }
        }
    }

    /// Read-your-writes after this app's own transaction: refreshes until the registry shows it -
    /// an indexer that has indexed up to `daa` (the block it landed in), or a chain walk that has
    /// applied it - so every screen reloading on `revision` (Your Domains, the marketplace, the
    /// name) shows the change without being opened again. Gives up after 45 s.
    func refreshUntilIncludes(txId: String, daa: UInt64?) async {
        let deadline = Date().addingTimeInterval(45)
        repeat {
            await refresh()
            if await includes(txId: txId, daa: daa) { return }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        } while Date() < deadline
    }

    private func includes(txId: String, daa: UInt64?) async -> Bool {
        switch source {
        case .indexer(let base):
            guard let daa else { return true }
            guard let status: KachatNames.IndexerAPI.StatusJSON = try? await Self.get(base, "/names/status") else { return false }
            return (status.indexedDaa ?? 0) >= daa
        default:
            let id = txId.lowercased()
            return chainState?.applied.contains { $0.lowercased() == id } ?? false
        }
    }

    /// `refresh()` unless the last one is younger than `maxAge` seconds (lookups from typed names).
    func refreshIfStale(maxAge: TimeInterval = 60) async {
        if let at = refreshedAt, Date().timeIntervalSince(at) < maxAge { return }
        await refresh(announce: false)
    }

    /// One walk at a time: whoever comes while one runs waits for it.
    private func walkShared(_ m: KachatNames.Manifest) async throws -> Bool {
        if let walkTask { return try await walkTask.value }
        let task = Task { @MainActor in try await self.walk(m) }
        walkTask = task
        defer { walkTask = nil }
        return try await task.value
    }

    /// While the indexer answers, the chain copy is still kept up to date now and then, so the
    /// moment it stops answering the names are already here instead of a walk from the genesis
    /// away. Nothing is read from this copy until then. The first walk, the whole registry from
    /// its genesis, waits for a connection that isn't metered.
    private func walkStandbyCopyIfDue(_ m: KachatNames.Manifest) {
        let expensive = NetworkEpochMonitor.shared.isExpensivePath
        let defaultsKey = "kachat_names_standby_walked_\(m.network)"
        let last = standbyWalkedAt ?? (UserDefaults.standard.object(forKey: defaultsKey) as? Date)
        if let last, Date().timeIntervalSince(last) < (expensive ? 7200 : 1800) { return }
        if last == nil, expensive { return }
        guard walkTask == nil else { return }
        standbyWalkedAt = Date()
        UserDefaults.standard.set(Date(), forKey: defaultsKey)
        Task { @MainActor [weak self] in
            do {
                await self?.loadChainCopyIfNeeded(m)
                _ = try await self?.walkShared(m)
            } catch {
                AppLog.log("[KachatNames] standby walk of the registry failed: %@", error.localizedDescription)
            }
        }
    }

    /// True when the walk applied a transaction (or started over from the genesis).
    @discardableResult
    private func walk(_ m: KachatNames.Manifest) async throws -> Bool {
        var state = chainState ?? .atGenesis(m)
        var report = try await walkToTip(&state, m)
        // An inconsistent result (a stale UTXO, or gaps and names that don't tile the key
        // space) is walked again once from the genesis rather than kept.
        if report.stale || (try? state.checkInvariants()) == nil {
            AppLog.log("[KachatNames] the walked registry is inconsistent; walking again from the genesis")
            // nothing is answered from the bad copy, even if the walk below fails
            chainState?.reachedTip = nil
            chainState?.verifiedAt = nil
            state = .atGenesis(m)
            report = try await walkToTip(&state, m)
            try state.checkInvariants()
        }
        if report.reachedTip {
            state.reachedTip = true
            state.verifiedAt = KachatNames.nowMs()
        }
        if !report.applied.isEmpty {
            AppLog.log("[KachatNames] walked %d registry transaction(s) in %d round(s)", report.applied.count, report.rounds)
        }
        if !report.unresolved.isEmpty {
            AppLog.log("[KachatNames] %d spent registry UTXO(s) wait for the REST API to index their spend", report.unresolved.count)
        }
        // a network switch while this walked: the answer is the other network's
        guard preparedNetwork == m.network else { return false }
        let changed = !report.applied.isEmpty || chainState == nil
        chainState = state
        saveChainCopy(state)
        return changed
    }

    /// A long history takes more than one walk's rounds: keeps going, saving what it has between
    /// them, so a walk that fails later doesn't lose the part already read.
    private func walkToTip(_ state: inout KachatNames.RegistryState, _ m: KachatNames.Manifest) async throws -> KachatNames.RegistryState.WalkReport {
        var total = try await Self.walkOffMain(&state, m)
        var passes = 1
        while total.ranOutOfRounds, !total.stale, passes < Self.maxWalkPasses, preparedNetwork == m.network {
            chainState = state
            saveChainCopy(state)
            let next = try await Self.walkOffMain(&state, m)
            total.rounds += next.rounds
            total.applied += next.applied
            total.events += next.events
            total.unresolved = next.unresolved
            total.stale = next.stale
            total.reachedTip = next.reachedTip
            total.ranOutOfRounds = next.ranOutOfRounds
            passes += 1
        }
        return total
    }

    private static let maxWalkPasses = 20

    /// A first walk applies the registry's whole history, which is too much for the main thread.
    private nonisolated static func walkOffMain(
        _ state: inout KachatNames.RegistryState,
        _ m: KachatNames.Manifest
    ) async throws -> KachatNames.RegistryState.WalkReport {
        let start = state
        let (walked, report) = try await Task.detached(priority: .utility) { () -> (KachatNames.RegistryState, KachatNames.RegistryState.WalkReport) in
            var working = start
            let report = try await Self.walkOnce(&working, m)
            return (working, report)
        }.value
        state = walked
        return report
    }

    private nonisolated static func walkOnce(_ state: inout KachatNames.RegistryState, _ m: KachatNames.Manifest) async throws -> KachatNames.RegistryState.WalkReport {
        // the registry's gaps and names (registry v4 has no price record)
        let covenantIds: Set<String> = [KachatNames.hex(m.registryCovenantId)]
        return try await state.walk(
            manifest: m,
            address: { KachatNamesService.p2shAddress(script: $0) },
            live: { addresses in
                var out = Set<String>()
                var start = 0
                while start < addresses.count {
                    let chunk = Array(addresses[start..<min(start + 50, addresses.count)])
                    for u in try await NodePoolService.shared.getUtxosByAddresses(chunk) {
                        // A node reports the covenant id; the REST fallback cannot (nil). A UTXO
                        // carrying another id is not the registry's.
                        if let c = u.covenantId, !c.isEmpty, !covenantIds.contains(c.lowercased()) { continue }
                        out.insert("\(u.outpoint.transactionId.lowercased()):\(u.outpoint.index)")
                    }
                    start += 50
                }
                return out
            },
            transactions: { address, wanted in try await Self.restTransactions(address: address, spending: wanted) }
        )
    }

    /// Accepted transactions touching `address`, newest first (kaspa-rest-server), paged until
    /// every outpoint in `spending` has its spender, the history ends, or `restMaxPages` pages.
    /// One page is not enough: 50 dust payments to a registry address would hide the spend that
    /// moved it on, and the names behind it would never resolve (IOS-065).
    nonisolated static func restTransactions(address: String, spending wanted: Set<String>) async throws -> [KachatNames.TxView] {
        let base = AppSettings.load().kaspaRestAPIURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let root = base.hasSuffix("/") ? String(base.dropLast()) : base
        var out: [KachatNames.TxView] = []
        var missing = wanted
        for page in 0..<restMaxPages {
            guard let url = URL(string: "\(root)/addresses/\(address)/full-transactions?limit=\(restPageSize)&offset=\(page * restPageSize)&resolve_previous_outpoints=no") else {
                throw KachatNames.Failure("bad Kaspa REST API URL")
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw KachatNames.Failure("the Kaspa REST API answered \((response as? HTTPURLResponse)?.statusCode ?? 0) for \(address)")
            }
            guard let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { break }
            let txs = try list.compactMap { try KachatNames.TxView.fromREST($0) }
            out.append(contentsOf: txs)
            for tx in txs {
                for input in tx.inputs { missing.remove("\(KachatNames.hex(input.outpoint.txid)):\(input.outpoint.index)") }
            }
            if missing.isEmpty || list.count < restPageSize { break }
        }
        return out
    }

    nonisolated static let restPageSize = 50
    /// 1,000 transactions per address: past the newest dust anyone would pay to send
    nonisolated static let restMaxPages = 20

    /// Whether the REST API has seen `txId` accepted.
    static func isAccepted(txId: String) async -> Bool {
        let base = AppSettings.load().kaspaRestAPIURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: "\(base.hasSuffix("/") ? String(base.dropLast()) : base)/transactions/\(txId)?inputs=false&outputs=false&resolve_previous_outpoints=no"),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return (j["is_accepted"] as? Bool) == true
    }

    /// After a submit: wait (up to ~2 minutes) for the transaction to be accepted, then refresh.
    func refreshAfter(txId: String) {
        Task { @MainActor in
            for attempt in 0..<40 {
                try? await Task.sleep(nanoseconds: UInt64(attempt < 5 ? 2 : 3) * 1_000_000_000)
                if await Self.isAccepted(txId: txId) { break }
            }
            await refresh()
        }
    }

    // MARK: - Reads

    /// Before Kaspa goes to the owner a record names, a node has to hold that exact record: the
    /// P2SH address commits to the name and its owner, and the covenant id to the registry, so
    /// neither an indexer nor an out-of-date chain copy can pay anyone but the current owner.
    /// Throws if it doesn't, whichever source the record came from.
    func confirmOnChain(_ n: KachatNames.NameInfo) async throws {
        guard let fields = n.fields else { throw KachatNames.Failure("the indexer's record can't be checked") }
        let m = try await service.loadManifest()
        guard let address = KachatNamesService.p2shAddress(script: m.name.script(fields.encoded)) else {
            throw KachatNames.Failure("the name record has no address")
        }
        // nodes only: the REST fallback can't report a covenant id
        let utxos = try await NodePoolService.shared.getUtxosByAddresses([address], allowRestFallback: false)
        let txid = KachatNames.hex(n.outpoint.txid)
        let registry = KachatNames.hex(m.registryCovenantId)
        guard utxos.contains(where: {
            $0.outpoint.transactionId.lowercased() == txid && $0.outpoint.index == n.outpoint.index
                && $0.covenantId?.lowercased() == registry
        }) else {
            throw KachatNames.Failure("the chain doesn't hold that name record")
        }
    }

    func lookup(_ raw: String) async throws -> KachatNames.Lookup {
        try await prepare()
        let name = KachatNames.Codec.normalize(raw)
        try KachatNames.Codec.validate(name)
        if case .indexer(let base) = source,
           let j = try await fromIndexer(KachatNames.IndexerAPI.NameJSON.self, base, "/names/\(name)") {
            if let info = j.info(keyOf: Self.keyOf) { return .registered(info) }
            return .free(name: name, gap: j.gap?.info)
        }
        let st = try readChainState()
        if let n = st.name(name) { return .registered(KachatNames.RegistryState.info(n)) }
        return .free(name: name, gap: st.gap(containing: KachatNames.Codec.key(name)).map(KachatNames.RegistryState.info))
    }

    /// The indexer's answer, or nil once it has stopped answering (`indexerOutageConfirmed`): the
    /// registry then moves to the chain and the caller reads it from there. A single failure is
    /// thrown for the caller's own retry, and a 404 and the like are answers, thrown as they
    /// always were.
    private func fromIndexer<T: Decodable>(_ type: T.Type, _ base: String, _ path: String) async throws -> T? {
        do {
            let answer: T = try await Self.get(base, path)
            noteIndexerGaveData()
            return answer
        } catch {
            guard Self.indexerIsDown(error) else {
                indexerFailuresInARow = 0
                throw error
            }
            guard indexerOutageConfirmed() else { throw error }
            failOverToChain(after: error)
            return nil
        }
    }

    private func noteIndexerGaveData() {
        indexerFailuresInARow = 0
        indexerRetryNotBefore = nil
        failoverBackoff = 60
    }

    /// Counts a failed request; true from the third in a row within two minutes, so one timeout
    /// never moves the registry off a working indexer. Failures within five seconds of each other
    /// count once: a dropped connection fails everything in flight at the same moment.
    private func indexerOutageConfirmed() -> Bool {
        let now = Date()
        let sinceLast = now.timeIntervalSince(lastIndexerFailureAt)
        if sinceLast > 120 { indexerFailuresInARow = 0 }
        if indexerFailuresInARow == 0 || sinceLast >= 5 {
            lastIndexerFailureAt = now
            indexerFailuresInARow += 1
        }
        return indexerFailuresInARow >= 3
    }

    private nonisolated static func indexerIsDown(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if let failure = error as? KachatNames.Failure {
            let prefix = "the names indexer answered "
            guard failure.message.hasPrefix(prefix), let code = Int(failure.message.dropFirst(prefix.count)) else { return false }
            return code == 0 || code == 429 || code >= 500
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            // the phone has no connection: that says nothing about the indexer
            case .cancelled, .notConnectedToInternet, .dataNotAllowed: return false
            default: return true
            }
        }
        // a body it couldn't decode is still the indexer answering
        return false
    }

    /// The indexer stopped answering: the names are on the chain, so read them there from now on.
    /// The next refresh (once a minute while on the chain) goes back to it when it recovers.
    private func failOverToChain(after error: Error) {
        guard case .indexer = source, let m = service.manifest else { return }
        AppLog.log("[KachatNames] the indexer didn't answer (%@): reading the registry from the chain", error.localizedDescription)
        source = .chain
        indexerRetryNotBefore = Date().addingTimeInterval(failoverBackoff)
        failoverBackoff = min(failoverBackoff * 2, 600)
        Task { @MainActor [weak self] in
            await self?.loadChainCopyIfNeeded(m)
            await self?.refresh(announce: false)
        }
    }

    /// How old a walk that reached the live UTXOs may be for its copy to answer. On the chain
    /// the walk repeats every minute; a copy older than this says only what the registry was.
    private static let chainCopyMaxAgeMs: Int64 = 15 * 60 * 1000

    /// The chain copy, only while it holds the whole registry as it stands. Otherwise "not in
    /// here" says nothing, so a read fails (and whatever is saved keeps showing) rather than
    /// answering that a name is free or an address has none.
    private func readChainState() throws -> KachatNames.RegistryState {
        guard let st = chainState, st.reachedTip == true, let walkedAt = st.verifiedAt,
              KachatNames.nowMs() - walkedAt < Self.chainCopyMaxAgeMs else {
            Task { @MainActor [weak self] in await self?.refreshIfStale(maxAge: 30) }
            throw KachatNames.Failure("the registry is still being read from the chain")
        }
        return st
    }

    /// Which of `addresses` hold at least one .kachat name (active or in grace - the same set
    /// Your Domains lists, `heldNames`). Drives the "Contains domain" tag on Manage Addresses.
    /// Empty off testnet; an address whose lookup fails just isn't tagged.
    func ownersOfNames(among addresses: [String]) async -> Set<String> {
        guard KachatNamesService.isLaunched, !addresses.isEmpty else { return [] }
        if refreshedAt == nil { await refresh() }
        var owners = Set<String>()
        for address in addresses {
            guard let key = Self.keyOf(address),
                  let owned = try? await heldNames(owner: key),
                  !owned.isEmpty else { continue }
            owners.insert(address)
        }
        return owners
    }

    /// The names an owner still holds, oldest first: active ones and expired ones in grace (still
    /// renewable). A lapsed name is no longer theirs - it's in the marketplace's Reclaimable tab.
    /// Your Domains, its count on Profile and the "Contains domain" tag all show this set.
    func heldNames(owner: Data) async throws -> [KachatNames.NameInfo] {
        let grace = graceMs
        return try await names(owner: owner, includeInactive: true).filter { $0.status(graceMs: grace) != .lapsed }
    }

    /// Keeps a `heldNames` answer true as time passes: waits until the next of `names` lapses,
    /// then hands back the ones still held, until none is left to lapse (or the task is
    /// cancelled). A lapse is just the clock running out, so no registry change announces it.
    func dropLapsed(from names: [KachatNames.NameInfo], update: ([KachatNames.NameInfo]) -> Void) async {
        var held = names
        while let next = held.map({ $0.expiresAt + graceMs }).filter({ $0 > KachatNames.nowMs() }).min() {
            let wait = UInt64(max(0, next - KachatNames.nowMs()) + 500) * 1_000_000
            try? await Task.sleep(nanoseconds: wait)
            if Task.isCancelled { return }
            let grace = graceMs
            held = held.filter { $0.status(graceMs: grace) != .lapsed }
            update(held)
        }
    }

    /// The names an owner holds, oldest first; `includeInactive` adds grace and lapsed ones.
    func names(owner: Data, includeInactive: Bool) async throws -> [KachatNames.NameInfo] {
        try await prepare()
        var answered: [KachatNames.NameInfo]?
        if case .indexer(let base) = source {
            guard let address = Self.address(of: owner) else { return [] }
            let j = try await fromIndexer(KachatNames.IndexerAPI.NamesJSON.self, base, "/names/by-owner/\(address)?includeInactive=\(includeInactive)")
            answered = j?.names.compactMap { $0.info(keyOf: Self.keyOf) }
        }
        let all: [KachatNames.NameInfo]
        if let answered {
            all = answered
        } else {
            let ownerHex = KachatNames.hex(owner)
            all = try readChainState().names.filter { $0.owner == ownerHex }.map(KachatNames.RegistryState.info)
        }
        let grace = graceMs
        return all
            .filter { includeInactive || $0.status(graceMs: grace) == .active }
            .sorted { ($0.registeredAt ?? .max, $0.name) < ($1.registeredAt ?? .max, $1.name) }
    }

    /// The offers `buyer` made that are still open.
    func myOffers(buyer: Data) async throws -> [KachatNames.OfferInfo] {
        try await prepare()
        if case .indexer(let base) = source {
            guard let address = Self.address(of: buyer) else { return [] }
            if let j = try await fromIndexer(KachatNames.IndexerAPI.OffersJSON.self, base, "/offers/by-buyer/\(address)") {
                return j.offers.compactMap { $0.info(name: nil, keyOf: Self.keyOf) }
            }
        }
        let me = KachatNames.hex(buyer)
        return try readChainState().offers.filter { $0.buyer == me }.map(KachatNames.RegistryState.info)
    }


    // MARK: - Identity and profiles

    /// The label and profile of an address (KACHAT_NAMES.md section 7). Without an indexer the
    /// label comes from the walked names and the profile from the address's own record on the
    /// chain (`chainProfile`); this wallet's own last write comes first.
    func identity(address: String) async throws -> KachatNames.Identity {
        let address = address.lowercased()
        // No registry on this network yet (mainnet): no names or label, only the profile.
        guard KachatNamesService.isLaunched else { return try await profileOnlyIdentity(address: address) }
        try await prepare()
        if case .indexer(let base) = source,
           let j = try await fromIndexer(KachatNames.IndexerAPI.IdentityJSON.self, base, "/identity/\(address)") {
            return j.identity
        }
        guard let key = Self.keyOf(address) else { return KachatNames.Identity(address: address, label: nil, names: [], profile: nil) }
        // held names: a name in grace still labels and resolves to its owner
        let owned = try await heldNames(owner: key)
        var profile = ownProfile(for: address)?.profile
        if profile == nil { profile = await chainProfile(address: address) }
        let label = KachatNames.label(owned: owned, primaryName: profile?.primaryName, graceMs: graceMs)
        return KachatNames.Identity(address: address, label: label, names: owned.map(\.name), profile: profile)
    }

    /// The address's profile with no indexer: its latest record on the chain, looked for at most
    /// every half hour. Not found (too far back in a busy address's history, or the REST API not
    /// answering) keeps the profile already saved, since that is no proof it was ever cleared.
    private func chainProfile(address: String) async -> KachatNames.Profile? {
        let saved = identities[address]?.identity.profile
        if let at = chainProfileCheckedAt[address], Date().timeIntervalSince(at) < Self.chainProfileRecheck { return saved }
        guard chainProfileLookups < Self.maxChainProfileLookups else { return saved }
        chainProfileLookups += 1
        defer { chainProfileLookups -= 1 }
        chainProfileCheckedAt[address] = Date()
        guard let record = await Self.latestProfileRecord(address: address) else { return saved }
        // the REST API's listing says who spent the coins; only the input's signature proves it
        let proof = await ChatService.shared.provenSender(of: record.txId, expected: address, myAddress: "")
        return proof == .proven ? record.profile : saved
    }

    private static let maxChainProfileLookups = 4

    private static let chainProfileRecheck: TimeInterval = 1800
    /// Two pages, newest first: profile records are rare, and this runs per person shown.
    private nonisolated static let profilePages = 2
    private nonisolated static let profilePageSize = 100

    /// The newest `kchat:1:profile:` record `address` wrote (KACHAT_NAMES.md section 7): one of
    /// its inputs is the address's and one of its outputs pays back to it, so only the key holder
    /// can write one. The caller checks the input's signature.
    private nonisolated static func latestProfileRecord(address: String) async -> (txId: String, profile: KachatNames.Profile)? {
        let base = AppSettings.load().kaspaRestAPIURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let root = base.hasSuffix("/") ? String(base.dropLast()) : base
        let marker = KachatNames.hex(Data("kchat:1:profile:".utf8))
        for page in 0..<profilePages {
            guard let url = URL(string: "\(root)/addresses/\(address)/full-transactions?limit=\(profilePageSize)&offset=\(page * profilePageSize)&resolve_previous_outpoints=light&fields=transaction_id,is_accepted,payload,inputs,outputs,block_time"),
                  let (data, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
            for tx in list {
                if let accepted = tx["is_accepted"] as? Bool, !accepted { continue }
                guard let txId = tx["transaction_id"] as? String,
                      let payload = (tx["payload"] as? String)?.lowercased(), payload.hasPrefix(marker),
                      ((tx["inputs"] as? [[String: Any]]) ?? []).contains(where: { ($0["previous_outpoint_address"] as? String)?.lowercased() == address }),
                      ((tx["outputs"] as? [[String: Any]]) ?? []).contains(where: { ($0["script_public_key_address"] as? String)?.lowercased() == address }),
                      let json = Data(hexString: String(payload.dropFirst(marker.count))),
                      json.count <= KachatNames.Codec.maxProfileJSONBytes,
                      let profile = try? JSONDecoder().decode(KachatNames.Profile.self, from: json),
                      profile.v == 1 else { continue }
                return (txId, profile.sanitized())
            }
            if list.count < profilePageSize { break }
        }
        return nil
    }

    /// An address's profile where the network has no registry yet (mainnet): the indexer's
    /// `GET /profiles/{address}`, falling back to the record this device last wrote for its own
    /// address. The indexer answers 503 until it follows profiles on this network
    /// (kachat-indexer docs/KACHAT_PROFILES.md); then only this wallet's own profile shows.
    private func profileOnlyIdentity(address: String) async throws -> KachatNames.Identity {
        if let own = ownProfile(for: address)?.profile {
            return KachatNames.Identity(address: address, label: nil, names: [], profile: own)
        }
        // An indexer without profiles on this network answers 503 for every address: one such
        // answer pauses all profile lookups for ten minutes instead of one request per contact.
        guard let base = Self.indexerBase(), (profilesUnavailableUntil ?? .distantPast) < Date() else {
            return KachatNames.Identity(address: address, label: nil, names: [], profile: await chainProfile(address: address))
        }
        do {
            let j: KachatNames.IndexerAPI.ProfileJSON = try await Self.get(base, "/profiles/\(address)")
            return KachatNames.Identity(address: address, label: nil, names: [], profile: j.profile?.sanitized())
        } catch {
            if (error as? KachatNames.Failure)?.message.hasSuffix("answered 503") == true {
                profilesUnavailableUntil = Date().addingTimeInterval(600)
            }
            guard Self.indexerIsDown(error) else { throw error }
            return KachatNames.Identity(address: address, label: nil, names: [], profile: await chainProfile(address: address))
        }
    }

    /// The address's `.kachat` identity as the app shows it, from a cache that fills in the
    /// background: callable from any view body (on mainnet, profile only). An answer is
    /// re-asked once the registry moved on or after five minutes, and this wallet's own saved
    /// profile always wins for its own address. When an answer lands, views that read contact
    /// names re-render (ContactsManager is told).
    // MARK: - People shown as an address

    private var unnamedSweepStarted = false
    private var unnamedSweepRunning = false

    /// While the app is open, once a minute: everyone the app is showing as an address - a contact
    /// with no name you gave them (chat or Address Book) and no .kachat name known - may be asked
    /// again whether they have one. Never asked yet, or the last lookup failed (the registry
    /// still loading at launch): this pass. A "no name" answer backs off - asked again after 1,
    /// then 5, 15 and 60 minutes - and sooner (after a minute) only once the registry has seen
    /// new transactions (`revision`), since a name only appears through one (IOS-087). Started
    /// once, at launch.
    func startUnnamedIdentitySweep() {
        guard !unnamedSweepStarted else { return }
        unnamedSweepStarted = true
        Task { @MainActor [weak self] in
            // the first pass once the app has settled after launch
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            while let self {
                if UIApplication.shared.applicationState == .active {
                    // on the chain: keep up with it, and go back to the indexer once it recovers
                    if self.source == .chain { await self.refreshIfStale(maxAge: 55) }
                    await self.refreshUnnamedIdentities()
                }
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
    }

    private func refreshUnnamedIdentities() async {
        guard KachatNamesService.profilesEnabled, !unnamedSweepRunning,
              let me = WalletManager.shared.currentWallet?.publicAddress.lowercased() else { return }
        unnamedSweepRunning = true
        defer { unnamedSweepRunning = false }
        let book = AddressBookManager.shared
        var targets: [String] = []
        let byRecency = ContactsManager.shared.contacts.sorted {
            ($0.lastMessageAt ?? .distantPast) > ($1.lastMessageAt ?? .distantPast)
        }
        for contact in byRecency {
            let key = contact.address.lowercased()
            guard key != me, contact.assignedName == nil, book.entry(for: key)?.customName == nil,
                  NetworkType(address: key) != nil, NetworkType.isOnActiveNetwork(key) else { continue }
            if let entry = identities[key] {
                if entry.identity.label != nil { continue }
                let age = Date().timeIntervalSince(entry.at)
                let backoff = Self.unnamedBackoff[min(unnamedAnswers[key] ?? 0, Self.unnamedBackoff.count - 1)]
                let registryMoved = entry.revision != revision && age > 60
                if age < backoff, !registryMoved { continue }
            }
            targets.append(key)
        }
        guard !targets.isEmpty else { return }
        // One batch for everyone due (the indexer's /identity/batch), so a pass is a single
        // request however many contacts are unnamed - and nobody waits behind the 40-cap.
        if let found = await identitiesBatch(targets) {
            var anyChanged = false
            for key in targets {
                guard let identity = found[key] else {
                    // not in the answer (the indexer skipped it): a miss, asked again in a minute
                    identityMisses[key] = Date()
                    continue
                }
                identityMisses[key] = nil
                if storeFetchedIdentity(identity, for: key) { anyChanged = true }
                // one more "no name" in a row backs the next ask off further
                unnamedAnswers[key] = identity.label == nil ? (unnamedAnswers[key] ?? 0) + 1 : nil
            }
            if anyChanged {
                ContactsManager.shared.objectWillChange.send()
                ContactsManager.shared.scheduleSharedNameSync()
            }
            return
        }
        // No batch (the chain walker - local lookups - or an indexer without the endpoint yet):
        // four at a time, the people you talk to most recently first.
        let due = Array(targets.prefix(40))
        var start = 0
        while start < due.count {
            guard UIApplication.shared.applicationState == .active else { return }
            let slice = due[start..<min(start + 4, due.count)]
            start += slice.count
            // per address: nil when the lookup failed, else whether the answer has no name
            let answers = await withTaskGroup(of: (String, Bool?).self) { group in
                for key in slice {
                    group.addTask { (key, await self.refreshIdentity(address: key).map { $0.label == nil }) }
                }
                var collected: [(String, Bool?)] = []
                for await answer in group { collected.append(answer) }
                return collected
            }
            for (key, unnamed) in answers {
                guard let unnamed else { continue }
                unnamedAnswers[key] = unnamed ? (unnamedAnswers[key] ?? 0) + 1 : nil
            }
        }
    }

    /// How long a "no name" answer is trusted by the sweep, by how many came in a row.
    private static let unnamedBackoff: [TimeInterval] = [60, 300, 900, 3600]
    /// "No name" answers in a row, per address (in memory: a relaunch starts over at a minute).
    private var unnamedAnswers: [String: Int] = [:]

    /// Looks the address's identity up now, whatever the cache holds (User Info > Rescan
    /// Profile), and stores the answer for every view that reads `cachedIdentity`.
    @discardableResult
    func refreshIdentity(address: String) async -> KachatNames.Identity? {
        guard KachatNamesService.profilesEnabled else { return nil }
        let key = address.lowercased()
        guard NetworkType(address: key) != nil, NetworkType.isOnActiveNetwork(key),
              let found = try? await identity(address: key) else { return nil }
        identityMisses[key] = nil
        if storeFetchedIdentity(found, for: key) {
            ContactsManager.shared.objectWillChange.send()
            ContactsManager.shared.scheduleSharedNameSync()
        }
        return found
    }

    /// Files a fetched identity in the cache; true when it changed (the caller then tells
    /// ContactsManager, once per batch rather than per address). An unchanged answer only
    /// stamps the entry fresh.
    private func storeFetchedIdentity(_ found: KachatNames.Identity, for key: String) -> Bool {
        if identities[key]?.identity != found {
            objectWillChange.send()
            identities[key] = CachedIdentity(identity: found, revision: revision, at: Date())
            persistIdentities()
            return true
        }
        identities[key]?.revision = revision
        identities[key]?.at = Date()
        return false
    }

    /// Everyone at once: `POST /identity/batch` (one request and two set queries on the indexer,
    /// against one GET per address), keyed back by lowercased address. nil when the source is
    /// the chain walker (each lookup is local anyway) or the indexer doesn't serve the endpoint
    /// yet - the caller falls back to per-address lookups.
    private func identitiesBatch(_ addresses: [String]) async -> [String: KachatNames.Identity]? {
        guard KachatNamesService.isLaunched, !addresses.isEmpty else { return nil }
        guard (try? await prepare()) != nil, case .indexer(let base) = source else { return nil }
        struct BatchBody: Encodable { let addresses: [String] }
        struct BatchJSON: Decodable { let identities: [String: KachatNames.IndexerAPI.IdentityJSON] }
        var out: [String: KachatNames.Identity] = [:]
        // the indexer takes at most 200 per call
        for chunk in stride(from: 0, to: addresses.count, by: 200).map({ Array(addresses[$0..<min($0 + 200, addresses.count)]) }) {
            do {
                let answer: BatchJSON = try await Self.post(base, "/identity/batch", BatchBody(addresses: chunk))
                for (address, identity) in answer.identities {
                    out[address.lowercased()] = identity.identity
                }
            } catch {
                if Self.indexerIsDown(error), indexerOutageConfirmed() { failOverToChain(after: error) }
                return nil
            }
        }
        return out
    }

    func cachedIdentity(for address: String) -> KachatNames.Identity? {
        guard KachatNamesService.profilesEnabled else { return nil }
        let key = address.lowercased()
        guard NetworkType(address: key) != nil, NetworkType.isOnActiveNetwork(key) else { return nil }
        let entry = identities[key]
        // Five minutes old, or older than a minute once the registry changed: every refresh
        // bumps `revision`, and re-asking for every address on screen after each one cost a
        // request per avatar and redrew the whole list as each answer came back.
        let stale = entry.map {
            let age = Date().timeIntervalSince($0.at)
            return age > 300 || ($0.revision != revision && age > 60)
        } ?? true
        // a failed lookup (the registry still loading, a network blip) is asked again after a
        // minute, not five - until then the person shows as their address
        let missedRecently = identityMisses[key].map { Date().timeIntervalSince($0) < 60 } ?? false
        if stale, !missedRecently, !identityLookups.contains(key) {
            identityLookups.insert(key)
            Task { [weak self] in
                guard let self else { return }
                let found = try? await self.identity(address: key)
                self.identityLookups.remove(key)
                guard let found else {
                    self.identityMisses[key] = Date()
                    return
                }
                self.identityMisses[key] = nil
                if self.storeFetchedIdentity(found, for: key) {
                    ContactsManager.shared.objectWillChange.send()
                    ContactsManager.shared.scheduleSharedNameSync()
                }
            }
        }
        var identity = entry?.identity
        if let own = ownProfile(for: key)?.profile {
            identity = identity ?? KachatNames.Identity(address: key, label: nil, names: [], profile: nil)
            identity?.profile = own
        }
        return identity
    }

    // MARK: Profile cache on disk

    private nonisolated static let identitiesFile = "identities.json"
    private static let identitiesKeep = 1000

    /// The identities cached on the last run. Each is marked stale (an impossible revision), so it
    /// is shown at once and re-fetched on first use.
    private nonisolated static func loadIdentities() -> [String: CachedIdentity] {
        guard let data = KachatProfileCache.read(identitiesFile),
              let stored = try? JSONDecoder().decode([String: CachedIdentity].self, from: data) else { return [:] }
        return stored.mapValues { var c = $0; c.revision = -1; return c }
    }

    private func persistIdentities() {
        guard !identitiesPersistScheduled else { return }
        identitiesPersistScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self else { return }
            self.identitiesPersistScheduled = false
            self.writeIdentities()
        }
    }

    private func writeIdentities() {
        var keep = identities
        if keep.count > Self.identitiesKeep {
            for (k, _) in keep.sorted(by: { $0.value.at < $1.value.at }).prefix(keep.count - Self.identitiesKeep) { keep[k] = nil }
        }
        guard let data = try? JSONEncoder().encode(keep) else { return }
        Task.detached(priority: .utility) { KachatProfileCache.write(Self.identitiesFile, data) }
    }

    /// Settings > Storage > Cache > Profiles: forgets every cached identity (on disk too). Views
    /// re-fetch them as they need them. This device's own saved profile record is not cache and
    /// stays.
    func clearProfileCache() {
        objectWillChange.send()
        identities = [:]
        identityMisses = [:]
        identityLookups = []
        KachatProfileCache.remove(Self.identitiesFile)
        revision += 1
        ContactsManager.shared.objectWillChange.send()
    }

    /// The profile record this device last wrote for `address`.
    func ownProfile(for address: String) -> OwnProfile? {
        let address = address.lowercased()
        if let p = ownProfiles[address] { return p }
        guard !ownProfileMisses.contains(address) else { return nil }
        guard let data = Self.readFile(Self.profileFile(address), network: Self.profileNetwork(address)), let p = try? JSONDecoder().decode(OwnProfile.self, from: data) else {
            ownProfileMisses.insert(address)
            return nil
        }
        ownProfiles[address] = p
        return p
    }

    func noteOwnProfile(_ profile: KachatNames.Profile, address: String, txId: String) {
        storeOwnProfile(OwnProfile(address: address.lowercased(), profile: profile.sanitized(), txId: txId, at: KachatNames.nowMs()))
    }

    private func storeOwnProfile(_ record: OwnProfile) {
        ownProfiles[record.address] = record
        ownProfileMisses.remove(record.address)
        if let data = try? JSONEncoder().encode(record) {
            Self.writeFile(Self.profileFile(record.address), data, network: Self.profileNetwork(record.address))
        }
        revision += 1
    }

    /// Brings this device's copy of its own profile up to date with the chain, so a profile saved
    /// on another device - KaChat for Android or Desktop, another iPhone - shows here too, and the
    /// editor starts from it instead of overwriting it with an older one. The indexer's record
    /// (`GET /profiles/{address}`, every network) is adopted when this device has none (a fresh
    /// import) or when it is a different, newer record. The local copy stays when it is the same
    /// record or newer (the indexer hasn't seen this device's latest save yet).
    func syncOwnProfile(address: String) async {
        guard KachatNamesService.profilesEnabled, let base = Self.indexerBase() else { return }
        let key = address.lowercased()
        guard NetworkType.isOnActiveNetwork(key),
              let j: KachatNames.IndexerAPI.ProfileJSON = try? await Self.get(base, "/profiles/\(key)"),
              j.address.lowercased() == key, let remote = j.profile?.sanitized(), let txId = j.txId else { return }
        if let local = ownProfile(for: key) {
            guard local.txId != txId, let at = j.updatedAt, at > local.at else { return }
        }
        AppLog.log("[KachatNames] own profile updated from the chain (saved on another device): %@", String(txId.prefix(12)))
        storeOwnProfile(OwnProfile(address: key, profile: remote, txId: txId, at: j.updatedAt ?? KachatNames.nowMs()))
    }

    // MARK: - Addresses

    nonisolated static func address(of xonly: Data) -> String? {
        guard xonly.count == 32 else { return nil }
        return KaspaAddress(hrp: KachatNamesService.addressPrefix, type: .pubKey, payload: xonly).address
    }

    /// The x-only key of a Schnorr address on the network the app runs on.
    nonisolated static func keyOf(_ address: String) -> Data? {
        guard let a = KaspaAddress(address: address.lowercased()), a.hrp == KachatNamesService.addressPrefix, a.type == .pubKey, a.payload.count == 32 else { return nil }
        return a.payload
    }

    // MARK: - HTTP

    private nonisolated static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 25
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    /// Off the main actor: listings, history and activity answers decode on the shared pool.
    private nonisolated static func get<T: Decodable>(_ base: String, _ path: String) async throws -> T {
        guard let url = URL(string: base + path) else { throw KachatNames.Failure("bad indexer URL") }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            if code == 404 { throw KachatNames.Failure("not found") }
            throw KachatNames.Failure("the names indexer answered \(code)")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Off the main actor, like `get`: a JSON POST to the names indexer.
    private nonisolated static func post<Body: Encodable, T: Decodable>(_ base: String, _ path: String, _ body: Body) async throws -> T {
        guard let url = URL(string: base + path) else { throw KachatNames.Failure("bad indexer URL") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            if code == 404 { throw KachatNames.Failure("not found") }
            throw KachatNames.Failure("the names indexer answered \(code)")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Cache files (Application Support/KachatNames/<network>/)

    private nonisolated static func directory(network: String = KachatNamesService.networkName) -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("KachatNames", isDirectory: true).appendingPathComponent(network, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    nonisolated static func readFile(_ name: String, network: String = KachatNamesService.networkName) -> Data? {
        guard let dir = directory(network: network) else { return nil }
        return try? Data(contentsOf: dir.appendingPathComponent(name))
    }

    nonisolated static func writeFile(_ name: String, _ data: Data, network: String = KachatNamesService.networkName) {
        guard let dir = directory(network: network) else { return }
        try? data.write(to: dir.appendingPathComponent(name), options: .atomic)
    }

    /// The cache folder an address's own profile lives in: its network's (testnet keeps the
    /// registry's folder, so profiles saved before mainnet profiles existed are still found).
    private static func profileNetwork(_ address: String) -> String {
        NetworkType(address: address) == .mainnet ? "mainnet" : "testnet-10"
    }

    static func walletSuffix(_ address: String) -> String {
        KeychainService.walletHashSuffix(address.lowercased())
    }

    private static func profileFile(_ address: String) -> String { "profile-\(walletSuffix(address)).json" }

    private nonisolated static func loadCache(_ m: KachatNames.Manifest) -> KachatNames.RegistryState? {
        guard let data = readFile("registry.json"),
              let st = try? JSONDecoder().decode(KachatNames.RegistryState.self, from: data),
              st.matches(m), (try? st.checkInvariants()) != nil else { return nil }
        return st
    }

    private nonisolated static func saveCache(_ st: KachatNames.RegistryState) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(st) { writeFile("registry.json", data) }
    }
}

// MARK: - Social profile: avatar, banner and bio (looked up on the device)

/// The profile cache folder (Caches/KachatProfiles): what the app knows about people's profiles -
/// their identity records and the avatars, banners and bios looked up from their social links.
/// Rebuilt on demand, so it lives in Caches and is measured and cleared by Settings > Storage >
/// Cache > Profiles (with the avatar and banner images, `KNSProfileImages`).
enum KachatProfileCache {
    static var directory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("KachatProfiles", isDirectory: true)
    }

    static func read(_ name: String) -> Data? {
        guard let url = directory?.appendingPathComponent(name) else { return nil }
        return try? Data(contentsOf: url)
    }

    static func write(_ name: String, _ data: Data) {
        guard let dir = directory else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: dir.appendingPathComponent(name), options: .atomic)
    }

    static func remove(_ name: String) {
        guard let url = directory?.appendingPathComponent(name) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

/// Turns a profile's social link (`KachatNames.SocialSource`) into what that platform shows right
/// now - avatar, banner, bio - and caches the answer on this device; no indexer involved.
///
/// The cache holds the picture URLs and the bio; `KNSAvatarView` / `KNSBannerImageView` download
/// and keep the images. An answer is fresh for 5 days; a stale one is still shown while it is
/// looked up again. When the platform answers but no longer shows something (taken down, account
/// gone), it is dropped at once, so the platform's moderation carries over. When the platform
/// can't be reached, the last answer stays.
@MainActor
final class KachatSocialImageResolver: ObservableObject {
    static let shared = KachatSocialImageResolver()

    private struct Entry: Codable {
        var profile: KachatNames.SocialProfile
        var checkedAt: Date
    }

    /// The cache file in `KachatProfileCache` (it lived in UserDefaults before 2026-10-07).
    private static let cacheFile = "social.json"
    private static let legacyDefaultsKey = "kachat_social_profile_cache"
    /// Avatars, banners and bios are looked up afresh once their answer is 5 days old, so an
    /// updated profile reaches everyone eventually (the last answer shows meanwhile).
    private static let freshFor: TimeInterval = 5 * 24 * 3600
    private static let maxEntries = 500
    /// The link-preview crawler user agent: X, TikTok and others serve their Open Graph tags to it.
    private static let crawlerAgent = "facebookexternalhit/1.1"
    /// A desktop browser: YouTube's desktop channel page carries the banner in plain form (the
    /// mobile page escapes it); GitHub's API wants a User-Agent.
    private static let browserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    /// Not `@Published`: a re-check that finds the same profile only stamps `checkedAt`, and
    /// that must not redraw every avatar on screen. `objectWillChange` is sent by hand when a
    /// profile really changes.
    private var entries: [String: Entry] = [:]
    private var inFlight: [String: Task<Lookup, Never>] = [:]
    /// Links a view body already started a lookup for: `profile(for:)` runs on every redraw of
    /// every avatar, and must start one lookup, not one per redraw.
    private var requested: Set<String> = []
    /// When a link's platform last couldn't be reached: not asked again for ten minutes, so an
    /// unreachable platform isn't hit again on every redraw.
    private var unreachableAt: [String: Date] = [:]
    private static let unreachableRetry: TimeInterval = 600
    private var persistScheduled = false

    private init() {
        if let data = KachatProfileCache.read(Self.cacheFile),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = decoded
        } else if let data = UserDefaults.standard.data(forKey: Self.legacyDefaultsKey),
                  let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            // moved out of UserDefaults into the measurable, clearable profile cache folder
            entries = decoded
            KachatProfileCache.write(Self.cacheFile, data)
        }
        UserDefaults.standard.removeObject(forKey: Self.legacyDefaultsKey)
        // Answers with nothing at all are looked up again once: earlier builds cached FxTwitter's
        // wrong "User not found" as an account with no avatar, banner or bio for a day.
        if !UserDefaults.standard.bool(forKey: Self.emptyRecheckKey) {
            entries = entries.filter { $0.value.profile != KachatNames.SocialProfile() }
            UserDefaults.standard.set(true, forKey: Self.emptyRecheckKey)
        }
    }

    private static let emptyRecheckKey = "kachat_social_empty_rechecked_v1"

    /// Settings > Storage > Cache > Profiles: forgets every looked-up avatar, banner and bio;
    /// they are looked up again when next shown.
    func clearAll() {
        objectWillChange.send()
        entries = [:]
        requested = []
        unreachableAt = [:]
        inFlight.values.forEach { $0.cancel() }
        inFlight = [:]
        KachatProfileCache.remove(Self.cacheFile)
    }

    /// The stored answer for `source`, however old - read only, no lookup started. The profile
    /// editor's preview rows use it: a Form rebuilds rows on scroll, and one scrolled back in
    /// must show its answer again at once instead of debouncing and looking it up afresh.
    func cachedProfile(_ source: KachatNames.SocialSource) -> KachatNames.SocialProfile? {
        entries[source.link]?.profile
    }

    /// The cached profile for `link`, starting a lookup when there is none or it is stale.
    /// Views read this in `body`; the published cache re-renders them when the lookup lands.
    func profile(for link: String?) -> KachatNames.SocialProfile? {
        guard let link, let source = KachatNames.SocialSource(link: link, for: .avatar) else { return nil }
        let key = source.link
        let entry = entries[key]
        let stale = entry.map { Date().timeIntervalSince($0.checkedAt) > Self.freshFor } ?? true
        let unreachableRecently = unreachableAt[key].map { Date().timeIntervalSince($0) < Self.unreachableRetry } ?? false
        if stale, !unreachableRecently, inFlight[key] == nil, !requested.contains(key) {
            requested.insert(key)
            Task {
                _ = await self.resolve(source, maxAge: Self.freshFor)
                self.requested.remove(key)
            }
        }
        return entry?.profile
    }

    /// Looks these profile links up again now, whatever the cache holds (User Info > Rescan
    /// Profile): an avatar, banner or bio changed on the platform shows at once. Returns the
    /// fresh answers by link.
    func rescan(_ links: [String?]) async -> [String: KachatNames.SocialProfile] {
        var answers: [String: KachatNames.SocialProfile] = [:]
        for link in Set(links.compactMap { $0 }) {
            guard let source = KachatNames.SocialSource(link: link, for: .avatar) else { continue }
            unreachableAt[source.link] = nil
            if let profile = await resolve(source, maxAge: 0).profile { answers[link] = profile }
        }
        return answers
    }

    /// What a lookup came back with.
    enum Lookup: Equatable {
        /// The platform answered (possibly with nothing: taken down, account gone).
        case answered(KachatNames.SocialProfile)
        /// It couldn't be reached in time; the last answer this device had, if any.
        case unreachable(KachatNames.SocialProfile?)

        var profile: KachatNames.SocialProfile? {
            switch self {
            case .answered(let p): return p
            case .unreachable(let p): return p
            }
        }
    }

    /// Hard limit for one lookup, every request and fallback included: a preview never spins
    /// longer than this. Each step has its own shorter timeout (`fetch(timeout:)`), so a slow
    /// first source can't use up the time the next one needs.
    private static let deadline: UInt64 = 20_000_000_000

    /// Looks the profile up now (the editor's preview), sharing a lookup in flight.
    @discardableResult
    func resolve(_ source: KachatNames.SocialSource, maxAge: TimeInterval = 300) async -> Lookup {
        let key = source.link
        // A recent answer is the answer: three fields on one account cost one request.
        if let entry = entries[key], Date().timeIntervalSince(entry.checkedAt) < maxAge {
            return .answered(entry.profile)
        }
        if let running = inFlight[key] { return await running.value }
        let task = Task<Lookup, Never> { [weak self] in
            let started = Date()
            let outcome = await Self.withDeadline { await Self.lookUp(source) }
            AppLog.log("[KachatSocial] %@ %@ in %.1fs", source.platform.rawValue,
                       outcome == nil ? "unreachable" : "answered", Date().timeIntervalSince(started))
            guard let self else { return .unreachable(nil) }
            guard let answered = outcome else {
                self.unreachableAt[key] = Date()
                return .unreachable(self.entries[key]?.profile) // keep the last answer
            }
            self.unreachableAt[key] = nil
            if self.entries[key]?.profile != answered { self.objectWillChange.send() }
            self.entries[key] = Entry(profile: answered, checkedAt: Date())
            self.persist()
            return .answered(answered)
        }
        inFlight[key] = task
        let value = await task.value
        inFlight[key] = nil
        return value
    }

    /// `work`'s result, or nil once the deadline passes (the work is cancelled).
    private nonisolated static func withDeadline(_ work: @escaping @Sendable () async -> KachatNames.SocialProfile?) async -> KachatNames.SocialProfile? {
        await withTaskGroup(of: KachatNames.SocialProfile??.self) { group in
            group.addTask { .some(await work()) }
            group.addTask {
                try? await Task.sleep(nanoseconds: deadline)
                return .none
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? nil
        }
    }

    /// One disk write for a burst of answers, off the main thread.
    private func persist() {
        guard !persistScheduled else { return }
        persistScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self else { return }
            self.persistScheduled = false
            self.writeEntries()
        }
    }

    private func writeEntries() {
        if entries.count > Self.maxEntries {
            let oldest = entries.sorted { $0.value.checkedAt < $1.value.checkedAt }.prefix(entries.count - Self.maxEntries)
            for (k, _) in oldest { entries[k] = nil }
        }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        let file = Self.cacheFile
        Task.detached(priority: .utility) { KachatProfileCache.write(file, data) }
    }

    /// The platform's answer (possibly empty: taken down, account gone), or nil when it
    /// couldn't be reached or answered with an error - nothing is known then.
    private nonisolated static func lookUp(_ source: KachatNames.SocialSource) async -> KachatNames.SocialProfile? {
        typealias S = KachatNames.SocialSource
        switch source.platform {
        case .discord:
            guard let url = URL(string: "https://discord.com/api/v10/invites/\(source.handle)"),
                  let (data, status) = await fetch(url, agent: browserAgent) else { return nil }
            if status == 404 { return KachatNames.SocialProfile() }
            guard status == 200 else { return nil }
            return KachatNames.SocialProfile(avatar: S.discordImage(fromInviteJSON: data, kind: .avatar),
                                             banner: S.discordImage(fromInviteJSON: data, kind: .banner),
                                             bio: S.discordDescription(fromInviteJSON: data))
        case .x:
            // FxTwitter first: one small JSON answer with avatar, banner and bio. X's own page
            // (served to link-preview crawlers) is the fallback, and unavatar.io the last resort
            // for the avatar alone. Each step's outcome is logged: a phone network can be
            // challenged or rate-limited where a desktop is not.
            if let url = URL(string: "https://api.fxtwitter.com/\(source.handle)") {
                let answer = await fetch(url, agent: browserAgent, timeout: 5)
                // Only a profile is taken from FxTwitter. Its "User not found" is not final: it
                // says that for real accounts too (@Curiousbeing99, 2026-10-07), so X's own page
                // below decides whether the account is gone.
                if let (data, status) = answer, status == 200,
                   let p = S.fxTwitterProfile(fromJSON: data), p != KachatNames.SocialProfile() {
                    return p
                }
                AppLog.log("[KachatSocial] x %@: FxTwitter %@", source.handle,
                           answer.map { "HTTP \($0.1)" } ?? "no answer")
            }
        case .github:
            guard let url = URL(string: "https://api.github.com/users/\(source.handle)"),
                  let (data, status) = await fetch(url, agent: browserAgent) else { return nil }
            if status == 404 { return KachatNames.SocialProfile() }
            guard status == 200 else { return nil }
            let gh = S.githubProfile(fromJSON: data)
            return KachatNames.SocialProfile(avatar: gh.avatar, banner: nil, bio: gh.bio)
        default:
            break
        }
        guard let url = URL(string: source.link), let (data, status) = await fetch(url, agent: crawlerAgent) else {
            AppLog.log("[KachatSocial] %@ %@: page no answer", source.platform.rawValue, source.handle)
            return await xAvatarOnly(source)
        }
        if status == 404 || status == 410 { return KachatNames.SocialProfile() }
        guard status == 200 else {
            AppLog.log("[KachatSocial] %@ %@: page HTTP %d", source.platform.rawValue, source.handle, status)
            return await xAvatarOnly(source)
        }
        let html = String(decoding: data, as: UTF8.self)
        // A page with no profile tags at all is not a profile without an avatar: it's a login
        // wall, a challenge or a script shell. That is "couldn't look it up", never cached as
        // an empty answer that would read as "this account has no avatar".
        guard S.openGraphImage(in: html) != nil || S.openGraphDescription(in: html) != nil else {
            AppLog.log("[KachatSocial] %@ %@: page has no profile tags (%d bytes)", source.platform.rawValue, source.handle, data.count)
            return await xAvatarOnly(source)
        }
        var result = KachatNames.SocialProfile()
        if let image = S.openGraphImage(in: html) {
            result.avatar = source.platform == .x ? S.xAvatar(fromOpenGraph: image) : image
        }
        result.bio = S.bio(for: source.platform, openGraphDescription: S.openGraphDescription(in: html))
        switch source.platform {
        case .x:
            result.banner = S.xBanner(in: html)
        case .youtube:
            if let (page, st) = await fetch(url, agent: browserAgent, cookie: "CONSENT=YES+1"), st == 200 {
                result.banner = S.youtubeBanner(in: String(decoding: page, as: UTF8.self))
            }
        default:
            break
        }
        return result
    }

    /// X only, when FxTwitter and X's page both failed: the avatar from unavatar.io, which answers
    /// with the image itself (404 when the account has none). nil = still unreachable.
    private nonisolated static func xAvatarOnly(_ source: KachatNames.SocialSource) async -> KachatNames.SocialProfile? {
        guard source.platform == .x,
              let url = URL(string: "https://unavatar.io/x/\(source.handle)?fallback=false"),
              let (data, status) = await fetch(url, agent: browserAgent, timeout: 5) else { return nil }
        guard status == 200, data.count > 0 else {
            AppLog.log("[KachatSocial] x %@: unavatar HTTP %d", source.handle, status)
            return nil
        }
        var p = KachatNames.SocialProfile()
        p.avatar = url.absoluteString
        return p
    }

    /// Ephemeral (nothing written to the shared cookie store or cache), and no request outlives 8 s.
    private nonisolated static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 8
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    private nonisolated static func fetch(_ url: URL, agent: String, cookie: String? = nil, timeout: TimeInterval = 6) async -> (Data, Int)? {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        if let cookie { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        return (data.prefix(3_000_000), http.statusCode)
    }
}

// MARK: - Old .kachat reminders

/// Earlier builds scheduled local reminders for .kachat names on the phone. Nothing schedules them
/// since the market left the app; this only clears what is still pending.
@MainActor
enum KachatNameReminders {
    /// `kachat-reminder-<network>-<wallet tag>-<name>-<expiresAt>-<kind>`.
    private static let root = "kachat-reminder-"
    /// The first build's ids, one device-wide set: removed wherever they are found.
    private static let legacyPrefix = "kachat-local-"

    /// A short, stable tag for a wallet in the ids (the address's last 12 characters).
    private static func walletTag(_ wallet: String) -> String {
        String(wallet.lowercased().suffix(12))
    }

    /// Every pending .kachat reminder on this phone, for every wallet - run once when the
    /// market left the app (`RetiredFeatureCleanup`).
    static func removeEverything() async {
        let center = UNUserNotificationCenter.current()
        let ids = await center.pendingNotificationRequests().map(\.identifier)
            .filter { $0.hasPrefix(root) || $0.hasPrefix(legacyPrefix) }
        if !ids.isEmpty { center.removePendingNotificationRequests(withIdentifiers: ids) }
    }

    /// A wallet's reminders, for when it leaves this phone. The tag comes from the address as
    /// given, whose checksum differs between kaspa: and kaspatest:, so a caller removing an
    /// account calls this for each of its network variants (`accountAddressVariants`).
    static func removeAll(forWallet wallet: String) async {
        let center = UNUserNotificationCenter.current()
        let tag = "-\(walletTag(wallet))-"
        let ids = await center.pendingNotificationRequests().map(\.identifier)
            .filter { $0.hasPrefix(root) && $0.contains(tag) }
        if !ids.isEmpty { center.removePendingNotificationRequests(withIdentifiers: ids) }
    }
}
