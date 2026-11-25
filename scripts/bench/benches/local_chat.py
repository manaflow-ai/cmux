"""local-chat: select to first reply of a local chat a person starts, on a fresh build of a commit, with a real model.

Wraps scripts/measure/local-chat-first-reply.sh (goal local-instant-start): the timed chat of cmuxterm-hq's synthetic
probe `local-chat` (tools/fleet-reconcilers/local_chat_probe.py), which times only the published NIGHTLY, here on a
fleet Mac at any commit (`--arg build=SHA`, a pull request's head). Per round: the daemon restarts, the probe's wait
for a ready spare, then the app's New chat and the composer's Send (debug.agent_pane compose_send, a person's
gesture), timed to the turn's end. The line it reads:

  LOCAL-CHAT-FIRST-REPLY {"ref", "n", "failed", "select_to_first_text_ms": {"p50", "samples"}, "stages_p50": {..},
                          "turn_marks_p50": {..}, "spare_ready": [..]}

Rows (ms, better = lower): select_to_first_text, stage.before_turn, stage.turn, stage.after_turn, and mark.agent_ready,
mark.first_prompt, mark.to_agent, mark.first_model, mark.turn_wall; failed_rounds (count).

Run: `cmux-bench local-chat --host fleet [--arg build=SHA] [--arg rounds=5]` (base_url defaults to SR2, the team route
that signs requests itself, so no credential reaches the worker).
"""
from __future__ import annotations

import json
from pathlib import Path

from benchlib.bench import Bench, BenchError, Context

HARNESS = "scripts/measure/local-chat-first-reply.sh"
ARTIFACT = "artifacts/local-chat-first-reply.json"
SR2 = "http://100.120.48.119:4016"
PASS_THROUGH = ("base_url", "build", "rounds", "model", "claude")
MARK = "LOCAL-CHAT-FIRST-REPLY "


def summary(text: str) -> dict | None:
    found = None
    for line in text.splitlines():
        at = line.find(MARK)
        if at >= 0:
            try:
                found = json.loads(line[at + len(MARK):])
            except json.JSONDecodeError:
                pass
    return found if isinstance(found, dict) else None


class LocalChat(Bench):
    name = "local-chat"
    summary = "Local chat select to first reply on a build of a commit (New chat, Send, turn end), stages and turn marks"
    units = "ms, count"
    owner = "local-instant-start"
    hosts = ("fleet",)
    harness = HARNESS
    version = "1"
    nightly = False

    def run(self, ctx: Context) -> None:
        args = {"base_url": SR2} | {k: v for k, v in ctx.args.items() if k in PASS_THROUGH}
        res = ctx.fleet_step(HARNESS, [f"{k}={v}" for k, v in args.items()], ARTIFACT, step_class="exclusive",
                             labels=("measure",), timeout=5400, display=True)
        self.ingest(ctx, res.log_path)

    def ingest(self, ctx: Context, path: Path) -> None:
        text = Path(path).read_text(encoding="utf-8", errors="replace")
        s = summary(text)
        if s is None and text.lstrip().startswith("{"):
            s = (json.loads(text) or {}).get("summary")
        if not s:
            raise BenchError(f"{path}: no {MARK.strip()} line (not a local-chat-first-reply.sh log or JSON)")
        n = s.get("n")
        p50 = (s.get("select_to_first_text_ms") or {}).get("p50")
        if p50 is not None:
            ctx.row("select_to_first_text", float(p50), "ms", n=n)
        for key, value in (s.get("stages_p50") or {}).items():
            ctx.row("stage." + key.removesuffix("_ms"), float(value), "ms", n=n)
        for key, value in (s.get("turn_marks_p50") or {}).items():
            ctx.row("mark." + key.removesuffix("_ms"), float(value), "ms", n=n)
        ctx.row("failed_rounds", float(s.get("failed") or 0), "count", n=n)
        ctx.notes.append(f"local-chat: ref {s.get('ref')}, model {s.get('model')}, spare ready {s.get('spare_ready')}")


BENCH = LocalChat()
