#!/usr/bin/env python3
"""Cua Driver Bench v2 with this eval's drivers (README.md, "Bench v2").

The bench (trycua/cua libs/cua-driver-bench, FSL-1.1-MIT) runs from its pinned source in the VM and is
never copied into this repo. This wrapper imports its runner and, before handing it the command line,
registers one Claude Code arm per driver this eval fetched:

  cc-cmux-cua        cmux-cua from its helper bundle, its daemon started as cmux starts it
                     (input_ab.serve_argv, cmux's helper and MCP environment), with cmux's skill
  cc-cua-driver-0380 the Cua Driver 0.38.0 release app with its own skill, run_script on, as the
                     bench's public "Cua Driver" setup runs main

Everything else is the bench's own: the prompts, the model, the limits, BenchLab, the sentinel, the
checkers and the row schema. Preflight checks that assume the bench's own builds (their pins, the
0.34.0 release) can be waived by name with --waive REGEX; a waived check is kept, as "warn", with
the reason in its detail. Afterwards the run's rows, preflight and report are copied to --out with a
summary.md.

  bench_v2.py --bench DIR --work DIR --build-dir DIR --out DIR --driver LABEL=BIN --skills LABEL=DIR
              [--waive REGEX]... --mode preflight|run [--condition C] [--runs N] [--tasks A,B]
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
# The BenchLab tasks of Bench v2. CDB-G02 to CDB-G04 need LibreOffice, GnuCash and Chrome in the image.
DEFAULT_TASKS = ["MB-09", "MB-10", "MB-11", "IR-01", "IR-02", "IR-03", "IR-04"]
# What cmux's helper gets (ComputerUseHelperDaemon.environment) and what acpmux gives its MCP server
# (agent_tools.rs), as input_ab.py runs it, without the per-launch socket tokens: the bench's own
# status, stop and health calls carry no token.
CMUX_ENV = (
    ("CMUX_CUA_EXTERNAL_PERMISSION_FLOW", "1"),
    ("CMUX_CUA_PERMISSIONS_GATE", "0"),
    ("CMUX_CUA_RESPONSIBILITY_DISCLAIMED", "1"),
    ("CMUX_CUA_TELEMETRY_ENABLED", "false"),
    ("CMUX_CUA_UPDATE_CHECK", "false"),
    ("CMUX_CUA_CURSOR_LABEL", "cmux"),
    ("CMUX_CUA_CURSOR_GRADIENT", "#12c7f5,#2d8cff,#6c5cff"),
    ("CMUX_CUA_CURSOR_BLOOM", "#2d8cff"),
    ("CMUX_CUA_MCP_FORCE_PROXY", "1"),
)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def pairs(values: list[str], what: str) -> dict[str, str]:
    out = {}
    for value in values:
        key, sep, rest = value.partition("=")
        if not sep:
            raise SystemExit(f"bench_v2.py: {what} is LABEL=PATH, not {value}")
        out[key] = rest
    return out


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--bench", type=Path, required=True, help="automated-eval/macos_bench of the pinned source")
    p.add_argument("--work", type=Path, required=True)
    p.add_argument("--build-dir", type=Path, required=True)
    p.add_argument("--out", type=Path, required=True)
    p.add_argument("--driver", action="append", default=[])
    p.add_argument("--skills", action="append", default=[])
    p.add_argument("--waive", action="append", default=[])
    p.add_argument("--mode", choices=["preflight", "run"], default="preflight")
    p.add_argument("--condition", choices=["background", "foreground"], default="background")
    p.add_argument("--runs", type=int, default=1)
    p.add_argument("--tasks", default=",".join(DEFAULT_TASKS))
    a = p.parse_args()
    drivers, skills = pairs(a.driver, "--driver"), pairs(a.skills, "--skills")

    os.environ["CDB_BENCH_WORK"] = str(a.work)  # claude_arms reads it at import
    sys.path.insert(0, str(a.bench))
    sys.path.insert(1, str(HERE))
    import arms  # noqa: E402
    import claude_arms as ca  # noqa: E402
    import desktop_runtime as desktop  # noqa: E402
    import input_ab  # noqa: E402
    import run_bench  # noqa: E402

    ours: dict[str, dict] = {}
    for label, binary in drivers.items():
        binary_path = Path(binary)
        app = binary_path.parents[2]
        if label.startswith("cmux-cua"):
            arm, state = "cc-cmux-cua", a.work / "cmux-cua"
            build = ca.CuaBuild(arm, label, app, "/tmp/cdb-bench-cmux-cua.sock", state / "daemon-state",
                                Path(skills[label]), daemon_env=CMUX_ENV + (("CMUX_CUA_STATE_DIR", str(state / "helper")),),
                                executable=binary_path)
            description = f"{label}, the cmux Computer Use helper as cmux runs it, with cmux's cmux-cua skill"
        elif label.startswith("cua-driver-"):
            arm = "cc-cua-driver-" + label.removeprefix("cua-driver-").replace(".", "")
            build = ca.CuaBuild(arm, label, app, f"/tmp/cdb-bench-{arm}.sock", a.work / arm / "daemon-state",
                                Path(skills[label]), daemon_env=(ca.SCRIPT_FLAG,),
                                prompt_addendum=ca.RUN_SCRIPT_ADDENDUM, executable=binary_path)
            description = f"Cua Driver {label.removeprefix('cua-driver-')} release app, run_script on, its own skill"
            ca.CUA_BIN = binary_path  # the recorder's daemon (screen recordings, occlusion checks)
        else:
            raise SystemExit(f"bench_v2.py: no arm for driver {label}")
        ca.CUA_BUILDS[arm] = build
        ca.ARM_DESCRIPTIONS[arm] = description
        ours[arm] = {"label": label, "binary": str(binary_path), "sha256": sha256(binary_path),
                     "skills": skills[label], "description": description}
    ca.CUA_ARMS = tuple(ca.CUA_BUILDS)
    arms.CLAUDE_ARMS = tuple(arms.CLAUDE_ARMS) + tuple(ours)
    arms.ALL_ARMS = tuple(arms.ALL_ARMS) + tuple(ours)

    # cmux-cua has no --dangerously-bypass-approvals: start its daemon with cmux's own serve flags.
    start_driver = desktop.start_driver

    def start_cmux_aware(binary, socket, state, *, overlay=True, log_name="daemon.log", env_extra=None):
        if Path(binary).name != "cmux-cua":
            return start_driver(binary, socket, state, overlay=overlay, log_name=log_name, env_extra=env_extra)
        Path(socket).unlink(missing_ok=True)
        proc = desktop.start_app(input_ab.serve_argv(str(binary), socket), state / "home", state / log_name, env=env_extra)
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            if proc.poll() is not None:
                raise RuntimeError(f"cmux-cua exited ({proc.returncode}); see {state / log_name}")
            done = subprocess.run([str(binary), "status", "--socket", socket], env=desktop.desktop_env(state / "home", env_extra),
                                  capture_output=True, timeout=5)
            if done.returncode == 0:
                return proc
            time.sleep(0.3)
        desktop.stop_group(proc.pid)
        raise TimeoutError(f"cmux-cua not ready; see {state / log_name}")

    desktop.start_driver = start_cmux_aware

    # The bench pins its own builds; ours are pinned by this eval (pins.json, the cmux-cua release hash).
    check_daemon = run_bench.check_daemon

    def check_ours(pins, arm="cc-cua-driver"):
        if arm not in ours:
            return check_daemon(pins, arm)
        spec = ca.CUA_BUILDS[arm]
        health = ca.cua_health(spec.socket, spec.home, spec.bin)
        checks = {k: v for k, v in health.get("checks", {}).items() if k.startswith("tcc_")}
        return [
            (f"{arm} daemon answers health_report", "pass" if health.get("ok") else "fail",
             json.dumps(health.get("build") or health.get("error"))[:300]),
            (f"{arm} binary", "pass", f"{ours[arm]['label']} sha256 {ours[arm]['sha256']}"),
            (f"{arm} daemon accessibility + screen recording", "pass" if desktop.capabilities_ok(health) else "fail",
             json.dumps(checks)),
        ]

    run_bench.check_daemon = check_ours

    preflight = run_bench.preflight

    def preflight_with_waivers(ctx, with_models=True):
        out = []
        for name, status, detail in preflight(ctx, with_models):
            if status == "fail" and any(re.search(w, name) for w in a.waive):
                status, detail = "warn", f"waived by the cmux eval: {detail}"
                print(f"[WAIVED] {name}", flush=True)
            out.append((name, status, detail))
        return out

    run_bench.preflight = preflight_with_waivers

    run_id = "preflight" if a.mode == "preflight" else f"v2-{a.condition}"
    argv = [a.mode, "--bench-v2", "--build-dir", str(a.build_dir), "--run-id", run_id, "--arms", *ours,
            "--tasks", *[t for t in a.tasks.split(",") if t], "--condition", a.condition,
            "--allow-non-terminal", "--no-model-preflight", "--allow-unknown-quota"]
    if a.mode == "run":
        argv += ["--park-pointer", "--phase1-runs", str(a.runs), "--phase2-runs", "0"]
    print("bench_v2.py: run_bench.py " + " ".join(argv), flush=True)
    sys.argv = [str(a.bench / "run_bench.py"), *argv]
    try:
        status = run_bench.main()
    except SystemExit as stop:
        if not isinstance(stop.code, int) and stop.code is not None:
            print(f"bench_v2.py: run_bench.py stopped: {stop.code}", file=sys.stderr, flush=True)
        status = stop.code if isinstance(stop.code, int) else (0 if stop.code is None else 1)

    a.out.mkdir(parents=True, exist_ok=True)
    run_dir = a.work / "runs" / run_id
    for name in ("results.jsonl", "preflight.json", "manifest.json", "runner.log", "done.json", "PREFLIGHT_FAILED"):
        if (run_dir / name).is_file():
            shutil.copy2(run_dir / name, a.out / name)
    (a.out / "arms.json").write_text(json.dumps({"arms": ours, "waived": a.waive, "argv": argv,
                                                 "exit": status}, indent=2) + "\n")
    analyze = a.bench / "tools" / "analyze_v2.py"
    if (run_dir / "results.jsonl").is_file() and analyze.is_file():
        subprocess.run([sys.executable, "-I", str(analyze), str(run_dir), "--md", str(a.out / "report.md"),
                        "--json", str(a.out / "report.json")], check=False)
    write_summary(a.out, run_id, status)
    return status


def write_summary(out: Path, run_id: str, status: int) -> None:
    lines = ["## Bench v2", ""]
    preflight = json.loads((out / "preflight.json").read_text()) if (out / "preflight.json").is_file() else []
    failed = [c for c in preflight if c[1] == "fail"]
    waived = [c for c in preflight if c[1] == "warn" and str(c[2]).startswith("waived")]
    lines.append(f"`{run_id}`, exit {status}. Preflight: {len(preflight)} checks, {len(failed)} failed, {len(waived)} waived.")
    for name, _, detail in failed + waived:
        lines.append(f"- {'waived' if (name, _, detail) in waived else 'failed'}: {name}: {str(detail)[:200]}")
    rows = []
    if (out / "results.jsonl").is_file():
        for raw in (out / "results.jsonl").read_text().splitlines():
            try:
                row = json.loads(raw)
            except ValueError:
                continue
            if row.get("final", True):
                rows.append(row)
    if rows:
        lines += ["", "| arm | task | condition | passed | background completion | turns | wall s |", "|---|---|---|---|---|---|---|"]
        for row in sorted(rows, key=lambda r: (r.get("arm", ""), r.get("task", ""), r.get("run_index", 0))):
            completion = (row.get("multiplayer") or {}).get("background_completion")
            lines.append(f"| {row.get('arm')} | {row.get('task')} | {row.get('condition')} | {row.get('passed')} | "
                         f"{'n/a' if completion is None else completion} | {row.get('turns')} | {row.get('wall_s')} |")
    if (out / "report.md").is_file():
        lines += ["", "The bench's own report: `bench-v2/report.md`."]
    (out / "summary.md").write_text("\n".join(lines) + "\n")


if __name__ == "__main__":
    raise SystemExit(main())
