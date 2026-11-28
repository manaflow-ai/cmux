"""Cloud chat first-byte timing while Cloud Git is active."""
from __future__ import annotations

import json
import math
import re
from pathlib import Path

from benchlib.bench import Bench, BenchError, Context

HARNESS = "scripts/measure/cloud-first-byte.sh"
MARK = "CLOUD-FIRST-BYTE "


def report(path: Path) -> dict:
    found = None
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if MARK in line:
            try:
                found = json.loads(line.split(MARK, 1)[1])
            except json.JSONDecodeError:
                continue
    if not isinstance(found, dict):
        raise BenchError(f"cloud-first-byte: no {MARK.strip()} line in {path}")
    return found


class CloudFirstByte(Bench):
    name = "cloud-first-byte"
    summary = "Cloud chat first response byte while a concurrent Cloud Git operation is active"
    units = "ms, count"
    owner = "office queue pathway (ask-c8688c0b05)"
    hosts = ("fleet",)
    harness = HARNESS
    version = "2"
    nightly = False

    def run(self, ctx: Context) -> None:
        for key in ("ref", "chat-command", "git-command", "completion-marker"):
            if not ctx.arg(key):
                raise BenchError(f"cloud-first-byte: --arg {key}=VALUE is required")
        if not re.fullmatch(r"[0-9a-f]{40}", ctx.arg("ref")):
            raise BenchError("cloud-first-byte: ref must be a full pushed SHA")
        samples = ctx.arg("samples") or "5"
        parallel = ctx.arg("parallel") or "1"
        timeout = ctx.arg("timeout") or "300"
        if not samples.isdigit() or not parallel.isdigit():
            raise BenchError("cloud-first-byte: samples and parallel must be counts")
        try:
            seconds = float(timeout)
        except ValueError as exc:
            raise BenchError("cloud-first-byte: timeout must be finite and positive") from exc
        if not math.isfinite(seconds) or seconds <= 0 or not 0 < int(parallel) <= int(samples):
            raise BenchError("cloud-first-byte: positive samples/timeout and parallel <= samples required")
        args = ["--json=artifacts/cloud-first-byte.json", f"--samples={samples}", f"--parallel={parallel}", f"--timeout={timeout}"]
        for key in ("chat-command", "git-command", "completion-marker"):
            if ctx.arg(key):
                args += [f"--{key}={ctx.arg(key)}"]
        result = ctx.fleet_step(HARNESS, args=args, artifact="artifacts/cloud-first-byte.json",
                                step_class="exclusive", labels=("measure",), timeout=math.ceil(seconds * math.ceil(int(samples) / int(parallel))) + 10)
        self.ingest(ctx, result.log_path)
        if result.exit_code != 0:
            raise BenchError(f"cloud-first-byte: fleet step exited {result.exit_code}")

    def ingest(self, ctx: Context, path: Path) -> None:
        found = report(path)
        if found.get("schema") != "cloud-first-byte/v2" or found.get("measurement") != "command_stdout_first_byte":
            raise BenchError("cloud-first-byte: unsupported measurement semantics")
        rows = found.get("rows", [])
        if not isinstance(rows, list) or not rows or len(rows) != found.get("samples"):
            raise BenchError("cloud-first-byte: missing sample rows")
        ctx.notes.append(f"cloud-first-byte host={found.get('host')} commit={found.get('commit')}")
        ctx.notes.append(f"flow_completed={found.get('flow_completed')} errors={found.get('errors')} timeouts={found.get('timeouts')}")
        values = [row["first_byte_ms"] for row in found.get("rows", [])
                  if isinstance(row, dict) and row.get("flow_completed")
                  and isinstance(row.get("first_byte_ms"), (int, float))]
        if values:
            ctx.row("first_byte", unit="ms", samples=values)
        ctx.row("completed", float(found.get("completed", 0)), "count", n=found.get("samples"))
        ctx.row("errors", float(found.get("errors", 0)), "count", n=found.get("samples"))
        ctx.row("timeouts", float(found.get("timeouts", 0)), "count", n=found.get("samples"))
        if (not found.get("flow_completed") or len(values) != len(rows)
                or found.get("errors") != 0 or found.get("timeouts") != 0
                or found.get("completed") != len(rows)):
            raise BenchError("cloud-first-byte: flow did not complete; see harness receipt")


BENCH = CloudFirstByte()
