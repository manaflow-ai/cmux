"""idle_attention: idle CPU, wakeups, WindowServer CPU and GPU with waiting tabs and rows drawn as a badge or a glow.

Leo 2026-11-19 asked for idle CPU and GPU numbers for `notifications.attention.mark` glow (a breathing halo on every
unselected waiting tab and sidebar row, a render-server animation). Wraps scripts/measure/split-spring.sh
--suite=idle-attention (scripts/cmux-next/idle-attention.py, bench_memory.py --waiting): a bench-config app built at
the step's ref, launched fresh per arm with --waiting workspaces waiting unread and --waiting-tabs unread tabs, the
launch workspace shown, idle for --measure seconds. Arms interleave for --reps rounds: badge (default), glow (then the
window minimized: sample `minimized`), and with base_sha= that commit's app. It prints

  IDLE-ATTN arm=A round=R sample=S app_cpu_pct=.. app_wakeups_per_s=.. total_cpu_pct=.. windowserver_cpu_pct=..
            gpu_device_pct=.. gpu_renderer_pct=.. gpu_tiler_pct=.. window={..} unread={..}

which `ingest` reads (one row per metric with every round as a sample; labels arm, sample; better = lower).
Args: --arg waiting=10 --arg waiting_tabs=3 --arg measure=60 --arg reps=2 --arg base_sha=SHA.
"""
from __future__ import annotations

import json
import re
import subprocess
from pathlib import Path

from benchlib.bench import Bench, BenchError, Context

HARNESS = "scripts/measure/split-spring.sh"
ARTIFACT = "artifacts/split-spring/idle-attention.tgz"
PASS_THROUGH = {"waiting": "--waiting", "waiting_tabs": "--waiting-tabs", "measure": "--measure", "settle": "--settle",
                "reps": "--reps", "arms": "--arms", "base_sha": "--base-sha"}
FIELD = re.compile(r"(\w+)=(\S+)")
LINE = re.compile(r"^IDLE-ATTN arm=(\S+) round=(\S+) sample=(\S+) (.*)$")
MACHINE = re.compile(r"^IDLE-ATTN-MACHINE (\{.*\})$")
METRICS = {"app_cpu_pct": ("app_cpu", "%"), "app_wakeups_per_s": ("app_wakeups", "per_s"),
           "total_cpu_pct": ("total_cpu", "%"), "windowserver_cpu_pct": ("windowserver_cpu", "%"),
           "gpu_device_pct": ("gpu_device", "%"), "gpu_renderer_pct": ("gpu_renderer", "%"),
           "gpu_tiler_pct": ("gpu_tiler", "%")}


class IdleAttention(Bench):
    name = "idle_attention"
    summary = "Idle app CPU, wakeups, WindowServer CPU and GPU % with waiting tabs and rows as a badge or a glow"
    units = "%, per_s"
    owner = "perf (notifications.attention.mark)"
    hosts = ("fleet",)
    harness = HARNESS
    version = "1"
    # Fractions of a percent swing by more than 10 % run to run.
    thresholds = {m: 25.0 for m, _ in METRICS.values()}
    nightly = False

    def harness_args(self, ctx: Context) -> tuple[list[str], str]:
        out = ["--suite=idle-attention", "--config=bench", "--app-cache"]
        out += [f"{flag}={ctx.args[key]}" for key, flag in PASS_THROUGH.items() if ctx.args.get(key)]
        sha = ctx.build.get("sha")
        if ctx.build.get("channel") != "sha" or not sha:
            raise BenchError("idle_attention: builds the app at a commit; pass --build SHA")
        return out, sha

    def run(self, ctx: Context) -> None:
        args, ref = self.harness_args(ctx)
        res = ctx.fleet_step(self.harness, args, ARTIFACT, step_class="exclusive", labels=("measure",), timeout=7200, display=True,
                             ref=ref)
        log = res.log_path
        if "IDLE-ATTN " not in res.log and res.job_id:
            full = ctx.workdir / f"{res.job_id}.log"
            got = subprocess.run(["cmux-ci", "log", res.job_id, "--tail", "200000"], text=True, capture_output=True)
            if got.returncode == 0:
                full.write_text(got.stdout)
                log = full
        self.ingest(ctx, log)

    def ingest(self, ctx: Context, path: Path) -> None:
        samples: dict[tuple[str, str, str], list[float]] = {}
        for line in Path(path).read_text(encoding="utf-8", errors="replace").splitlines():
            line = line.strip()
            if m := MACHINE.match(line):
                host = json.loads(m.group(1))
                ctx.host.update({"name": host.get("host"), "role": "fleet", "os": f"macOS {host.get('macos')}",
                                 "chip": host.get("chip") or host.get("model")})
                continue
            if not (m := LINE.match(line)):
                continue
            fields = dict(FIELD.findall(m.group(4)))
            for key, (metric, _unit) in METRICS.items():
                try:
                    value = float(fields[key])
                except (KeyError, ValueError):
                    continue
                samples.setdefault((metric, m.group(1), m.group(3)), []).append(value)
        if not samples:
            raise BenchError(f"{path}: no IDLE-ATTN line (not an idle-attention log?)")
        units = dict(METRICS.values())
        for (metric, arm, sample), values in sorted(samples.items()):
            ctx.row(metric, None, units[metric], samples=values, labels={"arm": arm, "sample": sample})


BENCH = IdleAttention()
