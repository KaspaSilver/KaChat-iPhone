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
        case chatting, spending
    }

    @EnvironmentObject private var walletManager: WalletManager
    @Environment(\.dismiss) private var dismiss
    @StateObject private var fiatAmountState = KaspaFiatAmountState()

    @State private var destination: Destination = .chatting
    /// A spending address that has never been revealed, used or handed out - reserved for this
    /// request when Spending Address is picked (once per screen: Copy, Share and Send all reuse
    /// it), so no two requests ever share an address and a payment can't mix with another.
    @State private var spendingAddress: String?
    @State private var reservingSpending = false
    @State private var amountInput = ""
    @State private var memo = ""
    @State private var copied = false
    @State private var isSending = false
    @State private var sendError: String?

    private var address: String? {
        switch destination {
        case .chatting: return walletManager.currentWallet?.publicAddress
        case .spending: return spendingAddress
        }
    }

    /// The request, signed by your chatting address: whoever pays sees it is from you - your
    /// name and picture - even when it asks to be paid to a spending address, which has none.
    private var request: PaymentRequest? {
        guard let address, let sompi = KaspaUnit.sompi(fromUserText: amountInput), sompi > 0 else { return nil }
        let unsigned = PaymentRequest(address: address, amountSompi: sompi, memo: memo, toChattingAddress: destination == .chatting)
        // an account whose key isn't on this phone can still ask; the payer is told it's unsigned
        guard let creator = walletManager.currentWallet?.publicAddress,
              let key = WalletManager.shared.getPrivateKey() else { return unsigned }
        return unsigned.signed(by: creator, privateKey: key) ?? unsigned
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            destinationPill("Chatting Address", .chatting)
                            destinationPill("Spending Address", .spending)
                        }

                        if let address {
                            AddressResolutionCard(address: address)
                        } else {
                            HStack { Spacer(); ProgressView(); Spacer() }
                                .padding(.vertical, 18)
                        }

                        Text(destination == .chatting
                             ? "The payment lands in your chat with whoever pays, with the memo."
                             : "Paid to a brand-new address of yours, used for this request only. The memo shows to whoever pays, but doesn't travel with the payment.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
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

                    if let recipient {
                        if let sendError {
                            Text(sendError)
                                .font(.footnote)
                                .foregroundColor(.red)
                                .multilineTextAlignment(.center)
                        }
                        SendActionButton(
                            title: "Send Payment Request",
                            isBusy: isSending,
                            isEnabled: request != nil && !isSending,
                            requiresSlide: false
                        ) {
                            send(to: recipient)
                        }
                    } else {
                        SendActionButton(
                            title: copied ? "Copied" : "Copy Payment Request",
                            isBusy: false,
                            isEnabled: request != nil,
                            requiresSlide: false,
                            action: copy
                        )

                        if let request, let url = URL(string: request.shareURLString) {
                            ShareLink(item: url) {
                                Label("Share", systemImage: "square.and.arrow.up")
                                    .font(.subheadline.weight(.semibold))
                            }
                        }
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
            .onChange(of: request) { _ in copied = false }
            .onChange(of: destination) { picked in
                if picked == .spending { reserveSpendingAddress() }
            }
        }
    }

    /// A pill like the amount's currency switch: the chosen one filled in.
    private func destinationPill(_ title: LocalizedStringKey, _ value: Destination) -> some View {
        let selected = destination == value
        return Button {
            Haptics.impact(.light)
            destination = value
        } label: {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(selected ? .black : .primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    Capsule().fill(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.regularMaterial))
                )
                .overlay(Capsule().stroke(Color.accentColor.opacity(selected ? 0 : 0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func reserveSpendingAddress() {
        guard spendingAddress == nil, !reservingSpending else { return }
        reservingSpending = true
        Task {
            spendingAddress = await walletManager.reserveFreshSpendingAddresses(count: 1).first?.address
            reservingSpending = false
            // watched from now on, so its payment shows the moment it lands
            ChatService.shared.checkAndResubscribeIfNeeded()
        }
    }

    /// Sends the request into the chat as a message: it shows there as a Payment Request card,
    /// which they tap to pay.
    private func send(to contact: Contact) {
        guard let request else { return }
        isSending = true
        sendError = nil
        Task {
            do {
                try await ChatService.shared.sendMessage(to: contact, content: request.shareURLString, feeOverride: nil)
                Haptics.success()
                dismiss()
            } catch {
                isSending = false
                sendError = UserFacingError.message(for: error)
            }
        }
    }

    private func copy() {
        guard let request else { return }
        UIPasteboard.general.string = request.shareURLString
        Haptics.success()
        copied = true
    }
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
