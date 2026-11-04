#!/usr/bin/env python3
"""m6 (d) film check (cmux-ad m6, frame-owner-s4): in every frame of a key resize, each terminal shows its content at its
pane's size, its content edge within 1 device px of the pane edge cmux shows in the same frame, or the previous frame's
size clipped and anchored top-left ("late"); never stretched, never the shell beside it.

  judge_m6.py BASE [BASE ...] [--judge JUDGE_PIXEL.py] [--json OUT.json]
      BASE: a fixture film without suffix (.../px-keys-rk-3t-s1r-s1), or any of its files

The judge is judge_pixel.py's m6 contract (R-HARNESS 3e.1: rules E2 to E5 per film frame and content kind, the pane edge
from cmux's own layer in the same frame). It reads only fixture films (the note px_record_start writes): gen_pixel.py's
px-keys-rk-3t plays the open-P0 journey resize-keyboard's presses on three terminal fixtures in its places.

Per film, one verdict from the judge's `m6.kinds.terminal` row:
  pass        no failing terminal frame, and at least one terminal frame judged (late frames pass: the previous size,
              clipped, top-left, is the contract's allowance until the new size's frame is drawn)
  fail        a failing terminal frame: the frames and the rule of each edge (E2 a top-left edge off, E3 a far edge off,
              E4 the shell beside the content, E5 a stretched ring)
  not judged  the judge could not read the film (exit 2: no scan, trace or fixture note) or judged no terminal frame:
              never a pass
The judge's other items (pages, dividers, the film's clock) are not this check's. Exit 0 when every film passes, 1 when a
film fails, 2 when a film is not judged and none fails.

Without --judge, the judge is judge_pixel.py at JUDGE_REF (R-HARNESS's branch r-harness/s1b-3e1-main-window), taken from
git with the video_judge.py it imports into a folder of its own (the kit's own judge_pixel.py has no m6 rows yet). It needs
numpy: run this under the VM venv (/work/tmp/bv-venv/bin/python); the judge runs under the same interpreter.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

JUDGE_REF = "b774bd3df0dc"
JUDGE_FILES = ("scripts/journeys/video-cases/judge_pixel.py", "scripts/journeys/video_judge.py")
SUFFIXES = (".mov.frames.json", ".mov.scan", ".trace.json", ".events.json", ".meta.json", ".result.json", ".mov")
RULES = ("E2", "E3", "E4", "E5")


def base_of(path: str) -> str:
    for suffix in SUFFIXES:
        if path.endswith(suffix):
            return path[: -len(suffix)]
    return path


def verdict(report: dict | None, judge_exit: int, stderr: str = "") -> dict:
    """The film's verdict from judge_pixel's report (None when it wrote none) and its exit code."""
    if report is None or judge_exit == 2:
        why = (stderr.strip().splitlines() or [f"the judge exited {judge_exit} with no report"])[-1][:300]
        return {"status": "not judged", "line": f"m6 terminal content: not judged ({why})"}
    row = ((report.get("m6") or {}).get("kinds") or {}).get("terminal")
    if not row or row.get("frames", 0) - row.get("not_judged", 0) <= 0:
        return {"status": "not judged", "line": "m6 terminal content: not judged (no terminal frame judged)"}
    out = {key: row.get(key, 0) for key in ("frames", "pass", "late", "fail", "not_judged")}
    counts = f"{out['pass']} pass, {out['late']} late, {out['not_judged']} not judged of {out['frames']} frames"
    if out["fail"]:
        rules = ", ".join(f"{r} {n}" for r, n in (row.get("fail_by_rule") or {}).items() if n and r in RULES)
        line = (f"m6 terminal content: FAIL, {out['fail']} failing frames (frames {row.get('fail_ranges')}; edges: {rules}); "
                f"{counts}")
        return {"status": "fail", "line": line, **out}
    return {"status": "pass", "line": f"m6 terminal content: pass, 0 failing frames; {counts}", **out}


def git_show(ref: str, path: str) -> str:
    root = Path(__file__).resolve().parents[3]
    return subprocess.run(["git", "-C", str(root), "show", f"{ref}:{path}"], capture_output=True, text=True,
                          check=True, timeout=60).stdout


def extract_judge(folder: str, show=git_show) -> Path:
    """JUDGE_FILES at JUDGE_REF in FOLDER, laid out as judge_pixel.py imports them (video-cases/ under the journeys folder)."""
    judge = Path(folder) / "video-cases" / "judge_pixel.py"
    judge.parent.mkdir(parents=True, exist_ok=True)
    judge.write_text(show(JUDGE_REF, JUDGE_FILES[0]))
    (Path(folder) / "video_judge.py").write_text(show(JUDGE_REF, JUDGE_FILES[1]))
    return judge


def judge_film(judge: Path, base: str, scratch: str) -> dict:
    out = Path(scratch) / (os.path.basename(base) + ".pixel.json")
    done = subprocess.run([sys.executable, "-I", str(judge), base, "--json", str(out)], capture_output=True, text=True,
                          timeout=900)
    report = json.loads(out.read_text()) if out.is_file() else None
    if isinstance(report, list):  # several bases in one call write a list; this script asks for one at a time
        report = report[0] if report else None
    film = {"base": base, "judge_exit": done.returncode, **verdict(report, done.returncode, done.stderr)}
    return film


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0], formatter_class=argparse.RawDescriptionHelpFormatter,
                                 epilog=__doc__.split("\n\n", 1)[1])
    ap.add_argument("bases", nargs="+")
    ap.add_argument("--judge", help="a judge_pixel.py with m6 rows (default: JUDGE_REF from git)")
    ap.add_argument("--json")
    opts = ap.parse_args(argv)
    bases = list(dict.fromkeys(base_of(b) for b in opts.bases))
    with tempfile.TemporaryDirectory(prefix="judge-m6-") as scratch:
        judge = Path(opts.judge) if opts.judge else extract_judge(os.path.join(scratch, "judge"))
        films = [judge_film(judge, base, scratch) for base in bases]
    statuses = {f["status"] for f in films}
    status = "fail" if "fail" in statuses else "not judged" if "not judged" in statuses else "pass"
    for film in films:
        print(f"{os.path.basename(film['base'])}: {film['line']}")
    print(f"m6 (d): {status} ({sum(f['status'] == 'pass' for f in films)} of {len(films)} films pass)")
    if opts.json:
        Path(opts.json).write_text(json.dumps({"status": status, "judge": str(opts.judge or JUDGE_REF), "films": films},
                                              indent=1) + "\n")
    return {"pass": 0, "fail": 1, "not judged": 2}[status]


if __name__ == "__main__":
    sys.exit(main())
