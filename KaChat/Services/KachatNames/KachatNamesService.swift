import Foundation
import P256K
import Security

/// `.kachat` names: the app side of the pure code in `KachatNames.*`. This service adds what needs
/// the app: the network gate, loading and verifying the manifest, and the address profile record.
///
/// Names run on testnet-10 and, since the mainnet v1 launch on 2026-10-09, on mainnet: each network
/// has its own bundled manifest (`Resources/kachat-names-<network>.json`), its own pinned templates
/// and price tables (`KachatNames.Manifest`), and its own address prefix (`addressPrefix`). The
/// manifest in use always matches the network the app runs on (`networkName`).
@MainActor
final class KachatNamesService: ObservableObject {
    static let shared = KachatNamesService()

    @Published private(set) var manifest: KachatNames.Manifest?
    /// The manifest describes an earlier registry: names wait for the v3 genesis manifest.
    /// The screens show "Setting up" instead of an error.
    @Published private(set) var registryUpgrading = false

    /// Why the bundled manifest was refused. The bundle can't change while the app runs, so it
    /// is not read and verified again on every call (until `resetManifest`).
    private var bundleFailure: Error? {
        didSet { bundleFailureNetwork = bundleFailure == nil ? nil : Self.networkName }
    }
    private var bundleFailureNetwork: String?

    enum ServiceError: LocalizedError {
        case testnetOnly
        case wrongAddressNetwork
        case noManifest(String)
        case dryRunManifest
        case wrongNodeNetwork(String)
        case keyMismatch
        case notOnChain(String)
        case badProfile(String)
        case submitMismatch(expected: String, got: String)
        /// the manifest is for an earlier registry; this app builds for v3 and waits for its genesis
        case registryUpgrading

        var errorDescription: String? {
            switch self {
            case .registryUpgrading:
                return AppLocalization.string("The .kachat registry is being upgraded. Names open here again once the new registry is live.")
            case .testnetOnly: return AppLocalization.string(".kachat names aren't live on this network yet")
            case .wrongAddressNetwork: return AppLocalization.string("This address is on a different network than the app.")
            case .noManifest(let why): return "No .kachat registry manifest: \(why)"
            case .dryRunManifest: return "The .kachat manifest is from a dry run; that registry does not exist"
            case .wrongNodeNetwork(let n): return "The node is on \(n), not \(KachatNamesService.networkName)"
            case .keyMismatch: return "The signing key is not the key the transaction was built for"
            case .notOnChain(let what): return "\(what) is not on chain (or not with the registry covenant id)"
            case .badProfile(let why): return "Profile: \(why)"
            case .submitMismatch(let e, let g): return "The node accepted \(g), expected \(e)"
            }
        }
    }

    private init() {}

    // MARK: - Gate

    /// The only network names may run on until an audit.
    /// The .kachat UI and identity - on every network since 2026-10-04: mainnet shows the same
    /// screens as testnet (and people by their .kachat name, not KNS), in a "Coming soon" state
    /// until its registry launches. Every UI change lands on both networks. The KNS branches this
    /// guards are kept, unreachable, as a switch-back.
    nonisolated static var isEnabled: Bool { true }
    /// Whether this network has a live registry the app reads and transacts with (lookups,
    /// listings, registrations, resolving typed names): testnet-10, and mainnet since 2026-10-09.
    nonisolated static var isLaunched: Bool { KachatNames.Manifest.supportedNetworks.contains(networkName) }

    /// The manifest network name of the network the app runs on.
    nonisolated static var networkName: String { AppSettings.load().networkType == .mainnet ? "mainnet" : "testnet-10" }

    /// The address prefix of the network the app runs on: names, owners and registry outputs are
    /// shown and parsed with it.
    nonisolated static var addressPrefix: String { AppSettings.load().networkType == .mainnet ? "kaspa" : "kaspatest" }
    /// Address profiles (`kchat:1:profile:`) work on every network: a profile is a plain
    /// self-send from the chatting address, with no registry behind it, so mainnet can save and
    /// read them before its registry launches. Only the primary name needs the registry.
    nonisolated static var profilesEnabled: Bool { isEnabled }

    /// Whether `error` means the registry is being upgraded (a v1 manifest), not a failure.
    nonisolated static func isRegistryUpgrading(_ error: Error) -> Bool {
        if case ServiceError.registryUpgrading = error { return true }
        return (error as? KachatNames.Failure)?.isOutdatedRegistry == true
    }

    /// The gate on every registry read and write: the network the app runs on has a live
    /// registry (`isLaunched`). `isEnabled` only turns the UI on.
    func requireLaunched() throws {
        guard Self.isLaunched else { throw ServiceError.testnetOnly }
    }

    // MARK: - Manifest

    /// The verified registry manifest: `kachat-names-testnet-10.json` from the app bundle when it
    /// ships one, else the indexer's `GET /names/manifest`. Cached once verified.
    func loadManifest(allowDryRun: Bool = false) async throws -> KachatNames.Manifest {
        try requireLaunched()
        // the network switched: the other network's manifest (and the registry read from it) go
        if let m = manifest, m.network != Self.networkName {
            resetManifest()
            KachatNamesRegistry.shared.reset()
        } else if manifest == nil, bundleFailureNetwork != Self.networkName {
            bundleFailure = nil
            registryUpgrading = false
        }
        if let m = manifest, allowDryRun || !m.isDryRun {
            return m
        }
        if let bundleFailure { throw bundleFailure }
        let (data, source) = try await manifestData()
        let m: KachatNames.Manifest
        do {
            m = try KachatNames.Manifest.decode(data)
            // an indexer-served manifest is trusted only when every template is pinned in the app
            try m.verify(source: source == "bundle" ? .bundle : .indexer)
        } catch {
            // A registry version this app doesn't build for (an earlier or a later one) is expected,
            // not an error: say "being upgraded", once, and stop re-reading the bundle.
            let refused: Error = Self.isRegistryUpgrading(error) ? ServiceError.registryUpgrading : error
            if Self.isRegistryUpgrading(error) {
                if !registryUpgrading { AppLog.log("[KachatNames] the %@ manifest is an earlier registry; .kachat waits for a registry v4 or v5 manifest", source) }
                registryUpgrading = true
            }
            if source == "bundle" { bundleFailure = refused }
            throw refused
        }
        if m.isDryRun && !allowDryRun {
            throw ServiceError.dryRunManifest
        }
        registryUpgrading = false
        manifest = m
        return m
    }

    /// Forget the cached manifest (network switch, indexer change).
    func resetManifest() {
        manifest = nil
        bundleFailure = nil
        registryUpgrading = false
    }

    private func manifestData() async throws -> (Data, String) {
        if let url = Bundle.main.url(forResource: KachatNames.Manifest.bundleResource(network: Self.networkName), withExtension: "json"),
           let data = try? Data(contentsOf: url) {
            return (data, "bundle")
        }
        let base = AppSettings.load().kachatNamesIndexerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else {
            throw ServiceError.noManifest("none in the app and no indexer is configured")
        }
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        guard let url = URL(string: trimmed + "/names/manifest") else {
            throw ServiceError.noManifest("bad indexer URL")
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ServiceError.noManifest("the indexer answered \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return (data, url.absoluteString)
    }

    // MARK: - Environment

    /// The signer's x-only key for a wallet private key.
    nonisolated static func xonlyKey(privateKey: Data) throws -> Data {
        let key = try P256K.Schnorr.PrivateKey(dataRepresentation: privateKey)
        return Data(key.xonly.bytes)
    }

    // MARK: - UTXOs

    /// The P2SH address (this network's prefix) of a P2SH script (`OP_BLAKE2B <hash> OP_EQUAL`).
    nonisolated static func p2shAddress(script: Data) -> String? {
        let b = [UInt8](script)
        guard b.count == 35, b[0] == 0xaa, b[1] == 0x20, b[34] == 0x87 else { return nil }
        return KaspaAddress(hrp: addressPrefix, type: .scriptHash, payload: Data(b[2..<34])).address
    }

    // MARK: - Profile record

    /// The address profile record (KACHAT_NAMES.md section 7): a self-transfer with payload
    /// `kchat:1:profile:<json>`, built and signed by the existing version-0 payload builder.
    /// `json` is the whole profile (records replace, never patch), a JSON object of at most 2 KB.
    func buildProfileRecord(address: String, privateKey: Data, utxos: [UTXO], json: Data) throws -> KaspaRpcTransaction {
        guard Self.profilesEnabled else { throw ServiceError.testnetOnly }
        // The record is written from the wallet's address on the network the app runs on.
        guard NetworkType(address: address) == AppSettings.load().networkType else { throw ServiceError.wrongAddressNetwork }
        guard json.count <= KachatNames.Codec.maxProfileJSONBytes else { throw ServiceError.badProfile("over 2 KB") }
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            throw ServiceError.badProfile("not a JSON object")
        }
        guard (object["v"] as? NSNumber)?.intValue == 1 else { throw ServiceError.badProfile("\"v\" must be 1") }
        let payload = KachatNames.Codec.profilePayload(json: json)
        let plain = utxos.filter { $0.covenantId == nil }
        return try KasiaTransactionBuilder.buildPayloadSelfSendTx(
            from: address, senderPrivateKey: privateKey, utxos: plain, payload: payload
        )
    }

    /// Build, sign and submit the profile record; returns its id.
    @discardableResult
    func submitProfileRecord(address: String, privateKey: Data, utxos: [UTXO], json: Data) async throws -> String {
        let tx = try buildProfileRecord(address: address, privateKey: privateKey, utxos: utxos, json: json)
        return try await NodePoolService.shared.submitTransaction(tx).txId
    }
}
