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

A gif or screenshot has to stay under 5 MiB, the limit of the proxy GitHub
renders an inline image through; past it a reader sees a broken image, so the
upload is refused instead. Lower `--gif-fps` or `--gif-width`, or record less.
An mp4 is only linked, so it is allowed to be larger.

Nothing already on the branch is replaced without `--force`, and the run names
the blob it replaced. Every file is converted and measured before the first
upload, so a file the tool refuses cannot leave the earlier ones stranded.

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
# An image in a PR body is proxied by Camo, which refuses anything past 5 MiB
# and leaves the reader a broken image. So an inline gif or screenshot stops
# there: uploading it would look like it worked and render like it did not.
INLINE_WARN_BYTES = 3 * 1024 * 1024
INLINE_MAX_BYTES = 5 * 1024 * 1024
# An mp4 is only ever linked, so it is fetched on purpose and Camo is not in
# the way. It still has a ceiling: the branch is read by every PR linking it.
FILE_WARN_BYTES = 8 * 1024 * 1024
FILE_MAX_BYTES = 25 * 1024 * 1024

# A branch that holds code is not a place for megabytes of media.
PROTECTED_BRANCHES = ("main", "master")

# Enough of a header to tell what a file actually is. A caller who renames a
# screenshot to .mp4 gets a clear refusal instead of a one-frame gif.
MAGIC = (
    (b"\x89PNG\r\n\x1a\n", 0, "png"),
    (b"\xff\xd8\xff", 0, "jpeg"),
    (b"GIF87a", 0, "gif"),
    (b"GIF89a", 0, "gif"),
    (b"ftyp", 4, "video"),
)
FAMILY_OF_SUFFIX = {
    ".png": "png", ".jpg": "jpeg", ".jpeg": "jpeg", ".gif": "gif",
    ".mp4": "video", ".mov": "video",
}


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


def family_of_content(path: Path) -> str | None:
    """What the first bytes say the file is, or None when they say nothing."""
    with path.open("rb") as handle:
        head = handle.read(16)
    for magic, offset, family in MAGIC:
        if head[offset:offset + len(magic)] == magic:
            return family
    return None


def require_matching_content(path: Path) -> None:
    """Refuse a file whose header disagrees with its extension.

    Only a header we recognize can disagree: an unknown one is left alone, so
    an unusual but valid container is not refused on a guess.
    """
    found = family_of_content(path)
    expected = FAMILY_OF_SUFFIX.get(path.suffix.lower())
    if found is None or expected is None or found == expected:
        return
    raise MediaError(
        f"{path.name} is a {found} file, not {expected}. Rename it to its real type."
    )


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


def plan(files: list[Path], label: str | None, gif: bool) -> list[Upload]:
    """What goes on the branch, in the order it was asked for.

    An mp4 plans two entries: the mp4 itself and the gif made from it, the gif
    named after it so the pair stays obvious in the folder listing.
    """
    if label and len(files) > 1:
        raise MediaError(
            f"--label names one file, and {len(files)} were given; "
            "upload them one at a time or let the names caption them"
        )
    uploads: list[Upload] = []
    used: set[str] = set()
    for path in files:
        require_matching_content(path)
        name = sanitize(path.name)
        if name in used:
            raise MediaError(f"two files would upload as {name}; rename one")
        used.add(name)
        caption = label or label_for(name)
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


def check_size(path: Path, kind: str) -> list[str]:
    """Refuse a file GitHub would not show; warn before it gets there.

    A gif or screenshot is rendered inline through Camo and has to fit under
    its limit. An mp4 is only linked, so it is allowed to be bigger.
    """
    inline = kind in ("gif", "image")
    ceiling = INLINE_MAX_BYTES if inline else FILE_MAX_BYTES
    warn_at = INLINE_WARN_BYTES if inline else FILE_WARN_BYTES
    size = path.stat().st_size
    megabytes = size / 1024 / 1024
    if size > ceiling:
        limit = f"{ceiling / 1024 / 1024:.0f} MB"
        detail = ("GitHub will not render an image past it, so a reader would see a broken image. "
                  if inline else "")
        raise MediaError(
            f"{path.name} is {megabytes:.1f} MB, over the {limit} limit. {detail}"
            "Record a shorter clip, or lower --gif-fps or --gif-width."
        )
    if size > warn_at:
        return [f"{path.name} is {megabytes:.1f} MB; a PR page will be slow to load it"]
    return []


def looks_absent(text: str) -> bool:
    return "404" in text or "Not Found" in text


def looks_like_a_conflict(text: str) -> bool:
    """A write that lost a race: the file moved between the read and the PUT."""
    return "409" in text or "but expected" in text or "wasn't supplied" in text


def gh_read(args: list[str], runner=None, absent_ok: bool = False) -> dict | None:
    """A `gh api` read.

    A failure is a failure: it returns None only for a 404 the caller asked to
    treat as an absence. Collapsing every failure into None once meant a bad
    token or a typo'd repository was reported as "the media branch does not
    exist, create it", which is advice that overwrites a shared branch.
    """
    done = (runner or subprocess.run)(["gh", "api", *args], capture_output=True, text=True)
    if done.returncode == 0:
        try:
            parsed = json.loads(done.stdout)
        except json.JSONDecodeError as error:
            raise MediaError(f"gh api {args[0]} returned something that is not JSON: {error}") from error
        return parsed if isinstance(parsed, dict) else None
    said = (done.stderr or done.stdout).strip() or f"exit status {done.returncode}"
    if absent_ok and looks_absent(said):
        return None
    raise MediaError(f"gh api {args[0]} failed: {said}\nCheck `gh auth status` and --repo.")


def contents_path(repo: str, path: str, branch: str | None = None) -> str:
    route = f"repos/{repo}/contents/{urllib.parse.quote(path)}"
    return f"{route}?ref={urllib.parse.quote(branch, safe='')}" if branch else route


def existing_sha(repo: str, branch: str, path: str, runner=None) -> str | None:
    found = gh_read([contents_path(repo, path, branch)], runner=runner, absent_ok=True)
    if found is None:
        return None
    sha = found.get("sha")
    return sha if isinstance(sha, str) else None


def put_file(repo: str, branch: str, path: str, local: Path, message: str,
             runner=None) -> None:
    """Write one file to the branch through the contents API.

    The body goes in on stdin: a base64 megabyte does not fit in an argument
    list, and `gh api -f` would put it there.

    A rejected write is retried once with a freshly read sha, because two
    sessions uploading to this branch at the same time is normal and the loser
    of that race should not lose its clip.
    """
    content = base64.b64encode(local.read_bytes()).decode("ascii")
    sha = existing_sha(repo, branch, path, runner=runner)
    for attempt in (1, 2):
        body: dict[str, str] = {"message": message, "branch": branch, "content": content}
        if sha:
            body["sha"] = sha
        done = (runner or subprocess.run)(
            ["gh", "api", "--method", "PUT", contents_path(repo, path), "--input", "-"],
            input=json.dumps(body), capture_output=True, text=True,
        )
        if done.returncode == 0:
            return
        said = (done.stderr or done.stdout).strip()
        if attempt == 1 and looks_like_a_conflict(said):
            sha = existing_sha(repo, branch, path, runner=runner)
            continue
        raise MediaError(f"upload of {path} failed: {said}")


def require_branch(repo: str, branch: str, runner=None) -> None:
    if gh_read([f"repos/{repo}/branches/{urllib.parse.quote(branch, safe='')}"],
               runner=runner, absent_ok=True) is None:
        raise MediaError(
            f"no {branch} branch on {repo}. It holds PR media only; create it before uploading."
        )


def require_pull_request(pr: int, repo: str, runner=None) -> None:
    """A folder named after a pull request that does not exist is litter."""
    if gh_read([f"repos/{repo}/pulls/{pr}"], runner=runner, absent_ok=True) is None:
        raise MediaError(f"no pull request {pr} on {repo}; check --pr and --repo")


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
    parser.add_argument("--force", action="store_true",
                        help="replace a file already on the branch at the same path")
    parser.add_argument("--dry-run", action="store_true",
                        help="print the plan and the Markdown; upload nothing")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None, runner=None) -> int:
    args = parse_args(argv)
    if args.pr <= 0:
        print("pr-media: --pr must be a pull request number", file=sys.stderr)
        return 2
    uploaded: list[Upload] = []
    uploads: list[Upload] = []
    warnings: list[str] = []
    try:
        if args.branch in PROTECTED_BRANCHES:
            raise MediaError(f"{args.branch} is a code branch; upload media to {BRANCH} instead")
        uploads = plan(collect(args.files), args.label, args.gif)
        for upload in uploads:
            print(f"plan {upload.kind:>5}  {remote_path(args.pr, upload.name)}"
                  + (f"  (from {upload.local.name})" if upload.source_name else ""))
        if args.dry_run:
            # Nothing here reaches the network, so a dry run stays usable
            # without a token; it still measures what it was handed.
            for upload in uploads:
                if not upload.source_name:
                    warnings.extend(check_size(upload.local, upload.kind))
            print()
            print(markdown(uploads, args.pr, args.repo, args.branch), end="")
            report(warnings)
            return 0

        require_branch(args.repo, args.branch, runner=runner)
        require_pull_request(args.pr, args.repo, runner=runner)
        with tempfile.TemporaryDirectory(prefix="pr-media-") as scratch:
            # Convert and measure everything first. A file refused half way
            # through used to leave the earlier ones on the branch with no
            # Markdown naming them.
            ready: list[tuple[Upload, Path]] = []
            for upload in uploads:
                path = convert(upload, Path(scratch), args.gif_fps, args.gif_width, runner=runner) \
                    if upload.source_name else upload.local
                warnings.extend(check_size(path, upload.kind))
                ready.append((upload, path))

            replacing = {
                target: sha
                for upload, _ in ready
                if (target := remote_path(args.pr, upload.name))
                and (sha := existing_sha(args.repo, args.branch, target, runner=runner))
            }
            if replacing and not args.force:
                listed = ", ".join(sorted(replacing))
                raise MediaError(
                    f"already on {args.branch}: {listed}. "
                    "Rename the file, or pass --force to replace it."
                )

            for upload, path in ready:
                target = remote_path(args.pr, upload.name)
                if target in replacing:
                    print(f"replacing {target} (blob {replacing[target]})")
                put_file(args.repo, args.branch, target, path,
                         f"PR {args.pr} media {upload.name}", runner=runner)
                uploaded.append(upload)
                print(f"uploaded {target}")

        body = markdown(uploads, args.pr, args.repo, args.branch)
        # Printed before the comment is attempted: a refused comment must not
        # take the Markdown with it.
        print()
        print(body, end="")
        if args.comment:
            comment_on_pr(args.pr, args.repo, body, runner=runner)
            print(f"commented on {args.repo}#{args.pr}")
        report(warnings)
    except (MediaError, OSError) as error:
        print(f"pr-media: {error}", file=sys.stderr)
        if uploaded and len(uploaded) < len(uploads):
            print()
            print(f"partial upload; Markdown for what landed on {args.branch}:")
            print(markdown(uploaded, args.pr, args.repo, args.branch), end="")
        report(warnings)
        return 1
    return 0


def report(warnings: list[str]) -> None:
    for warning in warnings:
        print(f"note: {warning}", file=sys.stderr)


if __name__ == "__main__":
    sys.exit(main())
