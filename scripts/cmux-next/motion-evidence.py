#!/usr/bin/env python3
"""Run and package cmux NEXT's native motion evidence.

This is a thin, receipt-oriented wrapper around the existing DEBUG socket guard:

    scripts/cmux-next/motion-evidence.py --socket /tmp/cmux-debug.sock --out evidence/motion

It drives the golden interactions, judges their per-display-link traces, and writes one
``motion-evidence.json`` manifest beside the scenario JSON, verdicts, and optional window frame
capture. It never builds or launches the app; callers supply the exact tagged DEBUG app socket.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--socket", required=True, help="debug socket of the already-built tagged app")
    parser.add_argument("--out", required=True, type=Path, help="evidence directory")
    parser.add_argument("--python", default=sys.executable, help="Python interpreter for golden.py")
    args = parser.parse_args()
    golden = Path(__file__).resolve().parents[1] / "ci" / "frame-pacing" / "golden.py"
    args.out.mkdir(parents=True, exist_ok=True)
    drive = subprocess.run([args.python, str(golden), "drive", args.socket, str(args.out)], text=True, capture_output=True)
    (args.out / "drive.stdout.log").write_text(drive.stdout)
    (args.out / "drive.stderr.log").write_text(drive.stderr)
    if drive.returncode != 0:
        return drive.returncode
    judge = subprocess.run([args.python, str(golden), "judge", str(args.out)], text=True, capture_output=True)
    (args.out / "judge.md").write_text(judge.stdout)
    (args.out / "judge.stderr.log").write_text(judge.stderr)
    verdicts = {}
    verdict_file = args.out / "verdicts.json"
    if verdict_file.exists():
        verdicts = json.loads(verdict_file.read_text())
    manifest = {
        "schema": "cmux.motion-evidence.v1",
        "createdAt": datetime.now(timezone.utc).isoformat(),
        "socket": "tagged-debug-app",
        "guard": "scripts/ci/frame-pacing/golden.py",
        "verdicts": verdicts,
        "judgeExitCode": judge.returncode,
        "artifacts": sorted(path.name for path in args.out.iterdir() if path.is_file()),
    }
    (args.out / "motion-evidence.json").write_text(json.dumps(manifest, indent=2) + "\n")
    sys.stdout.write(judge.stdout)
    return judge.returncode


if __name__ == "__main__":
    raise SystemExit(main())
