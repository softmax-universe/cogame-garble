# Garble player protocol v3

Connect to `COWORLD_PLAYER_WS_URL` with the assigned slot and token. All frames are JSON text.

The game sends `welcome` with the seat's anonymous alias, then redacted `state` frames after events. Each turn it sends:

```json
{"type":"turn","turn":0,"timeout_ms":25000,"view":{"alias":"Sprocket","prices":[10,11,12,13],"tickets":[]}}
```

`view` is the ordinary seat observation. It contains the seat's alias, turn, prices, forecast, private holdings and contract, cash, airtime, notes, public settled deals, and only the traffic this seat heard. `tickets` contains every confirmable ticket with this listener's heard text. `heard` is null when the text does not parse; otherwise it includes parsed terms and possible near-neighbour values. It never contains another seat's private holdings, contract, notes, or ungarbled transmission.

Every player sends one complete action before `timeout_ms` expires:

```json
{"type":"decision","turn":0,"source":"player","action":{"channel":"RADIO","text":"SELL 5 ORE AT 12","notes":"","confirm":null}}
```

`channel` is `RADIO` or another seat's exact alias. `confirm` is null or an object with integer `ticket`, `side` (`SELL` or `BUY`), `commodity` (`ORE`, `OAT`, `TIN`, `TAR`), integer `qty`, and integer `price`. The game validates actions, applies all transmissions in seat order, then applies all confirms in seat order. Only the first decision or failure frame for the pending turn is considered. Missing, timed-out, failed, or invalid actions terminate the unfinished episode unscored (no fallback move, no invented turn forfeit).

`source` is `player` or `scripted`; it annotates replay decisions. A player that fails to produce an action may send `{"type":"decision_failed","turn":0,"failure_kind":"infra_failure"|"rejected_action","reason":"..."}` to terminate the unfinished episode unscored immediately. After the turn, the game sends `decision_result` with `accepted` (and `reason` when rejected). A legal confirm that later voids is still accepted. A completed game ends with `final` scores and portfolio values; an aborted episode sends `final` with `"failed": true` and `"scores": null`.
