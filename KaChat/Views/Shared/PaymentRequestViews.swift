import SwiftUI
import UIKit

// MARK: - Request Payment (Chats > + > Request Payment)

/// Makes a payment request link: to your chatting or spending address, an exact amount and what
/// it's for. Copy (or share) the link and send it anywhere; in KaChat it opens Send Kaspa filled
/// in (`PaymentRequest`, `KaChatInternalLink.paymentRequest`). Made from a 1:1 chat's + sheet
/// (`recipient`), it is for that person: the button sends it into the chat instead.
struct CreatePaymentRequestView: View {
    /// The contact it is for (a 1:1 chat): Send Payment Request sends it to them.
    var recipient: Contact? = nil

    enum Destination: Hashable {
        /// A brand-new spending address, never revealed, used or handed out.
        case fresh
        /// One of your addresses, picked from the list: the chatting address or a spending one.
        case chosen
    }

    @EnvironmentObject private var walletManager: WalletManager
    @Environment(\.dismiss) private var dismiss
    @StateObject private var fiatAmountState = KaspaFiatAmountState()

    @State private var destination: Destination = .fresh
    /// The brand-new address reserved for this request (`reserveFreshSpendingAddresses`) - only
    /// when it's copied, shared or sent, so opening the screen and cancelling uses none up. Once
    /// per screen: Copy, Share and Send all reuse it, so no two requests share an address.
    @State private var freshAddress: String?
    @State private var chosenAddress: String?
    @State private var showAddressPicker = false
    @State private var amountInput = ""
    @State private var memo = ""
    @State private var copied = false
    @State private var isWorking = false
    @State private var sendError: String?
    @State private var shareItem: ShareURL?

    private struct ShareURL: Identifiable {
        let url: URL
        var id: String { url.absoluteString }
    }

    private var chattingAddress: String? { walletManager.currentWallet?.publicAddress }

    private var amountSompi: UInt64? {
        guard let sompi = KaspaUnit.sompi(fromUserText: amountInput), sompi > 0 else { return nil }
        return sompi
    }

    /// Ready to hand out: an amount, and an address (or a fresh one to be made).
    private var canMake: Bool {
        amountSompi != nil && (destination == .fresh || chosenAddress != nil)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            destinationPill("Fresh Address", selected: destination == .fresh) {
                                destination = .fresh
                            }
                            destinationPill("Choose an Address", selected: destination == .chosen) {
                                destination = .chosen
                                showAddressPicker = true
                            }
                        }

                        switch destination {
                        case .fresh:
                            if let freshAddress {
                                AddressResolutionCard(address: freshAddress)
                            }
                            Text("Paid to a brand-new address of yours, never used before and used for this request only. It's made when you copy, share or send the request. The memo shows to whoever pays, but doesn't travel with the payment.")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        case .chosen:
                            if let chosenAddress {
                                AddressResolutionCard(address: chosenAddress)
                                Text(chosenAddress == chattingAddress
                                     ? "The payment lands in your chat with whoever pays, with the memo."
                                     : "The memo shows to whoever pays, but doesn't travel with the payment.")
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                            } else {
                                Text("Pick which of your addresses gets paid.")
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }

                    KaspaAmountEntry(
                        fiatAmountState: fiatAmountState,
                        onAmountChange: { amountInput = $0 },
                        showsMax: false,
                        focusOnAppear: true,
                        onMax: {}
                    )
                    .padding(.top, 8)

                    VStack(alignment: .trailing, spacing: 6) {
                        TextField("What it's for (optional)", text: $memo, axis: .vertical)
                            .lineLimit(1...4)
                            .padding(14)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(.regularMaterial)
                            )
                            .onChange(of: memo) { value in
                                if value.count > PaymentRequest.memoLimit {
                                    memo = String(value.prefix(PaymentRequest.memoLimit))
                                }
                            }
                        Text(verbatim: "\(memo.count)/\(PaymentRequest.memoLimit)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    if let sendError {
                        Text(sendError)
                            .font(.footnote)
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                    }

                    if let recipient {
                        SendActionButton(
                            title: "Send Payment Request",
                            isBusy: isWorking,
                            isEnabled: canMake && !isWorking,
                            requiresSlide: false
                        ) {
                            send(to: recipient)
                        }
                    } else {
                        SendActionButton(
                            title: copied ? "Copied" : "Copy Payment Request",
                            isBusy: isWorking,
                            isEnabled: canMake && !isWorking,
                            requiresSlide: false,
                            action: copy
                        )

                        Button(action: share) {
                            Label("Share", systemImage: "square.and.arrow.up")
                                .font(.subheadline.weight(.semibold))
                        }
                        .disabled(!canMake || isWorking)
                    }

                    Text("Anyone who opens or pastes it in KaChat gets Send Kaspa with this filled in, and sees it was made by your chatting address (signed with its key).")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Request Payment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onChange(of: amountInput) { _ in copied = false }
            .onChange(of: memo) { _ in copied = false }
            .onChange(of: destination) { _ in copied = false }
            .onChange(of: chosenAddress) { _ in copied = false }
            .sheet(isPresented: $showAddressPicker) {
                PaymentRequestAddressPicker(selected: chosenAddress) { address in
                    chosenAddress = address
                }
            }
            .sheet(item: $shareItem) { item in
                PaymentRequestShareSheet(url: item.url)
            }
        }
    }

    /// A pill like the amount's currency switch: the chosen one filled in.
    private func destinationPill(_ title: LocalizedStringKey, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.impact(.light)
            action()
        } label: {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(selected ? .black : .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .padding(.horizontal, 6)
                .background(
                    Capsule().fill(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.regularMaterial))
                )
                .overlay(Capsule().stroke(Color.accentColor.opacity(selected ? 0 : 0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The request to hand out, signed by your chatting address (whoever pays sees it's from you,
    /// even when it's paid to a spending address, which has no identity). A fresh address is
    /// reserved here, the first time it's needed.
    private func makeRequest() async -> PaymentRequest? {
        guard let sompi = amountSompi else { return nil }
        let address: String
        switch destination {
        case .fresh:
            if let freshAddress {
                address = freshAddress
            } else {
                guard let reserved = await walletManager.reserveFreshSpendingAddresses(count: 1).first?.address else {
                    sendError = AppLocalization.string("Couldn't make a new address. Please try again.")
                    return nil
                }
                freshAddress = reserved
                address = reserved
                // watched from now on, so its payment shows the moment it lands
                ChatService.shared.checkAndResubscribeIfNeeded()
            }
        case .chosen:
            guard let chosenAddress else { return nil }
            address = chosenAddress
        }
        let unsigned = PaymentRequest(address: address, amountSompi: sompi, memo: memo,
                                      toChattingAddress: address == chattingAddress)
        // an account whose key isn't on this phone can still ask; the payer is told it's unsigned
        guard let creator = chattingAddress, let key = WalletManager.shared.getPrivateKey() else { return unsigned }
        return unsigned.signed(by: creator, privateKey: key) ?? unsigned
    }

    /// Sends the request into the chat as a message: it shows there as a Payment Request card,
    /// which they tap to pay.
    private func send(to contact: Contact) {
        isWorking = true
        sendError = nil
        Task {
            guard let request = await makeRequest() else { isWorking = false; return }
            do {
                try await ChatService.shared.sendMessage(to: contact, content: request.shareURLString, feeOverride: nil)
                Haptics.success()
                dismiss()
            } catch {
                isWorking = false
                sendError = UserFacingError.message(for: error)
            }
        }
    }

    private func copy() {
        isWorking = true
        sendError = nil
        Task {
            defer { isWorking = false }
            guard let request = await makeRequest() else { return }
            UIPasteboard.general.string = request.shareURLString
            Haptics.success()
            copied = true
        }
    }

    private func share() {
        isWorking = true
        sendError = nil
        Task {
            defer { isWorking = false }
            guard let request = await makeRequest(), let url = URL(string: request.shareURLString) else { return }
            shareItem = ShareURL(url: url)
        }
    }
}

/// Choose an Address: which of your addresses a payment request asks to be paid to - your
/// chatting address, then your spending addresses (the ones Manage Addresses shows, plus hidden
/// ones holding Kaspa), each with its name, balance and whether it was ever used (the same check
/// as Manage Addresses: a balance means used, else the cached answer, else a history lookup).
struct PaymentRequestAddressPicker: View {
    let selected: String?
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [SpendingAddressEntry]?
    /// Used / unused per address; missing while its lookup is out (or failed: "Checking", never
    /// a possibly-wrong "Unused").
    @State private var used: [String: Bool] = [:]

    var body: some View {
        NavigationStack {
            List {
                if let chatting = WalletManager.shared.currentWallet {
                    Section("Chatting Address") {
                        row(title: AppLocalization.string("Chatting Address"), address: chatting.publicAddress,
                            balance: chatting.balanceSompi, badge: nil)
                    }
                }
                Section("Spending Addresses") {
                    if let entries {
                        ForEach(entries) { entry in
                            row(title: entry.displayLabel, address: entry.address, balance: entry.balanceSompi,
                                badge: entry.isCurrent ? AppLocalization.string("Primary") : nil)
                        }
                    } else {
                        HStack { Spacer(); ProgressView(); Spacer() }
                    }
                }
            }
            .navigationTitle("Choose an Address")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task {
            let all = await WalletManager.shared.getSpendingAddressList()
            let shown = all
                .filter { !$0.hidden || $0.balanceSompi > 0 }
                .sorted { $0.index < $1.index }
            entries = shown
            await checkUsed(shown)
        }
    }

    private func checkUsed(_ shown: [SpendingAddressEntry]) async {
        let chat = ChatService.shared
        var all: [(address: String, balance: UInt64)] = shown.map { ($0.address, $0.balanceSompi) }
        if let wallet = WalletManager.shared.currentWallet {
            all.insert((wallet.publicAddress, wallet.balanceSompi ?? 0), at: 0)
        }
        var toProbe: [String] = []
        for item in all {
            if item.balance > 0 {
                used[item.address] = true
            } else if let cached = chat.cachedSpendingAddressUsedState(item.address) {
                used[item.address] = cached
            } else {
                toProbe.append(item.address)
            }
        }
        // a few at a time, like Manage Addresses (a burst gets rate-limited)
        var pending = toProbe.makeIterator()
        await withTaskGroup(of: (String, Bool?).self) { group in
            for _ in 0..<8 {
                guard let address = pending.next() else { break }
                group.addTask { (address, await chat.spendingAddressUsedState(address)) }
            }
            while let (address, answer) = await group.next() {
                if let answer { used[address] = answer }
                if let next = pending.next() {
                    group.addTask { (next, await chat.spendingAddressUsedState(next)) }
                }
            }
        }
    }

    @ViewBuilder
    private func usedTag(_ address: String) -> some View {
        switch used[address] {
        case true?:
            Text("Used")
                .font(.caption2.weight(.bold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.secondary.opacity(0.15)))
        case false?:
            Text("Unused")
                .font(.caption2.weight(.bold))
                .foregroundColor(.green)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.green.opacity(0.15)))
        case nil:
            Text("Checking")
                .font(.caption2.weight(.semibold))
                .foregroundColor(.secondary)
        }
    }

    private func row(title: String, address: String, balance: UInt64?, badge: String?) -> some View {
        Button {
            onPick(address)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(verbatim: title)
                            .font(.subheadline.weight(.semibold))
                        usedTag(address)
                        if let badge {
                            Text(verbatim: badge)
                                .font(.caption2.weight(.bold))
                                .foregroundColor(.accentColor)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                        }
                    }
                    Text(verbatim: "\(address.prefix(14))...\(address.suffix(6))")
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                }
                Spacer()
                if let balance {
                    Text(verbatim: "\(KaspaUnit.plain(balance)) \(KaspaUnit.symbol)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundColor(balance > 0 ? .primary : .secondary)
                }
                if address == selected {
                    Image(systemName: "checkmark")
                        .foregroundColor(.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct PaymentRequestShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Paying one

/// A text view where pasting someone's payment request opens Send Kaspa (the KaPosts composer;
/// the chat composers' `ComposerUITextView` does the same).
final class PaymentRequestAwareTextView: UITextView {
    override func paste(_ sender: Any?) {
        if PaymentRequestPaste.openIfRequest(UIPasteboard.general.string) { return }
        super.paste(sender)
    }
}

/// Pasting a payment request anywhere in KaChat opens Send Kaspa with it. Only text that is the
/// link and nothing else, and only someone else's request: your own pastes as text, so you can
/// send it to the person who should pay.
enum PaymentRequestPaste {
    @MainActor
    static func openIfRequest(_ text: String?) -> Bool {
        guard let text, let match = KaChatInternalLink.match(in: text), match.coversWholeMessage,
              case .paymentRequest(let request) = match.link, !request.isOwn else { return false }
        KaChatLinkRouter.openPaymentRequest(request)
        return true
    }
}

/// What a payment request asks for, above the amount on Send Kaspa.
struct PaymentRequestSummary: View {
    let request: PaymentRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Requested")
                .font(.caption.weight(.semibold))
                .foregroundColor(.accentColor)
                .textCase(.uppercase)
            Text(verbatim: "\(request.amountText) \(KaspaUnit.symbol)")
                .font(.headline)
            if !request.memo.isEmpty {
                Text(verbatim: request.memo)
                    .font(.subheadline)
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(request.toChattingAddress
                 ? "Paid as a chat payment: it shows in your chat with them."
                 : "Paid to their spending address.")
                .font(.caption)
                .foregroundColor(.secondary)

            Divider().padding(.vertical, 4)

            if let creator = request.creator {
                // Who made it - checked against the signature in the link when it was opened.
                Label("Requested by", systemImage: "checkmark.seal.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.green)
                AddressResolutionCard(address: creator)
                if creator.lowercased() != request.address.lowercased() {
                    Text("Signed by their chatting address. The payment goes to the address above.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else {
                Label("Not signed: who made this request can't be confirmed.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
        )
    }
}

/// One of your own payment requests, tapped in a chat: what it asks for and where it pays into,
/// with its link to copy or share again. Nothing to pay - it's yours.
struct OwnPaymentRequestView: View {
    let request: PaymentRequest
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    VStack(spacing: 6) {
                        Text(verbatim: "\(request.amountText) \(KaspaUnit.symbol)")
                            .font(.system(size: 40, weight: .bold, design: .rounded))
                            .multilineTextAlignment(.center)
                        if !request.memo.isEmpty {
                            Text(verbatim: request.memo)
                                .font(.body)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.top, 8)

                    VStack(alignment: .leading, spacing: 8) {
                        Text(request.toChattingAddress ? "Paid to your chatting address" : "Paid to your spending address")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.accentColor)
                            .textCase(.uppercase)
                        AddressResolutionCard(address: request.address)
                        Text(request.toChattingAddress
                             ? "The payment lands in your chat with whoever pays, with the memo."
                             : "Paid to a brand-new address of yours, used for this request only. The memo shows to whoever pays, but doesn't travel with the payment.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }

                    SendActionButton(
                        title: copied ? "Copied" : "Copy Payment Request",
                        isBusy: false,
                        isEnabled: true,
                        requiresSlide: false
                    ) {
                        UIPasteboard.general.string = request.shareURLString
                        Haptics.success()
                        copied = true
                    }

                    if let url = URL(string: request.shareURLString) {
                        ShareLink(item: url) {
                            Label("Share", systemImage: "square.and.arrow.up")
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
            .navigationTitle("Your Payment Request")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }
}

/// Presents Send Kaspa for the payment request waiting in `PaymentRequestRouter` - a tapped
/// request card, a pasted link, a link opened from outside the app.
struct PaymentRequestSheetPresenter: ViewModifier {
    @ObservedObject private var router = PaymentRequestRouter.shared
    @EnvironmentObject private var settingsViewModel: SettingsViewModel

    func body(content: Content) -> some View {
        content
            .sheet(item: $router.pending) { request in
                if request.isOwn {
                    OwnPaymentRequestView(request: request)
                        .environmentObject(settingsViewModel)
                } else if let wallet = WalletManager.shared.currentWallet {
                    WithdrawKaspaView(
                        fromAddress: wallet.publicAddress,
                        availableBalanceSompi: wallet.balanceSompi,
                        paymentRequest: request
                    )
                    .environmentObject(ChatService.shared)
                    .environmentObject(ContactsManager.shared)
                    .environmentObject(WalletManager.shared)
                    .environmentObject(settingsViewModel)
                }
            }
    }
}
