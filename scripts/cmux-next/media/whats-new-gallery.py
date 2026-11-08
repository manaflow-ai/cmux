#!/usr/bin/env python3
"""Render each What's New highlight's gallery state, and its before, and put them on pr-media.

    whats-new-gallery.py plan [--days N] [--all] --out PLAN.json     the states to render
    whats-new-gallery.py manifest --plan PLAN.json --cases ALL.json [--parent SHA] --out MANIFEST.json
    whats-new-gallery.py parents --plan PLAN.json                     the commits to render befores at
    whats-new-gallery.py publish --plan PLAN.json --results DIR       privacy check, then upload

Leo, 2026-10-20: "tho i think vids and before/afters for our techincal stuff is p important... we
want things to be PRETTY!!!!" On 2026-11-08 one of the 31 New or Improved highlights in the newest
30 nightlies had a picture: release-notes.py --pr-media takes the first pr-media picture in the pull
request's body, and bodies stopped carrying them. Most of those pull requests change a webview
gallery entry, and many name the state they picked and the one before it. A highlight now says so:

    gallery: pages.changelog.update-surfaces/card-preview-over-rows
    before: pages.changelog.update-surfaces/card-preview-over-rows-solid

whats-new-gallery.yml runs this on each push to feat-cmux-next that changes a highlight:

- `plan` lists the highlights added in the last DAYS (default 7) and each picture (after, before)
  not on pr-media yet (`--all`: every one): the states a `gallery:` or `before:` line names, else
  for a New or Improved highlight the state to pick from the gallery files its commit changed, and
  for an Improved one with no `before:` the same state at the commit before it (release-notes.py
  gallery_urls);
- `manifest` picks those states (infer: the first variant the commit added, of the first entry it
  added one to, else the first entry's first variant), writes them back to the plan, and keeps, from
  webviews/scripts/gallery/manifest.ts's cases (default dark theme, normal width, component frame),
  the one case per planned state, named HIGHLIGHT--ROLE; with `--parent SHA`, from the cases of the
  checkout at SHA, the befores rendered there (the same state, else the entry's first one);
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
import re
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


def show(rev: str, path: str) -> str | None:
    """A file's text at a commit, or None where it is not."""
    run = subprocess.run(["git", "-C", str(ROOT), "show", f"{rev}:{path}"], capture_output=True, text=True)
    return run.stdout if run.returncode == 0 else None


def gallery_sources(commit: str) -> list[str]:
    """The gallery files a commit changed, as manifest.ts's cases name them (under webviews/)."""
    names = git("show", "--format=", "--name-only", "--diff-filter=AM", commit).split()
    return [n.removeprefix("webviews/") for n in names
            if n.startswith("webviews/") and re.search(r"\.gallery\.tsx?$", n)]


def plan(days: int, everything: bool, exists=published) -> list[dict]:
    since = time.time() - days * 86400
    rows = []
    for name in sorted(git("ls-files", "--", notes.HIGHLIGHTS).split()):
        if not name.endswith(".md"):
            continue
        born = git("log", "--diff-filter=A", "--format=%ct %H", "-1", "HEAD", "--", name).split()
        if not born or int(born[0]) < since:
            continue
        meta, _ = notes.front_matter((ROOT / name).read_text(encoding="utf-8"))
        if notes.CLIP.fullmatch(meta.get("clip", "")):
            continue
        highlight_id = Path(name).stem
        category = meta.get("category", "").lower()
        states = notes.gallery_states(meta)
        commit = born[1]
        for role, url in notes.gallery_urls(meta, highlight_id, category or "new").items():
            if not everything and exists(url):
                continue
            row = {"id": highlight_id, "role": role, "url": url, "path": url.split(f"/{BRANCH}/", 1)[1]}
            if role in states:
                row["state"] = states[role]
            else:
                # An inferred state, or the after state again at the commit before the highlight's.
                row["state"] = states.get("after")
                if row["state"] is None:
                    row["sources"] = gallery_sources(commit)
                    row["commit"] = commit
                    if not row["sources"]:
                        continue
                if role == "before":
                    row["parent"] = git("rev-parse", f"{commit}^").strip()
            if row["state"]:
                row["entry"], _, row["variant"] = row["state"].partition("/")
            rows.append(row)
    return rows


def case_id(row: dict) -> str:
    return f"{row['id']}--{row['role']}"


def _dark(cases: list[dict]) -> list[dict]:
    return [c for c in cases if c.get("params", {}).get("colorScheme") == "dark"]


# A variant named for the old look (`before`, `-old`, `-solid`) shows what the change replaced.
OLD_LOOK = re.compile(r"(^|-)(before|old|solid|previous)$")


def _key(variant: str) -> re.Pattern:
    return re.compile(r"(?<![\w-])[\"']?" + re.escape(variant) + r"[\"']?\s*:")


def changed_lines(commit: str, path: str) -> set[int]:
    """The line numbers, in the file at `commit`, that the commit added or changed."""
    run = subprocess.run(["git", "-C", str(ROOT), "diff", "-U0", f"{commit}^", commit, "--", path],
                         capture_output=True, text=True)
    lines = set()
    for start, count in re.findall(r"^@@ -\S+ \+(\d+)(?:,(\d+))? @@", run.stdout, re.M):
        lines.update(range(int(start), int(start) + int(count or 1)))
    return lines


def infer(row: dict, cases: list[dict], text_at=show, changed=changed_lines) -> str | None:
    """The state of the gallery files row["commit"] changed: the first variant the commit added (its key
    is in the file at the commit and not the commit before), else the variant whose lines it changed most, else the first
    one; of the first entry with such a variant. A variant named for the old look is the last choice."""
    entries: dict[str, list[str]] = {}
    sources: dict[str, str] = {}
    for c in _dark(cases):
        p = c["params"]
        if p.get("source") in row["sources"]:
            variants = entries.setdefault(p["entry"], [])
            sources[p["entry"]] = p["source"]
            if p.get("variant") not in variants:
                variants.append(p["variant"])
    if not entries:
        return None
    commit = row["commit"]
    scored = []
    for entry, variants in entries.items():
        path = f"webviews/{sources[entry]}"
        variants = sorted(variants, key=lambda v: bool(OLD_LOOK.search(v)))
        before, after = text_at(f"{commit}^", path) or "", text_at(commit, path) or ""
        added = [v for v in variants if _key(v).search(after) and not _key(v).search(before)]
        if added:
            return f"{entry}/{added[0]}"
        text = after.split("\n")
        starts = sorted((next((i + 1 for i, line in enumerate(text) if _key(v).search(line)), 0), v)
                        for v in variants)
        touched = {v: 0 for v in variants}
        for line in changed(commit, path):
            owner = [v for start, v in starts if 0 < start <= line]
            if owner:
                touched[owner[-1]] += 1
        best = max(variants, key=lambda v: touched[v])  # the first of the most changed
        scored.append((touched[best], entry, best if touched[best] else variants[0]))
    count, entry, variant = max(scored, key=lambda s: s[0])  # ties keep the first entry
    return f"{entry}/{variant}"


def resolve(rows: list[dict], cases: list[dict], text_at=show) -> tuple[list[dict], list[str]]:
    """The rows with their inferred states filled in, and the highlights none could be picked for."""
    out, missing = [], []
    for row in rows:
        if not row.get("state"):
            state = infer(row, cases, text_at)
            if state is None:
                missing.append(f"{row['id']}: no gallery state in {', '.join(row['sources'])}")
                continue
            row = {**row, "state": state}
            row["entry"], _, row["variant"] = state.partition("/")
        out.append(row)
    return out, missing


def manifest(rows: list[dict], cases: list[dict], parent: str | None = None) -> tuple[list[dict], list[str]]:
    """One case per row: the dark default theme's case of its entry and variant; and the rows with none.
    With `parent`, the befores rendered at that commit: the same state, else its entry's first one there."""
    out, missing = [], []
    for row in rows:
        if row.get("parent") != parent:
            continue
        dark = [c for c in _dark(cases) if c["params"].get("entry") == row["entry"]]
        hit = next((c for c in dark if c["params"].get("variant") == row["variant"]), None)
        if hit is None and parent is not None and dark:
            hit = dark[0]
        if hit is None:
            missing.append(f"{row['id']}: no gallery state {row['state']}" + (f" at {parent}" if parent else ""))
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
    m.add_argument("--parent")
    m.add_argument("--out", type=Path, required=True)
    a = sub.add_parser("parents")
    a.add_argument("--plan", type=Path, required=True)
    a.add_argument("--limit", type=int, default=4)
    u = sub.add_parser("publish")
    u.add_argument("--plan", type=Path, required=True)
    u.add_argument("--results", type=Path, required=True)
    args = parser.parse_args(argv)
    if args.cmd == "plan":
        rows = plan(args.days, args.all)
        args.out.write_text(json.dumps(rows, indent=2) + "\n")
        # Every entry when a state is still to be picked: its entry is not known before the cases are.
        if all(r.get("state") for r in rows):
            print(" ".join(sorted({r["entry"] for r in rows})))
        return 0
    rows = json.loads(args.plan.read_text())
    if args.cmd == "parents":
        parents = list(dict.fromkeys(r["parent"] for r in rows if r.get("parent")))
        print(" ".join(parents[:args.limit]))
        return 0
    if args.cmd == "manifest":
        cases = json.loads(args.cases.read_text())
        missing = []
        if args.parent is None:
            rows, missing = resolve(rows, cases)
            args.plan.write_text(json.dumps(rows, indent=2) + "\n")
        out, unmatched = manifest(rows, cases, args.parent)
        args.out.write_text(json.dumps(out, indent=2) + "\n")
        for line in missing + unmatched:
            print(f"::warning title=What's New picture::{line}")
        return 0
    problems = publish(rows, args.results)
    for line in problems:
        print(f"::warning title=What's New picture::{line}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
