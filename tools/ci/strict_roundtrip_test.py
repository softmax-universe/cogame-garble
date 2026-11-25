#!/usr/bin/env python3
"""Public host+player round-trip tests for Garble strict interface and capture.

Covers:
1. Valid regular JSON, single outer markdown fence, confirm:null, omitted
   optional defaults, and exact Nov 25 live responses (turns 0-7 including
   >400-rune notes clipped at 400 and NO X-Softmax-Llm-Call-Id header).
2. Invalid / ambiguous JSON objects (prose around JSON, multiple objects,
   invalid channel) -> episode terminates unscored with no results.json.
3. Provider / infra failure (HTTP 429, missing credentials / disabled LLM) ->
   episode terminates unscored with no results.json and no numeric scores.
4. Purely scripted offline certification fixture from coworld_manifest_template.json.
"""

from __future__ import annotations

import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

NOV25_TRAJECTORY = Path(
    "/tmp/inkling-suite-native-diag/wave1/garble-validation-52000/"
    "garble-validation-52000_s52000_seat0/trajectory.jsonl"
)

NOV25_FALLBACK_RESPONSES = [
    '```json\n{\n  "channel": "RADIO",\n  "text": "SELL 20 ORE AT 20",\n  "confirm": null,\n  "notes": "Surplus: 20 ORE. Demand: 2 OAT (contract commodity). Premium: 9 per unit OAT held. Current price ORE=11, OAT=8. Offering 20 ORE at 20 (market + premium) to secure OAT for contract. Repeating ORE and price to survive noise. Will confirm if counterparty repeats back."\n}\n```',
    '```json\n{\n  "channel": "RADIO",\n  "text": "SELL 20 ORE AT 20 20",\n  "confirm": null,\n  "notes": "Turn 1: Offering 20 ORE at 20 (market 11 + premium 9) to secure OAT for contract. Repeating price twice to survive noise. Will confirm if counterparty repeats back. Current interference 0.15 is low, but repetition protects against garbling."\n}\n```',
    '```json\n{\n  "channel": "RADIO",\n  "text": "SELL 20 ORE AT 20 20",\n  "confirm": null,\n  "notes": "Turn 2: Re-offering 20 ORE at 20 (market 12 + premium 9 = 21, rounding to 20). Repeating price twice to survive noise at interference 0.3. Need to secure OAT for contract. Current portfolio 260 vs hold 280 suggests I\'m underwater; must execute this trade to lock in premium. No settled deals yet, so waiting for counterparty response."\n}\n```',
    '```json\n{\n  "channel": "RADIO",\n  "text": "SELL 20 ORE AT 20 20",\n  "confirm": null,\n  "notes": "Turn 3: Re-offering 20 ORE at 20 (market 12 + premium 9 = 21, rounding to 20). Repeating price twice to survive noise at interference 0.6. Need to secure OAT for contract. Current portfolio 280 vs hold 260 suggests I\'m slightly ahead but must execute this trade to lock in premium. No settled deals yet, so waiting for counterparty response."\n}\n```',
    '```json\n{\n  "channel": "RADIO",\n  "text": "SELL 20 ORE AT 20 20",\n  "confirm": null,\n  "notes": "Turn 4: Re-offering 20 ORE at 20 (market 11 + premium 9 = 20). Repeating price twice to survive interference 0.75. Need to secure OAT for contract quota of 12. Current portfolio 280 vs hold 280 suggests break-even; must execute this trade to lock in premium and improve score. No settled deals yet involving me. Bolt\'s ticket 20 expires turn 6, but I\'m not interested in their 50 ORE offer at 10-11. Focus on my core trade: sell ORE, buy OAT."\n}\n```',
    '```json\n{\n  "channel": "RADIO",\n  "text": "SELL 20 ORE AT 20 20",\n  "confirm": null,\n  "notes": "Turn 5: Re-offering 20 ORE at 20 (market 12 + premium 9 = 21, but 20 is safer given interference 0.6). Repeating price twice to survive garbling. Need to secure OAT for contract quota of 12. Current portfolio 260 vs hold 280 means I\'m underwater; must execute this trade to lock in premium and improve score. Bolt\'s ticket 20 expires turn 6, but I\'m not interested in their 50 ORE offer at 10-11. Focus on getting OAT at reasonable price to meet contract requirements."\n}\n```',
    '```json\n{\n  "channel": "RADIO",\n  "text": "SELL 20 ORE AT 20 20",\n  "confirm": null,\n  "notes": "Turn 6: Re-offering 20 ORE at 20 (market 12 + premium 9 = 21, but 20 is safer given interference 0.3). Repeating price twice to survive garbling. Need to secure OAT for contract quota of 12. Current portfolio 280 vs hold 260 means I\'m at break-even; must execute this trade to lock in premium and improve score. Bolt\'s ticket 30 expires turn 8, but I\'m not interested in their 5 OAT offer at 10. Focus on selling ORE to buy OAT for contract."\n}\n```',
    '```json\n{\n  "channel": "RADIO",\n  "text": "SELL 20 ORE AT 20 20",\n  "confirm": null,\n  "notes": "Turn 7: Re-offering 20 ORE at 20 (market 13 + premium 9 = 22, but 20 is conservative given interference 0.15). Repeating price twice to survive garbling. Need to secure OAT for contract quota of 12. Current portfolio 300 vs hold 280 means I\'m at 1.07 score; must execute this trade to lock in premium and improve further. Bolt\'s ticket 30 expires turn 8, but I\'m not interested in their 5 OAT offer at 10. Widget\'s ticket 33 (5 ORE at 15) is also not optimal for my strategy. Focus on selling my 20 ORE surplus at a premium price to fund the OAT purchase needed for my contract."\n}\n```',
]

BASE_ENV = {
    "HOME": str(Path.home()),
    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin",
    "LANG": "en_US.UTF-8",
    "LC_ALL": "en_US.UTF-8",
    "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
}


def free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def load_nov25_responses() -> list[str]:
    if NOV25_TRAJECTORY.is_file():
        responses = []
        for line in NOV25_TRAJECTORY.read_text().splitlines():
            row = json.loads(line)
            if row.get("event_type") == "decision" and row.get("seat") == "0":
                responses.append(row["attempts"][0]["response"])
        assert len(responses) == 8
        return responses
    return NOV25_FALLBACK_RESPONSES


def run_episode(
    game_bin: Path,
    player_bin: Path,
    case: str,
    seat0_responder,
    *,
    turns: int = 8,
    seed: int = 52000,
    seat0_env_override: dict[str, str] | None = None,
    all_scripted_ids: list[str] | None = None,
) -> tuple[int, Path]:
    out = Path(tempfile.mkdtemp(prefix=f"garble-rt-{case}-"))
    model = None
    if all_scripted_ids is None and seat0_env_override is None:

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                raw = self.rfile.read(int(self.headers["Content-Length"]))
                body = json.loads(raw)
                view, _ = json.JSONDecoder().raw_decode(body["messages"][0]["content"])
                code, text = seat0_responder(view)
                if code == 200:
                    payload = {
                        "id": f"msg_rt_{view['turn']}",
                        "type": "message",
                        "role": "assistant",
                        "model": body["model"],
                        "content": [{"type": "text", "text": text}],
                        "stop_reason": "end_turn",
                        "usage": {"input_tokens": 100, "output_tokens": 50},
                    }
                else:
                    payload = {"error": text}
                encoded = json.dumps(payload, ensure_ascii=False).encode()
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(encoded)))
                # Deliberately omit X-Softmax-Llm-Call-Id to match Nov 25 live proxy
                self.end_headers()
                self.wfile.write(encoded)

            def log_message(self, *_args):
                pass

        model = ThreadingHTTPServer(("127.0.0.1", free_port()), Handler)
        threading.Thread(target=model.serve_forever, daemon=True).start()

    game_port = free_port()
    config = {
        "tokens": [f"tok-{i}" for i in range(5)],
        "players": [{"name": f"Seat-{i}"} for i in range(5)],
        "seed": seed,
        "turns": turns,
        "sampled": True,
        "turnDelayMs": 0,
        "turnSpacingMs": 0,
        "actionTimeoutSeconds": 8,
        "player_connect_timeout_seconds": 8,
    }
    (out / "config.json").write_text(json.dumps(config))
    game_env = {
        **BASE_ENV,
        "COGAME_HOST": "127.0.0.1",
        "COGAME_PORT": str(game_port),
        "COGAME_CONFIG_URI": (out / "config.json").as_uri(),
        "COGAME_RESULTS_URI": (out / "results.json").as_uri(),
        "COGAME_SAVE_REPLAY_URI": (out / "replay.json").as_uri(),
        "COGAME_SAVE_TRAJECTORY_URI": (out / "trajectory.jsonl").as_uri(),
        "COWORLD_EPISODE_ID": f"rt-{case}",
        "COWORLD_GAME_VERSION": "0.1.7",
        "COWORLD_SOURCE_REVISION": "local-rt",
    }
    procs: list[subprocess.Popen] = []
    handles = []
    try:
        gh = (out / "game.log").open("w")
        handles.append(gh)
        game = subprocess.Popen(
            [str(game_bin)], env=game_env, stdout=gh, stderr=subprocess.STDOUT
        )
        procs.append(game)
        for _ in range(100):
            assert game.poll() is None, "game exited before listen"
            with socket.socket() as s:
                if s.connect_ex(("127.0.0.1", game_port)) == 0:
                    break
            time.sleep(0.05)

        for seat in range(5):
            penv = {
                **BASE_ENV,
                "COWORLD_PLAYER_WS_URL": f"ws://127.0.0.1:{game_port}/player?slot={seat}&token=tok-{seat}",
            }
            if all_scripted_ids is not None:
                penv["PLAYER_SCRIPTED"] = all_scripted_ids[seat]
            elif seat == 0:
                if seat0_env_override is not None:
                    penv.update(seat0_env_override)
                else:
                    assert model is not None
                    penv["COWORLD_LLM_ENDPOINT"] = f"http://127.0.0.1:{model.server_port}"
                    penv["COWORLD_LLM_MODEL"] = "anthropic/claude-haiku-4.5"
            else:
                penv["PLAYER_SCRIPTED"] = "quoter"
            ph = (out / f"player-{seat}.log").open("w")
            handles.append(ph)
            procs.append(
                subprocess.Popen(
                    [str(player_bin)], env=penv, stdout=ph, stderr=subprocess.STDOUT
                )
            )

        rc = game.wait(timeout=60)
        for p in procs[1:]:
            p.wait(timeout=10)
        return rc, out
    finally:
        for p in reversed(procs):
            if p.poll() is None:
                p.terminate()
                try:
                    p.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    p.kill()
        for h in handles:
            h.close()
        if model is not None:
            model.shutdown()


def main() -> None:
    game_bin = Path(sys.argv[1]).resolve()
    player_bin = Path(sys.argv[2]).resolve()
    nov25 = load_nov25_responses()

    # 1. Exact Nov 25 live responses (fenced, confirm:null, clipped notes, no call_id)
    rc, out = run_episode(
        game_bin, player_bin, "nov25-live", lambda view: (200, nov25[view["turn"]])
    )
    assert rc == 0, f"nov25-live failed: {(out / 'game.log').read_text()}"
    results = json.loads((out / "results.json").read_text())
    assert results["reason"] == "complete" and len(results["scores"]) == 5
    rows = [json.loads(l) for l in (out / "trajectory.jsonl").read_text().splitlines()]
    assert rows[-1]["status"] == "completed" and rows[-1]["participant_outcomes"] == results["scores"]
    s0 = [r for r in rows[:-1] if r["seat"] == "0"]
    assert len(s0) == 8
    for turn, row in enumerate(s0):
        assert row["action_status"] == "accepted", f"turn {turn} was {row['action_status']}"
        assert row["attempts"][0]["accepted"] is True
        assert row["attempts"][0]["response"] == nov25[turn]
        if turn >= 4:
            diag = row["observation"]["telemetry_frames"][0]
            assert diag["notes_clipped"] is True and diag["stored_notes_runes"] == 400
            assert len(row["executed_action"]["notes"]) == 400
    print("PASS 1/5: Nov 25 exact 8 turns (fenced, confirm:null, clipped notes, no call_id)")

    # 2. Regular JSON + omitted optional defaults + single outer fence
    def regular_and_defaults(view):
        t = view["turn"]
        if t == 0:
            return 200, json.dumps({"text": "SELL 5 ORE AT 12"})  # omitted channel/notes/confirm
        if t == 1:
            return 200, json.dumps({"channel": "RADIO", "text": "SELL 5 ORE AT 12", "confirm": None})
        if t == 2:
            return 200, '```\n{"text":"BUY 3 TIN AT 10","confirm":null}\n```'
        return 200, json.dumps(
            {"channel": "RADIO", "text": "SELL 5 ORE AT 12", "notes": "", "confirm": None}
        )

    rc, out = run_episode(game_bin, player_bin, "regular-defaults", regular_and_defaults, turns=6, seed=11)
    assert rc == 0, f"regular-defaults failed: {(out / 'game.log').read_text()}"
    rows = [json.loads(l) for l in (out / "trajectory.jsonl").read_text().splitlines()]
    assert rows[-1]["status"] == "completed"
    for row in (r for r in rows[:-1] if r["seat"] == "0"):
        assert row["action_status"] == "accepted"
    print("PASS 2/5: Regular JSON, omitted optional defaults, confirm:null, plain fence")

    # 3. Invalid / ambiguous JSON objects -> unscored termination, no results.json
    for label, bad_text in [
        ("ambiguous-two-objects", '{"text":"SELL 5 ORE AT 12"}{"text":"BUY 5 ORE AT 10"}'),
        ("prose-wrapped", 'Here is my move: {"text":"SELL 5 ORE AT 12"}'),
        ("invalid-channel", '{"channel":"Nobody","text":"SELL 5 ORE AT 12"}'),
    ]:
        rc, out = run_episode(game_bin, player_bin, label, lambda _v, t=bad_text: (200, t), turns=6, seed=11)
        assert rc != 0, f"{label} unexpectedly succeeded"
        assert not (out / "results.json").exists(), f"{label} wrote results.json"
        rows = [json.loads(l) for l in (out / "trajectory.jsonl").read_text().splitlines()]
        assert rows[-1]["status"] == "failed"
        assert rows[-1]["participant_outcomes"] is None
        assert rows[-1]["outcome"]["failure_kind"] == "rejected_action"
        s0_t0 = next(r for r in rows[:-1] if r["decision_id"] == "0-0")
        assert s0_t0["action_status"] == "rejected" and s0_t0["executed_action"] is None
    print("PASS 3/5: Invalid/ambiguous objects terminate unscored with rejected_action")

    # 4. Provider / infra failures (HTTP 429 and disabled/no-credentials) -> unscored termination
    rc, out = run_episode(game_bin, player_bin, "http429", lambda _v: (429, "rate limit"), turns=6, seed=11)
    assert rc != 0 and not (out / "results.json").exists()
    rows = [json.loads(l) for l in (out / "trajectory.jsonl").read_text().splitlines()]
    assert rows[-1]["status"] == "failed" and rows[-1]["participant_outcomes"] is None
    assert rows[-1]["outcome"]["failure_kind"] == "infra_failure"

    rc, out = run_episode(game_bin, player_bin, "no-creds", None, turns=6, seed=11, seat0_env_override={})
    assert rc != 0 and not (out / "results.json").exists()
    rows = [json.loads(l) for l in (out / "trajectory.jsonl").read_text().splitlines()]
    assert rows[-1]["status"] == "failed" and rows[-1]["participant_outcomes"] is None
    assert rows[-1]["outcome"]["failure_kind"] == "infra_failure"
    print("PASS 4/5: Provider/infra failures terminate unscored with infra_failure and no numeric scores")

    # 5. Purely scripted offline certification from manifest
    manifest = json.loads((ROOT / "coworld_manifest_template.json").read_text())
    assert manifest["player"][0]["id"] == "garble-player"
    assert manifest["player"][0]["env"].get("COWORLD_LLM_ENABLED") == "true"
    assert "PLAYER_SCRIPTED" not in manifest["player"][0]["env"]
    players_by_id = {p["id"]: p for p in manifest["player"]}
    cert_scripts = []
    for entry in manifest["certification"]["players"]:
        pid = entry["player_id"]
        assert pid in players_by_id
        script = players_by_id[pid].get("env", {}).get("PLAYER_SCRIPTED")
        assert script in ("quoter", "shark"), f"certification seat {pid} is not scripted!"
        cert_scripts.append(script)
    cert_cfg = manifest["certification"]["game_config"]
    rc, out = run_episode(
        game_bin,
        player_bin,
        "offline-cert",
        None,
        turns=cert_cfg["turns"],
        seed=cert_cfg["seed"],
        all_scripted_ids=cert_scripts,
    )
    assert rc == 0, f"offline-cert failed: {(out / 'game.log').read_text()}"
    cert_results = json.loads((out / "results.json").read_text())
    assert cert_results["reason"] == "complete" and cert_results["turns"] == cert_cfg["turns"]
    assert len(cert_results["scores"]) == 5
    print("PASS 5/5: Purely scripted offline certification completes with genuine scores")


if __name__ == "__main__":
    main()
