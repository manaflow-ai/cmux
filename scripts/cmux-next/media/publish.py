#!/usr/bin/env python3
"""Post cmux-next tour media on its pull request, in the `tour` part of its status comment.

    publish.py --media DIR --pr N --sha SHA [--run-url URL] [--note TEXT] [--dry-run]

DIR holds tour.py's output (<tour>/manifest.json, shots/, frames/). For each
tour this turns the frames into an mp4 and a GIF, uploads them and the
screenshots to the `pr-media` branch at <pr>/<sha8>/next-<tour>/ (the layout
scripts/ci/prune_pr_media.py bounds), and writes the `tour` section of the
PR's status comment (scripts/ci/pr_status.py): the GIF, a step table, failed
steps' screenshots inline and the rest folded. With no tour output, `--note`
says why in one line. The comment this used to keep on its own (COMMENT_MARKER)
is deleted on the first write.

Uploads go through scripts/pr-media.py's git writer, after its
privacy check (scripts/ci/pr_media_privacy.py) has passed every file of the
tour: one refused file uploads none of that tour's media. Nothing is
posted when the pull request's head has moved past SHA: the newer push's run
posts its own.
"""

from __future__ import annotations

import argparse
import html
import importlib.util
import json
import re
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from typing import Any, Callable

ROOT = Path(__file__).resolve().parents[3]
COMMENT_MARKER = "<!-- cmux-next:tour-media -->"
TOURS_DIR = "scripts/cmux-next/media/tours"
# Native window recordings carry their own timestamps and are encoded at that rate. The still-frame
# fallback uses the manifest's measured interval. This is the target rate for any downstream reel
# normalisation; it must never turn a real recording into a four-frame-per-second clip.
VIDEO_FPS = 60
# tour.py's FRAME_INTERVAL, for a manifest that names none.
DEFAULT_FRAME_INTERVAL = 0.5
VIDEO_SIZE = (1280, 800)
# The GIF's frame rate comes from pr_media.gif_attempts: 50 fps from a 60 Hz recording when it fits, else 30,
# stepping down width first and then rate until it fits under the inline limit (never above the clip's rate).
GIF_WIDTHS = (720, 560, 440)
VIDEO_NAME = "capture.mov"
TOUR_NAME = re.compile(r"[a-z0-9][a-z0-9-]{0,39}")
# A step's main-window shot, or one of its other windows (tour.py: <shot>--w<window number>).
SHOT_PATH = re.compile(r"shots/[0-9]{2}-[a-z0-9-]{1,40}(?:-failed)?(?:--w[0-9]{1,9})?\.png")
# Other-window shots one tour uploads at most (each is a commit on pr-media).
MAX_WINDOW_SHOTS = 20
WINDOW_KIND = re.compile(r"[A-Za-z0-9._-]{1,40}")
STATUS_TEXT = {"ok": "ok", "failed": "**failed**", "unavailable": "unavailable"}
# An ok step whose shot no `expect` checked (tour.py's `checked`): it ran, but nothing read the screen.
UNCHECKED_TEXT = "ok, unchecked (no expect)"


def load_pr_media() -> Any:
    spec = importlib.util.spec_from_file_location("pr_media_tool", ROOT / "scripts/pr-media.py")
    module = importlib.util.module_from_spec(spec)
    assert spec.loader
    # Its dataclasses look their module up in sys.modules while it loads.
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def manifests(media: Path) -> list[tuple[Path, dict[str, Any]]]:
    """Each tour's folder and manifest. The artifact came from a job that ran
    the pull request's code, so it is data: a folder whose name is not a tour
    slug, or a manifest that is not an object, is skipped."""
    found = []
    def manifest_order(path: Path) -> tuple[str, int, str]:
        # Adjacent base/head sections make the before/after comparison easy to
        # scan in the PR comment. capture_paths.py names these ``*-before`` and
        # ``*-after`` while keeping each clip a normal tour artifact.
        name = path.parent.name
        variant = 0 if name.endswith("-before") else 1
        comparison = name.rsplit("-", 1)[0] if name.endswith(("-before", "-after")) else name
        return comparison, variant, name

    for path in sorted(media.glob("*/manifest.json"), key=manifest_order):
        if not TOUR_NAME.fullmatch(path.parent.name) or path.is_symlink():
            print(f"warning: skipping {path}: not a tour folder", file=sys.stderr)
            continue
        try:
            manifest = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as error:
            print(f"warning: skipping {path}: {error}", file=sys.stderr)
            continue
        if isinstance(manifest, dict) and isinstance(manifest.get("steps", []), list):
            manifest["steps"] = [clean_step(step) for step in manifest.get("steps", []) if isinstance(step, dict)]
            manifest["frames"] = manifest.get("frames") if isinstance(manifest.get("frames"), list) else []
            for key in ("title", "error", "capture_mode"):
                if key in manifest:
                    manifest[key] = str(manifest[key])
            found.append((path.parent, manifest))
    return found


def clean_step(step: dict[str, Any]) -> dict[str, Any]:
    """A step with only the fields the comment shows, each a plain string or int."""
    status = step.get("status")
    index = step.get("index")
    return {
        "index": index if isinstance(index, int) and not isinstance(index, bool) else "",
        "title": str(step.get("title", ""))[:200],
        "status": status if isinstance(status, str) and status in STATUS_TEXT else "failed",
        "detail": str(step.get("detail") or "")[:500],
        "command": str(step.get("command") or "")[:500],
        "shot": step["shot"] if isinstance(step.get("shot"), str) else "",
        # False when no `expect` checked the step; absent in manifests from before tour.py wrote it.
        **({"checked": step["checked"]} if isinstance(step.get("checked"), bool) else {}),
        # The step's other windows (floating panels, popovers, sheets), each a shot tour.py wrote.
        "windows": [
            {"shot": window["shot"], "kind": window["kind"] if WINDOW_KIND.fullmatch(str(window.get("kind"))) else "window"}
            for window in (step.get("windows") if isinstance(step.get("windows"), list) else [])[:8]
            if isinstance(window, dict) and isinstance(window.get("shot"), str) and SHOT_PATH.fullmatch(window["shot"])
        ],
    }


def shot_file(directory: Path, shot: Any) -> Path | None:
    """The screenshot a step names, when it is one tour.py could have written:
    shots/NN-slug.png inside the tour folder, a regular file, not a link."""
    if not isinstance(shot, str) or not SHOT_PATH.fullmatch(shot):
        return None
    path = directory / shot
    if path.is_symlink() or not path.is_file():
        return None
    return path


def input_framerate(manifest: dict[str, Any]) -> str:
    """ffmpeg's -framerate for the tour's frames: one over the seconds between them, so the video runs in
    real time. A missing or unreasonable frame_interval falls back to tour.py's default."""
    interval = manifest.get("frame_interval")
    if isinstance(interval, bool) or not isinstance(interval, (int, float)) or not 1 / 120 <= interval <= 60:
        interval = DEFAULT_FRAME_INTERVAL
    return f"{1 / interval:.6g}"


def capture_file(directory: Path, manifest: dict[str, Any]) -> Path | None:
    """Return tour.py's native window recording when it is a safe local file.

    The manifest is untrusted job output. Keep the publisher inside the tour directory and reject
    links so a malformed capture cannot make the media job read another artifact.
    """
    name = manifest.get("video")
    if name != VIDEO_NAME or not isinstance(name, str):
        return None
    path = directory / name
    try:
        if path.is_symlink() or not path.is_file() or path.parent.resolve() != directory.resolve():
            return None
    except OSError:
        return None
    return path


def make_video(directory: Path, manifest: dict[str, Any], into: Path, pr_media: Any,
               run: Callable[..., Any] = subprocess.run) -> tuple[Path | None, Path | None]:
    """(mp4, gif) from a native recording, or measured-rate still frames."""
    native = capture_file(directory, manifest)
    frames = manifest.get("frames") or []
    if (native is None and len(frames) < 2) or not shutil.which("ffmpeg"):
        return None, None
    mp4 = into / "tour.mp4"
    env = pr_media.tool_env()
    if native is not None:
        # ScreenCaptureKit writes a window-only MOV at the display's real rate (normally 60 Hz).
        # Do not add an input -framerate: that would discard its timestamps and create 4 fps video.
        source = ["-i", str(native)]
        rate = ["-fps_mode", "passthrough"]
    else:
        source = ["-framerate", input_framerate(manifest), "-i",
                  str(directory / "frames/frame-%05d.jpg")]
        rate = []
    done = run(["ffmpeg", "-nostdin", "-loglevel", "error", "-y", *source, "-t", "300",
                # A fixed output size: a frame of another size cannot break the stream.
                "-vf", f"scale={VIDEO_SIZE[0]}:{VIDEO_SIZE[1]}:force_original_aspect_ratio=decrease,"
                       f"pad={VIDEO_SIZE[0]}:{VIDEO_SIZE[1]}:(ow-iw)/2:(oh-ih)/2:color=white",
                *rate, "-an", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-movflags", "+faststart", str(mp4)],
               capture_output=True, text=True, env=env)
    if done.returncode != 0 or not mp4.is_file():
        print(f"warning: no video for {directory.name}: {done.stderr.strip()}", file=sys.stderr)
        return None, None
    gif = into / "tour.gif"
    # The rate is known, so nothing is probed: a native recording runs at the display's rate (a variable-rate
    # capture's average undercounts it, and must not cap the gif below 30), the still fallback at its measured one.
    source_rate = float(VIDEO_FPS) if native is not None else float(input_framerate(manifest))
    for fps, width in pr_media.gif_attempts(GIF_WIDTHS, None, source_rate):
        done = run(pr_media.gif_argv(mp4, gif, fps, width), capture_output=True, text=True, env=env)
        if done.returncode == 0 and gif.is_file() and gif.stat().st_size <= pr_media.INLINE_MAX_BYTES - 512 * 1024:
            return mp4, gif
    return mp4, None


def unchecked(step: dict[str, Any]) -> bool:
    """An ok step with a shot that no `expect` checked."""
    return step.get("status") == "ok" and bool(step.get("shot")) and step.get("checked") is False


def step_row(step: dict[str, Any]) -> str:
    status = UNCHECKED_TEXT if unchecked(step) else STATUS_TEXT.get(step.get("status", ""), "")
    detail = f": {cell(step['detail'])}" if step.get("detail") else ""
    # A code span cannot hold its own backticks, and inside one nothing else is Markdown.
    one_line = re.sub(r"[\r\n]+", " ", str(step.get("command") or "")).replace("`", "'")
    command = f"`{one_line}`" if one_line else ""
    return f"| {cell(step.get('index', ''))} | {cell(step.get('title', ''))} | {status}{detail} | {command.replace('|', chr(92) + '|')} |"


MARKDOWN_SPECIAL = re.compile(r"([\\`*_{}\[\]()#+!<>~|-])")


def cell(text: Any) -> str:
    """Manifest text for the comment, inert: it comes from a job that ran the
    pull request's code. HTML and Markdown are escaped, and @ is broken so no
    mention or team ping is sent."""
    escaped = MARKDOWN_SPECIAL.sub(r"\\\1", html.escape(str(text), quote=False))
    return re.sub(r"[\r\n]+", " ", escaped.replace("@", "@\u200b"))


def image(url: str, title: str, width: int) -> str:
    return f'<img src="{html.escape(url, quote=True)}" alt="{html.escape(title, quote=True)}" width="{width}">'


def step_images(step: dict[str, Any], urls: dict[str, str]) -> str:
    """The step's main-window shot, then each other window it shot."""
    parts = [image(urls[step["shot"]], step["title"], 480)]
    parts += [image(urls[window["shot"]], f"{step['title']} ({window['kind']})", 360)
              for window in step.get("windows") or [] if urls.get(window["shot"])]
    return " ".join(parts)


def tour_section(manifest: dict[str, Any], urls: dict[str, str]) -> str:
    steps = manifest.get("steps") or []
    counts = {status: sum(1 for step in steps if step.get("status") == status and not unchecked(step))
              for status in ("ok", "failed", "unavailable")}
    counts["unchecked"] = sum(1 for step in steps if unchecked(step))
    summary = ", ".join(f"{count} {status}" for status, count in counts.items() if count)
    verdict = manifest.get("result")
    verdict_label = {
        "pass": "PASS",
        "degraded": "DEGRADED",
        "failed": "FAILED",
    }.get(verdict, "UNCLASSIFIED")
    lines = [f"### {cell(manifest.get('title') or 'Tour')}: {verdict_label} — {summary or 'no steps ran'}", ""]
    if manifest.get("error"):
        lines += [f"> {cell(str(manifest['error']).splitlines()[0][:300])}", ""]
    capture = str(manifest.get("capture_mode") or "")
    if capture.startswith("none") and not any(urls.get(str(step.get("shot"))) for step in steps):
        lines += [f"> No screenshots: screen capture is unavailable on this runner ({cell(capture[:400])}).", ""]
    if urls.get("tour.gif"):
        lines.append(image(urls["tour.gif"], "tour", 720))
    if urls.get("tour.mp4"):
        lines += ["", f"[Video (mp4)]({urls['tour.mp4']})"]
    lines += ["", "| # | Step | Result | Command |", "| --- | --- | --- | --- |"]
    lines += [step_row(step) for step in steps]
    failed = [step for step in steps if step.get("status") == "failed" and urls.get(str(step.get("shot", "")))]
    if failed:
        lines += ["", "Failed steps:", ""]
        lines += [f"**{cell(step['index'])}. {cell(step['title'])}**<br>{step_images(step, urls)}<br>"
                  for step in failed]
    rest = [step for step in steps if step not in failed and urls.get(str(step.get("shot", "")))]
    if rest:
        lines += ["", f"<details><summary>Screenshots ({len(rest)})</summary>", ""]
        lines += [f"**{cell(step['index'])}. {cell(step['title'])}**<br>{step_images(step, urls)}<br>"
                  for step in rest]
        lines += ["", "</details>"]
    return "\n".join(lines)


def scope_table(media: Path) -> str:
    """Render the path-to-interaction decision recorded by the runner."""
    receipt = media / "capture-receipt.json"
    if not receipt.is_file() or receipt.is_symlink():
        return ""
    try:
        data = json.loads(receipt.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return ""
    matches = data.get("matches")
    if not isinstance(matches, dict):
        return ""
    rows = []
    order = data.get("tours") if isinstance(data.get("tours"), list) else []
    for tour in order:
        if not isinstance(tour, str) or not TOUR_NAME.fullmatch(tour):
            continue
        paths = matches.get(tour)
        if not isinstance(paths, list) or not paths:
            continue
        paths_text = "<br>".join(f"`{cell(path)}`" for path in paths)
        rows.append(f"| `{tour}` | {paths_text} |")
    if not rows:
        return ""
    return "### Path-selected interactions\n\n| Interaction | Changed paths |\n| --- | --- |\n" + "\n".join(rows) + "\n"


def render(sha: str, sections: list[str], run_url: str | None, note: str | None,
           scope: str = "") -> str:
    run = f" ([run]({run_url}))" if run_url else ""
    if not sections:
        # No media: one line, not a block.
        why = f" {note}" if note else ""
        return f"Tour of `{sha[:10]}`{run}: no media.{why}\n"
    lines = [f"**Tour** of `{sha[:10]}`{run}", ""]
    if note:
        lines += [note, ""]
    if scope:
        lines += [scope, ""]
    lines += sections
    lines += ["", f"<sub>Tours are data in `{TOURS_DIR}`: add a step or a tour file to show your feature.</sub>"]
    return "\n".join(lines) + "\n"


def gh(args: list[str], stdin: str | None = None) -> str:
    done = subprocess.run(["gh", *args], input=stdin, capture_output=True, text=True)
    if done.returncode != 0:
        raise RuntimeError(f"gh {' '.join(args[:3])}: {done.stderr.strip()}")
    return done.stdout


def upsert_comment(repo: str, pr: int, body: str) -> None:
    sys.path.insert(0, str(ROOT / "scripts/ci"))
    import pr_status
    pr_status.upsert(repo, pr, "tour", body, legacy=COMMENT_MARKER)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--media", type=Path, required=True)
    parser.add_argument("--pr", type=int, required=True)
    parser.add_argument("--sha", required=True)
    parser.add_argument("--repo", default="manaflow-ai/cmux")
    parser.add_argument("--run-url")
    parser.add_argument("--note", help="why the tour did not run or is incomplete")
    parser.add_argument("--dry-run", action="store_true", help="print the comment; upload and post nothing")
    args = parser.parse_args(argv)

    if not args.dry_run and head_moved(args):
        return 0

    pr_media = load_pr_media()
    sections = []
    with tempfile.TemporaryDirectory() as scratch:
        for directory, manifest in manifests(args.media) if args.media.is_dir() else []:
            try:
                sections.append(publish_tour(directory, manifest, args, pr_media, Path(scratch)))
            except (OSError, ValueError, TypeError, KeyError, subprocess.SubprocessError, pr_media.MediaError) as error:
                print(f"warning: tour {directory.name}: {error}", file=sys.stderr)
                sections.append(f"### {cell(directory.name)}: the media could not be published ({cell(str(error)[:200])})")

    body = render(args.sha, sections, args.run_url, args.note, scope_table(args.media))
    if args.dry_run:
        print(body)
        return 0
    # Uploads take minutes; a push in the meantime posts its own media.
    if head_moved(args):
        return 0
    upsert_comment(args.repo, args.pr, body)
    print(f"Posted the tour media on #{args.pr}")
    return 0


def head_moved(args: argparse.Namespace) -> bool:
    head = gh(["api", f"repos/{args.repo}/pulls/{args.pr}", "--jq", ".head.sha"]).strip()
    if head != args.sha:
        print(f"#{args.pr} moved to {head[:8]}; its own run posts the media")
        return True
    return False


def publish_tour(directory: Path, manifest: dict[str, Any], args: argparse.Namespace, pr_media: Any,
                 scratch: Path) -> str:
    """Upload one tour's media; its comment section."""
    name = directory.name
    folder = f"{args.pr}/{args.sha[:8]}/next-{name}"
    files: dict[str, Path] = {}
    window_files: dict[str, Path] = {}
    for step in manifest["steps"]:
        for key in [step.get("shot")] + [window["shot"] for window in step.get("windows") or []]:
            shot = shot_file(directory, key)
            if shot and shot.stat().st_size <= pr_media.INLINE_MAX_BYTES \
                    and pr_media.family_of_content(shot) == "png":
                (files if key == step.get("shot") else window_files)[key] = shot
    into = scratch / name
    into.mkdir()
    mp4, gif = make_video(directory, manifest, into, pr_media)
    for local in (mp4, gif):
        if local:
            files[local.name] = local
    windows = list(window_files.items())[:MAX_WINDOW_SHOTS]
    if not args.dry_run:
        # The whole tour before its first upload; a refusal (PrivacyError) ends the tour.
        pr_media.check_privacy([(f"{folder}/{key}", local) for key, local in [*files.items(), *windows]],
                               args.repo)
    urls = {}
    # The main shots and the video first; a window shot that fails to upload is
    # dropped on its own, so it never costs the tour its other media.
    for key, local in files.items():
        remote = f"{folder}/{key}"
        if not args.dry_run:
            # No #N in the message: GitHub lists every commit that names the pull request in its
            # timeline, one entry per uploaded file (scripts/pr-media.py writes PR N the same way).
            pr_media.put_file(args.repo, pr_media.BRANCH, remote, local,
                              f"PR {args.pr} cmux-next tour media at {args.sha[:8]}", checked=True)
        urls[key] = pr_media.raw_url(args.repo, pr_media.BRANCH, remote)
    for key, local in windows:
        remote = f"{folder}/{key}"
        try:
            if not args.dry_run:
                pr_media.put_file(args.repo, pr_media.BRANCH, remote, local,
                                  f"PR {args.pr} cmux-next tour media at {args.sha[:8]}", checked=True)
        except Exception as error:  # noqa: BLE001 - one window's upload must not end the tour
            print(f"warning: {key}: {error}", file=sys.stderr)
            continue
        urls[key] = pr_media.raw_url(args.repo, pr_media.BRANCH, remote)
    return tour_section(manifest, urls)


if __name__ == "__main__":
    sys.exit(main())
