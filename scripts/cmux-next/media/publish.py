#!/usr/bin/env python3
"""Post cmux-next tour media on its pull request: one sticky comment per PR.

    publish.py --media DIR --pr N --sha SHA [--run-url URL] [--note TEXT] [--dry-run]

DIR holds tour.py's output (<tour>/manifest.json, shots/, frames/). For each
tour this turns the frames into an mp4 and a GIF, uploads them and the
screenshots to the `pr-media` branch at <pr>/<sha8>/next-<tour>/ (the layout
scripts/ci/prune_pr_media.py bounds), and writes the comment marked
COMMENT_MARKER: the GIF, a step table, failed steps' screenshots inline and
the rest folded. With no tour output, `--note` says why in the same comment.

Uploads go through scripts/pr-media.py's contents-API writer. Nothing is
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
BOT = "github-actions[bot]"
# Frames are taken about every 0.5 s; played at 4 per second the video runs at 2x.
VIDEO_FPS = 4
GIF_FPS = 4
VIDEO_SIZE = (1280, 800)
# tour.py's MAX_FRAMES: a larger artifact does not make a longer video.
MAX_FRAMES = 600
GIF_WIDTHS = (720, 560, 440)
TOUR_NAME = re.compile(r"[a-z0-9][a-z0-9-]{0,39}")
SHOT_PATH = re.compile(r"shots/[0-9]{2}-[a-z0-9-]{1,40}(?:-failed)?\.png")
STATUS_TEXT = {"ok": "ok", "failed": "**failed**", "unavailable": "unavailable"}


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
    for path in sorted(media.glob("*/manifest.json")):
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


def make_video(directory: Path, manifest: dict[str, Any], into: Path, pr_media: Any,
               run: Callable[..., Any] = subprocess.run) -> tuple[Path | None, Path | None]:
    """(mp4, gif) from the tour's frames; (None, None) with fewer than two frames."""
    if len(manifest.get("frames") or []) < 2 or not shutil.which("ffmpeg"):
        return None, None
    mp4 = into / "tour.mp4"
    done = run(["ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-framerate", str(VIDEO_FPS),
                "-i", str(directory / "frames/frame-%05d.jpg"),
                "-frames:v", str(MAX_FRAMES),
                # A fixed output size: a frame of another size cannot break the stream.
                "-vf", f"scale={VIDEO_SIZE[0]}:{VIDEO_SIZE[1]}:force_original_aspect_ratio=decrease,"
                       f"pad={VIDEO_SIZE[0]}:{VIDEO_SIZE[1]}:(ow-iw)/2:(oh-ih)/2:color=white",
                "-c:v", "libx264", "-pix_fmt", "yuv420p", "-movflags", "+faststart", str(mp4)],
               capture_output=True, text=True)
    if done.returncode != 0 or not mp4.is_file():
        print(f"warning: no video for {directory.name}: {done.stderr.strip()}", file=sys.stderr)
        return None, None
    gif = into / "tour.gif"
    for width in GIF_WIDTHS:
        done = run(pr_media.gif_argv(mp4, gif, GIF_FPS, width), capture_output=True, text=True)
        if done.returncode == 0 and gif.is_file() and gif.stat().st_size <= pr_media.INLINE_MAX_BYTES - 512 * 1024:
            return mp4, gif
    return mp4, None


def step_row(step: dict[str, Any]) -> str:
    status = STATUS_TEXT.get(step.get("status", ""), "")
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


def tour_section(manifest: dict[str, Any], urls: dict[str, str]) -> str:
    steps = manifest.get("steps") or []
    counts = {status: sum(1 for step in steps if step.get("status") == status)
              for status in ("ok", "failed", "unavailable")}
    summary = ", ".join(f"{count} {status}" for status, count in counts.items() if count)
    lines = [f"### {cell(manifest.get('title') or 'Tour')}: {summary or 'no steps ran'}", ""]
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
        lines += [f"**{cell(step['index'])}. {cell(step['title'])}**<br>{image(urls[step['shot']], step['title'], 480)}<br>"
                  for step in failed]
    rest = [step for step in steps if step not in failed and urls.get(str(step.get("shot", "")))]
    if rest:
        lines += ["", f"<details><summary>Screenshots ({len(rest)})</summary>", ""]
        lines += [f"**{cell(step['index'])}. {cell(step['title'])}**<br>{image(urls[step['shot']], step['title'], 480)}<br>"
                  for step in rest]
        lines += ["", "</details>"]
    return "\n".join(lines)


def render(sha: str, sections: list[str], run_url: str | None, note: str | None) -> str:
    run = f" ([run]({run_url}))" if run_url else ""
    lines = [COMMENT_MARKER, f"**cmux-next tour** of `{sha}`{run}", ""]
    if note:
        lines += [note, ""]
    lines += sections or ["The tour produced no media."]
    lines += ["", f"<sub>Tours are data in `{TOURS_DIR}`: add a step or a tour file to show your feature.</sub>"]
    return "\n".join(lines) + "\n"


def gh(args: list[str], stdin: str | None = None) -> str:
    done = subprocess.run(["gh", *args], input=stdin, capture_output=True, text=True)
    if done.returncode != 0:
        raise RuntimeError(f"gh {' '.join(args[:3])}: {done.stderr.strip()}")
    return done.stdout


def upsert_comment(repo: str, pr: int, body: str) -> None:
    ids = gh(["api", f"repos/{repo}/issues/{pr}/comments", "--paginate", "--jq",
              f'.[] | select(.user.login == "{BOT}" and (.body | contains("{COMMENT_MARKER}"))) | .id'])
    existing = ids.split()
    payload = json.dumps({"body": body})
    if existing:
        gh(["api", "-X", "PATCH", f"repos/{repo}/issues/comments/{existing[0]}", "--input", "-"], payload)
    else:
        gh(["api", "-X", "POST", f"repos/{repo}/issues/{pr}/comments", "--input", "-"], payload)


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

    body = render(args.sha, sections, args.run_url, args.note)
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
    for step in manifest["steps"]:
        shot = shot_file(directory, step.get("shot"))
        if shot and shot.stat().st_size <= pr_media.INLINE_MAX_BYTES \
                and pr_media.family_of_content(shot) == "png":
            files[step["shot"]] = shot
    into = scratch / name
    into.mkdir()
    mp4, gif = make_video(directory, manifest, into, pr_media)
    for local in (mp4, gif):
        if local:
            files[local.name] = local
    urls = {}
    for key, local in files.items():
        remote = f"{folder}/{key}"
        if not args.dry_run:
            pr_media.put_file(args.repo, pr_media.BRANCH, remote, local,
                              f"cmux-next tour media for #{args.pr} at {args.sha[:8]}")
        urls[key] = pr_media.raw_url(args.repo, pr_media.BRANCH, remote)
    return tour_section(manifest, urls)


if __name__ == "__main__":
    sys.exit(main())
