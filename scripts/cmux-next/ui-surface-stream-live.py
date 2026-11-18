#!/usr/bin/env python3
"""An agent UI surface card streaming into a long chat, measured in the live pane of a fleet Mac on its own.

plans/cmux-next/agent-ui-surfaces-DESIGN.md, "Streaming and frames": golden.py's `ui_surface_stream` scenario
(scripts/ci/frame-pacing/ui_surface_stream.py) alone, without the rest of the golden interactions and without the
frame pacing workflow, which runs only while an owned Mac is free. The fleet entry is split-spring.sh's dispatcher
(the measure script reviewed for pull request heads), which builds the app at the step's commit and brings up the
virtual display:

    cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/split-spring.sh \\
      --ref <sha> --arg=--suite=ui-surface-stream --arg=--vdisplay=120 --arg=--config=bench \\
      --artifact artifacts/split-spring/report.json [--arg=--rounds=3]

It launches the app through bench_launch.py (mock agent pane, automation socket, a scratch config of its own),
runs the scenario's drive (Labs `labs.agentUiSurfaces` on in that scratch config, then `debug.agent_pane` `stream`
with and without the `cmux-catalog-cards` card, ROUNDS each, alternating), judges it, and writes:

- `--json` (report.json): {suite, verdict, row, data}: the judge's verdict, the summary row golden.py prints, and the
  raw rounds (each round's page frame intervals, long tasks, the app's `debug.frames` over the call);
- `<out>/summary.md`: the row as a table, and the driver's notes.

The refresh the judge counts missed vsyncs against is the app's own (`debug.frames` refresh_ms), else 120 Hz.
Report only: exit 0 when both arms measured, 1 when not (the summary says why), 2 when the app did not launch.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "ci" / "frame-pacing"))
from bench_launch import BenchApp, LaunchError  # noqa: E402
import golden  # noqa: E402
import ui_surface_stream  # noqa: E402


def refresh_of(data: dict) -> float:
    for result in data.get("rounds") or []:
        ms = float((result.get("app_frames") or {}).get("refresh_ms") or 0)
        if 2 <= ms <= 50:
            return ms
    return 1000 / 120


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--app", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--json", required=True)
    parser.add_argument("--tag", help="unused: the app's tag is its bundle's")
    parser.add_argument("--rounds", type=int, default=ui_surface_stream.ROUNDS)
    opts, unknown = parser.parse_known_args()
    if unknown:
        print(f"ui-surface-stream: ignoring {unknown}", file=sys.stderr)
    out = Path(opts.out) / "ui-surface-stream"
    out.mkdir(parents=True, exist_ok=True)
    ui_surface_stream.ROUNDS = max(1, opts.rounds)
    # The golden window (golden.sh's 1100 x 720) on the main display: the virtual one when split-spring.sh made it.
    app = BenchApp(opts.app, out=str(out), window=(80, 80, 1100, 720),
                   env={"CMUX_NEXT_AGENT_PANE_FULL_RATE": "1"})
    data: dict = {}
    driver = None
    try:
        try:
            app.launch()
        except LaunchError as error:
            report = {"suite": "ui-surface-stream", "error": f"launch: {error}"}
            Path(opts.json).write_text(json.dumps(report, indent=1) + "\n")
            print(f"ui-surface-stream: the app did not launch: {error}", file=sys.stderr)
            return 2
        driver = golden.Driver(app.socket, out)
        # Its file is the BenchApp's scratch cmux.json, which this run made: the only file the scenario may edit.
        ui_surface_stream.drive(driver, out, config=Path(app.scratch) / "cmux.json")
    finally:
        app.stop()
    data = golden.load(out, "ui_surface_stream") or {"error": "the scenario wrote no result"}
    refresh = refresh_of(data)
    verdict = ui_surface_stream.judge(data, refresh)
    row = ui_surface_stream.markdown_row(verdict)
    log = driver.log if driver else []
    summary = ["## Agent UI surface stream (live pane)", "",
               f"Display refresh {refresh:.2f} ms. Report only.", "",
               "| scenario | result | intermediate frames | largest step | frame p95 / max | notes |",
               "|---|---|---|---|---|---|", row]
    if log:
        summary += ["", "Driver notes:", ""] + [f"- {entry}" for entry in log[:20]]
    (out / "summary.md").write_text("\n".join(summary) + "\n")
    Path(opts.json).write_text(json.dumps({"suite": "ui-surface-stream", "refresh_ms": refresh, "verdict": verdict,
                                           "row": row, "driver_log": log, "data": data}, indent=1) + "\n")
    print("\n".join(summary))
    # One line a reader can grep in the step log.
    line = {key: verdict.get(key) for key in ("measured", "added_over_16_7", "claim_holds")}
    for arm in ui_surface_stream.ARMS:
        line[arm] = {key: (verdict.get(arm) or {}).get(key)
                     for key in ("p50_ms", "p95_ms", "max_ms", "over_16_7", "frames", "long_tasks")}
    print("UI-SURFACE-STREAM " + json.dumps(line))
    return 0 if verdict.get("measured") else 1


if __name__ == "__main__":
    os.umask(0o022)
    sys.exit(main())
