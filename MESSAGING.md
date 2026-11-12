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

**Reading back your own sends**: a contextual message or payment memo is sealed to the recipient,
and the sender's seed can open it again. The sender makes the ECIES ephemeral private key
`e = HKDF-SHA256(ikm = chatting private key, salt = the message's 12-byte nonce, info = "kachat-sent-message-v1", 32 bytes)`
instead of random. On another device with the same seed: read the nonce from the message, work out
`e`, check its public key equals the message's ephemeral public key (a mismatch means an older or
another client's message, which can't be read), then ECDH `e` with the recipient's public key
(`02 || x-only`, from their address) and open the sealed box as usual. Nothing on the wire changes
and receivers do nothing different, so clients without this still read these messages; only their
own sends stay unrecoverable until they adopt it. Sends from before this used a random key and
can't be recovered.

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

**Key insight**: For self-stash messages, the mempool gives the **payload** first. The subscription only suggests the sender: anyone can seal a message under a contact's public alias and pay dust to the contact's address, so the message is shown only once the signatures on the transaction's inputs prove the contact sent it (`provenSender`, read from the REST API, a couple of seconds). Until then it falls back to the indexer, which files messages by the transaction's sender.

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

### Checking a received payment read from the REST API

A received payment read from the Kaspa REST API is shown only after its signatures check out,
so a lying or broken API can't put a payment in a contact's chat. The rules, the same on every
client (audits AND-042, XP-033, IOS-091, IOS-092):

1. **Rebuild the transaction from the REST fields**, every input included (the signature hash
   commits to all outpoints and sequences), version 0 or 1 (v1: no sig-op counts; outputs carry
   their covenant). An input the API left unresolved gets its spent output's address and amount
   from `GET /transactions/<previous_outpoint_hash>` (output `index`, read safely - a bad index
   is ignored, never a crash).
2. **Each standard key-address (P2PK Schnorr) input must carry a well-formed signature:** push
   65 bytes, a 64-byte signature and a sighash type. A blank, short or differently pushed
   signature script cannot be on chain and counts as a failure. A sighash type other than
   SIGHASH_ALL can't be checked: no answer. Other inputs (P2SH covenant spends, ECDSA) are not
   checked here.
3. **Verdict.** All checked signatures valid: show it, under a sender taken **only from an input
   whose signature was actually verified** - the first verified input that isn't ours. Never the
   first input overall: a skipped ECDSA or covenant-shaped input can be listed first by a forger
   who signs a second input of their own (IOS-094). Valid, but no verified input names a sender
   other than us: treat it as no answer (step 4). A failure: forged (dropped) **only if the
   REST fields rebuild the claimed transaction id** (v0: blake2b "TransactionID"; v1:
   TransactionV1Id over PayloadDigest and TransactionRest), because then the API described the
   transaction completely. If they don't, a field the signature covers is missing (the REST API
   returns no lock time or sequences) and there is no answer.
4. **No answer: two sources.** Our node proves the coins: it must list unspent coins from that
   txid paying our address exactly the amount. The node can't say WHO paid, so the sender comes
   from a second source the REST server can't speak for: the KaChat indexer's
   `GET /payments/by-receiver` row for that txid (read by the indexer from its own node). If the
   REST answer names a sender too, it must equal the indexer's. Only when the node AND the
   indexer agree is the payment shown, under the indexer's sender and without a memo (the
   payload is part of what could not be checked); such a node-confirmed payment may never
   replace a message already on file for that txid that we sent (IOS-096). Otherwise hold it:
   every held txid is due on every payment sync (on the first history page or not), re-read by
   id and checked again, for up to 7 days.

## Payload Encryption

### Contextual Messages

Uses ECIES (Elliptic Curve Integrated Encryption Scheme, see `KasiaCipher`):
1. Generate ephemeral key pair
2. ECDH (secp256k1) with recipient's public key → shared secret
3. Derive encryption key from shared secret via HKDF-SHA256
4. ChaCha20-Poly1305 encrypt the message
5. Output: `ephemeral_pubkey || nonce || ciphertext || tag`

### Photos and voice notes: the binary media frame

Since KaChat iOS 5.2.2 (2026-10-22) a 1:1 photo or voice note is NOT encrypted as its
media-file JSON text. That JSON carried the file as a base64 data URL, and the whole ciphertext
was base64'd again into the payload - about 40% of the bytes on chain were encoding. The
plaintext handed to the cipher is now a binary frame holding the raw file bytes:

```
0xFF 0x4B 0x43 0x4D 0x01            magic: 0xFF "KCM" version 1
u32, big-endian                     length of the header JSON in bytes
header JSON (UTF-8)                 {"mimeType":"image/jpeg","name":"photo.jpg","size":20072}
raw file bytes                      the JPEG / WebM-Opus exactly, no base64
```

- Applies to the media-file JSON (`{"type":"file",...,"content":"data:<mime>;base64,..."}`)
  of `image/*` and `audio/*` types only. Every other message stays UTF-8 text.
- Groups (since 2026-11-11): voice notes only, as the `gcomm` plaintext ("In group chats" below).
- The payload around it is unchanged: `kchat:1:comm:<alias>:<base64(encrypted)>` (or the `dm`
  form), so indexers and push need no change.
- Reading: decrypt to BYTES first. If they start with the magic, rebuild the media-file JSON:
  `{"type":"file","name":"<name>","size":<raw byte count>,"mimeType":"<mime>","content":
  "data:<mime>;base64,<base64 of raw>"}`, and treat it exactly as the text form from then on.
  Otherwise decode UTF-8 as before. 0xFF never begins UTF-8, so the two never collide.
- Sizes (iOS): a photo's size is chosen at send time (High, Medium or Low, up to 1, 0.5 or
  0.1 KAS), and one bigger than a transaction goes as several messages ("Photos: quality tiers
  and multi-part photos" below). A voice note is up to
  14.5 s / 31 KB per message: 16 kbps CBR Opus in 60 ms frames since 2026-11-11 (6 kbps in
  20 ms before), and longer notes go as several messages (below). A client that predates the
  frame fails to decode it as UTF-8 and shows nothing (or "[Encrypted message]") - Android and
  Desktop must read it to show iOS photos.
- iOS: `ContextualMediaFrame` (KaChatCipher.swift); sent by `encryptContextualMessage`,
  read by `KasiaCipher.decrypt` and the push extension's `mediaFrameEnvelope`.

### Photos: quality tiers and multi-part photos

Since 2026-11-11, iOS asks for a quality when an on-chain photo is sent, in 1:1 chats and in
groups (`PhotoQualitySheet`). The Nextcloud route (full quality, uploaded) never asks. Each
tier is a fee budget, and it buys the largest JPEG whose parts' fees add up to no more than
that. Older and other clients may show these photos broken or blank (the owner accepted this).

- **Tiers:** High, up to 1 KAS; Medium, up to 0.5 KAS; Low, up to 0.1 KAS. The sheet shows each
  tier's real fee once the photo has been compressed for it (off the main thread), and "Up to
  …" until then.
- **Byte budgets (`PhotoTier.maxBytes`):** the exact largest total, rounded down about 0.5% for
  header length and extra-input slack:

  | Tier | 1:1 bytes | parts | 1:1 fee | Group bytes | parts | Group fee |
  |---|---|---|---|---|---|---|
  | High | 368,000 (exact 369,799) | 12 | ~0.995 KAS | 243,000 (exact 244,047) | 12 | ~0.996 KAS |
  | Medium | 184,000 (exact 184,904) | 6 | ~0.498 KAS | 121,500 (exact 122,038) | 6 | ~0.498 KAS |
  | Low | 36,000 (exact 36,635) | 2 | ~0.098 KAS | 23,500 (exact 24,013) | 2 | ~0.098 KAS |

- **One part's fee, for a chunk of R bytes** (2 grams of transient mass per transaction byte,
  100 sompi a gram, 272 bytes of input and output, a ~142-byte tagged header):
  - **1:1:** payload = 26 + 4 x ceil((9 + header + R + 61) / 3) in `kchat:1:comm:`. A full
    31,000-byte chunk is a 41,638-byte payload, mass 83,820, 0.0838 KAS.
  - **Groups:** payload = 391 + 2 x (9 + header + R + 16) in the unchanged `gcomm` payload. A
    full 21,000-byte chunk is a 42,719-byte payload, mass 85,982, 0.0860 KAS.
- **Compression (iOS, `ImagePrep.prepareJPEGForTiers`):** the image is re-rendered into a fresh
  bitmap, so orientation is applied and no EXIF, GPS or camera metadata is kept.
  - It picks the largest long edge (3000, 2560, 2240, 2048, 1920, 1600, 1440, 1280, 1080, 960,
    800, 640, 480 or 360 px, never upscaled) at which JPEG quality 0.5 fits the budget.
  - It then takes the highest quality up to 0.85 that still fits at that edge.
  - It goes below 0.5 only at 360 px.
- **Multi-part:** a photo bigger than one part (31,000 bytes in 1:1, 21,000 in groups) is cut
  into raw byte chunks. Each chunk goes as its own message, one transaction each, in index
  order through the send queue, after a balance check for all parts. Each chunk is a binary
  media frame whose header carries `"mediaPart":{"count":N,"id":"<random 16-byte hex>","index":i}`
  (the voice tag, under its own key). The rebuilt media-file JSON carries it between
  `mimeType` and `content`, and part files are named `photo-<i>of<N>.jpg`. The rules are the
  voice tag's: count 2...12, index 1...count, a hex id of 16 to 64 characters, image types
  only, and a malformed tag means a plain photo. A photo of one part is an ordinary untagged
  photo.
- **Reassembly:** join the chunks in index order **only once all N are present**, then decode.
  Until then, show one placeholder bubble ("Receiving… N of M") at the earliest part's place.
- **One message everywhere, as for long voice notes:**
  - Parts belong together by sender (and group id in a group), `id` and `count`.
  - Status is combined, Retry resends only failed parts, and Delete removes all parts.
  - Reply, react and the explorer link use part 1.
  - Unread and the chat list count it once, and only the first part to arrive rings.
  - Save, share and full screen use the joined image.
- **Groups:** photos are now the binary media frame too (`GroupChatService.groupPlaintextData`),
  inside the unchanged `gcomm` payload.
- **Android and Desktop must:**
  - Read the frame in group plaintext.
  - Group `mediaPart` chunks, join them in order once all are there, and decode the JPEG.
  - Show one bubble with "Receiving… N of M" until then.
  - Count, ring, retry and delete the photo once, as above.

### Long voice notes (multi-part)

Since 2026-11-11 iOS sends on-chain voice notes at **16 kbps CBR Opus in 60 ms frames**, in
1:1 chats and in groups (group format below). A note is as long as 1 KAS of fees allows:
**2:50 in 1:1, 1:50 in groups**. A note longer than one part is split into parts, and each part
is sent as its own ordinary voice message, one transaction each, in the binary media frame (in
groups, inside the `gcomm` payload: see below). A note of one part's length or less is still
one message with no tag. Nextcloud voice notes are unchanged.

- **Each part is a complete WebM-Opus file**, playable on its own. Each part's encoder is
  also fed the codec's 312-sample look-ahead from the next part, and the part's Info Duration
  states its real length. A reader that drops each part's pre-skip and cuts it to that
  duration joins the parts with no gap.
- **Part layout at 16 kbps:**
  - libopus 1.5.2 CBR makes each 60 ms packet (12 x 16000 / 8 + 100) / 200 = 120 bytes.
  - A SimpleBlock is 1 ID + 1 size + 4 header + 120 = 126 bytes.
  - Each Cluster of 16 packets costs 10 bytes, and the headers 155.
  - A part of T seconds is N = ceil((T x 48000 + 312) / 2880) packets and
    155 + 126 N + 10 ceil(N / 16) bytes.
- **1:1 limits:**
  - **Part length 14.5 s.** The cap is 31,000 bytes: N <= 243 (244 packets is 31,059 bytes),
    so T <= 14.57 s. A full part is 242 packets, 30,807 bytes.
  - **Note length 170 s (2:50).** A full part is a ~41,386-byte payload (frame, ECIES and
    base64 in `kchat:1:comm:`). Its mass is 2 x (payload + 272 bytes of input and output) =
    83,316, so 0.0833 KAS. 12 full parts (174 s) are 0.9998 KAS and a 13th would pass 1 KAS,
    so the note is 174 s rounded down to 5 s.
- **Fees in 1:1:**

  | Note | Parts | Fee |
  |---|---|---|
  | one full part (14.5 s) | 1 | 0.0833 KAS |
  | 60 s | 5 | 0.346 KAS |
  | 120 s | 9 | 0.691 KAS |
  | 170 s (max) | 12 | 0.977 KAS |
  | 175 s (not allowed) | 13 | 1.007 KAS |
- **Parts per note:** at most 12, a strict bound readers enforce. Both paths' longest notes
  need exactly 12.
- **The tag:** every part carries
  `"voicePart":{"id":"<random 16-byte hex>","index":<1-based>,"count":<N>}`. It goes in the
  frame's header JSON, and in the media-file JSON rebuilt from it, between `mimeType` and
  `content`:
  `{"type":"file","name":"voice-2of12.webm","size":30807,"mimeType":"audio/webm","voicePart":{"id":"…","index":2,"count":12},"content":"data:…"}`.
  Part files are named `voice-<index>of<count>.webm`.
- **Read it defensively:** `count` 2...12, `index` 1...count (integers), `id` hex of 16 to
  64 characters (compare it lowercased), audio types only. A part decodes to at most 25 s. A
  malformed tag means the message is a plain single voice note. Parts belong together when
  they have the same sender, `id` and
  `count`.
- **Sending (iOS):** the balance for all parts is checked before the first goes out. The parts
  then go out in index order, one after another through the send queue, so each one spends the
  previous one's change. Parts never carry a reply envelope, which would take them off the
  frame and past what one transaction holds.
- **Fallback:** a client that doesn't know the tag ignores the unknown key and shows N
  separate, playable voice notes in order. Android, Desktop and older iOS builds do this today.
- **What Android and Desktop must do to show one bubble:**
  - Collapse parts with the same (sender, id, count) into a single audio bubble, at the time
    and position of the earliest part, and hide the other rows.
  - Show the total duration and one scrubber. Play gaplessly: decode each part to PCM in index
    order, drop each part's pre-skip, cut it to its Info Duration, and concatenate.
  - While parts are missing, play what's there in order and say so ("Receiving… 7 of 12").
  - Outgoing: one status for the note (any part failed means Failed, then Sending). Retry
    resends only the failed parts.
  - Reply and react target part 1 (the earliest). Delete removes every part.
  - The chat list, unread counts and notifications count the note once: only the first part
    to arrive bumps unread and rings.
- **iOS notifications:** the push extension lets the first part to arrive ring and count.
  Without the `com.apple.developer.usernotifications.filtering` entitlement (the extension
  doesn't have it) a later part can't be withheld. It is delivered passive instead (no sound,
  no screen wake, no badge) in the same thread, and the quiet notification of the part before
  it is removed. That leaves at most the first banner and one quiet entry per note
  (`voice_part_banners` in the App Group). In the foreground the app lists such a push without
  a banner (`kachat_quiet_voice_part`). Multi-part photos (`mediaPart`) work the same way.
- **Parts arrive as bare txIds:** a part is too big for the push payload, so the extension reads
  it from the Kaspa REST API to find its tag. The push often beats the API to the transaction,
  so the read retries for up to 20 seconds (`fetchTransactionPayload`). A payload-less push that
  still can't be read joins its sender's burst (`part_push_bursts`: by sender in 1:1, by
  blinded group id in groups): one that follows another within 60 seconds is delivered quiet,
  as a later part would be. Two separate large messages sent within a minute ring once; the
  app still shows both.
- iOS: `VoicePartTag` / `VoicePartGrouping` (Models.swift), `WebMOpusEncoder.encodeParts`
  (ChatDetailView.swift), `ChatService.sendVoiceNoteParts`, and
  `WebMOpusDecoder.decodePartsToPCMFile` with `LazyMultipartAudioBubble` (MessageBubbleView.swift).

#### In group chats

Since 2026-11-11 every group voice note, short or long, is sealed as the **binary media frame**
above (`0xFF "KCM" 0x01`, header JSON, raw WebM bytes) in place of the base64 media-file JSON.
**Older and other clients (Android, Desktop, older iOS) can't read these until they're
updated:** they show nothing or a blank bubble. The owner accepted this. Group photos and
every other group message stay UTF-8 text.

- **Wire:** the outer `gcomm` payload is unchanged:
  `kchat:1:gcomm:<blinded id>:<epoch>:<sender id>:<sender key>:<msg id>:<ciphertext hex>:<signature>`.
  Only the ChaCha20-Poly1305 plaintext changed: the frame instead of the JSON text. The indexer
  and push server see nothing different.
- **Reading:** decrypt to bytes first. If they start with the magic, rebuild the media-file
  JSON as in 1:1 (with `voicePart` when the header has a valid one). Otherwise decode UTF-8 as
  before, so old text-form group notes keep playing. iOS: `GroupCipher.decryptMessage`, and the
  push extension's `NotificationGroupCipher.decryptMessage`.
- **The tag** is in the frame header JSON, as in 1:1:
  `{"mimeType":"audio\/webm","name":"voice-2of12.webm","size":20024,"voicePart":{"count":12,"id":"…","index":2}}`.
  Parts belong together by (group id, sender, `id`, `count`), with the same parsing rules.
- **Encoding (iOS):** 16 kbps CBR in 60 ms frames, as in 1:1. Parts are at most 9.8 s and
  21,000 bytes of WebM. A note of one part's length or less is one untagged message. The old
  6 kbps / 20 ms layout is left only for the Nextcloud route's on-chain fallback.
- **Cost of a part of R bytes:**
  - Plaintext: 9 bytes of magic and length + ~142 of header + R.
  - Payload: ~391 + 2 x (151 + R + 16) bytes, about 2 payload bytes per audio byte (2.67 with
    the old base64 JSON).
  - Mass: 2 x (payload + 272).
- **Group limits:**
  - **Part length 9.8 s.** The cap is 21,000 bytes: N <= 164 (165 packets is 21,055 bytes),
    so T <= 9.83 s. A full part is 164 packets, 20,929 bytes, a ~42,583-byte payload, mass
    85,710, so 0.0857 KAS.
  - **Note length 110 s (1:50).** 115 s would be 12 parts and 1.007 KAS.
  - The cap is about 42.7 KB of payload and 86,000 of the 100,000 mass ceiling.
- **Fees in groups:**

  | Note | Parts | Fee |
  |---|---|---|
  | one full part (9.8 s) | 1 | 0.0857 KAS |
  | 60 s | 7 | 0.528 KAS |
  | 110 s (max) | 12 | 0.964 KAS |
  | 115 s (not allowed) | 12 | 1.007 KAS |
- **Sending, grouping, playback, Retry, Delete, unread and notifications** work as in 1:1.
  On iOS: `GroupChatService.sendGroupVoiceNoteParts` (the balance for all parts is checked
  first) and `retryGroupVoiceNoteParts`. One bubble per note in `GroupChatDetailView`. Unread
  counts the note once (`unreadCount(for:)`). Only the first part to arrive posts a local
  banner. In the push extension, a later part's push is passive, in the group's thread.
- **Android and Desktop** must read the frame in group plaintext first, then group the parts
  as in 1:1, keyed by (group id, sender, `id`).

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

Cloud copies (the Nextcloud `kachat-contacts.json`, the older clients' shared
`kachat-backup.json`, and Android's per-account Google Drive files) are encrypted at rest. These are
the only cloud copies that exist; iOS keeps nothing in iCloud, and on iOS Nextcloud holds contacts only.

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

**Plaintext** depends on the file: the older clients' `kachat-backup.json` and an exported chat
archive hold the ChatHistoryArchive JSON, schema unchanged, including `desktopState` and any foreign
keys; iOS's `kachat-contacts.json` holds the Address Book export JSON (NEXTCLOUD_SYNC.md, "Contacts
only").

**Phantom rows**: a message whose `txId` is blank or carries a provisional `pending_` id
never reached the chain; exporters MUST NOT emit such rows, and mergers MUST drop them when
encountered in an existing file (they can never be connected to their delivered selves and
otherwise live in the union forever).

**Readers**: if the parsed top level has `kachatEncryptedBackup == 1`, decrypt then parse.
Writers ALWAYS encrypt. iOS refuses anything else: a plaintext `kachat-contacts.json` is never read
or overwritten, and a chat archive imported from a file must be an envelope, because nothing in a
plaintext archive is checked against the chain or a key. (Older clients may still read a legacy
plaintext `kachat-backup.json`.) For `kachat-contacts.json` the merge and overwrite rules are
NEXTCLOUD_SYNC.md's "Contacts only", not the archive merge below. Merge-on-upload becomes download, decrypt (if
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
- Text only. A payment notice, voice message, photo, chess move, reaction or any other
  envelope is never editable; an edit naming one is dropped. A **reply** is editable:
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
`ChatService.addMessageToConversation` and `GroupChatService` (next to the reaction branch). Public
chats left the iOS app; clients that still have them intercept edits on every room path too.

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
   - A bubble a notice filed is confirmed **only** by that notice's chain check. The app's generic
     incoming-payment handling (UTXO resolution, payment sync, warning retries) must never promote
     or move it: remember which txids a notice filed and leave them to the notice.
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

**Messages this account can't decrypt are stored but never shown.** A message that fails to
decrypt (typically one encrypted for another account that reached this contact's chat through
an account mix-up) is kept with the content `[Encrypted message]`, and a record with exactly
that content is hidden like the cross-device placeholder `📤 Sent via another device`: not in
the chat, not as the chat-list preview, not in search, never counted as unread, no banner. The
record stays, so a later successful decrypt replaces it (real content wins the dedupe) and the
message appears. The match is on the content itself (owner's decision on IOS-108: a contact
typing exactly `[Encrypted message]` is hidden too, an accepted quirk).

## Group keys on a device

A group's keys are stored per account, because two accounts on one device can share a group: deleting
one account, or the group on it, must not touch the other's keys. A listed group with no keys reads as
an empty thread, and normal catch-up can't fix that because its cursors are already past the root. So
the client drops that group's control and message cursors once per launch and walks them again: the
root rewrites the keys, still only from the admin on record, and the messages decrypt. Until then the
group is left out of the push watch list, while a Keychain read error still holds the whole update
back, so a passing failure can't drop a group from the server's list.

## When a send's outcome isn't known

A failed submit isn't always a failed send. If a node may have received the transaction and its answer
never came (a timeout or a dropped stream, not a connection that never opened or a rejection), look its
locally computed id up in the mempool and the REST API: first as for any failed submit, then 6 more
times, 3 seconds apart. If it still isn't found, the outcome is unknown, not failed. The send screen
says "Not confirmed" and "This may have gone through, but the network didn't confirm it. Check your
balance before sending again.", and offers only Done. A chat payment's bubble still reads as failed
until a delivered copy replaces it. A fresh change address is revealed anyway, since the change may be
on it, and a quantum source counts as spent.

A send still pending from before the app last started has nothing left working on it. After an account's
first full sync of a run, its delivered copy replaces it, and anything left is marked failed so Retry
appears. A delivered copy arriving later still replaces it.

## Signed rosters

A `gctl_root`'s `sig` leaves out `members` and `name`, so a member could resend the admin's root with
either one edited. Roots now also carry two optional fields, and `v` stays 1:

- `roster_version`: a number that only goes up. Writers use the time in milliseconds, or the last
  version this device saw plus 1 if that's higher.
- `roster_sig`: hex Schnorr signature by `admin_signing_pub` over these bytes, with every integer an
  8-byte little-endian value:
  `0x01 || "gctl_roster" || group_id (raw) || epoch || roster_version || member count || for each
  member: byte length, bytes || name byte length, name bytes`. Members are the UTF-8 of each lowercased
  address, sorted by those bytes. The name is the UTF-8 of `name` exactly as sent.

Every root an updated client writes carries both, including the self-addressed recovery root.

**Reading**, after `sig` verifies:
1. **Either field present:** verify `roster_sig`, and refuse the root if it's missing or fails. Never
   fall back to rule 2, or editing a signed root would work. The sender doesn't matter.
2. **Neither present:** the sender must be blank or equal the address derived from `admin_signing_pub`
   (version 0, the network's prefix, ignoring case). Blank is allowed because the by-recipient endpoint
   returns no sender until the indexer has resolved one.
3. **Pin:** store the highest `roster_version` applied, per account and group. A root for an older epoch
   only archives that epoch's key, as before. For the same or a newer epoch, a root that's unsigned or
   has a lower version than the pin can't change the name or members: at a newer epoch apply its keys
   and keep the stored name and members, and at the same epoch refuse it. Keys need no such check,
   because only the admin can sign them.
4. **Invites:** a held invite's signed root isn't replaced by an unsigned or lower-version root for the
   same epoch.

**Limits.** The pin only protects a device that has already seen a signed root. A new invitee or a
device restoring from its seed falls back to rule 2 until one arrives. Rule 2 stays weak: a blank sender
passes, and the live block scan reads the sender from the first output, which the transaction's builder
chooses. Those gaps close only once every client signs and unsigned roots can be refused. A device
without a pin can also be shown an older signed roster, since it's still genuinely the admin's. iOS's
push extension doesn't check `roster_sig` for the group name in an invite banner.

## Group invites

Being sent a `gctl_root` for a group this wallet doesn't hold is only an invite: it waits in Message
Requests until the user answers. A wallet's own groups (the root names it as admin) aren't invites.

A group id isn't tied to its admin: `verifyRootPayload` only proves a root agrees with its own
`admin_signing_pub`, and anyone who knows an id can sign a root for it. So an invite is one admin's
offer of one id, keyed `{group_id}:{admin_signing_pub}` in lowercase hex. Two admins' roots for an id
are two invites, each shown with who sent it, and neither can block the other. Accepting one drops
the others, because a device holds one group per id. A group the device already holds keeps its admin,
and roots for it signed by anyone else are refused. Lowercase a root's `group_id` and
`admin_signing_pub` when it arrives, so an uppercase copy can't pass for a different group.

No server change: everything below travels as ordinary `gctl` and `gcomm` transactions. Each answer
costs a network fee, and one that can't be sent yet is retried at the next catch-up.

**Accept** sends two transactions:
1. A self-addressed `gctl` signed by the wallet's key: `{"type":"gctl_invite_accept","v":2,"group_id","admin_signing_pub","signing_pub","sig"}`,
   where `sig` is Schnorr over `v (1 byte) || "gctl_invite_accept" || group_id (raw bytes) || admin_signing_pub (32 raw bytes)`.
   Honoured only when `signing_pub` is this wallet's own key. A device holding this joins the group
   with no further question, whether the root arrives before or after it, but only from that admin.
   A root from anyone else for the same id is an ordinary invite. v1 (no admin) is ignored.
2. A `gcomm` group message with the plaintext `{"type":"member_status","status":"joined"}`.

**Reject** sends two transactions:
1. A self-addressed `gctl_tombstone` v2, so this admin's offer is never made again:
   `{"type":"gctl_tombstone","v":2,"group_id","signing_pub","admin_signing_pub","sig"}`, where `sig` is
   Schnorr over `v (1 byte) || "gctl_tombstone" || group_id (raw bytes) || admin_signing_pub (32 raw bytes)`.
   Deleting a group publishes the same v2 marker for that group's admin. A v2 marker removes a held
   group only if its admin matches. A v1 marker (no `admin_signing_pub`, signed without it) is still
   honoured and covers that id from any admin, but new ones are only sent when the admin isn't known.
2. The same `gcomm` with `"status":"declined"`, sent with the invite's root and a fresh device id.

A `member_status` message is never a bubble and never notifies. It's sealed and signed like any group
message, so only members can read it, its sender is proven and must be in the roster, and on chain it
looks like any other group message. A client that doesn't handle this type must hide it: unknown
group envelopes otherwise show as raw JSON. Any other message from a member also counts as joined.

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

## Call messages (ignored since 2026-11-11)

KaChat for iPhone has no voice or video calls: no CallKit, PushKit, WebRTC or Nextcloud Talk, and
it never sends a call message. Other clients (and older iPhone builds) may still send the call
envelopes as ordinary encrypted 1:1 messages: JSON objects whose `type` starts with `call_`
(`call_invite`, `call_request`, `call_response`, `call_end`). The iPhone app recognizes them by
that `type` alone (`CallSignal.isCallSignal` in Models.swift) and drops them on arrival
(`addMessageToConversation`): no bubble, no unread count, no notification, never raw JSON. One an
older build already stored is hidden like the other placeholders (`ChatMessage.isHiddenPlaceholder`).
The notification extension silences their pushes the same way (`isCallSignal` in
NotificationService.swift). Nothing ever answers them, so a caller on another client rings out.

