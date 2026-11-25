"""wallpaper_cost: what a live wallpaper costs a cmux NEXT app (plans/cmux-next/live-wallpapers.md, "Cost").

Wraps scripts/measure/wallpaper-cost.sh: it builds a tagged app at the step's ref, launches it with a scratch HOME
and measures, 60 s each, a painting (the baseline), each live wallpaper with the pointer moving over the window,
then the first one idle, occluded, minimized and under Low Power Mode (scripts/measure/wallpaper-cost.py). One line
per phase, which `ingest` reads from the step log:

  WALLPAPER-COST <phase> id=<id> cpu_s_per_s=.. gpu_s_per_s=.. footprint_mb=.. frames_per_s=.. state=.. fps=..

Rows (better = lower, labels phase and id): cpu (%: app process CPU seconds per second, as % of one core), gpu (%:
the wallpaper's GPU seconds per second, as %), footprint (MB: the app's phys_footprint at the window's end), frames
(fps: frames drawn per second; informational). A held phase (idle, occluded, minimized, low-power) should draw no frames
and cost what the picture costs; `live_state` says which hold the scheduler gave.

Default args: measure=60 (about 20 minutes with the build for six wallpapers). Harness args pass through:
--arg measure=30 --arg ids=orbits,metal --arg frame_rate=60 --arg picture=<art id>.
"""
from __future__ import annotations

import re
import subprocess
from pathlib import Path

from benchlib.bench import Bench, BenchError, Context

HARNESS = "scripts/measure/wallpaper-cost.sh"
PASS_THROUGH = ("measure", "ids", "frame_rate", "picture")
FIELD = re.compile(r"(\w+)=(\"[^\"]*\"|\S+)")
LINE = re.compile(r"^WALLPAPER-COST (\S+) (.*)$")
MACHINE = re.compile(r"^WALLPAPER-COST-MACHINE (.*)$")
# (metric, field, unit, scale): seconds per second are reported as % of one core (or of the GPU's time).
METRICS = (("cpu", "cpu_s_per_s", "%", 100.0), ("gpu", "gpu_s_per_s", "%", 100.0), ("footprint", "footprint_mb", "MB", 1.0),
           ("frames", "frames_per_s", "fps", 1.0))


class WallpaperCost(Bench):
    name = "wallpaper_cost"
    summary = "CPU %, GPU %, fps and footprint of a tagged cmux NEXT app per live wallpaper, idle, occluded, minimized, Low Power"
    units = "%, MB, fps"
    owner = "design (live wallpapers)"
    hosts = ("fleet",)
    harness = HARNESS
    version = "1"
    # GPU and CPU per second at a few percent of a core swing run to run.
    thresholds = {"cpu": 25.0, "gpu": 25.0, "footprint": 10.0}
    nightly = False  # builds a tagged app and moves the pointer: a measure Mac nobody uses

    def harness_args(self, ctx: Context) -> tuple[list[str], str | None]:
        out = [f"{k}={v}" for k, v in ctx.args.items() if k in PASS_THROUGH]
        if ctx.arg("config"):
            out.append(f"--config={ctx.arg('config')}")
        sha = ctx.build.get("sha")
        if ctx.build.get("channel") in ("sha", "nightly") and sha:
            return out, sha
        if ctx.build.get("channel") == "nightly":
            ctx.notes.append("wallpaper_cost: the NIGHTLY feed names no source commit; measuring the feat-cmux-next tip")
            return out, None
        raise BenchError(f"wallpaper_cost: --build {ctx.build.get('channel')} has no commit to build; pass --build SHA")

    def run(self, ctx: Context) -> None:
        args, ref = self.harness_args(ctx)
        res = ctx.fleet_step(self.harness, args, None, step_class="exclusive", labels=("measure",), timeout=5400, ref=ref)
        log = res.log_path
        if "WALLPAPER-COST " not in res.log and res.job_id:
            full = ctx.workdir / f"{res.job_id}.log"
            got = subprocess.run(["cmux-ci", "log", res.job_id, "--tail", "200000"], text=True, capture_output=True)
            if got.returncode == 0:
                full.write_text(got.stdout)
                log = full
        self.ingest(ctx, log)

    def ingest(self, ctx: Context, path: Path) -> None:
        text = Path(path).read_text(encoding="utf-8", errors="replace")
        found = 0
        for line in text.splitlines():
            line = line.strip()
            if m := MACHINE.match(line):
                f = {k: v.strip('"') for k, v in FIELD.findall(m.group(1))}
                if f.get("host"):
                    ctx.host.update({"name": f["host"], "role": "fleet"})
                if f.get("macos"):
                    ctx.host["os"] = f"macOS {f['macos']}"
                continue
            m = LINE.match(line)
            if not m:
                continue
            f = dict(FIELD.findall(m.group(2)))
            labels = {"phase": m.group(1), "id": f.get("id", "?")}
            for metric, key, unit, scale in METRICS:
                try:
                    value = round(float(f[key]) * scale, 6)
                except (KeyError, ValueError):
                    continue
                ctx.row(metric, value, unit, labels=labels)
            found += 1
        if not found:
            raise BenchError(f"{path}: no WALLPAPER-COST line (not a wallpaper-cost.sh log?)")


BENCH = WallpaperCost()
