import SwiftUI

/// One kind of KaChat transaction the stats screen counts. The raw value is the key in the
/// indexer's `GET /stats` response (STATS_INDEXER.md), so it is part of that contract - don't
/// rename a case without the server.
enum KaChatStatCategory: String, CaseIterable, Identifiable {
    case messages, handshakes, payments
    case groupMessages, groupUpdates, publicChats
    case kaposts, kapostActions
    case chessMoves, chessGames
    /// .kachat names (registry transactions). An indexer reports them only where names are
    /// live, so on a network without the registry yet (mainnet before launch) they stay hidden.
    case kachatRegistrations, kachatRenewals, kachatSales, kachatOffers, kachatActivity
    case selfStash

    var id: String { rawValue }

    /// One of the .kachat registry kinds - shown together as the .kachat Domains card.
    var isKachat: Bool {
        switch self {
        case .kachatRegistrations, .kachatRenewals, .kachatSales, .kachatOffers, .kachatActivity: return true
        default: return false
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .messages: return "Direct Messages"
        case .handshakes: return "New Chats"
        case .payments: return "Payments"
        case .groupMessages: return "Group Messages"
        case .groupUpdates: return "Group Updates"
        case .publicChats: return "Public Chats"
        case .kaposts: return "KaPosts"
        case .kapostActions: return "KaPost Activity"
        case .chessMoves: return "Chess Moves"
        case .chessGames: return "Chess Games"
        case .kachatRegistrations: return "Names Registered"
        case .kachatRenewals: return "Name Renewals"
        case .kachatSales: return "Name Sales"
        case .kachatOffers: return "Name Offers"
        case .kachatActivity: return "Name Activity"
        case .selfStash: return "Saved Records"
        }
    }

    var detail: LocalizedStringKey {
        switch self {
        case .messages: return "1:1 texts, voice notes, reactions and 1:1 chess"
        case .handshakes: return "Handshakes that start a 1:1 chat"
        case .payments: return "KAS sent in chats"
        case .groupMessages: return "Messages in group chats"
        case .groupUpdates: return "Creating groups, invites and other changes"
        case .publicChats: return "Messages in public rooms"
        case .kaposts: return "Posts, replies, quotes and polls"
        case .kapostActions: return "Votes, follows, edits and deletes"
        case .chessMoves: return "Moves played in Chess Online"
        case .chessGames: return "Games started in Chess Online"
        case .kachatRegistrations: return ".kachat names claimed"
        case .kachatRenewals: return ".kachat names extended or renewed"
        case .kachatSales: return ".kachat names bought from a listing or through an accepted offer"
        case .kachatOffers: return "Offers made on .kachat names"
        case .kachatActivity: return "Listings, transfers, releases, reclaims and returned offers"
        case .selfStash: return "Chat keys and contact notes saved to your own account"
        }
    }

    var icon: String {
        switch self {
        case .messages: return "bubble.left.and.bubble.right.fill"
        case .handshakes: return "hand.wave.fill"
        case .payments: return "paperplane.fill"
        case .groupMessages: return "person.3.fill"
        case .groupUpdates: return "person.badge.plus"
        case .publicChats: return "dot.radiowaves.left.and.right"
        case .kaposts: return "text.bubble.fill"
        case .kapostActions: return "hand.thumbsup.fill"
        case .chessMoves: return "checkerboard.rectangle"
        case .chessGames: return "trophy.fill"
        case .kachatRegistrations: return "at.badge.plus"
        case .kachatRenewals: return "arrow.clockwise.circle.fill"
        case .kachatSales: return "cart.fill"
        case .kachatOffers: return "hand.raised.fill"
        case .kachatActivity: return "tag.fill"
        case .selfStash: return "tray.full.fill"
        }
    }

    var color: Color {
        switch self {
        case .messages: return .blue
        case .handshakes: return .cyan
        case .payments: return .green
        case .groupMessages: return .indigo
        case .groupUpdates: return .teal
        case .publicChats: return .orange
        case .kaposts: return .pink
        case .kapostActions: return .purple
        case .chessMoves: return .brown
        case .chessGames: return .yellow
        case .kachatRegistrations: return .mint
        case .kachatRenewals: return Color(red: 0.0, green: 0.55, blue: 0.5)
        case .kachatSales: return .red
        case .kachatOffers: return Color(red: 0.85, green: 0.55, blue: 0.1)
        case .kachatActivity: return Color(red: 0.45, green: 0.45, blue: 0.75)
        case .selfStash: return .gray
        }
    }
}

enum KaChatStatRange: String, CaseIterable, Hashable {
    case day, week, all

    var title: String {
        switch self {
        case .day: return "24 Hours"
        case .week: return "7 Days"
        case .all: return "All Time"
        }
    }

    var caption: LocalizedStringKey {
        switch self {
        case .day: return "KaChat transactions in the last 24 hours"
        case .week: return "KaChat transactions in the last 7 days"
        case .all: return "KaChat transactions on Kaspa, all time"
        }
    }
}

/// One category's counts as an indexer reports them. Every field is optional: a server that
/// only keeps an all-time counter still works, the shorter ranges just show a dash.
struct KaChatStatCounts: Decodable, Equatable {
    let total: Int64?
    let last24h: Int64?
    let last7d: Int64?

    func value(for range: KaChatStatRange) -> Int64? {
        switch range {
        case .day: return last24h
        case .week: return last7d
        case .all: return total
        }
    }
}

struct KaChatStatsSnapshot: Equatable {
    var counts: [KaChatStatCategory: KaChatStatCounts]
    var updatedAt: Date?
    var indexedSince: Date?
    var fetchedAt: Date
}

/// Fetches and holds the stats. Shared so switching tabs and coming back doesn't refetch: a
/// snapshot younger than a minute is reused unless the user pulls to refresh.
@MainActor
final class KaChatStatsModel: ObservableObject {
    static let shared = KaChatStatsModel()

    enum Failure: Equatable {
        /// No KaChat indexer is set for this network (testnet, for now).
        case noIndexer
        /// No indexer answered `/stats` with anything this app knows.
        case unavailable
    }

    @Published private(set) var snapshot: KaChatStatsSnapshot?
    @Published private(set) var failure: Failure?
    @Published private(set) var isLoading = false

    private var sourceKey = ""
    private static let freshFor: TimeInterval = 60

    func refresh(force: Bool) async {
        let bases = Self.indexerBases()
        let key = bases.joined(separator: "|")
        if key != sourceKey {
            // Another network or indexer: the old numbers aren't this server's.
            sourceKey = key
            snapshot = nil
            failure = nil
        }
        guard !bases.isEmpty else {
            failure = .noIndexer
            return
        }
        if !force, let snapshot, Date().timeIntervalSince(snapshot.fetchedAt) < Self.freshFor { return }
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        let fetched = await Self.fetch(from: bases)
        guard key == sourceKey else { return }
        if let fetched {
            snapshot = fetched
            failure = nil
        } else {
            // Keep showing the last numbers, if there are any; the screen says they're stale.
            failure = .unavailable
        }
    }

    /// Every KaChat indexer this network is configured with, deduplicated - by default they are
    /// all the same server, so this is one request.
    private static func indexerBases() -> [String] {
        let settings = AppSettings.load()
        var seen = Set<String>()
        return [settings.indexerURL, settings.publicChatIndexerURL, settings.kaPostIndexerURL]
            .map { url -> String in
                var trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
                while trimmed.hasSuffix("/") { trimmed.removeLast() }
                return trimmed
            }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    private struct Response: Decodable {
        let updatedAt: Int64?
        let indexedSince: Int64?
        let categories: [String: KaChatStatCounts]
    }

    /// Asks each indexer for `/stats` and merges: a category comes from the first indexer (in
    /// settings order) that reports it, so one server can report everything or each its own
    /// slice. Nil when none of them reports a single category this app knows.
    private nonisolated static func fetch(from bases: [String]) async -> KaChatStatsSnapshot? {
        let responses = await withTaskGroup(of: (Int, Response?).self) { group -> [Response] in
            for (index, base) in bases.enumerated() {
                group.addTask { (index, await fetchOne(base)) }
            }
            var collected: [(Int, Response)] = []
            for await (index, response) in group {
                if let response { collected.append((index, response)) }
            }
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }

        var counts: [KaChatStatCategory: KaChatStatCounts] = [:]
        for response in responses {
            for (key, value) in response.categories {
                guard let category = KaChatStatCategory(rawValue: key), counts[category] == nil else { continue }
                counts[category] = value
            }
        }
        guard !counts.isEmpty else { return nil }

        func date(_ ms: Int64?) -> Date? { ms.map { Date(timeIntervalSince1970: Double($0) / 1000) } }
        return KaChatStatsSnapshot(
            counts: counts,
            updatedAt: responses.compactMap { date($0.updatedAt) }.max(),
            indexedSince: responses.compactMap { date($0.indexedSince) }.min(),
            fetchedAt: Date()
        )
    }

    private nonisolated static func fetchOne(_ base: String) async -> Response? {
        guard let url = URL(string: "\(base)/stats") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) { return nil }
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            return nil
        }
    }
}

/// Kaspa Hub > KaChat Stats: how many transactions KaChat has put on Kaspa, split by kind -
/// direct messages, payments, group and public chat messages, KaPosts, chess moves and so on.
///
/// The numbers are the indexers' (`GET /stats`, STATS_INDEXER.md), never this phone's own
/// traffic. A category no indexer reports is left out rather than shown as zero; while loading,
/// or when the indexer has no stats yet, the rows keep their real names with the numbers
/// redacted, so nothing invented is ever on screen.
struct KaChatStatsView: View {
    enum Page: Hashable { case transactions, fees }

    @ObservedObject private var model = KaChatStatsModel.shared
    @State private var page: Page = .transactions
    @State private var showInfo = false
    /// .kachat registry transactions and what they paid (sompi), over 24 hours, 7 days and all
    /// time - from the registry itself (its indexer, or the chain), so it shows wherever names
    /// are live.
    @State private var kachatTransactions: KachatNamesRegistry.Totals?
    @State private var kachatFees: KachatNamesRegistry.Totals?
    @State private var kachatLoaded = false

    /// The kinds with a card of their own. .kachat's five are one card, .kachat Domains.
    private static let chatCategories = KaChatStatCategory.allCases.filter { !$0.isKachat }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    hero
                    UnderlineTabBar(
                        tabs: [(tab: Page.transactions, title: "Transactions"), (tab: Page.fees, title: "Fees")],
                        selection: $page
                    )
                    switch page {
                    case .transactions: transactionsPage
                    case .fees: feesPage
                    }
                    footer
                }
                .padding(.bottom, 28)
            }
            .background(Color(.systemGroupedBackground))
            .refreshable {
                await model.refresh(force: true)
                await loadKachat()
            }
            .task {
                await model.refresh(force: false)
                await loadKachat()
            }
            .navigationTitle("KaChat Stats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { ConnectionStatusIndicator() }
                ToolbarItem(placement: .principal) { BalanceToolbarLabel() }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showInfo = true
                    } label: {
                        Image(systemName: "questionmark.circle")
                    }
                    .accessibilityLabel(Text("What counts"))
                }
            }
            .sheet(isPresented: $showInfo) { infoSheet }
        }
    }

    // MARK: - Numbers

    private func loadKachat() async {
        guard KachatLive.isEnabled else {
            kachatTransactions = nil
            kachatFees = nil
            kachatLoaded = true
            return
        }
        let registry = KachatNamesRegistry.shared
        await registry.refreshIfStale()
        if let totals = try? await registry.activityTotals() {
            kachatTransactions = totals.transactions
            kachatFees = totals.fees
        }
        kachatLoaded = true
    }

    /// The .kachat Domains counts: the registry's own, else the indexer's five .kachat kinds
    /// added up.
    private var kachatTotals: KachatNamesRegistry.Totals? {
        if let kachatTransactions { return kachatTransactions }
        guard let snapshot = model.snapshot else { return nil }
        let counts = KaChatStatCategory.allCases.filter(\.isKachat).compactMap { snapshot.counts[$0] }
        guard !counts.isEmpty else { return nil }
        func sum(_ value: (KaChatStatCounts) -> Int64?) -> UInt64 {
            counts.reduce(0) { $0 + UInt64(max(value($1) ?? 0, 0)) }
        }
        return KachatNamesRegistry.Totals(last24h: sum(\.last24h), last7d: sum(\.last7d), total: sum(\.total))
    }

    /// Every KaChat transaction, all time: each kind's all-time count plus .kachat's.
    private var allTimeTotal: Int64? {
        var sum: Int64 = 0
        var any = false
        if let snapshot = model.snapshot {
            for category in Self.chatCategories {
                if let total = snapshot.counts[category]?.total {
                    sum += total
                    any = true
                }
            }
        }
        if let kachat = kachatTotals {
            sum += Int64(kachat.total)
            any = true
        }
        return any ? sum : nil
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(spacing: 6) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 34, weight: .semibold))
                .foregroundColor(.accentColor)
                .padding(.bottom, 4)
            Group {
                if let total = allTimeTotal {
                    Text(total.formatted())
                } else if model.snapshot != nil || model.failure != nil {
                    Text(verbatim: "—")
                } else {
                    Text(verbatim: "000,000").redacted(reason: .placeholder)
                }
            }
            .font(.system(size: 44, weight: .heavy, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            Text("KaChat transactions on Kaspa, all time")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
    }

    // MARK: - Pages

    @ViewBuilder
    private var transactionsPage: some View {
        if let snapshot = model.snapshot {
            ForEach(Self.chatCategories.filter { snapshot.counts[$0] != nil }) { category in
                let counts = snapshot.counts[category]
                statCard(icon: category.icon, color: category.color, title: category.title, detail: category.detail,
                         values: [counts?.last24h, counts?.last7d, counts?.total].map { $0.map { $0.formatted() } })
            }
        } else {
            if let failure = model.failure, !model.isLoading {
                unavailableCard(failure)
            }
            ForEach(Self.chatCategories) { category in
                statCard(icon: category.icon, color: category.color, title: category.title, detail: category.detail,
                         values: [], redacted: true)
            }
        }
        if let kachat = kachatTotals {
            statCard(icon: "at", color: .mint, title: ".kachat Domains", detail: "Transactions on the .kachat registry",
                     values: [kachat.last24h, kachat.last7d, kachat.total].map { Optional($0.formatted()) })
        }
    }

    @ViewBuilder
    private var feesPage: some View {
        if let fees = kachatFees {
            statCard(icon: "at", color: .mint, title: ".kachat Domains", detail: "Paid for registrations and renewals",
                     values: [fees.last24h, fees.last7d, fees.total].map { Optional(KaspaUnit.amount($0)) })
        } else if kachatLoaded {
            VStack(spacing: 6) {
                Text("Fees aren't available yet")
                    .font(.headline)
                Text("Your indexer doesn't report them yet. They'll show here once it does.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(18)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
            .padding(.horizontal, 16)
        } else {
            statCard(icon: "at", color: .mint, title: ".kachat Domains", detail: "Paid for registrations and renewals",
                     values: [], redacted: true)
        }
    }

    // MARK: - Cards

    /// One kind: its icon, name and what it counts, then its 24 Hours, 7 Days and All Time
    /// figures side by side. A figure the indexer doesn't keep shows a dash.
    private func statCard(icon: String, color: Color, title: LocalizedStringKey, detail: LocalizedStringKey,
                          values: [String?], redacted: Bool = false) -> some View {
        card {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(color))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Text(detail)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)
            Divider().padding(.leading, 60)
            HStack(spacing: 0) {
                ForEach(Array(KaChatStatRange.allCases.enumerated()), id: \.element) { index, range in
                    if index > 0 { Divider().frame(height: 34) }
                    statColumn(range.title, index < values.count ? values[index] : nil, redacted: redacted)
                }
            }
            .padding(.vertical, 12)
        }
    }

    private func statColumn(_ title: String, _ value: String?, redacted: Bool) -> some View {
        VStack(spacing: 4) {
            Group {
                if redacted {
                    Text(verbatim: "0,000").redacted(reason: .placeholder)
                } else if let value {
                    Text(verbatim: value)
                } else {
                    Text(verbatim: "—").foregroundColor(.secondary)
                }
            }
            .font(.headline)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            Text(LocalizedStringKey(title))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 4)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0, content: content)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
            .padding(.horizontal, 16)
    }

    // MARK: - States and footer

    private func unavailableCard(_ failure: KaChatStatsModel.Failure) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 28, weight: .semibold))
                .foregroundColor(.secondary)
            switch failure {
            case .noIndexer:
                Text("No indexer is set for this network")
                    .font(.headline)
                Text("Add one in Settings > Connection Settings to see KaChat stats.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            case .unavailable:
                Text("Stats aren't available yet")
                    .font(.headline)
                Text("Your indexer doesn't report KaChat stats yet. They'll show here once it does.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                Button("Try Again") {
                    Task { await model.refresh(force: true) }
                }
                .buttonStyle(.bordered)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var footer: some View {
        if let snapshot = model.snapshot {
            VStack(spacing: 4) {
                if model.failure == .unavailable {
                    Text("Couldn't refresh. Showing the last numbers.")
                }
                Text("Updated \(Self.relative(snapshot.updatedAt ?? snapshot.fetchedAt))")
                if let since = snapshot.indexedSince {
                    Text("Counting since \(since.formatted(date: .abbreviated, time: .omitted))")
                }
            }
            .font(.footnote)
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
        }
    }

    private static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: min(date, Date()), relativeTo: Date())
    }

    // MARK: - What counts

    private var infoSheet: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(KaChatStatCategory.allCases) { category in
                        HStack(alignment: .top, spacing: 14) {
                            Image(systemName: category.icon)
                                .font(.title3)
                                .foregroundColor(category.color)
                                .frame(width: 30)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(category.title).font(.subheadline.weight(.semibold))
                                Text(category.detail).font(.subheadline).foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("Every KaChat action is its own Kaspa transaction. These totals come from KaChat's indexer, counting what it has seen on chain - nothing is read from your phone.")
                        .textCase(nil)
                } footer: {
                    Text("1:1 messages are encrypted, so voice notes, reactions and 1:1 chess moves count as direct messages: nobody, the indexer included, can tell them apart.")
                }
            }
            .navigationTitle("What counts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showInfo = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
