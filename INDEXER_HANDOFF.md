# Indexer hand-off from the iPhone app

The iPhone (Apple) session does not change kachat-indexer. Anything the indexer needs because of
an iPhone change is written here, and the indexer session picks it up when the owner says
"check iOS".

**For the indexer session:** work through the **Open** items in order. When one is done, move it
to **Done** with your kachat-indexer commit, and keep the app-side contract as written. If a
contract can't be met as written, say so to the owner rather than changing the app's side.

**For the iPhone session:** add an item for every app change that needs the indexer to store,
serve or check something new, or to change how it does. Say what the app sends and expects
(endpoint, request, response, rules) and which KaChat commit and spec file it comes from, so the
item stands on its own.

## Open

_Nothing open._

## Done

- **2026-10-22 - Chess leaderboard periods (This month / All time).** KaChat 77d6038,
  ONLINE_CHESS.md §6. `GET /chess/leaderboard` and `/chess/player` take `period=month|all`, the
  response carries `period` and `since`, and both boards count from the fresh-start cutoff
  `1792647960000`. Done in kachat-indexer eaae9d2, before this file existed.
