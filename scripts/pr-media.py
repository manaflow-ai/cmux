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

The gif is smooth by default: 30 fps, or 50 when the clip itself runs that fast
(a gif cannot play faster: its frame delays are hundredths of a second and
browsers play a 1/100 s delay as 1/10 s, so a "60 fps" gif shows about 10).
It never goes above the clip's own rate, so no frame is repeated. A gif or
screenshot has to stay under 5 MiB, the limit of the proxy GitHub renders an
inline image through, so a gif past it is made again narrower and then at a
lower frame rate until it fits (gif_attempts). Only a gif that still does not
fit at the smallest step, or a screenshot past it, is refused. An mp4 is only
linked, so it is allowed to be larger.

Nothing already on the branch is replaced without `--force`, and the run names
the blob it replaced. Every file is converted and measured before the upload,
and the whole batch lands as one commit, so a file the tool refuses cannot
leave the earlier ones stranded.

Every file goes through the shared privacy check (scripts/ci/pr_media_privacy.py)
before the first upload, the gif made from an mp4 included: a capture that
shows a private machine or account name is refused, in any pull request, and
nothing is uploaded; the message names the name's category and how to fix it.
`put_file()` runs the same check on each file for the tools that import it
(scripts/cmux-next/media/publish.py and reel.py check their whole batch first).
A refusal is never retried. In GitHub Actions the check refuses unless the
step runs inside .github/actions/pr-media-publish, the one publishing step: it
brings the pr-media environment's private-terms list and an OCR tool, so a CI
writer never falls back to the built-in patterns with its images unread.

Conversion needs ffmpeg. The branch is read and written with git first (see
MediaBranch): the host's ssh key or credential helper, or GH_TOKEN in CI. When
git cannot reach or authenticate to the remote (a host where only `gh` is
logged in, a network failure), the same reads and the one-commit write go
through `gh api graphql` instead (ApiBranch), never a `contents/` read.
`--comment` uses `gh` too. `--dry-run` resolves the whole plan and prints it
without running either; it still runs the privacy check on the files as given
(no gif yet).
"""

from __future__ import annotations

import argparse
import base64
import contextlib
import fcntl
import importlib.util
import json
import math
import os
import random
import re
import shutil
import subprocess
import sys
import tempfile
import time
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

# Leo, 2026-10-31, on 4 and then 10-15 fps previews: "WHY ... IS IT NOT 30/60/120". A gif's frame delays are
# hundredths of a second, and browsers play a delay of 1/100 s or less as 1/10 s, so 50 fps (2/100 s) is the
# fastest a gif really plays; a "60 fps" gif would show about 10. So a clip recorded at 50 fps or more makes a
# 50 fps gif when it fits, anything else 30, and a gif over the inline limit steps down this ladder.
DEFAULT_GIF_FPS = 30
GIF_MAX_FPS = 50
GIF_FPS_LADDER = (50, 30, 24, 20, 15, 12, 10)
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


class PrivacyError(MediaError):
    """The privacy check refused the files or could not run; a retry gets the same answer."""


class GitTransportError(MediaError):
    """git could not reach or authenticate to the remote (or timed out). GitHub's GraphQL API may still answer
    the same question, so the module-level reads and writes fall back to ApiBranch on this error alone."""


# The one privacy check shared by every pr-media writer; it lives in scripts/ci.
PRIVACY_MODULE = Path(__file__).resolve().parent / "ci" / "pr_media_privacy.py"
_privacy = None


def privacy_module():
    """scripts/ci/pr_media_privacy.py, loaded once. A checkout without it refuses
    to upload rather than skipping the check."""
    global _privacy
    if _privacy is None:
        spec = importlib.util.spec_from_file_location("cmux_pr_media_privacy", PRIVACY_MODULE)
        if not PRIVACY_MODULE.is_file() or spec is None or spec.loader is None:
            raise PrivacyError(f"the privacy check {PRIVACY_MODULE} is missing; nothing is uploaded without it. "
                             "Add scripts/ci/pr_media_privacy.py (and pr_media_ocr.swift) to a sparse checkout.")
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module
        spec.loader.exec_module(module)
        _privacy = module
    return _privacy


# In GitHub Actions every pr-media write goes through this composite action. It
# gives the check the pr-media environment's private-terms list and an OCR tool
# (tesseract on Linux, Vision on macOS) and sets PUBLISH_GATE for its command.
PUBLISH_ACTION = ".github/actions/pr-media-publish"
PUBLISH_GATE = "PR_MEDIA_PUBLISH_GATE"


def require_publish_gate(privacy, items: list[tuple[str, Path]], env, ocr_given: bool) -> None:
    """In GitHub Actions, refuse unless the publishing action set this step up.

    Off CI the check reads this machine's terms file and names and Vision, as
    before. In CI a step that skipped the action would check with the built-in
    patterns only and skip every image, so it writes nothing instead.
    """
    if env.get("GITHUB_ACTIONS") != "true":
        return
    if env.get(PUBLISH_GATE) != "1":
        raise PrivacyError(f"in GitHub Actions pr-media is written only through {PUBLISH_ACTION}, "
                           "which loads the private-terms list and an OCR tool; this step does not use it")
    if not env.get("PR_MEDIA_PRIVATE_TERMS", "").strip():
        raise PrivacyError("no private-terms list (PR_MEDIA_PRIVATE_TERMS): the job needs `environment: pr-media`")
    media = any(Path(remote).suffix.lower() in privacy.MEDIA_SUFFIXES for remote, _local in items)
    if media and not ocr_given and privacy.ocr_binary(env) is None:
        raise PrivacyError("no OCR tool, so images would go unread; nothing is uploaded")


def check_privacy(items: list[tuple[str, Path]], repo: str, **options) -> None:
    """Run the shared pre-push check on (path on the branch, local file) pairs.

    Raises PrivacyError when a file is refused; the message names paths and kinds,
    never the text it matched. options go to check_upload (env, ocr, lookup,
    out); tests replace this module-level hook. In GitHub Actions the step must
    run inside PUBLISH_ACTION (require_publish_gate).
    """
    privacy = privacy_module()
    require_publish_gate(privacy, items, options.get("env", os.environ), "ocr" in options)
    try:
        privacy.check_upload(items, repo, **options)
    except privacy.Refused as refused:
        raise PrivacyError(str(refused)) from None
    except privacy.BadInput as error:
        raise PrivacyError(f"privacy check: {error}") from None


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


def gif_widths(width: int) -> tuple[int, ...]:
    """The width and two narrower steps, even (a palette gif needs no even width, but the scale stays tidy)."""
    steps = (width, round(width * 0.8) // 2 * 2, round(width * 0.62) // 2 * 2)
    return tuple(dict.fromkeys(step for step in steps if step > 0))


def gif_attempts(widths: tuple[int, ...], fps: int | None = None,
                 source_rate: float | None = None) -> list[tuple[int, int]]:
    """(fps, width) pairs to encode in order until one fits under the inline limit.

    With no `fps`, a clip at 50 fps or more starts at GIF_MAX_FPS and anything else at DEFAULT_GIF_FPS. A rate
    above the default is tried only at full width (a bonus when it fits); the first rate at or under it is tried
    at every width, so the gif gets narrower before it gets choppier; lower rates use the narrowest width. No
    rate goes above the clip's own (`source_rate`), so a slow clip's frames are never repeated.
    """
    if fps is None:
        fps = GIF_MAX_FPS if source_rate and source_rate >= GIF_MAX_FPS else DEFAULT_GIF_FPS
    fps = max(1, min(fps, GIF_MAX_FPS))
    ceiling = max(1, math.ceil(source_rate)) if source_rate else None
    attempts: list[tuple[int, int]] = []
    widened = False
    for rate in (fps, *(step for step in GIF_FPS_LADDER if step < fps)):
        if ceiling:
            rate = min(rate, ceiling)
        if rate > DEFAULT_GIF_FPS:
            these = widths[:1]
        elif not widened:
            these, widened = widths, True
        else:
            these = widths[-1:]
        attempts.extend(pair for width in these if (pair := (rate, width)) not in attempts)
    return attempts


def source_fps(path: Path, runner=None, env: dict[str, str] | None = None) -> float | None:
    """The clip's frame rate from ffprobe, or None when it cannot be read (then the gif starts at the default)."""
    if shutil.which("ffprobe") is None:
        return None
    try:
        done = (runner or subprocess.run)(
            ["ffprobe", "-v", "error", "-select_streams", "v:0",
             "-show_entries", "stream=r_frame_rate,avg_frame_rate", "-of", "json", str(path)],
            capture_output=True, text=True, env=env if env is not None else tool_env())
        stream = json.loads(done.stdout or "{}").get("streams", [{}])[0]
    except (OSError, ValueError, IndexError, AttributeError):
        return None
    for key in ("r_frame_rate", "avg_frame_rate"):
        numerator, _, denominator = str(stream.get(key, "")).partition("/")
        try:
            rate = float(numerator) / float(denominator or 1)
        except (ValueError, ZeroDivisionError):
            continue
        # A variable-rate clip can report its timebase (90000/1) as r_frame_rate; that is not a frame rate.
        if 0 < rate <= 240:
            # The average undercounts a variable-rate screen capture (no frame while nothing moves), so it
            # never caps the gif below the default.
            return rate if key == "r_frame_rate" else max(rate, float(DEFAULT_GIF_FPS))
    return None


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


# Every read and write of the media branch goes through git first, never the REST API: on agent hosts the
# glaeda-gh shim refuses a `contents/` read of a repository checked out there, and gh-quota refuses REST
# reads with no GraphQL equivalent (`branches/`, `pulls/N`) and every REST write once the shared quota
# runs low, which stopped every `cmux-ci capture --pr` upload (2026-10-30). Git spends none of that quota.
#
# The writer is a bare, shallow (depth 1), blob-less clone that tracks only the media branch, kept in the
# user's cache dir (PR_MEDIA_CACHE_DIR, default $XDG_CACHE_HOME/cmux-pr-media) and reused by every run on
# the host: fetching the branch tip costs its trees (about 1 MB for two thousand pull requests' folders),
# never the media in it. An upload builds one commit on the fetched tip with `git mktree --missing`, so no
# blob already on the branch is ever read or fetched, and pushes it without force; a push that lost a race
# (the branch moved) fetches the new tip and builds the commit again. One flock per clone serializes the
# runs on a host. PR_MEDIA_REMOTE_URL overrides the remote (tests point it at a local repository).
PUSH_ATTEMPTS = 6
CACHE_ENV = "PR_MEDIA_CACHE_DIR"
REMOTE_ENV = "PR_MEDIA_REMOTE_URL"
GIT_TIMEOUT = 300
# What a lost race looks like from `git push`: built again on the new tip and retried, and final (not a reason
# to try the API) once the attempts run out.
PUSH_RACE = re.compile(r"non-fast-forward|fetch first|cannot lock ref|failed to update ref|incorrect old value")
# A GitHub hiccup: retried, then handed to the API like any other transport failure.
PUSH_TRANSIENT = re.compile(r"HTTP 50[0234]|RPC failed|remote end hung up|early EOF|Connection reset|timed out")
# The remote answered and refused the push (a protected branch, a hook): the API would be refused the same way,
# so this is final and never retried.
PUSH_REFUSED = re.compile(r"\[remote rejected\]|hook declined")
DEFAULT_IDENTITY = ("cmux pr-media", "pr-media@users.noreply.github.com")


def cache_root() -> Path:
    explicit = os.environ.get(CACHE_ENV)
    if explicit:
        return Path(explicit)
    return Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache") / "cmux-pr-media"


# The userinfo of an http(s) or ssh URL: `user:secret@` or `token@`.
URL_USERINFO = re.compile(r"(?i)\b((?:https?|ssh)://)[^/@\s]+@")


def without_userinfo(url: str) -> str:
    """URL with any `user:password@` or `token@` of an http(s) URL dropped, so a secret in a clone's origin
    never reaches a command line, the cache clone's config or an error message; git's credential helper
    (or GH_TOKEN, credential_args) authenticates instead. An ssh or scp-like URL keeps its user (`git@`)."""
    if re.match(r"(?i)https?://", url):
        return URL_USERINFO.sub(r"\1", url, count=1)
    return url


def redact(text: str) -> str:
    """TEXT with the userinfo of every http(s) or ssh URL in it replaced, for error messages."""
    return URL_USERINFO.sub(r"\1***@", text)


def remote_url(repo: str) -> str:
    """Where the media branch lives. The origin URL of a local clone of REPO when there is one (this host
    already authenticates that way, often over ssh), else https. It may carry an http(s) credential, which
    MediaBranch keeps out of arguments, config files and messages (url_credential_env)."""
    explicit = os.environ.get(REMOTE_ENV)
    if explicit:
        return explicit
    for candidate in (Path.cwd(), Path.home() / "Projects" / "cmux"):
        done = subprocess.run(["git", "-C", str(candidate), "remote", "get-url", "origin"],
                              capture_output=True, text=True)
        url = done.stdout.strip()
        if done.returncode == 0 and origin_is(url, repo):
            return url
    return f"https://github.com/{repo}.git"


def origin_is(url: str, repo: str) -> bool:
    """Whether URL is github.com's REPO (https, ssh or scp-like form, with or without `.git`)."""
    match = re.fullmatch(r"(?:https?://(?:[^@/]+@)?|ssh://(?:[^@/]+@)?|[^@/:]+@)github\.com[:/]"
                         r"([^/]+/[^/]+?)(?:\.git)?/?", url.strip())
    return bool(match) and match.group(1).lower() == repo.lower()


def git_env(secret_url: str | None = None, url: str | None = None) -> dict[str, str]:
    env = {**os.environ, "GIT_TERMINAL_PROMPT": "0",
           # A blob the branch already holds is never needed here; if something did ask for one, fail rather
           # than download it.
           "GIT_NO_LAZY_FETCH": "1"}
    if secret_url and url and secret_url != url:
        env.update(url_credential_env(env, secret_url, url))
    return env


# Answers git's credential request from two environment variables, so no secret is in its text.
URL_CREDENTIAL_HELPER = ('!f() { test "$1" = get || exit 0; echo "username=$PR_MEDIA_URL_USERNAME"; '
                         'echo "password=$PR_MEDIA_URL_PASSWORD"; }; f')


def url_credential_env(env: dict[str, str], secret_url: str, url: str) -> dict[str, str]:
    """The credential in SECRET_URL's userinfo, handed to git for URL alone by a credential helper that reads
    it from this child's environment (PR_MEDIA_URL_USERNAME, PR_MEDIA_URL_PASSWORD): a host whose only
    credential is in its origin URL authenticates as before, and the secret is in no process's arguments
    (git passes a rewritten URL to git-remote-https as one), no config file and no message. The helper is
    set through GIT_CONFIG_COUNT, after any config already given that way. A token alone (`TOKEN@`) is
    GitHub's x-access-token form."""
    userinfo = re.match(r"(?i)https?://([^/@\s]+)@", secret_url)
    if not userinfo:
        return {}
    user, colon, password = userinfo.group(1).partition(":")
    user, password = urllib.parse.unquote(user), urllib.parse.unquote(password)
    if not colon:
        user, password = "x-access-token", user
    # Scoped to the remote's scheme and host: git asks for a host's credential without the path unless
    # credential.useHttpPath is set, and this child process talks to no other repository there. The empty
    # value first drops any helper the host's own config names for it.
    parts = urllib.parse.urlsplit(url)
    scope = f"{parts.scheme}://{parts.netloc}"
    count = int(env.get("GIT_CONFIG_COUNT") or 0)
    return {"PR_MEDIA_URL_USERNAME": user, "PR_MEDIA_URL_PASSWORD": password,
            "GIT_CONFIG_COUNT": str(count + 2),
            f"GIT_CONFIG_KEY_{count}": f"credential.{scope}.helper", f"GIT_CONFIG_VALUE_{count}": "",
            f"GIT_CONFIG_KEY_{count + 1}": f"credential.{scope}.helper",
            f"GIT_CONFIG_VALUE_{count + 1}": URL_CREDENTIAL_HELPER}


def credential_args() -> list[str]:
    """In CI the token is in the environment (the publish action's GH_TOKEN); hand it to git directly rather
    than through `gh auth git-credential`, which a host's gh guard may refuse. Elsewhere git's own
    configuration (an ssh key, a credential helper) authenticates, as it does for any push. The empty value
    first clears the helpers the host already names: git stops at the first helper that answers, so a cached
    account (perhaps one that can't push) would otherwise win over the token."""
    if not (os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")):
        return []
    helper = '!f() { echo username=x-access-token; echo "password=${GH_TOKEN:-$GITHUB_TOKEN}"; }; f'
    return ["-c", "credential.https://github.com.helper=", "-c", f"credential.https://github.com.helper={helper}"]


def safe_branch(branch: str) -> str:
    if subprocess.run(["git", "check-ref-format", "--branch", branch], capture_output=True).returncode != 0:
        raise MediaError(f"{branch!r} is not a branch name")
    return branch


def safe_remote_path(path: str) -> list[str]:
    parts = path.split("/")
    if not path or any(part in ("", ".", "..") or "\0" in part for part in parts):
        raise MediaError(f"{path!r} is not a path on the branch")
    return parts


class MediaBranch:
    """The media BRANCH of REPO, read and written with git through the shared cache clone."""

    def __init__(self, repo: str, branch: str, url: str | None = None, root: Path | None = None):
        self.repo, self.branch = repo, safe_branch(branch)
        given = url or remote_url(repo)
        # The URL git is given; any credential in GIVEN reaches git only through git_env (url_credential_env).
        self.url = without_userinfo(given)
        self.secret_url = given if given != self.url else None
        root = root or cache_root()
        self.dir = root / (re.sub(r"[^A-Za-z0-9._-]", "_", repo) + ".git")
        self.lock_path = root / (self.dir.name + ".lock")
        self.tracking = f"refs/remotes/origin/{self.branch}"
        self.tip: str | None = None

    def env(self) -> dict[str, str]:
        return git_env(self.secret_url, self.url)

    def git(self, *args: str, input: str | None = None, cwd: Path | None = None, timeout: float = GIT_TIMEOUT,
            check: bool = True) -> subprocess.CompletedProcess:
        command = ["git", *credential_args(), "-C", str(cwd or self.dir), *args]
        try:
            done = subprocess.run(command, input=input, capture_output=True, text=True, env=self.env(),
                                  timeout=timeout)
        except subprocess.TimeoutExpired as error:
            raise GitTransportError(f"git {args[0]} took longer than {timeout:.0f} s") from error
        if check and done.returncode != 0:
            raise MediaError(redact(f"git {args[0]} failed: {(done.stderr or done.stdout).strip()}"))
        return done

    def git_bytes(self, *args: str, input: bytes | None = None) -> bytes:
        """A local git command whose output is tree records: read and written as bytes, because text mode
        turns a `\r` in a name into `\n` and two names would become one."""
        try:
            done = subprocess.run(["git", "-C", str(self.dir), *args], input=input, capture_output=True,
                                  env=self.env(), timeout=GIT_TIMEOUT)
        except subprocess.TimeoutExpired as error:
            raise MediaError(f"git {args[0]} took longer than {GIT_TIMEOUT:.0f} s") from error
        if done.returncode != 0:
            said = (done.stderr or done.stdout).decode("utf-8", "replace").strip()
            raise MediaError(redact(f"git {args[0]} failed: {said}"))
        return done.stdout

    def ls_remote(self, ref: str) -> str | None:
        """REF's commit on the remote, or None when the remote has no such ref."""
        # Run from the cache dir, not the caller's checkout, so no repository's own config applies.
        self.dir.parent.mkdir(parents=True, exist_ok=True)
        done = self.git("ls-remote", "--exit-code", self.url, ref, cwd=self.dir.parent, check=False, timeout=120)
        if done.returncode == 2:  # --exit-code: the remote answered and has no such ref
            return None
        if done.returncode != 0:
            raise GitTransportError(redact(f"git ls-remote {self.url} failed: "
                                           f"{(done.stderr or done.stdout).strip()}"))
        for line in done.stdout.splitlines():
            sha, _, name = line.partition("\t")
            if name == ref:
                return sha
        return None

    @contextlib.contextmanager
    def locked(self):
        self.lock_path.parent.mkdir(parents=True, exist_ok=True)
        with open(self.lock_path, "a") as handle:
            fcntl.flock(handle, fcntl.LOCK_EX)
            try:
                yield
            finally:
                fcntl.flock(handle, fcntl.LOCK_UN)

    def ensure_clone(self) -> None:
        """Make the cache clone (the caller holds the lock), or point an existing one at this run's URL."""
        if (self.dir / "HEAD").is_file():
            self.git("config", "remote.origin.url", self.url)
            return
        staging = self.dir.with_name(f"{self.dir.name}.new-{os.getpid()}")
        shutil.rmtree(staging, ignore_errors=True)
        self.git("init", "-q", "--bare", str(staging), cwd=self.dir.parent)
        for key, value in (("remote.origin.url", self.url),
                           ("remote.origin.fetch", f"+refs/heads/{self.branch}:{self.tracking}"),
                           ("remote.origin.promisor", "true"),
                           ("remote.origin.partialclonefilter", "blob:none"),
                           ("core.logAllRefUpdates", "false")):
            self.git("config", key, value, cwd=staging)
        staging.rename(self.dir)

    def fetch(self) -> str:
        """Fetch the branch tip (its trees, no blobs) into the cache clone and return it. Caller holds the lock."""
        done = self.git("fetch", "-q", "--no-tags", "--depth", "1", "--filter=blob:none", "origin",
                        f"+refs/heads/{self.branch}:{self.tracking}", check=False)
        if done.returncode != 0:
            said = redact((done.stderr or done.stdout).strip())
            if "couldn't find remote ref" in said:
                raise MediaError(f"no {self.branch} branch on {self.repo}. It holds PR media only; "
                                 "create it before uploading.")
            raise GitTransportError(f"git fetch of {self.branch} failed: {said}")
        self.tip = self.git("rev-parse", "--verify", f"{self.tracking}^{{commit}}").stdout.strip()
        return self.tip

    def blob_sha(self, path: str) -> str | None:
        """PATH's blob on the branch (the sha GitHub's contents API reports), or None when it is not a file
        there. Reads the tip this run fetched first."""
        safe_remote_path(path)
        if self.tip is None:
            with self.locked():
                self.ensure_clone()
                self.fetch()
        entry = self.git_bytes("ls-tree", "-z", self.tip, "--", path).split(b"\0")[0]
        meta, _, named = entry.partition(b"\t")
        fields = meta.split()
        if named != os.fsencode(path) or len(fields) != 3 or fields[1] != b"blob":
            return None
        return fields[2].decode("ascii")

    def tree_with(self, base: str | None, changes: dict[str, str]) -> str:
        """The tree BASE with CHANGES (relative path -> blob) written in, built with `mktree --missing` so
        nothing it leaves alone is read. Names stay bytes end to end, exactly as the branch has them."""
        entries: dict[bytes, tuple[bytes, bytes, bytes]] = {}
        if base:
            for line in self.git_bytes("ls-tree", "-z", base).split(b"\0"):
                if line:
                    meta, _, name = line.partition(b"\t")
                    mode, kind, sha = meta.split()
                    entries[name] = (mode, kind, sha)
        nested: dict[bytes, dict[str, str]] = {}
        for path, blob in changes.items():
            head_text, slash, rest = path.partition("/")
            head = os.fsencode(head_text)
            if slash:
                nested.setdefault(head, {})[rest] = blob
            elif entries.get(head, (b"", b"blob", b""))[1] != b"blob":
                raise MediaError(f"{head_text} is a folder on {self.branch}, not a file")
            else:
                entries[head] = (b"100644", b"blob", blob.encode("ascii"))
        for name, inner in nested.items():
            old = entries.get(name)
            if old and old[1] != b"tree":
                raise MediaError(f"{os.fsdecode(name)} is a file on {self.branch}, not a folder")
            entries[name] = (b"040000", b"tree",
                             self.tree_with(old[2].decode("ascii") if old else None, inner).encode("ascii"))
        listing = b"".join(mode + b" " + kind + b" " + sha + b"\t" + name + b"\0"
                           for name, (mode, kind, sha) in entries.items())
        return self.git_bytes("mktree", "-z", "--missing", input=listing).decode("ascii").strip()

    def identity(self) -> dict[str, str]:
        if self.git("config", "user.email", check=False).stdout.strip():
            return {}
        name, email = DEFAULT_IDENTITY
        return {"GIT_AUTHOR_NAME": name, "GIT_AUTHOR_EMAIL": email,
                "GIT_COMMITTER_NAME": name, "GIT_COMMITTER_EMAIL": email}

    def put(self, files: dict[str, Path], message: str, expect: dict[str, str | None] | None = None) -> str:
        """Write FILES (path on the branch -> local file) as one commit on the branch; return the commit.

        EXPECT (path -> the blob the caller saw there, None for absent) makes the write a compare-and-swap:
        every tip it builds on, the first and each one fetched after a lost race, must still hold exactly
        that, or nothing is written. Without it a run that saw a path free would silently replace a file
        another uploader put there between its check and its push."""
        for path in files:
            safe_remote_path(path)
        with self.locked():
            self.ensure_clone()
            blobs = {path: self.git("hash-object", "-w", "--no-filters", "--", str(local.resolve())).stdout.strip()
                     for path, local in files.items()}
            for attempt in range(1, PUSH_ATTEMPTS + 1):
                tip = self.fetch()
                moved = sorted(path for path, seen in (expect or {}).items() if self.blob_sha(path) != seen)
                if moved:
                    raise MediaError(f"{', '.join(moved)} changed on {self.branch} while this run was uploading "
                                     "(another upload got there first); nothing was written. Check what is "
                                     "there now, then rename the file or pass --force to replace it.")
                tree = self.tree_with(f"{tip}^{{tree}}", blobs)
                env = {**self.env(), **self.identity()}
                commit = subprocess.run(["git", "-C", str(self.dir), "commit-tree", tree, "-p", tip, "-m", message],
                                        capture_output=True, text=True, env=env, timeout=60)
                if commit.returncode != 0:
                    raise MediaError(f"git commit-tree failed: {(commit.stderr or commit.stdout).strip()}")
                # --no-thin: a thin pack deltas against what the remote has, which means reading the blob a
                # replaced file had, and this clone has none (and must not fetch one).
                done = self.git("push", "-q", "--no-thin", "origin",
                                f"{commit.stdout.strip()}:refs/heads/{self.branch}", check=False)
                if done.returncode == 0:
                    self.tip = commit.stdout.strip()
                    return self.tip
                said = redact((done.stderr or done.stdout).strip())
                failed = f"upload of {', '.join(files)} failed: {said}"
                if PUSH_REFUSED.search(said) and not PUSH_RACE.search(said):
                    raise MediaError(failed)
                if PUSH_RACE.search(said):
                    if attempt == PUSH_ATTEMPTS:
                        raise MediaError(failed)
                elif not PUSH_TRANSIENT.search(said) or attempt == PUSH_ATTEMPTS:
                    raise GitTransportError(failed)
                retry_pause(0.5 * attempt + random.random())
        raise AssertionError("unreachable")


def retry_pause(seconds: float) -> None:
    """The wait before a retried push or API write; its own function so a test can count retries without
    patching time.sleep for the whole interpreter (subprocess waits on a child with it)."""
    time.sleep(seconds)


# Where the API fallback runs `gh`; tests point it at a stand-in.
API_RUNNER = None
API_TIMEOUT = 300
API_RACE = re.compile(r"(?i)expected branch to point to|not a fast.forward|reference update failed"
                      r"|HTTP 50[0234]|was submitted too quickly")
API_REF_QUERY = """query($owner: String!, $name: String!, $ref: String!) {
  repository(owner: $owner, name: $name) { ref(qualifiedName: $ref) { target { oid } } }
}"""
API_OBJECT_QUERY = """query($owner: String!, $name: String!, $expression: String!) {
  repository(owner: $owner, name: $name) { object(expression: $expression) { __typename oid } }
}"""
API_PULL_QUERY = """query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) { pullRequest(number: $number) { number } }
}"""
API_COMMIT_MUTATION = """mutation($input: CreateCommitOnBranchInput!) {
  createCommitOnBranch(input: $input) { commit { oid } }
}"""


class ApiBranch:
    """The media BRANCH of REPO through GitHub's GraphQL API, for when git can't reach or authenticate to the
    remote (a host where only `gh` is logged in, a network that drops git). Reads ask for a ref's commit and
    for a path's object id at a fixed commit: no file content, so none is the `contents/` source read the
    host's gh guard refuses, and none spends the REST quota. A write is one createCommitOnBranch with
    expectedHeadOid, so a batch is still one commit and a lost race is retried on the new tip, never forced.
    The ref read turns the broker's 60 s answer cache off (GLAEDA_GH_CACHE_TTL=0): a stale tip would only
    lose every race. Object reads name a commit sha, so a cached answer is still the right one."""

    def __init__(self, repo: str, branch: str, runner=None):
        self.repo, self.branch = repo, safe_branch(branch)
        self.owner, _, self.name = repo.partition("/")
        self.runner = runner

    def graphql(self, query: str, variables: dict, allow_missing: bool = False) -> dict:
        body = json.dumps({"query": query, "variables": variables})
        runner = self.runner or API_RUNNER or subprocess.run
        try:
            done = runner(["gh", "api", "graphql", "--input", "-"], input=body, capture_output=True, text=True,
                          env={**os.environ, "GLAEDA_GH_CACHE_TTL": "0"}, timeout=API_TIMEOUT)
        except subprocess.TimeoutExpired as error:
            raise MediaError(f"gh api graphql took longer than {API_TIMEOUT} s") from error
        except FileNotFoundError as error:
            raise MediaError("gh is not installed") from error
        try:
            answer = json.loads(done.stdout or "{}")
        except json.JSONDecodeError:
            answer = {}
        errors = answer.get("errors") or []
        if allow_missing:
            errors = [error for error in errors if error.get("type") != "NOT_FOUND"]
        if errors or answer.get("data") is None:
            said = "; ".join(str(error.get("message", error)) for error in errors) \
                or (done.stderr or done.stdout or f"exit {done.returncode}").strip()
            raise MediaError(f"gh api graphql failed: {said}")
        return answer["data"]

    def ref_tip(self, ref: str) -> str | None:
        data = self.graphql(API_REF_QUERY, {"owner": self.owner, "name": self.name, "ref": ref})
        found = (data.get("repository") or {}).get("ref")
        return found["target"]["oid"] if found else None

    def tip(self) -> str:
        tip = self.ref_tip(f"refs/heads/{self.branch}")
        if tip is None:
            raise MediaError(f"no {self.branch} branch on {self.repo}. It holds PR media only; "
                             "create it before uploading.")
        return tip

    def has_pull_request(self, number: int) -> bool:
        data = self.graphql(API_PULL_QUERY, {"owner": self.owner, "name": self.name, "number": number},
                            allow_missing=True)
        return bool((data.get("repository") or {}).get("pullRequest"))

    def entry(self, commit: str, path: str) -> tuple[str, str] | None:
        """(type, oid) of PATH at COMMIT, or None when nothing is there."""
        data = self.graphql(API_OBJECT_QUERY, {"owner": self.owner, "name": self.name,
                                               "expression": f"{commit}:{path}"}, allow_missing=True)
        found = (data.get("repository") or {}).get("object")
        return (found["__typename"], found["oid"]) if found else None

    def blob_sha(self, path: str, commit: str | None = None) -> str | None:
        safe_remote_path(path)
        found = self.entry(commit or self.tip(), path)
        return found[1] if found and found[0] == "Blob" else None

    def put(self, files: dict[str, Path], message: str, expect: dict[str, str | None] | None = None) -> str:
        """FILES as one commit on the branch, as MediaBranch.put: EXPECT is checked on every tip it builds on."""
        for path in files:
            safe_remote_path(path)
        additions = [{"path": path, "contents": base64.b64encode(local.read_bytes()).decode("ascii")}
                     for path, local in files.items()]
        headline, _, rest = message.partition("\n")
        for attempt in range(1, PUSH_ATTEMPTS + 1):
            tip = self.tip()
            for path in files:
                found = self.entry(tip, path)
                if found and found[0] != "Blob":
                    raise MediaError(f"{path} is a folder on {self.branch}, not a file")
                seen = found[1] if found else None
                if expect is not None and path in expect and seen != expect[path]:
                    raise MediaError(f"{path} changed on {self.branch} while this run was uploading "
                                     "(another upload got there first); nothing was written. Check what is "
                                     "there now, then rename the file or pass --force to replace it.")
            commit_message = {"headline": headline}
            if rest.strip():
                commit_message["body"] = rest.strip()
            try:
                data = self.graphql(API_COMMIT_MUTATION, {"input": {
                    "branch": {"repositoryNameWithOwner": self.repo, "branchName": self.branch},
                    "expectedHeadOid": tip, "message": commit_message,
                    "fileChanges": {"additions": additions}}})
            except MediaError as error:
                if attempt == PUSH_ATTEMPTS or not API_RACE.search(str(error)):
                    raise MediaError(f"upload of {', '.join(files)} through the GitHub API failed: {error}") \
                        from None
                retry_pause(0.5 * attempt + random.random())
                continue
            return data["createCommitOnBranch"]["commit"]["oid"]
        raise AssertionError("unreachable")


_BRANCHES: dict[tuple[str, str], MediaBranch] = {}
# Repository and branch -> why git failed, for the rest of the process: once git can't reach the remote, every
# later call goes to the API at once rather than waiting out another timeout.
_GIT_FAILED: dict[tuple[str, str], GitTransportError] = {}


def media_branch(repo: str, branch: str) -> MediaBranch:
    """One MediaBranch per repository and branch in this process, so a run fetches the tip once."""
    key = (repo, branch)
    if key not in _BRANCHES:
        _BRANCHES[key] = MediaBranch(repo, branch)
    return _BRANCHES[key]


def with_fallback(repo: str, branch: str, store: MediaBranch | None, by_git, by_api):
    """BY_GIT(store), or BY_API(ApiBranch) when git can't reach or authenticate to the remote. Every other
    error (a missing branch, a refused push, a race lost too often, a path that is a folder) is final."""
    key = (repo, branch)
    if key not in _GIT_FAILED:
        try:
            return by_git(store or media_branch(repo, branch))
        except GitTransportError as error:
            _GIT_FAILED[key] = error
    failed = _GIT_FAILED[key]
    try:
        return by_api(ApiBranch(repo, branch))
    except MediaError as error:
        raise MediaError(f"{failed}; the GitHub API fallback failed too: {error}") from None


def existing_sha(repo: str, branch: str, path: str, store: MediaBranch | None = None) -> str | None:
    safe_remote_path(path)
    return with_fallback(repo, branch, store, lambda git: git.blob_sha(path), lambda api: api.blob_sha(path))


def put_files(repo: str, branch: str, files: dict[str, Path], message: str, checked: bool = False,
              store: MediaBranch | None = None, expect: dict[str, str | None] | None = None) -> str:
    """Write FILES (path on the branch -> local file) to the branch in one commit.

    Every file goes through the privacy check first unless the caller already checked them (`checked=True`,
    as main() does for its whole batch). A refusal raises PrivacyError before anything is written and is
    never retried. A push that lost a race to another uploader is built again on the new tip and retried a
    bounded number of times. EXPECT makes it a compare-and-swap (MediaBranch.put)."""
    if not checked:
        check_privacy(list(files.items()), repo)
    return with_fallback(repo, branch, store, lambda git: git.put(files, message, expect=expect),
                         lambda api: api.put(files, message, expect=expect))


def put_file(repo: str, branch: str, path: str, local: Path, message: str,
             runner=None, checked: bool = False, store: MediaBranch | None = None) -> None:
    """One file, for the tools that import this (scripts/cmux-next/media/publish.py, reel.py).

    It replaces whatever is at PATH, as the contents-API writer it replaces did (it read the existing sha and
    sent it with the PUT): re-posting a pull request's tour media or a nightly reel overwrites the last copy.
    "Without --force nothing is replaced" is the CLI's rule (main()), not this function's."""
    put_files(repo, branch, {path: local}, message, checked=checked, store=store)


def require_branch(repo: str, branch: str, store: MediaBranch | None = None) -> None:
    ref = f"refs/heads/{safe_branch(branch)}"
    if with_fallback(repo, branch, store, lambda git: git.ls_remote(ref), lambda api: api.ref_tip(ref)) is None:
        raise MediaError(
            f"no {branch} branch on {repo}. It holds PR media only; create it before uploading."
        )


def require_pull_request(pr: int, repo: str, branch: str = BRANCH, store: MediaBranch | None = None) -> None:
    """A folder named after a pull request that does not exist is litter."""
    found = with_fallback(repo, branch, store, lambda git: git.ls_remote(f"refs/pull/{pr}/head") is not None,
                          lambda api: api.has_pull_request(pr))
    if not found:
        raise MediaError(f"no pull request {pr} on {repo}; check --pr and --repo")


# ffmpeg parses media a PR made, so it runs without the publish step's environment (the private terms list,
# GH_TOKEN): only what it needs to find itself, its temp dir, a locale and (for the reel's drawtext cards)
# fontconfig.
TOOL_ENV_KEYS = ("PATH", "HOME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE",
                 "FONTCONFIG_FILE", "FONTCONFIG_PATH", "XDG_CACHE_HOME")


def tool_env() -> dict[str, str]:
    return {key: os.environ[key] for key in TOOL_ENV_KEYS if key in os.environ}


def convert(upload: Upload, into: Path, fps: int | None, width: int, runner=None,
            limit: int = INLINE_MAX_BYTES) -> Path:
    """The gif for an mp4, at the smoothest step of gif_attempts that fits under `limit`.

    `fps` None picks the rate from the clip. When even the last step is too big, that smallest gif is returned
    and check_size refuses it with its message.
    """
    if shutil.which("ffmpeg") is None:
        raise MediaError("ffmpeg is needed to turn an mp4 into a gif; pass --no-gif to skip it")
    run = runner or subprocess.run
    destination = into / upload.name
    rate = source_fps(upload.local, run) if fps is None else None
    for attempt_fps, attempt_width in gif_attempts(gif_widths(width), fps, rate):
        done = run(gif_argv(upload.local, destination, attempt_fps, attempt_width),
                   capture_output=True, text=True, env=tool_env())
        if done.returncode != 0:
            raise MediaError(f"ffmpeg failed on {upload.local.name}: {(done.stderr or done.stdout).strip()}")
        if not destination.exists() or destination.stat().st_size == 0:
            raise MediaError(f"ffmpeg wrote no gif for {upload.local.name}")
        if destination.stat().st_size <= limit:
            break
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
    parser.add_argument("--gif-fps", type=int, default=None,
                        help=f"starting gif frame rate (default: {GIF_MAX_FPS} for a clip that fast, else "
                             f"{DEFAULT_GIF_FPS}; at most {GIF_MAX_FPS}); a gif over the inline limit steps down")
    parser.add_argument("--gif-width", type=int, default=DEFAULT_GIF_WIDTH,
                        help="starting gif width; a gif over the inline limit is made narrower first")
    parser.add_argument("--comment", action="store_true", help="post the Markdown to the PR as a comment")
    parser.add_argument("--force", action="store_true",
                        help="replace a file already on the branch at the same path")
    parser.add_argument("--dry-run", action="store_true",
                        help="print the plan and the Markdown; upload nothing")
    args = parser.parse_args(argv)
    if args.gif_width < 1:
        parser.error("--gif-width must be at least 1")
    if args.gif_fps is not None and args.gif_fps < 1:
        parser.error("--gif-fps must be at least 1")
    return args


def main(argv: list[str] | None = None, runner=None) -> int:
    args = parse_args(argv)
    if args.pr <= 0:
        print("pr-media: --pr must be a pull request number", file=sys.stderr)
        return 2
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
            print("privacy check of the files as given (a gif is checked when it is made):")
            check_privacy([(remote_path(args.pr, upload.name), upload.local)
                           for upload in uploads if not upload.source_name], args.repo)
            print()
            print(markdown(uploads, args.pr, args.repo, args.branch), end="")
            report(warnings)
            return 0

        require_branch(args.repo, args.branch)
        require_pull_request(args.pr, args.repo, args.branch)
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
            # Exactly what will be uploaded, gifs included, before any of it is.
            check_privacy([(remote_path(args.pr, upload.name), path) for upload, path in ready], args.repo)

            replacing = {
                target: sha
                for upload, _ in ready
                if (target := remote_path(args.pr, upload.name))
                and (sha := existing_sha(args.repo, args.branch, target))
            }
            if replacing and not args.force:
                listed = ", ".join(sorted(replacing))
                raise MediaError(
                    f"already on {args.branch}: {listed}. "
                    "Rename the file, or pass --force to replace it."
                )

            for target, sha in sorted(replacing.items()):
                print(f"replacing {target} (blob {sha})")
            # One commit for the whole batch: every file lands, or none does.
            names = ", ".join(upload.name for upload, _ in ready)
            targets = {remote_path(args.pr, upload.name): path for upload, path in ready}
            # Without --force every target must still be free when the commit is built (and rebuilt after a
            # lost race), not only when it was checked above; --force replaces whatever is there then.
            put_files(args.repo, args.branch, targets, f"PR {args.pr} media {names}", checked=True,
                      expect=None if args.force else dict.fromkeys(targets))
            for upload, _ in ready:
                print(f"uploaded {remote_path(args.pr, upload.name)}")

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
        report(warnings)
        return 1
    return 0


def report(warnings: list[str]) -> None:
    for warning in warnings:
        print(f"note: {warning}", file=sys.stderr)


if __name__ == "__main__":
    sys.exit(main())
