#!/usr/bin/env python3
"""Write the demo as a hot-verify steps file: each setup turned on in demo.sh's order, a pause, a shot.

    python3 examples/customize-demo/record-steps.py [--root DIR] [--hold SECONDS] > /tmp/demo-steps.json
    cmux-ci hot-verify PR --look --video --state /tmp/demo-steps.json

--root is where the profiles sit on the Mac that records (default: this folder, relative to the checkout,
which is where hot-verify runs its `cmux` steps). The last step is `cmux customize discard`, so the copy
ends on its own setup.
"""
import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
MAX_STEPS = 60  # hot-verify.py's limit


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default="examples/customize-demo")
    parser.add_argument("--hold", type=float, default=5.0)
    args = parser.parse_args()
    files = subprocess.run([str(HERE / "demo.sh"), "--list"], capture_output=True, text=True, check=True)
    steps = [{"action": "newTab.default", "name": "New Tab"}, {"wait": 2}, {"shot": "00-before"}]
    for index, file in enumerate(files.stdout.split(), start=1):
        name = re.sub(r"[^a-z0-9]+", "-", Path(file).with_suffix("").as_posix().lower()).strip("-")
        steps += [
            {"cmux": ["customize", "use", f"{args.root}/{file}"]},
            {"wait": args.hold},
            {"shot": f"{index:02d}-{name}"[:48]},
        ]
    steps += [{"cmux": ["customize", "discard"]}, {"wait": 2}, {"shot": "99-after-reset"}]
    if len(steps) > MAX_STEPS:
        print(f"record-steps: {len(steps)} steps, hot-verify takes {MAX_STEPS}; record in two runs", file=sys.stderr)
        return 1
    json.dump({"steps": steps}, sys.stdout, indent=2)
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
