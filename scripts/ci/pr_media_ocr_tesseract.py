#!/usr/bin/env python3
"""Tesseract OCR for the pr-media privacy gate on Linux, where Apple Vision is missing.

The same contract as pr_media_ocr.swift, so scripts/ci/pr_media_privacy.py
takes either as its OCR tool ($PR_MEDIA_PRIVACY_OCR): `pr_media_ocr_tesseract.py
FILE` prints the text recognized in one image, or in one frame per second (plus
the last) of a GIF or video, with an `@@frame N` line before each frame's text.
Identical frames are read once. Exit 2 when nothing could be read, which the
gate holds like a hit.

Each picture is read twice, as a page (`--psm 3`) and as sparse text
(`--psm 11`): UI screenshots mix paragraphs with scattered labels, and each
mode finds lines the other drops. .github/actions/pr-media-publish installs
tesseract and ffmpeg and points the gate here; main's pr-media-privacy.yml
reads the branch again with Vision after the push.
"""

from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

STILLS = frozenset({".png", ".jpg", ".jpeg", ".webp"})
MOVING = frozenset({".gif", ".mp4", ".mov"})
MODES = ("3", "11")
TIMEOUT = 120
# The tools parse media from a pull request's run, so they get no secret or token
# from the publishing step; one thread each, since frames already run in parallel.
TOOL_ENV = {key: value for key, value in os.environ.items() if key in {"PATH", "HOME", "LANG", "TMPDIR"}}
TOOL_ENV["OMP_THREAD_LIMIT"] = "1"


def fail(message: str) -> int:
    print(f"pr-media-ocr: {message}", file=sys.stderr)
    return 2


def read_picture(path: Path) -> list[str]:
    """Lines tesseract reads in one picture, both modes, in first-seen order."""
    # On stdin: Leptonica rewrites a /tmp path to its own temp folder and then misses the file.
    data = path.read_bytes()
    lines: list[str] = []
    for mode in MODES:
        done = subprocess.run(["tesseract", "stdin", "stdout", "--psm", mode], input=data,
                              capture_output=True, timeout=TIMEOUT, env=TOOL_ENV)
        if done.returncode != 0:
            raise RuntimeError(f"tesseract exited {done.returncode}")
        text = done.stdout.decode("utf-8", errors="replace")
        lines += [line.strip() for line in text.splitlines() if line.strip()]
    return list(dict.fromkeys(lines))


def frames(media: Path, into: Path) -> list[Path]:
    """One PNG per second plus the last frame, identical frames dropped."""
    run = ["ffmpeg", "-nostdin", "-v", "error", "-y"]
    subprocess.run([*run, "-i", str(media), "-vf", "fps=1", str(into / "%05d.png")],
                   check=True, capture_output=True, timeout=600, env=TOOL_ENV)
    # The last frame: -update keeps overwriting one file, so it ends as the final frame.
    subprocess.run([*run, "-i", str(media), "-update", "1", str(into / "last.png")],
                   capture_output=True, timeout=600, env=TOOL_ENV)
    seen: set[str] = set()
    distinct = []
    for path in sorted(into.glob("*.png"), key=lambda path: (path.stem == "last", path.name)):
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        if digest not in seen:
            seen.add(digest)
            distinct.append(path)
    return distinct


def main(argv: list[str]) -> int:
    if len(argv) != 1:
        return fail("usage: pr_media_ocr_tesseract.py FILE")
    media = Path(argv[0])
    if not media.is_file():
        return fail(f"not a file: {media.name}")
    if not shutil.which("tesseract"):
        return fail("tesseract is not installed")
    suffix = media.suffix.lower()
    try:
        if suffix in STILLS:
            print("\n".join(read_picture(media)))
            return 0
        if suffix not in MOVING:
            return fail(f"not an image or video: {media.name}")
        if not shutil.which("ffmpeg"):
            return fail("ffmpeg is not installed")
        with tempfile.TemporaryDirectory(prefix="pr-media-ocr-") as scratch:
            pictures = frames(media, Path(scratch))
            if not pictures:
                return fail(f"no readable frames in {media.name}")
            with ThreadPoolExecutor(max_workers=max(1, os.cpu_count() or 1)) as pool:
                for index, lines in enumerate(pool.map(read_picture, pictures)):
                    print(f"@@frame {index}")
                    if lines:
                        print("\n".join(lines))
        return 0
    except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
        return fail(f"could not read {media.name} ({type(error).__name__})")


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
