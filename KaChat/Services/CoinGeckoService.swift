import Foundation

/// Free public CoinGecko REST client for the KAS spot price. No API key required. Returns nil on
/// any failure rather than throwing, so callers fall back to their last-known price. Currency is
/// caller-supplied (`AppCurrency`, Settings > Customization > Currency) - CoinGecko's public API
/// takes any of its listed `vs_currency` values directly.
final class CoinGeckoService: Sendable {
    static let shared = CoinGeckoService()

    private let session: URLSession
    private let baseURL = "https://api.coingecko.com"

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 20
        session = URLSession(configuration: config)
    }

    private struct SimplePriceResponse: Decodable {
        let kaspa: [String: Double]
    }

    func getCurrentPrice(currency: AppCurrency) async -> (price: Double, change24hPercent: Double?)? {
        guard var components = URLComponents(string: baseURL + "/api/v3/simple/price") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "ids", value: "kaspa"),
            URLQueryItem(name: "vs_currencies", value: currency.rawValue),
            URLQueryItem(name: "include_24hr_change", value: "true")
        ]
        guard let url = components.url else { return nil }

        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let decoded = try JSONDecoder().decode(SimplePriceResponse.self, from: data)
            guard let price = decoded.kaspa[currency.rawValue] else { return nil }
            let change24h = decoded.kaspa["\(currency.rawValue)_24h_change"]
            return (price: price, change24hPercent: change24h)
        } catch {
            return nil
        }
    }
}

/// The KAS price in the chosen currency, for the Send screens' KAS / currency switch. It used to
/// come from Portfolio's view model; Portfolio left the app on 2026-10-24 (it lives in the KaChat
/// wallet app), so this keeps just the price: the last one is persisted, a failed fetch retries on
/// a growing pause, and a currency change in Settings fetches again.
@MainActor
final class KasPriceModel: ObservableObject {
    static let shared = KasPriceModel()

    /// The price in `currentCurrency` (the name is historical - it is not necessarily USD).
    @Published private(set) var currentPriceUsd: Double?
    @Published private(set) var currentCurrency: AppCurrency

    private var lastFetchAt: Date?
    private var retryTask: Task<Void, Never>?

    private struct PersistedPrice: Codable {
        let price: Double
        let change24h: Double?
        let fetchedAt: Date
    }

    private init() {
        currentCurrency = AppSettings.load().currency
        restorePersisted()
        NotificationCenter.default.addObserver(forName: .settingsDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleSettingsChanged() }
        }
        refresh()
    }

    /// A price older than five minutes (or none at all) is fetched again.
    func refreshIfStale() {
        if let lastFetchAt, Date().timeIntervalSince(lastFetchAt) < 5 * 60, currentPriceUsd != nil { return }
        refresh()
    }

    private func refresh() {
        let currency = currentCurrency
        Task { [weak self] in
            guard let self else { return }
            if let result = await CoinGeckoService.shared.getCurrentPrice(currency: currency) {
                self.apply(result.price, change24h: result.change24hPercent, currency: currency)
            } else {
                self.retryUntilLoaded()
            }
        }
    }

    /// CoinGecko's keyless tier 429s a launch burst for a while: keep asking on a growing pause.
    private func retryUntilLoaded() {
        guard retryTask == nil else { return }
        let currency = currentCurrency
        retryTask = Task { [weak self] in
            for delay in [3.0, 8.0, 20.0, 45.0, 90.0, 180.0] {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let self, !Task.isCancelled, self.currentCurrency == currency else { return }
                if let result = await CoinGeckoService.shared.getCurrentPrice(currency: currency) {
                    self.apply(result.price, change24h: result.change24hPercent, currency: currency)
                    return
                }
            }
            self?.retryTask = nil
        }
    }

    private func apply(_ price: Double, change24h: Double?, currency: AppCurrency) {
        guard currency == currentCurrency else { return }
        currentPriceUsd = price
        lastFetchAt = Date()
        retryTask?.cancel()
        retryTask = nil
        let saved = PersistedPrice(price: price, change24h: change24h, fetchedAt: Date())
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: Self.priceKey(currency))
        }
    }

    private func handleSettingsChanged() {
        let newCurrency = AppSettings.load().currency
        guard newCurrency != currentCurrency else { return }
        currentCurrency = newCurrency
        retryTask?.cancel()
        retryTask = nil
        currentPriceUsd = nil
        lastFetchAt = nil
        restorePersisted()
        refresh()
    }

    private func restorePersisted() {
        guard let data = UserDefaults.standard.data(forKey: Self.priceKey(currentCurrency)),
              let saved = try? JSONDecoder().decode(PersistedPrice.self, from: data) else { return }
        currentPriceUsd = saved.price
    }

    /// The same key Portfolio used, so the last known price survives the move.
    private static func priceKey(_ currency: AppCurrency) -> String { "kachat_kas_price_\(currency.rawValue)" }
}
