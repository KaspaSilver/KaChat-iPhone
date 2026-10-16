# Kasia Messaging Protocol

This document explains how messaging, payments, and handshakes work in Kasia on the Kaspa blockchain.

## Core Concepts

### Self-Stash Pattern (Contextual Messages)

Messages in Kasia are NOT sent as direct transfers to recipients. Instead, they use a **self-stash** pattern:

1. **Sender creates a transaction spending their own UTXOs**
2. **Output goes back to the sender's own address** (self-spend)
3. **Message payload is embedded in the transaction**
4. **Recipient monitors sender's address** via UTXO subscriptions

This pattern allows:
- Zero-cost messaging (only transaction fee, no transfer)
- Messages are stored on the sender's "stash" (their address history)
- Recipients can't be spammed (they choose who to subscribe to)

### UTXO Subscriptions

The app subscribes to UTXO changes for:
- **Our own address**: Detect incoming payments and handshakes
- **All contacts' addresses**: Detect when they send messages (self-stash)

When a UTXO notification arrives, we know:
- **Which address** the UTXO is for
- **Transaction ID**
- **Amount**
- **Whether UTXOs were added or removed**

## Transaction Types

### 1. Contextual Messages (Self-Stash)

**Direction**: Sender's address → Sender's address (self-spend)

**Payload format**: `kchat:1:comm:<alias>:<base64_encrypted_message>` (legacy root `ciph_msg:1:comm:` still accepted on read)

**First contact**: the sender's first message to someone who has never written to them is
`kchat:1:dm:<inboxTag>:<alias>:<base64_encrypted_message>` instead - a `comm` message plus the
recipient's inbox tag, so the recipient's app can find it (no handshake needed).
`inboxTag = lowercase hex of the first 16 bytes of SHA-256(UTF-8("kachat-inbox:v1:" + recipient))`,
`recipient` being the full lowercased address with its prefix. Readers normalise it to `comm` by
dropping the tag; everything after the tag is identical. Only that one message carries the tag.
Full rules (when to tag, the indexer's inbox endpoint, Message Requests):
`NO_HANDSHAKE_MESSAGING.md`.

**Flow**:
```
1. Alice wants to send message to Bob
2. Alice creates TX spending her UTXOs
3. Output goes back to Alice's address (minus fee)
4. Payload contains encrypted message for Bob
5. Bob subscribes to Alice's address
6. Bob receives UTXO notification: "Alice's address has new UTXO"
7. Bob fetches TX payload (via mempool RPC or REST API)
8. Bob decrypts and checks if message is for him
```

**UTXO Notification contains**:
- `address`: Sender's address (Alice)
- `transactionId`: TX ID to fetch payload
- `amount`: Self-stash amount

**What we DON'T need from REST API**:
- Sender address (we know from subscribed address)
- Just need the **payload** for decryption

### 2. Payments

**Direction**: Sender's address → Recipient's address

**Payload format**: `kchat:1:pay:<encrypted_memo>` (optional memo; legacy root `ciph_msg:1:pay:` still accepted on read)

**Flow**:
```
1. Alice sends KAS to Bob's address
2. Bob receives UTXO notification for HIS address
3. Bob sees incoming funds immediately
4. Bob needs to resolve TX to find sender (Alice)
```

**UTXO Notification contains**:
- `address`: Bob's address (our address)
- `transactionId`: TX ID
- `amount`: Payment amount

**What we NEED from REST API**:
- **Sender address** (not in UTXO notification for incoming payments)
- Payload (if any memo attached)

### 3. Handshakes

**Direction**: Sender's address → Recipient's address (payment-style)

**Payload format**: `kchat:1:handshake:<encrypted_handshake_data>` (legacy root `ciph_msg:1:handshake:` still accepted on read)

Handshakes are structurally similar to payments but carry encrypted public key exchange data in the payload. They establish the shared secret for future encrypted messaging.

**Flow**:
```
1. Alice wants to start conversation with Bob
2. Alice sends ~0.2 KAS to Bob's address with handshake payload
3. Bob receives UTXO notification for his address
4. Bob resolves TX to get sender and payload
5. Bob decrypts handshake to extract Alice's public key
6. Bob can now decrypt Alice's messages
7. Bob sends reciprocal handshake to complete key exchange
```

**What we NEED from REST API**:
- **Sender address** (critical for key exchange)
- **Payload** (encrypted handshake data)

### 4. Saved-handshake notes (contact recovery)

**Direction**: your address → your own address (fee only; the partner is not in the transaction)

**Payload format**: `kchat:1:self_stash:saved_handshake:<encrypted to your own key>`

How a freshly imported seed finds its chats again: the indexer serves these by owner
(`/self-stash/by-owner`, scope `saved_handshake`) and `fetchSavedHandshakes` decrypts each one.
Two shapes:

- **Handshake note** (`"type": "handshake"`), written with every handshake: `alias`,
  `theirAlias`, `partnerAddress`, `isResponse`.
- **Contact note** (`"type": "contact"`, 5.1), for a chat that never had a handshake
  (deterministic aliases): `partnerAddress` / `recipientAddress` only, no alias fields. Without
  it such a chat is invisible to a fresh import - its messages carry aliases derived from both
  keys, and an alias cannot be turned back into an address. The reader derives the
  deterministic pair from the address (`ensureRoutingState`) and fetches the chat.

iOS writes a contact note once per contact, after your first sent message in a chat with no
handshake (`ChatService.ensureContactStash`), and backfills old chats you have sent in after
each complete read-back (`backfillContactStashes`) - never before one, so it never duplicates a
note already on chain. The indexer sees only ciphertext under your address. Other platforms:
read a note with no alias as "derive the deterministic pair for this address", and write the
same note under the same rules.

## Message Resolution Flow

### For Self-Stash Messages (Fast Path)

```
UTXO Notification: Contact's address has new UTXO
                          ↓
            We know sender = subscribed address
                          ↓
    ┌─────────────────────┴─────────────────────┐
    ↓                                           ↓
Mempool RPC                              REST API
(immediate)                           (1.5s delay)
    ↓                                           ↓
Get TX payload                         Get TX payload
    ↓                                           ↓
    └─────────────→ First wins ←────────────────┘
                          ↓
              Decrypt & verify message
                          ↓
              Display in conversation
```

**Key insight**: For self-stash messages, we only need the **payload**, not the sender (we already know it from the subscription).

### For Payments/Handshakes (Requires REST)

```
UTXO Notification: Our address has new UTXO
                          ↓
        Sender unknown (only our address in notification)
                          ↓
               REST API required
                          ↓
        Resolve TX inputs to find sender
                          ↓
    ┌─────────────────────┴─────────────────────┐
    ↓                                           ↓
Has handshake payload?                   Regular payment
    ↓                                           ↓
Process as handshake                  Show in conversation
```

## Payload Encryption

### Contextual Messages

Uses ECIES (Elliptic Curve Integrated Encryption Scheme, see `KasiaCipher`):
1. Generate ephemeral key pair
2. ECDH (secp256k1) with recipient's public key → shared secret
3. Derive encryption key from shared secret via HKDF-SHA256
4. ChaCha20-Poly1305 encrypt the message
5. Output: `ephemeral_pubkey || nonce || ciphertext || tag`

### Handshakes

Contains:
- Sender's public key (for key exchange)
- Sender's alias/name
- Encrypted with recipient's public key

### Payments (optional memo)

Same encryption as contextual messages, but attached to a value transfer.

## UTXO Subscription Strategy

```swift
addressesToSubscribe = [
    myAddress,                    // Incoming payments, handshakes
    contact1.selfStashAddress,    // Contact 1's messages
    contact2.selfStashAddress,    // Contact 2's messages
    ...
]
```

When we detect:
- **Our address + we're NOT spending** → Incoming payment/handshake
- **Contact's address + contact IS spending** → Self-stash (message to us)
- **Contact's address + WE are spending** → Outgoing payment to contact

### Subscription Loss and Backstops

The `utxosChanged` subscription is server-side state tied to the gRPC stream: a transparent
reconnect silently drops it while the connection still answers pings. iOS re-sends the
subscription whenever the connection generation changes (see `UtxoSubscriptionManager`) and
runs a catch-up sync for the gap. Independently of that, every platform runs a foreground
indexer poll over contacts as a backstop (desktop 5s, Android 2s, iOS 5s sequential sweep),
plus a 60s fallback poll when the subscription is down and push is off. All paths dedupe by
`txId` on insert.

There is no per-contact "disable realtime" flag or spam detector on any platform.

## Encrypted Backup Envelope (v1)

Cloud copies of the chat archive (the shared Nextcloud `kachat-backup.json` and Android's
per-account Google Drive files) are encrypted at rest. These archives are the only cloud copies
that exist; iOS keeps nothing in iCloud.

**Envelope** (the file's entire content):

```json
{
  "kachatEncryptedBackup": 1,
  "cipher": "aes-256-gcm",
  "nonce": "<base64, 12 random bytes, fresh per write>",
  "ciphertext": "<base64, AES-256-GCM ciphertext with the 16-byte tag appended>",
  "walletHint": "<first 8 bytes of SHA-256(walletAddress), hex>"
}
```

**Key derivation** (identical on every platform):
`key = SHA-256( identity_private_key_bytes || UTF8("kachat-backup-v1") )` where
`identity_private_key_bytes` is the raw 32-byte private key of the chatting/identity address
(m/44'/111111'/0'/0/0). Any device holding the seed derives the same key; nothing else can
read the archive.

**Plaintext** is the existing ChatHistoryArchive JSON, schema unchanged, including
`desktopState` and any foreign keys.

**Phantom rows**: a message whose `txId` is blank or carries a provisional `pending_` id
never reached the chain; exporters MUST NOT emit such rows, and mergers MUST drop them when
encountered in an existing file (they can never be connected to their delivered selves and
otherwise live in the union forever).

**Readers**: if the parsed top level has `kachatEncryptedBackup == 1`, decrypt then parse;
otherwise treat as a legacy plaintext archive and parse as-is. Legacy files stay restorable
indefinitely; writers ALWAYS encrypt. Merge-on-upload becomes download, decrypt (if
enveloped), merge, encrypt, upload. `walletHint` lets a device skip a foreign wallet's file
without decrypting; the decrypted archive's own `walletAddress` is still validated as today.
A failed decrypt (wrong seed, corrupt file) aborts before any upload, never overwrites.

## Message Edits

A sender can edit their own earlier **text** message. Nothing on chain changes: the edit is a
new message whose content is this envelope, naming the original by txId:

```json
{"type":"edit","targetTxId":"<txId of the message being edited>","text":"the new text"}
```

It travels exactly like a reaction envelope - inside the normal encrypted contextual content
for 1:1 chats, inside the group-encrypted message for groups, and as the plaintext row content
for public chat rooms (`kchat:1:bcast:<channel>:{"type":"edit",...}`) - and is **never
rendered as a bubble**. Clients intercept it and show the newest edit's text in place of the
original, with a small "edited" mark. Rules, identical on every platform:

- Only the original sender's edits count. The editor is the transaction's sender (1:1: the
  decrypting party; group: the signed sender id; broadcast: the tx signer); an edit naming
  someone else's message is dropped. Clients also refuse edits on their own behalf unless
  the target is theirs.
- Newest by block time wins; an older edit replayed from history never overwrites a newer one.
- Text only. A payment notice, voice message, photo, chess move, call line, reaction or any
  other envelope is never editable; an edit naming one is dropped. A **reply** is editable:
  the edit's `text` replaces the reply's text and the quote is kept
  (`MessageEditCodec.apply`).
- `text` is capped at 4 000 characters. Unknown extra fields are ignored.
- No delete, and no edit window: any time.
- Storage is up to the client (iOS keeps a small edits table beside reactions in each store;
  the original row is never rewritten). The original stays on chain and in explorers.
- **No notification** for an edit - it changes an earlier bubble in place. Clients never
  banner it; push services must not push it (public rooms); the iOS notification extension
  blanks one that arrives anyway (1:1 and groups, where the server cannot see inside).

Reference implementation: `MessageEditCodec` in `Models.swift`; interception in
`ChatService.addMessageToConversation`, `GroupChatService` (next to the reaction branch) and
`PublicChatService` (scan, indexer page and sweep paths).

## Chat Payments From a Spending Address (`payment_notice`)

Every send screen has a **From**: the chatting address (the default) or one of the person's
spending addresses. A 1:1 chat payment From the **chatting address** is the normal chat payment
(`kchat:1:pay:` payload, memo sealed to the contact's chatting key), found by the payee's
payment detection as always.

A chat payment From a **spending address** is different: the payee has never seen that address,
so they can't tell which chat it belongs to (a `kchat:1:pay:` payload from it would open a
Message Request from a stranger on their side - XP-022). So:

1. **Payer.** The payment is a **plain transfer** (no payload) from the spending address to the
   contact's chatting address. Right after it is accepted, the chatting address sends a
   `payment_notice` in the 1:1 chat (an invisible envelope in the normal encrypted contextual
   content, like a reaction):

   ```json
   {"type":"payment_notice","txId":"a1b2...","amountSompi":123450000,"address":"kaspa:qq...","memo":"rent"}
   ```

   | Field | Type | Required | Meaning |
   |-------|------|----------|---------|
   | `type` | string | yes | Always `"payment_notice"` |
   | `txId` | string | yes | The payment's transaction id (64 lowercase hex) |
   | `amountSompi` | integer | yes | Amount paid, in sompi |
   | `address` | string | yes | The address paid: the **payee's chatting address** |
   | `memo` | string | no | The payer's note, at most 500 characters; omitted when empty. It travels only here |

   The payer's own bubble ("Sent X KAS - memo") is made by the send flow. If the notice fails
   to send, the payee still has the KAS (shown in their self-chat, below).

2. **Payee.** On a `payment_notice` in a 1:1 chat:
   - If `address` is not this wallet's chatting address, **drop it silently** (no bubble, no
     banner): it is an old app's fresh-address pool payment (see Retired, below).
   - Otherwise **check the chain first** (any contact can send a notice naming any public
     txid - IOS-083). The tx must pay this chatting address exactly `amountSompi`, carry **no
     payload** (a chat payment or a message is never a notice's payment), and none of its inputs
     may be **any address the person owns** or another contact's address. "Owns" means every
     address the app knows as theirs: the chatting address, every revealed spending address,
     every Cold Storage / KasSigner address and every other saved account's addresses (a
     top-up from one of them is public, and a contact must never claim it). A notice that fails
     is dropped.
   - If it passes, render an incoming payment bubble in **that chat**: "Received X KAS", or
     "Received X KAS - <memo>", transaction id = `txId`, timestamp from the notice's block time.
     Deduplicate by `txId`. A message with that txid already stored elsewhere may move into this
     chat **only** if it is an incoming payment from an address that is no contact and none of
     the person's own (a plain transfer shown in the self-chat with "From: <address>") - the
     first notice to claim it wins; check this again after the chain lookup, since another
     notice may have claimed it meanwhile.
     Never move or overwrite anything else: another chat's payment, a message, or anything we
     sent. A later payment fetch finds the txId present and does nothing.
   - No chain answer (not indexed yet, or **any** input whose address isn't resolved - it could be
     one of ours): never move an existing record. With nothing stored yet, show the bubble marked
     unverified (warning) and check again when the notice is read again; a re-check that says the
     claim is false removes that unverified bubble.
   - Notification: "Received payment", without the claimed amount.

3. **Payer's other devices.** An outgoing `payment_notice` read back from the indexer makes the
   outgoing payment bubble ("Sent X KAS - memo") in that chat if no message with `txId` exists.

KaPosts tips and payment-request payments (`chat=1`) sent From a spending address follow the
same rule. A plain transfer from an unknown address with no notice stays in the self-chat.

iOS: `ChatService+PaymentPools.swift` (`sendSpendingPaymentNotice`, `handlePaymentNotice`),
`sendPaymentInternal`, `PaymentPoolCodec` (Models.swift), the notification extension's
`isSilentPoolEnvelope`.

### Retired: Fresh-Address Payment Pools (until 5.2)

Up to 5.2 the apps offered contacts fresh spending addresses (`addr_pool`, `addr_pool_request`)
to pay into, with a `payment_notice` naming the pool address. Removed on 2026-10-13 (iOS 6333dd3,
Android 221172a5, Desktop 4c0f1b6). Now:

- Never send `addr_pool` or `addr_pool_request`. Receivers drop both silently (no bubble, no
  banner).
- Offered pools were not revoked. A contact still on 5.2 may pay one of our former pool
  addresses and send a `payment_notice` naming it. Owner decision (XP-023): that notice is
  dropped silently; the KAS is safe on our spending chain (Manage Addresses shows it) but no
  chat shows it. This ends as those contacts update.

## getMempoolEntry Usage

The `getMempoolEntry` RPC is used to speed up message delivery:

| Transaction Type | Need Sender? | Need Payload? | Use getMempoolEntry? |
|-----------------|--------------|---------------|---------------------|
| Self-stash message | No (known from subscription) | Yes | **Yes - primary path** |
| Incoming payment | Yes | Optional | No - REST API needed |
| Incoming handshake | Yes | Yes | No - REST API needed |

For self-stash messages, mempool RPC can reduce message latency from **2-4 seconds** (REST API indexing delay) to **~100ms** (immediate mempool query).

## Implementation Notes

### ChatService UTXO Handler

```swift
// Case 1: UTXO to our address, not us spending
if utxoAddress == myAddress && !weAreSpending {
    // Incoming payment or handshake
    // Need REST API to resolve sender
}

// Case 2: UTXO to contact's address
else if contactAddresses.contains(utxoAddress) {
    if weAreSpending {
        // Outgoing payment we sent
    } else if removedAddresses.contains(utxoAddress) {
        // Contact's self-stash - likely a message
        // Can use getMempoolEntry for fast payload retrieval
    }
}
```

### Message Decryption Filter

When we receive a self-stash notification, the message might not be for us:
- Sender could be messaging another contact
- We decrypt and check the recipient field
- If not for us, discard silently

## Transaction Payload Formats

Written prefixes use the `kchat:1:` root; the legacy `ciph_msg:1:` root is accepted on read for
every kind below (dual-read, write-new):

```
kchat:1:comm:<alias>:<base64_encrypted>       # Contextual message
kchat:1:dm:<inboxTag>:<alias>:<base64_encrypted>  # First-contact message: comm + the recipient's inbox tag (NO_HANDSHAKE_MESSAGING.md)
kchat:1:pay:<base64_encrypted>                # Payment with memo
kchat:1:handshake:<encrypted_hex>             # Handshake
kchat:1:self_stash:<data>                     # Self-stash metadata
kchat:1:bcast:<channel>:<content>             # Broadcast channel post (plaintext)
kchat:1:gcomm:...                             # Group chat message (see GroupCipher)
kchat:1:gctl:...                              # Group chat control message
```

## Fees

- **Message (self-stash)**: ~0.0001-0.001 KAS (depends on payload size)
- **Payment**: Standard Kaspa fee + tiny payload if memo
- **Handshake**: ~0.2 KAS transfer + standard fee

## Summary

| Operation | TX Direction | Payload | Sender from UTXO? | Fast Path? |
|-----------|-------------|---------|-------------------|------------|
| Send message | Self → Self | Encrypted message | Yes (subscription) | getMempoolEntry |
| Send payment | Self → Recipient | Optional memo | N/A (we're sender) | Immediate |
| Receive payment | Sender → Self | Optional memo | No | REST API |
| Send handshake | Self → Recipient | Key exchange | N/A (we're sender) | Immediate |
| Receive handshake | Sender → Self | Key exchange | No | REST API |

## Calls (5.0): Nextcloud Talk over the 1:1 channel

Voice and video calls never leave KaChat and need a Nextcloud on ONE side only. The caller's
Nextcloud (Talk installed, calls enabled - detected from `/ocs/v2.php/cloud/capabilities`
`spreed.features` incl. `conversation-v4`/`signaling-v3` and `config.call.enabled`) hosts a
throwaway **public** Talk conversation; the callee joins it as a Talk **guest** on that server,
so no account of their own is involved. Media is one WebRTC peer connection between the two
phones, negotiated over Talk's *internal* signaling API (the external HPB mode is refused with
a message). STUN/TURN come from the caller's server's `signaling/settings`.

Ringing is ordinary encrypted contextual messages, JSON like the chess envelopes, all carrying
the same `callId` (a UUID). **The caller is the only side that ever writes to the chain, and at
most twice per call**: one opening message and one closing message. The callee answers, declines
and hangs up through the Talk room itself (joining it, a `kachat_decline` signaling message, or
leaving it), never on chain.

A closed app cannot see the chain, so alongside the opening message the caller's phone asks
the push service to send the callee a **VoIP push** (`POST /v1/push/ring`, PUSH_EXTENSIONS.md
§5) carrying `call_id`, `kind`, `video`, the caller's address and a hex copy of that same
opening message encrypted to the callee. iOS wakes the callee's KaChat and it rings through
CallKit at once; the push's copy gives the room straight away when the keys are reachable, and
the chain message fills it in otherwise (the ringing call's `callId` matches, so the app knows
the invite is the one it is already showing). The push is best effort and carries nothing the
chain does not: no push, and an open app still rings off the chain message a little later.

**Multitasking camera (Picture in Picture in other apps).** iOS pauses an app's camera the
moment it leaves the foreground unless the App ID carries Apple's
`com.apple.developer.avfoundation.multitasking-camera-access` entitlement, granted on request
(developer.apple.com > Account > Additional resources > "Multitasking Camera Access" request
form; describe the video-call feature). Once approved: enable the capability on the
`com.kachat.app` App ID in the portal, add
`<key>com.apple.developer.avfoundation.multitasking-camera-access</key><true/>` to
`KaChat/KaChat.entitlements` and `KaChat/KaChatRelease.entitlements`, and let automatic signing
regenerate the profiles. The code is already in place (`WebRTCClient.startCaptureIfNeeded` sets
`isMultitaskingCameraAccessEnabled` whenever the session reports it supported); adding the
entitlement key BEFORE Apple grants it breaks signing, so it is deliberately not in the repo yet.

| Envelope | Sent by | Fields |
|---|---|---|
| `{"type":"call_invite"}` | the caller, when they host | `callId`, `server` (https base URL), `token` (room), `video` (bool), `viaRequest` (bool, optional - true when a host answers a `call_request`) |
| `{"type":"call_request"}` | a caller with NO Nextcloud | `callId`, `video` - asks the contact to host; if the contact's KaChat can host and their "Allow calls" switch is on for the requester, it opens a room, answers with a `call_invite {viaRequest:true}` (the one message a non-caller ever sends - the requester cannot learn the room any other way) and rings; the requester joins that room as a guest. A contact that cannot host stays silent and the request rings out. |
| `{"type":"call_end"}` | the caller, always | `callId`, `reason` (`hangup`, `remote_hangup`, `declined`, `no_answer`, `cancelled`, `failed`), `durationSeconds` (when it connected). Sent only after the caller's opening message went out. |
| `{"type":"call_response"}` | *legacy* - nothing sends it any more | `callId`, `accepted`, `reason`; still parsed so older clients' messages render |

**Who hosts.** A phone whose Nextcloud is connected always hosts its own calls: before falling
back to `call_request` it re-checks Talk on the server when the last answer is unknown or was a
failed lookup (a lookup that couldn't reach the server is not "no Talk"). Likewise a phone asked
to host re-checks before turning a request away.

**Hosting a request (the callee side).** Ring at once (so an Answer tapped while the room is
being opened finds the call), then open the room, check its signaling is internal (not the
external HPB), and only then send the `call_invite {viaRequest:true}` - again on a failed send.
The host also **pushes** that invite to the requester (`POST /v1/push/ring`, `kind:"invite"`) so
their phone joins without waiting for the chain; a requester already waiting for that call id
joins from the push and ignores the later chain copy. After Answer the other phone has 30 s to
appear in the room, then the call ends as failed ("X didn't join") instead of hanging on
"Connecting".

**Consent before ringing.** A call (VoIP push, `call_request`, or a non-`viaRequest`
`call_invite`) from someone whose "Allow calls" is off is ended or silenced on arrival, from a
list the push handlers can read before the wallet loads - never a ring or an "Incoming call"
banner first. Call messages are never wrapped as a reply.

So a hosted call costs the caller 2 messages whatever happens (answered: invite + "Call · 4:12";
declined / no answer / cancelled: invite + the reason); a requested call costs the caller 2 and the
host 1 (its invite). Callee-side events reach the caller through the room: appearing in the call =
answered; `kachat_decline` from the callee's guest session = declined; the callee leaving the
call = hang-up (the caller writes the duration); the host deleting the room = a declined request
(the waiting guest sees a 404).

Clients render these as call-history bubbles ("Voice call started", "Missed call", "Call
declined", "Call · 4:12"; a `viaRequest` invite is the neutral "Voice call ready") and never as
raw JSON. The call button is always there; Chat Info's per-contact switch (`Contact.callsEnabled`,
OFF by default, device-local) is the gate - the first tap on a not-yet-enabled contact asks
"Enable calls and video calls with X?" and saves the answer. While off, that contact's invites and
requests are ignored silently. A client keeps a persisted set of call ids it has handled so a
re-ingested invite/request never rings twice. An invite is only answerable for 45 s after its
block time; the callee's phone rings for 30 s and the caller gives up after 35 s with `no_answer`.

Call sequence (caller): `POST /apps/spreed/api/v4/room` (`roomType=3`) → `POST
/room/{token}/participants/active` (gives the Talk `sessionId`) → `POST /call/{token}` (`flags`
= 1|2|4) → send `call_invite` → long-poll `GET /api/v3/signaling/{token}` for `usersInRoom` +
peer `message`s, send offer/answer/candidates via `POST /api/v3/signaling/{token}`
(`messages=[{ev:"message",fn:<json>,sessionId}]`, `fn` = `{to,sid,roomType:"video",type,payload}`).
The peer with the larger Talk session id sends the offer (Talk web's tie-break); the other side
offers itself after 10 s of silence. Callee mirrors this unauthenticated (guest cookie session),
plus `POST /api/v1/guest/{token}/name`. On hang-up the caller leaves the call and conversation
and deletes the room.

