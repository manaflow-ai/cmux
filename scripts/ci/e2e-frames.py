#!/usr/bin/env python3
"""Turn a UI/E2E test run into per-test storyboards you can look at.

    e2e-frames.py <run-id | run URL | path/to/x.xcresult> [--test SUBSTRING] [--out DIR]

Every XCUITest step already saves a screenshot into the run's xcresult, and
tests add named captures (`XCTAttachment`, e.g. `capture("account-menu")`).
That is a frame-by-frame recording of the run that needs no screen recorder,
so it works on the owned Macs that record no video and on runners whose screen
capture is broken. This script downloads the run's `test-results` artifact,
exports the attachments, and writes for each test:

    <out>/<Class>/<method>/frames/NNN-<label>.png   every image, in time order
    <out>/<Class>/<method>/sheet-N.png              3x4 contact sheets (ffmpeg)
    <out>/<Class>/<method>/steps.mp4                2 fps slideshow (ffmpeg)

and prints each test's result, failure messages, named captures, and the frame
nearest the first failure. Contact sheets are 1920 px wide, small enough for an
agent's image reader; open a single frame for detail.

Needs `gh` (for a run), Xcode's `xcrun xcresulttool`, and `sips`; ffmpeg is
optional and only adds the sheets and the slideshow.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = "manaflow-ai/cmux"
ARTIFACT = "test-results"
IMAGE_SUFFIXES = {".png", ".jpg", ".jpeg", ".heic"}
FRAME_WIDTH = 960
SHEET_COLUMNS, SHEET_ROWS = 3, 4
SHEET_TILE_WIDTH = 640


def run(cmd: list[str], **kwargs) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, check=True, text=True, capture_output=True, **kwargs)


def parse_run_id(value: str) -> str | None:
    if value.isdigit():
        return value
    match = re.search(r"/actions/runs/(\d+)", value)
    return match.group(1) if match else None


def download_xcresults(run_id: str, repo: str, into: Path) -> list[Path]:
    into.mkdir(parents=True, exist_ok=True)
    existing = sorted(into.rglob("*.xcresult"))
    if existing:
        return existing
    try:
        run(["gh", "run", "download", run_id, "--repo", repo, "-n", ARTIFACT, "-D", str(into)])
    except subprocess.CalledProcessError as error:
        sys.exit(
            f"could not download '{ARTIFACT}' from run {run_id}: {error.stderr.strip()}\n"
            "A run that failed before tests started uploads no results."
        )
    found = sorted(into.rglob("*.xcresult"))
    if not found:
        sys.exit(f"run {run_id}: artifact '{ARTIFACT}' has no .xcresult bundle")
    return found


def test_results(xcresult: Path) -> dict[str, dict]:
    """nodeIdentifier -> {result, failures[]} for every test case."""
    raw = run(["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", str(xcresult)]).stdout
    results: dict[str, dict] = {}

    def walk(node: dict) -> None:
        if node.get("nodeType") == "Test Case":
            failures = [
                child.get("name", "")
                for child in node.get("children", [])
                if child.get("nodeType") == "Failure Message"
            ]
            results[node.get("nodeIdentifier", node.get("name", "?"))] = {
                "result": node.get("result", "?"),
                "failures": failures,
            }
        for child in node.get("children", []):
            walk(child)

    for node in json.loads(raw).get("testNodes", []):
        walk(node)
    return results


def label_for(name: str) -> str:
    """A short file-name label: XCUITest's own shots become 'step', captures keep their name."""
    if name.startswith("Screenshot "):
        return "step"
    base = re.sub(r"_\d+_[0-9A-F-]{36}.*$", "", name)  # capture("x") -> x_0_<UUID>.png
    base = re.sub(r"[^A-Za-z0-9._-]+", "-", base).strip("-.")
    return base[:48] or "image"


def to_png(source: Path, destination: Path) -> None:
    run(["sips", "-s", "format", "png", "--resampleWidth", str(FRAME_WIDTH), str(source), "--out", str(destination)])


def build_sheets(frames: Path, test_dir: Path) -> list[Path]:
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg or not any(frames.iterdir()):
        return []
    # ffmpeg's image2 reader wants a contiguous numbered sequence.
    with tempfile.TemporaryDirectory() as tmp:
        for index, frame in enumerate(sorted(frames.glob("*.png")), start=1):
            os.symlink(frame.resolve(), Path(tmp) / f"{index:04d}.png")
        pattern = str(Path(tmp) / "%04d.png")
        tile_height = SHEET_TILE_WIDTH * 9 // 16
        # Fit inside the tile both ways: a taller-than-16:9 capture would
        # otherwise overflow the pad and ffmpeg would write nothing.
        scale = (f"scale={SHEET_TILE_WIDTH}:{tile_height}:force_original_aspect_ratio=decrease,"
                 f"pad={SHEET_TILE_WIDTH}:{tile_height}:-1:-1:color=0x202020")
        subprocess.run(
            [ffmpeg, "-loglevel", "error", "-y", "-framerate", "1", "-i", pattern,
             "-vf", f"{scale},tile={SHEET_COLUMNS}x{SHEET_ROWS}:padding=4:color=0x000000",
             "-fps_mode", "passthrough", str(test_dir / "sheet-%d.png")],
            check=False,
        )
        subprocess.run(
            [ffmpeg, "-loglevel", "error", "-y", "-framerate", "2", "-i", pattern,
             "-vf", "scale=1280:720:force_original_aspect_ratio=decrease,pad=1280:720:-1:-1:color=0x202020,format=yuv420p",
             str(test_dir / "steps.mp4")],
            check=False,
        )
    return sorted(test_dir.glob("sheet-*.png"), key=lambda p: int(re.sub(r"\D", "", p.stem) or 0))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("source", help="workflow run id, run URL, or a local .xcresult path")
    parser.add_argument("--test", help="only tests whose Class/method contains this substring")
    parser.add_argument("--out", type=Path, help="output directory (default: $TMPDIR/cmux-e2e-frames/<run>)")
    parser.add_argument("--repo", default=REPO)
    parser.add_argument("--json", action="store_true", help="print the summary as JSON")
    args = parser.parse_args()

    local = Path(args.source)
    if local.suffix == ".xcresult" and local.exists():
        xcresults = [local]
        tag = local.stem
    else:
        run_id = parse_run_id(args.source)
        if not run_id:
            parser.error("source must be a run id, a run URL, or an existing .xcresult")
        tag = run_id
        base = Path(tempfile.gettempdir()) / "cmux-e2e-frames" / run_id
        xcresults = download_xcresults(run_id, args.repo, base / "download")
    out = args.out or Path(tempfile.gettempdir()) / "cmux-e2e-frames" / tag

    summary = []
    for xcresult in xcresults:
        # Retried shards upload one bundle per attempt; keep them apart.
        root = out / xcresult.stem if len(xcresults) > 1 else out
        try:
            results = test_results(xcresult)
            exported = out / "attachments" / xcresult.stem
            if not (exported / "manifest.json").exists():
                exported.mkdir(parents=True, exist_ok=True)
                run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(xcresult), "--output-path", str(exported)])
        except subprocess.CalledProcessError as error:
            print(f"skipped {xcresult}: xcresulttool failed ({(error.stderr or '').strip()[:200]})", file=sys.stderr)
            continue
        manifest = json.loads((exported / "manifest.json").read_text())
        with_attachments = {entry.get("testIdentifier") for entry in manifest}
        for identifier, outcome in results.items():
            if identifier in with_attachments or (args.test and args.test not in identifier):
                continue
            # XCUITest drops step screenshots from passing tests; only
            # captures kept with `.keepAlways` survive.
            summary.append({
                "test": identifier, "result": outcome["result"], "failures": outcome["failures"],
                "frames": 0, "captures": [], "failure_frame": None, "sheets": [], "slideshow": None, "dir": None,
            })

        for entry in manifest:
            identifier = entry.get("testIdentifier", "unknown")
            if args.test and args.test not in identifier:
                continue
            class_name, _, method = identifier.partition("/")
            test_dir = root / class_name / (method.rstrip("()") or "test")
            frames = test_dir / "frames"
            if test_dir.exists():  # no sheets or slideshow left from an earlier extraction
                shutil.rmtree(test_dir)
            frames.mkdir(parents=True)

            images = sorted(
                (a for a in entry.get("attachments", [])
                 if Path(a.get("exportedFileName", "")).suffix.lower() in IMAGE_SUFFIXES),
                key=lambda a: a.get("timestamp", 0),
            )
            captures, failure_frame = [], None
            for index, attachment in enumerate(images, start=1):
                name = attachment.get("suggestedHumanReadableName", "")
                frame = frames / f"{index:03d}-{label_for(name)}.png"
                try:
                    to_png(exported / attachment["exportedFileName"], frame)
                except subprocess.CalledProcessError:
                    print(f"skipped unreadable image {attachment['exportedFileName']} ({identifier})", file=sys.stderr)
                    continue
                if not name.startswith("Screenshot "):
                    captures.append(str(frame))
                if attachment.get("isAssociatedWithFailure") and failure_frame is None:
                    failure_frame = str(frame)

            outcome = results.get(identifier, {"result": "?", "failures": []})
            summary.append({
                "test": identifier,
                "result": outcome["result"],
                "failures": outcome["failures"],
                "frames": len(images),
                "captures": captures,
                "failure_frame": failure_frame,
                "sheets": [str(p) for p in build_sheets(frames, test_dir)],
                "slideshow": str(test_dir / "steps.mp4") if (test_dir / "steps.mp4").exists() else None,
                "dir": str(test_dir),
            })

    if args.json:
        print(json.dumps(summary, indent=2))
        return 0
    if not summary:
        print(f"no test attachments matched in {out}")
        return 1
    for item in summary:
        location = item["dir"] or "no images: passing tests keep only captures attached with .keepAlways"
        print(f"{item['result']:>7}  {item['test']}  ({item['frames']} frames)  {location}")
        for failure in item["failures"]:
            # XCUITest appends the element tree; --json keeps the whole message.
            print(f"         failure: {failure.splitlines()[0] if failure else ''}")
        if item["failure_frame"]:
            print(f"         at failure: {item['failure_frame']}")
        for capture in item["captures"]:
            print(f"         capture: {capture}")
        for sheet in item["sheets"]:
            print(f"         sheet: {sheet}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
