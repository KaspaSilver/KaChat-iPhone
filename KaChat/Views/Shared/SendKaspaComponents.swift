import SwiftUI
import UIKit

// The pieces every Send Kaspa screen is built from, so they look and behave the same: the 1:1
// chat's Send KAS sheet, Profile's Send Kaspa, a spending address's Send, and KasSigner's send.
// Recipient on top (paste, scan a QR, names resolve), then the big amount (KAS or your currency,
// Max), the fee and balance, the fee speed and coin control, and a slide-to-send button.

/// The frosted card the Send Kaspa pieces sit on.
func sendKaspaGlass(cornerRadius: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .fill(.regularMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
        )
}

// MARK: - Recipient

/// Who the Kaspa goes to: an address or a name, with Paste and Scan QR beside the field and a
/// line saying what the input resolved to. The screen keeps its own lookup logic (it watches
/// `input`); this only shows it. With `lockedAddress` (Compound UTXOs) the recipient is fixed.
struct SendRecipientCard: View {
    @Binding var input: String
    var lockedAddress: String? = nil
    let isResolving: Bool
    let resolvedAddress: String?
    let resolvedName: String?
    let lookupError: String?
    let isValidAddress: Bool
    let onScan: () -> Void
    /// Every service's answer for a typed name (`NameServicesClient.resolveEverywhere`, .kachat
    /// first) and the one in use: the rest are offered under "Other domains".
    var nameResolutions: [NameResolution] = []
    var selectedTLD: NameServiceTLD? = nil
    var onSelectResolution: (NameResolution) -> Void = { _ in }

    @ObservedObject private var addressBook = AddressBookManager.shared
    @State private var showAddressBook = false

    private var trimmed: String { input.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("To")
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
            if let lockedAddress {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.merge")
                        .foregroundColor(.accentColor)
                    Text(verbatim: lockedAddress)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text("Consolidating This Address")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                HStack(spacing: 14) {
                    TextField("kaspa:qr... or domain", text: $input)
                        .font(.system(.subheadline, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        if let pasted = UIPasteboard.general.string {
                            input = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                            .font(.body.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                    .accessibilityLabel(Text("Paste"))
                    Button(action: onScan) {
                        Image(systemName: "qrcode.viewfinder")
                            .font(.body.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                    .accessibilityLabel(Text("Scan QR"))
                    if !addressBook.entries.isEmpty {
                        Button {
                            showAddressBook = true
                        } label: {
                            Image(systemName: "book.closed")
                                .font(.body.weight(.semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.accentColor)
                        .accessibilityLabel(Text("Address Book"))
                    }
                }
                AddressResolutionCard(address: resolvedAddress ?? (isValidAddress ? trimmed : nil), domain: resolvedName)
                if let savedName = addressBook.entry(for: resolvedAddress ?? trimmed)?.customName {
                    Label(savedName, systemImage: "book.closed.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.accentColor)
                }
                if !trimmed.isEmpty {
                    statusLine
                    if !isResolving {
                        OtherDomainsDropdown(resolutions: nameResolutions, selected: selectedTLD, onSelect: onSelectResolution)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(sendKaspaGlass(cornerRadius: 20))
        .fullScreenCover(isPresented: $showAddressBook) {
            AddressBookPickerSheet { entry in input = entry.address }
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if isResolving {
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.8)
                Text("Looking up domain...")
            }
            .font(.caption)
            .foregroundColor(.secondary)
        } else if let lookupError {
            Label(lookupError, systemImage: "xmark.circle.fill")
                .font(.caption)
                .foregroundColor(.red)
        } else if let resolvedAddress {
            VStack(alignment: .leading, spacing: 2) {
                Label("Resolved: \(resolvedName ?? "")", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundColor(.green)
                Text(verbatim: resolvedAddress)
                    .font(.caption2.monospaced())
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } else {
            Label(KaspaAddress.validityText(trimmed, isValid: isValidAddress),
                  systemImage: isValidAddress ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.caption)
                .foregroundColor(isValidAddress ? .green : .red)
        }
    }
}

// MARK: - Other domains

/// "Other domains": what the same typed name points to on the other services, under the name it
/// resolved to, each selectable. Every field that takes an address shows it; the order is always
/// .kachat first (`NameServiceTLD.resolutionOrder`). Opens by itself when nothing was picked but
/// another service has the name.
struct OtherDomainsDropdown: View {
    let resolutions: [NameResolution]
    let selected: NameServiceTLD?
    let onSelect: (NameResolution) -> Void

    @State private var expanded = false

    private var others: [NameResolution] { resolutions.filter { $0.tld != selected } }

    var body: some View {
        if !others.isEmpty {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(others) { resolution in
                        Button {
                            onSelect(resolution)
                            expanded = false
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: resolution.display)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundColor(resolution.address == nil ? .secondary : .primary)
                                    Text(resolution.address ?? Self.missingText(resolution))
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer(minLength: 0)
                                if resolution.address != nil {
                                    Image(systemName: "arrow.right.circle")
                                        .foregroundColor(.accentColor)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(resolution.address == nil)
                    }
                }
                .padding(.top, 4)
            } label: {
                Text("Other domains")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.accentColor)
            }
            .tint(.accentColor)
            .onAppear { openIfNothingPicked() }
            .onChange(of: resolutions) { _ in openIfNothingPicked() }
        }
    }

    private func openIfNothingPicked() {
        if selected == nil, resolutions.contains(where: { $0.address != nil }) { expanded = true }
    }

    static func missingText(_ r: NameResolution) -> String {
        if r.notLive { return String(localized: "Coming soon") }
        return r.failed ? String(localized: "Couldn't check") : String(localized: "Not registered")
    }
}

// MARK: - Amount

/// The big centred amount and its unit, with the KAS / your-currency switch (showing the
/// converted value) and Max under it. Hands the screen the KAS amount text after every edit.
struct KaspaAmountEntry: View {
    @ObservedObject var fiatAmountState: KaspaFiatAmountState
    @ObservedObject private var priceModel = KasPriceModel.shared
    /// Receives the amount in KAS (as text) after each edit - what the screen stores.
    let onAmountChange: (String) -> Void
    /// Cleans what was typed before it's used: by default digits and one decimal point, with
    /// "," read as "." for comma-decimal keyboards, at most 8 decimals.
    var sanitize: (String) -> String = KaspaUnit.sanitizeAmountInput
    var isEstimatingMax = false
    var maxEnabled = true
    /// False leaves Max out (asking for an amount, not sending one: Request Payment).
    var showsMax = true
    /// Puts the cursor in the amount when the screen appears (the amount is the first thing to type).
    var focusOnAppear = false
    let onMax: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        let display = Self.grouped(fiatAmountState.displayText)
        let fontSize: CGFloat = display.count <= 7 ? 52 : (display.count <= 10 ? 40 : 30)
        let price = priceModel.currentPriceUsd
        VStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                TextField(
                    "0",
                    // Shown with thousands separators ("12,345.5", or "12 345.5" where "," is the decimal point); what the screen gets stays plain.
                    text: Binding(
                        get: { Self.grouped(fiatAmountState.displayText) },
                        set: { newValue in
                            let plain = Self.ungrouped(newValue, previous: Self.grouped(fiatAmountState.displayText))
                            onAmountChange(fiatAmountState.onDisplayTextChange(sanitize(plain), priceInCurrency: price))
                        }
                    )
                )
                .font(.system(size: fontSize, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)
                .keyboardType(.decimalPad)
                .fixedSize()
                .focused($isFocused)
                .accessibilityLabel(Text(KaspaUnit.label(AppLocalization.string("Amount (KAS)"))))

                Text(verbatim: fiatAmountState.isFiatMode ? priceModel.currentCurrency.code : KaspaUnit.symbol)
                    .font(.system(size: fontSize * 0.55, weight: .semibold, design: .rounded))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { isFocused = true }

            HStack(spacing: 10) {
                if price != nil {
                    Button {
                        fiatAmountState.toggleMode(priceInCurrency: price)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.up.arrow.down")
                                .font(.caption.weight(.semibold))
                            if let conversion = fiatAmountState.conversionLabelText(priceInCurrency: price, currency: priceModel.currentCurrency) {
                                Text(verbatim: conversion)
                            } else {
                                Text(verbatim: fiatAmountState.isFiatMode ? KaspaUnit.symbol : priceModel.currentCurrency.code)
                            }
                        }
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(sendKaspaGlass(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Switch between Kaspa and your currency"))
                }

                if showsMax {
                Button(action: onMax) {
                    Group {
                        if isEstimatingMax {
                            ProgressView().scaleEffect(0.7)
                        } else {
                            Text("Max")
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.accentColor)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(sendKaspaGlass(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .disabled(!maxEnabled || isEstimatingMax)
                .opacity(maxEnabled ? 1 : 0.5)
                }
            }
        }
        .onAppear {
            guard focusOnAppear else { return }
            // The field doesn't exist yet on the tap that presented the screen.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { isFocused = true }
        }
    }
}

extension KaspaAmountEntry {
    /// Where the device writes the decimal point as "," (de, fr, es, it, pt, ru, tr, id, vi...),
    /// a comma is ALWAYS the decimal point - "0,001" pasted from a chat is 0.001, never 1 (IOS-078) -
    /// and thousands show as a thin space ("2 500"), which no reader takes for a decimal.
    /// Elsewhere thousands show as "," ("12,345.5").
    static func usesCommaDecimal(_ locale: Locale = .current) -> Bool {
        locale.decimalSeparator == ","
    }

    static func groupingSeparator(_ locale: Locale = .current) -> String {
        usesCommaDecimal(locale) ? "\u{202F}" : ","
    }

    /// "12345.5" -> "12,345.5", or "12 345,5" where "," is the decimal point: a separator every
    /// three digits of the whole part, the decimal point the device's own (so the person sees the
    /// "," they typed and doesn't type it again - IOS-082), the rest as typed.
    static func grouped(_ plain: String, locale: Locale = .current) -> String {
        let parts = plain.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let point = usesCommaDecimal(locale) ? "," : "."
        guard let whole = parts.first, whole.allSatisfy({ $0.isASCII && $0.isNumber }) else { return plain }
        var out = ""
        if whole.count > 3 {
            let separator = groupingSeparator(locale)
            for (i, ch) in whole.enumerated() {
                if i > 0, (whole.count - i) % 3 == 0 { out.append(separator) }
                out.append(ch)
            }
        } else {
            out = String(whole)
        }
        return parts.count > 1 ? out + point + parts[1] : out
    }

    /// The edited field back to a plain number ("." the decimal point).
    /// - Comma-decimal device: the thin spaces shown are ours and go; the first "," is the
    ///   decimal point and any further one is dropped (a second tap on the key never moves the
    ///   point - IOS-082). A pasted "1.234,5" (dots as grouping, a comma decimal) is 1234.5.
    /// - Otherwise: the commas shown are ours and go; a comma TYPED as the decimal point stays one:
    ///   typed at the end, or a single comma not three digits from the end in a number that had no
    ///   grouping ("0,5" is 0.5), or after a lone leading zero ("0,001" is 0.001, as no grouped
    ///   number starts "0,").
    static func ungrouped(_ edited: String, previous: String, locale: Locale = .current) -> String {
        if usesCommaDecimal(locale) {
            var text = edited.replacingOccurrences(of: "\u{202F}", with: "")
                .replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "\u{00A0}", with: "")
            if text.contains(",") {
                // a comma is the decimal point; dots beside it can only be grouping
                text = text.replacingOccurrences(of: ".", with: "")
                if let first = text.firstIndex(of: ",") {
                    let head = text[..<first]
                    let tail = text[text.index(after: first)...].replacingOccurrences(of: ",", with: "")
                    text = String(head) + "." + tail
                }
            }
            return text
        }
        if edited == previous + "," {
            return previous.replacingOccurrences(of: ",", with: "") + "."
        }
        if !previous.contains(","), !edited.contains("."), edited.filter({ $0 == "," }).count == 1,
           let comma = edited.firstIndex(of: ","),
           edited[..<comma] == "0" || edited[..<comma].isEmpty
            || edited.distance(from: edited.index(after: comma), to: edited.endIndex) != 3 {
            return edited.replacingOccurrences(of: ",", with: ".")
        }
        return edited.replacingOccurrences(of: ",", with: "")
    }
}

extension Binding where Value == String {
    /// An amount field's text with thousands separators while shown ("12,345.5"), the plain number
    /// stored - the same rules as `KaspaAmountEntry`, for the amount fields that aren't one.
    var groupedAmount: Binding<String> {
        Binding(
            get: { KaspaAmountEntry.grouped(wrappedValue) },
            set: { wrappedValue = KaspaAmountEntry.ungrouped($0, previous: KaspaAmountEntry.grouped(wrappedValue)) }
        )
    }
}

// MARK: - Fee and coin control

/// Network fee (tap to set a custom one), the fee speed, and coin control - one card.
struct SendFeeControls: View {
    @Binding var feeTier: WithdrawFeeTier
    @Binding var isEditingFee: Bool
    @Binding var customFeeText: String
    let isEstimatingFee: Bool
    /// The fee as shown ("0.0001 KAS"), nil while unknown.
    let feeText: String?
    let onStartEditing: () -> Void
    let onCommit: () -> Void
    var showsCoinControl = true
    var coinControlSummary: String = ""
    var onCoinControl: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Network Fee")
                    .font(.subheadline)
                Spacer()
                if isEditingFee {
                    TextField("0.00", text: $customFeeText)
                        .keyboardType(.decimalPad)
                        .numericKeyboardDoneButton()
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 110)
                        .onSubmit(onCommit)
                    Button(action: onCommit) {
                        Image(systemName: "checkmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                } else if isEstimatingFee {
                    ProgressView().scaleEffect(0.75)
                } else if let feeText {
                    Button(action: onStartEditing) {
                        HStack(spacing: 4) {
                            Text(verbatim: feeText).underline()
                            Image(systemName: "pencil").font(.caption2)
                        }
                        .font(.subheadline)
                        .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(verbatim: "—").foregroundColor(.secondary)
                }
            }
            Picker("Fee", selection: $feeTier) {
                ForEach(WithdrawFeeTier.allCases) { tier in
                    Text(LocalizedStringKey(tier.rawValue)).tag(tier)
                }
            }
            .pickerStyle(.segmented)
            Text("If the network is busy, Fast or Priority pays a higher fee to help this confirm sooner. Tap the fee amount to set a custom fee.")
                .font(.caption)
                .foregroundColor(.secondary)

            if showsCoinControl {
                Divider()
                Button(action: onCoinControl) {
                    HStack {
                        Text("Coin Control")
                            .font(.subheadline)
                            .foregroundColor(.primary)
                        Spacer()
                        Text(verbatim: coinControlSummary)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(sendKaspaGlass(cornerRadius: 20))
    }
}

/// "Automatic" or "3 UTXOs selected", for the coin control row.
func coinControlSummary(_ manualUtxos: [UTXO]?) -> String {
    guard let manualUtxos else { return AppLocalization.string("Automatic") }
    return "\(manualUtxos.count) UTXO\(manualUtxos.count == 1 ? "" : "s") selected"
}

/// A small glass capsule for one line of context (available balance, fee).
struct SendInfoPill<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .font(.caption)
            .foregroundColor(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(sendKaspaGlass(cornerRadius: 14))
    }
}

// MARK: - Send button

/// The send button: slide the knob to the right end to send, so a payment can't go out on a
/// stray touch. Letting go before the end springs it back; after a send that didn't go through
/// (an error, the small-amount question) it resets by itself. VoiceOver gets a plain activate
/// action. With `requiresSlide: false` it's an ordinary tap in the same look (KasSigner's "Build
/// Unsigned Transaction", which moves nothing by itself).
struct SendActionButton: View {
    let title: LocalizedStringKey
    let isBusy: Bool
    let isEnabled: Bool
    var requiresSlide = true
    let action: () -> Void

    @State private var offset: CGFloat = 0
    @State private var reachedEnd = false
    private let height: CGFloat = 56
    private let inset: CGFloat = 4

    private var active: Bool { isEnabled && !isBusy }

    var body: some View {
        Group {
            if requiresSlide {
                slider
            } else {
                track(progress: 0)
                    .overlay {
                        label.frame(maxWidth: .infinity)
                    }
                    .onTapGesture {
                        guard active else { return }
                        action()
                    }
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            guard active else { return }
            action()
        }
        .onChange(of: isBusy) { busy in
            if !busy { reset() }
        }
    }

    private var slider: some View {
        GeometryReader { geometry in
            let knob = height - inset * 2
            let maxOffset = max(1, geometry.size.width - knob - inset * 2)
            let progress = min(1, offset / maxOffset)
            ZStack(alignment: .leading) {
                track(progress: progress, knob: knob)
                label
                    .opacity(isBusy ? 1 : Double(1 - progress))
                    .frame(maxWidth: .infinity)
                if !isBusy {
                    Circle()
                        .fill(Color.white)
                        .frame(width: knob, height: knob)
                        .overlay(
                            Image(systemName: "chevron.right.2")
                                .font(.headline.weight(.bold))
                                .foregroundColor(Color.accentColor)
                        )
                        .shadow(color: Color.black.opacity(0.15), radius: 4, x: 0, y: 2)
                        .offset(x: inset + offset)
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    guard active else { return }
                                    if offset == 0 && value.translation.width > 0 { Haptics.impact(.light) }
                                    offset = min(max(0, value.translation.width), maxOffset)
                                    if offset >= maxOffset && !reachedEnd {
                                        reachedEnd = true
                                        Haptics.impact(.medium)
                                    } else if offset < maxOffset {
                                        reachedEnd = false
                                    }
                                }
                                .onEnded { _ in
                                    guard active else { return }
                                    if offset >= maxOffset * 0.95 {
                                        offset = maxOffset
                                        action()
                                        // A send that didn't start (dust question, a validation
                                        // error) leaves it not busy: put the knob back.
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                                            if !isBusy { reset() }
                                        }
                                    } else {
                                        reset()
                                    }
                                }
                        )
                }
            }
        }
    }

    private func track(progress: CGFloat, knob: CGFloat = 0) -> some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.accentColor.opacity(isEnabled || isBusy ? 1 : 0.4))
            if knob > 0 {
                Capsule()
                    .fill(Color.white.opacity(0.25))
                    .frame(width: inset * 2 + knob + offset)
            }
        }
    }

    private var label: some View {
        HStack(spacing: 8) {
            if isBusy {
                ProgressView().tint(.black)
            } else {
                Text(title).font(.headline)
            }
        }
        .foregroundColor(.black)
    }

    private func reset() {
        reachedEnd = false
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { offset = 0 }
    }
}

// MARK: - From (which of your addresses a send comes out of)

/// Where a send comes from: the chatting address (every send screen's default), or one of the
/// spending addresses picked under Choose an Address.
enum SendSource: Equatable, Hashable {
    case chatting
    case spending(index: Int, address: String, label: String)

    var spendingIndex: Int? {
        if case .spending(let index, _, _) = self { return index }
        return nil
    }

    @MainActor
    var address: String? {
        switch self {
        case .chatting: return WalletManager.shared.currentWallet?.publicAddress
        case .spending(_, let address, _): return address
        }
    }
}

/// A pill to pick one of a few choices, like the amount's currency switch: the chosen one
/// filled in teal. Send screens' From, Request Payment's address.
struct SelectablePill: View {
    let title: LocalizedStringKey
    let selected: Bool
    let action: () -> Void

    var body: some View {
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
}

/// The From section every send screen starts with, so it is always plain which address the
/// Kaspa leaves from: Chatting Address (the default) or Choose an Address (any of your
/// addresses, each marked used or unused), and the chosen address with its balance.
struct SendFromSection: View {
    @Binding var source: SendSource
    /// The chosen address's balance, loaded here (nil while it loads) - the screen's Available.
    @Binding var availableSompi: UInt64?
    /// Opened from one address's own page (its history's Send): that address only, no choice.
    var isLocked: Bool = false
    @State private var showPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("From")
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
            if !isLocked {
                HStack(spacing: 10) {
                    SelectablePill(title: "Chatting Address", selected: source == .chatting) {
                        source = .chatting
                    }
                    SelectablePill(title: "Choose an Address", selected: source != .chatting) {
                        showPicker = true
                    }
                }
            }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: title)
                        .font(.subheadline.weight(.semibold))
                    if let address = source.address {
                        Text(verbatim: "\(address.prefix(14))...\(address.suffix(6))")
                            .font(.caption.monospaced())
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                if let availableSompi {
                    Text(verbatim: "\(KaspaUnit.plain(availableSompi)) \(KaspaUnit.symbol)")
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(12)
            .background(sendKaspaGlass(cornerRadius: 14))
        }
        .sheet(isPresented: $showPicker) {
            OwnAddressPicker(title: "Send From", selected: source.address) { picked in
                source = picked
            }
        }
        .task(id: source) {
            availableSompi = nil
            guard let address = source.address else { return }
            let utxos = (try? await NodePoolService.shared.getUtxosByAddresses([address])) ?? []
            guard !Task.isCancelled else { return }
            availableSompi = utxos.reduce(UInt64(0)) { $0 + $1.amount }
        }
    }

    private var title: String {
        switch source {
        case .chatting: return AppLocalization.string("Chatting Address")
        case .spending(_, _, let label): return label
        }
    }
}

/// Your addresses to pick from - the chatting address, then the spending addresses (the ones
/// Manage Addresses shows, plus hidden ones holding Kaspa) - each with its name, balance and
/// whether it was ever used (a balance means used, else the cached answer, else a history
/// lookup, eight at a time; "Checking" until answered, never a possibly-wrong "Unused").
/// A send's Choose an Address, and Request Payment's.
struct OwnAddressPicker: View {
    let title: LocalizedStringKey
    let selected: String?
    /// The .kachat market signs its funding inputs as plain P2PK, which a quantum-safe (KIP-22)
    /// address can't be - its picker leaves them out.
    var excludeQuantum: Bool = false
    let onPick: (SendSource) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [SpendingAddressEntry]?
    @State private var used: [String: Bool] = [:]

    var body: some View {
        NavigationStack {
            List {
                if let chatting = WalletManager.shared.currentWallet {
                    Section("Chatting Address") {
                        row(title: AppLocalization.string("Chatting Address"), address: chatting.publicAddress,
                            balance: chatting.balanceSompi) { .chatting }
                    }
                }
                Section("Spending Addresses") {
                    if let entries {
                        ForEach(entries) { entry in
                            row(title: entry.displayLabel, address: entry.address, balance: entry.balanceSompi) {
                                .spending(index: entry.index, address: entry.address, label: entry.displayLabel)
                            }
                        }
                    } else {
                        HStack { Spacer(); ProgressView(); Spacer() }
                    }
                }
            }
            .navigationTitle(title)
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
                .filter { !excludeQuantum || !$0.isQuantum }
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

    private func row(title: String, address: String, balance: UInt64?, source: @escaping () -> SendSource) -> some View {
        Button {
            onPick(source())
            dismiss()
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(verbatim: title)
                            .font(.subheadline.weight(.semibold))
                        usedTag(address)
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

// MARK: - Coin Control

/// Coin control — lets the user fix the exact UTXO set a send spends from instead of the
/// automatic largest-first selector. Reachable from a send form's "Coin Control" row (moved here
/// from Cold Storage on 2026-10-24; it fetches via the generic
/// `NodePoolService.shared.getUtxosByAddresses`, keyed only by `fromAddress`).
/// Passes the selection back as a plain `[UTXO]?` (nil = automatic) rather than owning any state
/// itself, since the actual spendable set needs re-resolving against a fresh fetch at build time
/// anyway.
struct CoinControlView: View {
    let fromAddress: String
    let initialSelection: [UTXO]?
    let onDone: ([UTXO]?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var utxos: [UTXO] = []
    @State private var selectedKeys: Set<String> = []
    @State private var isLoading = false
    /// The node could not be asked. Shown in place of "no coins": an outage must never read as
    /// an empty address when the coins here are about to be spent.
    @State private var loadError: String?
    @State private var utxoLabels: [String: String] = [:]

    private func loadUtxos() async {
        isLoading = true
        do {
            utxos = try await NodePoolService.shared.getUtxosByAddresses([fromAddress])
            loadError = nil
        } catch {
            loadError = UserFacingError.message(for: error)
        }
        isLoading = false
    }

    private func key(_ utxo: UTXO) -> String {
        "\(utxo.outpoint.transactionId):\(utxo.outpoint.index)"
    }

    private var selectedTotalSompi: UInt64 {
        utxos.filter { selectedKeys.contains(key($0)) }.reduce(0) { $0 + $1.amount }
    }

    var body: some View {
        NavigationStack {
            List {
                if isLoading && utxos.isEmpty {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                } else if utxos.isEmpty {
                    if let loadError {
                        UtxoLoadFailureRow(detail: loadError) {
                            Task { await loadUtxos() }
                        }
                    } else {
                        Text("No UTXOs found at this address.")
                            .foregroundColor(.secondary)
                    }
                } else {
                    Section {
                        ForEach(Array(utxos.enumerated()), id: \.offset) { _, utxo in
                            let k = key(utxo)
                            let isSelected = selectedKeys.contains(k)
                            Button {
                                if isSelected {
                                    selectedKeys.remove(k)
                                } else {
                                    selectedKeys.insert(k)
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                        .foregroundColor(isSelected ? .accentColor : .secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        if let label = utxoLabels[k], !label.isEmpty {
                                            Text(label)
                                                .font(.caption)
                                                .fontWeight(.bold)
                                                .foregroundColor(.accentColor)
                                        }
                                        Text(verbatim: "\(formatKas(utxo.amount)) \(KaspaUnit.symbol)")
                                            .font(.subheadline)
                                            .fontWeight(.semibold)
                                            .foregroundColor(.primary)
                                        Text("\(utxo.outpoint.transactionId.prefix(10))...:\(utxo.outpoint.index)")
                                            .font(.system(.caption2, design: .monospaced))
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    } footer: {
                        if !selectedKeys.isEmpty {
                            Text(verbatim: "Selected: \(formatKas(selectedTotalSompi)) \(KaspaUnit.symbol) (\(selectedKeys.count) UTXO\(selectedKeys.count == 1 ? "" : "s"))")
                        }
                    }
                }
            }
            .navigationTitle("Coin Control")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button("Select All") { selectedKeys = Set(utxos.map(key)) }
                        Button("Automatic (Clear Selection)") { selectedKeys.removeAll() }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    let selected = utxos.filter { selectedKeys.contains(key($0)) }
                    onDone(selected.isEmpty ? nil : selected)
                    dismiss()
                } label: {
                    Text(selectedKeys.isEmpty ? "Use Automatic Selection" : "Confirm Selection")
                        .font(.subheadline.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .foregroundColor(.black)
                        .background(Capsule().fill(Color.accentColor))
                }
                .padding(.horizontal)
                .padding(.bottom, 16)
            }
            .task {
                utxoLabels = UtxoLabelStore.load(address: fromAddress)
                await loadUtxos()
                if let initialSelection {
                    selectedKeys = Set(initialSelection.map(key))
                }
            }
        }
    }

    private func formatKas(_ sompi: UInt64) -> String {
        String(format: "%.8f", Double(sompi) / 100_000_000.0)
    }
}

/// Names a person gave individual coins (UTXOs), shown in Coin Control. Kept under the key Cold
/// Storage used, so labels set there before it left the app still show.
enum UtxoLabelStore {
    static func load(address: String) -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: "kachat_cold_storage_utxo_labels_" + address),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return decoded
    }
}
