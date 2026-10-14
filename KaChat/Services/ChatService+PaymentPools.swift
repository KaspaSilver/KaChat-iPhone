import Foundation

// The payment's From, and what is left of Chats Payment Privacy.
//
// Chats Payment Privacy (fresh spending addresses offered to contacts through invisible
// `addr_pool` envelopes, payments sent to them, `payment_notice` bubbles) was removed on
// 2026-10-13: the person now picks where a payment comes FROM on every send screen (Chatting
// Address or Choose an Address), and payments go to the contact's chatting address. Other
// clients may still send `addr_pool` / `addr_pool_request`; they are swallowed so they never
// show as text.
//
// `payment_notice` lives on for one job (XP-022): a chat payment sent From a spending address
// is a plain transfer the payee can't place, so the chatting address sends a notice naming it
// right after, and both sides file it in their 1:1 chat. A notice for a payment to any other
// address (an old app paying one of our former pool addresses) is dropped (XP-023).

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

    // MARK: - Chat payments From a spending address

    /// Tells the chat about a payment just sent From a spending address: an encrypted
    /// `payment_notice` from the chatting address, so the payee's app files the payment (and its
    /// memo, which travels only here) in the chat with us. Our own bubble is already there.
    /// Fire-and-forget: if it fails, the payee still has the KAS, shown in their self-chat.
    func sendSpendingPaymentNotice(to contact: Contact, txId: String, amountSompi: UInt64, memo: String) {
        let trimmedMemo = String(memo.trimmingCharacters(in: .whitespacesAndNewlines).prefix(PaymentNoticeContent.maxMemoLength))
        let payload = PaymentPoolCodec.encode(
            PaymentNoticeContent(txId: txId.lowercased(), amountSompi: amountSompi, address: contact.address,
                                 memo: trimmedMemo.isEmpty ? nil : trimmedMemo)
        )
        guard !payload.isEmpty else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await self.enqueueOutgoingTxOperation {
                    try await self.sendEnvelopeInternal(to: contact, payload: payload)
                }
                AppLog.log("[ChatService] Sent payment_notice for %@", String(txId.prefix(12)))
            } catch {
                AppLog.log("[ChatService] payment_notice send failed for %@: %@",
                           String(txId.prefix(12)), error.localizedDescription)
            }
        }
    }

    /// A `payment_notice` in a 1:1 chat - theirs (they paid us From a spending address) or our own
    /// read back on another device. It names a payment to the receiving side's chatting address;
    /// anything else (an old app's pool payment) is dropped. The payment becomes a payment bubble
    /// in this chat, with its memo; if it already showed in the self-chat ("From: <address>"),
    /// it moves here. Deduped by the payment's txId.
    func handlePaymentNotice(_ notice: PaymentNoticeContent, message: ChatMessage, contactAddress: String) {
        guard let wallet = WalletManager.shared.currentWallet else { return }
        let walletAddress = wallet.publicAddress
        let txId = notice.txId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard txId.count == 64, txId.allSatisfy(\.isHexDigit), notice.amountSompi > 0 else { return }
        let paidAddress = message.isOutgoing ? contactAddress : walletAddress
        guard notice.address.lowercased() == paidAddress.lowercased() else {
            AppLog.log("[ChatService] Dropped payment_notice %@ - not a payment to the chatting address",
                       String(txId.prefix(12)))
            return
        }
        let isOutgoing = message.isOutgoing
        let memo = String((notice.memo ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(PaymentNoticeContent.maxMemoLength))

        Task { @MainActor [weak self] in
            guard let self, self.isActiveWallet(walletAddress) else { return }
            if let existing = await self.findLocalMessage(txId: txId) {
                let counterpart = existing.isOutgoing ? existing.receiverAddress : existing.senderAddress
                if existing.isOutgoing == isOutgoing, counterpart.lowercased() == contactAddress.lowercased() {
                    return
                }
                // shown elsewhere first (the self-chat): it belongs to this chat
                self.removeMessage(txId: txId)
            }
            let bubble = ChatMessage(
                txId: txId,
                senderAddress: isOutgoing ? walletAddress : contactAddress,
                receiverAddress: notice.address,
                content: self.paymentNoticeText(amountSompi: notice.amountSompi, memo: memo, isOutgoing: isOutgoing),
                timestamp: message.timestamp,
                blockTime: message.blockTime,
                acceptingBlock: nil,
                isOutgoing: isOutgoing,
                messageType: .payment,
                deliveryStatus: .sent
            )
            self.addMessageToConversation(bubble, contactAddress: contactAddress)
            if let key = self.messageEncryptionKey() {
                self.messageStore.upsertMessage(bubble, contactAddress: contactAddress, encryptionKey: key, refile: true)
            }
            self.saveMessages()
            AppLog.log("[ChatService] Payment %@ filed in its chat from a payment_notice", String(txId.prefix(12)))
            if !isOutgoing {
                await self.verifyPaymentNotice(txId: txId, paidAddress: notice.address,
                                               claimedSompi: notice.amountSompi, memo: memo)
            }
        }
    }

    private func paymentNoticeText(amountSompi: UInt64, memo: String, isOutgoing: Bool) -> String {
        let amount = formatKasAmount(amountSompi)
        if memo.isEmpty {
            return String(format: KaspaUnit.label(AppLocalization.string(isOutgoing ? "Sent %@ KAS" : "Received %@ KAS")), amount)
        }
        return String(format: KaspaUnit.label(AppLocalization.string(isOutgoing ? "Sent %@ KAS — %@" : "Received %@ KAS — %@")),
                      amount, memo)
    }

    /// The chain is the judge of a received notice: the amount shown is what the transaction
    /// really paid our chatting address, and a transaction that paid it nothing is marked with a
    /// warning. Silent when the transaction can't be fetched (checked again on the next notice
    /// replay).
    private func verifyPaymentNotice(txId: String, paidAddress: String, claimedSompi: UInt64, memo: String) async {
        guard let url = kaspaRestURL(path: "/transactions/\(txId)"),
              let (data, response) = try? await URLSession.shared.data(for: Self.timedRequest(url)),
              let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode),
              let fullTx = try? JSONDecoder().decode(KaspaFullTransactionResponse.self, from: data) else {
            return
        }
        let paid = fullTx.outputs
            .filter { $0.scriptPublicKeyAddress?.lowercased() == paidAddress.lowercased() }
            .reduce(UInt64(0)) { $0 + $1.amount }
        guard paid != claimedSompi else { return }
        if paid == 0 {
            AppLog.log("[ChatService] payment_notice %@ FAILED verification - pays nothing to the chatting address",
                       String(txId.prefix(12)))
        }
        _ = updateIncomingPaymentStatus(
            txId: txId,
            deliveryStatus: paid == 0 ? .warning : .sent,
            content: paymentNoticeText(amountSompi: paid == 0 ? claimedSompi : paid, memo: memo, isOutgoing: false)
        )
        saveMessages()
    }
}
