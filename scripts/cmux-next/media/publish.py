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
GIF_WIDTHS = (720, 560, 440)
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
    found = []
    for path in sorted(media.glob("*/manifest.json")):
        try:
            found.append((path.parent, json.loads(path.read_text(encoding="utf-8"))))
        except (OSError, ValueError) as error:
            print(f"warning: skipping {path}: {error}", file=sys.stderr)
    return found


def make_video(directory: Path, manifest: dict[str, Any], into: Path, pr_media: Any,
               run: Callable[..., Any] = subprocess.run) -> tuple[Path | None, Path | None]:
    """(mp4, gif) from the tour's frames; (None, None) with fewer than two frames."""
    if len(manifest.get("frames") or []) < 2 or not shutil.which("ffmpeg"):
        return None, None
    mp4 = into / "tour.mp4"
    done = run(["ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-framerate", str(VIDEO_FPS),
                "-i", str(directory / "frames/frame-%05d.jpg"),
                "-vf", "scale='min(1280,iw)':-2,pad=ceil(iw/2)*2:ceil(ih/2)*2",
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
    status = STATUS_TEXT.get(step.get("status", ""), step.get("status", ""))
    if step.get("detail"):
        status += f": {step['detail']}"
    command = f"`{step['command']}`" if step.get("command") else ""
    return f"| {step.get('index', '')} | {cell(step.get('title', ''))} | {cell(status)} | {cell(command)} |"


def cell(text: Any) -> str:
    """Table cell text: a pipe or newline would end the cell."""
    return str(text).replace("|", "\\|").replace("\n", " ")


def image(url: str, title: str, width: int) -> str:
    return f'<img src="{html.escape(url, quote=True)}" alt="{html.escape(title, quote=True)}" width="{width}">'


def tour_section(manifest: dict[str, Any], urls: dict[str, str]) -> str:
    steps = manifest.get("steps") or []
    counts = {status: sum(1 for step in steps if step.get("status") == status)
              for status in ("ok", "failed", "unavailable")}
    summary = ", ".join(f"{count} {status}" for status, count in counts.items() if count)
    lines = [f"### {manifest.get('title', manifest.get('name'))}: {summary or 'no steps ran'}", ""]
    if manifest.get("error"):
        lines += [f"> {manifest['error'].splitlines()[0][:300]}", ""]
    if urls.get("tour.gif"):
        lines.append(image(urls["tour.gif"], "tour", 720))
    if urls.get("tour.mp4"):
        lines += ["", f"[Video (mp4)]({urls['tour.mp4']})"]
    lines += ["", "| # | Step | Result | Command |", "| --- | --- | --- | --- |"]
    lines += [step_row(step) for step in steps]
    failed = [step for step in steps if step.get("status") == "failed" and urls.get(step.get("shot", ""))]
    if failed:
        lines += ["", "Failed steps:", ""]
        lines += [image(urls[step["shot"]], f"{step['index']} {step['title']}", 480) for step in failed]
    rest = [step for step in steps if step not in failed and urls.get(step.get("shot", ""))]
    if rest:
        lines += ["", f"<details><summary>Screenshots ({len(rest)})</summary>", ""]
        lines += [f"**{step['index']}. {html.escape(step['title'])}**<br>{image(urls[step['shot']], step['title'], 480)}<br>"
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

    if not args.dry_run:
        head = gh(["api", f"repos/{args.repo}/pulls/{args.pr}", "--jq", ".head.sha"]).strip()
        if head != args.sha:
            print(f"#{args.pr} moved to {head[:8]}; its own run posts the media")
            return 0

    pr_media = load_pr_media()
    sections = []
    with tempfile.TemporaryDirectory() as scratch:
        for directory, manifest in manifests(args.media) if args.media.is_dir() else []:
            name = manifest.get("name") or directory.name
            folder = f"{args.pr}/{args.sha[:8]}/next-{name}"
            files: dict[str, Path] = {}
            for step in manifest.get("steps") or []:
                shot = directory / step.get("shot", "")
                if step.get("shot") and shot.is_file() and shot.stat().st_size <= pr_media.INLINE_MAX_BYTES:
                    files[step["shot"]] = shot
            into = Path(scratch) / name
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
            sections.append(tour_section(manifest, urls))

    body = render(args.sha, sections, args.run_url, args.note)
    if args.dry_run:
        print(body)
        return 0
    upsert_comment(args.repo, args.pr, body)
    print(f"Posted the tour media on #{args.pr}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
