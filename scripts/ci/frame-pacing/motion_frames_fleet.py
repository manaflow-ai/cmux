#!/usr/bin/env python3
"""golden.py's motion_frames on a cmux-ci fleet Mac: `split-spring.sh --suite=motion-frames`.

    cmux-ci run --class exclusive --measurement --label measure --display \
      --script scripts/measure/split-spring.sh --ref SHA \
      --arg=--suite=motion-frames --arg=--vdisplay=120 --artifact artifacts/split-spring/report.json

split-spring.sh builds the ref's app and brings up the 120 Hz virtual display, then
split-spring-terminal.py hands over here with `--tag --app --out --json`. This runs golden.sh
(GOLDEN_ONLY=motion_frames, GOLDEN_DISPLAY=given) on that app, judges it, and writes report.json:
{verdict, exit, markdown}. Exit 1 only on a measured FAIL; not measured exits 0 (fail open).
The same check the `frames` suite of cmux-next-frame-pacing.yml runs on an owned Mac.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--tag", required=True, help="the app's baked tag")
    parser.add_argument("--app", required=True, help="the built .app")
    parser.add_argument("--out", required=True, help="the artifact folder")
    parser.add_argument("--json", required=True, help="report.json")
    args, _ = parser.parse_known_args(argv)

    work = Path(args.out) / "motion-frames-work"
    (work / "app").mkdir(parents=True, exist_ok=True)
    link = work / "app" / Path(args.app).name
    if not link.exists():
        link.symlink_to(Path(args.app).resolve())
    env = {**os.environ, "CMUX_TAG": args.tag, "GOLDEN_ONLY": "motion_frames", "GOLDEN_DISPLAY": "given"}
    drive = subprocess.run(["bash", str(HERE / "golden.sh"), str(work)], env=env, timeout=900)
    out = work / "out" / "golden"
    judged = subprocess.run([sys.executable, str(HERE / "golden.py"), "judge", str(out)],
                            capture_output=True, text=True, timeout=120)
    verdicts_path = out / "verdicts.json"
    verdicts = json.loads(verdicts_path.read_text()) if verdicts_path.exists() else {}
    verdict = verdicts.get("motion_frames") or {"ok": True, "measured": False, "note": "not measured: no verdict"}
    report = {"suite": "motion-frames", "drive_exit": drive.returncode, "judge_exit": judged.returncode,
              "verdict": verdict, "markdown": judged.stdout}
    Path(args.json).parent.mkdir(parents=True, exist_ok=True)
    Path(args.json).write_text(json.dumps(report, indent=2) + "\n")
    print(judged.stdout)
    if judged.stderr:
        print(judged.stderr, file=sys.stderr)
    return 1 if verdict.get("measured") and not verdict.get("ok") else 0


if __name__ == "__main__":
    sys.exit(main())
