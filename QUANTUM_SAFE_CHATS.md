# Quantum-safe chats (design, not built)

Status: **planning**. Nothing here is implemented. iOS is the reference; Android, Desktop and the
extension must follow the wire formats exactly, and must ship the **read** side before iOS sends
anything new (section 12).

## 1. The problem: harvest now, decrypt later

Every KaChat message lives on the Kaspa chain forever. Anyone can copy it today and keep it until a
large quantum computer exists, then break the key exchange and read it.

Today a 1:1 message is ECIES (`KaChatCipher.swift`): a one-time secp256k1 key, ECDH with the
recipient's key (taken from their address), HKDF-SHA256, ChaCha20-Poly1305. The sealed blob is
`nonce (12) || ephemeral public key (33, compressed) || ciphertext || tag (16)`. Both public keys are
public, so Shor's algorithm gives the shared secret and the message.

What is exposed today, by kind:

| Data on chain | How it's sealed today | Exposed to a future quantum attacker |
|---|---|---|
| `comm` / `dm` messages, photos, voice notes | ECIES to the recipient | Yes |
| `pay` memos, `payment_notice` | ECIES to the recipient | Yes |
| Read-back of your own sends | ECIES, one-time key derived from the chatting private key | Yes (the chatting private key itself falls to Shor) |
| `self_stash` notes (`saved_handshake`, contact notes) | ECIES to your own key | Yes |
| Group roots to members (`gctl_root`, `gctl_epoch`) | ECIES to each member | Yes, and with it every message of that epoch |
| Admin's group recovery copy (carries `groupSeed`) | ECIES to your own key | Yes, and with it **every epoch** of that group (epoch roots are derived from the seed) |
| Group messages (`gcomm`) | Symmetric (ChaCha20-Poly1305) | Only through the root keys above |
| Call setup (Nextcloud Talk opening message) | 1:1 ECIES | Yes |
| Handshakes (older clients, Kasia) | ECIES | Yes |

Not in scope: metadata (who wrote to whom, when, amounts) is public now and stays public;
signatures (Schnorr) can be forged by a quantum computer later, but forgery doesn't reveal old
messages (section 14 covers the follow-up). Funds are a separate problem, already handled by
quantum-safe (KIP-22) addresses. **Messages already on chain can't be protected**: only what is
sent after this ships.

## 2. Goals

- New 1:1 chats, payment memos and groups can't be read even by a future quantum computer.
- The user does nothing: an upgrade happens by itself on the next message once both apps support it.
- Normal fees after a one-time setup per conversation. Upgraded messages are slightly **smaller** than
  today's.
- Seed restore keeps working: a new device with the seed reads everything, including its own sends.
- No indexer change for messages: the payload kinds (`comm`, `dm`, `pay`, `gctl`, `gcomm`) and aliases
  stay as they are. Only the sealed bytes change.
- Never weaker than today: the new key mixes in today's secp256k1 ECDH, so breaking only the
  post-quantum part gains nothing.

## 3. Overview

1. **Each account publishes one post-quantum public key** on chain (section 5), once.
2. **Self-addressed data switches to a symmetric key from the seed** (section 4). No other party is
   involved, no size cost, so this ships first.
3. **A conversation upgrades once** (section 6): the next message to someone with a published key
   carries a one-time **setup** (an X-Wing encapsulation, ~1.1 KB). Both sides derive a **conversation
   key** from it.
4. **Every later message** in both directions is sealed with symmetric keys from the conversation key
   (section 7). No per-message post-quantum data, so the fee is back to normal.
5. **Groups** carry their keys over the upgraded 1:1 channels and stop deriving epoch keys from a
   seed that was ever sent the old way (section 9).

The KEM is **X-Wing** (ML-KEM-768 combined with X25519, `draft-connolly-cfrg-xwing-kem`), available
in CryptoKit as `XWingMLKEM768X25519` on iOS 26. Sizes: public key 1216 bytes, ciphertext 1120 bytes,
shared secret 32 bytes, private key seed 32 bytes.

## 4. Keys from the seed

All new secrets come from the **BIP39 seed bytes** (64 bytes, passphrase included), never from the
chatting private key. A quantum computer can recover the chatting private key from its public key,
but not the seed, so nothing derived from the seed falls with it.

```
acct      = UTF8(network hrp, e.g. "kaspa") || u32le(chatting address index) || u8(wallet family)
K_self    = HKDF-SHA256(ikm = seed64, salt = "kachat-self-v1",   info = acct,              32 bytes)
pqSeed(k) = HKDF-SHA256(ikm = seed64, salt = "kachat-pq-kem-v1", info = acct || u32le(k), 32 bytes)
pqKey(k)  = XWingMLKEM768X25519.PrivateKey(seedRepresentation: pqSeed(k), publicKey: nil)
```

- `k` is the key id (`kid`), starting at 0. A new `kid` only on a deliberate key change (section 5.3).
- `acct` keeps two accounts on one seed, and mainnet and testnet, from sharing a key (a shared key
  would link them).
- Every KaChat account today is created or imported from a seed. If a client ever adds key-only
  import, that account can't use quantum-safe chats (it shows "Needs a seed phrase").

### 4.1 Self-sealed data (`K_self`)

Everything a client seals only to itself moves to symmetric encryption with `K_self`:

- `self_stash` notes (`saved_handshake`, contact notes, and the new `pq_key`'s companions),
- the admin's group recovery copy (it carries `groupSeed`),
- the conversation-key wrap in a setup (section 6.2).

Format: magic and type `0xFF 0x4B 0x51 0x03` ("\xFFKQ", self-sealed), then
`nonce (12) || ChaCha20-Poly1305(K_self, nonce, plaintext, aad = magic||type) || tag (16)`. It's 33
bytes shorter than ECIES to yourself, so slightly cheaper. Old notes stay on chain as they are; only new
ones are protected.

Optional, low priority: the Nextcloud backup envelope's key comes from the chatting private key
(`MESSAGING.md`, "Encrypted Backup Envelope"). The file isn't public, but a v2 envelope could use
`HKDF(seed64, salt = "kachat-backup-v2", info = acct)`.

## 5. Publishing the post-quantum key

### 5.1 Record

A self-stash transaction from the chatting address back to itself:

```
kchat:1:self_stash:pq_key:<base64(record)>
```

`record` (binary, 1297 bytes):

```
"KPQK" (4) || v = 1 (1) || kid u32le (4) || created_ms u64le (8) || pk (1216, X-Wing) || sig (64)
sig = Schnorr(chatting key) over SHA-256("kachat-pq-key-v1" || v || kid || created_ms || pk || UTF8(chatting address, lowercase))
```

The record isn't encrypted: it's a public key. The address comes from the transaction's sender and is
signed into `sig`, so a record can't be replayed under another address.

### 5.2 Finding someone's key

- Ask the indexer `GET /self-stash/by-owner?owner=<address>&scope=pq_key` (the same endpoint the
  saved-handshake notes use). **Indexer handoff:** confirm it stores and serves any `self_stash`
  scope; if it filters by scope, add `pq_key` (handoff doc in the indexer repo, no indexer code from
  here).
- Fallback when the indexer can't answer: scan the address's transactions on the REST API for the
  prefix (slow; only on demand).
- Verify `sig`, and that the transaction's sender is the address. Ignore anything that fails.
- Cache per address: "has key (kid, pk)", "no key, checked at T" (re-check after 24 h or when they
  message us), "invalid".

### 5.3 Pinning and key changes

- **Pin the earliest valid record** per address and kid (lowest DAA score / block time). A later record
  with the **same** kid and a different key is ignored.
- A record with a **higher** kid is a key change: accept it, start a new setup on the next send, and
  show a system line in the chat ("aurora.kachat's quantum-safe key changed"). Until a quantum computer
  exists, Schnorr can't be forged, so a key change today is genuine. Once one exists, a forged change
  shows up as this warning (section 14 plans the real fix).
- Clients never publish a higher kid on their own. Only "Reset quantum-safe key" in settings does
  (an advanced action, for a device the user believes was compromised).

### 5.4 When the key gets published

- Once per account, after the chatting address first has enough KAS. Silent, retried at the next
  launch if it fails. Never blocks sending.
- New accounts: automatic (mentioned on the onboarding "How KaChat Uses Kaspa" page).
- Existing accounts: one "Quantum-safe chats" sheet after updating (section 11.1). **Decision needed**,
  section 15.
- A wallet that already sees its own `pq_key` on chain (restored seed, second device) never publishes
  again.

## 6. Upgrading a conversation

### 6.1 When

The sender (A) upgrades the conversation with B on its next `comm`, `dm`, `pay` memo or
`payment_notice` to B when all of these hold:

1. quantum-safe chats are on for A's account (section 11.3),
2. A's device can encapsulate (iOS 26+, section 13),
3. B has a valid pinned `pq_key`,
4. no conversation key exists yet for A and B (from either side), or B's key changed.

B doesn't need A's key. The initiator encapsulates to the responder only, and both use the result.
Neither side ever sends a separate upgrade transaction: the setup rides on a real message.

If A can't afford the extra ~1.5 KB right now but can afford the plain message, send the plain message
and try again on the next send. Messaging is never blocked by the upgrade.

### 6.2 Setup message

```
(ss_x, ct) = X-Wing.Encapsulate(pk_B)           // CryptoKit: pk_B.encapsulate()
ss_ec      = ECDH_secp256k1(A chatting private key, B chatting public key)   // as KaChatCipher does today
conv_id    = first 8 bytes of SHA-256("kachat-pq-conv-id-v1" || ct)
CK         = HKDF-SHA256(ikm = ss_x || ss_ec, salt = conv_id,
                         info = "kachat-pq-ck-v1" || UTF8(A lowercase) || UTF8(B lowercase), 32 bytes)
```

Sealed blob (replaces today's ECIES blob after the alias, base64 as today):

```
0xFF 0x4B 0x51 0x01                       magic "\xFFKQ" + type 1 = setup
kid_B u32le (4)                           which of B's keys
ct (1120)                                 X-Wing ciphertext
wrap_nonce (12) || wrap (32 + 16)         CK sealed with A's K_self, aad = "kachat-pq-wrap-v1" || conv_id || UTF8(B)
nonce (12) || body || tag (16)            the actual message, sealed as in section 7
```

- **B** decapsulates `ct` with `pqKey(kid_B)`, computes `ss_ec` the same way from its side, and gets
  `CK`. Any of B's devices with the seed can do this, at any time, from the chain alone.
- **A's other devices** (and A after a seed restore) open `wrap` with `K_self`. ML-KEM encapsulation is
  random, so this wrap is the only way the initiator gets `CK` back.

### 6.3 Responder's first reply carries a wrap too

B's first message in the conversation uses type `0x04` (a type-2 message plus a `K_self` wrap of `CK`
for B's own devices):

```
0xFF 0x4B 0x51 0x04 || conv_id (8) || wrap_nonce (12) || wrap (48) || nonce (12) || body || tag (16)
```

After that, every device on both sides gets `CK` with symmetric crypto only. Only the device that first
decapsulates needs X-Wing, which matters for older iOS versions (section 13).

### 6.4 Both start at once

If A and B each send a setup before seeing the other's, two conversation keys exist. Both stay valid
and every message names its `conv_id`, so both decrypt. For sending, every device uses the setup
**accepted first on chain** (lower DAA score; tie: lower `conv_id`) and switches to it as soon as it
sees both.

## 7. Messages after the upgrade

```
K_dir(S) = HKDF-SHA256(ikm = CK, salt = conv_id, info = "kachat-pq-dir-v1" || UTF8(S lowercase), 32 bytes)
```

`S` is the sending address, so the two directions never share a key.

```
0xFF 0x4B 0x51 0x02 || conv_id (8) || nonce (12, random) || ChaCha20-Poly1305(K_dir(S), nonce, plaintext,
                                                              aad = magic||type||conv_id) || tag (16)
```

- Plaintext is exactly what is sealed today: UTF-8 text, the binary media frame (`0xFF "KCM"`),
  payment memos, call setup, group control JSON.
- Overhead is 40 bytes against today's 61, so every upgraded message is **21 bytes smaller**.
- Stateless: no ratchet, no counters to sync. Messages can arrive out of order, from several devices,
  or years later after a seed restore. Random 96-bit nonces under one direction key are safe far past
  any chat's lifetime.
- Read-back of your own sends works on every device that holds `CK`.
- **No downgrade:** once a conversation has a `CK`, a client never sends that peer a plain ECIES
  message again. If one arrives from the peer anyway (an old device of theirs), it's shown normally,
  and its info says "Standard encryption".

### 7.1 Telling formats apart

Today's blobs start with a random nonce, so any first bytes can occur. Readers:

1. If the blob starts with `0xFF 0x4B 0x51` and the type is known, try that format.
2. If that fails authentication, or the magic isn't there, decrypt it the way it's done today.
3. If both fail: an unknown type shows **"Update KaChat to read this message"**; anything else stays
   "[Encrypted message]" as now.

A plain message can start with the magic by chance (1 in 16.7 million); step 2 still reads it, so it
costs only one extra failed check.

### 7.2 Missing keys

A type-2 message whose `conv_id` isn't known yet (the setup hasn't been fetched) waits as
"Waiting for keys…", is retried after the next history fetch, and never becomes a lasting failure on
its own. A full history fetch processes setups (type 1) and wraps (type 4) before type-2 messages.

## 8. Requests, payments and calls

- **First contact (`dm`)**: a `dm` to someone with a published key carries the setup. The inbox tag and
  Message Requests work exactly as in `NO_HANDSHAKE_MESSAGING.md`. A request shows the same content once
  accepted.
- **Payments**: the memo of `kchat:1:pay:` and `payment_notice` use type 2 (or type 1 if this payment is
  what upgrades the chat). The transfer itself is unchanged.
- **Calls**: the Nextcloud Talk opening message rides the 1:1 channel, so it's covered once the chat is
  upgraded.
- **Kasia and older clients** never publish a key, so chats with them stay as they are today.

## 9. Groups

Today, epoch roots are `HKDF(groupSeed, ...)` and the admin's recovery copy carries `groupSeed` sealed
the old way. One harvested recovery copy gives every epoch of that group, past and future. So upgrading
a group means a fresh random root, delivered only over upgraded channels.

### 9.1 v2 roots

- `gctl_root` / `gctl_epoch` get `"v": 2` and `"pq": true`, and in a quantum-safe group,
  `groupRootEpoch` is **32 random bytes per epoch**, never derived from `groupSeed`.
- Each member's copy is sealed with type 2 under that member's 1:1 conversation key (the admin is
  always a 1:1 contact of every member already). A member with no conversation key yet gets the setup
  (type 1) on that same message.
- The admin's recovery copy is self-sealed (type 3, `K_self`) and holds every epoch's random root, so a
  restored admin rebuilds the group.
- Group messages (`gcomm`) are unchanged.
- `blindingKey` still comes from `groupSeed`. For groups whose seed went out the old way, that only
  lets an attacker link the group's messages together (metadata), not read them.

### 9.2 When a group is quantum-safe

- **New group:** quantum-safe from the start when every member it's created with has a key.
- **Existing group:** the admin taps "Make Group Quantum-Safe" (section 11.6). This starts a new epoch
  with a random root sent over upgraded channels. Earlier epochs stay as they were.
- **Adding a member with no key:** the admin is warned first. If they go ahead, that member's root goes
  out the old way, so the group shows as "Standard encryption" until the admin upgrades it again.
- Clients that don't understand v2 roots can't read the group after the upgrade. The admin only gets
  the button when every member's app can.

## 10. Costs

At the minimum fee KaChat uses (`KaspaFeePolicy`: 100 sompi per gram, 2 grams per payload byte, so
**about 200 sompi per byte**, more on a busy network). A short message today costs about 0.002 KAS
(the onboarding's "5 Kaspa is enough for about 2500 messages").

| What | When | Extra cost |
|---|---|---|
| Publishing your key (`pq_key`, ~1.76 KB payload) | Once per account | about 0.004 KAS |
| Setup on the first message to someone (+~1.54 KB) | Once per conversation | about 0.003 KAS |
| Responder's wrap (+~80 bytes) | Once per conversation, on their first reply | about 0.00016 KAS |
| Every later message (21 bytes smaller) | Each message | about 0.00006 KAS **cheaper** |
| Self-stash notes (33 bytes smaller) | Each note | slightly cheaper |
| Group upgrade | Once per group | a normal root message per member, plus a setup for any member without a conversation key |

A conversation pays back its setup after about 50 messages. Measure the real numbers on testnet before
release; the transaction around the payload adds the same base cost it does today.

## 11. UI

The rule: users shouldn't have to understand any of this. Nothing asks for a choice in normal use,
nothing looks broken when a chat isn't upgraded yet, and the words are plain ("quantum-safe", never
"ML-KEM" or "post-quantum" in the UI). KaChat already calls KIP-22 addresses "Quantum-safe", so chats
use the same word and the same shield icon.

### 11.1 After updating (existing accounts, once)

A sheet on the first launch after the update, after any What's New content:

```
┌───────────────────────────────────────┐
│               (shield)                │
│         Quantum-Safe Chats            │
│                                       │
│ Your messages are stored on the Kaspa │
│ network forever. Future computers may │
│ break today's encryption, so KaChat   │
│ now protects new messages against     │
│ that.                                 │
│                                       │
│ • It's automatic. Each chat upgrades  │
│   once both of you have updated.      │
│ • One-time network fee of about       │
│   0.004 KAS for your account.         │
│ • Earlier messages can't be upgraded. │
│                                       │
│ [          Turn On          ]         │
│              Not Now                  │
└───────────────────────────────────────┘
```

- **Turn On** publishes the key in the background and dismisses at once. No Face ID (it's a self-send
  like a message, and messages don't ask).
- With no KAS: the button reads **Turn On When Funded**, and the key goes out after the first deposit.
- **Not Now** leaves it off. Settings has the switch (11.3), and the sheet never comes back.
- New accounts skip the sheet: on by default, explained by one added line on the onboarding page "How
  KaChat Uses Kaspa".

### 11.2 Inside a chat

- **Header:** an upgraded chat shows a small shield beside the name in the header pill. Tapping the
  name opens the contact info as today. A chat that isn't upgraded shows nothing extra, so nothing looks
  broken.
- **System line** at the point of upgrade, on both sides, centred like the "Today" divider:
  `(shield) Messages from here on are quantum-safe`. Tapping it opens the explainer (11.7).
- **Key change:** `(shield) aurora.kachat's quantum-safe key changed`, tappable for what it means.
- **Message details:** the message's long-press sheet (`MessageActionsSheet`) gets an "Encryption"
  line, either "Quantum-safe" or "Standard". No badge on every bubble.
- **"Update KaChat to read this message"** bubble for unknown types (an old app on another device),
  with an **Update** button to the App Store.
- **"Waiting for keys…"** for a type-2 message whose setup isn't fetched yet (7.2). It resolves by itself.

### 11.3 Settings > Security > Quantum-Safe Chats

```
Quantum-Safe Chats                    On  >
```

Detail screen:

```
[x] Upgrade my chats automatically

Your key        Published Nov 6, 2026
                (or: Publishing… / Waiting for KAS / Not published)
Chats           12 of 18 quantum-safe

Chats upgrade by themselves once both people have
updated KaChat. Messages sent before can't be
upgraded.  Learn More

Advanced
  Reset Quantum-Safe Key         (red, confirmation)
```

- The switch only controls whether this account **starts** upgrades. A key already on chain can't be
  removed, so people can still start quantum-safe chats with you, and you still read them. The footer
  says so when the switch is off and a key exists.
- **Reset Quantum-Safe Key** publishes a new `kid` after a confirmation: "Only do this if you think
  someone has your seed phrase. Your contacts will see that your key changed." This is the one place
  that asks for Face ID, the same as delete.
- On iOS earlier than 26 (if v1 requires it, section 13): the row reads "Needs iOS 26" with a short
  explanation, and the switch is disabled.

### 11.4 Contact info (`ChatInfoView`)

An "Encryption" row under the address:

- **Quantum-safe** (shield), "since Nov 6, 2026",
- **Standard** with the footnote "aurora.kachat's app hasn't turned on quantum-safe chats yet. This
  chat upgrades by itself when it does." No nagging, no prompt to message them about it.

### 11.5 Sending money

- The Review screen is unchanged unless this payment is the one that upgrades the chat. Then one quiet
  line under the network fee reads "Includes a one-time quantum-safe setup", and the fee shown already
  includes it.
- Messages have no review screen, so their small one-time extra isn't shown.

### 11.6 Groups

Group info gets an "Encryption" row:

- **Quantum-safe**
- **Standard**, with "2 members need to update KaChat" (tap to list them), or, for the admin when
  everyone is ready, a **Make Group Quantum-Safe** button:

```
Make this group quantum-safe?

New messages will use new keys that future
computers can't break. Earlier messages stay
as they are. Each member gets a new key
message (about 0.002 KAS each).

[ Make Quantum-Safe ]   Cancel
```

- Afterwards both admin and members see the system line `(shield) This group is now quantum-safe`.
- Adding a member who has no key shows: "aurora.kachat's app can't receive quantum-safe keys yet.
  Adding them makes this group use standard encryption until you upgrade it again." [Add Anyway] [Cancel]

### 11.7 Explainer and Help

One sheet (from the system lines, Settings "Learn More", and contact info), also added to Help:

- **What it protects:** messages, photos, voice notes, payment memos and group chats sent from now on.
- **What it doesn't:** messages sent before; who you talk to and amounts, which are public on any
  blockchain.
- **Why it's needed:** messages stay on the network forever, and future quantum computers could break
  today's encryption.
- **Cost:** a one-time fee per account and per chat. After that, messages cost the same as before.

### 11.8 Localisation and accessibility

Every string goes into all `*.lproj/Localizable.strings` in the app and the push extension. The shield
gets the label "Quantum-safe". The system lines are read as one element. Nothing relies on colour alone.

## 12. Rollout

Every phase ships on iOS first and is then ported, per the existing cross-client rule. A phase that
**sends** something new waits until every KaChat client **reads** it.

1. **Readers everywhere:** the magic, types 1 to 4, `K_self`, `pq_key` verification, the "Update KaChat to
   read this message" bubble. Nothing new is sent yet.
2. **Self-sealed data:** new `self_stash` notes and the admin recovery copy sealed with `K_self`. Safe
   once Android and Desktop read it, because the same seed may be open there.
3. **Keys:** publish `pq_key` (11.1, 11.3). Still no upgraded chats.
4. **1:1 upgrades:** setups, type-2 messages, payments, `dm`, contact info and chat UI.
5. **Groups v2:** random epoch roots, "Make Group Quantum-Safe".

Kasia isn't a KaChat client. Chats with Kasia users simply never upgrade, and that's fine.

## 13. iOS implementation notes

- **CryptoKit:** `XWingMLKEM768X25519.PrivateKey(seedRepresentation:publicKey:)`,
  `PublicKey(rawRepresentation:)`, `publicKey.encapsulate()` returns the shared secret and the
  encapsulated ciphertext, and `privateKey.decapsulate(_:)` returns a `SymmetricKey`. All iOS 26 and
  later.
- **Deployment target is iOS 16.** Only three things need X-Wing: publishing a key, encapsulating a
  setup, and decapsulating one. Thanks to the wraps (6.2, 6.3), every other device reads with symmetric
  crypto alone. **Decision needed** (section 15): require iOS 26 for those three in v1, or bundle a
  vetted X-Wing implementation for iOS 16 to 25.
- **New code** (names indicative):
  - `QuantumSafe/QuantumSafeKeys.swift`: `K_self`, `pqSeed`, X-Wing keys.
  - `QuantumSafe/PQKeyDirectory.swift`: publish, fetch, verify, pin, cache.
  - `QuantumSafe/PQSessionStore.swift`: conversation keys per peer and `conv_id`, in the shared Keychain
    access group so the push extension can read them.
  - `KaChatCipher`: format dispatch (7.1) and the new seal and open paths.
- **Changed code:**
  - `ChatService` send paths: choose the format (6.1, 7).
  - Fetching: process setups first (7.2).
  - `GroupChatService`: v2 roots (9).
  - `KaChatNotificationService/NotificationService.swift`: read types 2 and 4 for banners.
  - Settings, contact info, chat header, system lines, Review footnote, onboarding line, Help.
- **Seed access:** `K_self` and `pqSeed` need the seed bytes. Derive them once, when the wallet loads
  from the seed phrase, and keep only the derived keys in the Keychain (same protection class as the
  private key). Never put the seed in the app group.
- **Push extension:** gets conversation keys and `K_self`-derived direction keys only, never the seed
  or `pqSeed`.

Android: BouncyCastle has ML-KEM; X-Wing is a small combiner on top and must match CryptoKit
byte for byte (test vectors). Desktop and extension: an audited JS ML-KEM and X-Wing library.

## 14. Later (not v1)

- **Quantum-safe signatures:** add an ML-DSA-65 key (`MLDSA65` in CryptoKit) to the `pq_key` record and
  sign key changes and group roots with it. This closes the forged-key-change gap in 5.3 once quantum
  computers exist.
- **Periodic re-key:** a fresh setup every N messages limits the damage of a stolen phone. It's not needed
  for the harvest problem itself.
- **Backup envelope v2** (4.1).

## 15. Decisions for the owner

1. **Existing accounts:** ask once with the sheet in 11.1 (recommended, because it spends a small fee),
   or turn on silently like new accounts?
2. **iOS 16 to 25:** require iOS 26 to publish and upgrade in v1 (recommended; simplest, and older
   devices still read through the wraps), or bundle an X-Wing library now?
3. **Upgrade trigger:** automatic on the next message (recommended), or an explicit "Upgrade chat"
   button?
4. **Groups:** admin taps "Make Group Quantum-Safe" (recommended, because it shows a cost), or upgrade
   automatically when all members are ready?
5. **Header shield:** show it on upgraded chats (recommended), or only in contact info?
6. **Order:** iOS phases 1 and 2 first and Android next (recommended), or wait to ship each phase on all
   clients together?

## 16. Testing

- Test vectors for `K_self`, `pqSeed`, the X-Wing public key from a fixed seed, `conv_id`, `CK` and
  `K_dir`, shared by every client.
- Two simulators (A on iOS 26, B on iOS 26): setup, replies both ways, photos, voice, payments,
  `payment_notice`, `dm` first contact through Message Requests.
- A restores the seed on a fresh device and reads everything, including its own sends (the wrap).
  The same for B (decapsulation, then the type-4 wrap).
- A third device on iOS 18 with B's seed reads the chat after B's first reply.
- Both start at once (6.4); a key change (5.3); a forged record with a bad signature (ignored).
- An old app build shows "Update KaChat to read this message"; old messages still read.
- Low balance: the plain message still goes, and the upgrade waits.
- Push banners for type 2; Message Requests banners unchanged.
- Groups: v2 root, a restored admin, adding a member with no key, a member on an old client.
- Fees on testnet against section 10.
