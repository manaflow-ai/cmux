#!/usr/bin/env python3
"""Layout shifts, blinks and staggered settles in every recording under some folders, as one Markdown table.

  scripts/cmux-next/recording-shifts-report.py DIR_OR_FILE... [--summary OUT.md] [--title T]

Each .mov, .mp4 or .y4m found (recursively) is read by flicker-check.py; its report is written beside it as
<recording>.shifts.json, and one row per recording goes to stdout (and is appended to --summary, e.g.
$GITHUB_STEP_SUMMARY): jumps (a block that moved in one frame and stayed), blinks, staggered settles, glides
(moves over several frames, not counted as shifts), and the first jumps' times, boxes and moves in source pixels.

It reports; it never fails a run (exit 0 even when a recording cannot be read: its row says why). The seeded
recordings in scripts/cmux-next/tests/test_flicker_check.py are what fail CI when the detector stops seeing a
planted shift. The iOS simulator's `video` runs (scripts/ci/cmux-next-ios-sim.sh) and the Mac What's New and
tour captures (cmux-next-media.yml) call this.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("flicker_check", HERE / "flicker-check.py")
flicker = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(flicker)

SUFFIXES = (".mov", ".mp4", ".y4m")


def recordings(paths):
    for path in paths:
        if path.is_file() and path.suffix.lower() in SUFFIXES:
            yield path
        elif path.is_dir():
            yield from sorted(p for p in path.rglob("*") if p.is_file() and p.suffix.lower() in SUFFIXES)


def row(path, report, seconds, base):
    counts = report["counts"]
    jumps = [e for e in report["events"] if e["kind"] == "jump"][:3]
    first = "; ".join(f"{e['ms'] / 1000:.2f}s ({e['dx']},{e['dy']})px at {e['box']}" for e in jumps) or "-"
    name = path.relative_to(base) if base and path.is_relative_to(base) else path
    return (f"| `{name}` | {report['frames']} | {counts['jump']} | {counts['blink']} | {counts['staggered']} | "
            f"{counts['glide']} | {first} | {seconds:.1f}s |")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("paths", nargs="+", type=Path)
    parser.add_argument("--summary", type=Path, help="append the table here too (e.g. $GITHUB_STEP_SUMMARY)")
    parser.add_argument("--title", default="Layout shifts in the recordings (scripts/cmux-next/flicker-check.py)")
    args = parser.parse_args(argv)

    base = args.paths[0] if len(args.paths) == 1 and args.paths[0].is_dir() else None
    lines = [f"### {args.title}", "",
             "| recording | frames | jumps | blinks | staggered | glides | first jumps | read in |",
             "|---|---:|---:|---:|---:|---:|---|---:|"]
    found = 0
    for path in recordings(args.paths):
        found += 1
        started = time.monotonic()
        try:
            report = flicker.analyse(path)
        except (Exception, SystemExit) as error:  # noqa: BLE001
            # One unreadable recording (a half-written file, no ffmpeg) is a row, not a failed run.
            lines.append(f"| `{path}` | - | - | - | - | - | not read: {' '.join(str(error).split())[:160]} | - |")
            continue
        Path(f"{path}.shifts.json").write_text(json.dumps(report, indent=2) + "\n")
        lines.append(row(path, report, time.monotonic() - started, base))
    if not found:
        lines.append("| (no .mov, .mp4 or .y4m recording found) | | | | | | | |")
    text = "\n".join(lines) + "\n"
    sys.stdout.write(text)
    if args.summary:
        with args.summary.open("a") as out:
            out.write(text + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
