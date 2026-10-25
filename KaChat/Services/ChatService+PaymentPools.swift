import Foundation
import Combine

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
                // usually an empty chatting address: kept, and sent once it has KAS (IOS-086)
                AppLog.log("[ChatService] payment_notice send failed for %@, kept for later: %@",
                           String(txId.prefix(12)), error.localizedDescription)
                self.keepUnsentNotice(UnsentPaymentNotice(contactAddress: contact.address, payload: payload, txId: txId))
            }
        }
    }

    // MARK: - Notices waiting for the chatting address

    struct UnsentPaymentNotice: Codable, Equatable {
        let contactAddress: String
        let payload: String
        let txId: String
    }

    private var unsentNoticesKey: String? {
        WalletManager.shared.currentWallet.map { "kachat_unsent_payment_notices.\($0.publicAddress.lowercased())" }
    }

    private var unsentNotices: [UnsentPaymentNotice] {
        get {
            guard let key = unsentNoticesKey, let data = UserDefaults.standard.data(forKey: key) else { return [] }
            return (try? JSONDecoder().decode([UnsentPaymentNotice].self, from: data)) ?? []
        }
        set {
            guard let key = unsentNoticesKey else { return }
            if newValue.isEmpty {
                UserDefaults.standard.removeObject(forKey: key)
            } else if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: key)
            }
        }
    }

    private func keepUnsentNotice(_ notice: UnsentPaymentNotice) {
        var list = unsentNotices
        guard !list.contains(where: { $0.txId == notice.txId }) else { return }
        list.append(notice)
        unsentNotices = Array(list.suffix(50))
    }

    /// Sends the notices that failed for want of KAS on the chatting address - called when its
    /// balance turns positive (`observeChattingBalanceForNotices`). One at a time; any that
    /// still fails stays for next time.
    func sendUnsentPaymentNotices() async {
        guard !sendingUnsentNotices else { return }
        let pending = unsentNotices
        guard !pending.isEmpty else { return }
        sendingUnsentNotices = true
        defer { sendingUnsentNotices = false }
        var left: [UnsentPaymentNotice] = []
        for notice in pending {
            guard let contact = contactsManager.getContact(byAddress: notice.contactAddress) else { continue }
            do {
                _ = try await enqueueOutgoingTxOperation {
                    try await self.sendEnvelopeInternal(to: contact, payload: notice.payload)
                }
                AppLog.log("[ChatService] Sent a kept payment_notice for %@", String(notice.txId.prefix(12)))
            } catch {
                left.append(notice)
            }
        }
        unsentNotices = left
    }

    /// The chatting address got KAS: the notices waiting for it go out.
    func observeChattingBalanceForNotices() {
        unsentNoticesCancellable = WalletManager.shared.$currentWallet
            .map { $0?.balanceSompi ?? 0 }
            .removeDuplicates()
            .filter { $0 > 0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { await self?.sendUnsentPaymentNotices() }
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
                    guard !isOutgoing, existing.messageType == .payment, existing.deliveryStatus == .warning else { return }
                    switch await self.checkNoticeOnChain(txId: txId, paidAddress: walletAddress,
                                                         claimedSompi: notice.amountSompi, payer: contactAddress) {
                    case .valid:
                        _ = self.updateIncomingPaymentStatus(
                            txId: txId, deliveryStatus: .sent,
                            content: self.paymentNoticeText(amountSompi: notice.amountSompi, memo: memo, isOutgoing: false))
                        self.saveMessages()
                    case .invalid(let reason):
                        // still this notice's unverified bubble after the await?
                        guard self.isActiveWallet(walletAddress),
                              let current = await self.findLocalMessage(txId: txId),
                              !current.isOutgoing, current.deliveryStatus == .warning,
                              current.senderAddress.lowercased() == contactAddress.lowercased() else { return }
                        // the claim was false: its unverified bubble goes (a real payment under
                        // that txid is filed where it belongs by the next payment fetch)
                        self.unmarkNoticeBubble(txId)
                        self.removeMessage(txId: txId)
                        self.messageStore.deleteMessage(txId: txId)
                        self.saveMessages()
                        AppLog.log("[ChatService] Removed unverified payment_notice bubble %@ - %@", String(txId.prefix(12)), reason)
                    case .unknown:
                        break
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
                // Placement again, after the await: another notice for the same txid may have
                // claimed it meanwhile (first notice wins), or the record may have appeared.
                guard self.isActiveWallet(walletAddress) else { return }
                let current = await self.findLocalMessage(txId: txId)
                if let current {
                    guard self.isClaimableSelfChatPayment(current, walletAddress: walletAddress) else {
                        AppLog.log("[ChatService] Dropped payment_notice %@ - claimed or filed while it was checked",
                                   String(txId.prefix(12)))
                        return
                    }
                    self.removeMessage(txId: txId)
                }
                self.fileNoticeBubble(txId: txId, notice: notice, memo: memo, message: message, contactAddress: contactAddress,
                                      walletAddress: walletAddress, isOutgoing: false, status: .sent, moving: current != nil)
            case .invalid(let reason):
                AppLog.log("[ChatService] Dropped payment_notice %@ - %@", String(txId.prefix(12)), reason)
            case .unknown:
                // no chain answer: never move a record on an unchecked claim; with nothing stored
                // yet, show it marked unverified (checked again when the notice is read again).
                // After the await: still this wallet (a switch meanwhile must not file A's bubble
                // into B - IOS-090), and still nothing stored under that txid.
                guard existing == nil, self.isActiveWallet(walletAddress),
                      await self.findLocalMessage(txId: txId) == nil else { return }
                self.fileNoticeBubble(txId: txId, notice: notice, memo: memo, message: message, contactAddress: contactAddress,
                                      walletAddress: walletAddress, isOutgoing: false, status: .warning, moving: false)
            }
        }
    }

    /// A stored message a received notice may claim: an incoming payment from an address that is
    /// no contact of ours (so it sits in the self-chat with "From:") and none of our own.
    private func isClaimableSelfChatPayment(_ m: ChatMessage, walletAddress: String) -> Bool {
        guard m.messageType == .payment, !m.isOutgoing else { return false }
        let sender = m.senderAddress.lowercased()
        guard !sender.isEmpty, !ownAddressesForNotices(walletAddress: walletAddress).contains(sender) else { return false }
        return contactsManager.getContact(byAddress: m.senderAddress) == nil
    }

    /// Every address this phone knows as the person's own, lowercased: the chatting address,
    /// every revealed spending address, every saved account's chatting and (cached) spending
    /// addresses and every Cold Storage receive address. A transfer from any of them is the person moving their own
    /// money, which no contact's notice may ever claim (IOS-083).
    private func ownAddressesForNotices(walletAddress: String) -> Set<String> {
        var own = Set(WalletManager.shared.allSpendingAddresses().map { $0.lowercased() })
        own.insert(walletAddress.lowercased())
        // every saved account: its chatting address and every spending address this phone
        // derived for it (run 10: B's Address #2 topping up A's chatting address is ours too)
        for account in WalletManager.shared.savedAccounts {
            own.insert(account.publicAddress.lowercased())
            for spending in WalletManager.shared.cachedSpendingAddresses(ofAccount: account.publicAddress) {
                own.insert(spending.lowercased())
            }
        }
        return own
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
        if !isOutgoing { markNoticeBubble(txId, wallet: walletAddress) }
        addMessageToConversation(bubble, contactAddress: contactAddress)
        if moving, let key = messageEncryptionKey() {
            messageStore.upsertMessage(bubble, contactAddress: contactAddress, encryptionKey: key, refile: true)
        }
        saveMessages()
        AppLog.log("[ChatService] Payment %@ filed in its chat from a payment_notice (%@)",
                   String(txId.prefix(12)), status.rawValue)
    }

    // MARK: Bubbles a notice filed (IOS-083, run 11)
    //
    // A received payment a payment_notice filed in its sender's chat is that notice's to confirm
    // (its chain check, with the own-address and other-contact rules). The generic incoming-payment
    // code (UTXO resolution, the REST payment sync, the warning retry) knows nothing of notices,
    // and promoting such a bubble to "sent" in place would confirm a claim nobody checked - so it
    // leaves the txids listed here alone. Per wallet, the newest 2,000.

    private var noticeBubblesKey: String? {
        WalletManager.shared.currentWallet.map { Self.noticeBubblesKey(wallet: $0.publicAddress) }
    }

    private static func noticeBubblesKey(wallet: String) -> String {
        "kachat_notice_bubbles_\(wallet.lowercased())"
    }

    func isNoticeBubble(_ txId: String) -> Bool {
        guard let key = noticeBubblesKey else { return false }
        return (UserDefaults.standard.stringArray(forKey: key) ?? []).contains(txId.lowercased())
    }

    /// `wallet`: the wallet the bubble was filed for (default: the active one).
    func markNoticeBubble(_ txId: String, wallet: String? = nil) {
        guard let key = wallet.map(Self.noticeBubblesKey(wallet:)) ?? noticeBubblesKey else { return }
        var ids = UserDefaults.standard.stringArray(forKey: key) ?? []
        guard !ids.contains(txId.lowercased()) else { return }
        ids.append(txId.lowercased())
        UserDefaults.standard.set(Array(ids.suffix(2000)), forKey: key)
    }

    func unmarkNoticeBubble(_ txId: String) {
        guard let key = noticeBubblesKey else { return }
        let ids = (UserDefaults.standard.stringArray(forKey: key) ?? []).filter { $0 != txId.lowercased() }
        UserDefaults.standard.set(ids, forKey: key)
    }

    private enum NoticeCheck {
        case valid
        case invalid(String)
        /// the transaction couldn't be read (not indexed yet, or no answer)
        case unknown
    }

    /// What the chain says about a received notice: the tx pays `paidAddress` exactly
    /// `claimedSompi`, carries no payload (a chat payment or a message is never a notice's
    /// payment), and none of its inputs is ours (any of `ownAddressesForNotices`) or another
    /// contact's.
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
        // an input without a resolved address could be one of ours: no chain answer yet
        let rawInputs = fullTx.inputs ?? []
        guard !rawInputs.isEmpty, rawInputs.allSatisfy({ $0.previousOutpointAddress != nil }) else { return .unknown }
        let inputs = rawInputs.compactMap { $0.previousOutpointAddress?.lowercased() }
        let own = ownAddressesForNotices(walletAddress: paidAddress)
        for input in inputs {
            if own.contains(input) { return .invalid("paid by one of our own addresses") }
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
