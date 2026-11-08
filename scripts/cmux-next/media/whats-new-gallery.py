#!/usr/bin/env python3
"""Render each What's New highlight's gallery state, and its before, and put them on pr-media.

    whats-new-gallery.py plan [--days N] [--all] --out PLAN.json     the states to render
    whats-new-gallery.py manifest --plan PLAN.json --cases ALL.json --out MANIFEST.json
    whats-new-gallery.py publish --plan PLAN.json --results DIR       privacy check, then upload

Leo, 2026-10-20: "tho i think vids and before/afters for our techincal stuff is p important... we
want things to be PRETTY!!!!" On 2026-11-08 one of the 31 New or Improved highlights in the newest
30 nightlies had a picture: release-notes.py --pr-media takes the first pr-media picture in the pull
request's body, and bodies stopped carrying them. Most of those pull requests change a webview
gallery entry, and many name the state they picked and the one before it. A highlight now says so:

    gallery: pages.changelog.update-surfaces/card-preview-over-rows
    before: pages.changelog.update-surfaces/card-preview-over-rows-solid

whats-new-gallery.yml runs this on each push to feat-cmux-next that changes a highlight:

- `plan` lists the highlights added in the last DAYS (default 7) with a `gallery:` line, and each
  state (after, before) whose picture is not on pr-media yet (`--all`: every one);
- `manifest` keeps, from webviews/scripts/gallery/manifest.ts's cases (default dark theme, normal
  width, component frame), the one case per planned state, named HIGHLIGHT--ROLE;
- scripts/gallery-matrix/runner.ts renders them in Chromium;
- `publish` reads each picture through scripts/pr-media.py's privacy check (a refusal uploads
  nothing) and puts it at release-notes.py's gallery_url, whats-new/ID/gallery-KEY-ROLE.png.

The next nightly's notes find the pictures there (release-notes.py add_gallery_media). Only the
states a highlight names are published, never every state a pull request touches (#21400 took the
automatic per-PR gallery publishing out). A highlight with a clip shows the clip instead.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import time
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[3]
REPO = "manaflow-ai/cmux"
BRANCH = "pr-media"
ENGINE = "chromium"


def _load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


notes = _load("release_notes_for_gallery", ROOT / "scripts/cmux-next/release-notes.py")


def git(*args: str) -> str:
    return subprocess.run(["git", "-C", str(ROOT), *args], capture_output=True, text=True, check=True).stdout


def published(url: str) -> bool:
    request = urllib.request.Request(url, method="HEAD", headers={"User-Agent": "cmux-whats-new-gallery/1"})
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            return response.status == 200
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return False
        raise


def plan(days: int, everything: bool, exists=published) -> list[dict]:
    since = time.time() - days * 86400
    rows = []
    for name in sorted(git("ls-files", "--", notes.HIGHLIGHTS).split()):
        if not name.endswith(".md"):
            continue
        born = git("log", "--diff-filter=A", "--format=%ct", "-1", "HEAD", "--", name).strip()
        if not born or int(born) < since:
            continue
        meta, _ = notes.front_matter((ROOT / name).read_text(encoding="utf-8"))
        if notes.CLIP.fullmatch(meta.get("clip", "")):
            continue
        highlight_id = Path(name).stem
        for role, state in notes.gallery_states(meta).items():
            url = notes.gallery_url(highlight_id, role, state)
            if everything or not exists(url):
                entry, _, variant = state.partition("/")
                rows.append({"id": highlight_id, "role": role, "state": state, "entry": entry,
                             "variant": variant, "url": url, "path": url.split(f"/{BRANCH}/", 1)[1]})
    return rows


def case_id(row: dict) -> str:
    return f"{row['id']}--{row['role']}"


def manifest(rows: list[dict], cases: list[dict]) -> tuple[list[dict], list[str]]:
    """One case per row: the dark default theme's case of its entry and variant; and the rows with none."""
    out, missing = [], []
    for row in rows:
        hit = next((c for c in cases if c.get("params", {}).get("entry") == row["entry"]
                    and c["params"].get("variant") == row["variant"] and c["params"].get("colorScheme") == "dark"),
                   None)
        if hit is None:
            missing.append(f"{row['id']}: no gallery state {row['state']}")
            continue
        out.append({**hit, "id": case_id(row)})
    return out, missing


def publish(rows: list[dict], results: Path) -> list[str]:
    pr_media = _load("pr_media_tool", ROOT / "scripts/pr-media.py")
    files = []
    problems = []
    for row in rows:
        local = results / f"{case_id(row)}-{ENGINE}.png"
        if not local.is_file() or not notes.pr_media_picture(local.read_bytes()):
            problems.append(f"{row['id']} {row['role']}: {row['state']} did not render")
            continue
        files.append((row, local))
    if files:
        if pr_media.privacy_module().ocr_binary() is None:
            raise SystemExit("whats-new-gallery: publish reads every picture first, and no OCR is set up")
        # One check for all of them: a refusal names paths and kinds only, and uploads nothing.
        pr_media.check_privacy([(row["path"], local) for row, local in files], REPO)
        for row, local in files:
            pr_media.put_file(REPO, BRANCH, row["path"], local,
                              f"What's New picture: {row['id']} ({row['role']}, {row['state']})", checked=True)
            print(row["url"])
    return problems


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("plan")
    p.add_argument("--days", type=int, default=7)
    p.add_argument("--all", action="store_true")
    p.add_argument("--out", type=Path, required=True)
    m = sub.add_parser("manifest")
    m.add_argument("--plan", type=Path, required=True)
    m.add_argument("--cases", type=Path, required=True)
    m.add_argument("--out", type=Path, required=True)
    u = sub.add_parser("publish")
    u.add_argument("--plan", type=Path, required=True)
    u.add_argument("--results", type=Path, required=True)
    args = parser.parse_args(argv)
    if args.cmd == "plan":
        rows = plan(args.days, args.all)
        args.out.write_text(json.dumps(rows, indent=2) + "\n")
        print(" ".join(sorted({r["entry"] for r in rows})))
        return 0
    rows = json.loads(args.plan.read_text())
    if args.cmd == "manifest":
        cases, missing = manifest(rows, json.loads(args.cases.read_text()))
        args.out.write_text(json.dumps(cases, indent=2) + "\n")
        for line in missing:
            print(f"::warning title=What's New picture::{line}")
        return 0
    problems = publish(rows, args.results)
    for line in problems:
        print(f"::warning title=What's New picture::{line}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
