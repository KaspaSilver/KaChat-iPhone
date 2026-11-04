import Foundation

/// `.kachat` names on Kaspa covenants: reading the registry (design: KACHAT_NAMES.md, byte-level
/// reference: kachat-domains/README.md, source of truth: the kachat-domains Rust harness and CLI).
///
/// Everything in `KachatNames` except `KachatNamesService` is pure value code (Foundation, BLAKE3,
/// BLAKE2b): codecs, the manifest and the registry walker's decoding. The walker is checked against
/// `KaChatTests/KachatNamesVectors.json` by `scripts/test_kachat_names_registry.swift`.
enum KachatNames {

    /// Errors the core throws. Messages are for logs and developer UI; the screens map them.
    struct Failure: LocalizedError, Equatable {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }

        /// The manifest describes a registry this app doesn't build for: an earlier one (v1 - v3)
        /// or a later one than v5 (`newerRegistry`). Not an error to show as one: the screens say
        /// the registry is being set up.
        static let outdatedRegistry = Failure("manifest: an earlier registry; this app needs a registry v4 or v5 manifest")
        static let newerRegistry = Failure("manifest: a later registry version than this app builds for; update KaChat")

        var isOutdatedRegistry: Bool { self == Failure.outdatedRegistry || self == Failure.newerRegistry }

        /// A registry transaction that spends a gap or name not tracked yet: it applies once the
        /// walk has reached the transaction that created that UTXO (`RegistryState.apply`).
        static let waitsForEarlierTransaction = Failure("a registry input is not tracked yet: an earlier registry transaction comes first")
    }

    // MARK: - Constants (rusty-kaspa a41a333, kachat-domains params)

    /// A mainnet period. Registry v3 reads the period from the manifest (`Params.periodMs`):
    /// testnet-10 runs a 24-hour clock.
    static let yearMs: Int64 = 31_536_000_000

    static let zero32 = Data(repeating: 0, count: 32)
    static let ff32 = Data(repeating: 0xff, count: 32)

    // MARK: - Hex

    static func hex(_ data: Data) -> String {
        let digits: [Character] = Array("0123456789abcdef")
        var out = ""
        out.reserveCapacity(data.count * 2)
        for b in data {
            out.append(digits[Int(b >> 4)])
            out.append(digits[Int(b & 0x0f)])
        }
        return out
    }

    static func unhex(_ string: String) throws -> Data {
        let chars = Array(string.utf8)
        guard chars.count % 2 == 0 else { throw Failure("odd-length hex") }
        func nibble(_ c: UInt8) throws -> UInt8 {
            switch c {
            case 0x30...0x39: return c - 0x30
            case 0x61...0x66: return c - 0x61 + 10
            case 0x41...0x46: return c - 0x41 + 10
            default: throw Failure("bad hex digit")
            }
        }
        var out = Data(capacity: chars.count / 2)
        var i = 0
        while i < chars.count {
            out.append(try nibble(chars[i]) << 4 | nibble(chars[i + 1]))
            i += 2
        }
        return out
    }

    static func unhex32(_ string: String) throws -> Data {
        let d = try unhex(string)
        guard d.count == 32 else { throw Failure("expected 32 hex bytes") }
        return d
    }

    // MARK: - Little-endian helpers

    static func le16(_ v: UInt16) -> Data { Data([UInt8(v & 0xff), UInt8(v >> 8)]) }
    static func le32(_ v: UInt32) -> Data { Data((0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) }) }
    static func le64(_ v: UInt64) -> Data { Data((0..<8).map { UInt8(truncatingIfNeeded: v >> (8 * UInt64($0))) }) }

    // MARK: - Hashes

    static func blake3(_ data: Data) -> Data { Blake3.hash(data) }

    /// Unkeyed BLAKE2b-256 (the P2SH script hash).
    static func blake2b256(_ data: Data) -> Data {
        var h = Blake2b(digestLength: 32, key: nil)
        h.update(data)
        return h.finalize()
    }

    /// rusty-kaspa `blake2b_hasher!` (keyed BLAKE2b-256, the domain string as the key).
    static func blake2bKeyed(_ domain: String, _ data: Data) -> Data {
        var h = Blake2b(digestLength: 32, key: Data(domain.utf8))
        h.update(data)
        return h.finalize()
    }

    // MARK: - Names

    enum Codec {
        /// What a person types, made canonical: trimmed, lowercased, `.kachat` dropped.
        static func normalize(_ raw: String) -> String {
            var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if s.hasSuffix(".kachat") { s.removeLast(".kachat".count) }
            return s
        }

        /// The gap's rule: `a-z 0-9 -`, 1..32 bytes, no hyphen at either end.
        static func validate(_ name: String) throws {
            let b = Array(name.utf8)
            guard !b.isEmpty, b.count <= 32 else { throw Failure("a name is 1..32 characters") }
            for c in b {
                let ok = (c >= 0x61 && c <= 0x7a) || (c >= 0x30 && c <= 0x39) || c == 0x2d
                guard ok else { throw Failure("a name is a-z, 0-9 and '-' only") }
            }
            guard b.first != 0x2d, b.last != 0x2d else { throw Failure("a name cannot start or end with '-'") }
        }

        static func isValid(_ name: String) -> Bool { (try? validate(name)) != nil }

        /// `key = blake3(name)`.
        static func key(_ name: String) -> Data { KachatNames.blake3(Data(name.utf8)) }

        /// The name zero padded to 32 bytes (the name state field).
        static func padded(_ name: String) -> Data {
            var d = Data(name.utf8.prefix(32))
            d.append(Data(repeating: 0, count: 32 - d.count))
            return d
        }

        /// The name in a padded field (bytes up to the first zero).
        static func unpadded(_ field: Data) -> String {
            let bytes = field.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }

        // MARK: Integers

        /// 8-byte little-endian sign-magnitude (state ints, template part lengths).
        static func num8(_ v: Int64) -> Data {
            precondition(v != Int64.min, "num8 of Int64.min")
            var out = KachatNames.le64(v.magnitude)
            if v < 0 { out[out.startIndex + 7] |= 0x80 }
            return out
        }

        /// Little-endian sign-magnitude bytes -> Int64.
        static func scriptNum(_ b: Data) throws -> Int64 {
            if b.isEmpty { return 0 }
            guard b.count <= 8 else { throw Failure("script number longer than 8 bytes") }
            let bytes = [UInt8](b)
            var v: UInt64 = 0
            for (k, byte) in bytes.enumerated() {
                let x = k == bytes.count - 1 ? byte & 0x7f : byte
                v |= UInt64(x) << (8 * UInt64(k))
            }
            let negative = bytes[bytes.count - 1] & 0x80 != 0
            let value = Int64(bitPattern: v)
            return negative ? -value : value
        }

        // MARK: States

        /// Gap state, 66 bytes: `0x20 lo 0x20 hi`.
        static func gapState(lo: Data, hi: Data) -> Data {
            var d = Data([0x20]); d.append(lo); d.append(0x20); d.append(hi)
            return d
        }

        /// Name state (registry v2 and v3, unchanged), 126 bytes:
        /// `0x20 key 0x20 name 0x20 owner 0x08 price 0x08 periodStart 0x08 expiresAt`
        /// (price at bytes 100..108, periodStart 109..117, expiresAt 118..126).
        static func nameState(_ f: NameFields) -> Data {
            var d = Data([0x20]); d.append(f.key)
            d.append(0x20); d.append(f.paddedName)
            d.append(0x20); d.append(f.owner)
            d.append(0x08); d.append(num8(f.price))
            d.append(0x08); d.append(num8(f.periodStart))
            d.append(0x08); d.append(num8(f.expiresAt))
            return d
        }

        /// Offer state (registry v3), 108 bytes: `0x20 key 0x20 buyer 0x20 seller 0x08 refundAfter`.
        static func offerState(_ f: OfferFields) -> Data {
            var d = Data([0x20]); d.append(f.key)
            d.append(0x20); d.append(f.buyer)
            d.append(0x20); d.append(f.seller)
            d.append(0x08); d.append(num8(f.refundAfter))
            return d
        }

        // MARK: Scripts

        /// `OP_BLAKE2B <blake2b-256(redeem)> OP_EQUAL` (rusty-kaspa `pay_to_script_hash_script`).
        static func p2shScript(_ redeem: Data) -> Data {
            var d = Data([0xaa, 0x20])
            d.append(KachatNames.blake2b256(redeem))
            d.append(0x87)
            return d
        }

        /// Schnorr P2PK: `0x20 <x-only key> OP_CHECKSIG`.
        static func p2pkScript(_ xonly: Data) -> Data {
            var d = Data([0x20]); d.append(xonly); d.append(0xac)
            return d
        }

        /// Every push of a push-only script, as bytes (OP_0 -> [], OP_n -> [n], OP_1NEGATE -> [0x81]).
        static func parsePushes(_ script: Data) throws -> [Data] {
            let s = [UInt8](script)
            var out: [Data] = []
            var i = 0
            func take(_ n: Int) throws -> Data {
                guard i + n <= s.count else { throw Failure("truncated push") }
                defer { i += n }
                return Data(s[i..<(i + n)])
            }
            while i < s.count {
                let op = s[i]
                i += 1
                switch op {
                case 0x00: out.append(Data())
                case 0x01...0x4b: out.append(try take(Int(op)))
                case 0x4c:
                    let n = Int(try take(1)[0])
                    out.append(try take(n))
                case 0x4d:
                    let l = [UInt8](try take(2))
                    out.append(try take(Int(l[0]) | Int(l[1]) << 8))
                case 0x4e:
                    let l = [UInt8](try take(4))
                    let n = Int(l[0]) | Int(l[1]) << 8 | Int(l[2]) << 16 | Int(l[3]) << 24
                    out.append(try take(n))
                case 0x4f: out.append(Data([0x81]))
                case 0x51...0x60: out.append(Data([op - 0x50]))
                default: throw Failure(String(format: "not a push-only script (opcode 0x%02x)", op))
                }
            }
            return out
        }

        // MARK: Templates and covenant ids

        /// silverscript `template_hash`: `blake3(num8(|prefix|) || prefix || num8(|suffix|) || suffix)`.
        static func templateHash(prefix: Data, suffix: Data) -> Data {
            var h = Blake3()
            h.update(num8(Int64(prefix.count)))
            h.update(prefix)
            h.update(num8(Int64(suffix.count)))
            h.update(suffix)
            return h.finalize()
        }

        /// rusty-kaspa `covenant_id(outpoint, authorized outputs)` (KIP-20).
        static func covenantId(outpoint: Outpoint, authorized: [(index: UInt32, output: TxOutput)]) -> Data {
            var d = outpoint.txid
            d.append(KachatNames.le32(outpoint.index))
            d.append(KachatNames.le64(UInt64(authorized.count)))
            for (index, o) in authorized {
                d.append(KachatNames.le32(index))
                d.append(KachatNames.le64(o.value))
                d.append(KachatNames.le16(o.scriptVersion))
                d.append(KachatNames.le64(UInt64(o.script.count)))
                d.append(o.script)
            }
            return KachatNames.blake2bKeyed("CovenantID", d)
        }

        // MARK: Payload markers (KACHAT_NAMES_INDEXER.md B4)

        /// `kchat:1:profile:<json>`: an address profile record (KACHAT_NAMES.md section 7).
        static func profilePayload(json: Data) -> Data {
            var d = Data("kchat:1:profile:".utf8)
            d.append(json)
            return d
        }

        static let maxProfileJSONBytes = 2048
    }

    // MARK: - Typed states

    struct NameFields: Equatable {
        var key: Data
        var paddedName: Data
        var owner: Data
        var price: Int64
        /// unix ms, the start of the current paid period (registry v2): register sets it to `now`,
        /// `renew` to the old expiry; every other entry keeps it.
        var periodStart: Int64
        var expiresAt: Int64

        init(key: Data, paddedName: Data, owner: Data, price: Int64, periodStart: Int64, expiresAt: Int64) {
            self.key = key
            self.paddedName = paddedName
            self.owner = owner
            self.price = price
            self.periodStart = periodStart
            self.expiresAt = expiresAt
        }

        init(name: String, owner: Data, price: Int64, periodStart: Int64, expiresAt: Int64) {
            self.init(key: Codec.key(name), paddedName: Codec.padded(name), owner: owner, price: price,
                      periodStart: periodStart, expiresAt: expiresAt)
        }

        var name: String { Codec.unpadded(paddedName) }
        var encoded: Data { Codec.nameState(self) }

        /// transfer / buy / offer accept: new owner, listing cleared, period and expiry kept.
        func withOwner(_ owner: Data) -> NameFields {
            NameFields(key: key, paddedName: paddedName, owner: owner, price: 0, periodStart: periodStart, expiresAt: expiresAt)
        }

        /// list: the price, period and expiry kept.
        func withPrice(_ price: Int64) -> NameFields {
            NameFields(key: key, paddedName: paddedName, owner: owner, price: price, periodStart: periodStart, expiresAt: expiresAt)
        }

        /// What `extend(years)` leaves: the same period start, the expiry `years` periods later.
        func extended(_ years: Int64, periodMs: Int64) -> NameFields {
            NameFields(key: key, paddedName: paddedName, owner: owner, price: price, periodStart: periodStart,
                       expiresAt: expiresAt + years * periodMs)
        }

        /// What `renew(years)` leaves: a new period from the old expiry, so no time is lost or gained.
        func renewed(_ years: Int64, periodMs: Int64) -> NameFields {
            NameFields(key: key, paddedName: paddedName, owner: owner, price: price, periodStart: expiresAt,
                       expiresAt: expiresAt + years * periodMs)
        }
    }

    struct OfferFields: Equatable {
        var key: Data
        var buyer: Data
        /// The name's owner the offer was made to (registry v3): only they can accept or decline it.
        var seller: Data
        var refundAfter: Int64
        var encoded: Data { Codec.offerState(self) }
    }
}
