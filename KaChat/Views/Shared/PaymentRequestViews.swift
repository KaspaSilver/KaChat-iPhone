import SwiftUI
import UIKit

// MARK: - Request Payment (Profile > the send / receive button > Request Payment)

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
    /// The next brand-new address, shown before it's reserved: the one `reserveFreshSpendingAddresses`
    /// hands out next (the slot after the last revealed one).
    @State private var nextFreshAddress: String?
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
                            SelectablePill(title: "Fresh Address", selected: destination == .fresh) {
                                destination = .fresh
                            }
                            SelectablePill(title: "Choose an Address", selected: destination == .chosen) {
                                destination = .chosen
                                showAddressPicker = true
                            }
                        }

                        switch destination {
                        case .fresh:
                            if let address = freshAddress ?? nextFreshAddress {
                                AddressResolutionCard(address: address)
                            } else {
                                HStack { Spacer(); ProgressView(); Spacer() }
                                    .padding(.vertical, 18)
                            }
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
            .task {
                // derived, not reserved: opening the screen and cancelling uses no address up.
                // The fresh slot is quantum-safe (KIP-22) now, matching what reserving returns.
                // Checked on chain (IOS-101), so the preview never shows a slot already used.
                // Slot and address from the same account (IOS-109).
                nextFreshAddress = await WalletManager.shared.verifiedFreshQuantumSlot()?.address
            }
            .sheet(isPresented: $showAddressPicker) {
                OwnAddressPicker(title: "Choose an Address", selected: chosenAddress) { picked in
                    chosenAddress = picked.address
                }
            }
            .sheet(item: $shareItem) { item in
                PaymentRequestShareSheet(url: item.url)
            }
        }
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
