## The scripted baselines: bounded, legal, and load-bearing. Quoter and shark
## are two fieldable scripted policies, so a whole episode of them must
## complete without ever proposing an illegal move, and the table must actually
## trade. Also tests strict JSON extraction and decision parsing.

import std/[algorithm, base64, json, monotimes, options, os, strutils, times, unicode, unittest]
import garble/[llm, server, sim, training_capture]

proc fixture(seed: int, turns = 12, noiseScale = 1.0): GameConfig =
  result = defaultGameConfig()
  result.seed = seed
  result.turns = turns
  result.noiseScale = noiseScale
  result.turnDelayMs = 0
  result.sampled = true
  for index in 0 ..< Seats:
    result.players.add(PlayerConfig(name: "P" & $(index + 1)))
    result.tokens.add("t" & $index)

proc checkLegal(decision: Decision) =
  doAssert decision.text.runeLen <= MaxTextRunes, decision.text
  doAssert strutils.splitWhitespace(decision.text).len <= MaxWords
  doAssert decision.notes.len == 0, "a baseline never writes notes"
  doAssert decision.channel == Radio or decision.channel in 0 ..< Seats
  if decision.hasConfirm:
    doAssert decision.ticket >= 1
    doAssert decision.qty in 0 .. MaxQty
    doAssert decision.price in 0 .. MaxPrice
    doAssert decision.commodity in 0 ..< CommodityCount

proc playScripted(config: GameConfig, kinds: seq[ScriptKind]): Sim =
  ## Decisions are simultaneous: every seat decides from the same snapshot,
  ## then the transmissions land, then the confirms.
  result = initSim(config)
  while not result.done:
    result.beginTurn()
    var decisions: seq[Decision]
    for seat in 0 ..< Seats:
      decisions.add(scriptedAction(result, seat, kinds[seat]))
      checkLegal(decisions[seat])
    for seat in 0 ..< Seats:
      result.applySay(seat, decisions[seat].channel, decisions[seat].text,
        decisions[seat].notes, scripted = true)
    for seat in 0 ..< Seats:
      let decision = decisions[seat]
      if decision.hasConfirm:
        result.applyConfirm(seat, decision.ticket, decision.side,
          decision.qty, decision.commodity, decision.price, scripted = true)
    for seat in 0 ..< Seats:
      doAssert result.airtime[seat] >= 0
      doAssert result.airtime[seat] <= AirtimeBudget
    result.endTurn()

proc mixOf(mask: int): seq[ScriptKind] =
  for seat in 0 ..< Seats:
    result.add(if ((mask shr seat) and 1) == 1: skShark else: skQuoter)

proc dealsIn(sim: Sim): int =
  for event in sim.events:
    if event.kind == evDeal:
      inc result

proc mishearsIn(sim: Sim): int =
  for event in sim.events:
    if event.kind == evDeal and event.misheard:
      inc result

suite "legality and boundedness":
  test "every mix of quoter and shark plays a whole legal episode":
    for seed in [1, 11, 42, 1234]:
      for mask in 0 ..< (1 shl Seats):
        let started = getMonoTime()
        let sim = playScripted(fixture(seed), mixOf(mask))
        let elapsed = (getMonoTime() - started).inMilliseconds
        check sim.done
        check sim.reason == "complete"
        check sim.turnsPlayed == 12
        check elapsed < 2000
        let results = sim.resultsJson()
        for value in results["airtimeUsed"]:
          check value.getInt() in 0 .. AirtimeBudget
        for seat in 0 ..< Seats:
          check sim.notes[seat].len == 0

suite "the game actually happens":
  test "an all-quoter table settles deals on every seed":
    var totals: seq[int]
    for seed in 0 ..< 50:
      let sim = playScripted(fixture(seed), mixOf(0))
      let deals = dealsIn(sim)
      check deals >= 1
      totals.add(deals)
    totals.sort()
    let median = totals[totals.len div 2]
    echo "all-quoter deals: median ", median, " min ", totals[0], " max ",
      totals[^1]
    check median >= 3

suite "the shield is load-bearing":
  test "sharks produce more mishearings than an honest table":
    var sharkMishears = 0
    var quoterMishears = 0
    for seed in 0 ..< 200:
      ## 3 sharks (seats 0, 1, 2) and 2 quoters
      sharkMishears += mishearsIn(playScripted(fixture(seed), mixOf(0b00111)))
      quoterMishears += mishearsIn(playScripted(fixture(seed), mixOf(0)))
    echo "misheard deals: shark-heavy ", sharkMishears, " all-quoter ",
      quoterMishears
    check sharkMishears > quoterMishears

  test "an honest table does better in the quiet than in the storm":
    var quiet = 0.0
    var storm = 0.0
    for seed in 0 ..< 200:
      let calm = playScripted(fixture(seed, noiseScale = 0.5), mixOf(0))
      let loud = playScripted(fixture(seed, noiseScale = 1.5), mixOf(0))
      for seat in 0 ..< Seats:
        quiet += calm.score(seat)
        storm += loud.score(seat)
    quiet = quiet / float(200 * Seats)
    storm = storm / float(200 * Seats)
    echo "mean quoter score: quiet ", formatFloat(quiet, ffDecimal, 4),
      " storm ", formatFloat(storm, ffDecimal, 4)
    check quiet > storm

suite "scripted baselines and client config":
  test "player-side baselines match the offline scripted baselines":
    for name in ["ANTHROPIC_API_KEY", "ANTHROPIC_API_KEY_URI",
        "AWS_ENDPOINT_URL_BEDROCK_RUNTIME", "AWS_BEARER_TOKEN_BEDROCK"]:
      delEnv(name)
    let client = newLlmClient(900, "claude-sonnet-5")
    check client.disabled
    check parseScriptKind("") == skNone
    check parseScriptKind("none") == skNone
    check parseScriptKind("quoter") == skQuoter
    check parseScriptKind("shark") == skShark
    for legacy in ["1", "true", "yes", "typo"]:
      expect GarbleError:
        discard parseScriptKind(legacy)
    for seed in [1, 11, 42]:
      var sim = initSim(fixture(seed))
      while not sim.done:
        sim.beginTurn()
        var decisions: seq[Decision]
        for seat in 0 ..< Seats:
          let view = sim.seatDecisionView(seat)
          let kind = if seat mod 2 == 0: skQuoter else: skShark
          for candidate in [skQuoter, skShark]:
            let action = scriptedDecisionFromView(view, candidate)
            let decision = parseDecision(sim, seat, action)
            check decision == scriptedAction(sim, seat, candidate)
            checkLegal(decision)
          decisions.add(scriptedAction(sim, seat, kind))
        for seat, decision in decisions:
          sim.applySay(seat, decision.channel, decision.text,
            decision.notes, scripted = true)
        for seat, decision in decisions:
          if decision.hasConfirm:
            sim.applyConfirm(seat, decision.ticket, decision.side,
              decision.qty, decision.commodity, decision.price,
              scripted = true)
        sim.endTurn()

suite "reply parsing":
  proc sample(): Sim =
    var sim = initSim(fixture(11))
    sim.beginTurn()
    sim

  proc decide(sim: Sim, body: string): Decision =
    parseDecision(sim, 0, extractJsonObject(body))

  test "a well-formed reply parses":
    let sim = sample()
    let decision = sim.decide("""{"channel":"RADIO",
      "text":"SELL 5 5 ORE ORE AT 12 12",
      "confirm":{"ticket":7,"side":"SELL","qty":5,"commodity":"TIN",
      "price":50},"notes":"Gizmo repeats prices."}""")
    check decision.channel == Radio
    check decision.text == "SELL 5 5 ORE ORE AT 12 12"
    check decision.hasConfirm
    check decision.ticket == 7
    check decision.side == sdSell
    check decision.qty == 5
    check decision.commodity == 2
    check decision.price == 50
    check decision.notes == "Gizmo repeats prices."
    check sim.decide("{\"channel\":\"" & sim.names[3] & "\"}").channel == 3

  test "omitted optional fields keep valid defaults":
    let sim = sample()
    let d1 = sim.decide("""{"text":"hello"}""")
    check d1.channel == Radio
    check d1.text == "hello"
    check d1.notes.len == 0
    check not d1.hasConfirm
    check not sim.decide("""{"text":"hello","confirm":null}""").hasConfirm
    check sim.decide("""{"confirm":null}""").text.len == 0

  test "extractJsonObject accepts bare JSON or a single ordinary outer markdown fence":
    let sim = sample()
    let fencedJson = "\xEF\xBB\xBF```json\n" &
      """{"channel":"RADIO","text":"SELL 5 ORE AT 12","confirm":{"ticket":2,"side":"SELL","commodity":"ORE","qty":5,"price":12},"notes":"watch \"{\" and } in strings"}""" &
      "\n```"
    let d1 = sim.decide(fencedJson)
    check d1.hasConfirm
    check d1.ticket == 2
    check d1.notes == """watch "{" and } in strings"""

    let fencedPlain = "```\n" &
      """{"channel":"RADIO","text":"BUY 3 TIN AT 20","confirm":null,"notes":"ok {still inside}"}""" &
      "\n```"
    let d2 = sim.decide(fencedPlain)
    check not d2.hasConfirm
    check d2.text == "BUY 3 TIN AT 20"
    check d2.notes == "ok {still inside}"

    check "final JSON block" in ActionReplyInstruction
    for candidate in [
      "My stock covers this sale.\n```json\n{\"text\":\"a\"}\n```",
      "```json\n{\"text\":\"a\"}",
      "```\n{\"text\":\"a\"}",
      "My stock covers this sale.\n```json\n{\"text\":\"a\"}",
      "My stock covers this sale.\n```\n{\"text\":\"a\"}\n"
    ]:
      check extractJsonObject(candidate)["text"].getStr == "a"
      check strictRawObject(candidate) == extractJsonObject(candidate)

  test "extractJsonObject rejects surrounding prose, extra objects, and bad fences":
    for bad in [
      "",
      "   \n  ",
      "not json",
      "[]",
      "123",
      "\xEF\xBB\xBF{\"text\":\"unclosed\"",
      """Here you go: {"text":"SELL 5 ORE AT 12"} — hope that helps.""",
      """{"text":"SELL 5 ORE AT 12"} trailing prose""",
      """{"text":"SELL 5 ORE AT 12"} trailing {not: json}""",
      """{"text":"a"}{"text":"b"}""",
      "```json\n{\"text\":\"a\"}\n```\nExtra note after fence.",
      "```json\n{\"text\":\"a\"}\n{\"text\":\"b\"}\n```",
      "```json\n{\"text\":\"a\"}\n{\"text\":\"b\"}",
      "```json\n{\"text\":\"a\"}\n```\n```json\n{\"text\":\"b\"}\n```",
      "My plan.\n```json\n{\"text\":\"a\"}\n```\n```json\n{\"text\":\"b\"}",
      "```python\n{\"text\":\"a\"}\n```",
      "```python\n{\"text\":\"a\"}",
      "```json",
      "```json\n",
      "```json\n{\"text\":\"a\"",
      "```json\n{\"text\":\"a\",\"confirm\":{\"ticket\":1}",
      "My plan.\n```json\n{\"text\":\"a\""
    ]:
      expect GarbleError:
        discard extractJsonObject(bad)

  test "complete orders permit metadata and reject ambiguous or invalid actions":
    let sim = sample()
    let radio = sim.decide("""{"channel":"RADIO","text":"SELL 2 TIN AT 9","comment":"my extra description"}""")
    check radio.channel == Radio and radio.text == "SELL 2 TIN AT 9"
    for body in [
      """{"channel":"radio","text":"x"}""",
      """{"channel":"Nobody","text":"x"}""",
      """{"channel":""}""",
      """{"channel":123}""",
      "{\"channel\":\"" & sim.names[0] & "\"}",
      "{\"channel\":\"" & sim.names[3].toLowerAscii() & "\"}",
      """{"text":123}""",
      """{"notes":false}""",
      """{"ticket":1,"text":"SELL 5 ORE AT 12"}""",
      """{"confirm":{"ticket":1,"side":"sell","commodity":"ORE","qty":5,"price":12}}""",
      """{"confirm":{"ticket":1,"side":"SELL","commodity":"ore","qty":5,"price":12}}""",
      """{"confirm":{"ticket":"1","side":"SELL","commodity":"ORE","qty":5,"price":12}}""",
      """{"confirm":{"ticket":1.0,"side":"SELL","commodity":"ORE","qty":5,"price":12}}""",
      """{"confirm":{"ticket":1,"side":"SELL","commodity":"ORE","qty":"5","price":12}}""",
      """{"confirm":{"ticket":1,"side":"SELL","commodity":"ORE","qty":5.0,"price":12}}""",
      """{"confirm":{"ticket":1,"side":"SELL","commodity":"ORE","qty":"five","price":12}}""",
      """{"confirm":{"ticket":1,"side":"SELL","commodity":"ORE","qty":5,"price":"twelve"}}""",
      """{"confirm":{"ticket":1,"side":"SELL","commodity":"ORE","qty":5,"price":12,"extra":1}}"""
    ]:
      expect GarbleError:
        discard sim.decide(body)

  test "ill-formed confirms are rejected":
    let sim = sample()
    for body in ["""{"confirm":{"ticket":1,"side":"SELL","commodity":"ORE",
        "qty":100,"price":12}}""",
        """{"confirm":{"ticket":1,"side":"SELL","commodity":"ORE",
        "qty":5,"price":-1}}""",
        """{"confirm":{"side":"SELL","commodity":"ORE","qty":5,"price":12}}""",
        """{"confirm":{"ticket":0,"side":"SELL","commodity":"ORE","qty":5,
        "price":12}}""",
        """{"confirm":{"ticket":1,"side":"SELL","commodity":"COAL","qty":5,
        "price":12}}""",
        """{"confirm":{"ticket":1,"side":"HOLD","commodity":"ORE","qty":5,
        "price":12}}""",
        """{"confirm":7}"""]:
      expect GarbleError:
        discard sim.decide(body)

  test "text and notes are capped on rune boundaries":
    let sim = sample()
    let decision = sim.decide("""{"channel":"RADIO","text":"""" &
      repeat("\u97F3", 400) & """","notes":"""" &
      repeat("\u97F3", 900) & """"}""")
    check decision.text.runeLen == MaxTextRunes
    check decision.notes.runeLen == MaxNotesRunes
    check decision.text.validateUtf8() == -1
    check decision.notes.validateUtf8() == -1
    check decision.channel == Radio

suite "native capture acceptance and Nov 25 live responses":
  const Nov25Responses = [
    "```json\n{\n  \"channel\": \"RADIO\",\n  \"text\": \"SELL 20 ORE AT 20\",\n  \"confirm\": null,\n  \"notes\": \"Surplus: 20 ORE. Demand: 2 OAT (contract commodity). Premium: 9 per unit OAT held. Current price ORE=11, OAT=8. Offering 20 ORE at 20 (market + premium) to secure OAT for contract. Repeating ORE and price to survive noise. Will confirm if counterparty repeats back.\"\n}\n```",
    "```json\n{\n  \"channel\": \"RADIO\",\n  \"text\": \"SELL 20 ORE AT 20 20\",\n  \"confirm\": null,\n  \"notes\": \"Turn 1: Offering 20 ORE at 20 (market 11 + premium 9) to secure OAT for contract. Repeating price twice to survive noise. Will confirm if counterparty repeats back. Current interference 0.15 is low, but repetition protects against garbling.\"\n}\n```",
    "```json\n{\n  \"channel\": \"RADIO\",\n  \"text\": \"SELL 20 ORE AT 20 20\",\n  \"confirm\": null,\n  \"notes\": \"Turn 2: Re-offering 20 ORE at 20 (market 12 + premium 9 = 21, rounding to 20). Repeating price twice to survive noise at interference 0.3. Need to secure OAT for contract. Current portfolio 260 vs hold 280 suggests I'm underwater; must execute this trade to lock in premium. No settled deals yet, so waiting for counterparty response.\"\n}\n```",
    "```json\n{\n  \"channel\": \"RADIO\",\n  \"text\": \"SELL 20 ORE AT 20 20\",\n  \"confirm\": null,\n  \"notes\": \"Turn 3: Re-offering 20 ORE at 20 (market 12 + premium 9 = 21, rounding to 20). Repeating price twice to survive noise at interference 0.6. Need to secure OAT for contract. Current portfolio 280 vs hold 260 suggests I'm slightly ahead but must execute this trade to lock in premium. No settled deals yet, so waiting for counterparty response.\"\n}\n```",
    "```json\n{\n  \"channel\": \"RADIO\",\n  \"text\": \"SELL 20 ORE AT 20 20\",\n  \"confirm\": null,\n  \"notes\": \"Turn 4: Re-offering 20 ORE at 20 (market 11 + premium 9 = 20). Repeating price twice to survive interference 0.75. Need to secure OAT for contract quota of 12. Current portfolio 280 vs hold 280 suggests break-even; must execute this trade to lock in premium and improve score. No settled deals yet involving me. Bolt's ticket 20 expires turn 6, but I'm not interested in their 50 ORE offer at 10-11. Focus on my core trade: sell ORE, buy OAT.\"\n}\n```",
    "```json\n{\n  \"channel\": \"RADIO\",\n  \"text\": \"SELL 20 ORE AT 20 20\",\n  \"confirm\": null,\n  \"notes\": \"Turn 5: Re-offering 20 ORE at 20 (market 12 + premium 9 = 21, but 20 is safer given interference 0.6). Repeating price twice to survive garbling. Need to secure OAT for contract quota of 12. Current portfolio 260 vs hold 280 means I'm underwater; must execute this trade to lock in premium and improve score. Bolt's ticket 20 expires turn 6, but I'm not interested in their 50 ORE offer at 10-11. Focus on getting OAT at reasonable price to meet contract requirements.\"\n}\n```",
    "```json\n{\n  \"channel\": \"RADIO\",\n  \"text\": \"SELL 20 ORE AT 20 20\",\n  \"confirm\": null,\n  \"notes\": \"Turn 6: Re-offering 20 ORE at 20 (market 12 + premium 9 = 21, but 20 is safer given interference 0.3). Repeating price twice to survive garbling. Need to secure OAT for contract quota of 12. Current portfolio 280 vs hold 260 means I'm at break-even; must execute this trade to lock in premium and improve score. Bolt's ticket 30 expires turn 8, but I'm not interested in their 5 OAT offer at 10. Focus on selling ORE to buy OAT for contract.\"\n}\n```",
    "```json\n{\n  \"channel\": \"RADIO\",\n  \"text\": \"SELL 20 ORE AT 20 20\",\n  \"confirm\": null,\n  \"notes\": \"Turn 7: Re-offering 20 ORE at 20 (market 13 + premium 9 = 22, but 20 is conservative given interference 0.15). Repeating price twice to survive garbling. Need to secure OAT for contract quota of 12. Current portfolio 300 vs hold 280 means I'm at 1.07 score; must execute this trade to lock in premium and improve further. Bolt's ticket 30 expires turn 8, but I'm not interested in their 5 OAT offer at 10. Widget's ticket 33 (5 ORE at 15) is also not optimal for my strategy. Focus on selling my 20 ORE surplus at a premium price to fund the OAT purchase needed for my contract.\"\n}\n```"
  ]

  test "all 8 Nov 25 live responses accept through decoder and native capture without platform_call_id":
    let trajPath = getTempDir() / ("garble-nov25-proof-" & $getMonoTime().ticks & ".jsonl")
    defer:
      if fileExists(trajPath): removeFile(trajPath)
    putEnv("COGAME_SAVE_TRAJECTORY_URI", "file://" & trajPath)
    putEnv("COWORLD_EPISODE_ID", "nov25-unit-proof")
    putEnv("COWORLD_GAME_VERSION", "0.1.7")
    putEnv("COWORLD_SOURCE_REVISION", "local-test")
    delEnv("COGAME_RESULTS_URI")
    delEnv("COGAME_SAVE_REPLAY_URI")

    var sim = initSim(fixture(52000, turns = 8))
    let capture = newRuntimeCapture(sim)
    for turn in 0 ..< 8:
      sim.beginTurn()
      capture.beginCaptureTurn(sim)
      let rawText = Nov25Responses[turn]
      let extracted = extractJsonObject(rawText)
      let reqBody = $ %*{"max_tokens": 900, "model": "anthropic/claude-haiku-4.5",
        "system": "sys", "messages": [{"role": "user", "content": "usr"}]}
      let respBody = $ %*{"id": "msg_nov25_" & $turn, "type": "message",
        "role": "assistant", "model": "anthropic/claude-haiku-4.5",
        "content": [{"type": "text", "text": rawText}], "stop_reason": "end_turn"}
      var attempt = requestAttempt(reqBody)
      attempt.response = %rawText
      attempt.rawResponse = %respBody
      attempt.responseBodyB64 = some(encode(respBody))
      attempt.responseComplete = some(true)
      attempt.responseReaderJoined = some(true)
      attempt.httpStatus = some(200)
      # Explicitly omit platformCallId (mirrors live Nov 25 proxy headers)
      let priv = PrivateCapture(evidence: privateEnvelope(attempt, reqBody))
      let frame = decisionFrame(%turn, "player", extracted, priv)
      let idx = capture.receivedFrame(turn, 0, frame, "received action")
      let parsed0 = parseDecision(sim, 0, frame["action"])
      capture.selectedFrame(turn, 0, idx, sim.decisionJson(parsed0))

      var decisions = @[parsed0]
      for seat in 1 ..< Seats:
        decisions.add(scriptedAction(sim, seat, skQuoter))
      for seat in 0 ..< Seats:
        sim.applySay(seat, decisions[seat].channel, decisions[seat].text,
          decisions[seat].notes, seat != 0)
      for seat in 0 ..< Seats:
        if decisions[seat].hasConfirm:
          sim.applyConfirm(seat, decisions[seat].ticket, decisions[seat].side,
            decisions[seat].qty, decisions[seat].commodity, decisions[seat].price,
            seat != 0)
      capture.appliedCaptureTurn(sim, @[false, false, false, false, false])
      sim.endTurn()

    let results = sim.resultsJson()
    capture.finishCapture(results)

    var seat0Rows: seq[JsonNode]
    var episodeRow: JsonNode
    for line in readFile(trajPath).splitLines():
      if line.len == 0: continue
      let row = parseJson(line)
      if row["event_type"].getStr() == "decision" and row["seat"].getStr() == "0":
        seat0Rows.add(row)
      elif row["event_type"].getStr() == "episode":
        episodeRow = row
    check seat0Rows.len == 8
    check episodeRow["status"].getStr() == "completed"
    check episodeRow["participant_outcomes"].kind == JArray
    check episodeRow["participant_outcomes"].len == 5
    for turn in 0 ..< 8:
      let row = seat0Rows[turn]
      check row["action_status"].getStr() == "accepted"
      check row["selected_attempt_id"].kind == JString
      let att = row["attempts"][0]
      check att["accepted"].getBool()
      check att["rejection_reason"].kind == JNull
      # Exact raw fenced model text preserved untouched
      check att["response"].getStr() == Nov25Responses[turn]
      check row["executed_action"]["channel"].getStr() == "RADIO"
      check row["executed_action"]["confirm"].kind == JNull
      let diag = row["observation"]["telemetry_frames"][0]
      if turn < 4:
        check not diag.hasKey("notes_clipped")
        check row["executed_action"]["notes"].getStr().runeLen <= MaxNotesRunes
      else:
        check diag["notes_clipped"].getBool()
        check diag["raw_notes_runes"].getInt() > MaxNotesRunes
        check diag["stored_notes_runes"].getInt() == MaxNotesRunes
        check row["executed_action"]["notes"].getStr().runeLen == MaxNotesRunes
        check row["executed_action"]["notes"].getStr().endsWith("\u2026")

  test "suppliedActionMatches allows optional omissions, confirm:null, and clipped notes but rejects modified game actions":
    let actual = %*{"channel": "RADIO", "text": "SELL 5 ORE AT 12",
      "notes": cleanText(repeat("a", 450), MaxNotesRunes), "confirm": nil}
    var clipped = false
    var priorRetained = false
    # Omitted channel/notes/confirm with exact text
    check suppliedActionMatches(%*{"text": "SELL 5 ORE AT 12"}, actual, clipped, priorRetained)
    check not clipped
    # Explicit confirm:null + clipped notes
    check suppliedActionMatches(%*{"channel": "RADIO", "text": "SELL 5 ORE AT 12",
      "confirm": nil, "notes": repeat("a", 450)}, actual, clipped, priorRetained)
    check clipped
    # Do NOT silently accept trimmed or altered game text
    check not suppliedActionMatches(%*{"text": "  SELL 5 ORE AT 12  "}, actual, clipped, priorRetained)
    check not suppliedActionMatches(%*{"channel": "radio", "text": "SELL 5 ORE AT 12"}, actual, clipped, priorRetained)
    # Single outer markdown fence accepted by strictRawObject, prose rejected
    check strictRawObject("```json\n{\"text\":\"SELL 5 ORE AT 12\",\"confirm\":null}\n```")["text"].getStr() == "SELL 5 ORE AT 12"
    expect ValueError:
      discard strictRawObject("Here is my move: {\"text\":\"SELL 5 ORE AT 12\"}")

suite "player failure wire artifact":
  test "attributable policy failures emit message and failed_policy_index":
    let payload = playerFailureJson("rejected_action",
      "seat 2 turn 1: invalid channel: Nobody", 2)
    check payload.len == 2
    check payload["message"].getStr() == "seat 2 turn 1: invalid channel: Nobody"
    check payload["failed_policy_index"].getInt() == 2
    check not payload.hasKey("kind")

  test "provider failures name the interrupted seat and remain inconclusive":
    let payload = playerFailureJson("infra_failure", "deadline exceeded", 3)
    check payload["kind"].getStr() == "episode_inconclusive"
    check payload["failed_policy_index"].getInt() == 3
    check payload["message"].getStr() == "deadline exceeded"
    check playerFailureJson("infra_failure", "game error", -1).isNil
    check playerFailureJson("rejected_action", "unknown seat", Seats).isNil
