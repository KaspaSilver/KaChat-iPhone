#if canImport(CoreNFC) && !targetEnvironment(macCatalyst)
import SwiftUI

/// Settings > Back Up to NFC Card, behind the seed phrase's biometric gate. Two taps: the first
/// reads the card to learn whether it needs a new PIN or already holds a backup, the second saves.
/// It never clears the "not backed up" card on Profile: the written seed phrase stays the main copy.
struct NFCCardBackupView: View {
    private enum Step {
        case intro, details, erase, saved, erased
    }

    @EnvironmentObject private var walletManager: WalletManager
    @Environment(\.dismiss) private var dismiss

    @State private var step: Step = .intro
    @State private var card: NFCCardStatus?
    @State private var pin = ""
    @State private var confirmPIN = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var replaceConfirmed = false
    @State private var understoodPassword = false
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var showEraseConfirmation = false

    private var pinValid: Bool {
        NFCCard.pinLengths.contains(pin.count) && pin.allSatisfy(\.isNumber)
    }

    private var canSave: Bool {
        guard let card, pinValid, !busy else { return false }
        if !card.pinSet && pin != confirmPIN { return false }
        if card.hasBackup && !replaceConfirmed { return false }
        return password.count >= NFCCard.minimumPasswordLength
            && password == confirmPassword
            && password != pin
            && understoodPassword
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch step {
                    case .intro: intro
                    case .details: details
                    case .erase: erase
                    case .saved: finished(title: "Backup saved",
                                          detail: "It was read back from the card and checked. To restore it, choose Import Existing Account, then Restore from NFC Card. This card doesn't replace your written seed phrase, so keep that too.")
                    case .erased: finished(title: "Backup erased",
                                           detail: "The backup is gone from this card. Its PIN stays the same.")
                    }
                }
                .padding()
            }
            .navigationTitle("NFC Card Backup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if step != .saved && step != .erased {
                        Button("Cancel") { dismiss() }
                            .disabled(busy)
                    }
                }
            }
            .alert("NFC Card", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .confirmationDialog("Erase the backup on this card?", isPresented: $showEraseConfirmation, titleVisibility: .visible) {
                Button("Erase Backup", role: .destructive) {
                    Task { @MainActor in await eraseBackup() }
                }
            } message: {
                Text("This can't be undone.")
            }
        }
        .interactiveDismissDisabled(busy)
        .onDisappear(perform: clearSecrets)
    }

    private var intro: some View {
        Group {
            Text("Back up to an NFC card")
                .font(.title2.weight(.bold))
            Text("Saves an encrypted copy of this account's seed phrase on your card, protected by a PIN and a password.")
                .foregroundColor(.secondary)
            NFCCardNote(icon: "exclamationmark.triangle.fill", tint: .orange,
                        text: "This isn't cold storage. The card only holds an encrypted copy and never creates keys, so keep your seed phrase written down too.")
            NFCCardNote(icon: "sdcard.fill", tint: .accentColor,
                        text: "Your card needs the KaChat-NFC software first. Load it from the NFC Card page in Kaspa Quick Start.")
            NFCCardNote(icon: "key.fill", tint: .accentColor,
                        text: "If you forget the PIN or the password, this backup can't be recovered.")
            CreateWalletNextButton(title: "Scan Card", enabled: !busy, busy: busy) {
                Task { @MainActor in await scanCard() }
            }
            Button("Erase a Backup on a Card") {
                step = .erase
            }
            .frame(maxWidth: .infinity)
            .disabled(busy)
        }
    }

    private var details: some View {
        Group {
            if let card {
                if card.hasBackup {
                    NFCCardNote(icon: "exclamationmark.triangle.fill", tint: .orange,
                                text: "This card already holds a backup. Saving replaces it once the new one is confirmed.")
                    Toggle("Replace the backup on this card", isOn: $replaceConfirmed)
                }
                if card.pinSet {
                    NFCCardSecretField(title: "Card PIN", text: $pin, isNumeric: true)
                    if card.triesRemaining < 5 {
                        Text("\(card.triesRemaining) PIN tries left on this card.")
                            .font(.footnote)
                            .foregroundColor(.orange)
                    }
                } else {
                    NFCCardSecretField(title: "New card PIN, 6 to 12 digits", text: $pin, isNumeric: true)
                    NFCCardSecretField(title: "Confirm card PIN", text: $confirmPIN, isNumeric: true)
                    Text("After 5 wrong tries the PIN is blocked for good, and there's no reset.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                NFCCardSecretField(title: "New backup password", text: $password, isNumeric: false)
                NFCCardSecretField(title: "Confirm backup password", text: $confirmPassword, isNumeric: false)
                Text("At least 12 characters, and different from the PIN. It encrypts your seed phrase on this iPhone and never reaches the card. It's what protects you if someone reads the chip, so make it strong.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                Toggle("I understand this password can't be reset or recovered", isOn: $understoodPassword)
                CreateWalletNextButton(title: "Save to Card", enabled: canSave, busy: busy) {
                    Task { @MainActor in await save() }
                }
            }
        }
    }

    private var erase: some View {
        Group {
            Text("Erase a backup")
                .font(.title2.weight(.bold))
            Text("Enter the card's PIN, then tap the card to erase the backup on it.")
                .foregroundColor(.secondary)
            NFCCardSecretField(title: "Card PIN", text: $pin, isNumeric: true)
            CreateWalletNextButton(title: "Erase Backup", enabled: pinValid && !busy, busy: busy) {
                showEraseConfirmation = true
            }
            Button("Back") {
                pin = ""
                step = .intro
            }
            .frame(maxWidth: .infinity)
            .disabled(busy)
        }
    }

    private func finished(title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        Group {
            Image(systemName: "checkmark.circle.fill")
                .font(.largeTitle)
                .foregroundColor(.green)
                .frame(maxWidth: .infinity)
            Text(title)
                .font(.title2.weight(.bold))
                .frame(maxWidth: .infinity)
            Text(detail)
                .foregroundColor(.secondary)
            CreateWalletNextButton(title: "Done", enabled: true) { dismiss() }
        }
    }

    private func clearSecrets() {
        pin = ""
        confirmPIN = ""
        password = ""
        confirmPassword = ""
    }

    private func show(_ error: Error) {
        if case NFCCardError.cancelled = error { return }
        errorMessage = error.localizedDescription
    }

    @MainActor
    private func scanCard() async {
        busy = true
        defer { busy = false }
        do {
            let status = try await NFCCard.run(success: "Card found.") { connection in
                try await connection.select()
            }
            guard !status.pinBlocked else { throw NFCCardError.pinBlocked }
            card = status
            replaceConfirmed = false
            step = .details
        } catch {
            show(error)
        }
    }

    @MainActor
    private func save() async {
        guard let card, canSave else { return }
        busy = true
        defer { busy = false }
        let enteredPIN = pin
        let enteredPassword = password
        do {
            guard let wallet = walletManager.currentWallet,
                  let seedPhrase = try walletManager.getSeedPhrase() else {
                throw NFCCardError.seedUnavailable
            }
            let phrasePassphrase = seedPhrase.passphrase ?? ""
            let payload = NFCCardBackupPayload(
                words: seedPhrase.words,
                passphrase: phrasePassphrase.isEmpty ? nil : phrasePassphrase,
                family: walletManager.walletSourceFamily(for: wallet.publicAddress).rawValue,
                chattingAddressIndex: walletManager.chattingAddressIndex(for: wallet.publicAddress),
                alias: wallet.alias
            )
            let backup = try await Task.detached(priority: .userInitiated) {
                try NFCCardBackupFormat.seal(payload, password: enteredPassword)
            }.value
            guard backup.count <= card.maxBackup else { throw NFCCardError.backupTooLarge }

            try await NFCCard.run(success: "Backup saved.") { connection in
                connection.setMessage("Saving. Keep the card still.")
                let current = try await connection.select()
                if current.pinBlocked { throw NFCCardError.pinBlocked }
                // The confirmations were for the card scanned first. An interrupted save can
                // legitimately leave that card with its new PIN and no backup yet.
                if (current.hasBackup && !card.hasBackup) || (card.pinSet && !current.pinSet) {
                    throw NFCCardError.cardChanged
                }
                if !current.pinSet {
                    try await connection.setPIN(enteredPIN)
                }
                try await connection.verifyPIN(enteredPIN)
                try await connection.writeBackup(backup)
                guard try await connection.readBackup() == backup else {
                    throw NFCCardError.saveNotConfirmed
                }
            }

            // What's on the card has to open with this password, not just match what was sent.
            _ = try await Task.detached(priority: .userInitiated) {
                try NFCCardBackupFormat.open(backup, password: enteredPassword)
            }.value
            clearSecrets()
            step = .saved
        } catch NFCCardError.wrongPIN(let triesRemaining) {
            pin = ""
            self.card = NFCCardStatus(
                pinSet: card.pinSet,
                hasBackup: card.hasBackup,
                pinBlocked: false,
                triesRemaining: triesRemaining,
                maxBackup: card.maxBackup
            )
            show(NFCCardError.wrongPIN(triesRemaining: triesRemaining))
        } catch {
            if case NFCCardError.pinBlocked = error { backToStart() }
            if case NFCCardError.cardChanged = error { backToStart() }
            show(error)
        }
    }

    private func backToStart() {
        clearSecrets()
        card = nil
        understoodPassword = false
        replaceConfirmed = false
        step = .intro
    }

    @MainActor
    private func eraseBackup() async {
        guard pinValid else { return }
        busy = true
        defer { busy = false }
        let enteredPIN = pin
        do {
            try await NFCCard.run(success: "Backup erased.") { connection in
                let current = try await connection.select()
                if current.pinBlocked { throw NFCCardError.pinBlocked }
                if !current.pinSet { throw NFCCardError.noPIN }
                if !current.hasBackup { throw NFCCardError.noBackup }
                try await connection.verifyPIN(enteredPIN)
                try await connection.wipe()
            }
            clearSecrets()
            step = .erased
        } catch {
            pin = ""
            show(error)
        }
    }
}

/// A PIN or password entry. It never offers to save the value or autofill it.
struct NFCCardSecretField: View {
    let title: LocalizedStringKey
    @Binding var text: String
    let isNumeric: Bool

    var body: some View {
        SecureField(title, text: $text)
            .keyboardType(isNumeric ? .numberPad : .default)
            .textContentType(nil)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding()
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct NFCCardNote: View {
    let icon: String
    let tint: Color
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(tint)
                .frame(width: 24)
            Text(text)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .background(tint.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
#endif
