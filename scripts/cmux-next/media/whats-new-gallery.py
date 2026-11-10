#!/usr/bin/env python3
"""Render each What's New highlight's gallery state, and its before, and put them on pr-media.

    whats-new-gallery.py plan [--days N] [--all] --out PLAN.json     the states to render
    whats-new-gallery.py manifest --plan PLAN.json --cases ALL.json [--notes NOTES.json] [--parent SHA] --out MANIFEST.json
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
- `publish` crops each picture to what it shows (the stage's empty background off, a small margin
  kept; an after and its before to the same box, so they line up), then reads it through
  scripts/pr-media.py's privacy check (a refusal uploads
  nothing) and puts it at release-notes.py's gallery_url, whats-new/ID/gallery-KEY-ROLE.png.

The next nightly's notes find the pictures there (release-notes.py add_gallery_media). Only the
states a highlight names are published, never every state a pull request touches (#21400 took the
automatic per-PR gallery publishing out). A highlight with a clip shows the clip instead.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import sys
import time
import urllib.error
import urllib.request
import zlib

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
            row = {"id": highlight_id, "role": role, "url": url, "path": url.split(f"/{BRANCH}/", 1)[1],
                   "born": int(born[0])}
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


# A variant whose note opens "Selected" is the look its gallery file picked, of the ones it draws.
SELECTED_NOTE = re.compile(r"Selected\b")


def _note(notes: dict, entry: str, variant: str) -> str:
    """A variant's own note, from the entries (webviews/scripts/gallery/notes.ts), never read off its file's text.
    The notes are HEAD's even for an older highlight's commit: its after and its marked before render at HEAD,
    so HEAD's notes describe the variants that are drawn."""
    return (notes.get(entry) or {}).get(variant) or ""


def changed_lines(commit: str, path: str) -> set[int]:
    """The line numbers, in the file at `commit`, that the commit added or changed."""
    run = subprocess.run(["git", "-C", str(ROOT), "diff", "-U0", f"{commit}^", commit, "--", path],
                         capture_output=True, text=True)
    lines = set()
    for start, count in re.findall(r"^@@ -\S+ \+(\d+)(?:,(\d+))? @@", run.stdout, re.M):
        lines.update(range(int(start), int(start) + int(count or 1)))
    return lines


def infer(row: dict, cases: list[dict], text_at=show, changed=changed_lines, notes: dict | None = None) -> str | None:
    """The state of the gallery files row["commit"] changed: the first variant the commit added (its key
    is in the file at the commit and not the commit before; the one its note calls "Selected" first, as a new file's
    closed row showed nothing of what agent-file-result-cards opened), else the variant whose lines it changed most,
    else the first one; of the first entry with such a variant. A variant named for the old look is the last choice."""
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
            return f"{entry}/{min(added, key=lambda v: not SELECTED_NOTE.match(_note(notes or {}, entry, v)))}"
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


# A variant whose note opens with "Before" is the look its entry's change replaced ("Before: one flat list").
BEFORE_NOTE = re.compile(r"Before\s*[:(]")


def marked_before(state: str, cases: list[dict], notes: dict) -> str | None:
    """The variant of `state`'s entry that its gallery file marks as the old look (its note opens with
    "Before", else its name ends in one of OLD_LOOK's words), the one sharing the longest name prefix with
    `state`'s variant, which it must share at least its first word with (`notes-flat` for `notes-sections`,
    never another surface's old look); None when the entry marks none. It renders beside the after, at the
    same commit."""
    entry, _, after = state.partition("/")
    variants = list(dict.fromkeys(c["params"]["variant"] for c in _dark(cases)
                                  if c["params"].get("entry") == entry))
    family = after.split("-", 1)[0] + "-"
    marked = []
    for order, variant in enumerate(variants):
        if variant == after or variant.startswith(f"{after}-light") or not variant.startswith(family):
            continue
        noted = bool(BEFORE_NOTE.match(_note(notes, entry, variant)))
        if noted or OLD_LOOK.search(variant):
            shared = len(os.path.commonprefix([variant, after]))
            marked.append((not noted, -shared, order, variant))
    return f"{entry}/{min(marked)[3]}" if marked else None


def _source(state: str, cases: list[dict]) -> str | None:
    entry = state.partition("/")[0]
    return next((c["params"].get("source") for c in _dark(cases) if c["params"].get("entry") == entry), None)


def resolve(rows: list[dict], cases: list[dict], text_at=show, notes: dict | None = None) -> tuple[list[dict], list[str]]:
    """The rows with their inferred states filled in, and the highlights none could be picked for. A before
    with no `before:` line takes the old look its entry marks (``marked_before``), rendered now beside the
    after; only an entry that marks none renders the after's state at the commit before the highlight's, and only
    when its gallery file has that state there: a state its commit added has no look to render (a new file's
    cards, 2026-11-09), so it is named as missing instead of rendering nothing at a checkout there."""
    out, missing = [], []
    for row in rows:
        if not row.get("state"):
            state = infer(row, cases, text_at, notes=notes)
            if state is None:
                missing.append(f"{row['id']}: no gallery state in {', '.join(row['sources'])}")
                continue
            row = {**row, "state": state}
        if row["role"] == "before" and row.get("parent"):
            old = marked_before(row["state"], cases, notes or {})
            if old:
                row = {key: value for key, value in row.items() if key != "parent"} | {"state": old}
            elif (source := _source(row["state"], cases)) and not _key(row["state"].partition("/")[2]).search(
                    text_at(row["parent"], f"webviews/{source}") or ""):
                missing.append(f"{row['id']} before: {row['state']} is new in its commit, not in {source} at "
                               f"{row['parent'][:12]}; give its gallery file the old look, a variant whose note "
                               "opens \"Before:\"")
                continue
        row["entry"], _, row["variant"] = row["state"].partition("/")
        out.append(row)
    return out, missing


def manifest(rows: list[dict], cases: list[dict], parent: str | None = None) -> tuple[list[dict], list[str]]:
    """One case per row: the dark default theme's case of its entry and variant; and the rows with none.
    With `parent`, the befores rendered at that commit: the same state there, never another one (the entry's
    first variant there showed an unrelated picture as the before)."""
    out, missing = [], []
    for row in rows:
        if row.get("parent") != parent:
            continue
        dark = [c for c in _dark(cases) if c["params"].get("entry") == row["entry"]]
        hit = next((c for c in dark if c["params"].get("variant") == row["variant"]), None)
        if hit is None:
            missing.append(f"{row['id']}: no gallery state {row['state']}" + (f" at {parent}" if parent else ""))
            continue
        out.append({**hit, "id": case_id(row)})
    return out, missing


# The component frame renders the entry on a pane-wide stage, so most of a picture is the stage's
# empty background. `publish` keeps what differs from it, plus MARGIN device pixels.
MARGIN = 32
TOLERANCE = 6
PNG = b"\x89PNG\r\n\x1a\n"


def png_read(data: bytes) -> tuple[int, int, int, list[bytearray]] | None:
    """(width, height, channels, rows) of an 8-bit, non-interlaced RGB or RGBA PNG (what the
    runner writes), else None."""
    if not data.startswith(PNG):
        return None
    pos, idat, head = 8, [], None
    while pos + 8 <= len(data):
        size, kind = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + size]
        if kind == b"IHDR":
            head = struct.unpack(">IIBBBBB", body)
        elif kind == b"IDAT":
            idat.append(body)
        pos += 12 + size
    if head is None or head[2] != 8 or head[3] not in (2, 6) or head[6] != 0:
        return None
    width, height, channels = head[0], head[1], 3 if head[3] == 2 else 4
    raw, stride, rows, prior = zlib.decompress(b"".join(idat)), width * channels, [], bytearray(width * channels)
    for y in range(height):
        kind, line = raw[y * (stride + 1)], bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for i in range(stride):
            left = line[i - channels] if i >= channels else 0
            up = prior[i]
            if kind == 1:
                line[i] = (line[i] + left) & 255
            elif kind == 2:
                line[i] = (line[i] + up) & 255
            elif kind == 3:
                line[i] = (line[i] + ((left + up) >> 1)) & 255
            elif kind == 4:
                corner = prior[i - channels] if i >= channels else 0
                guess = left + up - corner
                pa, pb, pc = abs(guess - left), abs(guess - up), abs(guess - corner)
                line[i] = (line[i] + (left if pa <= pb and pa <= pc else up if pb <= pc else corner)) & 255
        rows.append(line)
        prior = line
    return width, height, channels, rows


def png_write(width: int, height: int, channels: int, rows: list[bytearray]) -> bytes:
    def chunk(kind: bytes, body: bytes) -> bytes:
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body))
    head = struct.pack(">IIBBBBB", width, height, 8, 2 if channels == 3 else 6, 0, 0, 0)
    raw = b"".join(b"\0" + bytes(row) for row in rows)
    return PNG + chunk(b"IHDR", head) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")


def content_box(width: int, height: int, channels: int, rows: list[bytearray]) -> tuple[int, int, int, int] | None:
    """(left, top, right, bottom) of what differs from the background, the commonest colour on
    the picture's edge; None for a picture with nothing on it."""
    def pixel(row, x):
        return tuple(row[x * channels:x * channels + 3])
    edge = [pixel(rows[0], x) for x in range(width)] + [pixel(rows[-1], x) for x in range(width)]
    edge += [pixel(row, 0) for row in rows] + [pixel(row, width - 1) for row in rows]
    background = max(set(edge), key=edge.count)
    left, top, right, bottom = width, height, -1, -1
    for y, row in enumerate(rows):
        hits = [x for x in range(width)
                if any(abs(row[x * channels + c] - background[c]) > TOLERANCE for c in range(3))]
        if hits:
            left, right = min(left, hits[0]), max(right, hits[-1])
            top, bottom = min(top, y), y
    return None if right < 0 else (left, top, right + 1, bottom + 1)


def crop_pictures(paths: list[Path], out: Path) -> list[Path]:
    """Each picture cropped to the union of their content boxes plus MARGIN, written under `out`;
    a picture that is not a plain PNG or the same size as the others is kept as it is."""
    read = {path: png_read(path.read_bytes()) for path in paths}
    sizes = {(png[0], png[1]) for png in read.values() if png}
    boxes = [content_box(*png) for png in read.values() if png]
    boxes = [box for box in boxes if box]
    if len(sizes) != 1 or not boxes or None in read.values():
        return paths
    width, height = sizes.pop()
    left = max(0, min(b[0] for b in boxes) - MARGIN)
    top = max(0, min(b[1] for b in boxes) - MARGIN)
    right = min(width, max(b[2] for b in boxes) + MARGIN)
    bottom = min(height, max(b[3] for b in boxes) + MARGIN)
    out.mkdir(parents=True, exist_ok=True)
    cropped = []
    for path, (_, _, channels, rows) in read.items():
        target = out / path.name
        target.write_bytes(png_write(right - left, bottom - top, channels,
                                     [row[left * channels:right * channels] for row in rows[top:bottom]]))
        cropped.append(target)
    return cropped


def publish(rows: list[dict], results: Path, exists=published) -> list[str]:
    pr_media = _load("pr_media_tool", ROOT / "scripts/pr-media.py")
    files = []
    problems = []
    for row in rows:
        local = results / f"{case_id(row)}-{ENGINE}.png"
        if not local.is_file() or not notes.pr_media_picture(local.read_bytes()):
            problems.append(f"{row['id']} {row['role']}: {row['state']} did not render")
            continue
        files.append((row, local))
    # An after and its before share one box, so the What's New pair lines up.
    by_highlight: dict[str, list[tuple[dict, Path]]] = {}
    for row, local in files:
        by_highlight.setdefault(row["id"], []).append((row, local))
    # A picture already up is never replaced: published notes pin its bytes' SHA-256, and the app drops
    # a picture whose bytes differ (ReleaseMediaStore), so a recropped copy would blank older nightlies.
    by_highlight = {key: kept for key, group in by_highlight.items()
                    if (kept := [pair for pair in group if not exists(pair[0]["url"])])}
    files = [pair for group in by_highlight.values()
             for pair in zip([row for row, _ in group],
                             crop_pictures([local for _, local in group], results / "cropped"))]
    if files:
        if pr_media.privacy_module().ocr_binary() is None:
            raise SystemExit("whats-new-gallery: publish reads every picture first, and no OCR is set up")
        # One check for all of them: a refusal names paths and kinds only, and uploads nothing.
        pr_media.check_privacy([(row["path"], local) for row, local in files], REPO)
        for row, local in files:
            # Create-only, checked again on the tip the commit builds on: a picture another run put there
            # since `exists` read it stays (its bytes may be pinned by signed notes already).
            try:
                pr_media.put_files(REPO, BRANCH, {row["path"]: local},
                                   f"What's New picture: {row['id']} ({row['role']}, {row['state']})",
                                   checked=True, expect={row["path"]: None})
            except pr_media.MediaConflict as error:  # any other failure stops the run, its pictures not up
                problems.append(f"{row['id']} {row['role']}: kept the copy already there ({error})")
                continue
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
    m.add_argument("--notes", type=Path, help="each variant's note (webviews/scripts/gallery/notes.ts)")
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
        # The newest highlights first: a commit whose before keeps failing never holds the newer ones back.
        newest = sorted((r for r in rows if r.get("parent")), key=lambda r: -r.get("born", 0))
        parents = list(dict.fromkeys(r["parent"] for r in newest))
        print(" ".join(parents[:args.limit]))
        return 0
    if args.cmd == "manifest":
        cases = json.loads(args.cases.read_text())
        missing = []
        if args.parent is None:
            notes = json.loads(args.notes.read_text()) if args.notes else {}
            rows, missing = resolve(rows, cases, notes=notes)
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
