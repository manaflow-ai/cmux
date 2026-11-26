"""app-stream-bytes: what acpmux sends the app's chat panes while chats stream, by kind, and its CPU (CMUX-571).

Wraps scripts/measure/app-stream-bytes.sh, which runs cmux-tui/crates/acpmux/tests/app_stream_bytes.rs: a real
daemon with stand-in agents, one WebSocket per chat pane opened as the app's page opens it (status, the row watch,
the plain attach of its chat), `chats` panes of which `shown` are on screen, every chat streaming `ticks` chunks
`tick_ms` apart. Each run prints, per arm and round, one summary line and one line per kind:

  app-stream-bytes: {"quietHidden": false, "chats": 8, "shown": 2, ..., "totalBytesPerSec": N,
                     "shownBytesPerSec": N, "hiddenBytesPerSec": N, "daemonCpuMsPerSec": N}
  app-stream-bytes-kind: {"quietHidden": false, "scope": "hidden", "row": {"kind", "bytesPerSec", "messages"}}

quietHidden false is the app before `quietHidden` (every pane got its chat's stream), true is the app now.

Rows (better = lower), labels arm (before, after):
  total_bytes_per_s, shown_bytes_per_s, hidden_bytes_per_s (bytes a second), daemon_cpu_ms_per_s (ms of CPU a
  second), with labels chats and shown; kind_bytes_per_s (bytes a second) with labels scope (shown, hidden) and
  kind (a method, with the record kind of a stream record: `_acpmux/event:agent_message_chunk`).
Rounds are samples of one row. `--arg rounds=3 --arg chats=8 --arg shown=2 --arg ticks=400 --arg tick_ms=10`.
"""
from __future__ import annotations

import json
from pathlib import Path

from benchlib.bench import Bench, BenchError, Context

HARNESS = "scripts/measure/app-stream-bytes.sh"
PASS_THROUGH = ("rounds", "chats", "shown", "ticks", "tick_ms")
SUMMARY = "app-stream-bytes: "
KIND = "app-stream-bytes-kind: "


def _json_after(line: str, prefix: str) -> dict | None:
    at = line.find(prefix)
    if at < 0:
        return None
    try:
        value = json.loads(line[at + len(prefix):])
    except ValueError:
        return None
    return value if isinstance(value, dict) else None


def _arm(run: dict) -> str:
    return "after" if run.get("quietHidden") else "before"


class AppStreamBytes(Bench):
    name = "app-stream-bytes"
    summary = "Bytes/s acpmux sends the app's chat panes while chats stream (by kind, shown and hidden) and its CPU"
    units = "bytes (per s), ms (CPU per s)"
    owner = "perf (CMUX-571)"
    hosts = ("fleet",)
    harness = HARNESS
    version = "1"
    # Stream bytes follow the stand-in agent and move little; CPU ms/s on a shared worker moves more.
    thresholds = {"daemon_cpu_ms_per_s": 25.0}
    nightly = False

    def run(self, ctx: Context) -> None:
        args = [f"{k}={v}" for k, v in ctx.args.items() if k in PASS_THROUGH]
        res = ctx.fleet_step(self.harness, args, None, step_class="exclusive", labels=("measure",), timeout=3600,
                             ref=ctx.build.get("sha"))
        self.ingest(ctx, res.log_path)

    def ingest(self, ctx: Context, path: Path) -> None:
        samples: dict[tuple, list[float]] = {}
        units: dict[tuple, str] = {}

        def add(metric: str, value: object, unit: str, labels: dict[str, str]) -> None:
            if isinstance(value, bool) or not isinstance(value, (int, float)):
                return
            key = (metric, tuple(sorted(labels.items())))
            samples.setdefault(key, []).append(float(value))
            units[key] = unit

        found = 0
        for line in Path(path).read_text(encoding="utf-8", errors="replace").splitlines():
            if (kind := _json_after(line, KIND)) is not None:
                row = kind.get("row") or {}
                add("kind_bytes_per_s", row.get("bytesPerSec"), "bytes",
                    {"arm": _arm(kind), "scope": str(kind.get("scope")), "kind": str(row.get("kind"))})
                continue
            if (run := _json_after(line, SUMMARY)) is None:
                continue
            found += 1
            base = {"arm": _arm(run), "chats": str(run.get("chats")), "shown": str(run.get("shown"))}
            add("total_bytes_per_s", run.get("totalBytesPerSec"), "bytes", base)
            add("shown_bytes_per_s", run.get("shownBytesPerSec"), "bytes", base)
            add("hidden_bytes_per_s", run.get("hiddenBytesPerSec"), "bytes", base)
            add("daemon_cpu_ms_per_s", run.get("daemonCpuMsPerSec"), "ms", base)
        if not found:
            raise BenchError(f"{path}: no `{SUMMARY.strip()}` line (not an app-stream-bytes.sh log?)")
        for (metric, labels), values in samples.items():
            ctx.row(metric, unit=units[(metric, labels)], samples=values, labels=dict(labels))


BENCH = AppStreamBytes()
