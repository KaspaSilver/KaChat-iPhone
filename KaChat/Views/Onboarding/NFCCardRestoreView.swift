#if canImport(CoreNFC) && !targetEnvironment(macCatalyst)
import SwiftUI

/// Import Account > Restore from NFC Card: the PIN and a tap read the backup, then the password
/// decrypts it on this iPhone. A wrong password needs no second tap, since the backup is in memory.
struct NFCCardRestoreView: View {
    @EnvironmentObject private var walletManager: WalletManager

    @State private var pin = ""
    @State private var password = ""
    @State private var backup: Data?
    @State private var busy = false
    @State private var errorMessage: String?

    private var pinValid: Bool {
        NFCCard.pinLengths.contains(pin.count) && pin.allSatisfy(\.isNumber)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if backup == nil {
                    Text("Restore from an NFC card")
                        .font(.title2.weight(.bold))
                    Text("Enter the card's PIN, then tap the card to read your backup.")
                        .foregroundColor(.secondary)
                    NFCCardSecretField(title: "Card PIN", text: $pin, isNumeric: true)
                    NFCCardNote(icon: "exclamationmark.triangle.fill", tint: .orange,
                                text: "After 5 wrong tries the PIN is blocked for good, and this backup can no longer be read.")
                    CreateWalletNextButton(title: "Scan Card", enabled: pinValid && !busy, busy: busy) {
                        Task { @MainActor in await readCard() }
                    }
                } else {
                    Text("Enter your backup password")
                        .font(.title2.weight(.bold))
                    Text("The backup was read from your card. This password decrypts it on this iPhone.")
                        .foregroundColor(.secondary)
                    NFCCardSecretField(title: "Backup password", text: $password, isNumeric: false)
                    CreateWalletNextButton(title: "Restore Account", enabled: !password.isEmpty && !busy, busy: busy) {
                        Task { @MainActor in await restore() }
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Import Account")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(busy)
        .alert("NFC Card", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .onDisappear {
            pin = ""
            password = ""
            backup = nil
        }
    }

    private func show(_ error: Error) {
        if case NFCCardError.cancelled = error { return }
        errorMessage = error.localizedDescription
    }

    @MainActor
    private func readCard() async {
        guard pinValid else { return }
        busy = true
        defer { busy = false }
        let enteredPIN = pin
        do {
            backup = try await NFCCard.run(success: "Backup read.") { connection in
                connection.setMessage("Reading. Keep the card still.")
                let current = try await connection.select()
                if current.pinBlocked { throw NFCCardError.pinBlocked }
                if !current.pinSet { throw NFCCardError.noPIN }
                if !current.hasBackup { throw NFCCardError.noBackup }
                try await connection.verifyPIN(enteredPIN)
                return try await connection.readBackup()
            }
            pin = ""
        } catch {
            pin = ""
            show(error)
        }
    }

    @MainActor
    private func restore() async {
        guard let backup else { return }
        busy = true
        defer { busy = false }
        let enteredPassword = password
        do {
            let payload = try await Task.detached(priority: .userInitiated) {
                try NFCCardBackupFormat.open(backup, password: enteredPassword)
            }.value
            guard let family = WalletSourceFamily(rawValue: payload.family) else {
                throw NFCCardError.unreadableBackup
            }
            try await commitImport(payload, family: family)
        } catch {
            show(error)
        }
    }

    /// The same arming as `ImportWalletView.commitImport`, so the Welcome Guide and the held sync
    /// behave exactly like a typed import.
    @MainActor
    private func commitImport(_ payload: NFCCardBackupPayload, family: WalletSourceFamily) async throws {
        walletManager.justCreatedNewWallet = true
        ChatService.shared.holdSyncForOnboarding()
        walletManager.justImportedWallet = true
        do {
            let wallet = try await walletManager.importWallet(
                from: SeedPhrase(words: payload.words, passphrase: payload.passphrase),
                alias: payload.alias,
                chattingAddressIndex: payload.chattingAddressIndex,
                family: family
            )
            // Unlike someone typing the words, this person may not have them written down.
            AccountBackupStatus.shared.markPending(wallet.publicAddress)
            Task { await walletManager.discoverSpendingAddresses() }
        } catch {
            walletManager.justCreatedNewWallet = false
            walletManager.justImportedWallet = false
            ChatService.shared.releaseSyncForOnboarding()
            throw error
        }
    }
}
#endif
