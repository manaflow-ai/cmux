#!/usr/bin/env python3
"""Fail a pull request that changes native app UI and shows no real capture of it.

    pr_capture_check.py --body-file BODY --paths-file PATHS [--labels a,b] [--head-sha SHA]

A change is native UI when scripts/cmux-next/media/path_map.py maps one of its paths (tests
aside) to a Mac tour: the app's Swift sources and resources, cmux themes, the Home sidebar, a
tour file. Webview-only changes are left to the gallery advisory run, which captures them.

Real capture, any one of:
  - the marker `cmux-ci capture` prints into the body, `<!-- cmux-capture sha=<40 hex> ...-->`,
    with an image from this pull request's pr-media folder right after it (a fleet build, driven
    on a capture mini, text-checked);
  - the `media-tour` or `media-tour-mac` label (adding `media-tour` makes cmux-next-media.yml
    tour the head at that moment on a Mac and post the shots in the status comment; a later
    push does not tour again, so re-add the label or run `cmux-ci capture` for a newer head;
    the label is taken on trust, the tour reports itself);
  - a line saying why none applies: `No capture: <reason>` (a refactor with no visible change).

A capture of an older commit passes with a warning. Prints GitHub annotations; exits 1 when the
change is native UI and none of the above is there, 0 otherwise (2 on bad input).
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "cmux-next" / "media"))
import path_map  # noqa: E402

TOUR_LABELS = {"media-tour", "media-tour-mac"}
MARKER = re.compile(r"<!--\s*cmux-capture\s+sha=(?P<sha>[0-9a-f]{40})\b[^>]*-->")
MEDIA = "https://raw.githubusercontent.com/manaflow-ai/cmux/pr-media/{pr}/" + r"\S+\.(?:png|gif|jpe?g)"
MEDIA_WINDOW = 2000  # the stills follow the marker; an image elsewhere in the body is not its capture
NO_CAPTURE = re.compile(r"^\s*(?:>\s*)*(?:[-*]\s+)?(?:\*\*)?No capture(?:\*\*)?(?:[ \t]*:|[ \t]+[—-])[ \t]*(?:\*\*)?[ \t]*\S.{3,}",
                        re.IGNORECASE | re.MULTILINE)
TEST_PATH = re.compile(r"(?:^|/)Tests?/|(?:^|/)tests?/|_test\.|(?:^|/)\w+Tests\.swift$|\.(?:test|spec)\.[jt]sx?$")
# A fenced block, or an unclosed fence to the end of the body.
FENCE = re.compile(r"^\s{0,3}(```|~~~).*?(?:^\s{0,3}\1|\Z)", re.DOTALL | re.MULTILINE)
COMMENT = re.compile(r"<!--.*?-->", re.DOTALL)
INLINE_CODE = re.compile(r"`[^`\n]+`")
COMMAND = "cmux-ci capture {sha} --state tour:{tour} --pr {pr}"


def ui_tours(paths: list[str]) -> list[str]:
    """The Mac tours the change's non-test paths map to; empty when it touches no native UI."""
    result = path_map.map_paths([p for p in paths if not TEST_PATH.search(p)])
    return list(result["tours"]) if result["is_ui"] else []


def evidence(body: str, labels: set[str], pr: str = "") -> tuple[str, str | None]:
    """(how the PR shows a real capture or says why not, the captured sha), or ("", None)."""
    text = FENCE.sub("", body or "")  # an example in a code block is not a capture
    media = re.compile(MEDIA.format(pr=pr if pr.isdigit() else r"\d+"))
    for marker in MARKER.finditer(text):
        after = text[marker.end():marker.end() + MEDIA_WINDOW]
        if media.search(INLINE_CODE.sub("", COMMENT.sub("", after))):
            return "capture", marker.group("sha")
    if labels & TOUR_LABELS:
        return "media tour label", None
    if NO_CAPTURE.search(COMMENT.sub("", text)):
        return "no-capture reason", None
    return "", None


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--body-file", type=Path, required=True)
    ap.add_argument("--paths-file", type=Path, required=True)
    ap.add_argument("--labels", default="")
    ap.add_argument("--head-sha", default="")
    ap.add_argument("--pr", default="N")
    a = ap.parse_args(argv)
    try:
        body = a.body_file.read_text(encoding="utf-8")
        paths = [p.strip() for p in a.paths_file.read_text(encoding="utf-8").splitlines() if p.strip()]
    except OSError as error:
        print(f"::error::pr capture check: {error}")
        return 2
    tours = ui_tours(paths)
    if not tours:
        print("No native UI change: no capture needed.")
        return 0
    how, sha = evidence(body, {l.strip() for l in a.labels.split(",") if l.strip()}, a.pr)
    if how:
        print(f"Native UI change ({', '.join(tours)}); shown by: {how}.")
        if sha and a.head_sha and sha != a.head_sha:
            print(f"::warning::The capture is of {sha[:12]}, not the head {a.head_sha[:12]}. "
                  "Capture again if the UI changed since.")
        return 0
    sha = a.head_sha or "<head sha>"
    commands = "\n".join("  " + COMMAND.format(sha=sha, tour=t, pr=a.pr) for t in tours[:3])
    print(f"::error title=No real capture::This changes native app UI ({', '.join(tours)}) and the description "
          "has no real capture. Paste what `cmux-ci capture` prints (a fleet build on a capture mini, light "
          "and dark, text-checked), add the media-tour label, or write `No capture: <why>`.")
    print("Native UI paths:\n" + "\n".join("  " + p for p in paths if path_map.tours_for_path(p)
                                           and not TEST_PATH.search(p))[:4000])
    print("Capture with (cmux-ci capture --list-states lists scenes and tours):\n" + commands)
    return 1


if __name__ == "__main__":
    sys.exit(main())
