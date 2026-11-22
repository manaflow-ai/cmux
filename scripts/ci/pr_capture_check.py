#!/usr/bin/env python3
"""Warn on a pull request that changes native app UI and shows no real capture of it.

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
  - this pull request's own pr-media stills in the body (an image under
    raw.githubusercontent.com/manaflow-ai/cmux/pr-media/<this PR>/, outside code and comments) with no
    marker: what `pr-media` uploads for a lane that cannot capture itself (a lane VM), or for a capture
    whose marker was not pasted (#27786 was failed with four of its own stills in the body). It is not
    tied to a commit, so it passes with a warning to capture again if the UI changed since;
  - a line saying why none applies: `No capture: <reason>` (a refactor with no visible change).

When a capture, a label or pr-media stills show the change, the description must also say that
the after image was viewed and include a one-sentence visual verdict.

A capture of an older commit passes with a warning. Prints GitHub annotations and never blocks a
land: a missing capture or missing review lines is a `::warning title=...` annotation and the
check exits 0 (2 only on bad input). Leo, 2026-10-31, on UI PRs held for capture rounds: "I T
HOGHT WE ALREADY FUCKING DID THESE WE DONT NEED FUCKIGN SCREENSHOTS JUST LET ME TRY THE SHIT OUT".
The landing tools count a red pr-capture-check as the PR's own red, so a failing exit here would
block the land.
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
# Treat an unterminated comment as hidden through the end of the body too.
COMMENT = re.compile(r"<!--.*?(?:-->|\Z)", re.DOTALL)
INLINE_CODE = re.compile(r"`[^`\n]+`")
COMMAND = "cmux-ci capture {sha} --state tour:{tour} --pr {pr}"
VIEWED_AFTER = re.compile(
    r"^\s*(?:>\s*)*(?:[-*]\s+)?(?:\*\*)?Viewed after image(?:\*\*)?[ \t]*:[ \t]*yes[ \t]*$",
    re.IGNORECASE | re.MULTILINE,
)
VISUAL_VERDICT = re.compile(
    r"^\s*(?:>\s*)*(?:[-*]\s+)?(?:\*\*)?Visual verdict(?:\*\*)?[ \t]*:[ \t]*(?P<verdict>\S(?:.*\S)?)[ \t]*$",
    re.IGNORECASE | re.MULTILINE,
)
VERDICT_PLACEHOLDER = "<one sentence: would Leo accept this next to ChatGPT/Claude?>"
SENTENCE_BOUNDARY = re.compile(
    r"(?P<marks>[.!?]+)(?:[\"')\]]*)\s+(?P<next>[A-Za-z0-9])"
)
ABBREVIATIONS = {"dr", "e", "eg", "etc", "g", "i", "ie", "mr", "mrs", "prof", "s", "vs"}


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
    # This pull request's own pr-media stills with no marker (module docs). Only its own folder counts, and only
    # when the PR number is known: another PR's stills are not this change's.
    if pr.isdigit() and media.search(INLINE_CODE.sub("", COMMENT.sub("", text))):
        return "pr-media stills", None
    return "", None


def visible_markdown(body: str) -> str:
    """Remove HTML comments and Markdown code blocks before matching proof lines."""
    visible: list[str] = []
    fence: tuple[str, int, int] | None = None
    in_comment = False
    html_code: str | None = None

    def quote_content(line: str) -> tuple[int, str]:
        depth = 0
        while quote := re.match(r"^ {0,3}>[ \t]?", line):
            depth += 1
            line = line[quote.end():]
        return depth, line

    for original in (body or "").splitlines(keepends=True):
        depth, content = quote_content(original.rstrip("\n"))
        if html_code is not None:
            if re.search(rf"</{html_code}\s*>", content, re.IGNORECASE):
                html_code = None
            continue
        if fence is not None and depth < fence[2]:
            fence = None  # leaving a blockquote ends its contained code block
        if fence is not None:
            marker = re.match(r"^ {0,3}(`{3,}|~{3,})[ \t]*$", content)
            if (depth == fence[2] and marker and marker.group(1)[0] == fence[0]
                    and len(marker.group(1)) >= fence[1]):
                fence = None
            continue

        # Indented code is literal too: its comment delimiters are not HTML.
        if not in_comment and (content.startswith("    ") or content.startswith("\t")):
            continue

        # Comments are recognized only outside code, so a literal comment opener
        # in a fenced example cannot consume visible proof after the example.
        line = ""
        rest = original
        while rest:
            if in_comment:
                end = rest.find("-->")
                if end < 0:
                    rest = ""
                else:
                    in_comment = False
                    rest = rest[end + 3:]
            else:
                start = rest.find("<!--")
                if start < 0:
                    line += rest
                    rest = ""
                else:
                    line += rest[:start]
                    rest = rest[start + 4:]
                    in_comment = True
        depth, content = quote_content(line.rstrip("\n"))
        html = re.match(r"^ {0,3}<(pre|code|script|style|textarea)(?:[\s>])", content, re.IGNORECASE)
        if html:
            tag = html.group(1).casefold()
            if not re.search(rf"</{tag}\s*>", content, re.IGNORECASE):
                html_code = tag
            continue
        marker = re.match(r"^ {0,3}(`{3,}|~{3,})(.*)$", content)
        if marker and not (marker.group(1)[0] == "`" and "`" in marker.group(2)):
            fence = (marker.group(1)[0], len(marker.group(1)), depth)
            continue
        if content.startswith("    ") or content.startswith("\t"):
            continue
        visible.append(line)
    return "".join(visible)


def visual_judgment(body: str) -> bool:
    """Whether the body records that its after image was viewed and judged."""
    text = visible_markdown(body)
    verdict = VISUAL_VERDICT.search(text)
    if not VIEWED_AFTER.search(text) or not verdict:
        return False
    value = verdict.group("verdict").strip()
    normalized_value = re.sub(r"\s+", " ", value).casefold()
    normalized_placeholder = re.sub(r"\s+", " ", VERDICT_PLACEHOLDER).casefold()
    # Ignore all whitespace while looking for the unchanged prompt. This catches
    # spaces inserted inside the angle-bracket placeholder or around its colon,
    # which otherwise let a cosmetic edit bypass the rejection.
    if re.sub(r"\s+", "", normalized_placeholder) in re.sub(r"\s+", "", normalized_value):
        return False
    # Treat whitespace before template punctuation and an extra trailing period as the
    # same unchanged prompt.  Otherwise a body can bypass the required visual judgment
    # by changing only the spacing before `>` or appending sentence punctuation.
    def normalize_template(text: str) -> str:
        text = re.sub(r"\s+([?!.>,])", r"\1", text)
        return re.sub(r"[.!?]+$", "", text).rstrip()

    if normalize_template(normalized_placeholder) in normalize_template(normalized_value):
        return False
    for boundary in SENTENCE_BOUNDARY.finditer(value):
        marks = boundary.group("marks")
        if set(marks) == {"."} and len(marks) > 1:
            if boundary.group("next").islower():
                continue
        preceding = re.search(r"([A-Za-z]{1,4})$", value[:boundary.start()])
        if not preceding or preceding.group(1).casefold() not in ABBREVIATIONS:
            return False
    return (len(re.findall(r"\b[\w']+\b", value)) >= 2
            and value[-1] in ".!?"
            )


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
        if how in {"capture", "media tour label", "pr-media stills"} and not visual_judgment(body):
            print("::warning title=After image review required::This capture is missing the review proof. "
                  "Add these body lines exactly:\n"
                  "Viewed after image: yes\n"
                  "Visual verdict: <one sentence: would Leo accept this next to ChatGPT/Claude?>\n"
                  "This does not block the land.")
            return 0
        print(f"Native UI change ({', '.join(tours)}); shown by: {how}.")
        if sha and a.head_sha and sha != a.head_sha:
            print(f"::warning::The capture is of {sha[:12]}, not the head {a.head_sha[:12]}. "
                  "Capture again if the UI changed since.")
        if how == "pr-media stills":
            print("::warning::The pr-media stills carry no capture marker, so they name no commit. "
                  "Capture again if the UI changed since they were taken.")
        return 0
    sha = a.head_sha or "<head sha>"
    commands = "\n".join("  " + COMMAND.format(sha=sha, tour=t, pr=a.pr) for t in tours[:3])
    print(f"::warning title=No real capture::This changes native app UI ({', '.join(tours)}) and the description "
          "has no real capture. Paste what `cmux-ci capture` prints (a fleet build on a capture mini, light "
          "and dark, text-checked), add the media-tour label, or write `No capture: <why>`. This does not "
          "block the land: Leo tries the build himself.")
    print("Native UI paths:\n" + "\n".join("  " + p for p in paths if path_map.tours_for_path(p)
                                           and not TEST_PATH.search(p))[:4000])
    print("Capture with (cmux-ci capture --list-states lists scenes and tours):\n" + commands)
    return 0


if __name__ == "__main__":
    sys.exit(main())
