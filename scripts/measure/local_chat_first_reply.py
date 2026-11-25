#!/usr/bin/env python3
"""Select to first reply of a local chat, the way a person starts one, in a tagged cmux NEXT app built at a commit.

The same timed chat as cmuxterm-hq's synthetic probe (tools/fleet-reconcilers/local_chat_probe.py, job `local-chat`
of synthetic-probes.yml), but on a fresh build of any commit on a fleet Mac instead of the published NIGHTLY on one
owner-only runner, so a commit's number is known before it ships:

  1. the app starts with a scratch HOME and its own acpmux home and socket; Claude Code (the binary the caller gives,
     the shell's pinned and checked download) goes into that HOME's ~/.local/bin, where acpmux looks for it;
  2. the daemon restarts with the route's environment (ANTHROPIC_BASE_URL and a placeholder key: a route that signs
     requests itself, so no credential reaches the worker);
  3. a warm-up chat a person makes (the app's New chat, then the composer's Send through debug.agent_pane
     compose_send, which records a gesture as a click does, so acpmux counts it a person's and remembers its shape for
     the next daemon's spare; a CLI chat never claims the spare);
  4. per round: the daemon restarts (a relaunch, long before the person's select), the probe's wait for a ready spare,
     then the timed chat: `cmux agent new-chat --cwd NEUTRAL --model M --focus`, the prompt sent by compose_send, and
     the turn's end in `acpmux history`. select_to_first_text_ms is new-chat's start to that end, as the probe's.

Each round has the probe's `select_to_first_text_stages` (before_turn_ms, turn_ms, after_turn_ms: they add up to the
round's ms) and `turn_marks_ms` (agent_ready_ms, first_prompt_ms, to_agent_ms, first_model_ms, turn_wall_ms).
Output: --json FILE (every round) and one line `LOCAL-CHAT-FIRST-REPLY {...}` with the p50s.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import statistics
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "cmux-next"))
import bench_memory as bm  # noqa: E402
import idle_cost_load as icl  # noqa: E402

PROMPT = "Reply with exactly: ok"  # cloud_start_matrix_probe.OK_PROMPT
CHAT_TIMEOUT_S = 300  # local_chat_probe.CHAT_TIMEOUT_S
SPARE_WAIT_S = 20.0  # local_chat_probe.SPARE_WAIT_S
SPARE_POLL_S = 0.5
SESSION_WAIT_S = 10.0
COMPOSER_WAIT_S = 30.0
POLL_S = 0.1
PLACEHOLDER_KEY = "sk-ant-placeholder-the-route-signs"


def say(*words):
    print("local-chat-first-reply:", *words, flush=True)


class Run:
    def __init__(self, app: str, socket_path: str, env: dict):
        self.app = bm.App(app, socket_path)
        self.acpmux = icl.bundled_acpmux(app)
        self.env = env

    def sh(self, argv, timeout):
        try:
            out = subprocess.run(argv, capture_output=True, text=True, timeout=timeout, env=self.env)
            return out.returncode, out.stdout, out.stderr
        except subprocess.TimeoutExpired:
            return 124, "", f"timed out after {timeout} s"

    def acp(self, *words, timeout=60):
        return self.sh([self.acpmux, *words], timeout)

    def cmux(self, *words, timeout=60):
        return self.sh([self.app.cli_path, "--app-socket", self.app.socket, *words], timeout)

    def pane(self, action, **params):
        result = self.app.call("debug.agent_pane", dict(params, action=action), timeout=40)
        if isinstance(result, dict) and isinstance(result.get("result"), str):
            try:
                result = dict(result, result=json.loads(result["result"]))
            except ValueError:
                pass
        return result


def restart_daemon(run: Run):
    """local_chat_probe's walk.restart_daemon: restart, or start when none runs; the route env is the CLI's own."""
    code, out, err = run.acp("daemon", "restart", timeout=90)
    if code != 0:
        code, out, err = run.acp("daemon", "start", timeout=90)
    if code != 0:
        raise SystemExit(f"local-chat-first-reply: acpmux daemon restart exit {code}: {(err or out).strip()[-300:]}")


def listed_sessions(run: Run) -> dict | None:
    code, out, _ = run.acp("--json", "ls", timeout=30)
    if code != 0:
        return None
    try:
        got = json.loads(out)
    except ValueError:
        return None
    rows = got.get("sessions") if isinstance(got, dict) else got
    if not isinstance(rows, list):
        return None
    ids = {}
    for row in rows:
        if isinstance(row, dict):
            sid = next((row[k] for k in ("id", "sessionId", "name") if isinstance(row.get(k), str) and row[k]), None)
            if sid:
                ids[sid] = row
    return ids


def new_session(run: Run, before: dict):
    fresh = [(sid, row) for sid, row in (listed_sessions(run) or {}).items() if sid not in before]
    people = [f for f in fresh if (f[1].get("createdBy") or {}).get("kind") == "person"]
    return (people or fresh or [None])[0]


def last_turn(run: Run, session: str) -> dict | None:
    code, out, _ = run.acp("--json", "history", session, "-n", "1", timeout=60)
    try:
        turns = json.loads(out).get("turns") if code == 0 else None
    except (ValueError, AttributeError):
        return None
    return turns[-1] if isinstance(turns, list) and turns and isinstance(turns[-1], dict) else None


def spare_ready(run: Run) -> dict:
    started, states = time.perf_counter(), []
    while True:
        code, out, _ = run.acp("--json", "daemon", "status", timeout=30)
        try:
            entries = json.loads(out)["pool"]["entries"] if code == 0 else None
        except (ValueError, KeyError, TypeError):
            entries = None
        waited = time.perf_counter() - started
        if not isinstance(entries, list):
            return {"ready": None, "wait_ms": round(waited * 1000), "states": states}
        states = [str(e.get("state")) for e in entries if isinstance(e, dict) and "spare" in (e.get("roles") or [])]
        if "ready" in states or waited >= SPARE_WAIT_S:
            return {"ready": "ready" in states, "wait_ms": round(waited * 1000), "states": states}
        time.sleep(SPARE_POLL_S)


def person_chat(run: Run, neutral: str, model: str) -> dict:
    """local_chat_probe.app_chat with the composer's Send through debug.agent_pane instead of CuaDriver's keys."""
    before = listed_sessions(run)
    if before is None:
        return {"ok": False, "ms": 0, "error": "acpmux --json ls could not be read before the chat"}
    started, started_at = time.monotonic(), time.time()

    def elapsed():
        return round((time.monotonic() - started) * 1000)

    def failed(why, **more):
        return {"ok": False, "ms": elapsed(), "error": why[:500], **more}

    code, out, err = run.cmux("agent", "new-chat", "--cwd", neutral, "--model", model, "--focus", "--json", timeout=60)
    if code != 0:
        return failed(f"cmux agent new-chat (exit {code}): {(err or out).strip()[-300:]}")
    new_chat_ms = elapsed()
    sent, tries = None, 0
    while time.monotonic() - started < COMPOSER_WAIT_S:
        tries += 1
        got = run.pane("compose_send", text=PROMPT)
        inner = got.get("result") if isinstance(got.get("result"), dict) else got
        if not got.get("error") and not inner.get("error"):
            sent = inner
            break
        if "no composer" not in json.dumps(got):
            return failed(f"compose_send: {json.dumps(got)[:300]}")
        time.sleep(POLL_S)
    if sent is None:
        return failed(f"no composer showed within {COMPOSER_WAIT_S:.0f} s of New chat ({tries} tries)")
    sent_ms = elapsed()
    found, end = None, time.monotonic() + SESSION_WAIT_S
    while found is None and time.monotonic() < end:
        found = new_session(run, before)
        if found is None:
            time.sleep(POLL_S)
    if found is None:
        return failed(f"no session appeared within {SESSION_WAIT_S:.0f} s of the composer's Send")
    session, row = found
    session_ms = elapsed()
    turn = None
    while time.monotonic() - started < CHAT_TIMEOUT_S:
        turn = last_turn(run, session)
        if turn and isinstance(turn.get("endedAt"), int):
            break
        time.sleep(POLL_S)
    else:
        return failed("the chat's turn did not end in time", session=session)
    ms, ended_at = elapsed(), time.time()
    code, reply, _ = run.acp("last", session, timeout=60)
    created = (row.get("createdBy") or {}).get("kind") if isinstance(row.get("createdBy"), dict) else None
    out = {"ok": code == 0 and bool(reply.strip()), "ms": ms, "reply": reply.strip()[:200], "session": session,
           "started_at_ms": round(started_at * 1000), "ended_at_ms": round(ended_at * 1000),
           "new_chat_ms": new_chat_ms, "composer_sent_ms": sent_ms, "session_seen_ms": session_ms,
           "compose_send": sent, "created_by": created}
    out.update(stages(out, turn))
    return out if out["ok"] else {**out, "error": "the chat's last reply could not be read"}


def stages(result: dict, turn: dict) -> dict:
    """local_chat_probe.stages, from the turn already read."""
    begun, ended = turn.get("startedAt"), turn.get("endedAt")
    if not isinstance(begun, int) or not isinstance(ended, int):
        return {"stages_error": "the turn has no start or end time"}
    before = max(0, begun - result["started_at_ms"])
    after = max(0, result["ended_at_ms"] - ended)
    agent = turn.get("agentStart") if isinstance(turn.get("agentStart"), dict) else {}
    marks = {"agent_ready_ms": agent.get("readyMs"), "first_prompt_ms": agent.get("firstPromptMs"),
             "to_agent_ms": turn.get("toAgentMs"), "first_model_ms": turn.get("firstModelMs"),
             "turn_wall_ms": turn.get("wallMs")}
    return {"select_to_first_text_stages": {"before_turn_ms": before, "turn_ms": max(0, result["ms"] - before - after),
                                            "after_turn_ms": after},
            "turn_marks_ms": {k: v for k, v in marks.items() if isinstance(v, int)}}


def p50s(rows: list[dict], key: str) -> dict:
    keys = sorted({k for r in rows for k in (r.get(key) or {})})
    return {k: statistics.median([r[key][k] for r in rows if k in (r.get(key) or {})]) for k in keys}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--app", required=True)
    ap.add_argument("--base-url", required=True)
    ap.add_argument("--claude", required=True, help="the Claude Code binary to put in the scratch HOME")
    ap.add_argument("--model", default="claude-haiku-5-5")
    ap.add_argument("--rounds", type=int, default=5)
    ap.add_argument("--ref", default="")
    ap.add_argument("--json", required=True)
    o = ap.parse_args()
    acp_home = tempfile.mkdtemp(prefix="lcfr-acpmux-")
    acp_sock = os.path.join(tempfile.mkdtemp(prefix="lcfr-", dir="/tmp"), "acp.sock")
    route = {"ANTHROPIC_BASE_URL": o.base_url, "ANTHROPIC_API_KEY": PLACEHOLDER_KEY, "DISABLE_AUTOUPDATER": "1"}
    extra = {**route, "ACPMUX_HOME": acp_home, "ACPMUX_SOCKET": acp_sock}
    pid, socket_path, scratch = bm.launch(o.app, {}, extra_env=extra, direct=True)
    home = os.path.join(scratch, "home")
    report = {"ref": o.ref, "app": o.app, "model": o.model, "base_url": o.base_url, "rounds": []}
    status = 0
    run = None
    try:
        os.makedirs(os.path.join(home, ".local", "bin"), exist_ok=True)
        os.symlink(os.path.abspath(o.claude), os.path.join(home, ".local", "bin", "claude"))
        env = {"HOME": home, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": os.path.join(scratch, "tmp") + "/",
               "USER": os.environ.get("USER", ""), "CLAUDE_CONFIG_DIR": os.path.join(home, ".claude"), **extra}
        run = Run(o.app, socket_path, env)
        deadline = time.monotonic() + 60
        while not run.app.ping():
            if time.monotonic() > deadline:
                raise SystemExit("local-chat-first-reply: the app's control socket did not answer within 60 s")
            time.sleep(0.5)
        say("app pid", pid, "identify", json.dumps(run.app.identify())[:300])
        neutral = os.path.join(scratch, "neutral")
        os.makedirs(neutral, exist_ok=True)
        restart_daemon(run)
        warm = person_chat(run, neutral, o.model)
        say("warm-up", json.dumps(warm)[:600])
        report["warm_up"] = warm
        if not warm.get("ok"):
            status = 1
        for r in range(1, o.rounds + 1):
            restart_daemon(run)
            spare = spare_ready(run)
            row = person_chat(run, neutral, o.model)
            row["round"], row["spare"] = r, spare
            report["rounds"].append(row)
            say(f"round {r}", json.dumps({k: row.get(k) for k in ("ok", "ms", "error", "created_by", "spare",
                                                                  "select_to_first_text_stages", "turn_marks_ms",
                                                                  "new_chat_ms", "composer_sent_ms", "session_seen_ms")}))
    finally:
        if run is not None:
            run.acp("daemon", "stop", "--end-agents", timeout=120)
        bm.end_bundle(o.app)
        good = [r for r in report["rounds"] if r.get("ok")]
        summary = {"ref": o.ref, "model": o.model, "n": len(good), "failed": len(report["rounds"]) - len(good),
                   "select_to_first_text_ms": {"p50": statistics.median([r["ms"] for r in good]) if good else None,
                                               "samples": [r["ms"] for r in good]},
                   "stages_p50": p50s(good, "select_to_first_text_stages"), "turn_marks_p50": p50s(good, "turn_marks_ms"),
                   "spare_ready": [r["spare"].get("ready") for r in report["rounds"]],
                   "created_by": sorted({str(r.get("created_by")) for r in good})}
        report["summary"] = summary
        os.makedirs(os.path.dirname(os.path.abspath(o.json)), exist_ok=True)
        with open(o.json, "w") as f:
            json.dump(report, f, indent=2)
        print("LOCAL-CHAT-FIRST-REPLY " + json.dumps(summary), flush=True)
        shutil.rmtree(scratch, ignore_errors=True)
        shutil.rmtree(acp_home, ignore_errors=True)
        shutil.rmtree(os.path.dirname(acp_sock), ignore_errors=True)
    if not report["rounds"] or any(not r.get("ok") for r in report["rounds"]):
        status = 1
    return status


if __name__ == "__main__":
    sys.exit(main())
