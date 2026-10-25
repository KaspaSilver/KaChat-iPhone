import SwiftUI

/// One KaChat bot: a Kaspa address that answers in an ordinary 1:1 chat (the KaChat-Bot repo,
/// run from the Kaspa Quick Start panel). Messaging it starts a private conversation; it asks its
/// setup questions in the chat.
struct KaChatBot: Identifiable, Equatable {
    let id: String
    let name: String
    let summary: String
    let systemImage: String
    /// The bot's mainnet address. Bots run on mainnet only.
    let address: String

    /// Every bot, in the order the circles row on Chats shows them.
    static let all: [KaChatBot] = [
        KaChatBot(
            id: "block-rewards",
            name: String(localized: "Block Reward Tracker"),
            summary: String(localized: "A message for every block reward paid to your mining address."),
            systemImage: "cube.transparent",
            address: "kaspa:qram07v34rnfwthwc7vssvgapxtdy9mheg8mz0v0yudqtm8z94sv5upwasd8q"
        ),
        KaChatBot(
            id: "wallet",
            name: String(localized: "Wallet Tracker"),
            summary: String(localized: "Tells you when a watched address receives or sends KAS."),
            systemImage: "wallet.pass",
            address: "kaspa:qzh3m296f44ez75avxd4k0dyvv5hj6sf06cuzaty5hk89w9nsprr6nngjsfvq"
        ),
        KaChatBot(
            id: "price",
            name: String(localized: "Price Bot"),
            summary: String(localized: "Alerts when KAS crosses your price, big moves and a daily summary."),
            systemImage: "chart.line.uptrend.xyaxis",
            address: "kaspa:qzk2jrk7wq3zdw2n0260v87fglky82cg5u3pwy73wpktk3u864yecm5djll40"
        ),
        KaChatBot(
            id: "kaspa-answers",
            name: String(localized: "Kaspa Answers"),
            summary: String(localized: "Ask anything related to Kaspa."),
            systemImage: "questionmark.bubble",
            address: "kaspa:qqj0vdfxv66xad0j382jeur2jpdpsjej2qzqzwaxtw66h2f3zg0djndh8ypq8"
        ),
    ]

    private static let addresses = Set(all.map { $0.address.lowercased() })

    static func bot(for address: String) -> KaChatBot? {
        let key = address.lowercased()
        return all.first { $0.address.lowercased() == key }
    }

    /// True for a bot's address. Bot chats never sit in the chat list: every bot is always a
    /// circle in the row above it, beside the group chats (since 2026-10-24).
    static func isBot(_ address: String) -> Bool {
        addresses.contains(address.lowercased())
    }

    /// Why the bot can't be messaged from here, or nil when it can.
    var unavailableReason: String? {
        guard !address.isEmpty else { return String(localized: "Coming soon.") }
        guard KaspaAddress.isValidOnActiveNetwork(address) else { return String(localized: "Bots run on mainnet only.") }
        return nil
    }

    /// The bots the circles row shows: the ones that can be messaged on this network.
    static var available: [KaChatBot] { all.filter { $0.unavailableReason == nil } }

    /// Opens (or starts) the 1:1 chat with this bot, the way the Address Book does, and returns
    /// its contact. Starting it accepts it, so the bot's replies land in the chat, not in Message
    /// Requests; the bot's name is the contact's name until the person renames it. A chat
    /// deleted before starts again: the deletion's block on the bot's messages is lifted, but
    /// what came before the deletion stays deleted (`clearDeletionTombstone` keeps it as the
    /// history floor).
    @MainActor
    func startChat() -> Contact? {
        guard unavailableReason == nil else { return nil }
        let contacts = ContactsManager.shared
        contacts.clearDeletionTombstone(address)
        var contact = contacts.getOrCreateContact(address: address)
        if contact.alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || contact.isAutoAdded {
            contact.alias = name
            contact.isAutoAdded = false
            contacts.updateContact(contact)
        }
        ChatService.shared.acceptChat(contact.address)
        _ = ChatService.shared.getOrCreateConversation(for: contact)
        return contact
    }
}
