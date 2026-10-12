import SwiftUI
import UIKit

// MARK: - Request Payment (Chats > + > Request Payment)

/// Makes a payment request link: to your chatting or spending address, an exact amount and what
/// it's for. Copy (or share) the link and send it anywhere; in KaChat it opens Send Kaspa filled
/// in (`PaymentRequest`, `KaChatInternalLink.paymentRequest`).
struct CreatePaymentRequestView: View {
    enum Destination: Hashable {
        case chatting, spending
    }

    @EnvironmentObject private var walletManager: WalletManager
    @Environment(\.dismiss) private var dismiss
    @StateObject private var fiatAmountState = KaspaFiatAmountState()

    @State private var destination: Destination = .chatting
    /// A fresh receive address of the spending chain, as Receive Kaspa shows.
    @State private var spendingAddress: String? = ReceiveAddressWarmCache.address
    @State private var amountInput = ""
    @State private var memo = ""
    @State private var copied = false

    private var address: String? {
        switch destination {
        case .chatting: return walletManager.currentWallet?.publicAddress
        case .spending: return spendingAddress
        }
    }

    private var request: PaymentRequest? {
        guard let address, let sompi = KaspaUnit.sompi(fromUserText: amountInput), sompi > 0 else { return nil }
        return PaymentRequest(address: address, amountSompi: sompi, memo: memo, toChattingAddress: destination == .chatting)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Paid to", selection: $destination) {
                            Text("Chatting Address").tag(Destination.chatting)
                            Text("Spending Address").tag(Destination.spending)
                        }
                        .pickerStyle(.segmented)

                        if let address {
                            AddressResolutionCard(address: address)
                        } else {
                            HStack { Spacer(); ProgressView(); Spacer() }
                                .padding(.vertical, 18)
                        }

                        Text(destination == .chatting
                             ? "The payment lands in your chat with whoever pays, with the memo."
                             : "Paid to a fresh address of yours. The memo shows to whoever pays, but doesn't travel with the payment.")
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

                    Text("Anyone who opens or pastes it in KaChat gets Send Kaspa with this filled in.")
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
            .task {
                if let fresh = await walletManager.freshReceiveAddress() {
                    spendingAddress = fresh
                    ReceiveAddressWarmCache.address = fresh
                }
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
        )
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
                if let wallet = WalletManager.shared.currentWallet {
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
