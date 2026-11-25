"""ext-reload: extension hot reload on a published NIGHTLY, save to shown, with no rebuild asked.

Wraps scripts/measure/ext-reload-nightly.sh (scripts/measure/ext-reload-nightly.py) on a fleet Mac with a console
session: the NIGHTLY DMG copied into a side instance, then
- read-back: `cmux ext dev` left watching a copy of examples/extensions/activity, a one-line save, then reads only
  (the watcher's own reload line, the daemon's loaded copy, the window's open views);
- edit-repaint.py in read-back mode: the customize folder's section, rows and pane, a palette command and a key
  binding saved `rounds` times each, each round timed to the window's own read-back showing it.
It prints its receipt as one line:

  EXT_RELOAD_NIGHTLY {"ok": .., "readback": {"save_to_reload_ms": .., "checks": {..}}, "edit_repaint": {CASE: {..}}}

Rows (better = lower): save_to_reload (ms), labels case=activity: the save to the watcher's reload line.
save_to_shown (ms), labels case (extension, rows, pane, command, shortcut) and bound (upper, lower): the medians
of edit-repaint's rounds (upper: the first read-back that showed the save; lower: the last that did not).
missed (count), labels case: rounds whose save never showed. checks_failed (count): the read-back checks that
failed (0 on a passing run).

The build is the published app itself: --build nightly measures the newest NIGHTLY DMG; any other build needs
--arg dmg=https://...dmg. --arg rounds=N passes through. `--import LOG` reads a fleet log or receipt.json.
"""
from __future__ import annotations

import json
import re
import subprocess
from pathlib import Path

from benchlib.bench import Bench, BenchError, Context

HARNESS = "scripts/measure/ext-reload-nightly.sh"
ARTIFACT = ".build/ext-reload-nightly/report.tgz"
LINE = re.compile(r"EXT_RELOAD_NIGHTLY (\{.*\})\s*$")


class ExtReload(Bench):
    name = "ext-reload"
    summary = "Extension hot reload on a NIGHTLY: save to shown in the window, no rebuild asked (fleet Mac)"
    units = "ms, count"
    owner = "extension capability matrix (hot reload)"
    hosts = ("fleet",)
    harness = HARNESS
    version = "1"
    thresholds = {"save_to_reload": 25.0, "save_to_shown": 25.0}
    nightly = False

    def harness_args(self, ctx: Context) -> list[str]:
        args = []
        dmg = ctx.arg("dmg")
        if dmg:
            if not dmg.startswith("https://"):
                raise BenchError("ext-reload: --arg dmg= takes an https:// URL of a NIGHTLY DMG")
            args.append(f"dmg={dmg}")
        elif ctx.build.get("channel") != "nightly":
            raise BenchError("ext-reload: measures a published app; pass --build nightly or --arg dmg=https://...dmg")
        if ctx.arg("rounds"):
            args.append(f"rounds={ctx.arg('rounds')}")
        return args

    def run(self, ctx: Context) -> None:
        res = ctx.fleet_step(self.harness, self.harness_args(ctx), ARTIFACT, step_class="exclusive",
                             labels=("measure",), timeout=1800, display=True)
        log = res.log_path
        if "EXT_RELOAD_NIGHTLY {" not in res.log and res.job_id:
            full = ctx.workdir / f"{res.job_id}.log"
            got = subprocess.run(["cmux-ci", "log", res.job_id, "--tail", "200000"], text=True, capture_output=True)
            if got.returncode == 0:
                full.write_text(got.stdout)
                log = full
        self.ingest(ctx, log)

    @staticmethod
    def receipt(path: Path) -> dict:
        """The last receipt in a log (EXT_RELOAD_NIGHTLY {json}), or a receipt.json itself."""
        text = Path(path).read_text(encoding="utf-8", errors="replace")
        try:
            whole = json.loads(text)
            if isinstance(whole, dict) and "readback" in whole:
                return whole
        except ValueError:
            pass
        found = None
        for line in text.splitlines():
            if m := LINE.search(line):
                try:
                    found = json.loads(m.group(1))
                except ValueError:
                    continue
        if not isinstance(found, dict):
            raise BenchError(f"{path}: no EXT_RELOAD_NIGHTLY receipt (not an ext-reload-nightly.sh log?)")
        return found

    def ingest(self, ctx: Context, path: Path) -> None:
        receipt = self.receipt(path)
        if receipt.get("host"):
            ctx.host.update({"name": receipt["host"], "role": "fleet"})
        readback = receipt.get("readback") or {}
        ctx.row("save_to_reload", readback.get("save_to_reload_ms"), "ms", labels={"case": "activity"})
        checks = readback.get("checks") or {}
        ctx.row("checks_failed", float(sum(1 for ok in checks.values() if not ok)), "count",
                labels={"case": "activity"})
        for case, stats in (receipt.get("edit_repaint") or {}).items():
            stats = stats or {}
            for bound in ("upper", "lower"):
                ctx.row("save_to_shown", stats.get(f"{bound}_median_ms"), "ms",
                        labels={"case": case, "bound": bound})
            ctx.row("missed", float(stats.get("missed", 0)), "count", labels={"case": case})
        if not ctx.rows:
            raise BenchError(f"{path}: the receipt has no numbers")
        if not receipt.get("ok"):
            ctx.notes.append("the receipt is not ok: a read-back check failed or a round was missed")


BENCH = ExtReload()
