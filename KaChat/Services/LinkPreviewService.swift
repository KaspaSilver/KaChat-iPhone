import Foundation
import CryptoKit
import ImageIO
import UIKit

// MARK: - Internal KaChat links

/// A link that points back INSIDE KaChat rather than out at the web. Recognized anywhere a
/// message body is rendered so it previews as a native in-app card and opens the target screen
/// on tap, instead of leaving the app (or, for the universal-link form, being scraped over the
/// network like any stranger's URL - see `LinkPreviewService`).
///
/// Wire contract, shared with the Android client (both platforms emit AND accept both forms):
///
/// | Target         | Custom scheme                  | Universal link                                    |
/// |----------------|--------------------------------|---------------------------------------------------|
/// | Profile          | `kachat://profile/<address>`   | `https://kachat.app/u/<address>`                  |
/// | KaPost post      | `kachat://kapost/<txid>` (or `kaposts://kapost/<txid>`) | `https://kachat.app/post/<txid>` |
/// | Payment request  | `kachat://pay/<address>?amount=<KAS>&memo=<text>[&chat=1]&by=<address>&sig=<hex>` | `https://kachat.app/pay/<address>?…` |
///
/// `<address>` is a full Kaspa address; in the universal form a mainnet address may drop its
/// `kaspa:` prefix (the app writes it without, so the link reads cleanly), and a missing
/// prefix means mainnet.
/// Everything a pasted link carries is attacker-controlled, so `parse` re-validates every
/// address from scratch rather than trusting the URL's text.
///
/// A KaPost post link opens the post in KaPost (`KaPostHandoff`): KaPosts left KaChat on
/// 2026-10-24 for its own app. Public Chat room links (`/broadcast/`, `kachat://broadcast/`)
/// are no longer internal, so such a link is an ordinary web link to kachat.app.
enum KaChatInternalLink: Equatable {
    /// Someone's KaChat profile: opens their User Info (yours too, for your own link).
    case profile(address: String)
    /// A post on KaPost: opens it in the KaPost app (`KaPostHandoff`).
    case kaPost(txId: String)
    /// A request to be paid: opens Send Kaspa with the address, amount and memo filled in
    /// (`PaymentRequest`).
    case paymentRequest(PaymentRequest)

    /// The universal-link host - the only host the app ever writes into a share. With KaChat
    /// installed iOS opens these links in the app; without it, kachat.app shows the profile or
    /// request with the download buttons, and unfurls a preview in every chat app
    /// (see KACHAT_APP_LINKS.md).
    static let universalLinkHost = "kachat.app"

    /// The one profile link every share button hands out - your own (Profile, beside the title)
    /// and anyone else's (User Info > Share) - so the two can never drift apart:
    /// `https://kachat.app/u/<address without kaspa:>`, lowercased and trimmed.
    static func profileShareURL(for address: String) -> URL? {
        let normalized = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        return URL(string: KaChatInternalLink.profile(address: normalized).universalLinkString)
    }

    /// The https form of the link - survives apps that strip unknown schemes, and
    /// falls back to the web/App Store for people who don't have KaChat installed.
    var universalLinkString: String {
        switch self {
        case .profile(let address):
            let path = address.hasPrefix("kaspa:") ? String(address.dropFirst("kaspa:".count)) : address
            return "https://\(Self.universalLinkHost)/u/\(path)"
        case .paymentRequest(let request):
            return "https://\(Self.universalLinkHost)/pay/\(request.linkTail)"
        case .kaPost(let txId):
            return "https://\(Self.universalLinkHost)/post/\(txId)"
        }
    }

    // MARK: Parsing

    /// Both link forms -> a validated target, or nil for anything else (including a
    /// well-formed-looking link whose payload fails validation).
    static func parse(_ url: URL) -> KaChatInternalLink? {
        guard let scheme = url.scheme?.lowercased() else { return nil }
        // `pathComponents` percent-decodes for us, and drops the leading "/" marker below.
        let parts = url.pathComponents.filter { $0 != "/" }
        switch scheme {
        case "kachat":
            // kachat://<target>/<payload> - exactly one payload component, so a link with extra
            // path segments (kachat://profile/a/b) is rejected rather than silently truncated.
            guard let host = url.host?.lowercased(), parts.count == 1, let payload = parts.first else { return nil }
            switch host {
            case "profile": return profileLink(rawAddress: payload)
            case "pay": return PaymentRequest(rawAddress: payload, url: url).map { .paymentRequest($0) }
            case "kapost": return kaPostLink(rawTxId: payload)
            default: return nil
            }
        case "kaposts":
            // KaPost's own scheme: only its post links are ours to recognize.
            guard url.host?.lowercased() == "kapost", parts.count == 1, let payload = parts.first else { return nil }
            return kaPostLink(rawTxId: payload)
        case "http", "https":
            var host = url.host?.lowercased() ?? ""
            if host.hasPrefix("www.") { host.removeFirst(4) }
            guard host == universalLinkHost, parts.count == 2 else { return nil }
            switch parts[0].lowercased() {
            case "u": return profileLink(rawAddress: parts[1])
            case "pay": return PaymentRequest(rawAddress: parts[1], url: url).map { .paymentRequest($0) }
            case "post": return kaPostLink(rawTxId: parts[1])
            default: return nil
            }
        default:
            return nil
        }
    }

    /// A post id is attacker-controlled too: letters, digits, "-" and "_" only, of a sane length
    /// (KaPost's own rule), so nothing else rides into the `kaposts://` link it opens.
    private static func kaPostLink(rawTxId: String) -> KaChatInternalLink? {
        let id = rawTxId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id.count >= 8, id.count <= 128 else { return nil }
        guard id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        return .kaPost(txId: id)
    }

    /// A pasted address is attacker-controlled like everything else in a link: it has to be a
    /// valid Kaspa address, checksum and all, or the link is not ours.
    /// The address opens on the network the app runs on: a link without a prefix (or shared
    /// from the other network) names the same key, so it becomes that key's address here -
    /// a `kaspa:` contact on testnet could never be reached (IOS-003).
    private static func profileLink(rawAddress: String) -> KaChatInternalLink? {
        let raw = rawAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.count <= 100, let address = KaspaAddress.onActiveNetwork(raw) else { return nil }
        return .profile(address: address)
    }

    // MARK: Detection inside message text

    /// One internal link found inside a message body.
    struct Match: Equatable {
        let link: KaChatInternalLink
        let url: URL
        /// The exact substring matched, so the caller can tell "the message IS this link" from
        /// "the message mentions this link".
        let matchedText: String
        /// True when the trimmed message consists of nothing but this link - the card then
        /// replaces the text bubble entirely (matching how a bare http link already renders).
        let coversWholeMessage: Bool
    }

    /// Both link forms, anywhere in free text. `NSDataDetector` (what `MessageTextRenderPlan`
    /// uses) only ever yields http(s) URLs, so the `kachat://` form needs its own scan; the
    /// universal form is matched here too so it is claimed as INTERNAL before the generic
    /// preview path can fetch it over the network.
    private static let pattern =
        #"(?:kachat://(?:profile|pay|kapost)/|kaposts://kapost/|https?://(?:www\.)?kachat\.app/(?:u|pay|post)/)[^\s<>"']+"#

    private static let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)

    /// Trailing prose punctuation is not part of the link ("... open kachat://profile/<address>.").
    private static let trailingTrim = CharacterSet(charactersIn: ".,;:!?)]}'\"")

    private final class MatchBox: NSObject {
        let value: Match?
        init(_ value: Match?) { self.value = value }
    }

    /// Same caching convention (and reason) as `MessageTextRenderPlan.firstLinkCache`: this runs
    /// from message-row bodies, several times per row per frame while scrolling.
    private static let matchCache: NSCache<NSString, MatchBox> = {
        let cache = NSCache<NSString, MatchBox>()
        cache.countLimit = 2_048
        return cache
    }()

    static func match(in text: String) -> Match? {
        let key = text as NSString
        if let cached = matchCache.object(forKey: key) { return cached.value }
        let result = uncachedMatch(in: text)
        matchCache.setObject(MatchBox(result), forKey: key)
        return result
    }

    private static func uncachedMatch(in text: String) -> Match? {
        // Cheap bail-out before paying for the regex: neither form can appear without one of
        // these two literals, and the overwhelming majority of messages contain neither.
        let lowered = text.lowercased()
        guard lowered.contains("kachat://") || lowered.contains("kaposts://") || lowered.contains(universalLinkHost) else { return nil }
        guard let regex else { return nil }
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var found: Match?
        regex.enumerateMatches(in: text, options: [], range: full) { result, _, stop in
            guard let result else { return }
            var candidate = ns.substring(with: result.range)
            while let last = candidate.unicodeScalars.last, trailingTrim.contains(last) {
                candidate.removeLast()
            }
            guard let url = URL(string: candidate), let link = parse(url) else { return }
            found = Match(
                link: link,
                url: url,
                matchedText: candidate,
                coversWholeMessage: text.trimmingCharacters(in: .whitespacesAndNewlines) == candidate
            )
            stop.pointee = true
        }
        return found
    }
}

/// A request to be paid, carried in a link (`KaChatInternalLink.paymentRequest`): who to pay, the
/// exact amount and what it's for. Made from Profile's send / receive button > Request Payment; pasting one anywhere in
/// KaChat, or tapping one, opens Send Kaspa with it filled in.
///
/// `https://kachat.app/pay/<address>?amount=<KAS>&memo=<text>&chat=1` (or `kachat://pay/...`):
/// - the address without `kaspa:` on mainnet (like profile links), with `kaspatest:` on testnet;
/// - `amount` in KAS, at most 8 decimals, "." as the separator;
/// - `memo` optional, at most `memoLimit` characters;
/// - `chat=1` when the address is the requester's chatting address: then the payment goes as a
///   chat payment, with the memo encrypted to them in it. A spending address can't read a memo,
///   so there the memo only tells the payer what it is for.
/// - `by` + `sig`: who made it - the maker's chatting address, which has an identity (a
///   `.kachat` name, a profile) where a spending address has none - and a Schnorr signature by
///   that address's key over everything above (`signingDigest`). A request is shown as "from"
///   someone only when the signature checks out; a link whose signature doesn't is refused
///   outright, since that is a link someone changed. Requests without them (none are made that
///   way) show no maker.
/// Everything in it is attacker-controlled: the address must be valid on the network the app runs
/// on, the amount positive and exact, and the memo is cleaned of control and direction marks.
struct PaymentRequest: Equatable, Identifiable {
    let address: String
    let amountSompi: UInt64
    let memo: String
    let toChattingAddress: Bool
    /// The chatting address that signed the request - verified, or nil.
    let creator: String?
    /// The creator's Schnorr signature over `signingDigest(creator:)`.
    let signature: Data?
    /// Each opening is its own sheet, even for the same request.
    let id = UUID()

    static let memoLimit = 140
    private static let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

    static func == (lhs: PaymentRequest, rhs: PaymentRequest) -> Bool {
        lhs.address == rhs.address && lhs.amountSompi == rhs.amountSompi
            && lhs.memo == rhs.memo && lhs.toChattingAddress == rhs.toChattingAddress
            && lhs.creator == rhs.creator && lhs.signature == rhs.signature
    }

    init(address: String, amountSompi: UInt64, memo: String, toChattingAddress: Bool,
         creator: String? = nil, signature: Data? = nil) {
        self.address = address
        self.amountSompi = amountSompi
        self.memo = Self.cleanMemo(memo)
        self.toChattingAddress = toChattingAddress
        self.creator = creator
        self.signature = signature
    }

    /// What the maker signs: every field of the request and the maker's own address, under a
    /// domain tag so the signature can't be passed off as anything else. SHA-256 of
    /// "kachat-payment-request:v1" and the fields, one per line: address, amount in sompi, memo,
    /// "1"/"0" for chat, creator.
    func signingDigest(creator: String) -> Data {
        let text = ["kachat-payment-request:v1", address.lowercased(), String(amountSompi), memo,
                    toChattingAddress ? "1" : "0", creator.lowercased()].joined(separator: "\n")
        return Data(SHA256.hash(data: Data(text.utf8)))
    }

    /// This request signed by `creator` (the wallet's chatting address) with its key.
    func signed(by creator: String, privateKey: Data) -> PaymentRequest? {
        guard let signature = try? GroupCipher.sign(signingDigest(creator: creator), privateKey: privateKey) else { return nil }
        return PaymentRequest(address: address, amountSompi: amountSompi, memo: memo,
                              toChattingAddress: toChattingAddress, creator: creator.lowercased(), signature: signature)
    }

    /// True when `signature` is `creator`'s over this request.
    static func verify(_ signature: Data, creator: String, request: PaymentRequest) -> Bool {
        guard let key = KaspaAddress.publicKey(from: creator), key.count == 32 else { return false }
        return GroupCipher.verify(signature, message: request.signingDigest(creator: creator), xOnlyPublicKey: key)
    }

    /// From a link's address segment and its query; nil unless every part is valid.
    init?(rawAddress: String, url: URL) {
        let raw = rawAddress.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard raw.count <= 100 else { return nil }
        let full = raw.contains(":") ? raw : "kaspa:" + raw
        // the request names an address on one network: a payment can't cross networks
        guard KaspaAddress.isValidOnActiveNetwork(full) else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name.lowercased() == name }?.value }
        guard let amountText = value("amount"), amountText.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
              let sompi = KaspaUnit.sompi(fromUserText: amountText), sompi > 0 else { return nil }
        let unsigned = PaymentRequest(address: full, amountSompi: sompi, memo: value("memo") ?? "", toChattingAddress: value("chat") == "1")
        switch (value("by"), value("sig")) {
        case (nil, nil):
            self = unsigned
        case let (by?, sig?):
            let rawBy = by.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let creator = rawBy.contains(":") ? rawBy : "kaspa:" + rawBy
            // a maker is shown only when the signature is theirs; one that isn't is a changed link
            guard rawBy.count <= 100, KaspaAddress.isValidOnActiveNetwork(creator),
                  let signature = Data(hexString: sig), signature.count == 64,
                  Self.verify(signature, creator: creator, request: unsigned) else { return nil }
            self.init(address: full, amountSompi: sompi, memo: unsigned.memo, toChattingAddress: unsigned.toChattingAddress,
                      creator: creator, signature: signature)
        default:
            return nil
        }
    }

    /// The first payment request in `text` - a pasted link, or a message holding one.
    static func found(in text: String) -> PaymentRequest? {
        guard let match = KaChatInternalLink.match(in: text), case .paymentRequest(let request) = match.link else { return nil }
        return request
    }

    /// The amount in KAS, exact: "12.5", "0.00000001".
    var amountText: String {
        let whole = amountSompi / 100_000_000
        let frac = amountSompi % 100_000_000
        guard frac > 0 else { return String(whole) }
        var fracText = String(format: "%08llu", frac)
        while fracText.hasSuffix("0") { fracText.removeLast() }
        return "\(whole).\(fracText)"
    }

    /// The link's address segment and query, shared by both forms.
    var linkTail: String {
        let path = address.hasPrefix("kaspa:") ? String(address.dropFirst("kaspa:".count)) : address
        var query = "amount=\(amountText)"
        // Only unreserved characters stay as they are: "&", "=", "+", "#" and spaces in a memo are
        // all escaped, so it reads back exactly as written whatever decodes it.
        if !memo.isEmpty, let encoded = memo.addingPercentEncoding(withAllowedCharacters: Self.unreserved) {
            query += "&memo=\(encoded)"
        }
        if toChattingAddress { query += "&chat=1" }
        if let creator, let signature {
            let by = creator.hasPrefix("kaspa:") ? String(creator.dropFirst("kaspa:".count)) : creator
            query += "&by=\(by)&sig=\(signature.hexString)"
        }
        return "\(path)?\(query)"
    }

    /// The link the Copy button gives out.
    var shareURLString: String { KaChatInternalLink.paymentRequest(self).universalLinkString }

    /// True when the address is one of this wallet's: your own request pastes as text (to send it
    /// to someone) instead of opening Send.
    ///
    /// Cheap enough for a view body (the request card asks on every draw): one you signed is yours
    /// at once, and the wallet's addresses are worked out once per account and address count -
    /// listing the spending addresses reads the seed and derives each of them, which on every
    /// redraw made a chat holding a request crawl.
    @MainActor
    var isOwn: Bool {
        let wallet = WalletManager.shared.currentWallet?.publicAddress.lowercased()
        if let creator, creator.lowercased() == wallet { return true }
        return Self.ownAddresses().contains(address.lowercased())
    }

    @MainActor private static var ownAddressCache: (key: String, addresses: Set<String>)?

    @MainActor
    private static func ownAddresses() -> Set<String> {
        let manager = WalletManager.shared
        guard let wallet = manager.currentWallet?.publicAddress.lowercased() else { return [] }
        let key = "\(wallet)|\(manager.maxSpendingAddressIndex)|q\(manager.maxQuantumAddressIndex)"
        if let cached = ownAddressCache, cached.key == key { return cached.addresses }
        var addresses: Set<String> = [wallet]
        addresses.formUnion(manager.allSpendingAddresses().map { $0.lowercased() })
        ownAddressCache = (key, addresses)
        return addresses
    }

    static func cleanMemo(_ memo: String) -> String {
        let scalars = memo.unicodeScalars.filter { scalar in
            let category = scalar.properties.generalCategory
            if category == .control || category == .format { return false }
            switch scalar.value {
            case 0x200B...0x200F, 0x202A...0x202E, 0x2066...0x2069, 0xFEFF: return false
            default: return true
            }
        }
        let cleaned = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        return String(cleaned.prefix(memoLimit))
    }
}

/// What a KaPost link's card shows once the post is found: who posted it and what it says.
struct KaPostPreview: Equatable {
    /// The poster's address on the network the app runs on, nil if their key didn't read.
    let authorAddress: String?
    let text: String
}

/// Looks the post a KaPost link names up on the KaChat indexer (`get-post?id=`, the lookup KaPost
/// itself uses), for the link's card in a chat. One answer per post per run, shared by every card;
/// a post not found is asked again after five minutes at most.
@MainActor
enum KaPostPreviewLoader {
    private static var cache: [String: KaPostPreview] = [:]
    private static var misses: [String: Date] = [:]
    private static var inFlight: [String: Task<KaPostPreview?, Never>] = [:]
    /// The indexer wants a requester key, which only marks per-reader fields (your vote). A fixed
    /// placeholder keeps who is reading the link out of the request.
    private nonisolated static let placeholderRequester = "02" + String(repeating: "0", count: 64)
    /// As much as the card can show, and what the link site puts in its preview.
    private nonisolated static let textLimit = 300

    static func cached(_ txId: String) -> KaPostPreview? { cache[txId] }

    static func load(_ txId: String) async -> KaPostPreview? {
        if let hit = cache[txId] { return hit }
        if let missed = misses[txId], Date().timeIntervalSince(missed) < 300 { return nil }
        if let running = inFlight[txId] { return await running.value }
        let base = AppSettings.load().indexerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let task = Task { () -> KaPostPreview? in
            guard let found = await fetch(txId, base: base) else { return nil }
            return KaPostPreview(authorAddress: found.authorKey.flatMap(authorAddress), text: found.text)
        }
        inFlight[txId] = task
        let result = await task.value
        inFlight[txId] = nil
        if let result { cache[txId] = result } else { misses[txId] = Date() }
        return result
    }

    private struct Response: Decodable {
        struct Post: Decodable {
            let userPublicKey: String?
            let postContent: String
        }
        let post: Post
    }

    private nonisolated static func fetch(_ txId: String, base: String) async -> (authorKey: String?, text: String)? {
        guard !base.isEmpty, var components = URLComponents(string: base) else { return nil }
        let path = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = path + "/get-post"
        components.queryItems = [
            URLQueryItem(name: "id", value: txId),
            URLQueryItem(name: "requesterPubkey", value: placeholderRequester),
        ]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let post = try? JSONDecoder().decode(Response.self, from: data).post,
              let bytes = Data(base64Encoded: post.postContent),
              let raw = String(data: bytes, encoding: .utf8) else { return nil }
        let text = cleanText(raw)
        guard !text.isEmpty else { return nil }
        return (post.userPublicKey, text)
    }

    /// Someone else's text, shown in a small card: one paragraph (line breaks become spaces), no
    /// control or direction marks (KaPost's invisible marker among them), at most `textLimit`.
    private nonisolated static func cleanText(_ raw: String) -> String {
        let flattened = raw.components(separatedBy: .newlines).joined(separator: " ")
        let scalars = flattened.unicodeScalars.filter { scalar in
            let category = scalar.properties.generalCategory
            if category == .control || category == .format { return false }
            switch scalar.value {
            case 0x200B...0x200F, 0x202A...0x202E, 0x2060...0x2069, 0xFEFF: return false
            default: return true
            }
        }
        let cleaned = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.count > textLimit ? String(cleaned.prefix(textLimit)) + "…" : cleaned
    }

    /// A poster's compressed public key (66 hex) as their address: posts are signed with the key
    /// a chatting address is made of.
    private static func authorAddress(_ hex: String) -> String? {
        guard hex.count == 66, let key = Data(hexString: hex), key.count == 33 else { return nil }
        let address = KaspaAddress(hrp: "kaspa", type: .pubKey, payload: Data(Array(key.dropFirst()))).address
        return KaspaAddress.onActiveNetwork(address)
    }
}

/// The payment request waiting to be shown: `MainTabView` presents Send Kaspa for it.
@MainActor
final class PaymentRequestRouter: ObservableObject {
    static let shared = PaymentRequestRouter()
    @Published var pending: PaymentRequest?
    private init() {}
}

/// Open Graph metadata scraped from a message link, for rendering a rich preview card.
struct LinkPreviewData: Equatable {
    let url: URL
    let title: String?
    let description: String?
    let imageURLString: String?
    let siteName: String?
    /// Set only for Nextcloud public-share media links (see
    /// KaChat-Desktop/docs/NEXTCLOUD_MEDIA_PREVIEW.md): tells the card this link is directly
    /// viewable media and which kind, so tapping opens the in-app viewer instead of Safari.
    var nextcloudMedia: NextcloudMediaKind? = nil
    /// The share's raw-file `/download` URL (streams via range requests) — the viewer's source.
    var mediaDownloadURLString: String? = nil
    /// Content-Length from the type-detection HEAD — shown on attachment cards.
    var mediaByteSize: Int64? = nil
    /// The Nextcloud server answered that this public share no longer exists (404/410), so the
    /// sender revoked it or it expired. The card renders a neutral "no longer shared" tile and,
    /// crucially, stops showing the share URL - a link nobody can open is just the sender's
    /// server address sitting in the transcript. Only ever set on a definite answer FROM the
    /// server; a network failure leaves this false and the card simply renders nothing.
    var nextcloudShareRevoked: Bool = false
}

enum NextcloudMediaKind: String, Equatable {
    case image
    case video
    case audio
    case pdf
    /// Anything else (Office docs, archives, …) — rendered as an attachment card that opens
    /// in Nextcloud's own web viewer; no native inline rendering exists for these.
    case file
}

/// Fetches Open Graph preview metadata for links sent in chat messages. Auto-fetch on render is
/// gated by sender trust (see `LinkPreviewCardView.autoFetch`): accepted 1:1 contacts and group
/// chats fetch automatically; non-accepted senders fetch only when the user
/// taps the placeholder card. Each recipient's own device does this fetch when the message
/// renders, rather than the sender embedding preview data in the encrypted message payload, so
/// link previews never bloat the on-chain/indexer payload. Mirrors `KNSService`'s async-fetch
/// shape (`KNSService.swift` `fetchPrimaryNameResult`) and `MessageTextRenderPlan`'s `NSCache`
/// sizing convention (`countLimit = 2_048`).
actor LinkPreviewService {
    /// What a log line may say about a link: its host, never the path or query. Logs are
    /// public (`AppLog`) and ship in the diagnostics export, and a Nextcloud share link's path
    /// IS its access token - logging it handed the user's private photos and voice notes to
    /// anyone who read the export.
    nonisolated static func logLabel(_ url: URL) -> String {
        url.host ?? "(no host)"
    }

    static let shared = LinkPreviewService()

    /// `nil` value = "fetched, but no preview data found" (still worth caching so a bad/plain link
    /// isn't refetched on every scroll). Bounded FIFO eviction, not LRU - simplicity over
    /// optimality for a cosmetic, cheap-to-refetch-on-relaunch cache. Entries also expire after
    /// `cacheTTL`: a link whose page changed (or whose preview image URL was a short-lived
    /// signed one) would otherwise stay stale for the whole process lifetime.
    private var cache: [String: LinkPreviewData?] = [:]
    private var cacheStoredAt: [String: Date] = [:]
    private var cacheOrder: [String] = []
    private let cacheLimit = 2_048
    static let cacheTTL: TimeInterval = 24 * 60 * 60

    /// In-flight fetches keyed by URL, so concurrent callers for the same not-yet-cached link
    /// (e.g. the message row and a re-render both mounting a `LinkPreviewCardView` for the same
    /// URL at once) await the *same* network request instead of each firing their own - avoids
    /// hammering a link's host with duplicate requests, which is a plausible way to trip a site's
    /// rate limiting.
    private var inFlight: [String: Task<LinkPreviewData?, Never>] = [:]

    /// Same two mechanisms for image bytes as `preview(for:)` has for metadata. Without them
    /// every card remount re-downloaded its image and N rows sharing one image fired N
    /// requests. `NSCache` (cost = byte count) so the bytes are bounded and shed under memory
    /// pressure; a `Data` body is only kept below the cost limit, an oversized one is served
    /// once and not retained.
    private let imageCache: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.countLimit = 256
        cache.totalCostLimit = 16 * 1024 * 1024
        return cache
    }()
    private var imageInFlight: [String: Task<Data?, Never>] = [:]

    private let fetchTimeout: TimeInterval = 8
    private let maxBodyBytes = 1_000_000
    private let maxImageBytes = 5_000_000

    /// Fetches a preview image's bytes using the same browser User-Agent as the scrape, plus a
    /// `Referer` (the page the image belongs to). Image CDNs like cdninstagram/fbcdn reject bare
    /// requests (no browser UA / no Referer) with a 403, which is why `AsyncImage` - which sends
    /// neither - silently failed for Instagram. Returns nil on any failure (card shows no image).
    /// `maxBytes` overrides the default 5 MB cap — the Nextcloud full-quality photo viewer
    /// passes a much higher limit since it deliberately fetches the original file.
    func imageData(_ url: URL, referer: URL, maxBytes: Int? = nil) async -> Data? {
        // Keyed by URL and cap: the full-quality Nextcloud fetch must not be answered from a
        // capped request's bytes (or vice versa).
        let key = "\(url.absoluteString)|\(maxBytes ?? maxImageBytes)"
        if let cached = imageCache.object(forKey: key as NSString) {
            return cached as Data
        }
        if let existing = imageInFlight[key] {
            return await existing.value
        }

        let task = Task<Data?, Never> { [weak self] in
            guard let self else { return nil }
            // First: browser UA (session default) + Referer. Fallback: Meta's crawler UA with no Referer -
            // some cdninstagram/fbcdn image URLs 403 the browser-UA/Referer combo but serve that crawler.
            if let data = await self.fetchImageBytes(url, userAgentOverride: nil, referer: referer, maxBytes: maxBytes) { return data }
            return await self.fetchImageBytes(url, userAgentOverride: Self.facebookExternalHitUserAgent, referer: nil, maxBytes: maxBytes)
        }
        imageInFlight[key] = task
        let data = await task.value
        imageInFlight.removeValue(forKey: key)

        if let data, data.count <= imageCache.totalCostLimit {
            imageCache.setObject(data as NSData, forKey: key as NSString, cost: data.count)
        }
        return data
    }

    private func fetchImageBytes(_ url: URL, userAgentOverride: String?, referer: URL?, maxBytes: Int? = nil) async -> Data? {
        var request = URLRequest(url: url)
        if let userAgentOverride { request.setValue(userAgentOverride, forHTTPHeaderField: "User-Agent") }
        if let referer { request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer") }
        request.setValue("image/avif,image/webp,image/png,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await fetchCapped(request, limit: maxBytes ?? maxImageBytes, onOverflow: .fail)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return nil }
            return data
        } catch {
            return nil
        }
    }

    /// A body read no further than `limit` bytes, on its own session so the reader can be its
    /// delegate. See `CappedResponseReader`.
    private func fetchCapped(_ request: URLRequest, limit: Int, onOverflow: CappedResponseReader.Overflow) async throws -> (Data, URLResponse) {
        let reader = CappedResponseReader(limit: limit, onOverflow: onOverflow)
        let cappedSession = URLSession(configuration: session.configuration, delegate: reader, delegateQueue: nil)
        defer { cappedSession.finishTasksAndInvalidate() }
        return try await reader.read(request, using: cappedSession)
    }

    /// A real desktop-browser User-Agent. A self-identifying bot UA (the old value) makes sites like
    /// Instagram serve a login/consent wall with no post-specific `og:image`; a browser UA gets the
    /// real page with usable Open Graph tags. Shared with the preview image loader so image CDNs
    /// (e.g. cdninstagram/fbcdn) that reject non-browser requests don't 403.
    static let browserUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"

    /// Meta's own link-scraper User-Agent. Instagram/Facebook serve full Open Graph tags - including
    /// `og:image` - to this crawler, whereas a plain browser UA increasingly gets a login wall whose
    /// HTML has the page title/description but no post-specific image (why the preview showed text but
    /// no picture). Used for the scrape on Meta hosts, and as the image-load fallback everywhere.
    static let facebookExternalHitUserAgent = "facebookexternalhit/1.1 (+http://www.facebook.com/externalhit_uatext.php)"

    private static let metaScrapeHosts: Set<String> = [
        "instagram.com", "www.instagram.com", "m.instagram.com",
        "facebook.com", "www.facebook.com", "m.facebook.com", "fb.watch"
    ]

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = fetchTimeout
        config.timeoutIntervalForResource = fetchTimeout
        config.httpAdditionalHeaders = [
            "User-Agent": Self.browserUserAgent,
            "Accept-Language": "en-US,en;q=0.9"
        ]
        return URLSession(configuration: config)
    }()

    private init() {}

    /// Non-actor-isolated mirror of `cache`, synchronously readable. Lets a view for an
    /// already-known URL initialize its `@State` with the final result on its very first render -
    /// zero async gap, so no late height change after the fact (the root cause of link previews
    /// disrupting scroll position when a row's height pops in after the fact).
    nonisolated func cachedResultIfKnown(for url: URL) -> LinkPreviewData?? {
        Self.syncCache.value(for: url.absoluteString)
    }

    private static let syncCache = SyncCacheMirror()

    /// Pre-seeds the cache with preview data the caller already knows to be true — the media
    /// send paths use this right after uploading, so the sender's own bubble renders instantly
    /// with zero network instead of waiting on the type probe.
    func seed(_ data: LinkPreviewData) {
        store(data, forKey: data.url.absoluteString)
    }

    func preview(for url: URL) async -> LinkPreviewData? {
        let key = url.absoluteString
        if let cached = cache[key] {
            if let storedAt = cacheStoredAt[key], Date().timeIntervalSince(storedAt) >= Self.cacheTTL {
                // Expired: drop it entirely and fall through to a fresh fetch, which re-stores
                // it at the back of the FIFO like any new entry.
                evict(key)
            } else {
                AppLog.log("[LinkPreview] cache hit for %@ -> %@", Self.logLabel(url), cached == nil ? "no data" : "has data")
                return cached
            }
        }
        // Failed share probes wait out the cooldown before re-hitting the server.
        if let failedAt = nextcloudFailureAt[key], Date().timeIntervalSince(failedAt) < nextcloudRetryCooldown {
            return nil
        }

        if let existing = inFlight[key] {
            AppLog.log("[LinkPreview] joining in-flight fetch for %@", Self.logLabel(url))
            return await existing.value
        }

        AppLog.log("[LinkPreview] fetching %@", Self.logLabel(url))
        let task = Task<LinkPreviewData?, Never> { [weak self] in
            await self?.fetchPreview(for: url)
        }
        inFlight[key] = task
        let result = await task.value
        inFlight.removeValue(forKey: key)
        AppLog.log("[LinkPreview] result for %@ -> %@", Self.logLabel(url), result == nil ? "no preview" : "preview")
        store(result, forKey: key)
        return result
    }

    /// Share URLs whose probe recently failed, with the failure time — retried after a
    /// cooldown rather than on every render. Unbounded caching of the failure would pin the
    /// message to a bare link forever; retrying every render hammers the server anonymously,
    /// which can trip Nextcloud's brute-force throttle and take ALL previews down with it.
    private var nextcloudFailureAt: [String: Date] = [:]
    private let nextcloudRetryCooldown: TimeInterval = 60

    private func store(_ value: LinkPreviewData?, forKey key: String) {
        if let url = URL(string: key), Self.nextcloudShareEndpoints(for: url) != nil {
            if value == nil {
                nextcloudFailureAt[key] = Date()
                return
            }
            nextcloudFailureAt.removeValue(forKey: key)
        }
        if cache[key] == nil {
            cacheOrder.append(key)
        }
        cache[key] = value
        cacheStoredAt[key] = Date()
        if cacheOrder.count > cacheLimit, !cacheOrder.isEmpty {
            let oldest = cacheOrder.removeFirst()
            cache.removeValue(forKey: oldest)
            cacheStoredAt.removeValue(forKey: oldest)
            // The mirror has to follow, or it grows past the limit the main cache enforces
            // (it was only ever written, never evicted from).
            Self.syncCache.remove(for: oldest)
        }
        Self.syncCache.set(value, for: key)
    }

    /// Removes one key from the main cache, its FIFO position, and the mirror; used for TTL
    /// expiry (the FIFO overflow path in `store` does its own removal from the front).
    private func evict(_ key: String) {
        cache.removeValue(forKey: key)
        cacheStoredAt.removeValue(forKey: key)
        cacheOrder.removeAll { $0 == key }
        Self.syncCache.remove(for: key)
    }

    private static let youTubeHosts: Set<String> = ["youtube.com", "www.youtube.com", "m.youtube.com", "youtu.be"]

    // MARK: - Nextcloud public shares (docs: KaChat-Desktop/docs/NEXTCLOUD_MEDIA_PREVIEW.md)

    struct NextcloudShareEndpoints: Equatable {
        let downloadURL: URL
        let previewURL: URL
    }

    /// `https://host/s/TOKEN` (or `/index.php/s/TOKEN`, token 10+ url-safe chars) -> the share's
    /// raw-file `/download` and thumbnail `/preview` endpoints; nil for any other URL.
    nonisolated static func nextcloudShareEndpoints(for url: URL) -> NextcloudShareEndpoints? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        let path = url.path
        guard let regex = try? NSRegularExpression(pattern: #"^(/index\.php)?/s/([A-Za-z0-9_-]{10,})/?$"#) else { return nil }
        let range = NSRange(path.startIndex..<path.endIndex, in: path)
        guard let match = regex.firstMatch(in: path, options: [], range: range),
              let tokenRange = Range(match.range(at: 2), in: path),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let prefix = match.range(at: 1).location != NSNotFound ? "/index.php" : ""
        components.path = "\(prefix)/s/\(path[tokenRange])"
        components.query = nil
        components.fragment = nil
        guard let base = components.url else { return nil }
        return NextcloudShareEndpoints(
            downloadURL: base.appendingPathComponent("download"),
            previewURL: base.appendingPathComponent("preview")
        )
    }

    /// What a Nextcloud server answers for a public share that was deleted, expired, or had its
    /// link removed. Anything else (403 password prompt, 5xx, a proxy error) is NOT treated as
    /// revoked - the link stays intact and the card just does not render.
    private static let shareGoneStatuses: Set<Int> = [404, 410]

    /// The share link itself carries no file type, so `HEAD` the `/download` URL (native HTTP,
    /// no CORS constraints) and branch on `Content-Type`. Non-media shares return nil, which
    /// renders as a plain link. The card's poster is the share's `/preview` thumbnail; the
    /// full-quality fetch/stream only happens when the user taps the card.
    private func fetchNextcloudPreview(for url: URL, endpoints: NextcloudShareEndpoints) async -> LinkPreviewData? {
        do {
            // HEAD first (cheapest); some servers/reverse proxies reject HEAD on public
            // downloads, so fall back to a 2-byte ranged GET — either way we only need the
            // response headers, never the body.
            // A 2-byte ranged GET is the primary probe — universally supported and exactly one
            // round trip (HEAD-then-GET doubled the wait on servers that dislike HEAD). HEAD
            // remains as the rare fallback for servers that mishandle Range.
            var http: HTTPURLResponse?
            // A status the SERVER returned saying the share is gone, as opposed to a request
            // that never got an answer. Only the former justifies hiding the link.
            var revokedStatus: Int?
            var rangeRequest = URLRequest(url: endpoints.downloadURL)
            rangeRequest.setValue("bytes=0-1", forHTTPHeaderField: "Range")
            // Capped: a server that ignores Range sends the whole file.
            if let (_, rangeResponse) = try? await fetchCapped(rangeRequest, limit: 64_000, onOverflow: .truncate),
               let rangeHTTP = rangeResponse as? HTTPURLResponse {
                if (200..<300).contains(rangeHTTP.statusCode) {
                    http = rangeHTTP
                } else if Self.shareGoneStatuses.contains(rangeHTTP.statusCode) {
                    revokedStatus = rangeHTTP.statusCode
                }
            }
            if http == nil, revokedStatus == nil {
                var headRequest = URLRequest(url: endpoints.downloadURL)
                headRequest.httpMethod = "HEAD"
                let (_, headResponse) = try await session.data(for: headRequest)
                if let headHTTP = headResponse as? HTTPURLResponse {
                    if (200..<300).contains(headHTTP.statusCode) {
                        http = headHTTP
                    } else if Self.shareGoneStatuses.contains(headHTTP.statusCode) {
                        revokedStatus = headHTTP.statusCode
                    }
                }
            }
            if let revokedStatus {
                AppLog.log("[LinkPreview] Nextcloud share gone (HTTP %d) for %@", revokedStatus, LinkPreviewService.logLabel(url))
                return LinkPreviewData(
                    url: url,
                    title: nil,
                    description: nil,
                    imageURLString: nil,
                    siteName: nil,
                    nextcloudShareRevoked: true
                )
            }
            guard let http else {
                AppLog.log("[LinkPreview] Nextcloud HEAD+ranged-GET both failed for %@", LinkPreviewService.logLabel(url))
                return nil
            }
            let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            let kind: NextcloudMediaKind
            if contentType.hasPrefix("image/") { kind = .image }
            else if contentType.hasPrefix("video/") { kind = .video }
            else if contentType.hasPrefix("audio/") { kind = .audio }
            else if contentType.contains("pdf") { kind = .pdf }
            else { kind = .file }
            let filename = Self.filename(fromContentDisposition: http.value(forHTTPHeaderField: "Content-Disposition"))
            let fallbackTitle: String
            switch kind {
            case .image: fallbackTitle = "Photo"
            case .video: fallbackTitle = "Video"
            case .audio: fallbackTitle = "Audio"
            case .pdf: fallbackTitle = "PDF"
            case .file: fallbackTitle = "File"
            }
            // Via the ranged-GET fallback, Content-Length is the 2-byte slice — the real size
            // lives in Content-Range ("bytes 0-1/12345").
            let byteSize: Int64?
            if let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
               let totalPart = contentRange.split(separator: "/").last, let total = Int64(totalPart) {
                byteSize = total
            } else {
                byteSize = http.value(forHTTPHeaderField: "Content-Length").flatMap { Int64($0) }
            }
            return LinkPreviewData(
                url: url,
                title: filename ?? fallbackTitle,
                description: nil,
                imageURLString: endpoints.previewURL.absoluteString,
                siteName: url.host.map { "Nextcloud · \($0)" } ?? "Nextcloud",
                nextcloudMedia: kind,
                mediaDownloadURLString: endpoints.downloadURL.absoluteString,
                mediaByteSize: byteSize
            )
        } catch {
            AppLog.log("[LinkPreview] Nextcloud HEAD failed for %@: %@", LinkPreviewService.logLabel(url), error.localizedDescription)
            return nil
        }
    }

    /// Pulls the shared file's name out of `Content-Disposition: attachment; filename="x.jpg"`
    /// (or the RFC 5987 `filename*=UTF-8''x.jpg` form) for the card title.
    private nonisolated static func filename(fromContentDisposition header: String?) -> String? {
        guard let header else { return nil }
        if let range = header.range(of: #"filename\*=UTF-8''([^;]+)"#, options: .regularExpression) {
            let raw = String(header[range]).replacingOccurrences(of: "filename*=UTF-8''", with: "")
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            return trimmed.removingPercentEncoding ?? trimmed
        }
        if let range = header.range(of: #"filename="([^"]+)""#, options: .regularExpression) {
            var raw = String(header[range]).replacingOccurrences(of: "filename=\"", with: "")
            if raw.hasSuffix("\"") { raw.removeLast() }
            return raw.isEmpty ? nil : raw
        }
        return nil
    }

    private func fetchPreview(for url: URL) async -> LinkPreviewData? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            AppLog.log("[LinkPreview] rejected non-http(s) scheme for %@", LinkPreviewService.logLabel(url))
            return nil
        }

        // Nextcloud public shares are media files, not pages — no Open Graph to scrape. Type
        // comes from a HEAD on the raw-file endpoint instead (see fetchNextcloudPreview).
        if let endpoints = Self.nextcloudShareEndpoints(for: url) {
            return await fetchNextcloudPreview(for: url, endpoints: endpoints)
        }

        // YouTube serves a cookie-consent-wall page (no Open Graph tags at all) to plain scraper
        // requests instead of the real video page - confirmed in testing: other sites (e.g.
        // Instagram) return usable og: tags via the generic path below, YouTube consistently
        // didn't. YouTube's own oEmbed endpoint is built exactly for this (no consent wall, no
        // API key needed) and is what most link-preview implementations use for YouTube URLs.
        if let host = url.host?.lowercased(), Self.youTubeHosts.contains(host) {
            if let oEmbedResult = await fetchYouTubeOEmbed(for: url) {
                return oEmbedResult
            }
            // Fall through to the generic scrape below only if oEmbed itself failed (e.g. a
            // private/deleted video) - unlikely to succeed either, but no harm trying.
        }

        do {
            var request = URLRequest(url: url)
            request.setValue("text/html", forHTTPHeaderField: "Accept")
            // Instagram/Facebook serve a login wall (title/description but no post `og:image`) to a
            // plain browser UA; their own crawler UA gets the full Open Graph including the image.
            if let host = url.host?.lowercased(), Self.metaScrapeHosts.contains(host) {
                request.setValue(Self.facebookExternalHitUserAgent, forHTTPHeaderField: "User-Agent")
            }

            // Stops reading at the cap and keeps what it has (Open Graph tags are in the head):
            // the link comes from whoever sent the message, and its server decides how much
            // would come down otherwise. Delivered in chunks through the session delegate, not
            // a `URLSession.AsyncBytes` loop - reading up to a million individual `UInt8` awaits
            // turned out unreliable in practice (device-dependent slowness compounding with the
            // 8s timeout, silently yielding no preview).
            let (data, response) = try await fetchCapped(request, limit: maxBodyBytes, onOverflow: .truncate)
            guard let httpResponse = response as? HTTPURLResponse else {
                AppLog.log("[LinkPreview] non-HTTP response for %@", LinkPreviewService.logLabel(url))
                return nil
            }
            AppLog.log("[LinkPreview] HTTP %d, %d bytes for %@", httpResponse.statusCode, data.count, LinkPreviewService.logLabel(url))
            guard (200..<300).contains(httpResponse.statusCode) else {
                return nil
            }

            guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                AppLog.log("[LinkPreview] could not decode response body as text for %@", LinkPreviewService.logLabel(url))
                return nil
            }

            let parsed = parse(html: html, url: url)
            if let host = url.host?.lowercased(), Self.metaScrapeHosts.contains(host), host.contains("instagram") {
                return Self.instagramFallback(for: url, scraped: parsed)
            }
            return parsed
        } catch {
            AppLog.log("[LinkPreview] fetch failed for %@: %@", LinkPreviewService.logLabel(url), error.localizedDescription)
            if let host = url.host?.lowercased(), host.contains("instagram") {
                return Self.instagramFallback(for: url, scraped: nil)
            }
            return nil
        }
    }

    /// Instagram stopped serving Open Graph data - title, description and above all
    /// `og:image` - to anyone not logged in, whatever the User-Agent (checked 2026-09-22 with a
    /// browser UA, Meta's own crawler UA and Twitterbot: every post, reel and profile page
    /// comes back as a bare "Instagram" shell, and the oEmbed endpoint now needs a Meta API
    /// token). So an Instagram link cannot show the post's picture without a logged-in
    /// session. Rather than an empty image box, the card names what the link is from the URL
    /// itself: the account, and whether it is a post, a reel or a profile.
    private static func instagramFallback(for url: URL, scraped: LinkPreviewData?) -> LinkPreviewData? {
        if let scraped, scraped.imageURLString != nil { return scraped }
        let parts = url.pathComponents.filter { $0 != "/" }
        let title: String
        let description: String
        switch parts.first?.lowercased() {
        case "p": title = "Instagram post"; description = "Open in Instagram to see the post."
        case "reel", "reels": title = "Instagram reel"; description = "Open in Instagram to watch the reel."
        case "stories": title = "Instagram story"; description = "Open in Instagram to see the story."
        case let handle? where !handle.isEmpty && !["explore", "accounts", "direct"].contains(handle):
            title = "@\(handle) on Instagram"; description = "Open in Instagram to see the profile."
        default: title = "Instagram"; description = "Open in Instagram."
        }
        return LinkPreviewData(
            url: url,
            title: scraped?.title.flatMap { $0 == "Instagram" ? nil : $0 } ?? title,
            description: scraped?.description ?? description,
            imageURLString: nil,
            siteName: "Instagram"
        )
    }

    private struct YouTubeOEmbedResponse: Decodable {
        let title: String?
        let authorName: String?
        let thumbnailURL: String?

        enum CodingKeys: String, CodingKey {
            case title
            case authorName = "author_name"
            case thumbnailURL = "thumbnail_url"
        }
    }

    private func fetchYouTubeOEmbed(for url: URL) async -> LinkPreviewData? {
        guard var components = URLComponents(string: "https://www.youtube.com/oembed") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "url", value: url.absoluteString),
            URLQueryItem(name: "format", value: "json")
        ]
        guard let oEmbedURL = components.url else { return nil }

        do {
            let (data, response) = try await session.data(from: oEmbedURL)
            guard let httpResponse = response as? HTTPURLResponse else { return nil }
            AppLog.log("[LinkPreview] YouTube oEmbed HTTP %d, %d bytes for %@", httpResponse.statusCode, data.count, LinkPreviewService.logLabel(url))
            guard (200..<300).contains(httpResponse.statusCode) else { return nil }

            let decoded = try JSONDecoder().decode(YouTubeOEmbedResponse.self, from: data)
            guard decoded.title != nil || decoded.thumbnailURL != nil else { return nil }

            return LinkPreviewData(
                url: url,
                title: decoded.title,
                description: nil,
                imageURLString: decoded.thumbnailURL,
                siteName: "YouTube"
            )
        } catch {
            AppLog.log("[LinkPreview] YouTube oEmbed failed for %@: %@", LinkPreviewService.logLabel(url), error.localizedDescription)
            return nil
        }
    }

    private func parse(html: String, url: URL) -> LinkPreviewData? {
        let title = metaContent(property: "og:title", in: html) ?? titleTag(in: html)
        let description = metaContent(property: "og:description", in: html) ?? metaContent(name: "description", in: html)
        // Entities decoded BEFORE the URL is used: an HTML attribute writes `&` as `&amp;`, and a
        // signed CDN link (Instagram's cdninstagram `...&oh=...&oe=...`) left as `&amp;oh=` loses
        // its signature - the CDN answered 403 to every Instagram preview image (checked
        // 2026-10-22: raw 403, decoded 200). Desktop always decoded it, so it showed the picture.
        let imageURLString = metaContent(property: "og:image", in: html).map { resolveURLString($0.htmlEntityDecoded, relativeTo: url) }
        let siteName = metaContent(property: "og:site_name", in: html) ?? url.host

        guard title != nil || description != nil || imageURLString != nil else {
            AppLog.log("[LinkPreview] no og: tags found in %d chars of HTML for %@", html.count, LinkPreviewService.logLabel(url))
            return nil
        }

        return LinkPreviewData(
            url: url,
            title: title?.htmlEntityDecoded,
            description: description?.htmlEntityDecoded,
            imageURLString: imageURLString,
            siteName: siteName
        )
    }

    /// Matches `<meta property="og:title" content="...">` in either attribute order, single or
    /// double quotes - real-world OG tags aren't consistent about ordering/quoting.
    private func metaContent(property: String, in html: String) -> String? {
        metaContent(attribute: "property", value: property, in: html)
    }

    private func metaContent(name: String, in html: String) -> String? {
        metaContent(attribute: "name", value: name, in: html)
    }

    private func metaContent(attribute: String, value: String, in html: String) -> String? {
        let escapedValue = NSRegularExpression.escapedPattern(for: value)
        let patterns = [
            #"<meta[^>]+\#(attribute)=["']\#(escapedValue)["'][^>]+content=["']([^"']*)["']"#,
            #"<meta[^>]+content=["']([^"']*)["'][^>]+\#(attribute)=["']\#(escapedValue)["']"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            if let match = regex.firstMatch(in: html, options: [], range: range),
               let contentRange = Range(match.range(at: 1), in: html) {
                let raw = String(html[contentRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                return raw.isEmpty ? nil : raw
            }
        }
        return nil
    }

    private func titleTag(in html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "<title[^>]*>([^<]*)</title>", options: .caseInsensitive) else {
            return nil
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = regex.firstMatch(in: html, options: [], range: range),
              let contentRange = Range(match.range(at: 1), in: html) else {
            return nil
        }
        let raw = String(html[contentRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : raw
    }

    private func resolveURLString(_ raw: String, relativeTo base: URL) -> String {
        guard let resolved = URL(string: raw, relativeTo: base)?.absoluteURL else {
            return raw
        }
        return resolved.absoluteString
    }
}

/// Thread-safe, non-actor-isolated cache mirror so `LinkPreviewCardView.init` can synchronously
/// check for an already-known result before the view's first render, without needing `await`.
private final class SyncCacheMirror: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: (value: LinkPreviewData?, storedAt: Date)] = [:]

    /// Returns `nil` (outer) if the URL has never been resolved; `.some(nil)` if it resolved to
    /// "no preview data"; `.some(.some(data))` if it resolved to real preview data. An entry
    /// past `LinkPreviewService.cacheTTL` reads as never-resolved so the view goes through
    /// `preview(for:)`, which is where the expired entry actually gets dropped and refetched.
    func value(for key: String) -> LinkPreviewData?? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = storage[key] else { return nil }
        guard Date().timeIntervalSince(entry.storedAt) < LinkPreviewService.cacheTTL else { return nil }
        return .some(entry.value)
    }

    func set(_ value: LinkPreviewData?, for key: String) {
        lock.lock()
        defer { lock.unlock() }
        storage[key] = (value, Date())
    }

    func remove(for key: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: key)
    }
}

private extension String {
    /// Handles the small set of entities that actually show up in OG titles/descriptions -
    /// no need for a full HTML-entity table for this cosmetic use.
    var htmlEntityDecoded: String {
        self
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#38;", with: "&")
            .replacingOccurrences(of: "&#x26;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }
}

/// Reads one response into memory and stops once it passes `limit`: `.truncate` keeps the first
/// `limit` bytes (a page), `.fail` gives up (an image is useless cut short, and a declared
/// Content-Length past the limit ends it before a byte of the body comes down). Used as the session
/// delegate, so the check runs on each chunk as it arrives rather than after the whole body has
/// landed in memory. The delegate callbacks are serial; `continuation` is set before the task
/// starts and cleared once it has been resumed.
final class CappedResponseReader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Overflow { case truncate, fail }

    private let limit: Int
    private let onOverflow: Overflow
    private var buffer = Data()
    private var response: URLResponse?
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?

    init(limit: Int, onOverflow: Overflow) {
        self.limit = limit
        self.onOverflow = onOverflow
    }

    func read(_ request: URLRequest, using session: URLSession) async throws -> (Data, URLResponse) {
        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private func finish(_ result: Result<(Data, URLResponse), Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        self.response = response
        if onOverflow == .fail, response.expectedContentLength > Int64(limit) {
            completionHandler(.cancel)
            finish(.failure(URLError(.dataLengthExceedsMaximum)))
        } else {
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard continuation != nil else { return }
        let room = limit - buffer.count
        guard data.count > room else {
            buffer.append(data)
            return
        }
        dataTask.cancel()
        switch onOverflow {
        case .fail:
            finish(.failure(URLError(.dataLengthExceedsMaximum)))
        case .truncate:
            buffer.append(data.prefix(room))
            if let response {
                finish(.success((buffer, response)))
            } else {
                finish(.failure(URLError(.badServerResponse)))
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(error))
        } else if let response {
            finish(.success((buffer, response)))
        } else {
            finish(.failure(URLError(.badServerResponse)))
        }
    }
}

/// Decodes an image straight to the size it's shown at, through an ImageIO thumbnail, rather than
/// materialising a full bitmap: `UIImage(data:)` on a few megabytes of highly compressed pixels
/// can ask for gigabytes.
enum ImageDownsampler {
    /// Past this the source isn't a photo: a 200-megapixel sensor is about the largest real one.
    private static let maxSourcePixels: Double = 200_000_000

    static func image(from data: Data, maxPixelSize: Int) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, sourceOptions) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
           let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
           width.doubleValue * height.doubleValue > maxSourcePixels {
            return nil
        }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize)
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            return UIImage(data: data)
        }
        return UIImage(cgImage: cgImage)
    }
}
