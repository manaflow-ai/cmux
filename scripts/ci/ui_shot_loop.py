#!/usr/bin/env python3
"""The UI screenshot loop's glue: base renders vs head renders, judged by cmux-shotdiff, posted on the PR.

Leo, 2026-11-27 14:30Z: "i think even y'all didnt even look at sceenshots for those / do we have that kinda loop? ...
i feel like some of those ought to be in the monorepo so it's just fire and forget".

    ui_shot_loop.py stage --surface web --base DIR --head DIR --out OUT
        pairs the ready screenshots of two gallery-matrix output dirs (results.json + PNGs) by state name;
        writes OUT/base/<surface>/<name>.png (to bless), OUT/heads/<surface>/<name>.png (to check) and
        OUT/states.json (name, label, new/removed). A state with no base render is new, one with no head is removed.
    ui_shot_loop.py gate --report report.json --states states.json [--labels L,L] [--body FILE]
        prints STATE<TAB>DESCRIPTION for the `cmux/ui-shot` status:
          success  nothing visual was rendered, or no state moved past shotdiff's threshold
          success  states moved and the PR says so: label `ui-shot-intended`, or a `Visual-change:` body line
          failure  states moved past the threshold and nothing says they are wanted
    ui_shot_loop.py media --report R --base DIR --heads DIR --shotdiff-out DIR --out DIR
        copies the base, head and diff PNG of each moved state under its pr-media name
    ui_shot_loop.py comment --report R --states S --media-dir DIR --pr N --sha SHA --repo R [--run-url U] [--intended]
        prints the PR comment (marker line first); images are the files pr-media.py --pr N put on pr-media.
    ui_shot_loop.py status STATE DESCRIPTION   env REPO SHA GH_TOKEN [RUN_URL]: post `cmux/ui-shot`

Stdlib only.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.parse
from pathlib import Path

CONTEXT = "cmux/ui-shot"
MARKER = "<!-- cmux-ui-shot-loop -->"
INTENDED_LABEL = "ui-shot-intended"
VISUAL_CHANGE = re.compile(r"^\s*Visual-change:\s*\S", re.M | re.I)
RAW = "https://raw.githubusercontent.com"
MEDIA_BRANCH = "pr-media"
MAX_ROWS = 24


def _results(directory: Path) -> dict[str, dict]:
    """state name -> result row, for rows whose screenshot is on disk and ready."""
    path = directory / "results.json"
    if not path.is_file():
        return {}
    out: dict[str, dict] = {}
    for row in json.loads(path.read_text()):
        shot = row.get("screenshot")
        if not shot or not (directory / shot).is_file() or row.get("ready") is False:
            continue
        out[Path(shot).stem] = row
    return out


def _label(row: dict) -> str:
    params = row.get("params") or {}
    bits = [str(row.get("id", ""))]
    for key in ("colorScheme", "theme", "width"):
        if params.get(key):
            bits.append(f"{key}={params[key]}")
    return " ".join(b for b in bits if b)


def cmd_stage(args) -> int:
    base, head = _results(Path(args.base)), _results(Path(args.head))
    out = Path(args.out)
    states = []
    for name in sorted(set(base) | set(head)):
        entry = {"name": f"{args.surface}/{name}", "label": _label(head.get(name) or base[name]),
                 "state": "changed" if name in base and name in head else "new" if name in head else "removed"}
        for which, rows, src in (("base", base, Path(args.base)), ("heads", head, Path(args.head))):
            if name in rows:
                dest = out / which / args.surface / f"{name}.png"
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(src / rows[name]["screenshot"], dest)
        states.append(entry)
    out.mkdir(parents=True, exist_ok=True)
    prior = []
    if (out / "states.json").is_file():
        prior = json.loads((out / "states.json").read_text())
    (out / "states.json").write_text(json.dumps(prior + states, indent=1) + "\n")
    print(f"staged {len(states)} {args.surface} states ({sum(s['state'] == 'new' for s in states)} new, "
          f"{sum(s['state'] == 'removed' for s in states)} removed)")
    return 0


def _failed(report: dict) -> list[dict]:
    return [e for e in report.get("entries", []) if e.get("status") in ("fail", "error")]


def cmd_gate(args) -> int:
    states = json.loads(Path(args.states).read_text()) if Path(args.states).is_file() else []
    if not states:
        print("success\tno visual state rendered for this head")
        return 0
    report = json.loads(Path(args.report).read_text())
    bad = _failed(report)
    if not bad:
        print(f"success\t{len(states)} states rendered, none moved past the pixel threshold")
        return 0
    body = Path(args.body).read_text() if args.body and Path(args.body).is_file() else ""
    labels = {x for x in (args.labels or "").split(",") if x}
    if INTENDED_LABEL in labels or VISUAL_CHANGE.search(body):
        print(f"success\t{len(bad)} states changed, marked intended")
        return 0
    print(f"failure\t{len(bad)} of {len(states)} states changed: label {INTENDED_LABEL} or add a Visual-change: line if wanted")
    return 0


def _img(repo: str, pr: int, name: str) -> str:
    return f"{RAW}/{repo}/{MEDIA_BRANCH}/{urllib.parse.quote(f'{pr}/{name}')}"


def media_name(state: str, kind: str) -> str:
    return "ui-shot-" + state.replace("/", "_") + f"-{kind}.png"


def cmd_comment(args) -> int:
    report = json.loads(Path(args.report).read_text())
    states = {s["name"]: s for s in json.loads(Path(args.states).read_text())}
    bad = _failed(report)
    moved = [e for e in report.get("entries", []) if e.get("status") not in ("identical", "pass", "missing")]
    lines = [MARKER, f"### UI screenshots, base vs head `{args.sha[:12]}`", ""]
    if bad:
        verdict = "**pixel diff above the threshold**" + (
            ", marked intended" if args.intended else
            f": label `{INTENDED_LABEL}` or add a `Visual-change:` line to the PR body if wanted")
    else:
        verdict = "no state moved past the threshold"
    lines.append(f"{len(states)} states rendered; {verdict}. Threshold: shotdiff defaults "
                 "(16/255 per channel, 1% of pixels, SSIM 0.98).")
    lines.append("")
    shown = (bad + [e for e in moved if e not in bad])[:MAX_ROWS]
    for e in shown:
        s = states.get(e["name"], {})
        v = e.get("verdict") or {}
        ratio = v.get("changed_ratio")
        what = e.get("status", "?") + (f" ({ratio * 100:.2f}% px, ssim {v.get('ssim')})" if ratio is not None else "")
        lines += [f"#### {s.get('label', e['name'])}: {what}", ""]
        # One picture per line at full width with a caption above it, never a table of thumbnails.
        for kind, caption in (("base", "Before (merge base)"), ("head", "After (head)"), ("diff", "Diff (red = changed)")):
            f = Path(args.media_dir) / media_name(e["name"], kind)
            if f.is_file():
                lines += [caption, "", f"![{kind}]({_img(args.repo, args.pr, f.name)})", ""]
    if len(moved) > len(shown):
        lines.append(f"{len(moved) - len(shown)} more in the run's artifact.")
    lines.append("")
    if args.run_url:
        lines.append(f"[run]({args.run_url}) | scripts/ci/ui_shot_loop.py | gate: `{CONTEXT}`")
    print("\n".join(lines))
    return 0


def cmd_media(args) -> int:
    report = json.loads(Path(args.report).read_text())
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    n = 0
    for e in report.get("entries", []):
        if e.get("status") in ("identical", "pass", "missing"):
            continue
        for kind, src in (("base", Path(args.base) / f"{e['name']}.png"), ("head", Path(args.heads) / f"{e['name']}.png"),
                          ("diff", Path(args.shotdiff_out) / "diff" / f"{e['name']}.png")):
            if src.is_file() and n < MAX_ROWS * 3:
                shutil.copyfile(src, out / media_name(e["name"], kind))
                n += 1
    print(f"{n} images")
    return 0


def cmd_status(args) -> int:
    repo, sha, token = os.environ["REPO"], os.environ["SHA"], os.environ["GH_TOKEN"]
    body = {"state": args.state, "context": CONTEXT, "description": args.description[:140]}
    if os.environ.get("RUN_URL"):
        body["target_url"] = os.environ["RUN_URL"]
    p = subprocess.run(["gh", "api", f"repos/{repo}/statuses/{sha}", "--input", "-"], input=json.dumps(body),
                       text=True, capture_output=True, env={**os.environ, "GH_TOKEN": token})
    if p.returncode:
        print(f"::warning::{CONTEXT} not posted: {p.stderr.strip()[:200]}", file=sys.stderr)
    return 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("stage")
    s.add_argument("--surface", default="web")
    s.add_argument("--base", required=True)
    s.add_argument("--head", required=True)
    s.add_argument("--out", required=True)
    s.set_defaults(fn=cmd_stage)
    g = sub.add_parser("gate")
    g.add_argument("--report", required=True)
    g.add_argument("--states", required=True)
    g.add_argument("--labels")
    g.add_argument("--body")
    g.set_defaults(fn=cmd_gate)
    m = sub.add_parser("media")
    m.add_argument("--report", required=True)
    m.add_argument("--base", required=True)
    m.add_argument("--heads", required=True)
    m.add_argument("--shotdiff-out", required=True)
    m.add_argument("--out", required=True)
    m.set_defaults(fn=cmd_media)
    c = sub.add_parser("comment")
    c.add_argument("--report", required=True)
    c.add_argument("--states", required=True)
    c.add_argument("--media-dir", required=True)
    c.add_argument("--pr", type=int, required=True)
    c.add_argument("--sha", required=True)
    c.add_argument("--repo", required=True)
    c.add_argument("--run-url")
    c.add_argument("--intended", action="store_true")
    c.set_defaults(fn=cmd_comment)
    t = sub.add_parser("status")
    t.add_argument("state")
    t.add_argument("description")
    t.set_defaults(fn=cmd_status)
    args = ap.parse_args(argv)
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
