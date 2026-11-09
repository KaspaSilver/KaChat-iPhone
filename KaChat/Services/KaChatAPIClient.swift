import Foundation
import Network
import Security

enum KasiaAPIClientError: Error {
    case dpiPaginationExhausted(endpoint: String)
    /// The server answered 404/405/501: it does not serve this endpoint (an older indexer).
    case endpointUnsupported(endpoint: String)
    /// This network has no indexer address set (blank in Settings), so there is nothing to ask.
    case noIndexer
}

extension KasiaAPIClientError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .dpiPaginationExhausted(let endpoint): return "Pagination exhausted for \(endpoint)"
        case .endpointUnsupported(let endpoint): return "Endpoint not served: \(endpoint)"
        case .noIndexer: return "No indexer is configured for this network"
        }
    }
}

/// Gate for the per-request [KasiaAPI] log lines. The unified logging system rate-limits (and
/// eventually quarantines: "QUARANTINED DUE TO HIGH LOGGING VOLUME") processes that log too
/// much - and with the 5s foreground contact sweep, the 2s open-chat poll and group catch-up
/// all hitting the indexer, one detailed line per HTTP request was enough to get the whole
/// process muted, dropping the log lines that actually matter.
///
/// Policy:
/// - Failures (transport error, non-2xx, decode error) always log, with full detail.
/// - Slow successes (total time above `slowRequestMs`) always log, tagged SLOW.
/// - All other successes log only while Settings > Diagnostics > "Verbose API Logging" is on;
///   otherwise they fold into a one-line rollup emitted at most once per 60s (and only when at
///   least one request happened), so silence still reads as health rather than death.
private final class APIRequestLogGate: @unchecked Sendable {
    static let shared = APIRequestLogGate()
    /// Successful requests slower than this always log (SLOW tag), even when not verbose.
    static let slowRequestMs = 2000

    private let lock = NSLock()
    private var okCount = 0
    private var okTotalMs = 0
    private var windowStart = Date()
    private let summaryInterval: TimeInterval = 60

    /// `AppSettings.load()` is cached (see AppSettingsCache) and callable from any context,
    /// so reading this per request - including from URLSession delegate queues - is cheap.
    var verboseEnabled: Bool {
        AppSettings.load().verboseAPILogging
    }

    /// Counts one successful, non-slow, non-verbose request. At most once per
    /// `summaryInterval`, returns the rollup line for the window just closed; the caller logs
    /// it (keeps AppLog usage at the call sites). No timers: the summary rides the next
    /// request after the window elapses.
    func recordQuietSuccess(durationMs: Int) -> String? {
        lock.lock()
        defer { lock.unlock() }
        okCount += 1
        okTotalMs += max(durationMs, 0)
        let elapsed = Date().timeIntervalSince(windowStart)
        guard elapsed >= summaryInterval else { return nil }
        let line = String(
            format: "[KasiaAPI] %d requests ok in last %ds (avg %dms)",
            okCount, Int(elapsed), okTotalMs / okCount
        )
        okCount = 0
        okTotalMs = 0
        windowStart = Date()
        return line
    }
}

/// FAIL/SLOW lines keep the endpoint path and the leading query params but cap very long query
/// strings (address lists etc.) so a failure stays one readable log record.
private func truncatedURLForLog(_ raw: String, maxLength: Int = 200) -> String {
    guard raw.count > maxLength else { return raw }
    return String(raw.prefix(maxLength)) + "...(+\(raw.count - maxLength) chars)"
}

final class KasiaAPIClient: NSObject, URLSessionTaskDelegate {
    static let shared = KasiaAPIClient()

    private var session: URLSession!
    private var fallbackSession: URLSession!
    private let sessionLock = NSLock()
    private let requestQueue = IndexerRequestQueue(maxConcurrent: 5)
    /// Whether the indexer is answering, and the history read in its place (see the end of
    /// this class).
    private let indexerHealth = IndexerHealth()
    private let chainHistoryCache = ChainHistoryCache()
    private let http1Client = HTTP1Client()
    private let dpiState = DpiModeState()
    private let rootCheckMinInterval: TimeInterval = 20
    private let largeResponseThresholdBytes = 2 * 1024
    private let confidenceGainHTTP2Success = 15
    private let confidenceGainLargeResponseBonus = 25
    private let confidenceGainSyncSuccess = 20
    private let highNoDpiConfidenceThreshold = 70
    private let confidentModeFailureWindow: TimeInterval = 25
    private let confidentModeFailuresBeforeHTTP1 = 2
    @MainActor private(set) var dpiSuspectedSnapshot: Bool = false

    private override init() {
        super.init()
        resetSessions()
        Task { @MainActor [weak self] in
            NetworkEpochMonitor.shared.onEpochChange { [weak self] _ in
                Task { await self?.resetHTTPModeForNewEpoch() }
            }
        }
    }

    @MainActor var isDpiSuspected: Bool {
        dpiSuspectedSnapshot
    }

    func recordIndexerSyncSuccess() async {
        guard await !shouldForceHTTP1() else { return }
        let confidence = await dpiState.recordHTTP2SyncSuccess(gain: confidenceGainSyncSuccess)
        #if DEBUG
        let epochId = await currentEpochId()
        AppLog.log("[KasiaAPI] HTTP/2 sync success signal (epoch=%d confidence=%d)", epochId, confidence)
        #endif
    }

    private func resetHTTPModeForNewEpoch() async {
        await dpiState.reset()
        await MainActor.run {
            dpiSuspectedSnapshot = false
        }
    }

    private func currentEpochId() async -> Int {
        await MainActor.run {
            NetworkEpochMonitor.shared.epochId
        }
    }

    private func shouldForceHTTP1() async -> Bool {
        let epochId = await currentEpochId()
        return await dpiState.shouldForceHTTP1(epochId: epochId)
    }

    // MARK: - URLSessionTaskDelegate

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        #if DEBUG
        // Log metrics immediately when received - use full URL with query params
        let fullURL = task.originalRequest?.url?.absoluteString ?? "unknown"
        logMetrics(metrics, endpoint: fullURL, task: task)
        #else
        // In release builds, log only the path without query params
        let path = task.originalRequest?.url?.path ?? "unknown"
        logMetrics(metrics, endpoint: path, task: task)
        #endif
    }

    /// Log detailed metrics for a completed request
    private func logMetrics(_ metrics: URLSessionTaskMetrics, endpoint: String, task: URLSessionTask) {
        guard let transaction = metrics.transactionMetrics.last else {
            AppLog.log("[KasiaAPI] [%@] No transaction data", endpoint)
            return
        }

        // Protocol info
        let proto = transaction.networkProtocolName ?? "unknown"
        let isReused = transaction.isReusedConnection
        let isProxyConnection = transaction.isProxyConnection

        // Remote address
        let remoteAddr = transaction.remoteAddress ?? "unknown"
        let remotePort = transaction.remotePort.map { String($0) } ?? "?"

        // Connection type detection
        var connProto = proto
        if proto.contains("h3") || proto.contains("quic") {
            connProto = "HTTP/3-QUIC-UDP"
        } else if proto.contains("h2") || proto == "http/2" {
            connProto = "HTTP/2-TCP"
        } else if proto.contains("http/1") {
            connProto = "HTTP/1.1-TCP"
        }

        // Timing breakdown
        var timings: [String] = []
        var totalMs: Int?

        if let fetchStart = transaction.fetchStartDate {
            if let domainEnd = transaction.domainLookupEndDate, let domainStart = transaction.domainLookupStartDate {
                let dnsMs = domainEnd.timeIntervalSince(domainStart) * 1000
                if dnsMs > 0 {
                    timings.append(String(format: "dns=%.0fms", dnsMs))
                }
            }

            if let connectEnd = transaction.connectEndDate, let connectStart = transaction.connectStartDate {
                let connectMs = connectEnd.timeIntervalSince(connectStart) * 1000
                if connectMs > 0 {
                    timings.append(String(format: "tcp=%.0fms", connectMs))
                }
            }

            if let secureEnd = transaction.secureConnectionEndDate, let secureStart = transaction.secureConnectionStartDate {
                let tlsMs = secureEnd.timeIntervalSince(secureStart) * 1000
                if tlsMs > 0 {
                    timings.append(String(format: "tls=%.0fms", tlsMs))
                }
            }

            if let requestEnd = transaction.requestEndDate, let requestStart = transaction.requestStartDate {
                let requestMs = requestEnd.timeIntervalSince(requestStart) * 1000
                timings.append(String(format: "send=%.0fms", requestMs))
            }

            if let responseEnd = transaction.responseEndDate, let responseStart = transaction.responseStartDate {
                let responseMs = responseEnd.timeIntervalSince(responseStart) * 1000
                timings.append(String(format: "recv=%.0fms", responseMs))
            }

            if let responseEnd = transaction.responseEndDate {
                let total = responseEnd.timeIntervalSince(fetchStart) * 1000
                totalMs = Int(total)
                timings.append(String(format: "TOTAL=%.0fms", total))
            }
        }

        let connType = isReused ? "REUSED" : "NEW-CONN"
        let proxyStr = isProxyConnection ? " PROXY" : ""
        let timingStr = timings.isEmpty ? "no-timing-data" : timings.joined(separator: " ")
        let taskError = task.error

        // Non-2xx never surfaces as task.error (the HTTP exchange itself succeeded), so read
        // the status here to classify it as a failure for logging purposes. processResponse's
        // thrown KasiaError carries the human-readable detail; this line keeps the wire detail.
        let httpStatus = (transaction.response as? HTTPURLResponse)?.statusCode
        let isHTTPFailure = httpStatus.map { !(200...299).contains($0) } ?? false

        // Rate-limit policy (see APIRequestLogGate): failures and slow requests always log,
        // routine successes only when Verbose API Logging is on, otherwise they roll up into
        // the once-a-minute summary line.
        if let err = taskError {
            AppLog.log("[KasiaAPI] [%@] FAIL | %@ %@%@ | %@:%@ | %@ | err=%@",
                  truncatedURLForLog(endpoint), connProto, connType, proxyStr, remoteAddr, remotePort, timingStr, err.localizedDescription)
        } else if isHTTPFailure {
            AppLog.log("[KasiaAPI] [%@] FAIL | status=%d | %@ %@%@ | %@:%@ | %@",
                  truncatedURLForLog(endpoint), httpStatus ?? 0, connProto, connType, proxyStr, remoteAddr, remotePort, timingStr)
        } else if let totalMs, totalMs > APIRequestLogGate.slowRequestMs {
            AppLog.log("[KasiaAPI] [%@] SLOW | %@ %@%@ | %@:%@ | %@",
                  truncatedURLForLog(endpoint), connProto, connType, proxyStr, remoteAddr, remotePort, timingStr)
        } else if APIRequestLogGate.shared.verboseEnabled {
            AppLog.log("[KasiaAPI] [%@] OK | %@ %@%@ | %@:%@ | %@",
                  endpoint, connProto, connType, proxyStr, remoteAddr, remotePort, timingStr)
        } else if let summary = APIRequestLogGate.shared.recordQuietSuccess(durationMs: totalMs ?? 0) {
            AppLog.log("%@", summary)
        }
    }

    // MARK: - Configuration

    /// Get the indexer base URL from settings
    private var baseURL: String {
        AppSettings.load().indexerURL
    }

    var currentBaseURL: String? {
        return baseURL
    }

    /// False when this network has no usable indexer address (blank, or not an http(s) URL).
    /// Testnet ships without one until its indexer is published; every indexer call is skipped
    /// then instead of firing a path-only request that iOS rejects as "unsupported URL".
    var hasIndexer: Bool {
        Self.isUsableBaseURL(baseURL)
    }

    static func isUsableBaseURL(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host?.isEmpty == false else { return false }
        return true
    }

    // MARK: - Handshakes

    func getHandshakesBySender(address: String, limit: Int = 50, blockTime: UInt64 = 0) async throws -> [HandshakeResponse] {
        try await fromIndexerOrChain {
            try await getPaginated(
                endpoint: "/handshakes/by-sender",
                params: ["address": address],
                limit: limit,
                startBlockTime: blockTime,
                getBlockTime: { $0.blockTime }
            )
        } chain: {
            try await chainHandshakes(address: address, sent: true, since: blockTime)
        }
    }

    func getHandshakesByReceiver(address: String, limit: Int = 50, blockTime: UInt64 = 0) async throws -> [HandshakeResponse] {
        try await fromIndexerOrChain {
            try await getPaginated(
                endpoint: "/handshakes/by-receiver",
                params: ["address": address],
                limit: limit,
                startBlockTime: blockTime,
                getBlockTime: { $0.blockTime }
            )
        } chain: {
            try await chainHandshakes(address: address, sent: false, since: blockTime)
        }
    }

    // MARK: - Contextual Messages

    func getContextualMessagesBySender(address: String, alias: String, limit: Int = 50, blockTime: UInt64 = 0) async throws -> [ContextualMessageResponse] {
        let aliasHex = alias.data(using: .utf8)?.map { String(format: "%02x", $0) }.joined() ?? ""
        return try await fromIndexerOrChain {
            try await getPaginated(
                endpoint: "/contextual-messages/by-sender",
                params: ["address": address, "alias": aliasHex],
                limit: limit,
                startBlockTime: blockTime,
                getBlockTime: { $0.blockTime }
            )
        } chain: {
            try await chainContextualMessages(address: address, alias: alias, since: blockTime)
        }
    }

    /// First-contact messages addressed to `tag` - a recipient's inbox tag (`InboxTag`) - newest
    /// after `blockTime`. Same objects as by-sender, with `sender` filled in
    /// (NO_HANDSHAKE_MESSAGING.md §5.3).
    func getContextualMessagesByInbox(tag: String, limit: Int = 100, blockTime: UInt64 = 0) async throws -> [ContextualMessageResponse] {
        // Only the indexer can look a tag up. While it's down, new ones arrive from the block
        // stream instead (`ChatService.refreshInboxBlockScan`).
        if await shouldSkipIndexer() { throw KasiaError.networkError("The indexer isn't answering") }
        return try await getPaginated(
            endpoint: "/contextual-messages/by-inbox",
            params: ["tag": tag],
            limit: limit,
            startBlockTime: blockTime,
            getBlockTime: { $0.blockTime }
        )
    }

    /// Whether the indexer answers inbox lookups: true on an answer, false on 404 (an indexer
    /// without the feature), nil when it couldn't be reached - unknown, so not worth caching.
    func probeInboxSupport() async -> Bool? {
        if await shouldSkipIndexer() { return nil }
        do {
            let _: [ContextualMessageResponse] = try await get(
                endpoint: "/contextual-messages/by-inbox",
                params: ["tag": String(repeating: "0", count: 32), "limit": "1"]
            )
            return true
        } catch let KasiaError.apiError(message) where message == "Resource not found" {
            return false
        } catch {
            return nil
        }
    }

    // MARK: - Payments

    /// Fetch a single page of payments by receiver (no pagination).
    func getPaymentsByReceiverOnce(address: String, limit: Int = 50, blockTime: UInt64 = 0) async throws -> [PaymentResponse] {
        let params: [String: String] = [
            "address": address,
            "limit": String(limit),
            "block_time": String(blockTime)
        ]
        return try await fromIndexerOrChain {
            try await get(endpoint: "/payments/by-receiver", params: params)
        } chain: {
            try await chainPayments(receiver: address, since: blockTime)
        }
    }

    /// The indexer's own row or nothing, never the chain's history: for a check whose point is
    /// that the indexer is a source the REST server can't speak for (`indexerSender`).
    func getPaymentsFromIndexerOnly(address: String, limit: Int = 50, blockTime: UInt64 = 0) async throws -> [PaymentResponse] {
        if await shouldSkipIndexer() { throw KasiaError.networkError("The indexer isn't answering") }
        return try await get(
            endpoint: "/payments/by-receiver",
            params: ["address": address, "limit": String(limit), "block_time": String(blockTime)]
        )
    }

    // MARK: - Self Stash

    /// `startBlockTime` 0 reads the whole stash; a caller that keeps a high-water mark passes it
    /// (rewound for reorg safety) to read only what landed since. Also says whether the read
    /// actually reached the end of the owner's stash - a
    /// short last page - rather than stopping at the page cap or on a page that made no
    /// progress. Contact-note bookkeeping only trusts a read-back that reached the end.
    func getSelfStashReportingEnd(owner: String, scope: String, limit: Int = 50, startBlockTime: UInt64 = 0) async throws -> (items: [SelfStashResponse], reachedEnd: Bool) {
        let scopeHex = scope.data(using: .utf8)?.map { String(format: "%02x", $0) }.joined() ?? ""
        var reachedEnd = false
        let items: [SelfStashResponse] = try await fromIndexerOrChain {
            try await getPaginated(
                endpoint: "/self-stash/by-owner",
                params: ["owner": owner, "scope": scopeHex],
                limit: limit,
                startBlockTime: startBlockTime,
                maxPages: 200,
                getBlockTime: { $0.blockTime },
                reachedEnd: { reachedEnd = $0 }
            )
        } chain: {
            // never reports the end: the read back from the chain stops at a page cap
            reachedEnd = false
            return try await chainSelfStash(owner: owner, scope: scope, since: startBlockTime)
        }
        return (items, reachedEnd)
    }

    // MARK: - Group Messages

    /// `blindedGroupId` is the sender-specific blinded group id (hex-encoded 32 bytes) - callers
    /// must query once per known group member, since each member sends under their own blinded id.
    /// Pass `cursor` from a previous response's last item to resume losslessly (`block_time` alone
    /// can collide across items) - omit only for a first-ever sync. See docs/GROUP_CHAT_API.md.
    func getGroupMessages(blindedGroupId: String, limit: Int = 50, cursor: String? = nil) async throws -> [GroupMessageResponse] {
        try await getPaginatedByCursor(
            endpoint: "/group-messages/by-blinded-group-id",
            params: ["blinded_group_id": blindedGroupId],
            limit: limit,
            startCursor: cursor,
            getCursor: { $0.cursor }
        )
    }

    /// One lane of a batched group-message request: a member's blinded group id, where its
    /// cursor stands, and how many rows to return. See GROUP_MESSAGES_INDEXER.md.
    struct GroupMessagesBatchQuery: Encodable {
        let blindedGroupId: String
        let cursor: String?
        let limit: Int
    }

    private struct GroupMessagesBatchResult: Decodable {
        let blindedGroupId: String
        let messages: [GroupMessageResponse]
    }

    private struct GroupMessagesBatchResponse: Decodable {
        let results: [GroupMessagesBatchResult]
    }

    /// Remembered for the session once the server says it has no batched endpoint, so the
    /// per-member path is used without a wasted request per group per pass.
    private var groupMessagesBatchUnsupported = false

    /// Every member's page in ONE request (`POST /group-messages/by-blinded-group-ids`), keyed
    /// by blinded group id in the result. Nil when the indexer does not serve the endpoint;
    /// the caller then falls back to `getGroupMessages` per member, which is what every pass
    /// used to do: 1 + admins + members requests per group, every minute.
    func getGroupMessagesBatch(_ queries: [GroupMessagesBatchQuery]) async throws -> [String: [GroupMessageResponse]]? {
        let unsupported = sessionLock.withLock { groupMessagesBatchUnsupported }
        guard !unsupported, !queries.isEmpty else { return nil }
        do {
            let response: GroupMessagesBatchResponse = try await postJSON(
                endpoint: "/group-messages/by-blinded-group-ids",
                body: ["queries": queries]
            )
            return Dictionary(response.results.map { ($0.blindedGroupId, $0.messages) }, uniquingKeysWith: { first, _ in first })
        } catch KasiaAPIClientError.endpointUnsupported {
            sessionLock.withLock { groupMessagesBatchUnsupported = true }
            AppLog.log("%@", "[KasiaAPI] Indexer has no batched group-messages endpoint; using one request per member")
            return nil
        }
    }

    struct GroupMessagesSinceResponse: Decodable {
        let messages: [GroupMessageResponse]
        let latestBlockTime: UInt64?
    }

    struct GroupControlSinceResponse: Decodable {
        let controls: [GroupControlResponse]
        let latestBlockTime: UInt64?
    }

    private struct GroupMessagesSinceBody: Encodable {
        let blindedGroupIds: [String]
        let sinceBlockTime: UInt64
        let limit: Int
    }

    private struct GroupControlSinceBody: Encodable {
        let senders: [String]
        let recipient: String
        let sinceBlockTime: UInt64
        let limit: Int
    }

    /// Remembered for the session once the server says it has no `since` reads.
    private var groupSinceUnsupported = false

    /// Everything newer than `sinceBlockTime` across the given blinded ids, oldest first
    /// (`POST /group-messages/since`, GROUP_MESSAGES_INDEXER.md §2). Nil when the indexer does
    /// not serve it; the group service then keeps the block stream for live delivery.
    func getGroupMessagesSince(blindedGroupIds: [String], sinceBlockTime: UInt64, limit: Int = 200) async throws -> GroupMessagesSinceResponse? {
        let unsupported = sessionLock.withLock { groupSinceUnsupported }
        guard !unsupported, !blindedGroupIds.isEmpty else { return nil }
        do {
            return try await postJSON(
                endpoint: "/group-messages/since",
                body: GroupMessagesSinceBody(blindedGroupIds: blindedGroupIds, sinceBlockTime: sinceBlockTime, limit: limit)
            )
        } catch KasiaAPIClientError.endpointUnsupported {
            sessionLock.withLock { groupSinceUnsupported = true }
            AppLog.log("%@", "[KasiaAPI] Indexer has no group 'since' reads; groups stay on the block stream")
            return nil
        }
    }

    /// Control newer than `sinceBlockTime` from the given admins or addressed to `recipient`
    /// (`POST /group-control/since`). Nil when the indexer does not serve it.
    func getGroupControlSince(senders: [String], recipient: String, sinceBlockTime: UInt64, limit: Int = 200) async throws -> GroupControlSinceResponse? {
        let unsupported = sessionLock.withLock { groupSinceUnsupported }
        guard !unsupported else { return nil }
        do {
            return try await postJSON(
                endpoint: "/group-control/since",
                body: GroupControlSinceBody(senders: senders, recipient: recipient, sinceBlockTime: sinceBlockTime, limit: limit)
            )
        } catch KasiaAPIClientError.endpointUnsupported {
            sessionLock.withLock { groupSinceUnsupported = true }
            return nil
        }
    }

    /// A JSON POST against the indexer, on the same session and queue as `get`. Deliberately
    /// without `get`'s HTTP/1.1 and fallback-session dance: the one caller is best-effort and
    /// falls back to `get` itself.
    private func postJSON<Body: Encodable, T: Decodable & Sendable>(endpoint: String, body: Body) async throws -> T {
        do {
            let result: T = try await postJSONToIndexer(endpoint: endpoint, body: body)
            await noteIndexerResult(error: nil)
            return result
        } catch {
            await noteIndexerResult(error: error)
            throw error
        }
    }

    private func postJSONToIndexer<Body: Encodable, T: Decodable & Sendable>(endpoint: String, body: Body) async throws -> T {
        guard hasIndexer else { throw KasiaAPIClientError.noIndexer }
        guard let url = URL(string: baseURL + endpoint) else {
            throw KasiaError.networkError("Invalid URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await requestQueue.enqueue { [self] in
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, [404, 405, 501].contains(http.statusCode) {
                throw KasiaAPIClientError.endpointUnsupported(endpoint: endpoint)
            }
            return try processResponse(data: data, response: response, url: url)
        }
    }

    // MARK: - Group Control

    /// `sender` is the admin's Kaspa address - `gctl` messages are always sent as a self-stash
    /// transaction from the group admin's own address. Only meaningful for a group already
    /// known locally - see `getGroupControlByRecipient` for first-invite discovery.
    func getGroupControl(sender: String, limit: Int = 50, cursor: String? = nil) async throws -> [GroupControlResponse] {
        try await getPaginatedByCursor(
            endpoint: "/group-control/by-sender",
            params: ["sender": sender],
            limit: limit,
            startCursor: cursor,
            getCursor: { $0.cursor }
        )
    }

    /// `recipient` is our own wallet address. Recipient-addressed `gctl` controls carry the
    /// recipient's x-only pubkey on-chain, so this discovers "you were added to a group" before
    /// the device knows any admin address at all - the fix for first-invite catch-up/push that a
    /// global device-fanout fallback used to paper over. See docs/GROUP_CHAT_API.md.
    func getGroupControlByRecipient(recipient: String, limit: Int = 50, cursor: String? = nil) async throws -> [GroupControlResponse] {
        try await getPaginatedByCursor(
            endpoint: "/group-control/by-recipient",
            params: ["recipient": recipient],
            limit: limit,
            startCursor: cursor,
            getCursor: { $0.cursor }
        )
    }

    // MARK: - Metrics

    func getMetrics() async throws -> IndexerMetrics {
        let endpoint = "/metrics"
        return try await get(endpoint: endpoint, params: [:])
    }

    // MARK: - Health Check

    func ping() async -> (isHealthy: Bool, latencyMs: Int?) {
        let startTime = Date()

        do {
            let _ = try await getMetrics()
            let latency = Int(Date().timeIntervalSince(startTime) * 1000)
            return (true, latency)
        } catch {
            return (false, nil)
        }
    }

    // MARK: - Private Methods

    /// Fetch with automatic pagination - continues fetching until all results are retrieved
    /// - Parameters:
    ///   - endpoint: API endpoint path
    ///   - params: Base query parameters (without limit/block_time)
    ///   - limit: Page size for each request
    ///   - startBlockTime: Starting block_time cursor (0 for all)
    ///   - maxPages: Maximum number of pages to fetch (safety limit)
    ///   - getBlockTime: Closure to extract blockTime from response item
    private func getPaginated<T: Decodable & Sendable>(
        endpoint: String,
        params: [String: String],
        limit: Int,
        startBlockTime: UInt64,
        maxPages: Int = 20,
        getBlockTime: (T) -> UInt64?,
        reachedEnd: ((Bool) -> Void)? = nil
    ) async throws -> [T] {
        var allResults: [T] = []
        var currentBlockTime = startBlockTime
        var pageCount = 0
        let baseLimit = limit
        var currentLimit = baseLimit
        var endedOnShortPage = false
        defer { reachedEnd?(endedOnShortPage) }

        while pageCount < maxPages {
            // Build params with current cursor
            var pageParams = params
            pageParams["limit"] = String(currentLimit)
            pageParams["block_time"] = String(currentBlockTime)

            let results: [T]
            do {
                results = try await get(endpoint: endpoint, params: pageParams)
            } catch {
                if await shouldScaleDownPagination(error) {
                    let nextLimit = nextDpiLimit(after: currentLimit, fallbackBase: baseLimit)
                    if nextLimit < currentLimit {
                        AppLog.log("[KasiaAPI] DPI pagination: reducing limit from %d to %d for %@", currentLimit, nextLimit, endpoint)
                        currentLimit = nextLimit
                        continue
                    }
                    if currentLimit <= 1 {
                        AppLog.log("[KasiaAPI] DPI pagination: limit=1 failed for %@", endpoint)
                        throw KasiaAPIClientError.dpiPaginationExhausted(endpoint: endpoint)
                    }
                }
                throw error
            }
            allResults.append(contentsOf: results)

            // If we got fewer results than the limit, we've reached the end
            if results.count < currentLimit {
                endedOnShortPage = true
                break
            }

            // Find the maximum blockTime in results for next page cursor
            let maxBlockTime = results.compactMap { getBlockTime($0) }.max()
            guard let nextBlockTime = maxBlockTime, nextBlockTime > currentBlockTime else {
                // No valid blockTime found or no progress - stop pagination
                break
            }

            currentBlockTime = nextBlockTime
            pageCount += 1

            if pageCount > 1 {
                AppLog.log("[KasiaAPI] Pagination: fetched page %d for %@, total items: %d, next cursor: %llu",
                      pageCount, endpoint, allResults.count, currentBlockTime)
            }
        }

        if pageCount >= maxPages {
            AppLog.log("[KasiaAPI] Pagination: reached max pages (%d) for %@, total items: %d",
                  maxPages, endpoint, allResults.count)
        }

        return allResults
    }

    /// Cursor-based counterpart to `getPaginated` - group endpoints return an opaque `cursor`
    /// alongside `block_time` since multiple items can share the same block_time (see
    /// docs/GROUP_CHAT_API.md). A first-ever sync (no stored cursor) omits the param entirely,
    /// which the indexer treats as "from the beginning" - once any page comes back, every
    /// subsequent page (within this call, and future calls once the caller persists it) resumes
    /// from the last item's cursor instead.
    private func getPaginatedByCursor<T: Decodable & Sendable>(
        endpoint: String,
        params: [String: String],
        limit: Int,
        startCursor: String?,
        maxPages: Int = 20,
        getCursor: (T) -> String?
    ) async throws -> [T] {
        var allResults: [T] = []
        var currentCursor = startCursor
        var pageCount = 0
        let baseLimit = limit
        var currentLimit = baseLimit

        while pageCount < maxPages {
            var pageParams = params
            pageParams["limit"] = String(currentLimit)
            if let currentCursor {
                pageParams["cursor"] = currentCursor
            }

            let results: [T]
            do {
                results = try await get(endpoint: endpoint, params: pageParams)
            } catch {
                if await shouldScaleDownPagination(error) {
                    let nextLimit = nextDpiLimit(after: currentLimit, fallbackBase: baseLimit)
                    if nextLimit < currentLimit {
                        AppLog.log("[KasiaAPI] DPI pagination: reducing limit from %d to %d for %@", currentLimit, nextLimit, endpoint)
                        currentLimit = nextLimit
                        continue
                    }
                    if currentLimit <= 1 {
                        AppLog.log("[KasiaAPI] DPI pagination: limit=1 failed for %@", endpoint)
                        throw KasiaAPIClientError.dpiPaginationExhausted(endpoint: endpoint)
                    }
                }
                throw error
            }
            allResults.append(contentsOf: results)

            if results.count < currentLimit {
                break
            }

            guard let nextCursor = results.last.flatMap(getCursor), nextCursor != currentCursor else {
                // No cursor on the last item, or no progress - stop pagination rather than loop.
                break
            }

            currentCursor = nextCursor
            pageCount += 1

            if pageCount > 1 {
                AppLog.log("[KasiaAPI] Cursor pagination: fetched page %d for %@, total items: %d",
                      pageCount, endpoint, allResults.count)
            }
        }

        if pageCount >= maxPages {
            AppLog.log("[KasiaAPI] Cursor pagination: reached max pages (%d) for %@, total items: %d",
                  maxPages, endpoint, allResults.count)
        }

        return allResults
    }

    private func nextDpiLimit(after limit: Int, fallbackBase: Int) -> Int {
        if limit > 10 {
            return 10
        }
        switch limit {
        case 10:
            return 5
        case 5:
            return 3
        case 3:
            return 2
        case 2:
            return 1
        default:
            return min(1, fallbackBase)
        }
    }

    private func get<T: Decodable & Sendable>(endpoint: String, params: [String: String]) async throws -> T {
        do {
            let result: T = try await getFromIndexer(endpoint: endpoint, params: params)
            await noteIndexerResult(error: nil)
            return result
        } catch {
            await noteIndexerResult(error: error)
            throw error
        }
    }

    private func getFromIndexer<T: Decodable & Sendable>(endpoint: String, params: [String: String]) async throws -> T {
        guard hasIndexer else { throw KasiaAPIClientError.noIndexer }
        var urlComponents = URLComponents(string: baseURL + endpoint)
        urlComponents?.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }

        guard let url = urlComponents?.url else {
            throw KasiaError.networkError("Invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        return try await requestQueue.enqueue { [self] in
            if await shouldForceHTTP1() {
                return try await performHTTP1(url: url)
            }
            do {
                let (data, response) = try await session.data(for: request)
                // Detailed metrics logged by URLSessionTaskDelegate
                let result: T = try processResponse(data: data, response: response, url: url)
                await recordHTTP2PathSuccess(responseBytes: data.count, source: "primary", url: url)
                return result
            } catch {
                if await shouldTryHTTP1AfterFailure(url: url, error: error, source: "primary") {
                    #if DEBUG
                    AppLog.log("[KasiaAPI] Primary failed; switching to HTTP/1.1 for %@", url.absoluteString)
                    #endif
                    await markHTTP1ForEpoch()
                    return try await performHTTP1(url: url)
                }
                if shouldRetryWithFallback(error) {
                    resetSessions()
                    #if DEBUG
                    AppLog.log("[KasiaAPI] Primary session failed for %@, retrying with fallback session", url.absoluteString)
                    #endif
                    var fallbackRequest = request
                    fallbackRequest.setValue("close", forHTTPHeaderField: "Connection")
                    do {
                        let (data, response) = try await fallbackSession.data(for: fallbackRequest)
                        let result: T = try processResponse(data: data, response: response, url: url)
                        await recordHTTP2PathSuccess(responseBytes: data.count, source: "fallback", url: url)
                        return result
                    } catch {
                        if await shouldTryHTTP1AfterFailure(url: url, error: error, source: "fallback") {
                            #if DEBUG
                            AppLog.log("[KasiaAPI] Fallback failed; trying HTTP/1.1 for %@", url.absoluteString)
                            #endif
                            let result: T = try await performHTTP1(url: url)
                            await markHTTP1ForEpoch()
                            return result
                        }
                        throw error
                    }
                }
                // Detailed metrics logged by URLSessionTaskDelegate
                throw error
            }
        }
    }

    private func markHTTP1ForEpoch() async {
        let epochId = await currentEpochId()
        await dpiState.markHTTP1(epochId: epochId)
        await MainActor.run {
            dpiSuspectedSnapshot = true
        }
        #if DEBUG
        AppLog.log("[KasiaAPI] DPI suspected - forcing HTTP/1.1 for epoch %d", epochId)
        #endif
    }

    private func recordHTTP2PathSuccess(responseBytes: Int, source: String, url: URL) async {
        guard await !shouldForceHTTP1() else { return }
        let confidence = await dpiState.recordHTTP2Success(
            responseBytes: responseBytes,
            largeResponseThreshold: largeResponseThresholdBytes,
            baseGain: confidenceGainHTTP2Success,
            largePayloadBonus: confidenceGainLargeResponseBonus
        )
        #if DEBUG
        // Per-request success chatter - verbose mode only (see APIRequestLogGate). The
        // confidence bookkeeping above always runs; only the log line is gated.
        if APIRequestLogGate.shared.verboseEnabled {
            let epochId = await currentEpochId()
            AppLog.log("[KasiaAPI] HTTP/2 path success (%@, bytes=%d, epoch=%d confidence=%d) %@",
                  source, responseBytes, epochId, confidence, url.absoluteString)
        }
        #endif
    }

    private func networkIsOnline() async -> Bool {
        await MainActor.run {
            NetworkEpochMonitor.shared.isOnline
        }
    }

    private func shouldTryHTTP1AfterFailure(url: URL, error: Error, source: String) async -> Bool {
        if await shouldForceHTTP1() { return false }
        guard shouldRetryWithFallback(error) else { return false }
        #if DEBUG
        AppLog.log("[KasiaAPI] Evaluating HTTP/1.1 fallback for %@ via %@ (err=%@)",
              url.absoluteString, source, error.localizedDescription)
        #endif
        guard isDpiLikelyError(error) else {
            return false
        }

        let isOnline = await networkIsOnline()
        let decision = await dpiState.recordFailureAndEvaluateHTTP1Fallback(
            isOnline: isOnline,
            highConfidenceThreshold: highNoDpiConfidenceThreshold,
            requiredFailuresWhenHighConfidence: confidentModeFailuresBeforeHTTP1,
            failureWindow: confidentModeFailureWindow
        )
        #if DEBUG
        AppLog.log("[KasiaAPI] DPI fallback decision for %@: switch=%@ reason=%@ conf=%d streak=%d online=%@",
              url.absoluteString,
              decision.shouldTryHTTP1 ? "yes" : "no",
              decision.reason,
              decision.confidence,
              decision.failureStreak,
              decision.isOnline ? "yes" : "no")
        #endif
        guard decision.shouldTryHTTP1 else { return false }

        if decision.requireRootProbe {
            let rootOk = await checkRootReachable()
            if !rootOk {
                #if DEBUG
                AppLog.log("[KasiaAPI] HTTP/1.1 root probe failed; staying on HTTP/2 for %@", url.absoluteString)
                #endif
                return false
            }
        }

        #if DEBUG
        AppLog.log("[KasiaAPI] DPI-like failure; trying HTTP/1.1 for %@", url.absoluteString)
        #endif
        return true
    }

    private func isDpiLikelyError(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .networkConnectionLost, .timedOut:
                return true
            default:
                break
            }
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && (nsError.code == NSURLErrorNetworkConnectionLost || nsError.code == NSURLErrorTimedOut)
    }

    private func checkRootReachable() async -> Bool {
        let currentEpoch = await currentEpochId()
        if let cached = await dpiState.cachedRootCheck(epochId: currentEpoch, minInterval: rootCheckMinInterval) {
            return cached
        }

        guard let rootURL = rootURL() else {
            await dpiState.setRootCheck(epochId: currentEpoch, ok: false)
            return false
        }

        do {
            let (_, response) = try await http1Client.get(url: rootURL, timeout: 6)
            let ok = (200...599).contains(response.statusCode)
            await dpiState.setRootCheck(epochId: currentEpoch, ok: ok)
            if ok {
                AppLog.log("[KasiaAPI] HTTP/1.1 root probe OK: %@", rootURL.absoluteString)
            } else {
                AppLog.log("[KasiaAPI] HTTP/1.1 root probe status %d: %@",
                      response.statusCode, rootURL.absoluteString)
            }
            return ok
        } catch {
            await dpiState.setRootCheck(epochId: currentEpoch, ok: false)
            AppLog.log("[KasiaAPI] HTTP/1.1 root probe failed for %@: %@", rootURL.absoluteString, error.localizedDescription)
            return false
        }
    }

    private func rootURL() -> URL? {
        guard var components = URLComponents(string: baseURL) else { return nil }
        if components.path.isEmpty {
            components.path = "/"
        }
        return components.url
    }

    private func performHTTP1<T: Decodable>(url: URL) async throws -> T {
        let start = Date()
        do {
            let (data, response) = try await http1Client.get(url: url, timeout: 10)
            // Decode BEFORE logging so a non-2xx or decode error takes the FAIL path below
            // instead of logging OK first (same failure/slow/verbose/rollup policy as the
            // URLSession delegate path - see APIRequestLogGate).
            let result: T = try processResponse(data: data, response: response, url: url)
            let elapsed = Int(Date().timeIntervalSince(start) * 1000)
            if elapsed > APIRequestLogGate.slowRequestMs {
                AppLog.log("[KasiaAPI] [%@] SLOW | HTTP/1.1 | TOTAL=%dms",
                      truncatedURLForLog(url.absoluteString), elapsed)
            } else if APIRequestLogGate.shared.verboseEnabled {
                AppLog.log("[KasiaAPI] [%@] OK | HTTP/1.1 | TOTAL=%dms", url.absoluteString, elapsed)
            } else if let summary = APIRequestLogGate.shared.recordQuietSuccess(durationMs: elapsed) {
                AppLog.log("%@", summary)
            }
            return result
        } catch {
            let elapsed = Int(Date().timeIntervalSince(start) * 1000)
            AppLog.log("[KasiaAPI] [%@] FAIL | HTTP/1.1 | TOTAL=%dms | err=%@",
                  truncatedURLForLog(url.absoluteString), elapsed, error.localizedDescription)
            throw error
        }
    }

    private func processResponse<T: Decodable>(data: Data, response: URLResponse, url: URL) throws -> T {

        guard let httpResponse = response as? HTTPURLResponse else {
            throw KasiaError.networkError("Invalid response")
        }

        // Validate Content-Type when present (permissive: missing Content-Type is allowed)
        if let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type"),
           !contentType.isEmpty {
            guard contentType.contains("application/json") || contentType.contains("text/json") else {
                throw KasiaError.apiError("Unexpected Content-Type: \(contentType)")
            }
        }

        let status = httpResponse.statusCode

        switch status {
        case 200:
            // Some endpoints may legitimately return an empty body when there are no results
            if data.isEmpty {
                if let emptyArray = ([] as [Any]) as? T {
                    return emptyArray
                }
                throw KasiaError.apiError("Empty response from indexer")
            }

            do {
                let decoder = JSONDecoder()
                return try decoder.decode(T.self, from: data)
            } catch {
                throw KasiaError.apiError("Failed to decode response: \(error.localizedDescription)")
            }

        case 400:
            if let errorResponse = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
                throw KasiaError.apiError(errorResponse.error)
            }
            throw KasiaError.apiError("Bad request")

        case 404:
            throw KasiaError.apiError("Resource not found")
        case 500:
            throw KasiaError.apiError("Server error")
        default:
            throw KasiaError.apiError("HTTP \(status)")
        }
    }

    // MARK: - When the indexer is down

    /// True while the indexer has stopped answering. Chats keep working from the node and the
    /// Kaspa REST API meanwhile; see `fromIndexerOrChain`.
    var isIndexerDown: Bool {
        get async {
            await endOutageIfIndexerChanged()
            return await indexerHealth.isDown
        }
    }

    /// For a caller about to read the indexer: true while it's down. Once a minute a single
    /// cheap request goes out to find out whether it's back, so an outage never costs a real
    /// sync run against a dead server.
    func shouldSkipIndexer() async -> Bool {
        guard await isIndexerDown else { return false }
        if await indexerHealth.claimRecoveryCheck() {
            Task { _ = try? await self.getMetrics() }
        }
        return true
    }

    /// A different indexer in Settings (or none) ends what was known about the old one.
    private func endOutageIfIndexerChanged() async {
        guard await indexerHealth.endOutageIfIndexerChanged(to: baseURL) else { return }
        await MainActor.run {
            NotificationCenter.default.post(name: .indexerAvailabilityChanged, object: nil, userInfo: ["down": false])
        }
    }

    private enum IndexerOutcome { case answered, down, inconclusive }

    private static func outcome(of error: Error) -> IndexerOutcome {
        if error is CancellationError { return .inconclusive }
        if let urlError = error as? URLError {
            switch urlError.code {
            // the phone has no connection: that says nothing about the indexer
            case .cancelled, .notConnectedToInternet, .dataNotAllowed: return .inconclusive
            default: return .down
            }
        }
        if error is HTTP1ClientError { return .down }
        if let clientError = error as? KasiaAPIClientError {
            switch clientError {
            case .dpiPaginationExhausted: return .down
            case .endpointUnsupported: return .answered
            case .noIndexer: return .inconclusive
            }
        }
        if let kasiaError = error as? KasiaError, case .apiError(let message) = kasiaError {
            // A body it couldn't decode is still the indexer answering: one odd row isn't an outage.
            if message == "Server error" || message.hasPrefix("Unexpected Content-Type") { return .down }
            if message.hasPrefix("HTTP "), let code = Int(message.dropFirst(5)), code == 429 || code >= 500 { return .down }
            return .answered
        }
        return .inconclusive
    }

    /// Every indexer request reports here. A change either way is announced, for what has its
    /// own way of working without it (the block stream).
    private func noteIndexerResult(error: Error?) async {
        let info: [String: Any]
        switch error.map(Self.outcome(of:)) ?? .answered {
        case .answered:
            guard let wentDownAt = await indexerHealth.recordAnswer() else { return }
            info = ["down": false, "downSinceMs": UInt64(wentDownAt.timeIntervalSince1970 * 1000)]
            AppLog.log("[KasiaAPI] Indexer is answering again")
        case .down:
            // a weak signal looks like a dead server: only an online phone's failures count
            guard await networkIsOnline(), await indexerHealth.recordFailure() else { return }
            info = ["down": true]
            AppLog.log("[KasiaAPI] Indexer isn't answering: reading chats from the node and the Kaspa REST API")
        case .inconclusive:
            return
        }
        await MainActor.run {
            NotificationCenter.default.post(name: .indexerAvailabilityChanged, object: nil, userInfo: info)
        }
    }

    /// The indexer's answer or, once it's confirmed down, the same thing read from the chain's
    /// history, so callers work the same either way. A one-off failure with the indexer up is
    /// thrown as it always was, for the caller's own retry to ask the indexer again.
    private func fromIndexerOrChain<T>(
        _ indexer: () async throws -> T,
        chain: () async throws -> T
    ) async throws -> T {
        if await shouldSkipIndexer() { return try await chain() }
        do {
            return try await indexer()
        } catch {
            guard Self.outcome(of: error) == .down, await indexerHealth.isDown else { throw error }
            return try await chain()
        }
    }

    // MARK: Reading history from the chain

    private static let chainPageSize = 100
    /// 2,000 transactions per address. A node keeps no history by address, so this is the Kaspa
    /// REST API, newest first; past this a window is left to the indexer when it's back.
    private static let chainMaxPages = 20

    /// `address`'s accepted transactions since `since` (ms), oldest first. Shared for a moment,
    /// since one sync asks about the same address several times over. Throws when the history
    /// runs past the page cap before reaching `since`: a partial read would move the caller's
    /// cursor past the part it never saw.
    func chainTransactions(address: String, since: UInt64) async throws -> [ChainHistoryTx] {
        let key = address.lowercased()
        if let cached = await chainHistoryCache.fresh(key, since: since) {
            return cached.filter { $0.blockTime >= since }
        }
        let base = AppSettings.load().kaspaRestAPIURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let root = base.hasSuffix("/") ? String(base.dropLast()) : base
        var found: [ChainHistoryTx] = []
        var reachedStart = false
        for page in 0..<Self.chainMaxPages {
            guard let delay = await chainHistoryCache.reserveRequestSlot() else {
                throw KasiaError.networkError("The Kaspa REST API is busy")
            }
            if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            let offset = page * Self.chainPageSize
            guard let url = URL(string: "\(root)/addresses/\(key)/full-transactions?limit=\(Self.chainPageSize)&offset=\(offset)&resolve_previous_outpoints=light&fields=transaction_id,is_accepted,payload,inputs,outputs,block_time") else {
                throw KasiaError.networkError("Invalid URL")
            }
            let parsed: (transactions: [ChainHistoryTx], rows: Int) = try await requestQueue.enqueue { [self] in
                let (data, response) = try await URLSession.shared.data(for: ChatService.timedRequest(url))
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200 else {
                    if status == 429 || status >= 500 { await chainHistoryCache.backOff() }
                    throw KasiaError.networkError("The Kaspa REST API answered \(status)")
                }
                return Self.parseChainRows(data)
            }
            found.append(contentsOf: parsed.transactions)
            if parsed.rows < Self.chainPageSize || (since > 0 && parsed.transactions.contains { $0.blockTime < since }) {
                reachedStart = true
                break
            }
        }
        guard reachedStart else { throw KasiaError.networkError("Too much history to read from the chain") }
        let inOrder = found.sorted { ($0.blockTime, $0.txId) < ($1.blockTime, $1.txId) }
        await chainHistoryCache.store(key, since: since, transactions: inOrder)
        return inOrder.filter { $0.blockTime >= since }
    }

    private static func parseChainRows(_ data: Data) -> (transactions: [ChainHistoryTx], rows: Int) {
        guard let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return ([], 0) }
        func number(_ value: Any?) -> UInt64? {
            if let n = value as? NSNumber { return n.uint64Value }
            if let s = value as? String { return UInt64(s) }
            return nil
        }
        let transactions = rows.compactMap { row -> ChainHistoryTx? in
            if let accepted = row["is_accepted"] as? Bool, !accepted { return nil }
            guard let txId = row["transaction_id"] as? String, let rawBlockTime = number(row["block_time"]) else { return nil }
            let blockTime = min(rawBlockTime, UInt64(Int64.max))
            let senders = ((row["inputs"] as? [[String: Any]]) ?? []).compactMap { ($0["previous_outpoint_address"] as? String)?.lowercased() }
            let outputs = ((row["outputs"] as? [[String: Any]]) ?? []).compactMap { output -> ChainHistoryTx.Output? in
                guard let address = (output["script_public_key_address"] as? String)?.lowercased(),
                      let amount = number(output["amount"]) else { return nil }
                return ChainHistoryTx.Output(address: address, amount: amount)
            }
            return ChainHistoryTx(
                txId: txId,
                blockTime: blockTime,
                payloadHex: (row["payload"] as? String)?.lowercased() ?? "",
                senders: Set(senders),
                outputs: outputs
            )
        }
        return (transactions, rows.count)
    }

    private static func hex(_ text: String) -> String {
        text.utf8.map { String(format: "%02x", $0) }.joined()
    }

    private static let handshakePrefixes = ["kchat:1:handshake:", "ciph_msg:1:handshake:"].map(hex)

    /// Only rows whose author's input signature checks out: the REST listing's addresses are its
    /// word, and the rest of the app takes only a signature as proof of who wrote something.
    /// A row that can't be proven now comes back from the indexer when it recovers.
    private func provenByAuthor<T>(_ rows: [T], txId: (T) -> String, author: (T) -> String) async -> [T] {
        var kept: [T] = []
        for row in rows {
            let id = txId(row)
            if await chainHistoryCache.isProven(id) {
                kept.append(row)
            } else if await ChatService.shared.provenSender(of: id, expected: author(row), myAddress: "") == .proven {
                await chainHistoryCache.markProven(id)
                kept.append(row)
            }
        }
        return kept
    }

    /// The indexer's form: the encrypted hex, with no protocol prefix.
    private func chainHandshakes(address: String, sent: Bool, since: UInt64) async throws -> [HandshakeResponse] {
        let me = address.lowercased()
        let rows: [HandshakeResponse] = try await chainTransactions(address: address, since: since).compactMap { tx in
            guard let prefix = Self.handshakePrefixes.first(where: { tx.payloadHex.hasPrefix($0) }) else { return nil }
            guard tx.senders.contains(me) == sent else { return nil }
            let sender = sent ? address : (tx.senders.sorted().first ?? "")
            let receiver = sent ? (tx.outputs.first { $0.address != me }?.address ?? "") : address
            guard !sender.isEmpty, !receiver.isEmpty else { return nil }
            return HandshakeResponse(
                txId: tx.txId, sender: sender, receiver: receiver, blockTime: tx.blockTime,
                acceptingBlock: nil, acceptingDaaScore: nil,
                messagePayload: String(tx.payloadHex.dropFirst(prefix.count))
            )
        }
        return await provenByAuthor(rows, txId: { $0.txId }, author: { $0.sender })
    }

    /// `kchat:1:comm:ALIAS:BASE64` becomes the indexer's form, hex(BASE64). Only what `address`
    /// itself spent into: a message is a transaction from its author to themselves.
    private func chainContextualMessages(address: String, alias: String, since: UInt64) async throws -> [ContextualMessageResponse] {
        let me = address.lowercased()
        let rows: [ContextualMessageResponse] = try await chainTransactions(address: address, since: since).compactMap { tx in
            guard tx.senders.contains(me), !tx.payloadHex.isEmpty,
                  let bytes = Data(hexString: tx.payloadHex), let raw = String(data: bytes, encoding: .utf8) else { return nil }
            let text = ContextualPayloadFormat.normalized(raw)
            guard text.hasPrefix("kchat:1:comm:") || text.hasPrefix("ciph_msg:1:comm:") else { return nil }
            let parts = text.split(separator: ":", maxSplits: 4, omittingEmptySubsequences: false)
            guard parts.count == 5, parts[3] == alias, !parts[4].isEmpty else { return nil }
            return ContextualMessageResponse(
                txId: tx.txId, sender: address, alias: Self.hex(alias), blockTime: tx.blockTime,
                acceptingBlock: nil, acceptingDaaScore: nil, messagePayload: Self.hex(String(parts[4]))
            )
        }
        return await provenByAuthor(rows, txId: { $0.txId }, author: { $0.sender })
    }

    private func chainPayments(receiver: String, since: UInt64) async throws -> [PaymentResponse] {
        let me = receiver.lowercased()
        return try await chainTransactions(address: receiver, since: since).compactMap { tx in
            guard !tx.senders.isEmpty, !tx.senders.contains(me) else { return nil }
            var amount: UInt64 = 0
            for output in tx.outputs where output.address == me {
                let (sum, overflowed) = amount.addingReportingOverflow(output.amount)
                if overflowed { return nil }
                amount = sum
            }
            guard amount > 0, let sender = tx.senders.sorted().first else { return nil }
            return PaymentResponse(
                txId: tx.txId, sender: sender, receiver: receiver, amount: amount, message: nil, blockTime: tx.blockTime,
                acceptingBlock: nil, acceptingDaaScore: nil, messagePayload: tx.payloadHex.isEmpty ? nil : tx.payloadHex
            )
        }
    }

    private func chainSelfStash(owner: String, scope: String, since: UInt64) async throws -> [SelfStashResponse] {
        let me = owner.lowercased()
        let prefixes = ["kchat:1:self_stash:", "ciph_msg:1:self_stash:"].map { Self.hex($0 + scope + ":") }
        return try await chainTransactions(address: owner, since: since).compactMap { tx in
            guard tx.senders.contains(me), let prefix = prefixes.first(where: { tx.payloadHex.hasPrefix($0) }) else { return nil }
            return SelfStashResponse(
                txId: tx.txId, owner: owner, scope: scope, blockTime: tx.blockTime,
                acceptingBlock: nil, acceptingDaaScore: nil, stashedData: String(tx.payloadHex.dropFirst(prefix.count))
            )
        }
    }

    private func shouldRetryWithFallback(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost:
                return true
            default:
                return false
            }
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut
    }

    private func shouldScaleDownPagination(_ error: Error) async -> Bool {
        if let http1Error = error as? HTTP1ClientError {
            switch http1Error {
            case .timeout, .invalidResponse:
                return true
            default:
                return false
            }
        }
        if let urlError = error as? URLError {
            guard urlError.code == .timedOut || urlError.code == .networkConnectionLost else { return false }
            return await shouldForceHTTP1()
        }
        if let description = error.localizedDescription as String?,
           description == HTTP1ClientError.timeout.errorDescription ||
            description == HTTP1ClientError.invalidResponse.errorDescription {
            return await shouldForceHTTP1()
        }
        return false
    }

    private func resetSessions() {
        sessionLock.lock()
        defer { sessionLock.unlock() }

        let oldSession = session
        let oldFallback = fallbackSession
        session = makeSession(kind: "primary", configuration: makePrimaryConfig())
        fallbackSession = makeSession(kind: "fallback", configuration: makeFallbackConfig())

        oldSession?.finishTasksAndInvalidate()
        oldFallback?.finishTasksAndInvalidate()
    }

    private func makeSession(kind: String, configuration: URLSessionConfiguration) -> URLSession {
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        AppLog.log("[KasiaAPI] URLSession initialized (%@)", kind)
        return session
    }

    private func makePrimaryConfig() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60
        config.waitsForConnectivity = true
        config.httpMaximumConnectionsPerHost = 5
        config.httpShouldUsePipelining = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        // No `Accept-Encoding: identity` / `Connection: close` here. Those belong to the DPI
        // workaround, which lives on the fallback session and the hand-rolled HTTP/1.1 path, but
        // they were applied to this session too - the normal HTTP/2 path that carries the
        // foreground sweep, ~81 requests a pass of hex-encoded JSON that compresses several
        // times over. Every one of them was downloaded uncompressed for no DPI benefit: HTTP/2
        // drops `Connection: close` as hop-by-hop anyway, so only the gzip refusal ever took
        // effect. Content is still decoded transparently, so byte counts recorded by the DPI
        // detector are unchanged.
        return config
    }

    private func makeFallbackConfig() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60
        config.waitsForConnectivity = true
        config.httpMaximumConnectionsPerHost = 5
        config.httpShouldUsePipelining = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpAdditionalHeaders = ["Connection": "close", "Accept-Encoding": "identity"]
        return config
    }
}

private enum HTTP1ClientError: LocalizedError {
    case invalidURL
    case invalidResponse
    case timeout
    case unsupportedScheme

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL"
        case .invalidResponse:
            return "Invalid HTTP response"
        case .timeout:
            return "Request timed out"
        case .unsupportedScheme:
            return "Unsupported URL scheme"
        }
    }
}

private actor HTTP1Client {
    private static let maxResponseSize = 10 * 1024 * 1024 // 10MB
    private let queue = DispatchQueue(label: "kasia.http1.client")

    func get(url: URL, timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
        guard let host = url.host else { throw HTTP1ClientError.invalidURL }
        guard let scheme = url.scheme, scheme == "https" else { throw HTTP1ClientError.unsupportedScheme }
        let port = url.port ?? 443
        guard let port16 = UInt16(exactly: port),
              let portValue = NWEndpoint.Port(rawValue: port16) else { throw HTTP1ClientError.invalidURL }

        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(tlsOptions.securityProtocolOptions, host)
        let parameters = NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
        parameters.allowLocalEndpointReuse = true

        let connection = NWConnection(host: NWEndpoint.Host(host), port: portValue, using: parameters)
        defer { connection.cancel() }

        let response: (Data, HTTPURLResponse) = try await withTimeout(timeout, onTimeout: {
            connection.cancel()
        }) { [self] in
            try await waitUntilReady(connection)
            let requestData = buildRequest(url: url, host: host)
            try await send(connection, data: requestData)
            return try await receiveHTTPResponse(connection, url: url)
        }
        return response
    }

    private func waitUntilReady(_ connection: NWConnection) async throws {
        let gate = ContinuationGate()
        try await withCheckedThrowingContinuation { continuation in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    gate.resumeOnce { continuation.resume() }
                case .failed(let error):
                    gate.resumeOnce { continuation.resume(throwing: error) }
                case .cancelled:
                    gate.resumeOnce { continuation.resume(throwing: HTTP1ClientError.invalidResponse) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    private func send(_ connection: NWConnection, data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func receiveOnce(_ connection: NWConnection) async throws -> (Data?, Bool) {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data?, Bool), Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (data, isComplete))
                }
            }
        }
    }

    private func buildRequest(url: URL, host: String) -> Data {
        let path = (url.path.isEmpty ? "/" : url.path) + (url.query.map { "?\($0)" } ?? "")
        let request = "GET \(path) HTTP/1.1\r\n" +
            "Host: \(host)\r\n" +
            "Connection: close\r\n" +
            "Accept: application/json\r\n" +
            "Accept-Encoding: identity\r\n" +
            "User-Agent: Kasia-iOS\r\n" +
            "\r\n"
        return Data(request.utf8)
    }

    private func receiveHTTPResponse(_ connection: NWConnection, url: URL) async throws -> (Data, HTTPURLResponse) {
        var buffer = Data()
        var headers: [String: String]?
        var bodyStart = 0

        while true {
            let (chunk, isComplete) = try await receiveOnce(connection)
            if let chunk {
                buffer.append(chunk)
            }

            guard buffer.count <= Self.maxResponseSize else {
                throw HTTP1ClientError.invalidResponse
            }

            if headers == nil {
                if let range = buffer.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) {
                    bodyStart = range.upperBound
                    headers = parseHeaders(from: buffer[..<range.lowerBound])
                }
            }

            if let headers {
                if let lengthStr = headers["content-length"], let length = Int(lengthStr) {
                    if buffer.count >= bodyStart + length {
                        let full = buffer.prefix(bodyStart + length)
                        return try parseHTTPResponse(data: Data(full), url: url)
                    }
                } else if let transfer = headers["transfer-encoding"], transfer.lowercased().contains("chunked") {
                    if buffer.range(of: Data([0x0D, 0x0A, 0x30, 0x0D, 0x0A, 0x0D, 0x0A]), options: [], in: bodyStart..<buffer.count) != nil {
                        return try parseHTTPResponse(data: buffer, url: url)
                    }
                } else if isComplete {
                    return try parseHTTPResponse(data: buffer, url: url)
                }
            }

            if isComplete, headers != nil {
                return try parseHTTPResponse(data: buffer, url: url)
            }
        }
    }

    private func parseHeaders(from data: Data) -> [String: String] {
        let headerString = String(decoding: data, as: UTF8.self)
        let lines = headerString.components(separatedBy: "\r\n")
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        return headers
    }

    private func parseHTTPResponse(data: Data, url: URL) throws -> (Data, HTTPURLResponse) {
        let separator = Data([0x0D, 0x0A, 0x0D, 0x0A])
        guard let headerRange = data.range(of: separator) else {
            throw HTTP1ClientError.invalidResponse
        }

        let headerData = data[..<headerRange.lowerBound]
        let bodyData = data[headerRange.upperBound...]
        let headerString = String(decoding: headerData, as: UTF8.self)
        let lines = headerString.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else {
            throw HTTP1ClientError.invalidResponse
        }
        let parts = statusLine.split(separator: " ")
        // The status comes straight off the wire; anything outside the HTTP range is a broken
        // (or hostile) peer, and HTTPURLResponse would reject it anyway.
        guard parts.count >= 2, let statusCode = Int(parts[1]), (100...599).contains(statusCode) else {
            throw HTTP1ClientError.invalidResponse
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let body: Data
        if let transfer = headers["transfer-encoding"], transfer.lowercased().contains("chunked") {
            body = try decodeChunkedBody(Data(bodyData))
        } else if let lengthStr = headers["content-length"], let length = Int(lengthStr) {
            body = Data(bodyData.prefix(length))
        } else {
            body = Data(bodyData)
        }

        guard let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        ) ?? HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: nil) else {
            throw HTTP1ClientError.invalidResponse
        }

        return (body, response)
    }

    private func decodeChunkedBody(_ data: Data) throws -> Data {
        var output = Data()
        var offset = 0
        while offset < data.count {
            guard let lineRange = findCRLF(in: data, start: offset) else {
                throw HTTP1ClientError.invalidResponse
            }
            let sizeData = data[offset..<lineRange.lowerBound]
            // Every value here comes from the server: an empty size line, a negative size or one
            // that overflows used to trap instead of failing the request.
            guard let sizeString = String(decoding: sizeData, as: UTF8.self).split(separator: ";").first,
                  let size = Int(sizeString.trimmingCharacters(in: .whitespaces), radix: 16),
                  size >= 0 else {
                throw HTTP1ClientError.invalidResponse
            }
            let chunkStart = lineRange.upperBound
            if size == 0 {
                break
            }
            guard size <= data.count - chunkStart else {
                throw HTTP1ClientError.invalidResponse
            }
            let chunkEnd = chunkStart + size
            output.append(data[chunkStart..<chunkEnd])
            offset = chunkEnd + 2
        }
        return output
    }

    private func findCRLF(in data: Data, start: Int) -> Range<Int>? {
        let crlf = Data([0x0D, 0x0A])
        return data.range(of: crlf, options: [], in: start..<data.count)
    }

    private func withTimeout<T>(
        _ seconds: TimeInterval,
        onTimeout: @escaping () -> Void,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                onTimeout()
                throw HTTP1ClientError.timeout
            }
            guard let result = try await group.next() else {
                throw HTTP1ClientError.timeout
            }
            group.cancelAll()
            return result
        }
    }
}

private struct HTTP1FallbackEvaluation {
    let shouldTryHTTP1: Bool
    let confidence: Int
    let failureStreak: Int
    let isOnline: Bool
    let requireRootProbe: Bool
    let reason: String
}

private actor DpiModeState {
    private var forcedHTTP1Epoch: Int?
    private var dpiDetectedEpoch: Int?
    private var lastRootCheck: (epoch: Int, time: Date, ok: Bool)?
    private var noDpiConfidence: Int = 0
    private var http2FailureStreak: Int = 0
    private var lastHTTP2FailureAt: Date?

    func reset() {
        forcedHTTP1Epoch = nil
        dpiDetectedEpoch = nil
        lastRootCheck = nil
        noDpiConfidence = 0
        http2FailureStreak = 0
        lastHTTP2FailureAt = nil
    }

    func shouldForceHTTP1(epochId: Int) -> Bool {
        forcedHTTP1Epoch == epochId
    }

    func markHTTP1(epochId: Int) {
        forcedHTTP1Epoch = epochId
        dpiDetectedEpoch = epochId
        http2FailureStreak = 0
        lastHTTP2FailureAt = nil
    }

    func recordHTTP2Success(
        responseBytes: Int,
        largeResponseThreshold: Int,
        baseGain: Int,
        largePayloadBonus: Int
    ) -> Int {
        http2FailureStreak = 0
        lastHTTP2FailureAt = nil
        var gain = baseGain
        if responseBytes >= largeResponseThreshold {
            gain += largePayloadBonus
        }
        noDpiConfidence = min(100, noDpiConfidence + gain)
        return noDpiConfidence
    }

    func recordHTTP2SyncSuccess(gain: Int) -> Int {
        http2FailureStreak = 0
        lastHTTP2FailureAt = nil
        noDpiConfidence = min(100, noDpiConfidence + gain)
        return noDpiConfidence
    }

    func recordFailureAndEvaluateHTTP1Fallback(
        isOnline: Bool,
        highConfidenceThreshold: Int,
        requiredFailuresWhenHighConfidence: Int,
        failureWindow: TimeInterval
    ) -> HTTP1FallbackEvaluation {
        let now = Date()
        if let lastFailure = lastHTTP2FailureAt, now.timeIntervalSince(lastFailure) <= failureWindow {
            http2FailureStreak += 1
        } else {
            http2FailureStreak = 1
        }
        lastHTTP2FailureAt = now

        if noDpiConfidence < highConfidenceThreshold {
            return HTTP1FallbackEvaluation(
                shouldTryHTTP1: true,
                confidence: noDpiConfidence,
                failureStreak: http2FailureStreak,
                isOnline: isOnline,
                requireRootProbe: false,
                reason: "low-confidence-first-failure"
            )
        }

        if !isOnline {
            return HTTP1FallbackEvaluation(
                shouldTryHTTP1: false,
                confidence: noDpiConfidence,
                failureStreak: http2FailureStreak,
                isOnline: isOnline,
                requireRootProbe: false,
                reason: "high-confidence-offline"
            )
        }

        if http2FailureStreak < requiredFailuresWhenHighConfidence {
            return HTTP1FallbackEvaluation(
                shouldTryHTTP1: false,
                confidence: noDpiConfidence,
                failureStreak: http2FailureStreak,
                isOnline: isOnline,
                requireRootProbe: false,
                reason: "high-confidence-awaiting-more-failures"
            )
        }

        return HTTP1FallbackEvaluation(
            shouldTryHTTP1: true,
            confidence: noDpiConfidence,
            failureStreak: http2FailureStreak,
            isOnline: isOnline,
            requireRootProbe: true,
            reason: "high-confidence-multi-failure-online"
        )
    }

    func cachedRootCheck(epochId: Int, minInterval: TimeInterval) -> Bool? {
        guard let last = lastRootCheck, last.epoch == epochId else { return nil }
        // Retry probe on every failure path; only cache positive checks briefly.
        if !last.ok { return nil }
        if Date().timeIntervalSince(last.time) < minInterval {
            return last.ok
        }
        return nil
    }

    func setRootCheck(epochId: Int, ok: Bool) {
        lastRootCheck = (epoch: epochId, time: Date(), ok: ok)
    }
}

private final class ContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func resumeOnce(_ action: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return }
        resumed = true
        action()
    }
}

extension Notification.Name {
    /// The indexer stopped answering or came back; `userInfo["down"]` says which.
    static let indexerAvailabilityChanged = Notification.Name("indexerAvailabilityChanged")
}

/// One transaction from an address's history on the Kaspa REST API (`KasiaAPIClient.chainTransactions`).
struct ChainHistoryTx: Sendable {
    struct Output: Sendable {
        let address: String
        let amount: UInt64
    }
    let txId: String
    let blockTime: UInt64
    let payloadHex: String
    /// The addresses whose coins it spent, lowercased (the REST API's word for it).
    let senders: Set<String>
    let outputs: [Output]
}

private actor ChainHistoryCache {
    private struct Entry {
        let since: UInt64
        let at: Date
        let transactions: [ChainHistoryTx]
    }
    private var entries: [String: Entry] = [:]
    private static let lifetime: TimeInterval = 20
    /// One request every quarter second at most, across the whole app: an outage hits every
    /// phone at once, and they all land on the same REST server.
    private static let requestSpacing: TimeInterval = 0.25
    private static let backOffSeconds: TimeInterval = 30
    private var nextRequestAt = Date.distantPast
    private var blockedUntil = Date.distantPast
    private var proven: Set<String> = []

    /// How long to wait before the next request, or nil while backing off.
    func reserveRequestSlot() -> TimeInterval? {
        let now = Date()
        guard now >= blockedUntil else { return nil }
        let at = max(now, nextRequestAt)
        nextRequestAt = at.addingTimeInterval(Self.requestSpacing)
        return at.timeIntervalSince(now)
    }

    func backOff() {
        blockedUntil = Date().addingTimeInterval(Self.backOffSeconds)
    }

    func isProven(_ txId: String) -> Bool { proven.contains(txId) }

    func markProven(_ txId: String) {
        if proven.count > 5_000 { proven.removeAll() }
        proven.insert(txId)
    }

    func fresh(_ address: String, since: UInt64) -> [ChainHistoryTx]? {
        guard let entry = entries[address], entry.since <= since,
              Date().timeIntervalSince(entry.at) < Self.lifetime else { return nil }
        return entry.transactions
    }

    func store(_ address: String, since: UInt64, transactions: [ChainHistoryTx]) {
        if entries.count > 500 { entries.removeAll() }
        entries[address] = Entry(since: since, at: Date(), transactions: transactions)
    }
}

/// Whether the indexer is answering. It only counts as down after several failures in a row, so
/// one timeout never moves the app off it, and failures within a few seconds of each other count
/// once, since a dropped connection fails everything in flight together. While it's down, one
/// request a minute checks whether it's back.
private actor IndexerHealth {
    private static let outageKey = "kachat_indexer_down_since"
    private var downSince: Date?
    /// An outage the app was killed during: the first answer after launch still closes it, so
    /// the window read from the chain is read again from the indexer.
    private var unfinishedOutage = UserDefaults.standard.object(forKey: IndexerHealth.outageKey) as? Date
    private var indexerURL: String?
    private var failuresInARow = 0
    private var lastFailureAt = Date.distantPast
    private var retryAt = Date.distantPast
    private static let failureSpacing: TimeInterval = 5
    private static let failuresToGoDown = 3
    /// Failures further apart than this aren't a run.
    private static let failureWindow: TimeInterval = 120
    private static let retryInterval: TimeInterval = 60

    var isDown: Bool { downSince != nil }

    /// True at most once a minute, while it's down.
    func claimRecoveryCheck() -> Bool {
        let now = Date()
        guard downSince != nil, now >= retryAt else { return false }
        retryAt = now.addingTimeInterval(Self.retryInterval)
        return true
    }

    /// True when an outage ended because Settings now names a different indexer.
    func endOutageIfIndexerChanged(to url: String) -> Bool {
        defer { indexerURL = url }
        guard let indexerURL, indexerURL != url else { return false }
        failuresInARow = 0
        unfinishedOutage = nil
        UserDefaults.standard.removeObject(forKey: Self.outageKey)
        defer { downSince = nil }
        return downSince != nil
    }

    /// True when this is the moment it went down.
    func recordFailure() -> Bool {
        let now = Date()
        let sinceLast = now.timeIntervalSince(lastFailureAt)
        if sinceLast > Self.failureWindow { failuresInARow = 0 }
        if failuresInARow == 0 || sinceLast >= Self.failureSpacing {
            lastFailureAt = now
            failuresInARow += 1
        }
        guard downSince == nil, failuresInARow >= Self.failuresToGoDown else { return false }
        // still the outage the app was killed during: it began back then
        let started = unfinishedOutage ?? now
        downSince = started
        unfinishedOutage = nil
        retryAt = now.addingTimeInterval(Self.retryInterval)
        UserDefaults.standard.set(started, forKey: Self.outageKey)
        return true
    }

    /// When it went down, if this answer is the moment it came back.
    func recordAnswer() -> Date? {
        failuresInARow = 0
        guard let wentDownAt = downSince ?? unfinishedOutage else { return nil }
        downSince = nil
        unfinishedOutage = nil
        UserDefaults.standard.removeObject(forKey: Self.outageKey)
        return wentDownAt
    }
}

private actor IndexerRequestQueue {
    private let maxConcurrent: Int
    private var permits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(maxConcurrent: Int = 1) {
        self.maxConcurrent = max(1, maxConcurrent)
        self.permits = max(1, maxConcurrent)
    }

    func enqueue<T>(_ operation: @escaping () async throws -> T) async throws -> T {
        await acquire()
        defer { Task { await release() } }
        return try await operation()
    }

    private func acquire() async {
        if permits > 0 {
            permits -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() async {
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.resume()
        } else {
            permits = min(permits + 1, maxConcurrent)
        }
    }
}

struct ErrorResponse: Codable {
    let error: String
}
