"""tui-idle: the idle cmux-tui daemon's memory on Linux at one or more commits, from one harness on one runner.

Wraps scripts/measure/tui-idle-ram.sh (CMUX-571, goal ram-baseline): for each commit it builds the release
daemon, starts it headless on a scratch home with one workspace and one terminal, waits 20 s and reads
/proc/<pid>/smaps_rollup, its threads and its largest mappings, three launches per commit; with --arg dhat=1 also
a dhat-heap build's Rust heap at exit and at peak. Every line it prints starts with TUI-IDLE (or DHAT), which
`ingest` reads:

  TUI-IDLE-AT <40-char sha> <subject>
  TUI-IDLE-BUILD <sha12> <s> s; cmux-tui <bytes> bytes
  TUI-IDLE-SECTION <sha12> .<section> <bytes> <address>
  TUI-IDLE {"label": "<sha12>-r<N>" | "<sha12>-dhat", "daemon_pss_anon_mb": .., "daemon_pss_mb": .., ...}
  <sha12> DHAT <file> gmax_bytes=.. end_bytes=.. sites=..

Rows (labels: commit = the first 12 characters), better = lower:
  anon (MB): the daemon's anonymous PSS, the memory that phys_footprint counts on a Mac (its heap, other
    anonymous maps, stacks); clean pages of the binary are not in it. Not Private_Dirty: the first launch after a
    link reads the binary's still-dirty page cache as private dirty (47.5 MB once, 15 MB after).
  pss, pss_file, rss (MB); threads (count); children_pss (MB): the terminal hosts and the shell;
  binary (MB): the cmux-tui file; section (MB, label section): .text, .rodata, .data.rel.ro, .got, ...;
  heap_end, heap_peak (MB): dhat's live Rust heap at exit and at its peak (dhat=1 only; the dhat launch's own
    smaps rows are left out, dhat's bookkeeping is in them).

Run: `cmux-bench tui-idle --build SHA [--arg commits=SHA,SHA] [--arg dhat=1]` sends the harness through `cmux-ci test`
(Linux, at the caller's open PR head on a lane VM) with every commit resolved to all 40 characters here, and
reads the log the harness writes to $FAST_CHECKS_OUT. `--import LOG` reads a run's log (the full one:
`gh api repos/manaflow-ai/cmux/actions/runs/RUN/logs`, 0_checks.txt).
"""
from __future__ import annotations

import json
import re
import shlex
import subprocess
from pathlib import Path

from benchlib.bench import REPO_ROOT, Bench, BenchError, Context

HARNESS = "scripts/measure/tui-idle-ram.sh"
PASS_THROUGH = ("dhat", "workspaces", "settle", "profile", "arenas")
MB = 1024 * 1024
# A GitHub Actions log prefixes each line with its time.
STAMP = re.compile(r"^\d{4}-\d\d-\d\dT[\d:.]+Z ")
AT = re.compile(r"^TUI-IDLE-AT ([0-9a-f]{40})\b")
BUILD = re.compile(r"^TUI-IDLE-BUILD ([0-9a-f]{12}) \d+ s; cmux-tui (\d+) bytes")
SECTION = re.compile(r"^TUI-IDLE-SECTION ([0-9a-f]{12}) \.([\w.]+)\s+(\d+)\s+\d+")
IDLE = re.compile(r"^TUI-IDLE (\{.*\})$")
DHAT = re.compile(r"^([0-9a-f]{12}) DHAT \S+ gmax_bytes=(\d+) end_bytes=(\d+)")
RUN_LABEL = re.compile(r"^([0-9a-f]{12})-(r\d+|dhat)$")
SAMPLED = (("anon", "daemon_pss_anon_mb", "MB"), ("pss", "daemon_pss_mb", "MB"),
           ("pss_file", "daemon_pss_file_mb", "MB"), ("rss", "daemon_rss_mb", "MB"),
           ("threads", "threads", "count"), ("children_pss", "children_pss_mb", "MB"))


def resolve(commit: str) -> str:
    """A commit by any unique prefix, as all 40 characters (GitHub fetches a commit only by its full id)."""
    got = subprocess.run(["git", "-C", str(REPO_ROOT), "rev-parse", "-q", "--verify", f"{commit}^{{commit}}"],
                         text=True, capture_output=True)
    if got.returncode != 0:
        raise BenchError(f"tui-idle: {commit} is not a commit in this checkout; fetch it or pass all 40 characters")
    return got.stdout.strip()


class TuiIdle(Bench):
    name = "tui-idle"
    summary = "Idle cmux-tui daemon memory on Linux (anonymous PSS, PSS, threads, binary sections) at commits"
    units = "MB, count"
    owner = "perf (CMUX-571 ram-baseline)"
    hosts = ("fleet",)
    harness = HARNESS
    version = "1"
    thresholds = {"anon": 10.0, "pss": 10.0, "threads": 10.0}
    floors = {"anon": 1.0, "pss": 2.0, "pss_file": 2.0, "rss": 2.0, "children_pss": 1.0, "binary": 1.0,
              "section": 0.25, "heap_end": 0.5, "heap_peak": 0.5}

    def commits(self, ctx: Context) -> list[str]:
        listed = [c for c in (ctx.arg("commits") or "").split(",") if c]
        if not listed and ctx.build.get("sha"):
            listed = [ctx.build["sha"]]
        if not listed:
            raise BenchError("tui-idle: name a commit (--build SHA or --arg commits=SHA,SHA)")
        return [resolve(c) for c in listed]

    def run(self, ctx: Context) -> None:
        args = [f"{k}={v}" for k, v in ctx.args.items() if k in PASS_THROUGH] + self.commits(ctx)
        out = ctx.workdir / "artifact"
        command = (f"set -o pipefail; {{ exec 2>&1; {HARNESS} {shlex.join(args)}; }}"
                   ' | tee "$FAST_CHECKS_OUT/tui-idle-ram.log"')
        cmd = ["cmux-ci", "test", "--timeout", "7200", "--artifact", str(out), "--", "bash", "-c", command]
        if ctx.dry_run:
            print("dry run:", shlex.join(cmd))
            raise BenchError("dry run")
        log = ctx.workdir / "tui-idle-ram.log"
        with log.open("w", encoding="utf-8") as f:
            result = subprocess.run(cmd, stdout=f, stderr=subprocess.STDOUT, text=True, check=False)
        if result.returncode:
            raise BenchError(f"tui-idle failed ({result.returncode}); see {log} and {out}")
        full = out / "tui-idle-ram.log"
        ctx.host.update({"name": "linux-ci", "os": "Linux"})
        self.ingest(ctx, full if full.exists() else log)

    def ingest(self, ctx: Context, path: Path) -> None:
        text = Path(path).read_text(encoding="utf-8", errors="replace")
        runs: dict[str, list[dict]] = {}
        found = 0
        for raw in text.splitlines():
            line = STAMP.sub("", raw.strip())
            if m := AT.match(line):
                runs.setdefault(m.group(1)[:12], [])
                found += 1
            elif m := BUILD.match(line):
                ctx.row("binary", int(m.group(2)) / MB, "MB", labels={"commit": m.group(1)})
            elif m := SECTION.match(line):
                ctx.row("section", int(m.group(3)) / MB, "MB", labels={"commit": m.group(1), "section": m.group(2)})
            elif m := DHAT.match(line):
                ctx.row("heap_peak", int(m.group(2)) / MB, "MB", labels={"commit": m.group(1)})
                ctx.row("heap_end", int(m.group(3)) / MB, "MB", labels={"commit": m.group(1)})
            elif m := IDLE.match(line):
                try:
                    sample = json.loads(m.group(1))
                except json.JSONDecodeError:
                    continue
                label = RUN_LABEL.match(str(sample.get("label", "")))
                if label and label.group(2) != "dhat":
                    runs.setdefault(label.group(1), []).append(sample)
        if not found:
            raise BenchError(f"{path}: no TUI-IDLE-AT line (not a tui-idle-ram.sh log?)")
        for commit, samples in runs.items():
            if not samples:
                ctx.notes.append(f"tui-idle: {commit} has no idle sample (its build or launch failed)")
                continue
            for metric, key, unit in SAMPLED:
                ctx.row(metric, unit=unit, samples=[s.get(key) for s in samples], labels={"commit": commit})


BENCH = TuiIdle()
