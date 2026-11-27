"""screen-share: bandwidth, frame rate under motion and input-to-frame latency of each screen stream.

Two harnesses, one bench:

  mode=eval (default)  scripts/measure/screen-stream-eval.sh on one fleet Mac (host and viewer on that Mac,
                       targets rd,webrtc by default, rd,webrtc,iphone-sim in the daily workflow's run). Its results.json
                       (schema cmux.screen-stream-eval/1) becomes rows labelled target=<the harness's target>.
  mode=vs              cmux-tui/crates/cmux-rd-host/scripts/screen-share-vs.py `run`: cmux's session path
                       against the OS's built-in screen sharing on two Macs. Its JSON lines (--out FILE, or
                       the step's log, which prints the same lines) become rows labelled target=<its stack
                       names> (cmux, apple).

`cmux-bench screen-share --import FILE` reads either: a results.json, a screen-share-vs JSON lines file, or a
fleet log of screen-share-vs.py. Every row has method=eval or method=vs: the two harnesses time different things
(eval ends at the decoded frame, host and viewer on one Mac by default; vs times the product's session path across
two Macs), so compare never pairs their rows.
"""
from __future__ import annotations

import json
import re
import shlex
import subprocess
from pathlib import Path
from typing import Any

from benchlib.bench import REPO_ROOT, Bench, BenchError, Context, base_tip

EVAL_SCRIPT = "scripts/measure/screen-stream-eval.sh"
EVAL_ARTIFACT = "artifacts/screen-stream-eval/results.json"
EVAL_SCHEMA = "cmux.screen-stream-eval/1"
VS_SCRIPT = "cmux-tui/crates/cmux-rd-host/scripts/screen-share-vs.py"
VS_MARKER = "cmux-tui/crates/cmux-rd-host/scripts/mac-marker/main.swift"
VS_ARTIFACT = "artifacts/screen-share-vs.jsonl"
WINDOW_PHASES = ("idle", "typing", "scroll")
# screen-stream-eval.sh's own arguments a bench run may pass through (--arg KEY=VALUE, same names).
EVAL_PASS = ("targets", "samples", "repeats", "input-frame-now", "ltr", "scene-marker", "netem-rtt-ms", "netem-loss-pct",
             "netem-seed", "video", "video-sha256")
# screen-share-vs.py run's options a bench run may set (--arg KEY=VALUE; KEY with _ or -).
VS_PASS = ("host", "viewer", "host-ip", "link", "link-bind", "via", "root", "bin", "cua-vnc", "rig-launch", "stacks",
           "trials", "warmup", "fps-trials", "samples", "fps-seconds", "max-fps", "vnc-user", "vnc-password-file")
VS_STAGES = ("up", "inject", "draw", "sck", "gate", "encode", "send", "first_packet", "down", "decode", "total")
VS_FIRST_FRAME_STAGES = ("signal", "capture_start", "first_capture", "gate", "encode", "send", "down", "decode", "total")


def _num(value: Any) -> float | None:
    return float(value) if isinstance(value, (int, float)) and not isinstance(value, bool) else None


def _slug(name: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-") or "unknown"


class ScreenShare(Bench):
    name = "screen-share"
    summary = "Screen share kbps, fps under motion and key/click-to-frame latency per stream (cmux and others)"
    units = "ms, kbps, fps, %, count"
    owner = "screen stream eval (HQ#7146, CMUX-572)"
    hosts = ("fleet",)
    harness = EVAL_SCRIPT
    version = "1"
    # kbps and OCR error move a lot from run to run (README: one WebRTC run's idle kbps 17 vs 78 on 2026-11-05).
    thresholds = {"kbps": 25.0, "ocr_cer": 50.0, "cpu_pct": 25.0, "process_cpu_pct": 25.0, "split_ms": 25.0,
                  "rtt_ms": 50.0, "key_to_frame_stage_ms": 25.0, "first_frame_stage_ms": 25.0}
    floors = {"kbps": 50.0, "ocr_cer": 1.0, "first_frame_ms": 20.0}
    # The daily screen-stream-eval workflow already runs it at the feat-cmux-next tip; it needs a console worker
    # with the launcher's grants and takes well past 30 minutes with the WebRTC build.
    nightly = False

    # --- run -----------------------------------------------------------------------------------
    def run(self, ctx: Context) -> None:
        mode = ctx.arg("mode", "eval")
        if mode == "eval":
            args = [f"{k}={ctx.arg(k) or ctx.arg(k.replace('-', '_'))}" for k in EVAL_PASS
                    if ctx.arg(k) or ctx.arg(k.replace("-", "_"))]
            res = ctx.fleet_step(EVAL_SCRIPT, args, EVAL_ARTIFACT, step_class="exclusive",
                                 labels=("measure", "gui-session-v1"), timeout=int(ctx.arg("timeout") or 5400),
                                 ref=ctx.arg("ref") or ctx.build.get("sha"))  # the hosts build at the measured commit
            self.ingest(ctx, res.artifact_path or res.log_path)
        elif mode == "vs":
            self._run_vs(ctx)
        else:
            raise BenchError(f"screen-share: --arg mode={mode}: expected eval or vs")

    def _run_vs(self, ctx: Context) -> None:
        def get(key: str) -> str | None:
            return ctx.arg(key) or ctx.arg(key.replace("-", "_"))

        missing = [k for k in ("host", "viewer", "host-ip") if not get(k)]
        if missing:
            raise BenchError("screen-share mode=vs needs --arg " + " --arg ".join(f"{k}=..." for k in missing)
                             + " (the shared Mac, the viewing Mac and the shared Mac's address on the link)")
        ref = ctx.arg("ref") or base_tip()
        have = subprocess.run(["git", "-C", str(REPO_ROOT), "cat-file", "-t", ref], text=True, capture_output=True)
        if have.returncode == 0:
            on = subprocess.run(["git", "-C", str(REPO_ROOT), "cat-file", "-e", f"{ref}:{VS_SCRIPT}"], capture_output=True)
            if on.returncode != 0:
                raise BenchError(f"screen-share mode=vs: {VS_SCRIPT} is not at {ref[:12]} yet (PR #44065); "
                                 "record a hand run with `cmux-bench screen-share --import results.jsonl`")
        args = ["run", f"--out={VS_ARTIFACT}"]
        if not get("marker-src"):
            args.append(f"--marker-src={VS_MARKER}")
        for key in VS_PASS + ("marker-src",):
            if get(key):
                args.append(f"--{key}={get(key)}")
        args += shlex.split(ctx.arg("vs_args") or "")
        res = ctx.fleet_step(VS_SCRIPT, args, VS_ARTIFACT, step_class="exclusive", labels=("measure",), ref=ref,
                             timeout=int(ctx.arg("timeout") or 3600))
        self.ingest(ctx, res.artifact_path or res.log_path)

    # --- ingest --------------------------------------------------------------------------------
    def ingest(self, ctx: Context, path: Path) -> None:
        text = path.read_text(encoding="utf-8", errors="replace")
        try:
            data = json.loads(text)
        except ValueError:
            data = None
        if isinstance(data, dict) and data.get("schema") == EVAL_SCHEMA:
            self._eval(ctx, data)
            return
        records = []
        for line in text.splitlines():
            line = line.strip()
            if line.startswith("{") and line.endswith("}"):
                try:
                    records.append(json.loads(line))
                except ValueError:
                    continue
        if any(isinstance(r, dict) and "summary" in r and "rtt" in r for r in records):
            self._vs(ctx, records)
            return
        # A screen-stream-eval log: the results.json the step printed is not in it, only the summary table.
        raise BenchError(f"screen-share: {path} is neither a screen-stream-eval results.json ({EVAL_SCHEMA}) nor "
                         "screen-share-vs.py JSON lines; for an eval step, import its results.json artifact")

    def _eval(self, ctx: Context, data: dict[str, Any]) -> None:
        run = data.get("run") or {}
        if run.get("blocked"):
            ctx.notes.append(f"screen-stream-eval measured nothing: {run['blocked']}")
        link = "loopback" if str(run.get("link", "")).startswith("loopback") else "lan"
        base = {"method": "eval", "link": link}
        if str(run.get("rd_input_frame_now", "0")) == "1":
            base["input_frame_now"] = "1"
        if str(run.get("rd_ltr", "0")) == "1":
            base["ltr"] = "1"
        if run.get("netem_rtt_ms") not in (None, ""):
            base["netem"] = f"{run.get('netem_rtt_ms')}ms/{run.get('netem_loss_pct', 0)}%"
        for name, t in (data.get("targets") or {}).items():
            labels = {**base, "target": name}
            for err in t.get("errors") or []:
                ctx.notes.append(f"{name}: {err}")
            for kind in ("key", "pointer"):
                lat = (t.get("latency") or {}).get(kind) or {}
                p50, p95, n = _num(lat.get("p50_ms")), _num(lat.get("p95_ms")), lat.get("n")
                if p50 is not None:
                    ctx.row("input_to_frame_ms", p50, "ms", p50=p50, p95=p95, n=n if isinstance(n, int) and n > 0 else None,
                            labels={**labels, "input": kind})
                    if isinstance(lat.get("lost"), int):
                        ctx.row("input_lost", lat["lost"], "count", labels={**labels, "input": kind})
                split = (t.get("split") or {}).get(kind) or {}
                for stage in ("input_to_capture_ms", "encode_ms", "transport_ms", "decode_ms"):
                    if _num(split.get(stage)) is not None:
                        ctx.row("split_ms", split[stage], "ms",
                                labels={**labels, "input": kind, "stage": stage.removesuffix("_ms")})
            sampled = t.get("sampled_fps") or {}
            for phase in WINDOW_PHASES:
                labels_p = {**labels, "phase": phase}
                if _num((t.get("kbps") or {}).get(phase)) is not None:
                    ctx.row("kbps", t["kbps"][phase], "kbps", labels=labels_p)
                fps = _num((t.get("fps") or {}).get(phase))
                if fps is not None:
                    # A still screen needs no frames: idle fps is reported, not judged.
                    ctx.row("fps", fps, "fps", better="none" if phase == "idle" else "higher", labels=labels_p)
                elif _num(sampled.get(phase)) is not None:
                    # A viewer with no frame counts: screenshot changes a second (at most 10), not decoded fps.
                    ctx.row("sampled_changes", sampled[phase], "per_s",
                            better="none" if phase == "idle" else "higher", labels=labels_p)
            typing = (t.get("split") or {}).get("typing") or {}
            for stage in ("encode_ms", "decode_ms"):
                if _num(typing.get(stage)) is not None:
                    ctx.row("split_ms", typing[stage], "ms",
                            labels={**labels, "input": "typing", "stage": stage.removesuffix("_ms")})
            ocr = t.get("ocr") or {}
            if _num(ocr.get("cer")) is not None:
                ctx.row("ocr_cer", ocr["cer"] * 100, "%", labels=labels)
            extra = t.get("extra") or {}
            if _num(extra.get("first_frame_ms")) is not None:
                ctx.row("first_frame_ms", extra["first_frame_ms"], "ms", labels=labels)
            for key in ("cpu_pct", "process_cpu_pct"):
                if _num(extra.get(key)) is not None:
                    ctx.row(key, extra[key], "%", labels=labels)

    def _vs(self, ctx: Context, records: list[dict[str, Any]]) -> None:
        head = next((r for r in records if "clock" in r and "host" in r), {})
        final = [r for r in records if "summary" in r and "rtt" in r][-1]
        # method=vs: another harness and method than eval's, so compare never pairs their rows.
        base = {"method": "vs", "link": str(final.get("link") or head.get("link") or "unknown")}
        trials = [r for r in records if r.get("stack") and not r.get("warmup") and "trial" in r]
        stacks = list(dict.fromkeys(r["stack"] for r in records if r.get("stack")))
        summ = final.get("summary") or {}
        names = [k for k in summ if k not in ("cmux_breakdown", "cmux_first_frame_breakdown")]
        # The table names its stacks in the order it ran them, the same order as its records' `stack`.
        target = dict(zip(names, stacks)) if len(stacks) == len(names) else {}
        for name in names:
            labels = {**base, "target": target.get(name) or _slug(name)}
            s = summ.get(name) or {}
            for key, metric, unit, better in (("first_frame_ms", "first_frame_ms", "ms", "lower"),
                                               ("key_to_frame_ms", "input_to_frame_ms", "ms", "lower"),
                                               ("fps", "fps", "fps", "higher")):
                st = s.get(key)
                if isinstance(st, dict) and _num(st.get("p50")) is not None:
                    extra = {"input": "key"} if metric == "input_to_frame_ms" else {"phase": "motion"} if metric == "fps" else {}
                    ctx.row(metric, st["p50"], unit, better=better, p50=st["p50"], p95=_num(st.get("p95")),
                            n=st.get("n") if isinstance(st.get("n"), int) else None, labels={**labels, **extra})
        for stack in stacks:
            labels = {**base, "target": stack}
            mine = [r for r in trials if r["stack"] == stack]
            kbps = [r["mbit_per_s"] * 1000 for r in mine if r.get("mode") == "fps" and r.get("ok")
                    and _num(r.get("mbit_per_s")) is not None]
            if kbps:
                ctx.row("kbps", unit="kbps", samples=kbps, labels={**labels, "phase": "motion"})
            lost = [r["lost"] for r in mine if r.get("mode") == "key" and r.get("ok") and isinstance(r.get("lost"), int)]
            if lost:
                ctx.row("input_lost", sum(lost), "count", labels={**labels, "input": "key"})
            failed = sum(1 for r in mine if not r.get("ok"))
            if mine:
                ctx.row("failed_trials", failed, "count", labels=labels)
        for key, metric, stages in (("cmux_breakdown", "key_to_frame_stage_ms", VS_STAGES),
                                    ("cmux_first_frame_breakdown", "first_frame_stage_ms", VS_FIRST_FRAME_STAGES)):
            for stage in stages:
                st = (summ.get(key) or {}).get(stage)
                if isinstance(st, dict) and _num(st.get("p50")) is not None:
                    ctx.row(metric, st["p50"], "ms", p50=st["p50"], p95=_num(st.get("p95")),
                            labels={**base, "target": "cmux", "stage": stage})
        rtt = final.get("rtt") or {}
        if _num(rtt.get("rtt_min_ms")) is not None:
            ctx.row("rtt_ms", rtt["rtt_min_ms"], "ms", better="none", labels={**base, "stat": "min"})
        if isinstance(rtt.get("rtt_ms"), dict) and _num(rtt["rtt_ms"].get("p50")) is not None:
            ctx.row("rtt_ms", rtt["rtt_ms"]["p50"], "ms", better="none", p50=rtt["rtt_ms"]["p50"],
                    p95=_num(rtt["rtt_ms"].get("p95")), labels={**base, "stat": "p50"})
        for r in records:
            if "error" in r and r.get("stack"):
                ctx.notes.append(f"{r['stack']} {r.get('mode')} trial {r.get('trial')}: {str(r['error'])[:200]}")


BENCH = ScreenShare()
