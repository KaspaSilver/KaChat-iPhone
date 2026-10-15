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
    /// in this chat, with its memo. Deduped by the payment's txId.
    ///
    /// Any contact can send a notice naming any public txid (IOS-083), so a received one is checked
    /// on chain BEFORE anything is filed: the tx must pay our chatting address exactly the amount,
    /// carry no payload (a plain transfer) and be paid by nobody we know as another contact. Only
    /// a plain transfer from an unknown address that landed in the self-chat may move into the
    /// chat; another chat's payment, a message, or anything sent by us is never touched.
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
            let existing = await self.findLocalMessage(txId: txId)
            if let existing {
                let counterpart = existing.isOutgoing ? existing.receiverAddress : existing.senderAddress
                if existing.isOutgoing == isOutgoing, counterpart.lowercased() == contactAddress.lowercased() {
                    // already in this chat; one filed unverified gets its chain check again
                    if !isOutgoing, existing.messageType == .payment, existing.deliveryStatus == .warning,
                       case .valid = await self.checkNoticeOnChain(txId: txId, paidAddress: walletAddress,
                                                                    claimedSompi: notice.amountSompi, payer: contactAddress) {
                        _ = self.updateIncomingPaymentStatus(
                            txId: txId, deliveryStatus: .sent,
                            content: self.paymentNoticeText(amountSompi: notice.amountSompi, memo: memo, isOutgoing: false))
                        self.saveMessages()
                    }
                    return
                }
                guard !isOutgoing, self.isClaimableSelfChatPayment(existing, walletAddress: walletAddress) else {
                    AppLog.log("[ChatService] Dropped payment_notice %@ - it names a message that isn't an unclaimed self-chat payment",
                               String(txId.prefix(12)))
                    return
                }
            }
            if isOutgoing {
                // our own notice on another device: the outgoing bubble, if this device has none
                guard existing == nil else { return }
                self.fileNoticeBubble(txId: txId, notice: notice, memo: memo, message: message, contactAddress: contactAddress,
                                      walletAddress: walletAddress, isOutgoing: true, status: .sent, moving: false)
                return
            }
            switch await self.checkNoticeOnChain(txId: txId, paidAddress: walletAddress,
                                                 claimedSompi: notice.amountSompi, payer: contactAddress) {
            case .valid:
                if existing != nil { self.removeMessage(txId: txId) }
                self.fileNoticeBubble(txId: txId, notice: notice, memo: memo, message: message, contactAddress: contactAddress,
                                      walletAddress: walletAddress, isOutgoing: false, status: .sent, moving: existing != nil)
            case .invalid(let reason):
                AppLog.log("[ChatService] Dropped payment_notice %@ - %@", String(txId.prefix(12)), reason)
            case .unknown:
                // no chain answer: never move a record on an unchecked claim; with nothing stored
                // yet, show it marked unverified (checked again when the notice is read again)
                guard existing == nil else { return }
                self.fileNoticeBubble(txId: txId, notice: notice, memo: memo, message: message, contactAddress: contactAddress,
                                      walletAddress: walletAddress, isOutgoing: false, status: .warning, moving: false)
            }
        }
    }

    /// A stored message a received notice may claim: an incoming payment from an address that is
    /// no contact of ours (so it sits in the self-chat with "From:") and not our own.
    private func isClaimableSelfChatPayment(_ m: ChatMessage, walletAddress: String) -> Bool {
        guard m.messageType == .payment, !m.isOutgoing else { return false }
        let sender = m.senderAddress.lowercased()
        guard !sender.isEmpty, sender != walletAddress.lowercased() else { return false }
        return contactsManager.getContact(byAddress: m.senderAddress) == nil
    }

    private func fileNoticeBubble(txId: String, notice: PaymentNoticeContent, memo: String, message: ChatMessage,
                                  contactAddress: String, walletAddress: String, isOutgoing: Bool,
                                  status: ChatMessage.DeliveryStatus, moving: Bool) {
        let bubble = ChatMessage(
            txId: txId,
            senderAddress: isOutgoing ? walletAddress : contactAddress,
            receiverAddress: notice.address,
            content: paymentNoticeText(amountSompi: notice.amountSompi, memo: memo, isOutgoing: isOutgoing),
            timestamp: message.timestamp,
            blockTime: message.blockTime,
            acceptingBlock: nil,
            isOutgoing: isOutgoing,
            messageType: .payment,
            deliveryStatus: status
        )
        addMessageToConversation(bubble, contactAddress: contactAddress)
        if moving, let key = messageEncryptionKey() {
            messageStore.upsertMessage(bubble, contactAddress: contactAddress, encryptionKey: key, refile: true)
        }
        saveMessages()
        AppLog.log("[ChatService] Payment %@ filed in its chat from a payment_notice (%@)",
                   String(txId.prefix(12)), status.rawValue)
    }

    private enum NoticeCheck {
        case valid
        case invalid(String)
        /// the transaction couldn't be read (not indexed yet, or no answer)
        case unknown
    }

    /// What the chain says about a received notice: the tx pays `paidAddress` exactly
    /// `claimedSompi`, carries no payload (a chat payment or a message is never a notice's
    /// payment), and none of its inputs is ours or another contact's.
    private func checkNoticeOnChain(txId: String, paidAddress: String, claimedSompi: UInt64, payer: String) async -> NoticeCheck {
        guard let url = kaspaRestURL(path: "/transactions/\(txId)",
                                     queryItems: [URLQueryItem(name: "resolve_previous_outpoints", value: "light")]),
              let (data, response) = try? await URLSession.shared.data(for: Self.timedRequest(url)),
              let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode),
              let fullTx = try? JSONDecoder().decode(KaspaFullTransactionResponse.self, from: data) else {
            return .unknown
        }
        let paid = fullTx.outputs
            .filter { $0.scriptPublicKeyAddress?.lowercased() == paidAddress.lowercased() }
            .reduce(UInt64(0)) { $0 + $1.amount }
        guard paid == claimedSompi else { return .invalid("it pays \(paid) sompi, not \(claimedSompi)") }
        guard (fullTx.payload ?? "").isEmpty else { return .invalid("the transaction carries a payload") }
        let inputs = (fullTx.inputs ?? []).compactMap { $0.previousOutpointAddress?.lowercased() }
        guard !inputs.isEmpty else { return .unknown }
        for input in inputs {
            if input == paidAddress.lowercased() { return .invalid("paid by our own address") }
            if input != payer.lowercased(), contactsManager.getContact(byAddress: input) != nil {
                return .invalid("paid by another contact")
            }
        }
        return .valid
    }

    private func paymentNoticeText(amountSompi: UInt64, memo: String, isOutgoing: Bool) -> String {
        let amount = formatKasAmount(amountSompi)
        if memo.isEmpty {
            return String(format: KaspaUnit.label(AppLocalization.string(isOutgoing ? "Sent %@ KAS" : "Received %@ KAS")), amount)
        }
        return String(format: KaspaUnit.label(AppLocalization.string(isOutgoing ? "Sent %@ KAS — %@" : "Received %@ KAS — %@")),
                      amount, memo)
    }
}
