#!/usr/bin/env python3
"""Diff the App Review gate's reviewer-path screens against feat-cmux-next.

The gate's reviewer-path legs export every screenshot the walk attaches
(`xcresulttool export attachments`) into screens/<family>/ and upload them in
ios-gate-stills-<lane>-<family> (runs before that kept them in
review-gate-path-<lane>-<family>, which the report's verdict downloads). This script pairs this run's stills with the
same family's stills from the newest feat-cmux-next push run, by attachment
name, and writes one markdown section: changed, new and removed screens, each
with the pull request's `Visual-change: <screen or *>: <why>` justification or
"unjustified". It warns and never fails: a missing baseline, a push run, a
download error or an image it cannot read is reported and exits 0.

    ios_gate_screen_diff.py --head-root in --family iphone --family ipad --family duo \
        --fetch-baseline --repo manaflow-ai/cmux --lane appstore --out screens.md

Tests pass --baseline-root instead of --fetch-baseline (tests/test_ios_gate_screen_diff.py).
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import os
import re
import struct
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile
import zlib
from dataclasses import dataclass
from pathlib import Path

# The workflow runs this script with -I, which leaves its own directory off sys.path.
sys.path.insert(0, str(Path(__file__).resolve().parent))
import deadline_http  # noqa: E402

# A pixel differs when some channel moves by more than this (of 255): the
# simulator's text antialiasing moves edge pixels by a few levels between two
# walks of the same build. A screen is "changed" when more than CHANGED_RATIO
# of its pixels differ. Measured on cmux#44149's first gate run, a change with
# no app code against push run 43795095024: 216 screens matched, the largest
# unchanged moved 0.18%, and seven others moved 0.25-0.51% (the status bar and
# a Chief or Workspaces list) with nothing changed. The walk now freezes the
# status bar (ios-review-gate.yml), and 1% stays above that noise while a moved
# control, a changed label or a new row is far over it.
CHANNEL_TOLERANCE = 16
CHANGED_RATIO = 0.01

WORKFLOW_FILE = "ios-review-gate.yml"
BASE_BRANCH = "feat-cmux-next"
MENTION = "@azooz2003-bit"
# Runs read when looking for a baseline: artifacts keep 3 days.
RUNS_TO_SCAN = 15
# Pixel comparison stops this many seconds in; the rest compare by bytes. A pure
# Python decode of a 1179x2556 still takes about 1.2 s (no Pillow on the runner).
TIME_BUDGET_S = 330
# Every family's artifact download together ends by this (the iPad zip is over 1 GB); the
# workflow's timeout is 420 s.
DOWNLOAD_BUDGET_S = 180
# Listing the runs and their artifacts, together.
LISTING_BUDGET_S = 90

# xcresulttool adds `_<index>_<UUID>` before what it takes for the name's extension, so
# `walk-x-DEAD-setup.teams.personal` exports as `walk-x-DEAD-setup.teams_0_<UUID>.personal`.
UUID_PART = re.compile(r"_\d+_[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}")
IMAGE_SUFFIXES = {".png", ".jpg", ".jpeg", ".heic"}
VISUAL_CHANGE = re.compile(r"^\s*Visual-change:\s*(?P<id>[^:]+?)\s*:\s*(?P<why>.+?)\s*$", re.MULTILINE)


# --- PNG -------------------------------------------------------------------

class ImageError(Exception):
    pass


@dataclass
class Png:
    width: int
    height: int
    channels: int  # samples per pixel after expanding a palette
    bpp: int  # bytes per pixel in the filtered stream
    filtered: list[bytes]  # one filter byte + filtered scanline per row
    palette: bytes | None


_CHANNELS = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}


def read_png(data: bytes) -> Png:
    """Parse an 8-bit, non-interlaced PNG into its filtered rows (decoded lazily)."""
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ImageError("not a PNG")
    pos = 8
    ihdr = None
    palette = None
    idat = []
    while pos + 8 <= len(data):
        (length,) = struct.unpack(">I", data[pos:pos + 4])
        kind = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + length]
        pos += 12 + length
        if kind == b"IHDR":
            ihdr = struct.unpack(">IIBBBBB", body)
        elif kind == b"PLTE":
            palette = body
        elif kind == b"IDAT":
            idat.append(body)
        elif kind == b"IEND":
            break
    if ihdr is None:
        raise ImageError("no IHDR")
    width, height, depth, color, _, _, interlace = ihdr
    if depth != 8 or interlace != 0 or color not in _CHANNELS:
        raise ImageError(f"unsupported PNG (depth {depth}, color type {color}, interlace {interlace})")
    bpp = _CHANNELS[color]
    stride = width * bpp
    try:
        stream = zlib.decompress(b"".join(idat))
    except zlib.error as error:
        raise ImageError(f"bad image data: {error}") from error
    if len(stream) < (stride + 1) * height:
        raise ImageError("truncated image data")
    rows = [stream[y * (stride + 1):(y + 1) * (stride + 1)] for y in range(height)]
    channels = 3 if color == 3 else bpp
    return Png(width, height, channels, bpp, rows, palette if color == 3 else None)


def _unfilter(row: bytes, prev: bytes, bpp: int) -> bytes:
    kind, line = row[0], row[1:]
    n = len(line)
    if kind == 0:
        return bytes(line)
    if kind == 2:  # Up
        return _add_bytes(line, prev)
    if kind == 1:  # Sub: a prefix sum per channel, bpp bytes apart
        out = bytearray(line)
        for i in range(bpp, n):
            out[i] = (out[i] + out[i - bpp]) & 0xFF
        return bytes(out)
    out = bytearray(n)
    if kind == 3:  # Average
        for i in range(n):
            left = out[i - bpp] if i >= bpp else 0
            out[i] = (line[i] + ((left + prev[i]) >> 1)) & 0xFF
        return bytes(out)
    if kind == 4:  # Paeth
        for i in range(n):
            if i >= bpp:
                a = out[i - bpp]
                c = prev[i - bpp]
            else:
                a = c = 0
            b = prev[i]
            p = a + b - c
            pa = abs(p - a)
            pb = abs(p - b)
            pc = abs(p - c)
            if pa <= pb and pa <= pc:
                pred = a
            elif pb <= pc:
                pred = b
            else:
                pred = c
            out[i] = (line[i] + pred) & 0xFF
        return bytes(out)
    raise ImageError(f"bad filter type {kind}")


def _add_bytes(a: bytes, b: bytes) -> bytes:
    """Byte-wise (a + b) mod 256, done on big ints so it runs at C speed."""
    n = len(a)
    if n == 0:
        return b""
    x = int.from_bytes(a, "big")
    y = int.from_bytes(b, "big")
    high = int.from_bytes(b"\x80" * n, "big")
    low = high ^ int.from_bytes(b"\xff" * n, "big")
    total = ((x & low) + (y & low)) ^ ((x ^ y) & high)
    return total.to_bytes(n, "big")


def _rows(png: Png, other: Png | None = None, other_rows: list[bytes] | None = None) -> list[bytes]:
    """Decode every row. While this image's rows so far equal `other`'s, a row whose filtered
    bytes also match is the same row, so it is taken from `other_rows` instead of decoded again:
    two stills of one screen decode about as fast as one."""
    prev = bytes(png.width * png.bpp)
    shared = other is not None and other_rows is not None
    out: list[bytes] = []
    for y, row in enumerate(png.filtered):
        if shared and other.filtered[y] == row:  # type: ignore[union-attr]
            raw = other_rows[y]  # type: ignore[index]
        else:
            raw = _unfilter(row, prev, png.bpp)
            shared = other_rows is not None and other_rows[y] == raw
        out.append(raw)
        prev = raw
    return out


def _rgba(raw: bytes, png: Png) -> bytes:
    """Expand a decoded row to RGBA."""
    if png.bpp == 4 and png.palette is None:
        return raw
    out = bytearray()
    if png.palette is not None:
        pal = png.palette
        for index in raw:
            out += pal[index * 3:index * 3 + 3] + b"\xff"
    elif png.bpp == 3:
        for i in range(0, len(raw), 3):
            out += raw[i:i + 3] + b"\xff"
    elif png.bpp == 2:
        for i in range(0, len(raw), 2):
            out += bytes((raw[i], raw[i], raw[i], raw[i + 1]))
    else:
        for v in raw:
            out += bytes((v, v, v, 255))
    return bytes(out)


@dataclass
class Diff:
    ratio: float  # differing pixels over pixels, 0..1
    box: tuple[int, int, int, int] | None  # x, y, w, h of the differing pixels
    note: str = ""


def diff_images(base_bytes: bytes, head_bytes: bytes, tolerance: int = CHANNEL_TOLERANCE) -> Diff:
    """Pixel difference of two stills; a size change counts as every pixel changed."""
    if base_bytes == head_bytes:
        return Diff(0.0, None)
    try:
        base = read_png(base_bytes)
        head = read_png(head_bytes)
        if (base.width, base.height) != (head.width, head.height):
            return Diff(1.0, None, f"size {base.width}x{base.height} -> {head.width}x{head.height}")
        base_rows = _rows(base)
        same_format = (base.bpp, base.palette) == (head.bpp, head.palette)
        head_rows = _rows(head, base, base_rows) if same_format else _rows(head)
    except (ImageError, struct.error, ValueError) as error:
        return Diff(1.0, None, f"not compared pixel by pixel ({error}); the files differ")
    differing = 0
    min_x, min_y, max_x, max_y = head.width, head.height, -1, -1
    for y in range(head.height):
        b_raw, h_raw = base_rows[y], head_rows[y]
        if b_raw == h_raw and base.palette == head.palette and base.bpp == head.bpp:
            continue
        b = _rgba(b_raw, base)
        h = _rgba(h_raw, head)
        if b == h:
            continue
        row_hits = 0
        for x in range(head.width):
            i = x * 4
            if b[i:i + 4] == h[i:i + 4]:
                continue
            if (abs(b[i] - h[i]) > tolerance or abs(b[i + 1] - h[i + 1]) > tolerance
                    or abs(b[i + 2] - h[i + 2]) > tolerance or abs(b[i + 3] - h[i + 3]) > tolerance):
                row_hits += 1
                if x < min_x:
                    min_x = x
                if x > max_x:
                    max_x = x
        if row_hits:
            differing += row_hits
            min_y = min(min_y, y)
            max_y = y
    pixels = head.width * head.height
    box = (min_x, min_y, max_x - min_x + 1, max_y - min_y + 1) if differing else None
    return Diff(differing / pixels if pixels else 0.0, box)


# --- Screens ---------------------------------------------------------------

def screen_name(human_name: str) -> str:
    """`gate-iphone-home-01_0_<UUID>.png` -> `gate-iphone-home-01`, and
    `walk-x-DEAD-setup.teams_0_<UUID>.personal` -> `walk-x-DEAD-setup.teams.personal`."""
    stem = human_name
    suffix = Path(human_name).suffix
    if suffix.lower() in IMAGE_SUFFIXES or suffix.lower() in {".txt", ".json"}:
        stem = human_name[: -len(suffix)]
    return UUID_PART.sub("", stem, count=1)


def load_screens(directory: Path | None) -> dict[str, Path]:
    """Name -> still for one family's exported attachments (images only)."""
    if directory is None or not directory.is_dir():
        return {}
    found: list[tuple[float, str, Path]] = []
    manifest = directory / "manifest.json"
    seen_files: set[str] = set()
    if manifest.is_file():
        try:
            tests = json.loads(manifest.read_text())
        except (OSError, ValueError):
            tests = []
        for test in tests if isinstance(tests, list) else []:
            for item in (test.get("attachments") or []) if isinstance(test, dict) else []:
                exported = str(item.get("exportedFileName") or "")
                path = directory / Path(exported).name
                if not exported or Path(exported).suffix.lower() not in IMAGE_SUFFIXES or not path.is_file():
                    continue
                human = str(item.get("suggestedHumanReadableName") or exported)
                found.append((float(item.get("timestamp") or 0), screen_name(human), path))
                seen_files.add(path.name)
    for path in sorted(directory.iterdir()):
        if path.name in seen_files or path.suffix.lower() not in IMAGE_SUFFIXES or not path.is_file():
            continue
        found.append((float("inf"), screen_name(path.name), path))
    screens: dict[str, Path] = {}
    for _, name, path in sorted(found, key=lambda t: (t[0], t[1])):
        key, n = name, 1
        while key in screens:
            n += 1
            key = f"{name}#{n}"
        screens[key] = path
    return screens


def find_family_dir(root: Path | None, family: str) -> Path | None:
    """screens/<family> wherever download-artifact put it under root."""
    if root is None or not root.is_dir():
        return None
    direct = root / "screens" / family
    if direct.is_dir():
        return direct
    for candidate in sorted(root.rglob(family)):
        if candidate.is_dir() and candidate.parent.name == "screens":
            return candidate
    return None


def justifications(body: str) -> list[tuple[str, str]]:
    """The body's `Visual-change:` lines, outside fenced code (an example in a fence justifies nothing)."""
    kept: list[str] = []
    fence = ""
    for line in (body or "").splitlines():
        marker = line.lstrip()[:3]
        if marker in ("```", "~~~"):
            fence = "" if fence == marker else (fence or marker)
            continue
        if not fence:
            kept.append(line)
    text = "\n".join(kept)
    return [(m.group("id").strip().strip("`"), m.group("why").strip()) for m in VISUAL_CHANGE.finditer(text)]


def justify(family: str, name: str, lines: list[tuple[str, str]]) -> str | None:
    for pattern, why in lines:
        if pattern == "*" or fnmatch.fnmatchcase(name, pattern) or fnmatch.fnmatchcase(f"{family}/{name}", pattern):
            return why
    return None


@dataclass
class Row:
    family: str
    name: str
    kind: str  # changed, new, removed
    ratio: float | None
    box: tuple[int, int, int, int] | None
    note: str
    why: str | None


def compare_family(family: str, head_dir: Path | None, base_dir: Path | None,
                   lines: list[tuple[str, str]], deadline: float = float("inf")) -> tuple[list[Row], int, float]:
    """Rows for the screens that differ, how many matched unchanged, and the largest unchanged ratio."""
    head = load_screens(head_dir)
    base = load_screens(base_dir)
    rows: list[Row] = []
    unchanged = 0
    largest_same = 0.0
    for name in sorted(set(head) | set(base)):
        if name not in base:
            rows.append(Row(family, name, "new", None, None, "", justify(family, name, lines)))
            continue
        if name not in head:
            rows.append(Row(family, name, "removed", None, None, "", justify(family, name, lines)))
            continue
        base_bytes, head_bytes = base[name].read_bytes(), head[name].read_bytes()
        if time.monotonic() > deadline and base_bytes != head_bytes:
            # Past the time budget a pair is compared by bytes only: the report job has 10 minutes.
            rows.append(Row(family, name, "changed", None, None, "files differ; not measured (time budget)",
                            justify(family, name, lines)))
            continue
        result = diff_images(base_bytes, head_bytes)
        if result.ratio > CHANGED_RATIO:
            rows.append(Row(family, name, "changed", result.ratio, result.box, result.note,
                            justify(family, name, lines)))
        else:
            unchanged += 1
            largest_same = max(largest_same, result.ratio)
    return rows, unchanged, largest_same


# --- Baseline download -----------------------------------------------------

@dataclass
class Baseline:
    family: str
    directory: Path | None
    run_id: int | None = None
    run_url: str = ""
    sha: str = ""
    conclusion: str = ""
    problem: str = ""


def _request(url: str, token: str) -> urllib.request.Request:
    request = urllib.request.Request(url, headers={
        "Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "cmux-ios-gate-screen-diff"})
    # Unredirected: the artifact zip redirects to blob storage, which refuses a GitHub token.
    request.add_unredirected_header("Authorization", f"Bearer {token}")
    return request


API_RETRIES = 2
API_RETRY_CAP_S = 20.0


def _refusal(error: urllib.error.HTTPError) -> str:
    """GitHub's own words for a refused call: a 403 is a rate limit, a missing scope or a blocked token."""
    try:
        message = json.loads(error.read().decode("utf-8", "replace")).get("message") or ""
    except Exception:  # noqa: BLE001 - the body is only a hint
        message = ""
    return f"HTTP Error {error.code}: {error.reason}" + (f" ({message[:160]})" if message else "")


def _retry_wait(error: urllib.error.HTTPError) -> float | None:
    """Seconds to wait before one more try of a rate-limited or flaky listing, or None when a retry cannot help."""
    headers = error.headers or {}
    if error.code in (403, 429):
        retry_after = headers.get("retry-after")
        if retry_after and retry_after.isdigit():
            return min(float(retry_after), API_RETRY_CAP_S)
        if headers.get("x-ratelimit-remaining") == "0" and (headers.get("x-ratelimit-reset") or "").isdigit():
            return min(max(float(headers["x-ratelimit-reset"]) - time.time(), 1.0), API_RETRY_CAP_S)
        return 5.0  # a secondary limit often names no wait; a missing scope costs two short retries
    return 2.0 if error.code >= 500 else None


def _api(url: str, token: str, deadline: "deadline_http.Deadline") -> bytes:
    """A JSON listing. Every call ends by DEADLINE as a whole (deadline_http), shared by all listings.

    A refusal is retried up to API_RETRIES times when it is a rate limit or a server error, and its
    reason is kept: the first live runs lost the baseline to a bare "HTTP Error 403: Forbidden" in 8 of 28 runs."""
    for attempt in range(API_RETRIES + 1):
        try:
            _, body, _ = deadline_http.request(_request(url, token), deadline=deadline, max_bytes=64 << 20,
                                               raise_errors=True)
            return body
        except urllib.error.HTTPError as error:
            wait = _retry_wait(error)
            reason = _refusal(error)
            if wait is None or attempt == API_RETRIES:
                raise RuntimeError(reason) from error
            deadline.left(f"retrying after {reason}")
            time.sleep(wait)
    raise AssertionError("unreachable")


def _download(url: str, token: str, deadline: "deadline_http.Deadline", path: Path) -> Path:
    """An artifact zip, streamed to PATH: the iPad leg's holds the agent pass too, over 1 GB."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with deadline_http.stream(_request(url, token), deadline=deadline, stall=60, raise_errors=True) as answer, \
            path.open("wb") as out:
        while True:
            chunk = answer.read(1 << 20)
            if not chunk:
                break
            out.write(chunk)
    return path


def _extract_family(archive_path: Path, family: str, dest: Path) -> Path | None:
    """Only screens/<family>/<file> members, by base name: nothing escapes dest."""
    out = dest / "screens" / family
    wrote = False
    with zipfile.ZipFile(archive_path) as archive:
        for member in archive.infolist():
            parts = Path(member.filename).parts
            if member.is_dir() or len(parts) < 3 or parts[-3] != "screens" or parts[-2] != family:
                continue
            name = Path(parts[-1]).name
            if not name or name.startswith("."):
                continue
            out.mkdir(parents=True, exist_ok=True)
            (out / name).write_bytes(archive.read(member))
            wrote = True
    return out if wrote else None


def stills_artifact_names(lane: str, family: str) -> list[str]:
    """A run's stills artifact, newest name first: ios-gate-stills-* since the stills
    left review-gate-path-*, which runs before that still hold."""
    return [f"ios-gate-stills-{lane}-{family}", f"review-gate-path-{lane}-{family}"]


def fetch_baselines(repo: str, lane: str, families: list[str], dest: Path, token: str,
                    exclude_run: str, api: str = "https://api.github.com") -> dict[str, Baseline]:
    """Each family's stills from the newest feat-cmux-next push run of this workflow that kept them.

    A run that concluded success wins; when none of the newest RUNS_TO_SCAN did and kept the
    artifact, the newest completed run that kept it is used and named as such.
    """
    result = {family: Baseline(family, None) for family in families}
    listings = deadline_http.Deadline(LISTING_BUDGET_S)
    query = urllib.parse.urlencode({"branch": BASE_BRANCH, "event": "push", "status": "completed",
                                    "per_page": RUNS_TO_SCAN})
    try:
        runs = json.loads(_api(f"{api}/repos/{repo}/actions/workflows/{WORKFLOW_FILE}/runs?{query}", token, listings))
    except Exception as error:  # noqa: BLE001 - warn only
        for baseline in result.values():
            baseline.problem = f"listing {BASE_BRANCH} push runs failed: {error}"
        return result
    candidates: dict[str, list[tuple[dict, dict]]] = {family: [] for family in families}
    for run in runs.get("workflow_runs") or []:
        if str(run.get("id")) == str(exclude_run):
            continue
        try:
            url = f"{api}/repos/{repo}/actions/runs/{run['id']}/artifacts?per_page=100"
            listing = json.loads(_api(url, token, listings))
        except Exception:  # noqa: BLE001 - skip that run
            continue
        names = {a.get("name"): a for a in listing.get("artifacts") or [] if not a.get("expired")}
        for family in families:
            artifact = next((names[n] for n in stills_artifact_names(lane, family) if n in names), None)
            if artifact:
                candidates[family].append((run, artifact))
        if all(any(r.get("conclusion") == "success" for r, _ in candidates[f]) for f in families):
            break
    downloads = deadline_http.Deadline(DOWNLOAD_BUDGET_S)
    for family in families:
        options = candidates[family]
        if not options:
            result[family].problem = (f"no {BASE_BRANCH} push run of {WORKFLOW_FILE} among the newest "
                                      f"{RUNS_TO_SCAN} kept {stills_artifact_names(lane, family)[0]} (artifacts keep 3 days)")
            continue
        run, artifact = next(((r, a) for r, a in options if r.get("conclusion") == "success"), options[0])
        baseline = result[family]
        baseline.run_id = run.get("id")
        baseline.run_url = run.get("html_url") or ""
        baseline.sha = (run.get("head_sha") or "")[:8]
        baseline.conclusion = run.get("conclusion") or ""
        try:
            archive = _download(f"{api}/repos/{repo}/actions/artifacts/{artifact['id']}/zip", token, downloads,
                                dest / f"{family}.zip")
            baseline.directory = _extract_family(archive, family, dest / family)
            archive.unlink()
            if baseline.directory is None:
                baseline.problem = f"run {baseline.run_id}'s artifact has no screens/{family}"
        except Exception as error:  # noqa: BLE001 - warn only
            baseline.problem = f"downloading run {baseline.run_id}'s artifact failed: {error}"
    return result


# --- Report ----------------------------------------------------------------

def _pct(ratio: float | None) -> str:
    return "" if ratio is None else f"{ratio * 100:.2f}%"


def render(rows: list[Row], unchanged: dict[str, int], largest_same: float, baselines: dict[str, Baseline],
           head_dirs: dict[str, Path | None], pull_request: bool) -> str:
    out = ["", "### iOS screens vs feat-cmux-next", ""]
    for family, baseline in baselines.items():
        if head_dirs.get(family) is None:
            out.append(f"- {family}: this run exported no screens (the leg was skipped or failed)")
        elif baseline.directory is None:
            out.append(f"- {family}: no baseline, {baseline.problem or 'none given'}; not compared")
        elif baseline.run_id:
            state = "" if baseline.conclusion == "success" else f", a run that concluded {baseline.conclusion}"
            out.append(f"- {family}: baseline push run [{baseline.run_id}]({baseline.run_url}) at "
                       f"`{baseline.sha}`{state}; {unchanged.get(family, 0)} screens unchanged")
        else:
            out.append(f"- {family}: baseline {baseline.directory.name}; {unchanged.get(family, 0)} screens unchanged")
    out.append("")
    out.append(f"A screen is changed when over {CHANGED_RATIO * 100:.1f}% of its pixels move by more than "
               f"{CHANNEL_TOLERANCE}/255 in a channel; the largest unchanged screen moved {_pct(largest_same)}.")
    out.append("")
    unjustified = [row for row in rows if row.why is None]
    # A family is compared exactly when main measured it, which records its unchanged count.
    skipped = [family for family in baselines if family not in unchanged]
    if not rows and not unchanged:
        out.append("Nothing was compared (no baseline for any family).")
    elif not rows and skipped:
        out.append(f"No compared screen differs from feat-cmux-next (not compared: {', '.join(skipped)}).")
    elif not rows:
        out.append("No screen differs from feat-cmux-next.")
    elif pull_request and unjustified:
        out.append(f"**{len(unjustified)} iOS screens differ from feat-cmux-next with no Visual-change line: "
                   f"is each wanted? cc {MENTION}**")
        out.append("")
        out.append("Justify one with a pull request body line `Visual-change: <screen or *>: <why>`.")
    elif pull_request:
        out.append(f"{len(rows)} iOS screens differ from feat-cmux-next, each with a Visual-change line.")
    else:
        out.append(f"{len(rows)} iOS screens differ from the previous feat-cmux-next push run.")
    if rows:
        out += ["", "| Device | Screen | Change | Pixels | Region | Justification |", "|---|---|---|---|---|---|"]
        for row in sorted(rows, key=lambda r: (r.why is not None, r.family, r.kind, r.name)):
            region = f"{row.box[2]}x{row.box[3]} at {row.box[0]},{row.box[1]}" if row.box else row.note
            if not pull_request:
                verdict = "n/a (push run)"
            elif row.why is None:
                verdict = "unjustified"
            else:
                verdict = f"justified: {row.why}".replace("|", "\\|")
            out.append(f"| {row.family} | `{row.name}` | {row.kind} | {_pct(row.ratio)} | {region} | {verdict} |")
    out.append("")
    return "\n".join(out)


def pr_body(event_path: str | None) -> str:
    if not event_path:
        return ""
    try:
        event = json.loads(Path(event_path).read_text())
    except (OSError, ValueError):
        return ""
    return str(((event.get("pull_request") or {}).get("body")) or "")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--head-root", type=Path, required=True, help="this run's downloaded ios-gate-stills-* artifacts")
    parser.add_argument("--family", action="append", required=True)
    parser.add_argument("--baseline-root", type=Path, help="screens/<family> of the baseline, already on disk")
    parser.add_argument("--fetch-baseline", action="store_true", help="download the newest feat-cmux-next push run's")
    parser.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", ""))
    parser.add_argument("--lane", default="appstore")
    parser.add_argument("--work", type=Path, default=Path("screen-baseline"))
    parser.add_argument("--event", default=os.environ.get("GITHUB_EVENT_NAME", ""))
    parser.add_argument("--event-path", default=os.environ.get("GITHUB_EVENT_PATH"))
    parser.add_argument("--pr-body", help="the pull request body (default: from --event-path)")
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args(argv)

    started = time.monotonic()
    pull_request = args.event == "pull_request"
    body = args.pr_body if args.pr_body is not None else pr_body(args.event_path)
    lines = justifications(body) if pull_request else []
    try:
        head_dirs = {family: find_family_dir(args.head_root, family) for family in args.family}
        if args.fetch_baseline:
            token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN") or ""
            if not token or not args.repo:
                baselines = {f: Baseline(f, None, problem="no GitHub token or repository to read it with")
                             for f in args.family}
            else:
                wanted = [f for f in args.family if head_dirs[f] is not None]
                fetched = fetch_baselines(args.repo, args.lane, wanted, args.work, token,
                                          os.environ.get("GITHUB_RUN_ID", "")) if wanted else {}
                baselines = {f: fetched.get(f, Baseline(f, None, problem="nothing to compare")) for f in args.family}
        else:
            baselines = {}
            for family in args.family:
                directory = find_family_dir(args.baseline_root, family)
                baselines[family] = Baseline(family, directory, problem="" if directory else
                                             f"the baseline has no screens/{family}")
        rows: list[Row] = []
        unchanged: dict[str, int] = {}
        largest_same = 0.0
        for family in args.family:
            if head_dirs[family] is None or baselines[family].directory is None:
                continue
            family_rows, same, largest = compare_family(family, head_dirs[family], baselines[family].directory, lines,
                                                        started + TIME_BUDGET_S)
            rows += family_rows
            unchanged[family] = same
            largest_same = max(largest_same, largest)
        text = render(rows, unchanged, largest_same, baselines, head_dirs, pull_request)
        text += f"\n<sub>Compared in {time.monotonic() - started:.0f} s by scripts/ci/ios_gate_screen_diff.py.</sub>\n"
    except Exception as error:  # noqa: BLE001 - warn only, never fail the gate
        text = f"\n### iOS screens vs feat-cmux-next\n\nThe screen diff could not run: {error!r}\n"
    args.out.write_text(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
