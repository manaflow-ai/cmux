#!/usr/bin/env python3
"""Put a clip or screenshot on the pr-media branch and print the Markdown for a PR.

    pr-media.py --pr 15277 clip.mp4 sidebar.png [...] [--dry-run]
    pr-media.py --pr 15277 frames-out/ --label "sidebar drag"

Each file lands at `<pr>/<name>` on the `pr-media` branch, and the tool prints
Markdown that embeds it from raw.githubusercontent.com, ready to paste into the
PR description or a comment. `--comment` posts that Markdown to the PR instead
of only printing it.

An mp4 is also converted to a gif, because GitHub renders a gif inline from a
raw URL and will not render an mp4 from one: a reviewer scrolling a PR sees the
gif move without clicking, and the mp4 stays linked next to it at full quality.
`cmux record --gif` output needs no conversion and is uploaded as it is.

Conversion needs ffmpeg. Everything else needs `gh` with push access to the
repository. `--dry-run` resolves the whole plan and prints it without running
either.
"""

from __future__ import annotations

import argparse
import base64
import json
import shutil
import subprocess
import sys
import tempfile
import urllib.parse
from dataclasses import dataclass
from pathlib import Path

REPO = "manaflow-ai/cmux"
BRANCH = "pr-media"
RAW_HOST = "https://raw.githubusercontent.com"

VIDEO_SUFFIXES = (".mp4", ".mov")
IMAGE_SUFFIXES = (".png", ".jpg", ".jpeg")
GIF_SUFFIXES = (".gif",)
MEDIA_SUFFIXES = VIDEO_SUFFIXES + IMAGE_SUFFIXES + GIF_SUFFIXES

DEFAULT_GIF_FPS = 10
DEFAULT_GIF_WIDTH = 900
# A gif this size still loads in a PR; past it a reader waits on the page.
WARN_BYTES = 8 * 1024 * 1024
# Past this the upload is refused: the branch is read by every PR that links it.
MAX_BYTES = 25 * 1024 * 1024


class MediaError(Exception):
    """A problem worth a one-line message rather than a traceback."""


@dataclass(frozen=True)
class Upload:
    """One file to place on the branch, and how to describe it."""

    local: Path
    name: str
    kind: str  # "gif", "video" or "image"
    label: str
    # The mp4 a gif was made from, so the two can be printed together.
    source_name: str | None = None


def sanitize(name: str) -> str:
    """A branch-safe, URL-safe file name that still reads like the original."""
    stem = Path(name).stem
    suffix = Path(name).suffix.lower()
    kept = [character if character.isalnum() or character in "-_." else "-" for character in stem]
    collapsed = "".join(kept)
    while "--" in collapsed:
        collapsed = collapsed.replace("--", "-")
    collapsed = collapsed.strip("-._")
    if not collapsed:
        raise MediaError(f"no usable file name in {name!r}")
    return collapsed + suffix


def label_for(name: str) -> str:
    """A caption from the file name: `02-sidebar-drag.gif` reads as `sidebar drag`."""
    stem = Path(name).stem
    parts = [part for part in stem.replace("_", "-").split("-") if part]
    if len(parts) > 1 and parts[0].isdigit():
        parts = parts[1:]
    return " ".join(parts) if parts else stem


def collect(paths: list[str]) -> list[Path]:
    """Files to upload, expanding a directory into the media files directly in it."""
    found: list[Path] = []
    for entry in paths:
        path = Path(entry)
        if path.is_dir():
            inside = sorted(
                child for child in path.iterdir()
                if child.is_file() and child.suffix.lower() in MEDIA_SUFFIXES
            )
            if not inside:
                raise MediaError(f"no media files directly in {path}")
            found.extend(inside)
            continue
        if not path.is_file():
            raise MediaError(f"not a file: {path}")
        if path.suffix.lower() not in MEDIA_SUFFIXES:
            raise MediaError(f"unsupported file type: {path} (want one of {', '.join(MEDIA_SUFFIXES)})")
        found.append(path)
    if not found:
        raise MediaError("nothing to upload")
    return found


def kind_of(path: Path) -> str:
    suffix = path.suffix.lower()
    if suffix in VIDEO_SUFFIXES:
        return "video"
    if suffix in GIF_SUFFIXES:
        return "gif"
    return "image"


def gif_argv(source: Path, destination: Path, fps: int, width: int) -> list[str]:
    """One-pass mp4 to gif: a palette from the clip itself, then the frames.

    `min(width\\,iw)` keeps a narrow clip at its own width instead of blowing it
    up, and the comma is escaped because a filter graph separates filters with
    one. stats_mode=diff spends the palette on what moves, which is what a UI
    clip is for.
    """
    chain = (
        f"fps={fps},"
        f"scale=w='min({width}\\,iw)':h=-1:flags=lanczos,"
        "split[frames][forpalette];"
        "[forpalette]palettegen=stats_mode=diff[palette];"
        "[frames][palette]paletteuse=dither=bayer:bayer_scale=3"
    )
    return [
        "ffmpeg", "-nostdin", "-loglevel", "error", "-y",
        "-i", str(source),
        "-filter_complex", chain,
        "-loop", "0",
        str(destination),
    ]


def remote_path(pr: int, name: str) -> str:
    return f"{pr}/{name}"


def raw_url(repo: str, branch: str, path: str) -> str:
    return f"{RAW_HOST}/{repo}/{branch}/{urllib.parse.quote(path)}"


def plan(files: list[Path], pr: int, label: str | None, gif: bool) -> list[Upload]:
    """What goes on the branch, in the order it was asked for.

    An mp4 plans two entries: the mp4 itself and the gif made from it, the gif
    named after it so the pair stays obvious in the folder listing.
    """
    uploads: list[Upload] = []
    used: set[str] = set()
    for path in files:
        name = sanitize(path.name)
        if name in used:
            raise MediaError(f"two files would upload as {name}; rename one")
        used.add(name)
        caption = label if label and len(files) == 1 else label_for(name)
        kind = kind_of(path)
        if kind == "video" and gif:
            gif_name = Path(name).with_suffix(".gif").name
            if gif_name in used:
                raise MediaError(f"{name} would overwrite {gif_name}; rename one")
            used.add(gif_name)
            uploads.append(Upload(local=path, name=gif_name, kind="gif", label=caption,
                                  source_name=name))
        uploads.append(Upload(local=path, name=name, kind=kind, label=caption))
    return uploads


def markdown(uploads: list[Upload], pr: int, repo: str = REPO, branch: str = BRANCH) -> str:
    """Markdown for the PR: the moving or still image inline, the mp4 linked.

    An mp4 that has a gif is not embedded, because GitHub will not render it
    from a raw URL; it is linked under the gif for anyone who wants the frames.
    """
    gif_sources = {upload.source_name for upload in uploads if upload.source_name}
    lines: list[str] = []
    for upload in uploads:
        url = raw_url(repo, branch, remote_path(pr, upload.name))
        if upload.kind in ("gif", "image"):
            lines.append(f"![{upload.label}]({url})")
        elif upload.name in gif_sources:
            lines.append(f"Full quality: [{upload.name}]({url})")
        else:
            lines.append(f"[{upload.label} ({upload.name})]({url})")
        lines.append("")
    return "\n".join(lines).strip() + "\n"


def check_size(path: Path) -> list[str]:
    """Refuse an upload nobody will wait for; warn before it gets there."""
    size = path.stat().st_size
    if size > MAX_BYTES:
        raise MediaError(
            f"{path.name} is {size / 1024 / 1024:.1f} MB, over the {MAX_BYTES // 1024 // 1024} MB limit. "
            "Record a shorter clip, or lower --gif-fps or --gif-width."
        )
    if size > WARN_BYTES:
        return [f"{path.name} is {size / 1024 / 1024:.1f} MB; a PR page will be slow to load it"]
    return []


def gh_json(args: list[str], runner=None) -> dict | None:
    """A `gh api` read, or None when the object is not there."""
    done = (runner or subprocess.run)(["gh", "api", *args], capture_output=True, text=True)
    if done.returncode != 0:
        return None
    try:
        return json.loads(done.stdout)
    except json.JSONDecodeError:
        return None


def existing_sha(repo: str, branch: str, path: str, runner=None) -> str | None:
    found = gh_json([f"repos/{repo}/contents/{urllib.parse.quote(path)}?ref={branch}"], runner=runner)
    if isinstance(found, dict):
        sha = found.get("sha")
        return sha if isinstance(sha, str) else None
    return None


def put_file(repo: str, branch: str, path: str, local: Path, message: str,
             runner=None) -> None:
    """Write one file to the branch through the contents API.

    The body goes in on stdin: a base64 megabyte does not fit in an argument
    list, and `gh api -f` would put it there.
    """
    body = {
        "message": message,
        "branch": branch,
        "content": base64.b64encode(local.read_bytes()).decode("ascii"),
    }
    sha = existing_sha(repo, branch, path, runner=runner)
    if sha:
        body["sha"] = sha
    done = (runner or subprocess.run)(
        ["gh", "api", "--method", "PUT", f"repos/{repo}/contents/{urllib.parse.quote(path)}", "--input", "-"],
        input=json.dumps(body), capture_output=True, text=True,
    )
    if done.returncode != 0:
        raise MediaError(f"upload of {path} failed: {(done.stderr or done.stdout).strip()}")


def require_branch(repo: str, branch: str, runner=None) -> None:
    if gh_json([f"repos/{repo}/branches/{branch}"], runner=runner) is None:
        raise MediaError(
            f"no {branch} branch on {repo}. It holds PR media only; create it before uploading."
        )


def convert(upload: Upload, into: Path, fps: int, width: int, runner=None) -> Path:
    if shutil.which("ffmpeg") is None:
        raise MediaError("ffmpeg is needed to turn an mp4 into a gif; pass --no-gif to skip it")
    destination = into / upload.name
    done = (runner or subprocess.run)(gif_argv(upload.local, destination, fps, width),
                                      capture_output=True, text=True)
    if done.returncode != 0:
        raise MediaError(f"ffmpeg failed on {upload.local.name}: {(done.stderr or done.stdout).strip()}")
    if not destination.exists() or destination.stat().st_size == 0:
        raise MediaError(f"ffmpeg wrote no gif for {upload.local.name}")
    return destination


def comment_on_pr(pr: int, repo: str, body: str, runner=None) -> None:
    done = (runner or subprocess.run)(["gh", "pr", "comment", str(pr), "--repo", repo, "--body-file", "-"],
                  input=body, capture_output=True, text=True)
    if done.returncode != 0:
        raise MediaError(f"posting the comment failed: {(done.stderr or done.stdout).strip()}")


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("files", nargs="+", metavar="FILE",
                        help="clips or screenshots, or a directory holding them")
    parser.add_argument("--pr", type=int, required=True, help="pull request number; also the folder name")
    parser.add_argument("--repo", default=REPO)
    parser.add_argument("--branch", default=BRANCH)
    parser.add_argument("--label", help="caption for a single file (otherwise taken from the name)")
    parser.add_argument("--no-gif", dest="gif", action="store_false",
                        help="upload an mp4 without also making a gif")
    parser.add_argument("--gif-fps", type=int, default=DEFAULT_GIF_FPS)
    parser.add_argument("--gif-width", type=int, default=DEFAULT_GIF_WIDTH)
    parser.add_argument("--comment", action="store_true", help="post the Markdown to the PR as a comment")
    parser.add_argument("--dry-run", action="store_true",
                        help="print the plan and the Markdown; upload nothing")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None, runner=None) -> int:
    args = parse_args(argv)
    if args.pr <= 0:
        print("pr-media: --pr must be a pull request number", file=sys.stderr)
        return 2
    try:
        uploads = plan(collect(args.files), args.pr, args.label, args.gif)
        for upload in uploads:
            print(f"plan {upload.kind:>5}  {remote_path(args.pr, upload.name)}"
                  + (f"  (from {upload.local.name})" if upload.source_name else ""))
        if args.dry_run:
            print()
            print(markdown(uploads, args.pr, args.repo, args.branch), end="")
            return 0

        require_branch(args.repo, args.branch, runner=runner)
        warnings: list[str] = []
        with tempfile.TemporaryDirectory(prefix="pr-media-") as scratch:
            for upload in uploads:
                path = convert(upload, Path(scratch), args.gif_fps, args.gif_width, runner=runner) \
                    if upload.source_name else upload.local
                warnings.extend(check_size(path))
                target = remote_path(args.pr, upload.name)
                put_file(args.repo, args.branch, target, path,
                         f"PR {args.pr} media {upload.name}", runner=runner)
                print(f"uploaded {target}")
        body = markdown(uploads, args.pr, args.repo, args.branch)
        if args.comment:
            comment_on_pr(args.pr, args.repo, body, runner=runner)
            print(f"commented on {args.repo}#{args.pr}")
        print()
        print(body, end="")
        for warning in warnings:
            print(f"note: {warning}", file=sys.stderr)
    except MediaError as error:
        print(f"pr-media: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
