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

    /// The bots Kaspa Hub > KaChat Bots lists, in this order.
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

    /// Why the bot can't be messaged from here, or nil when it can.
    var unavailableReason: String? {
        guard !address.isEmpty else { return String(localized: "Coming soon.") }
        guard KaspaAddress.isValidOnActiveNetwork(address) else { return String(localized: "Bots run on mainnet only.") }
        return nil
    }
}

/// Kaspa Hub > KaChat Bots: one card per bot; tapping a card opens (or starts) the chat with it.
struct KaChatBotsView: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    ForEach(KaChatBot.all) { bot in
                        KaChatBotCard(bot: bot)
                    }
                    Text("Messages to a bot are ordinary encrypted KaChat messages, so each one costs the usual network fee.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                        .padding(.top, 4)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("KaChat Bots")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    ConnectionStatusIndicator()
                }
                ToolbarItem(placement: .principal) {
                    BalanceToolbarLabel()
                }
            }
        }
    }
}

private struct KaChatBotCard: View {
    let bot: KaChatBot

    var body: some View {
        let unavailable = bot.unavailableReason
        Button {
            Haptics.impact(.light)
            open()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: bot.systemImage)
                    .font(.scaled(size: 24, weight: .semibold))
                    .foregroundColor(.accentColor)
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(Color.accentColor.opacity(0.15)))
                VStack(alignment: .leading, spacing: 4) {
                    Text(bot.name)
                        .font(.headline)
                        .foregroundColor(.primary)
                    Text(unavailable ?? bot.summary)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if unavailable == nil {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(.secondary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(unavailable != nil)
        .opacity(unavailable == nil ? 1 : 0.6)
        .accessibilityHint(Text(unavailable ?? String(localized: "Opens a chat with this bot.")))
    }

    /// Opens (or starts) the 1:1 chat, the way the Address Book does. Starting it accepts it, so
    /// the bot's replies land in the chat, not in Message Requests; the bot's name is the
    /// contact's name until the person renames it.
    private func open() {
        guard bot.unavailableReason == nil else { return }
        let contacts = ContactsManager.shared
        var contact = contacts.getOrCreateContact(address: bot.address)
        if contact.alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || contact.isAutoAdded {
            contact.alias = bot.name
            contact.isAutoAdded = false
            contacts.updateContact(contact)
        }
        ChatService.shared.acceptChat(contact.address)
        _ = ChatService.shared.getOrCreateConversation(for: contact)
        ChatService.shared.pendingChatNavigation = contact.address
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            NotificationCenter.default.post(name: .openChat, object: nil, userInfo: ["contactAddress": contact.address])
        }
    }
}
