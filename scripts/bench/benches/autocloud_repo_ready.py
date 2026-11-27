"""autocloud-repo-ready: AutoCloud start's repo-ready time, full `git clone` vs the warm blobless mirror.

Wraps `scripts/measure/autocloud-repo-ready.sh` (the same git steps as acpmux's
`auto_session/import/mirror.rs`, cmux#55715), which prints a Markdown table:
  | before | 1 | 61.20 | 1083.4 | ok |        (row, run, repo-ready s, from GitHub MB, clean+upstream)
Rows (label arm = before | after-cold | after-warm), better = lower:
  repo_ready (s): empty folder to a clean checked-out branch with its upstream, median of the runs;
  from_github (MB): pack bytes git received for that start;
  speedup (x, better = higher): before's median over each after arm's median.
A run whose checkout is not clean or has no upstream (BAD) records a note, not a number.
Run anywhere with network: `cmux-bench autocloud-repo-ready --host anywhere [--arg remote=URL]
[--arg branch=main] [--arg n=3]`; `--import LOG` reads a run's output.
"""
from __future__ import annotations

import re
import shlex
import statistics
import subprocess
from pathlib import Path

from benchlib.bench import REPO_ROOT, Bench, BenchError, Context

HARNESS = "scripts/measure/autocloud-repo-ready.sh"
ARMS = ("before", "after-cold", "after-warm")
ROW = re.compile(r"^\|\s*(before|after-cold|after-warm)\s*\|\s*(\d+)\s*\|\s*([\d.]+)\s*\|\s*([\d.-]+)\s*\|\s*(\w+)\s*\|")


class AutocloudRepoReady(Bench):
    name = "autocloud-repo-ready"
    summary = "AutoCloud start's repo-ready seconds and GitHub MB: full git clone vs warm blobless mirror + alternates"
    units = "s, MB, x"
    owner = "AutoCloud start (cmux#55715)"
    hosts = ("anywhere",)
    harness = HARNESS
    version = "1"
    floors = {"repo_ready": 0.5}

    def run(self, ctx: Context) -> None:
        cmd = ["bash", str(REPO_ROOT / HARNESS), ctx.arg("remote") or "https://github.com/manaflow-ai/cmux.git",
               ctx.arg("branch") or "main", ctx.arg("n") or "3"]
        if ctx.dry_run:
            print("dry run:", shlex.join(cmd))
            raise BenchError("dry run")
        got = subprocess.run(cmd, cwd=REPO_ROOT, text=True, capture_output=True, timeout=7200, check=False)
        log = ctx.workdir / "autocloud-repo-ready.txt"
        log.write_text(got.stdout + got.stderr, encoding="utf-8")
        if got.returncode:
            raise BenchError(f"{self.name}: harness failed ({got.returncode}): {got.stderr.strip()[-500:]}")
        self.ingest(ctx, log)

    def ingest(self, ctx: Context, path: Path) -> None:
        try:
            text = Path(path).read_text(encoding="utf-8")
        except OSError as exc:
            raise BenchError(f"{self.name}: {path}: {exc}") from exc
        secs: dict[str, list[float]] = {a: [] for a in ARMS}
        mbs: dict[str, list[float]] = {a: [] for a in ARMS}
        for line in text.splitlines():
            if line.startswith("Duress"):
                ctx.notes.append(line.strip()[:300])
            m = ROW.match(line.strip())
            if not m:
                continue
            arm, run, s, mb, ok = m.groups()
            if ok != "ok":
                ctx.notes.append(f"{arm} run {run}: checkout {ok}")
                continue
            secs[arm].append(float(s))
            mbs[arm].append(max(float(mb), 0.0))
        if not any(secs.values()):
            raise BenchError(f"{self.name}: {path}: no measured rows")
        for arm in ARMS:
            if secs[arm]:
                ctx.row("repo_ready", unit="s", samples=secs[arm], labels={"arm": arm})
                ctx.row("from_github", unit="MB", samples=mbs[arm], labels={"arm": arm})
        if secs["before"]:
            base = statistics.median(secs["before"])
            for arm in ("after-cold", "after-warm"):
                if secs[arm]:
                    ctx.row("speedup", base / max(statistics.median(secs[arm]), 1e-3), "x", better="higher",
                            labels={"arm": arm})


BENCH = AutocloudRepoReady()
