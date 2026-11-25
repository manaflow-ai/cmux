"""persona-walk: a person's first minutes with a fresh NEXT NIGHTLY on a fleet Mac, every night.

Leo, 2026-11-25: "how would "normal" or casual or relatively hardcore people do... anything? ... is someone 2024,
2025, 2026, living in the absolute future (maybe like me), or 2023 and before? those usecases". The personas and
their tasks are cmuxterm-hq docs/dogfood/personas; the scorecard there reads these rows.

The harness is scripts/measure/persona-walk.sh (mode=p0: download the newest NIGHTLY, install a scratch copy with its
own HOME, launch it, type a first message with Computer Use, read what the app answered). It needs a display worker
whose CuaDriver holds the Screen Recording and Accessibility grants (--arg worker=HOST, default cmux22).

Rows (better = lower): install, first_window, first_command (ms), and each task the casual and hardcore modes
finished (shell_in_new_tab, split, million_lines, reopen_window, ...; ms); tasks_done (count, better = higher); footprint (MB, the app's physical footprint at
first-window, after-5s and after-walk, labelled stage=); stuck_points (count of STUCK and FAIL lines the walk wrote:
a person hit a wall); first_reply_failed (1 when the Chief's answer to the first message was a failed turn).

  cmux-bench persona-walk --host fleet [--arg mode=p0|p0-casual|p0-hardcore] [--arg worker=HOST]
  cmux-bench persona-walk --import report.tgz   (a walk's artifact, or the directory it unpacks to)
"""
from __future__ import annotations

import json
import re
import subprocess
import tarfile
import tempfile
from pathlib import Path

from benchlib.bench import Bench, BenchError, Context

HARNESS = "scripts/measure/persona-walk.sh"
ARTIFACT = "artifacts/persona-walk/report.tgz"
STEPS = ("install", "first_window", "first_command")
# A note line the walk writes: "HH:MM:SS STUCK ..." or "HH:MM:SS FAIL ..." (not tool output that says FAIL).
STUCK = re.compile(r"^\d\d:\d\d:\d\d (STUCK|FAIL)\b(.*)$", re.M)
FOOTPRINT = re.compile(r"Footprint:\s*([\d.]+)\s*(KB|MB|GB)", re.I)
SCALE = {"KB": 1 / 1024, "MB": 1.0, "GB": 1024.0}


def unpack(path: Path) -> Path:
    if path.is_dir():
        return path
    if not tarfile.is_tarfile(path):
        raise BenchError(f"{path}: not a persona-walk report (a .tgz or its directory)")
    out = Path(tempfile.mkdtemp(prefix="persona-walk-"))
    with tarfile.open(path) as tar:
        tar.extractall(out, filter="data")
    return out


def jsonl(path: Path) -> list[dict]:
    if not path.exists():
        return []
    rows = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return [r for r in rows if isinstance(r, dict)]


class PersonaWalk(Bench):
    name = "persona-walk"
    summary = "A person's first minutes with a fresh NIGHTLY: install, first window, first message, memory, stuck points"
    units = "ms, MB, count"
    owner = "persona dogfood lane"
    hosts = ("fleet",)
    harness = HARNESS
    version = "1"
    thresholds = {"stuck_points": 0.0, "first_reply_failed": 0.0}
    floors = {"stuck_points": 0.0, "first_reply_failed": 0.0}
    nightly = True
    nightly_args = {"mode": "p0", "worker": "cmux22"}

    def run(self, ctx: Context) -> None:
        ctx.args.setdefault("worker", "cmux22")
        res = ctx.fleet_step(HARNESS, [f"mode={ctx.arg('mode', 'p0')}"], ARTIFACT, labels=("measure",),
                             timeout=1200, display=True)
        if res.artifact_path is None and res.job_id:  # a walk that hit a wall still packs its report
            got = ctx.workdir / "report.tgz"
            if subprocess.run(["cmux-ci", "artifact", res.job_id, str(got)], capture_output=True).returncode == 0 \
                    and got.exists():
                res.artifact_path = got
        if res.artifact_path is None:
            raise BenchError(f"persona-walk: no report from job {res.job_id or '?'} (log {res.log_path})")
        self.ingest(ctx, res.artifact_path)

    def ingest(self, ctx: Context, path: Path) -> None:
        root = unpack(Path(path))
        timings = {r.get("step"): r.get("ms") for r in jsonl(root / "timings.jsonl")}
        log = (root / "log.txt").read_text(encoding="utf-8", errors="replace") if (root / "log.txt").exists() else ""
        if not timings and not log:
            raise BenchError(f"{path}: no timings.jsonl or log.txt (not a persona-walk report)")
        for step in STEPS:
            if timings.get(step) is None:
                ctx.notes.append(f"persona-walk: {step} not reached")
        # Every step the walk timed is a row: p0's three, and each task the casual and hardcore modes finished.
        for step, ms in timings.items():
            if isinstance(step, str) and isinstance(ms, (int, float)):
                ctx.row(step, float(ms), "ms")
        ctx.row("tasks_done", float(len([s for s in timings if s != "install"])), "count", better="higher")
        for m in jsonl(root / "memory.jsonl"):
            fp = FOOTPRINT.search(str(m.get("footprint") or ""))
            if fp:
                ctx.row("footprint", round(float(fp.group(1)) * SCALE[fp.group(2).upper()], 1), "MB",
                        labels={"stage": m.get("label") or "?"})
        stuck = STUCK.findall(log)
        ctx.row("stuck_points", float(len(stuck)), "count")
        failed = [detail for kind, detail in stuck if detail.strip().startswith("first message:")]
        ctx.row("first_reply_failed", 1.0 if failed else 0.0, "count")
        for kind, detail in stuck:
            ctx.notes.append(f"persona-walk: {kind}{detail[:200]}")
        install = root / "install.json"
        if install.exists():
            try:
                dmg = json.loads(install.read_text()).get("dmg") or ""
            except json.JSONDecodeError:
                dmg = ""
            if dmg:
                ctx.notes.append(f"persona-walk: NIGHTLY {dmg.rsplit('/', 1)[-1]}")


BENCH = PersonaWalk()
