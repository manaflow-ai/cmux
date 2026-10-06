#!/usr/bin/env python3
"""Turn a UI test run into one labelled frame per test action.

    e2e-frames.py <run id | run URL | x.xcresult | dir of .xcresult> [--test SUBSTRING] [--out DIR]

For each test it writes, under <out>/<Class>/<method>/:

    steps.md                  numbered actions ("Click ... MenuItem"), the failure, and each frame's file
    frames/NN-<action>.jpg    the screen right after that action
    sheet-N.jpg               3x4 contact sheets, each tile captioned with its action
    attachments/<name>        text a test attached (a dogfood tour's trees, socket replies, step log)
    index.html                 an interactive local-first UI mirror of the run
    mirror.json                the mirror's machine-readable manifest

A frame is the last screenshot XCUITest saved under a top-level action. On hosts
where XCTest keeps a screen recording of a failing test instead, the recording
is sampled once a second and each sample is captioned with the action running
at that moment. Named captures (XCTAttachment) become their own steps.

A run id or URL first downloads the run's `ui-frames` artifact, which UI runs
of test-e2e.yml build in CI; for older runs it falls back to the `test-results`
xcresult. A local extracted `ui-frames` directory is accepted too, so a copied
artifact can be reviewed without another dispatch or a native toolchain.
`--summary FILE` appends a Markdown report (CI passes `$GITHUB_STEP_SUMMARY`).
Needs `gh` for runs, and xcrun, sips and ffmpeg to build from xcresults.
"""

from __future__ import annotations

import argparse
import contextlib
import html
import json
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = "manaflow-ai/cmux"
FRAMES_ARTIFACT = "ui-frames"
RESULTS_ARTIFACT = "test-results"
IMAGE_SUFFIXES = {".png", ".jpg", ".jpeg", ".heic"}
VIDEO_SUFFIXES = {".mp4", ".mov"}
FRAME_WIDTH = 960
SHEET_COLUMNS, SHEET_ROWS = 3, 4
TILE_WIDTH, TILE_HEIGHT = 640, 360
FONT = "/System/Library/Fonts/SFNS.ttf"
# Bookkeeping XCUITest logs between actions; never a step of its own.
NOISE = re.compile(r"^(kXCTAttachment|Checking existence of|Waiting .* to exist|Get number of matches|Find the |"
                   r"Wait for .* to idle|Check for interrupting|Synthesize event|Set Up$|Tear Down$)")
AT_FAILURE = "Screen at failure"
# XCUITest attaches these to every synthesized event; they bury what a test kept.
XCUITEST_NOISE = ("Synthesized Event", "UI Snapshot", "Debug description", "App UI hierarchy")
# XCTest's own activity names, shortened to what a reader needs.
RENAME = [(re.compile(r"^Collecting debug information"), AT_FAILURE), (re.compile(r"^Start Test at "), "Start")]


def run(cmd: list[str], **kwargs) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, check=True, text=True, capture_output=True, **kwargs)


def parse_run_id(value: str) -> str | None:
    if value.isdigit():
        return value
    match = re.search(r"/actions/runs/(\d+)", value)
    return match.group(1) if match else None


def download(run_id: str, repo: str, name: str, into: Path) -> bool:
    """Download an artifact once; a marker, not a non-empty directory, says it arrived, since a
    local fallback build writes into the same place."""
    marker = into / f".downloaded-{name}"
    if marker.exists():
        return True
    into.mkdir(parents=True, exist_ok=True)
    done = subprocess.run(["gh", "run", "download", run_id, "--repo", repo, "-n", name, "-D", str(into)],
                          capture_output=True, text=True)
    if done.returncode != 0:
        return False
    marker.touch()
    return True


def slug(text: str, limit: int = 48) -> str:
    return re.sub(r"[^A-Za-z0-9]+", "-", text).strip("-").lower()[:limit] or "step"


def test_results(xcresult: Path) -> dict[str, dict]:
    """nodeIdentifier -> {result, failures[]} for every test case."""
    raw = run(["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", str(xcresult)]).stdout
    results: dict[str, dict] = {}

    def walk(node: dict) -> None:
        if node.get("nodeType") == "Test Case":
            results[node.get("nodeIdentifier", node.get("name", "?"))] = {
                "result": node.get("result", "?"),
                "failures": [c.get("name", "") for c in node.get("children", [])
                             if c.get("nodeType") == "Failure Message"],
            }
        for child in node.get("children", []):
            walk(child)

    for node in json.loads(raw).get("testNodes", []):
        walk(node)
    return results


def actions(xcresult: Path, identifier: str) -> list[dict]:
    """Top-level test actions: title, start time, and the attachments beneath each, in time order."""
    try:
        raw = run(["xcrun", "xcresulttool", "get", "test-results", "activities",
                   "--path", str(xcresult), "--test-id", identifier]).stdout
    except subprocess.CalledProcessError:
        return []

    def attachments(node: dict) -> list[tuple[float, str, str]]:
        found = [(a.get("timestamp") or 0, a.get("uuid", ""), a.get("name", "")) for a in node.get("attachments", [])]
        for child in node.get("childActivities", []):
            found += attachments(child)
        return found

    steps = []
    for test_run in json.loads(raw).get("testRuns", []):
        for node in test_run.get("activities", []):
            title = " ".join(node.get("title", "").split())  # one line, for steps.md and captions
            if NOISE.match(title):
                continue
            for pattern, short in RENAME:
                if pattern.match(title):
                    title = short
            steps.append({"title": title, "start": node.get("startTime") or 0,
                          "attachments": sorted(attachments(node))})
    return steps


def to_jpg(source: Path, destination: Path) -> None:
    # sips exits 0 on a missing or unreadable input and just writes nothing.
    run(["sips", "-s", "format", "jpeg", "-s", "formatOptions", "75", "--resampleWidth", str(FRAME_WIDTH),
         str(source), "--out", str(destination)])
    if not destination.exists():
        raise OSError(f"sips wrote nothing for {source.name}")


# Samples a recording with AVFoundation, for hosts without ffmpeg (the owned minis): every macOS
# runner has `xcrun swift` with Xcode. Arguments: movie, output directory, frame width.
AVFOUNDATION_SAMPLER = r"""
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
let args = CommandLine.arguments
let asset = AVURLAsset(url: URL(fileURLWithPath: args[1]))
let generator = AVAssetImageGenerator(asset: asset)
generator.appliesPreferredTrackTransform = true
generator.maximumSize = CGSize(width: Double(args[3])!, height: 10000)
generator.requestedTimeToleranceBefore = .zero
generator.requestedTimeToleranceAfter = .zero
let seconds = CMTimeGetSeconds(asset.duration)
var index = 1
var second = 0.5
while second < seconds {
    if let image = try? generator.copyCGImage(at: CMTime(seconds: second, preferredTimescale: 600), actualTime: nil) {
        let url = URL(fileURLWithPath: args[2]).appendingPathComponent(String(format: "%04d.jpg", index))
        if let out = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(out, image, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
            CGImageDestinationFinalize(out)
        }
    }
    index += 1
    second += 1
}
"""


def sample_recording(source: Path, into: Path) -> list[tuple[float, Path]]:
    """One frame a second from a recording, as (seconds into it, file)."""
    if shutil.which("ffmpeg"):
        subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", str(source), "-vf", f"fps=1,scale={FRAME_WIDTH}:-2",
                        "-q:v", "5", str(into / "%04d.jpg")], check=False)
    else:
        sampler = into / "sample.swift"
        sampler.write_text(AVFOUNDATION_SAMPLER)
        done = subprocess.run(["xcrun", "swift", str(sampler), str(source), str(into), str(FRAME_WIDTH)],
                              capture_output=True, text=True)
        if done.returncode:
            print(f"skipped recording {source.name}: no ffmpeg, and AVFoundation sampling failed "
                  f"({done.stderr.strip()[:200]})", file=sys.stderr)
    return [(int(path.stem) - 0.5, path) for path in sorted(into.glob("*.jpg"))]


def has_drawtext() -> bool:
    """Homebrew's current ffmpeg is built without freetype; sheets then go uncaptioned (tile N is step N)."""
    filters = subprocess.run(["ffmpeg", "-hide_banner", "-filters"], capture_output=True, text=True).stdout
    return " drawtext " in filters and Path(FONT).exists()


def build_sheets(steps: list[dict], test_dir: Path) -> list[Path]:
    """3x4 grids of the step frames, captioned when ffmpeg can draw text."""
    if not shutil.which("ffmpeg") or not steps:
        return []
    captions = has_drawtext()
    per_sheet = SHEET_COLUMNS * SHEET_ROWS
    sheets = []
    with tempfile.TemporaryDirectory() as tmp:
        tiles = []
        for step in steps:
            caption = Path(tmp) / f"{step['number']}.txt"
            caption.write_text(f"{step['number']}. {step['title'][:70]}")
            tile = Path(tmp) / f"{step['number']:04d}.jpg"
            draw = (f"scale={TILE_WIDTH}:{TILE_HEIGHT}:force_original_aspect_ratio=decrease,"
                    f"pad={TILE_WIDTH}:{TILE_HEIGHT}:-1:-1:color=0x202020,"
                    f"drawbox=x=0:y=ih-24:w=iw:h=24:color=black@0.75:t=fill")
            if captions:
                draw += f",drawtext=fontfile={FONT}:textfile={caption}:x=6:y=h-19:fontsize=13:fontcolor=white"
            subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", str(step["path"]), "-vf", draw,
                            "-q:v", "4", str(tile)], check=False)
            if tile.exists():
                tiles.append(tile)
        for first in range(0, len(tiles), per_sheet):
            listing = Path(tmp) / f"sheet{first}.txt"
            listing.write_text("".join(f"file '{t}'\n" for t in tiles[first:first + per_sheet]))
            sheet = test_dir / f"sheet-{first // per_sheet + 1}.jpg"
            subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-f", "concat", "-safe", "0", "-i", str(listing),
                            "-vf", f"tile={SHEET_COLUMNS}x{SHEET_ROWS}:padding=4:color=black", "-frames:v", "1",
                            "-q:v", "4", str(sheet)], check=False)
            if sheet.exists():
                sheets.append(sheet)
    return sheets


def extract_test(xcresult: Path, exported: Path, entry: dict, outcome: dict, test_dir: Path) -> dict:
    identifier = entry.get("testIdentifier", "unknown")
    if test_dir.exists():
        shutil.rmtree(test_dir)
    frames = test_dir / "frames"
    frames.mkdir(parents=True)
    files = {Path(a["exportedFileName"]).stem: a for a in entry.get("attachments", []) if a.get("exportedFileName")}
    failed_at = min((a["timestamp"] for a in entry.get("attachments", [])
                     if a.get("isAssociatedWithFailure") and a.get("timestamp") is not None), default=None)
    plan = actions(xcresult, identifier)
    steps: list[dict] = []

    def add(title: str, source: Path, when: float, temporary: bool = False) -> None:
        path = frames / f"{len(steps) + 1:04d}-{slug(title)}.jpg"
        try:
            if temporary:
                shutil.move(source, path)
            else:
                to_jpg(source, path)
        except (subprocess.CalledProcessError, OSError):
            print(f"skipped unreadable {source.name} ({identifier})", file=sys.stderr)
            return
        steps.append({"title": title, "time": when, "path": path})

    # Screenshots: one per action, the last one it saved; named captures are steps of their own.
    for action in plan:
        images = [(t, u, n) for t, u, n in action["attachments"]
                  if u in files and Path(files[u]["exportedFileName"]).suffix.lower() in IMAGE_SUFFIXES]
        shots = [i for i in images if i[2].startswith("Screenshot")]
        if shots:
            when, uuid, _ = shots[-1]
            add(action["title"], exported / files[uuid]["exportedFileName"], when)
        for when, uuid, name in images:
            if not name.startswith("Screenshot"):
                label = re.sub(r"_[0-9]+_[0-9A-F-]{36}.*$", "", name)
                add(f"capture: {label}", exported / files[uuid]["exportedFileName"], when)

    # Recordings: a sample a second, captioned with the action running then.
    for attachment in entry.get("attachments", []):
        source = exported / attachment.get("exportedFileName", "")
        if source.suffix.lower() not in VIDEO_SUFFIXES:
            continue
        start = attachment.get("timestamp") or 0
        with tempfile.TemporaryDirectory() as tmp:
            for offset, sample in sample_recording(source, Path(tmp)):
                when = start + offset
                current = [a["title"] for a in plan if a["start"] <= when]
                add(f"{current[-1] if current else 'recording'} (+{int(offset)}s)", sample, when, temporary=True)

    # Screenshots and recording samples interleave by time; number them in that order.
    steps.sort(key=lambda s: s["time"])
    for number, step in enumerate(steps, start=1):
        final = frames / f"{number:03d}-{slug(step['title'])}.jpg"
        step["path"].rename(final)
        step["number"], step["path"] = number, final
    failed_step = None
    if failed_at is not None and steps:
        # The last action before the failure, not XCTest's own failure snapshot.
        before = [s for s in steps if s["time"] <= failed_at + 0.5 and s["title"] != AT_FAILURE]
        failed_step = (before or steps)[-1]["number"]

    # Text a test attached on purpose, under the name it gave.
    kept = [a for a in entry.get("attachments", [])
            if Path(a.get("exportedFileName", "")).suffix.lower() not in IMAGE_SUFFIXES | VIDEO_SUFFIXES
            and not a.get("suggestedHumanReadableName", "").startswith(XCUITEST_NOISE)]
    for attachment in kept:
        # "<name>_0_<UUID>.<ext>" -> "<name>.<ext>"
        name = re.sub(r"_[0-9]+_[0-9A-F-]{36}", "", attachment.get("suggestedHumanReadableName", ""))
        name = re.sub(r"[^A-Za-z0-9._-]+", "-", name).strip("-.") or attachment["exportedFileName"]
        destination = test_dir / "attachments" / name
        destination.parent.mkdir(exist_ok=True)
        with contextlib.suppress(OSError):
            shutil.copyfile(exported / attachment["exportedFileName"], destination)

    lines = [f"# {identifier}: {outcome['result']}", ""]
    lines += [f"Failure: {f.splitlines()[0]}" for f in outcome["failures"] if f]
    lines.append("")
    for step in steps:
        mark = "  <- failed here" if step["number"] == failed_step else ""
        lines.append(f"{step['number']}. {step['title']}  ({step['path'].relative_to(test_dir)}){mark}")
    if not steps:
        lines.append("No screenshots: XCUITest keeps them only for failing tests; "
                     "attach a .keepAlways capture to see a pass.")
    (test_dir / "steps.md").write_text("\n".join(lines) + "\n")
    return {"test": identifier, "result": outcome["result"],
            "failures": [f.splitlines()[0] for f in outcome["failures"] if f],
            "steps": [{"number": s["number"], "title": s["title"], "frame": str(s["path"])} for s in steps],
            "failed_step": failed_step, "sheets": [str(p) for p in build_sheets(steps, test_dir)],
            "dir": str(test_dir)}


def build(xcresults: list[Path], out: Path, test_filter: str | None) -> list[dict]:
    summary = []
    for xcresult in xcresults:
        root = out / xcresult.stem if len(xcresults) > 1 else out
        try:
            results = test_results(xcresult)
            exported = out / ".attachments" / xcresult.stem
            if not (exported / "manifest.json").exists():
                exported.mkdir(parents=True, exist_ok=True)
                run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(xcresult),
                     "--output-path", str(exported)])
        except subprocess.CalledProcessError as error:
            print(f"skipped {xcresult}: xcresulttool failed ({(error.stderr or '').strip()[:200]})", file=sys.stderr)
            continue
        entries = {e.get("testIdentifier"): e for e in json.loads((exported / "manifest.json").read_text())}
        for identifier, outcome in results.items():
            if test_filter and test_filter not in identifier:
                continue
            class_name, _, method = identifier.partition("/")
            entry = entries.get(identifier, {"testIdentifier": identifier, "attachments": []})
            summary.append(extract_test(xcresult, exported, entry, outcome,
                                        root / class_name / (method.rstrip("()") or "test")))
    return summary


def load_built(out: Path, test_filter: str | None) -> list[dict]:
    """Read a downloaded ui-frames artifact back into the summary shape."""
    summary = []
    for steps_md in sorted(out.rglob("steps.md")):
        text = steps_md.read_text().splitlines()
        identifier, _, result = text[0].lstrip("# ").rpartition(": ")
        if test_filter and test_filter not in identifier:
            continue
        steps = []
        failed_step = None
        for line in text:
            match = re.match(r"^(\d+)\. (.*?)  \((frames/[^)]+)\)(  <- failed here)?$", line)
            if match:
                number = int(match.group(1))
                steps.append({"number": number, "title": match.group(2), "frame": str(steps_md.parent / match.group(3))})
                if match.group(4):
                    failed_step = number
        summary.append({"test": identifier, "result": result,
                        "failures": [l[len("Failure: "):] for l in text if l.startswith("Failure: ")],
                        "steps": steps, "failed_step": failed_step,
                        "sheets": [str(p) for p in sorted(steps_md.parent.glob("sheet-*.jpg"))],
                        "dir": str(steps_md.parent)})
    return summary


def markdown(summary: list[dict]) -> str:
    """Job-summary report: one collapsible action list per test, failures first and open."""
    lines = ["## UI test steps", "",
             f"Each action's frame is in the `{FRAMES_ARTIFACT}` artifact: "
             "`scripts/ui-test <this run's URL>` downloads it.", ""]
    for item in sorted(summary, key=lambda i: i["result"] == "Passed"):
        opened = " open" if item["result"] != "Passed" else ""
        lines.append(f"<details{opened}><summary><b>{html.escape(item['result'])}</b> "
                     f"<code>{html.escape(item['test'])}</code></summary>\n")
        for failure in item["failures"]:
            lines.append(f"Failure: <code>{html.escape(failure[:300])}</code>\n")
        for step in item["steps"][:80]:
            mark = " <b>&lt;- failed here</b>" if step["number"] == item["failed_step"] else ""
            lines.append(f"{step['number']}. {html.escape(step['title'])}{mark}")
        lines.append("\n</details>\n")
    return "\n".join(lines) + "\n"


def write_mirror(out: Path, quiet: bool = False) -> None:
    """Build the interactive mirror next to the extracted frames."""
    mirror = Path(__file__).with_name("ui-mirror.py")
    result = subprocess.run(
        [sys.executable, str(mirror), str(out)],
        check=False,
        text=True,
        capture_output=True,
    )
    if result.returncode == 0 and not quiet:
        print(result.stdout.strip())
    elif result.returncode != 0:
        print(f"warning: could not build UI mirror: {result.stderr.strip()[:240]}", file=sys.stderr)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("source", help="run id, run URL, an .xcresult, or a directory of them")
    parser.add_argument("--test", help="only tests whose Class/method contains this substring")
    parser.add_argument("--out", type=Path, help="output directory (default: $TMPDIR/cmux-ui-frames/<run>)")
    parser.add_argument("--repo", default=REPO)
    parser.add_argument("--summary", type=Path, help="append a Markdown report to this file")
    parser.add_argument("--json", action="store_true", help="print the summary as JSON")
    args = parser.parse_args()

    local = Path(args.source)
    run_id = None if local.exists() else parse_run_id(args.source)
    if not local.exists() and not run_id:
        parser.error("source must be a run id, a run URL, an .xcresult, or a directory of them")
    local_built = local.is_dir() and any(local.rglob("steps.md"))
    if local_built:
        out = args.out or local
        if out.resolve() != local.resolve():
            # Keep an explicitly supplied output directory's unrelated files;
            # this command only refreshes the artifact's own paths.
            shutil.copytree(local, out, dirs_exist_ok=True)
    else:
        out = args.out or Path(tempfile.gettempdir()) / "cmux-ui-frames" / (run_id or local.stem)

    if local_built:
        summary = load_built(out, args.test)
    elif run_id and download(run_id, args.repo, FRAMES_ARTIFACT, out):
        summary = load_built(out, args.test)
    else:
        if run_id:
            bundles = out / ".download"
            if not download(run_id, args.repo, RESULTS_ARTIFACT, bundles):
                sys.exit(f"run {run_id} has neither '{FRAMES_ARTIFACT}' nor '{RESULTS_ARTIFACT}'; "
                         "a run that failed before its tests uploads nothing (see its log)")
            local = bundles
        xcresults = [local] if local.suffix == ".xcresult" else sorted(local.rglob("*.xcresult"))
        summary = build(xcresults, out, args.test)
        shutil.rmtree(out / ".attachments", ignore_errors=True)
        if args.summary and summary:
            with args.summary.open("a") as handle:
                handle.write(markdown(summary))

    write_mirror(out, quiet=args.json)
    if args.json:
        print(json.dumps(summary, indent=2))
        return 0
    if not summary:
        print(f"no tests matched in {out}")
        return 1
    for item in sorted(summary, key=lambda i: i["result"] == "Passed"):
        print(f"{item['result']:>8}  {item['test']}  ({len(item['steps'])} steps)")
        for failure in item["failures"]:
            print(f"          failure: {failure.splitlines()[0][:200] if failure else ''}")
        for step in item["steps"]:
            if step["number"] == item["failed_step"]:
                print(f"          failed at step {step['number']}: {step['title']}")
                print(f"          frame: {step['frame']}")
        if item["steps"]:
            print(f"          steps: {item['dir']}/steps.md")
        if item["dir"] and (Path(item["dir"]) / "attachments").is_dir():
            print(f"          attachments: {item['dir']}/attachments")
        for sheet in item["sheets"]:
            print(f"          sheet: {sheet}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
