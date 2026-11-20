"""wallpaper_cost: what a moving wallpaper costs a cmux NEXT app (plans/cmux-next/live-wallpapers.md, "Cost").

Wraps scripts/measure/wallpaper-cost.sh: it builds a tagged app at the step's ref, launches it with a scratch HOME
and measures, 60 s each, a painting (the baseline), each live wallpaper with the pointer moving over the window,
local test videos (videos=1080p30,4k60) and a YouTube wallpaper (youtube=ID), then for the first live wallpaper,
each video and each YouTube one: idle, occluded (off screen), covered (another window over it), minimized and Low
Power Mode (scripts/measure/wallpaper-cost.py). One line per phase, which `ingest` reads from the step log:

  WALLPAPER-COST <phase> id=<id> cpu_s_per_s=.. gpu_s_per_s=.. footprint_mb=.. frames_per_s=.. state=.. fps=..
      tree_cpu_s_per_s=.. tree_cpu_p95_s_per_s=.. webkit_cpu_s_per_s=.. decoder_cpu_s_per_s=..
      windowserver_cpu_s_per_s=.. gpu_util_pct=.. gpu_util_p95_pct=.. tree_footprint_mb=..
      net_in_kb_per_s=.. net_out_kb_per_s=.. if_in_kb_per_s=.. if_out_kb_per_s=..

Rows (better = lower, labels phase and id): cpu (%: app process CPU seconds per second, as % of one core), gpu (%:
the live wallpaper's GPU seconds per second, as %), footprint (MB: the app's phys_footprint at the window's end), frames
(fps: frames drawn per second; informational). Version 2 adds, when the line has them: tree_cpu and tree_cpu_p95 (the
app and every process it owns, WebKit's included, plus VTDecoderXPCService; mean and p95 of 1 s samples), webkit_cpu,
decoder_cpu, windowserver_cpu (% of one core), gpu_util and gpu_util_p95 (IOAccelerator Device Utilization %, the
whole GPU), tree_footprint (MB), net_in/net_out (kbps, kilobits per second, of the app's processes, nettop) and
if_in/if_out (kbps of every interface, the host's other traffic included). A held phase should draw no frames and
cost what the picture costs; `state` says which hold the scheduler gave.

Default args: measure=60 (about 20 minutes with the build for six wallpapers). Harness args pass through:
--arg measure=30 --arg ids=orbits,metal --arg frame_rate=60 --arg picture=<art id> --arg videos=1080p30,4k60
--arg youtube=<id> --arg youtube_qualities=default,720 --arg holds=<ids> --arg hold_phases=<phases>
--arg idle_pause=20 --arg settle=10.
"""
from __future__ import annotations

import re
import subprocess
from pathlib import Path

from benchlib.bench import Bench, BenchError, Context

HARNESS = "scripts/measure/wallpaper-cost.sh"
PASS_THROUGH = ("measure", "ids", "frame_rate", "picture", "videos", "youtube", "youtube_qualities", "holds", "hold_phases",
                "idle_pause", "settle")
FIELD = re.compile(r"(\w+)=(\"[^\"]*\"|\S+)")
LINE = re.compile(r"^WALLPAPER-COST (\S+) (.*)$")
MACHINE = re.compile(r"^WALLPAPER-COST-MACHINE (.*)$")
# (metric, field, unit, scale): seconds per second are reported as % of one core (or of the GPU's time).
METRICS = (("cpu", "cpu_s_per_s", "%", 100.0), ("gpu", "gpu_s_per_s", "%", 100.0), ("footprint", "footprint_mb", "MB", 1.0),
           ("frames", "frames_per_s", "fps", 1.0),
           # Version 2: the app's helper processes, the system's decoder and compositor, the whole GPU and the network.
           ("tree_cpu", "tree_cpu_s_per_s", "%", 100.0), ("tree_cpu_p95", "tree_cpu_p95_s_per_s", "%", 100.0),
           ("webkit_cpu", "webkit_cpu_s_per_s", "%", 100.0), ("decoder_cpu", "decoder_cpu_s_per_s", "%", 100.0),
           ("windowserver_cpu", "windowserver_cpu_s_per_s", "%", 100.0), ("gpu_util", "gpu_util_pct", "%", 1.0),
           ("gpu_util_p95", "gpu_util_p95_pct", "%", 1.0), ("tree_footprint", "tree_footprint_mb", "MB", 1.0),
           ("net_in", "net_in_kb_per_s", "kbps", 8.192), ("net_out", "net_out_kb_per_s", "kbps", 8.192),
           ("if_in", "if_in_kb_per_s", "kbps", 8.192), ("if_out", "if_out_kb_per_s", "kbps", 8.192))


class WallpaperCost(Bench):
    name = "wallpaper_cost"
    summary = ("CPU % (app, helpers, decoder, WindowServer), GPU %, fps, footprint and network of a tagged cmux NEXT app per "
               "picture, live wallpaper, local video and YouTube wallpaper, idle, occluded, covered, minimized, Low Power")
    units = "%, MB, fps"
    owner = "design (live wallpapers)"
    hosts = ("fleet",)
    harness = HARNESS
    version = "2"
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
