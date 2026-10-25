import SwiftUI
import UIKit

// What is left in KaChat of the `.kachat` screens since the market moved to the KaChat wallet
// app (2026-10-24): Edit KaChat Profile (`KachatLiveProfileEditor`, the `kchat:1:profile:`
// record) and the pieces it uses - the transaction-done sheet and the shared helpers. Every
// spending action shows its cost first, asks to confirm, then passes the device's own lock
// (`DeviceAuth`) before anything is signed.

// MARK: - Amounts

extension KaspaUnit {
    /// "35 TKAS", "0.2 TKAS", "1.99831 TKAS": exact, trailing zeros dropped.
    static func amount(_ sompi: UInt64) -> String {
        "\(plain(sompi)) \(symbol)"
    }

    static func plain(_ sompi: UInt64) -> String {
        let whole = sompi / 100_000_000
        let frac = sompi % 100_000_000
        guard frac > 0 else { return "\(whole)" }
        var f = String(format: "%08llu", frac)
        while f.hasSuffix("0") { f.removeLast() }
        return "\(whole).\(f)"
    }

    /// "+1.99 TKAS" / "-36.002 TKAS".
    static func signed(_ delta: Int64) -> String {
        delta >= 0 ? "+\(amount(UInt64(delta)))" : "-\(amount(delta.magnitude))"
    }
}

// MARK: - Shared pieces

enum KachatLive {
    /// The registry is live on this network (testnet only for now) - reads and actions run.
    static var isEnabled: Bool { KachatNamesService.isLaunched }
    /// What the device lock prompt says before any .kachat transaction is signed.
    static var authReason: String { AppLocalization.string("Confirm this .kachat transaction") }
    /// testnet-10 runs at 10 blocks per second
    static let daaPerSecond: UInt64 = 10

    static func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: TimeInterval(ms) / 1000) }

    /// A unix-ms day as a row value ("Oct 12, 2027"), in the in-app language, with the time when
    /// it is within two days (testnet's 24-hour periods).
    static func day(_ ms: Int64) -> String {
        let near = abs(ms - KachatNames.nowMs()) < 2 * 86_400_000
        return date(ms).formatted(Date.FormatStyle(date: .abbreviated, time: near ? .shortened : .omitted).locale(AppLocalization.locale))
    }

    /// The registry parameters, once the manifest is verified.
    @MainActor static var params: KachatNames.Params? { KachatNamesService.shared.manifest?.params }

    /// The receipt's line for a registration: how much stays locked with the name.
    @MainActor static var lockedNote: String? {
        guard let p = params else { return nil }
        return String(format: AppLocalization.string("%@ is locked with this name. It comes back to you when you release it."), KaspaUnit.amount(p.bond + p.gapValue))
    }

    /// Whether a period is a year (mainnet), not a short test clock (testnet's 24 hours).
    @MainActor static var yearlyPeriods: Bool { (params?.periodMs ?? KachatNames.yearMs) == KachatNames.yearMs }

    /// A length of time ("10 min", "10 days"), in the in-app language.
    /// Time left until a moment, for a live countdown: "2d 5h" while days remain, else "1:04:09"
    /// or "4:09" (hours, minutes, seconds).
    static func countdown(_ ms: Int64) -> String {
        let seconds = Double(max(ms, 0)) / 1000
        let f: DateComponentsFormatter
        if seconds >= 86_400 {
            f = componentsFormatter("countdown-days") {
                $0.allowedUnits = [.day, .hour]
                $0.unitsStyle = .abbreviated
                $0.maximumUnitCount = 2
            }
        } else {
            let hours = seconds >= 3600
            f = componentsFormatter(hours ? "countdown-hms" : "countdown-ms") {
                $0.allowedUnits = hours ? [.hour, .minute, .second] : [.minute, .second]
                $0.unitsStyle = .positional
                $0.zeroFormattingBehavior = .pad
            }
        }
        return f.string(from: seconds) ?? ""
    }

    static func duration(_ ms: Int64) -> String {
        let seconds = Double(ms) / 1000
        let units: NSCalendar.Unit = seconds >= 86_400 ? [.day] : (seconds >= 3600 ? [.hour, .minute] : [.minute])
        let f = componentsFormatter("duration-\(units.rawValue)") {
            $0.allowedUnits = units
            $0.unitsStyle = .abbreviated
            $0.maximumUnitCount = 2
        }
        return f.string(from: seconds) ?? ""
    }

    /// One formatter per style and language, not one per call: the Expired page ticks every
    /// tile's countdown once a second.
    private static var componentsFormatters: [String: DateComponentsFormatter] = [:]
    private static let componentsFormattersLock = NSLock()

    private static func componentsFormatter(_ style: String, _ configure: (DateComponentsFormatter) -> Void) -> DateComponentsFormatter {
        let locale = AppLocalization.locale
        let key = style + "|" + locale.identifier
        componentsFormattersLock.lock()
        defer { componentsFormattersLock.unlock() }
        if let known = componentsFormatters[key] { return known }
        let f = DateComponentsFormatter()
        var calendar = Calendar.current
        calendar.locale = locale
        f.calendar = calendar
        configure(f)
        componentsFormatters[key] = f
        return f
    }

    /// `count` periods: "1 year" / "2 years", or on a short clock "10 min" / "20 min".
    @MainActor static func periods(_ count: Int64) -> String {
        if yearlyPeriods {
            return count == 1 ? AppLocalization.string("1 year") : String(format: AppLocalization.string("%lld years"), count)
        }
        return duration(count * (params?.periodMs ?? KachatNames.yearMs))
    }

    /// Who an address is when you haven't named it yourself: its `.kachat` name ("alice.kachat"),
    /// the same rule as `ContactsManager.displayName`. nil without one (mainnet, until names
    /// launch). Views that call this observe `KachatNamesRegistry` so the name lands on its own.
    @MainActor static func identityName(_ address: String) -> String? {
        guard !address.isEmpty else { return nil }
        return KachatNamesRegistry.shared.cachedIdentity(for: address)?.label.map { "\($0).kachat" }
    }

    /// An address's `.kachat` profile banner and bio, each looked up from its social link on this
    /// device (every network: profiles aren't registry data). Callers observe
    /// `KachatNamesRegistry` and `KachatSocialImageResolver`.
    @MainActor static func profileBanner(_ address: String) -> String? {
        let link = KachatNamesRegistry.shared.cachedIdentity(for: address)?.profile?.banner
        return KachatSocialImageResolver.shared.profile(for: link)?.banner
    }

    @MainActor static func profileBio(_ address: String) -> String? {
        let link = KachatNamesRegistry.shared.cachedIdentity(for: address)?.profile?.bio
        return KachatSocialImageResolver.shared.profile(for: link)?.bio
    }

    /// What registering `name` costs for its first period (registry v4: fixed, baked into the
    /// pinned templates). Each further period costs `renewPrice`.
    @MainActor static func price(_ name: String) -> UInt64? {
        guard let prices = KachatNamesRegistry.shared.registerPrices, prices.count == 5 else { return nil }
        return prices[KachatNames.Codec.tier(name.utf8.count)]
    }

    /// What one more period of `name` costs: extend, renew, and registering past the first period.
    @MainActor static func renewPrice(_ name: String) -> UInt64? {
        guard let prices = KachatNamesRegistry.shared.renewPrices, prices.count == 5 else { return nil }
        return prices[KachatNames.Codec.tier(name.utf8.count)]
    }

    /// "Price per year", or on a short clock "Price per 10 min".
    @MainActor static var pricePerPeriodTitle: LocalizedStringKey {
        yearlyPeriods ? "Price per year" : "Price per \(periods(1))"
    }

    /// An event party: an address (indexer) or an x-only key in hex (walker), as a short address.
    static func party(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        if s.hasPrefix("kaspa") { return KachatNamesRegistry.shortAddress(s) }
        if let key = try? KachatNames.unhex32(s), let a = KachatNamesRegistry.address(of: key) {
            return KachatNamesRegistry.shortAddress(a)
        }
        return s
    }

    /// A key of this wallet: the chatting address or any revealed spending address (IOS-085).
    @MainActor static func isMine(_ key: Data) -> Bool { KachatNamesActions.shared.isOwnKey(key) }

    static func eventIcon(_ op: String) -> String {
        switch op {
        case "register": return "at.badge.plus"
        case "transfer": return "arrow.left.arrow.right"
        case "list": return "tag"
        case "delist": return "tag.slash"
        case "sale", "offer_accepted": return "cart"
        case "extend": return "calendar.badge.plus"
        case "renew": return "arrow.clockwise"
        case "release": return "arrow.uturn.backward"
        case "reclaim": return "arrow.3.trianglepath"
        case "import": return "arrow.down.doc"
        default: return "hand.raised"
        }
    }

    static func eventTitle(_ op: String) -> LocalizedStringKey {
        switch op {
        case "register": return "Registered"
        case "transfer": return "Transferred"
        case "list": return "Listed"
        case "delist": return "Delisted"
        case "sale": return "Sold"
        case "offer_accepted", "offer_accept": return "Offer accepted"
        case "extend": return "Extended"
        case "renew": return "Renewed"
        case "release": return "Released"
        case "reclaim": return "Reclaimed"
        case "import": return "Moved to the new registry"
        case "offer": return "Offer made"
        case "offer_withdraw": return "Offer withdrawn"
        case "offer_refund": return "Offer refunded"
        case "offer_decline": return "Offer declined"
        default: return "Activity"
        }
    }

    /// Why a typed name is not a name.
    static func invalidReason(_ name: String) -> LocalizedStringKey? {
        let b = Array(name.utf8)
        if b.isEmpty || b.count > 32 { return "A name is 1 to 32 characters." }
        if !b.allSatisfy({ ($0 >= 0x61 && $0 <= 0x7a) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2d }) {
            return "Use a-z, 0-9 and hyphens only."
        }
        if b.first == 0x2d || b.last == 0x2d { return "A name can't start or end with a hyphen." }
        return nil
    }

    /// Opens (or starts) a 1:1 chat with `address`.
    @MainActor
    static func message(_ address: String) {
        _ = ContactsManager.shared.getOrCreateContact(address: address)
        ChatService.shared.pendingChatNavigation = address
        NotificationCenter.default.post(name: .openChat, object: nil, userInfo: ["contactAddress": address])
    }
}

/// The app's glass card (`.regularMaterial`, hairline, soft shadow).
struct KachatGlass: ViewModifier {
    var cornerRadius: CGFloat = 16

    func body(content: Content) -> some View {
        content.background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.regularMaterial)
                .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).stroke(Color.white.opacity(0.18), lineWidth: 0.8))
                .shadow(color: Color.black.opacity(0.10), radius: 8, x: 0, y: 4)
        )
    }
}

extension View {
    func kachatGlass(cornerRadius: CGFloat = 16) -> some View { modifier(KachatGlass(cornerRadius: cornerRadius)) }
}

// MARK: - A finished transaction

/// A name transaction that went out: what it did and its id, for the half sheet below.
struct KachatTxDone: Identifiable, Equatable {
    var id: String { txId }
    let txId: String
    /// Localization key of the headline ("Listed for sale", "Profile saved", ...).
    var title: String = "Transaction sent"
    /// Already known to be in a block (a registration the driver saw land): no progress to follow.
    var accepted = false
    /// A line under the headline - a registration says how much stays locked with the name.
    var note: String? = nil
}

/// The receipt every name transaction ends on, in the Send receipt's style: what it does, its
/// progress followed on a node - sent, in a block, showing in KaChat - and the transaction id
/// as a link to the block explorer picked in Settings (the testnet-10 one on testnet), opened in
/// the in-app browser. Closing it early is fine: the change still lands.
struct KachatTxDoneSheet: View {
    let done: KachatTxDone
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var actions = KachatNamesActions.shared
    @State private var browserURL: URL?

    private var explorerURL: URL? { AppSettings.load().kaspaExplorer.txURL(for: done.txId) }
    private var stage: KachatNamesActions.TxStage { actions.txStages[done.txId] ?? (done.accepted ? .shown : .sent) }
    private var inBlock: Bool { stage == .accepted || stage == .shown }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch stage {
                case .shown:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.scaled(size: 52))
                        .foregroundColor(.green)
                case .dropped:
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.scaled(size: 52))
                        .foregroundColor(.orange)
                default:
                    ProgressView()
                        .controlSize(.large)
                        .frame(height: 52)
                }
            }
            .padding(.top, 28)

            Text(LocalizedStringKey(done.title))
                .font(.title3.weight(.bold))
                .padding(.top, 12)

            Text(stageText)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
                .padding(.top, 4)

            if let note = done.note {
                Label { Text(verbatim: note) } icon: { Image(systemName: "lock.fill") }
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(.accentColor)
                    .multilineTextAlignment(.leading)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(sendKaspaGlass(cornerRadius: 14))
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
            }

            VStack(alignment: .leading, spacing: 10) {
                step("Sent to the network", done: true)
                step("In a block", done: inBlock, active: !inBlock && stage != .dropped)
                step("Updated in KaChat", done: stage == .shown, active: stage == .accepted)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(sendKaspaGlass(cornerRadius: 16))
            .padding(.horizontal, 20)
            .padding(.top, 18)

            Button {
                browserURL = explorerURL
            } label: {
                HStack(spacing: 6) {
                    Text(verbatim: done.txId)
                        .font(.system(.footnote, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "arrow.up.right.square")
                        .font(.footnote)
                }
                .foregroundColor(.accentColor)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .background(sendKaspaGlass(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .disabled(explorerURL == nil)
            .padding(.horizontal, 20)
            .padding(.top, 12)

            Text("Tap the transaction to open it in the explorer.")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.top, 6)

            Button {
                dismiss()
            } label: {
                Text("Done")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Capsule().fill(Color.accentColor))
                    .foregroundColor(.black)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.top, 18)

            Spacer(minLength: 0)
        }
        .presentationDetents([.height(520), .large])
        .presentationDragIndicator(.visible)
        .task {
            // a transaction this sheet wasn't handed by `perform` (a profile save): follow it here
            if actions.txStages[done.txId] == nil, !done.accepted { actions.follow(txId: done.txId, plan: nil) }
        }
        .fullScreenCover(isPresented: Binding(
            get: { browserURL != nil },
            set: { if !$0 { browserURL = nil } }
        )) {
            if let browserURL {
                InAppBrowserScreen(url: browserURL) { self.browserURL = nil }
            }
        }
    }

    private var stageText: LocalizedStringKey {
        switch stage {
        case .sent, .inMempool: return "Waiting for the network to put it in a block. Usually a few seconds; longer when it's busy."
        case .accepted: return "It's in a block. Updating KaChat..."
        case .shown: return "Done. It shows in KaChat now."
        case .dropped: return "The network hasn't taken it. Nothing was spent if it never lands - try again with a faster fee."
        }
    }

    private func step(_ title: LocalizedStringKey, done: Bool, active: Bool = false) -> some View {
        HStack(spacing: 10) {
            Group {
                if done {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                } else if active {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "circle").foregroundColor(.secondary)
                }
            }
            .frame(width: 20)
            Text(title)
                .font(.subheadline)
                .foregroundColor(done || active ? .primary : .secondary)
        }
    }
}


private struct LabeledRow: View {
    let title: LocalizedStringKey
    let value: String
    var bold = false

    var body: some View {
        HStack {
            Text(title).fontWeight(bold ? .semibold : .regular)
            Spacer()
            Text(verbatim: value)
                .fontWeight(bold ? .semibold : .regular)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
        }
    }
}

// MARK: - Edit KaChat Profile

/// Where a social link's lookup stands - the editor saves only a field whose lookup found what
/// that field shows, so what gets saved is what was reviewed.
enum KachatSocialLookup: Equatable {
    case none, looking, found, empty, unreachable
}

/// One profile field's source (avatar, banner or bio) looked up on this device, showing exactly
/// the piece other people will see.
struct KachatSocialPreview: View {
    let link: String
    let kind: KachatNames.SocialSource.Kind
    @Binding var lookup: KachatSocialLookup

    @ObservedObject private var resolver = KachatSocialImageResolver.shared
    @State private var resolved: KachatNames.SocialProfile?
    @State private var attempt = 0
    /// The lookup whose answer may land: a newer one (edited link, Retry) supersedes it.
    @State private var activeKey = ""

    private var source: KachatNames.SocialSource? { KachatNames.SocialSource(link: link, for: kind) }

    private func piece(_ p: KachatNames.SocialProfile?) -> String? {
        switch kind {
        case .avatar: return p?.avatar
        case .banner: return p?.banner
        case .bio: return p?.bio
        }
    }

    var body: some View {
        // A VStack, not a Group: a Group hands its modifiers to each child, so `.task` below
        // would belong to whichever child shows - and switching from the spinner to the result
        // would cancel it and start the lookup again, endlessly. The VStack is one stable view.
        VStack(alignment: .leading, spacing: 0) {
            if let source {
                switch lookup {
                case .none, .looking:
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Looking up the profile...").font(.footnote).foregroundColor(.secondary)
                    }
                case .found:
                    found(source)
                case .empty:
                    note("person.crop.circle.badge.exclamationmark", missingText(source.platform))
                case .unreachable:
                    HStack(spacing: 10) {
                        Image(systemName: "wifi.exclamationmark").foregroundColor(.secondary)
                        Text(verbatim: String(format: AppLocalization.string("Couldn't reach %@."), source.platform.displayName))
                            .font(.footnote).foregroundColor(.secondary)
                        Spacer()
                        Button("Retry") { attempt += 1 }.font(.footnote.weight(.semibold))
                    }
                }
            }
        }
        // Debounced: one lookup once typing pauses. `attempt` reruns it for Retry. Whatever
        // happens - cancelled, restarted, failed - the state always lands somewhere final.
        .task(id: "\(source?.link ?? "")#\(attempt)") {
            let myKey = "\(source?.link ?? "")#\(attempt)"
            activeKey = myKey
            guard let source else { resolved = nil; lookup = .none; return }
            // The row scrolled back into view (a Form rebuilds its rows): the answer this
            // screen already got shows at once - no debounce, no "Looking up" flash, no
            // refetch. Retry (attempt > 0) still runs the full lookup.
            if attempt == 0, let cached = resolver.cachedProfile(source) {
                resolved = cached
                lookup = piece(cached) == nil ? .empty : .found
                // Still re-checked quietly (the resolver's own 5-minute freshness): a profile
                // changed on the platform lands here without the flash.
                let result = await resolver.resolve(source)
                guard activeKey == myKey, case .answered(let fresh) = result, fresh != cached else { return }
                resolved = fresh
                lookup = piece(fresh) == nil ? .empty : .found
                return
            }
            lookup = .looking
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard activeKey == myKey else { return }
            let result = await resolver.resolve(source)
            guard activeKey == myKey else { return }
            resolved = result.profile
            switch result {
            case .answered(let p):
                lookup = piece(p) == nil ? .empty : .found
            case .unreachable(let cached):
                lookup = piece(cached) == nil ? .unreachable : .found
            }
        }
    }

    @ViewBuilder
    private func found(_ source: KachatNames.SocialSource) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            switch kind {
            case .avatar:
                KNSAvatarView(avatarURLString: resolved?.avatar, fallbackText: "", size: 64)
            case .banner:
                KNSBannerImageView(bannerURLString: resolved?.banner, height: 90, cornerRadius: 8, fitsWidth: true)
            case .bio:
                Text(verbatim: resolved?.bio ?? "").font(.subheadline)
            }
            Text(verbatim: String(format: AppLocalization.string("From %@"), source.platform.displayName))
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func missingText(_ platform: KachatNames.SocialSource.Platform) -> String {
        let key: String
        switch kind {
        case .avatar: key = "No avatar on this %@ profile."
        case .banner: key = "No banner on this %@ profile."
        case .bio: key = "No bio on this %@ profile."
        }
        return String(format: AppLocalization.string(key), platform.displayName)
    }

    private func note(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundColor(.secondary)
            Text(verbatim: text).font(.footnote).foregroundColor(.secondary)
        }
    }
}

/// One profile field's source as the editor holds it: the platform picked and the handle typed.
struct KachatSourceInput: Equatable {
    var platform: KachatNames.SocialSource.Platform = .x
    var handle = ""

    init(platform: KachatNames.SocialSource.Platform = .x, handle: String = "") {
        self.platform = platform
        self.handle = handle
    }

    /// From a stored profile link.
    init(stored link: String?, _ kind: KachatNames.SocialSource.Kind) {
        if let s = KachatNames.SocialSource(link: link ?? "", for: kind) {
            self.init(platform: s.platform, handle: s.displayHandle)
        } else {
            self.init()
        }
    }

    var isEmpty: Bool { handle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func source(_ kind: KachatNames.SocialSource.Kind) -> KachatNames.SocialSource? {
        KachatNames.SocialSource.from(platform: platform, handle: handle, for: kind)
    }

    func isBad(_ kind: KachatNames.SocialSource.Kind) -> Bool { !isEmpty && source(kind) == nil }

    /// The source when the handle field holds a whole pasted link (rather than a handle).
    func pastedSource(_ kind: KachatNames.SocialSource.Kind) -> KachatNames.SocialSource? {
        let t = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.lowercased().hasPrefix("http") || (t.contains(".") && t.contains("/")) else { return nil }
        return source(kind)
    }
}

/// The address profile (KACHAT_NAMES.md section 7): where the avatar, banner and bio come from
/// (a social profile link each - they can be different accounts), a Linktree link, and which of
/// your names labels you - written as a `kchat:1:profile:` self-transfer. No free text and no
/// uploads: what shows comes from a platform that moderates it.
struct KachatLiveProfileEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var registry = KachatNamesRegistry.shared

    /// Each piece's source: a platform from the picker plus the handle typed after its prefix.
    @State private var avatarIn = KachatSourceInput()
    @State private var bannerIn = KachatSourceInput()
    @State private var bioIn = KachatSourceInput()
    @State private var avatarLookup: KachatSocialLookup = .none
    @State private var bannerLookup: KachatSocialLookup = .none
    @State private var bioLookup: KachatSocialLookup = .none
    @State private var linktree = ""
    @State private var primary = ""
    @State private var activeNames: [String] = []
    @State private var loaded = false
    @State private var showSave = false
    @State private var showClear = false

    private typealias Kind = KachatNames.SocialSource.Kind

    private var profile: KachatNames.Profile {
        var p = KachatNames.Profile()
        p.avatar = avatarIn.source(.avatar)?.link
        p.banner = bannerIn.source(.banner)?.link
        p.bio = bioIn.source(.bio)?.link
        p.linktree = KachatNames.Profile.linktreeLink(username: linktree)
        p.primaryName = primary.isEmpty ? nil : primary
        return p.sanitized()
    }

    /// A filled-in field whose lookup hasn't found what it shows (still looking, unreachable, or
    /// nothing there). It doesn't block saving - a social site being slow or unreachable from
    /// this phone must never stop a profile (or a primary name) from saving; the link is saved
    /// as entered and every viewer's app looks it up itself. The editor just says so.
    private func notReviewed(_ input: KachatSourceInput, _ lookup: KachatSocialLookup) -> Bool {
        !input.isEmpty && lookup != .found
    }

    private var hasUncheckedLinks: Bool {
        notReviewed(avatarIn, avatarLookup) || notReviewed(bannerIn, bannerLookup) || notReviewed(bioIn, bioLookup)
    }

    /// Only a malformed handle or Linktree username stops a save.
    private var blocked: Bool {
        avatarIn.isBad(.avatar) || bannerIn.isBad(.banner) || bioIn.isBad(.bio) || badLinktree
    }

    /// The Linktree field holds just the username (`linktr.ee/` is shown in front of it).
    private var badLinktree: Bool {
        let t = linktree.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.isEmpty && KachatNames.Profile.linktreeLink(username: t) == nil
    }

    /// Once one field's account is found, the empty fields take the same account where its
    /// platform can fill them - one handle sets up the whole profile, and each stays editable.
    private func fillEmpty(from input: KachatSourceInput) {
        let fits = { (kind: Kind) in KachatNames.SocialSource.Platform.choices(for: kind).contains(input.platform) }
        if avatarIn.isEmpty, fits(.avatar) { avatarIn = input }
        if bannerIn.isEmpty, fits(.banner) { bannerIn = input }
        if bioIn.isEmpty, fits(.bio) { bioIn = input }
    }

    /// Platform picker, the handle after the platform's prefix, and the preview of what it shows.
    private func sourceField(_ input: Binding<KachatSourceInput>, _ kind: Kind, _ lookup: Binding<KachatSocialLookup>) -> some View {
        Group {
            Picker("Account on", selection: input.platform) {
                ForEach(KachatNames.SocialSource.Platform.choices(for: kind), id: \.self) { p in
                    Text(verbatim: p.displayName).tag(p)
                }
            }
            .pickerStyle(.menu)
            HStack(spacing: 0) {
                Text(verbatim: input.wrappedValue.platform.prefix).foregroundColor(.secondary)
                TextField(input.wrappedValue.platform == .discord ? LocalizedStringKey("invite") : LocalizedStringKey("handle"), text: input.handle)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onChange(of: input.wrappedValue.handle) { _ in
                        // A whole pasted link: switch the picker to its platform, keep the handle.
                        if let pasted = input.wrappedValue.pastedSource(kind) {
                            input.wrappedValue = KachatSourceInput(platform: pasted.platform, handle: pasted.displayHandle)
                        }
                    }
                // One tap empties the field; saving then writes the profile without it.
                if !input.wrappedValue.handle.isEmpty {
                    Button {
                        input.wrappedValue = KachatSourceInput()
                        lookup.wrappedValue = .none
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Clear"))
                }
            }
            // Only while the handle names an account: no empty row, and the lookup starts when it
            // appears.
            if let link = input.wrappedValue.source(kind)?.link {
                KachatSocialPreview(link: link, kind: kind, lookup: lookup)
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label {
                        Text("Your profile belongs to your address, not to a name: it stays the same when you buy, sell or let a name go.")
                            .font(.subheadline)
                    } icon: {
                        Image(systemName: "person.text.rectangle").foregroundColor(.accentColor)
                    }
                } footer: {
                    Text("Each piece comes from a social profile you link, exactly as that platform shows it, so its moderation applies here too. You can use one account for all three, or mix them.")
                }
                Section {
                    sourceField($avatarIn, .avatar, $avatarLookup)
                } header: { Text("Avatar") } footer: {
                    if avatarIn.isBad(.avatar) { invalidHandleNote }
                }
                Section {
                    sourceField($bannerIn, .banner, $bannerLookup)
                } header: { Text("Banner") } footer: {
                    if bannerIn.isBad(.banner) { invalidHandleNote }
                }
                Section {
                    sourceField($bioIn, .bio, $bioLookup)
                } header: { Text("Bio") } footer: {
                    if bioIn.isBad(.bio) { invalidHandleNote }
                }
                Section {
                    HStack(spacing: 0) {
                        Text(verbatim: "linktr.ee/").foregroundColor(.secondary)
                        TextField("username", text: $linktree)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        if !linktree.isEmpty {
                            Button {
                                linktree = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text("Clear"))
                        }
                    }
                } header: { Text("Links") } footer: {
                    if badLinktree {
                        Text("Enter your Linktree username: letters, numbers, dots, dashes or underscores.").foregroundColor(.red)
                    } else {
                        Text("Add your Linktree to point people to your other accounts and websites.")
                    }
                }
                Section {
                    // The primary name needs the registry: until it launches on this network
                    // (mainnet) there's no name to pick, so the profile saves without one.
                    if KachatNamesService.isLaunched {
                        Picker("Primary name", selection: $primary) {
                            Text("None").tag("")
                            ForEach(activeNames, id: \.self) { n in Text(verbatim: "\(n).kachat").tag(n) }
                        }
                    } else {
                        HStack {
                            Text("Primary name")
                            Spacer()
                            Text("Coming soon").foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text(".kachat Name")
                } footer: {
                    if KachatNamesService.isLaunched {
                        Text("KaChat shows you by your primary name while you own it and it's active; otherwise by your oldest active name, or your address.")
                    } else {
                        Text(".kachat names aren't on mainnet yet. Your avatar, banner, bio and links save now; you can pick a primary name once names launch.")
                    }
                }
                Section {
                    Button {
                        showSave = true
                    } label: {
                        HStack { Spacer(); Text("Save Profile").font(.headline); Spacer() }
                    }
                    // Saves on every network: a profile is a self-send, with no registry behind it.
                    .disabled(!loaded || blocked || !KachatNamesService.profilesEnabled)
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if hasUncheckedLinks {
                            Text("Some links couldn't be checked from this phone right now. They're saved as entered, and people's apps load them when they can.")
                        }
                        Text("Saving writes your profile to the chain from your address to itself, for a network fee. Profiles are public.")
                    }
                }
                Section {
                    Button(role: .destructive) {
                        showClear = true
                    } label: {
                        HStack { Spacer(); Text("Clear Profile").font(.headline); Spacer() }
                    }
                    // Same gate as saving: a clear IS a save, of the empty record.
                    .disabled(!loaded || !KachatNamesService.profilesEnabled)
                } footer: {
                    Text("Clearing writes an empty profile to the chain from your address to itself, for a network fee, so KaChat shows nothing for your address again.")
                }
            }
            .sheet(isPresented: $showSave) {
                KachatProfileSaveSheet(title: "Save Profile", confirmTitle: "Save Profile", doneTitle: "Profile saved",
                                       makeProfile: { profile }, onSaved: { dismiss() })
            }
            // The newest record is the whole profile, so the empty record IS "this address has
            // nothing": the indexer and every app show nothing for it from then on.
            .sheet(isPresented: $showClear) {
                KachatProfileSaveSheet(title: "Clear Profile", confirmTitle: "Clear Profile", doneTitle: "Profile cleared",
                                       makeProfile: { KachatNames.Profile() }, onSaved: { dismiss() })
            }
            .onChange(of: avatarLookup) { v in if v == .found { fillEmpty(from: avatarIn) } }
            .onChange(of: bannerLookup) { v in if v == .found { fillEmpty(from: bannerIn) } }
            .onChange(of: bioLookup) { v in if v == .found { fillEmpty(from: bioIn) } }
            .navigationTitle("Edit KaChat Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { await load() }
        }
    }

    private var invalidHandleNote: some View {
        Text("That doesn't look like a handle on this platform.").foregroundColor(.red)
    }

    private func load() async {
        guard let address = KachatNamesActions.shared.myAddress else { loaded = true; return }
        await registry.refreshIfStale()
        // start from the newest profile, wherever it was saved (another device included)
        await registry.syncOwnProfile(address: address)
        var p = registry.ownProfile(for: address)?.profile
        if p == nil { p = try? await registry.identity(address: address).profile }
        if let p {
            avatarIn = KachatSourceInput(stored: p.avatar, .avatar)
            bannerIn = KachatSourceInput(stored: p.banner, .banner)
            bioIn = KachatSourceInput(stored: p.bio, .bio)
            linktree = KachatNames.Profile.linktreeUsername(p.linktree)
        }
        if let key = KachatNamesRegistry.keyOf(address) {
            activeNames = ((try? await registry.names(owner: key, includeInactive: false)) ?? []).map(\.name)
        }
        if let pn = p?.primaryName, activeNames.contains(pn) { primary = pn }
        loaded = true
    }

}

/// Review before a profile record goes out - what will be saved, the network fee, the chatting
/// address's balance before and after - the same confirmation every other name action shows.
/// Used by Edit KaChat Profile and by Set as Primary.
struct KachatProfileSaveSheet: View {
    let title: LocalizedStringKey
    let confirmTitle: LocalizedStringKey
    /// The finished-transaction half sheet's headline (a localization key).
    let doneTitle: String
    /// Builds the record to save when the sheet opens (Set as Primary reads your current profile).
    let makeProfile: () async -> KachatNames.Profile
    var onSaved: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var profile: KachatNames.Profile?
    @State private var fee: UInt64?
    @State private var quoteError: String?
    @State private var sending = false
    @State private var sendError: String?
    @State private var done: KachatTxDone?
    /// The "not enough funds" popup: the chatting address's QR to fund it. It opens by itself
    /// once per sheet; after that the Fund button under the message opens it (IOS-084).
    @State private var showFunding = false
    @State private var fundingShownOnce = false
    /// The last quote or save failed for lack of funds: the Fund button shows.
    @State private var shortOfFunds = false
    @AppStorage("kachat_profile_privacy_seen") private var privacySeen = false

    private static var notEnoughFundsMessage: String {
        KaspaUnit.label(AppLocalization.string("You don't have enough funds. Please send at least 1 KAS to your chatting address."))
    }

    /// The save can't be paid: the chatting address has no spendable coin, or too little for
    /// the fee - read from the error alone (an unreachable node is not "no funds").
    private func isShortOfFunds(_ error: Error) -> Bool {
        if case let KasiaError.networkError(message) = error, message.localizedCaseInsensitiveContains("insufficient") {
            return true
        }
        return false
    }

    /// Short of funds: the popup the first time, the Fund button after that.
    private func noteShortOfFunds() {
        shortOfFunds = true
        if !fundingShownOnce {
            fundingShownOnce = true
            showFunding = true
        }
    }

    private func source(_ link: String?, _ kind: KachatNames.SocialSource.Kind) -> String {
        guard let s = KachatNames.SocialSource(link: link ?? "", for: kind) else { return AppLocalization.string("None") }
        return "\(s.platform.displayName) · \(s.platform.prefix)\(s.displayHandle)"
    }

    var body: some View {
        NavigationStack {
            Form {
                if let profile {
                    Section {
                        LabeledRow(title: "Avatar", value: source(profile.avatar, .avatar))
                        LabeledRow(title: "Banner", value: source(profile.banner, .banner))
                        LabeledRow(title: "Bio", value: source(profile.bio, .bio))
                        LabeledRow(title: "Linktree", value: profile.linktree.map { $0.replacingOccurrences(of: "https://", with: "") } ?? AppLocalization.string("None"))
                        LabeledRow(title: "Primary name", value: profile.primaryName.map { "\($0).kachat" } ?? AppLocalization.string("None"))
                    } header: {
                        Text("Your Profile")
                    }
                }
                Section {
                    if let fee {
                        LabeledRow(title: "Network fee", value: KaspaUnit.amount(fee))
                        if let balance = WalletManager.shared.currentWallet?.balanceSompi {
                            LabeledRow(title: "Chatting address balance", value: KaspaUnit.amount(balance))
                            LabeledRow(title: "Balance after", value: KaspaUnit.amount(balance > fee ? balance - fee : 0), bold: true)
                        }
                    } else if quoteError == nil {
                        HStack { Text("Network fee"); Spacer(); ProgressView() }
                    }
                } footer: {
                    if let quoteError {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(verbatim: quoteError).foregroundColor(.red)
                            if shortOfFunds {
                                Button {
                                    showFunding = true
                                } label: {
                                    Label("Fund", systemImage: "qrcode")
                                        .font(.subheadline.weight(.semibold))
                                }
                            }
                        }
                    } else if privacySeen {
                        Text("Saved on chain from your chatting address to itself.")
                    } else {
                        Text("Profiles are public and on chain: anyone can read them, and earlier versions stay readable after you change them.")
                    }
                }
                Section {
                    Button {
                        authorize()
                    } label: {
                        HStack { Spacer(); if sending { ProgressView() } else { Text(confirmTitle).font(.headline) }; Spacer() }
                    }
                    .disabled(fee == nil || profile == nil || sending || done != nil)
                } footer: {
                    if let sendError {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(verbatim: sendError).foregroundColor(.red)
                            if shortOfFunds {
                                Button {
                                    showFunding = true
                                } label: {
                                    Label("Fund", systemImage: "qrcode")
                                        .font(.subheadline.weight(.semibold))
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .task { await quote() }
            .sheet(item: $done, onDismiss: { dismiss(); onSaved() }) { KachatTxDoneSheet(done: $0) }
            // Closes by itself once 1 KAS has arrived; either way the fee is worked out again.
            .sheet(isPresented: $showFunding, onDismiss: {
                quoteError = nil
                sendError = nil
                fee = nil
                Task { await quote() }
            }) {
                // closes once any KAS arrives; the fee is then worked out again
                ZeroBalanceFundingSheetView(title: Self.notEnoughFundsMessage)
            }
        }
    }

    private func quote() async {
        let p = await makeProfile()
        profile = p
        do {
            fee = try await KachatNamesActions.shared.profileFee(p)
            shortOfFunds = false
        } catch {
            if isShortOfFunds(error) {
                quoteError = Self.notEnoughFundsMessage
                noteShortOfFunds()
            } else {
                quoteError = error.localizedDescription
            }
        }
    }

    private func authorize() {
        guard let profile else { return }
        DeviceAuth.authenticate(reason: KachatLive.authReason) {
            Task { @MainActor in
                sending = true
                sendError = nil
                do {
                    let tx = try await KachatNamesActions.shared.saveProfile(profile)
                    privacySeen = true
                    done = KachatTxDone(txId: tx, title: doneTitle)
                    Haptics.success()
                } catch {
                    if isShortOfFunds(error) {
                        sendError = Self.notEnoughFundsMessage
                        noteShortOfFunds()
                    } else {
                        sendError = error.localizedDescription
                    }
                }
                sending = false
            }
        }
    }
}

// MARK: - Your Domains > .kachat

/// Your Domains > .kachat: the names this wallet holds, each with when it expires (or, in its
/// grace period, when that ends). Read-only - buying, renewing, selling and transferring them
/// happens in KaChat Wallet since the market left this app (2026-10-24).
struct KachatOwnedNamesList: View {
    let walletAddress: String
    @ObservedObject private var registry = KachatNamesRegistry.shared
    @ObservedObject private var service = KachatNamesService.shared
    @State private var names: [KachatNames.NameInfo] = []
    @State private var loaded = false

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                if !loaded {
                    ProgressView().padding(.vertical, 24)
                } else if service.registryUpgrading {
                    // the bundled manifest is for the previous registry: calm, no error
                    VStack(spacing: 10) {
                        Image(systemName: "hammer")
                            .font(.system(size: 40, weight: .semibold))
                            .foregroundColor(.accentColor)
                        Text("Setting up")
                            .font(.headline)
                        Text("The .kachat registry is being upgraded. Names open here again once the new registry is live.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                } else if names.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "at.circle")
                            .font(.system(size: 44, weight: .semibold))
                            .foregroundColor(.accentColor)
                        Text("No .kachat names yet")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                } else {
                    ForEach(names) { n in
                        DomainNameCardView(title: n.display, badge: Self.badge(for: n, graceMs: registry.graceMs),
                                           footnote: Self.expiryLine(for: n, graceMs: registry.graceMs))
                    }
                }
                Text("Buy, renew, sell and transfer .kachat names in KaChat Wallet.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
            }
            .padding()
        }
        .refreshable { await registry.refresh() }
        .task(id: registry.revision) {
            await load()
            // a name that lapses while this is open leaves right then
            await registry.dropLapsed(from: names) { names = $0 }
        }
    }

    /// The card's bottom-right corner: when the name expires - or, once it has, when its grace
    /// period ends (renew before then to keep it).
    static func expiryLine(for n: KachatNames.NameInfo, graceMs: Int64) -> String? {
        switch n.status(graceMs: graceMs) {
        case .active: return String(format: AppLocalization.string("Expires %@"), KachatLive.day(n.expiresAt))
        case .grace: return String(format: AppLocalization.string("Grace ends %@"), KachatLive.day(n.expiresAt + graceMs))
        case .lapsed: return nil
        }
    }

    /// The card badge: Listed, or Expired (in grace).
    static func badge(for n: KachatNames.NameInfo, graceMs: Int64) -> String? {
        switch n.status(graceMs: graceMs) {
        case .active: return n.isListed ? AppLocalization.string("Listed") : nil
        case .grace: return AppLocalization.string("Expired")
        case .lapsed: return nil
        }
    }

    /// Your own list (the chatting address's) holds the names on every address of this wallet;
    /// any other address lists its own. Lapsed names aren't yours any more and aren't listed.
    private func load() async {
        guard let key = KachatNamesRegistry.keyOf(walletAddress) else { loaded = true; return }
        if registry.refreshedAt == nil { await registry.refresh() }
        if walletAddress.lowercased() == KachatNamesActions.shared.myAddress,
           let own = try? await KachatNamesActions.shared.ownNamesAndOffers(heldOnly: true) {
            names = own.names
        } else {
            names = (try? await registry.heldNames(owner: key)) ?? []
        }
        loaded = true
    }
}
