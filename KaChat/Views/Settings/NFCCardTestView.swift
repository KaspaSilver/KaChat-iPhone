#if canImport(CoreNFC) && !targetEnvironment(macCatalyst)
import CoreNFC
import SwiftUI

/// Beta-only check for the smart card seed backup idea: can this iPhone see the card over NFC?
/// It only detects the card and never sends it anything that could change it.
struct NFCCardTestView: View {
    @StateObject private var scanner = NFCCardScanner()

    var body: some View {
        Form {
            Section {
                Button("Scan Card") { scanner.start() }
                    .disabled(!NFCTagReaderSession.readingAvailable || scanner.isScanning)
            } footer: {
                Text("Remove any thick case, tap Scan Card, then hold the card flat against the top back of your iPhone for about 5 seconds.")
            }
            if !NFCTagReaderSession.readingAvailable {
                Section("Result") {
                    Text("This device can't read NFC cards.")
                }
            } else if let result = scanner.result {
                Section("Result") {
                    Text(result)
                }
            }
        }
        .navigationTitle("Test NFC Card")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private final class NFCCardScanner: NSObject, ObservableObject, NFCTagReaderSessionDelegate {
    @Published private(set) var isScanning = false
    @Published private(set) var result: String?
    private var session: NFCTagReaderSession?
    private var foundCard = false

    func start() {
        guard let session = NFCTagReaderSession(pollingOption: .iso14443, delegate: self, queue: .main) else {
            result = "Couldn't start the NFC scan."
            return
        }
        foundCard = false
        result = nil
        isScanning = true
        session.alertMessage = "Hold your card against the top back of your iPhone."
        self.session = session
        session.begin()
    }

    func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {}

    func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        guard let tag = tags.first else { return }
        session.connect(to: tag) { [weak self] error in
            guard let self else { return }
            if let error {
                self.finish(session, "An NFC card was detected, but the connection dropped: \(error.localizedDescription). Hold it still and try again.")
                return
            }
            switch tag {
            case .iso7816(let card):
                self.finish(session, "Success: the card has working NFC, and its card manager answered (\(card.initialSelectedAID)).")
            case .miFare(let card):
                self.finish(session, "An NFC card was detected, but its card manager didn't answer. Card family: \(Self.name(of: card.mifareFamily)).")
            case .iso15693, .feliCa:
                self.finish(session, "A different type of NFC tag was detected, not this kind of smart card.")
            @unknown default:
                self.finish(session, "An unknown type of NFC tag was detected.")
            }
        }
    }

    func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        isScanning = false
        self.session = nil
        guard !foundCard else { return }
        switch (error as? NFCReaderError)?.code {
        case .readerSessionInvalidationErrorUserCanceled, .readerSessionInvalidationErrorSessionTimeout:
            result = "No card detected. The card most likely has no NFC, or NFC is switched off on it."
        default:
            result = "The scan couldn't run: \(error.localizedDescription)"
        }
    }

    private func finish(_ session: NFCTagReaderSession, _ message: String) {
        foundCard = true
        result = message
        session.alertMessage = "Card checked."
        session.invalidate()
    }

    private static func name(of family: NFCMiFareFamily) -> String {
        switch family {
        case .ultralight: return "Ultralight"
        case .plus: return "Plus"
        case .desfire: return "DESFire"
        case .unknown: return "unknown"
        @unknown default: return "unknown"
        }
    }
}
#endif
