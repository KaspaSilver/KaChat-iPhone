import Foundation

// The payment's From, and what is left of Chats Payment Privacy.
//
// Chats Payment Privacy (fresh spending addresses offered to contacts through invisible
// `addr_pool` envelopes, payments sent to them, `payment_notice` bubbles) was removed on
// 2026-10-13: the person now picks where a payment comes FROM on every send screen (Chatting
// Address or Choose an Address), and payments go to the contact's chatting address. Other
// clients may still send the envelopes; they are swallowed so they never show as text.

extension ChatService {
    /// The address a payment is funded from: the chatting address (nil, the default From) or
    /// the spending address at `spendingIndex` (Choose an Address).
    func paymentFundingSourceAddress(spendingIndex: Int? = nil) throws -> String {
        guard let wallet = WalletManager.shared.currentWallet else {
            throw KasiaError.walletNotFound
        }
        guard let spendingIndex else { return wallet.publicAddress }
        guard let address = WalletManager.shared.spendingAddress(at: spendingIndex) else {
            throw KasiaError.walletNotFound
        }
        return address
    }

    /// True for a retired payment-pool envelope (`addr_pool`, `addr_pool_request`,
    /// `payment_notice`) from another client: it is dropped, never a bubble.
    func isRetiredPaymentPoolEnvelope(_ content: String) -> Bool {
        PaymentPoolCodec.parse(content) != nil
    }
}
