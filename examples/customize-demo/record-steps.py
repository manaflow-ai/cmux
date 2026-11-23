#!/usr/bin/env python3
"""Write NIGHTLY capture steps in demo.sh's order.

    python3 examples/customize-demo/record-steps.py --ref FULL_SHA --output-dir /tmp/demo-states
    cmux-ci capture --nightly latest --state /tmp/demo-states/looks-hosts.json

--ref downloads published profiles into a unique temporary folder on the capture
Mac. --root instead uses files already staged there. Neither capture runner copies
the caller's checkout. --only records a subset; --video adds a short display clip. A clip's `recording`
step needs a whole capture Mac, which a lane VM cannot lease; --frames N takes N stills
per look instead (any route), which `ffmpeg` joins into a clip (VIDEO.md).
The copy ends on its own setup after `cmux customize discard`.
"""
import argparse
import json
import math
import re
import shlex
import subprocess
import sys
import uuid
from pathlib import Path

HERE = Path(__file__).resolve().parent
MAX_STEPS = 60  # NIGHTLY capture runner's limit


def stage_profiles(ref: str, root: str, files: list[str]) -> list[dict]:
    """Download data only, then wait on terminal output before using the files."""
    source = f"https://raw.githubusercontent.com/manaflow-ai/cmux/{ref}/examples/customize-demo/"
    code = (
        "from concurrent.futures import ThreadPoolExecutor\n"
        "from pathlib import Path\n"
        "from urllib.request import urlopen\n"
        f"root = Path({root!r})\n"
        "def fetch(name):\n"
        "    target = root / name\n"
        "    target.parent.mkdir(parents=True, exist_ok=True)\n"
        f"    with urlopen({source!r} + name, timeout=20) as response:\n"
        "        target.write_bytes(response.read())\n"
        "with ThreadPoolExecutor(max_workers=4) as pool:\n"
        f"    list(pool.map(fetch, {files!r}))\n"
        "print('CUSTOMIZATION_PROFILES_READY', flush=True)\n"
    )
    command = f"python3 -c {shlex.quote(code)}"
    if len(command) > 2000:
        raise ValueError("profile download command exceeds capture's argument limit; use --only")
    workspace = f"Demo setup {Path(root).name[-8:]}"
    return [
        {"cmux": ["workspace", "new", "--name", workspace, "--cwd", "/tmp", "--shell", command]},
        {"cmux": ["workspace", f"name:{workspace}", "screen", "current", "pane", "current",
                  "tab", "current", "terminal", "current", "screen", "wait", "--pattern",
                  "^CUSTOMIZATION_PROFILES_READY$", "--timeout-ms", "40000"], "record": True},
    ]


def main() -> int:
    parser = argparse.ArgumentParser()
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--root", help="absolute profile folder on the capture Mac")
    source.add_argument("--ref", help="published full commit SHA to download")
    parser.add_argument("--only", action="append", help="profile path from demo.sh --list; repeatable")
    parser.add_argument("--hold", type=float, default=3.0)
    parser.add_argument("--video", action="store_true", help="record a clip; requires a fleet display lease")
    parser.add_argument("--frames", type=int, default=1,
                        help="stills per look, spread over --hold (1 to 12): frames for a clip on any route")
    parser.add_argument("--output-dir", type=Path,
                        help="write one capture state per look (one named video each with --video)")
    args = parser.parse_args()
    if not math.isfinite(args.hold) or not 0 <= args.hold <= 30:
        parser.error("--hold must be from 0 to 30 seconds")
    if not 1 <= args.frames <= 12:
        parser.error("--frames must be from 1 to 12")
    if args.ref and not re.fullmatch(r"[0-9a-f]{40}", args.ref):
        parser.error("--ref must be a full lowercase commit SHA")
    if args.root and not Path(args.root).is_absolute():
        parser.error("--root must be an absolute folder on the capture Mac")
    files = subprocess.run([str(HERE / "demo.sh"), "--list"], capture_output=True, text=True, check=True)
    ordered = files.stdout.split()
    if args.only:
        unknown = set(args.only) - set(ordered)
        if unknown:
            parser.error(f"unknown profiles: {', '.join(sorted(unknown))}")
        ordered = [file for file in ordered if file in args.only]
    if args.output_dir:
        # Exclusive creation prevents overwriting states tied to an earlier receipt.
        args.output_dir.mkdir(parents=True, exist_ok=False)
        for file in ordered:
            name = clip_name(file)
            state = capture_steps(args, [file], name)
            path = args.output_dir / f"{name}.json"
            path.write_text(json.dumps({"steps": state}, indent=2) + "\n")
            print(path)
        return 0
    steps = capture_steps(args, ordered, "customization-demo")
    if len(steps) > MAX_STEPS:
        parser.error(f"{len(steps)} steps, capture takes {MAX_STEPS}; use --output-dir or split with --only")
    if args.video and len(ordered) * args.hold > 90:
        parser.error("leave time for transitions within the 120-second clip: use --output-dir")
    json.dump({"steps": steps}, sys.stdout, indent=2)
    print()
    return 0


def clip_name(file: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", Path(file).with_suffix("").as_posix().lower()).strip("-")


def capture_steps(args, ordered: list[str], clip: str) -> list[dict]:
    root = args.root or f"/tmp/customization-demo-{uuid.uuid4().hex[:12]}"
    # Status is evidence only: discard resets the profile, not library overlays.
    # This capture uses an isolated fresh home; inspect both answers before reuse.
    steps = [{"cmux": ["customize", "library", "status"], "record": True}]
    if args.ref:
        steps += stage_profiles(args.ref, root, ordered)
    if args.video:
        steps.append({"recording": "start", "clip": clip})
    if args.frames > 1:
        steps.append({"shot": "00-before"})
    for index, file in enumerate(ordered, start=1):
        if index > 1:
            steps.append({"cmux": ["customize", "discard"], "record": True})
        name = clip_name(file)
        steps += [
            {"cmux": ["customize", "use", f"{root}/{file}"], "record": True},
            # newTab.page: a capture's action.run is a script, which newTab.default gives a tab of the selected
            # tab's kind (the setup terminal), never the New Tab page that shows the look's own page.
            {"action": "newTab.page", "name": f"New Tab: {file}"},
        ]
        for frame in range(1, args.frames):
            steps += [{"wait": round(args.hold / args.frames, 2)},
                      {"shot": f"{index:02d}-{frame:02d}-{name}"[:48]}]
        steps += [
            {"wait": round(args.hold / args.frames, 2) if args.frames > 1 else args.hold},
            {"shot": f"{index:02d}-{name}"[:48]},
        ]
    if args.video:
        steps.append({"recording": "stop"})
    steps += [
        {"cmux": ["customize", "discard"], "record": True},
        {"cmux": ["customize", "library", "status"], "record": True},
        {"action": "newTab.page", "name": "Restored New Tab"},
        {"wait": 2},
        {"shot": "99-after-reset"},
    ]
    return steps


if __name__ == "__main__":
    sys.exit(main())
