#!/usr/bin/env python3
"""Signed release notes for the cmux-next in-app changelog (R114).

Each published build gets `notes/<build>.json` and a detached Ed25519
signature `notes/<build>.json.sig` (base64, the `content-signing` key), plus
a signed `notes/index.json` listing recent builds for the full history.

The notes also carry the build's What's New digest ("whatsNew", decision
WHATS-NEW-AFTER-UPDATE W3; scripts/whats-new/digest.py) built from the same
highlight files, when they validate, or from the short user-facing summary
when the build has no valid highlight digest.

Highlights are human-written: one Markdown file per highlight under
release-notes/next/highlights/. A highlight belongs to the first build whose
commit range adds its file, so writing the file is all a person does. Front
matter (lines before the first blank line):

    title: Updates you barely notice
    action: palette.checkForUpdates | Try it      (optional "Try it" button)
    clip: https://raw.githubusercontent.com/manaflow-ai/cmux/pr-media/whats-new/ID/HASH.webp | SHA256
                                                  (optional; written by media/whats-new-clips.py)

A highlight's clip is its looping demo (scripts/cmux-next/media/whats-new-clips.py records it from
release-notes/next/clips/ID.json, whose caption becomes its alt). It wins over --pr-media's picture,
and a clip added to a highlight of the last CLIP_REANNOUNCE_DAYS rides along with the next build (its
highlights and its What's New digest), so an update that already listed the item shows it again with
its clip (the page keeps one copy). A malformed clip line is left out with a report.

The rest is the body (Markdown). A build with no new highlight file uses its
user-facing summary for the What's New digest. Each commit is
also an item {title, author, pr} (newest first; pr from a "(#1234)" suffix)
for the update card's "What's changed" popover; older notes without items
still decode, and the app then reads the PR from each subject.

The notes also carry "summary": at most SUMMARY_LIMIT user-facing lines
{group, title} (group new / fixed / changed) from the same commit subjects,
with internal commits (ci, test, refactor, docs, chore, red tests, lint and
fleet work) left out. The update cards show its first lines, and `appcast`
writes the same lines as plain text into the build's appcast <description>.

  release-notes.py build --build B --short S --date D --head SHA [--since SHA] [--out DIR] [--pr-media] [--pr-descriptions]
  release-notes.py appcast --head SHA [--since SHA] --appcasts DIR --build B --feeds F...
  release-notes.py prs --head SHA [--since SHA] [--repo O/R] [--limit N]   the GitHub release's "PRs in this build"
  release-notes.py index --notes DIR/B.json [--previous index.json] [--keep 50] --out DIR/index.json
  release-notes.py backfill --index I --base URL... --public-key K --out DIR   adds summary/items to old notes
  release-notes.py since --index index.json [--not SHA]  prints the newest build's head commit (the next span's start)
  release-notes.py sign --key KEY.pem FILE...       writes FILE.sig
  release-notes.py verify --public-key BASE64 FILE  checks FILE.sig
  release-notes.py check --notes DIR/B.json         the release gate: fails a build with no or bad What's New entries
"""
import argparse, base64, hashlib, json, os, re, subprocess, sys, tempfile, time
import urllib.parse
from pathlib import Path

HIGHLIGHTS = "release-notes/next/highlights"
MAX_CHANGES = 200
SUMMARY_LIMIT = 8
PR_LIMIT = 40
DESCRIPTION_LIMIT = 240
GROUP_TITLES = {"new": "New", "fixed": "Fixed", "changed": "Changed"}
# Conventional types that never reach a person.
INTERNAL_TYPES = {"ci", "test", "tests", "refactor", "docs", "doc", "chore", "style", "build", "lint", "release-note",
                  "release-notes", "revert", "merge", "bench", "gallery"}
# Scopes of fix/feat commits that are about the pipeline or plumbing, not the app.
INTERNAL_SCOPES = {"ci", "nightly", "fleet", "release", "build", "tests", "test", "gallery", "crash", "lint", "docs",
                   "feat-cmux-next", "browser-parity", "first-party-apps", "browser-automation", "automation", "daemon",
                   "protocol", "sdk", "cmux-tui", "app-ffi", "backend", "nightly-next", "e2e", "harness", "deps",
                   "cmux-git", "cmux-tui-core", "release-notes", "appcast"}
# Subject words that mark internal work even without a type.
INTERNAL_BACKEND_WORDS = re.compile(
    r"\b(?:postgres(?:ql)?|vitess|snapshot cutoff|env(?:ironment)? projection|projection (?:read|write|shadow)|provider allocations?|cloud-3|credential plumbing|credential recovery|keyring credentials)\b", re.I | re.A)
# Subject words that mark internal work even without a type.
INTERNAL_WORDS = re.compile(
    r"\b(red|unit tests?|tests?|godfile|crash ratchet|baseline|index_subscript|int_conversion|lint|repin|re-pin|pin|"
    r"canary|fleet|review findings|move-only|ci|testbox|bisect|fixtures?|snapshot tests?|tree key|r2|ffi pin|budget|"
    r"isolated|wiring|socket|daemon|capabilit\w*|struct|type|owner|protocol|schema|sdk|refactor|smoke|acpmux|optchat-chief|"
    r"e2e|gallery|release notes?|publish\w*|pipeline|workflow|telemetry|crash reporting|exception reporting|benchmark|"
    r"frame budget|osc \d+|terminal host|seed|record\w*|nightly|headless|ffi|rust|regenerate|decode|renderer|texture|"
    r"machine code|scene captures?|policy log|host log|force unwrap|store intent|property model|false positive|inventory|"
    r"boundary|on the wire|debug reports?|dom events?|keybind actions?|main actor|shims?|"
    r"consumers?|metrics|review fixes|base reds?|feat-cmux-next|compile fix(?:es)?|byte limit|"
    r"fits the validator|validates? release headings|release[- ]notary|notes check)\b", re.I | re.A)
# Product names whose casing is not code ("MacOS": a title capitalized before LEADING_BRAND).
BRANDS = re.compile(r"\b(?:[Mm]acOS|[Ii]OS|[Ii]PadOS|[Ii]Cloud|[Ii]Phone|[Ii]Pad|GitHub|YouTube|SwiftUI|WebKit|JavaScript|TypeScript|ChatGPT|OpenAI)\b")
# Code-looking subjects (dotted names, snake_case, versioned ids, bead ids, backticks) are internal.
# ASCII classes, as JavaScript reads them in readableChange.ts.
CODE_LIKE = re.compile(r"`|\b[A-Za-z_]\w*\.[A-Za-z_]\w*\b|\w_\w|\w-v\d\b|\[cx-|\bcx-[a-z0-9]{3,}|\b[a-z]+[A-Z]\w*|\b[A-Z][a-z]+[A-Z]\w*|\b[A-Z]{2,}(?:-[A-Z]+)+\b|\{\w+\}", re.A)
# Work no user sees by its shape (readableChange.ts TOOL_NAME, PR_NUMBER, SQUASH_REPAIR): a tool name
# of three or more hyphenated parts, a pull request number, a repair after a squash.
TOOL_NAME = re.compile(r"(?<!\S)(?!(?:[a-z0-9]+-)*(?:to|by|of|and|in|the|a|an|on|for|or|at|with|up|not|per|one|two|three|four|five|six|seven|eight|nine|ten|cmd|command|shift|ctrl|control|alt|option|opt|fn|[a-z]|\d+)(?![a-z0-9]))[a-z][a-z0-9]*(?:-[a-z0-9]+){2,}(?=[\s,.;:!?)]|$)", re.I | re.A)
PR_NUMBER = re.compile(r"(?<!\S)#(?:N|\d{3,})(?![\w-])", re.A)
SQUASH_REPAIR = re.compile(r"\bsquash(?:ed)? (?:merge|commit)\b|\bsquash$", re.I | re.A)
CONVENTIONAL = re.compile(r"^(?P<type>[A-Za-z-]+)(?:\((?P<scope>[^)]*)\))?!?:\s*(?P<rest>.+)$")
AREA_PREFIX = re.compile(r"^(cmux-next(?: \w+){0,2}|cmuxnext|cmux next|acpmux|apps?|browser|gallery|release notes?|cx-[\w.]+|feed [\d.]+|cmux-tui)\s*:\s*", re.I)
# Files no user runs: CI workflows, tests, docs, plans, release notes and their checker, galleries,
# and the scripts that only measure, lint, guard or check the code. A commit that touches only these
# is internal whatever its subject says (nightly 4037632091801 read "Fixed: validate release headings
# within their day", #25533: notesCheck.ts and its test). The list is short on purpose: other scripts,
# scripts/ci/ included, can build or stage what ships (the CEF embed, the remote browser host, the
# agent pane bundle), and a change the list misses only stays news.
TOOLING_PATHS = re.compile(
    r"^(?:\.github/|tests/|tests_v2/|docs/|plans/|design/|release-notes/|webviews/test/|webviews/bench/"
    r"|scripts/(?:measure|fuzz|gallery-matrix|git-hooks)/|scripts/(?:ci|cmux-next)/tests/|scripts/cmux-next/media/)"
    # Contributor documents by name: other Markdown can ship (THIRD_PARTY_LICENSES.md opens from About).
    r"|/Tests/|(?:^|/)(?:AGENTS|CLAUDE|README(?:\.[\w-]+)?|STYLE|PLAN|TODO)\.md$"
    r"|^(?:CLA|CODE_OF_CONDUCT|CONTRIBUTING|DESIGN|ORCHESTRATION-NOTES|PROJECTS|REPORT|REVIEW|SECURITY|[\w-]+\.report)\.md$"
    r"|\.(?:test|spec|gallery|bench)\.[cm]?[jt]sx?$|^webviews/src/pages/changelog/notesCheck\.ts$"
    r"|^(?:webviews/)?scripts/(?:cmux-next/)?(?:check[-_]|lint[-_]|guardrails|bench[-_]|perf-(?:gate|cron)|prepush-gate"
    r"|arch[-_]|codebase-health|every-action|install-git-hooks|release-notes\.py|check-release-notes)[^/]*$")


def tooling_only(paths):
    """True when a commit touches at least one file and every one is CI or tooling (TOOLING_PATHS)."""
    return bool(paths) and all(TOOLING_PATHS.search(path) for path in paths)


# "area words: rest" after the conventional type: "cmux NEXT perf-split: review: …", "cmux-next strip: …".
LABEL = re.compile(r"^(?P<area>[A-Za-z][\w-]*(?: [A-Za-z][\w-]*){0,2})(?:\((?P<scope>[^)]*)\))?!?:\s+(?P<rest>\S.*)$")
# Work streams that measure or check the app (perf-split, perf-gate, motion-record, strip-scroll-check).
INTERNAL_AREA_SHAPE = re.compile(r"^(?:perf-[\w-]+|[\w-]+-(?:check|record|gate|bench|probe)|motion-record|review|gate|base-red)$", re.I)
PRODUCT_WORDS = {"cmux", "next", "cmux-next", "cmuxnext"}
# "(#123)", "(hq#45)", "(cx-abc)", "(cx-2y2 items 6, 10)", "(red)", "(review)", anywhere in the
# subject, and a bead reference cut off at the end.
# Also "(a283)", "(u3320)", "(a121, a211)": the Chief's agent and prompt ids, never for users.
REFS = re.compile(r"\s*\((?:[^()]*\bcx-[\w.]+[^()]*|[\w-]*#\d+|red|review)\)|\s*\((?:[^()]*\b)?cx-[\w.]*$"
                  r"|\s*\([au]\d+(?:\s*[,/]\s*[au]?\d+)*\)", re.I)

# A brand that starts lowercase keeps its casing at the start of a title: "macOS 26 …".
LEADING_BRAND = re.compile(r"^(?:macOS|iOS|iPadOS|iCloud|iPhone|iPad)\b")


def capitalized(text):
    """The text with a capital first letter, unless it starts with a lowercase brand."""
    return text if LEADING_BRAND.match(text) else text[:1].upper() + text[1:]


def summary_entry(subject):
    """(group, title) for a user-facing commit subject, else None."""
    text = " ".join(subject.split())
    if not text or text.lower().startswith(("merge ", "revert ", "bead:")):
        return None
    group = "changed"
    match = CONVENTIONAL.match(text)
    if match:
        kind, scope = match["type"].lower(), (match["scope"] or "").lower()
        if kind in INTERNAL_TYPES or any(part.strip() in INTERNAL_SCOPES for part in scope.split(",")):
            return None
        if kind not in {"feat", "fix", "perf"}:
            return None if kind not in {"cmux-next", "cmuxnext"} else summary_entry(match["rest"])
        group = {"feat": "new", "fix": "fixed", "perf": "changed"}[kind]
        text = match["rest"]
    # Each "area: " label in turn; a work-stream label marks the whole line internal. The same
    # rules as readableChange (webviews/src/pages/changelog/readableChange.ts).
    while (label := LABEL.match(text)):
        words = [w for w in label["area"].lower().split() if w not in PRODUCT_WORDS]
        scopes = [s.strip() for s in (label["scope"] or "").lower().split(",") if s.strip()]
        # "acpmux test: …", "sidebar ci: …": a label that names test or CI work is internal too.
        if any(INTERNAL_AREA_SHAPE.match(w) or w in INTERNAL_TYPES for w in words + scopes):
            return None
        text = label["rest"]
    text = AREA_PREFIX.sub("", text)
    text = REFS.sub("", text).strip(" .")
    if (not text or INTERNAL_WORDS.search(text) or INTERNAL_BACKEND_WORDS.search(text)
            or CODE_LIKE.search(BRANDS.sub("", text))
            or TOOL_NAME.search(text) or PR_NUMBER.search(text) or SQUASH_REPAIR.search(text)):
        return None
    if group == "changed" and re.match(r"^(add|adds|new|introduce|support|show)\b", text, re.I):
        group = "new"
    elif group == "changed" and re.match(r"^(fix|fixes|repair|stop|keep)\b", text, re.I):
        group = "fixed"
    # Whole: the page wraps a long line, and short_title gives the digest a title that fits.
    return group, capitalized(text)


# PR bodies are read only while the release is cut. The same deterministic extraction is used for
# every nightly: an explicit Changelog line wins, then the first prose in Summary, then the title.
CHANGELOG_LINE = re.compile(r"^(?:[-*+]\s*)?(?:Added|Changed|Fixed|Removed)\s*:\s*(?P<text>.*?)\s*$", re.I)
HEADING = re.compile(r"^#{1,6}\s*(?P<name>[^#].*?)\s*#*\s*$")
MARKDOWN_LINK = re.compile(r"\[([^]]+)\]\([^)]*\)")
MARKDOWN_LINK_URL = re.compile(r"\[([^]]+)\]\(([^)\s]+)\)")
INLINE_MARKUP = re.compile(r"[`*_~]")
HTML_COMMENT = re.compile(r"<!--.*?(?:-->|$)", re.S)
# Only known public destinations are stripped to their labels; an org can also own private repos.
PUBLIC_URL = re.compile(r"https?://(?:www\.)?(?:github\.com/manaflow-ai/cmux(?:/|$)|cmux\.com(?:/|$))", re.I)
PUBLIC_PROSE = re.compile(r"(?:[^\W_]|[\s.,!?…。！？:;'\"“”‘’«»()—–+*`~%\-])+")
UNSAFE_DESCRIPTION = re.compile(
    r"(?:\b(?:https?|file|ssh|git|ftp)://|(?<!\w)//|deeplink/agent|\b(?:aid-[a-z0-9-]{8,}|"
    r"(?:session|agent)[_-](?:id[_-])?[a-z0-9_-]{8,}|[a-f0-9]{16,}|"
    r"[0-9a-f]{8}-[0-9a-f-]{17,})\b|"
    r"\b(?:[a-z0-9-]+\.)+[a-z]{2,}\b|"
    r"\b\d{1,3}(?:\.\d{1,3}){3}\b|"
    r"\b(?:cmux-platform|cmux-lawrence|cmux\d+|blacksmith)\b|"
    r"\b(?:cmux\d+s?-|gcp-|aws-|austin-|cosmic-|air-|big-|huge-|blacksmith)[a-z0-9-]+\b)",
    re.I,
)
DESCRIPTION_QUOTES = "\"'”’»)]}"
DESCRIPTION_LABEL = re.compile(r"^(?:added|changed|fixed|removed|summary|changelog)\s*:\s*", re.I)
DESCRIPTION_PLACEHOLDER = re.compile(r"^(?:none|n/?a|no\s+changes?|no\s+user[- ]facing\s+changes?|tbd|todo)[.!…]*$", re.I)


def _first_sentence(text):
    """Return the first complete sentence, preserving closing quotes and abbreviations."""
    validate = _description_validator()
    for index, char in enumerate(text):
        if char not in ".!?。！？":
            continue
        if char == "." and ((index and text[index - 1] == ".") or
                             (index + 1 < len(text) and text[index + 1] == ".")):
            continue
        if char == "." and validate.is_abbreviation_period(text, index):
            continue
        if char == "." and index and index + 1 < len(text) and text[index - 1].isdigit() and text[index + 1].isdigit():
            continue
        # Use the release gate's quote boundary rule for straight and curly
        # single/double quotes, without treating contractions as quote openers.
        if validate.is_inline_quoted_punctuation(text, index):
            continue
        end = index + 1
        while end < len(text) and text[end] in DESCRIPTION_QUOTES:
            end += 1
        if end == len(text) or text[end].isspace():
            return text[:end].strip()
    return text


def _description_validator():
    validator_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "whats-new")
    if validator_path not in sys.path:
        sys.path.insert(0, validator_path)
    import validate
    return validate


def _safe_description(text):
    # Use the release gate's own internal-text rules before storing descriptions in items or
    # summary lines. Otherwise an issue reference can also make the digest drop a valid change.
    validate = _description_validator()
    for _, url in MARKDOWN_LINK_URL.findall(text):
        if not PUBLIC_URL.match(url):
            return False
    prose = MARKDOWN_LINK_URL.sub(r"\1", text)
    return (bool(PUBLIC_PROSE.fullmatch(prose)) and not UNSAFE_DESCRIPTION.search(prose)
            and not any(pattern.search(prose) for pattern, _ in validate.INTERNAL))


def _validated_description(text):
    """Keep final copy only when the release gate accepts it as an English summary."""
    if not _safe_description(text):
        return ""
    import validate
    problems = validate.Problems("PR description")
    validate.check_text(problems, "summary", text, "summary", "en")
    return "" if problems.items else text


def _candidate_description(text):
    """Normalize a body candidate after removing its Markdown/list and section label."""
    text = text.strip()
    text = re.sub(r"^[-*+]\s+", "", text)
    text = DESCRIPTION_LABEL.sub("", text).strip()
    if not text or DESCRIPTION_PLACEHOLDER.fullmatch(text) or not _safe_description(text):
        return ""
    return _plain_line(text)


def _plain_line(text):
    if not _safe_description(text):
        return ""
    text = MARKDOWN_LINK.sub(r"\1", text)
    text = INLINE_MARKUP.sub("", text)
    text = re.sub(r"\s+", " ", text).strip(" -")
    # Check before truncating: a period in a URL or identifier must not disguise unsafe copy.
    if not _safe_description(text):
        return ""
    # A PR body can contain several prose sentences. Keep the first complete sentence so the
    # generated description is always one line and one sentence, before applying the length cap.
    text = _first_sentence(text)
    if len(text) >= DESCRIPTION_LIMIT:
        text = text[:DESCRIPTION_LIMIT - 1].rsplit(" ", 1)[0].rstrip(" ,;:-")
    return _validated_description(sentence(text))

def pr_description(body, fallback=""):
    """Extract one plain-language sentence from a PR body, without headings or markup."""
    fallback = _candidate_description(fallback) or ("Fixes and improvements." if fallback else "")
    if not body:
        return fallback
    body = HTML_COMMENT.sub("", body.replace("\r", ""))
    lines = [line.strip() for line in body.splitlines()]
    section = None
    candidates = []
    summary_parts = []
    changelog_parts = []
    for line in lines:
        heading = HEADING.match(line)
        if heading:
            section = heading["name"].lower()
            continue
        if line.startswith("<!--") or not line:
            continue
        if section == "changelog":
            line = line.lstrip("-*+ ")
            if DESCRIPTION_PLACEHOLDER.fullmatch(line):
                return fallback
            match = CHANGELOG_LINE.match(line)
            if match:
                if changelog_parts:
                    candidates.append(" ".join(changelog_parts))
                changelog_parts = [match["text"]]
                continue
            if not line.startswith(("##", "###")):
                if changelog_parts:
                    changelog_parts.append(line)
        elif section == "summary":
            summary_parts.append(line)
    if changelog_parts:
        candidates.append(" ".join(changelog_parts))
    if summary_parts:
        # An explicit Changelog is the documented release-copy source. Summary is
        # only the fallback when no usable Changelog prose exists.
        candidates.append(" ".join(summary_parts))
    for candidate in candidates:
        text = _candidate_description(candidate)
        if text and _safe_description(text) and not text.lower().startswith(("none", "generated with", "agent session")):
            return text
    return fallback

def internal_change(subject, paths=(), description=""):
    """Whether a change belongs under the collapsed Under the hood section."""
    return tooling_only(paths) or bool(INTERNAL_BACKEND_WORDS.search(" ".join((subject, description))))


CLAUSE = re.compile(r",|;| —| - | \(| so | because | while ")
DANGLING = re.compile(r"\b(?:a|an|the|and|or|but|to|of|in|on|for|with|by|even|so|that|which|its|their)$", re.I)


def short_title(text, limit):
    """At most `limit` characters: the text when it fits, else its first clause when that fits, has
    three words and does not end on a joining word, else None. Never a cut word or an ellipsis
    (readableChange.ts shortTitle)."""
    text = " ".join(text.split()).rstrip(". ")
    if len(text) <= limit:
        return text
    for match in CLAUSE.finditer(text):
        head = text[:match.start()].rstrip(" ,;:—-")
        if len(head) > limit:
            return None
        if len(head.split()) >= 3 and not DANGLING.search(head):
            return head
    return None


def title_tail(full, title):
    """What follows `title` in `full`, as a summary (readableChange.ts titleTail)."""
    tail = full[len(title):].lstrip(" ,;:—-").strip()
    if tail.startswith("(") and tail.endswith(")"):
        tail = tail[1:-1]
    return capitalized(tail)


def summarize_changes(subjects, limit=SUMMARY_LIMIT, descriptions=None):
    """The user-facing lines, New then Fixed then Changed, newest first, deduplicated, at most `limit`."""
    seen, groups = set(), {"new": [], "fixed": [], "changed": []}
    for subject in subjects:
        entry = summary_entry(subject)
        if entry is None or entry[1].lower() in seen:
            continue
        seen.add(entry[1].lower())
        line = {"group": entry[0], "title": entry[1]}
        if descriptions:
            description = descriptions.get(subject, "")
            if _safe_description(description):
                line["description"] = description
        groups[entry[0]].append(line)
    # A fair share per group first (New 3, Fixed 3, Changed 2), then the rest in order.
    chosen = {g: groups[g][:n] for g, n in (("new", 3), ("fixed", 3), ("changed", 2))}
    rest = [(g, line) for g in ("new", "fixed", "changed") for line in groups[g][len(chosen[g]):]]
    while sum(map(len, chosen.values())) < limit and rest:
        g, t = rest.pop(0)
        chosen[g].append(t)
    return [line for g in ("new", "fixed", "changed") for line in chosen[g]][:limit]


def summary_text(lines):
    """The appcast <description>: one plain line per change, "New: …"."""
    return "\n".join(f'{GROUP_TITLES[line["group"]]}: {line["title"]}' for line in lines)


def commit_subjects(since, head):
    """The span's subjects for the summary, newest first: a tooling-only commit is left out."""
    return [subject for subject, _, paths in span_commits(since, head) if not tooling_only(paths)]


def git(*args):
    return subprocess.run(["git", *args], capture_output=True, text=True, check=True).stdout


def rev_range(since, head):
    return f"{since}..{head}" if since else head


def parse_highlight(path, text):
    head, _, body = text.partition("\n\n")
    meta = {}
    for line in head.splitlines():
        key, sep, value = line.partition(":")
        if sep:
            meta[key.strip().lower()] = value.strip()
    if "title" not in meta:
        raise SystemExit(f"{path}: a highlight needs a 'title:' line")
    item = {"id": os.path.splitext(os.path.basename(path))[0], "title": meta["title"], "body": body.strip(), "media": []}
    if meta.get("category", "").lower() in {"new", "improved", "fixed", "security"}:
        item["category"] = meta["category"].lower()
    if meta.get("action"):
        action_id, _, title = meta["action"].partition("|")
        item["action"] = {"id": action_id.strip(), "title": (title.strip() or "Try it")}
    clip = CLIP.fullmatch(meta.get("clip", ""))
    if clip:
        item["media"] = [{"url": clip["url"], "sha256": clip["sha256"], "kind": "image", "alt": meta["title"]}]
    elif "clip" in meta:
        # Left out, never a failed build: CI's whats-new-clips.py check holds the line to its shape.
        print(f"{path}: 'clip:' is not '{CLIP_PREFIX}ID/NAME.webp | SHA256'; left out", file=sys.stderr)
    return item


# A clip (whats-new-clips.py publish): an animated WebP on pr-media's whats-new/ folder and its hash, which the
# app checks before it shows it, as for --pr-media pictures.
CLIP_PREFIX = "https://raw.githubusercontent.com/manaflow-ai/cmux/pr-media/whats-new/"
CLIP = re.compile(r"(?P<url>" + re.escape(CLIP_PREFIX) + r"[a-z0-9][a-z0-9-]*/[0-9a-f]{12}\.webp)\s*\|\s*(?P<sha256>[0-9a-f]{64})")
CLIPS = "release-notes/next/clips"
CLIP_REANNOUNCE_DAYS = 7


def clip_caption(highlight, head):
    """The clip's caption (its spec's), else the highlight's title, as the clip's alt."""
    try:
        spec = json.loads(git("show", f"{head}:{CLIPS}/{highlight['id']}.json"))
    except (subprocess.CalledProcessError, ValueError):
        return
    caption = spec.get("caption") if isinstance(spec, dict) else None
    if isinstance(caption, str) and caption.strip():
        highlight["media"][0]["alt"] = caption.strip()


def reannounced(since, head, added):
    """Highlights added before the span, of the last CLIP_REANNOUNCE_DAYS, whose clip line the span set."""
    if not since:
        return []
    head_time = int(git("show", "-s", "--format=%ct", head).strip())
    out = []
    for path in git("diff", "--name-only", "--diff-filter=M", since, head, "--", HIGHLIGHTS).split():
        if not path.endswith(".md") or path in added:
            continue
        before = parse_highlight(path, git("show", f"{since}:{path}"))
        after = parse_highlight(path, git("show", f"{head}:{path}"))
        clip = lambda h: [(m["url"], m["sha256"]) for m in h["media"]]
        if not after["media"] or clip(before) == clip(after):  # a new title alone re-announces nothing
            continue
        born = git("log", "--diff-filter=A", "--format=%ct", "-1", head, "--", path).strip()
        if born and head_time - int(born) <= CLIP_REANNOUNCE_DAYS * 86400:
            out.append(path)
    return out


PR_SUFFIX = re.compile(r"^(?P<title>.*?)\s*\(#(?P<pr>\d+)\)\s*$")

# --pr-media: a highlight shows the first picture of the pull request that added it (Leo 2026-10-21,
# What's New design pass), when that picture is one this repository published to pr-media
# (scripts/pr-media.py). The notes carry its URL and hash; the app fetches it and shows it only when
# the bytes match (ReleaseMediaStore.highlightData). Anything else leaves the highlight without one.
PR_MEDIA_PREFIX = "https://raw.githubusercontent.com/manaflow-ai/cmux/pr-media/"
PR_MEDIA_IMAGE = re.compile(r"""(?:!\[[^\]]*\]\(\s*|<(?:img|video|source)\b[^>]*?\bsrc=["'])(?P<url>https://[^\s)"'>]+)""", re.I)
# The app's limit (ReleaseMediaStore.maxMediaBytes) and the media types it decodes.
PR_MEDIA_MAX_BYTES = 4 << 20
PR_MEDIA_SIGNATURES = (b"\x89PNG\r\n\x1a\n", b"\xff\xd8\xff", b"GIF87a", b"GIF89a")
# Each call waits at most PR_MEDIA_TIMEOUT seconds, and all of them together PR_MEDIA_BUDGET, so a slow
# GitHub leaves later highlights without pictures instead of running the signing job out of time.
PR_MEDIA_TIMEOUT = 10
PR_MEDIA_BUDGET = 120
PR_DESCRIPTION_BUDGET = 120


def pr_media_picture(data):
    """True for bytes the app would show: a picture or short video within its size limit."""
    webp = data[:4] == b"RIFF" and data[8:12] == b"WEBP"
    video = len(data) >= 12 and data[4:8] == b"ftyp"
    return 12 <= len(data) <= PR_MEDIA_MAX_BYTES and (webp or video or data.startswith(PR_MEDIA_SIGNATURES))


def public_pr_media_url(url):
    """Whether a PR body URL is the repository's public media host and branch."""
    try:
        parsed = urllib.parse.urlsplit(url)
        scheme = parsed.scheme
        hostname = parsed.hostname
        port = parsed.port
        username = parsed.username
        password = parsed.password
        query = parsed.query
        fragment = parsed.fragment
        decoded_path = urllib.parse.unquote(parsed.path)
    except ValueError:
        return False
    return (
        scheme == "https"
        and hostname == "raw.githubusercontent.com"
        and port is None
        and not username
        and not password
        and not query
        and not fragment
        and decoded_path.startswith("/manaflow-ai/cmux/pr-media/")
        # A remaining percent sign could be decoded again downstream. Reject it,
        # and backslashes that URL loaders can interpret as path separators.
        and "%" not in decoded_path
        and "\\" not in decoded_path
        and not any(segment in (".", "..") for segment in decoded_path.split("/"))
    )


def pr_body(pr, fixture, deadline=None):
    if fixture is not None:
        return fixture["bodies"].get(str(pr), "")
    timeout = PR_MEDIA_TIMEOUT
    if deadline is not None:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return ""
        timeout = min(timeout, remaining)
    try:
        result = subprocess.run(["gh", "api", f"repos/manaflow-ai/cmux/pulls/{pr}", "--jq", ".body // \"\""],
                                capture_output=True, text=True, timeout=timeout)
    except (subprocess.TimeoutExpired, OSError):
        return ""
    return result.stdout if result.returncode == 0 else ""


def pr_download(url, fixture):
    if fixture is not None:
        path = fixture["files"].get(url)
        return Path(path).read_bytes() if path else None
    import urllib.request

    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *args):
            return None

    request = urllib.request.Request(url, headers={"User-Agent": "cmux-release-notes/1"})
    with urllib.request.build_opener(NoRedirect).open(request, timeout=PR_MEDIA_TIMEOUT) as response:
        return response.read(PR_MEDIA_MAX_BYTES + 1)


def add_pr_media(highlight, path, head, deadline):
    """Gives `highlight` the first pr-media picture of the pull request whose commit added `path`.
    Any failure (a timeout, a missing gh, a URL urllib rejects, a cut-off download) only leaves the
    highlight without a picture: a PR body anyone can edit must never stop the notes."""
    if time.monotonic() > deadline:
        print(f"pr-media: {path}: out of time; left out", file=sys.stderr)
        return
    try:
        find_pr_media(highlight, path, head)
    except Exception as error:
        print(f"pr-media: {path}: {type(error).__name__}: {error}; left out", file=sys.stderr)


def find_pr_media(highlight, path, head):
    fixture_path = os.environ.get("CMUX_RELEASE_NOTES_PR_FIXTURE")
    fixture = json.loads(Path(fixture_path).read_text()) if fixture_path else None
    subject = git("log", "--diff-filter=A", "--format=%s", "-1", head, "--", path).strip()
    match = PR_SUFFIX.match(subject)
    if not match:
        return
    for found in PR_MEDIA_IMAGE.finditer(pr_body(int(match["pr"]), fixture)):
        url = found["url"]
        if not public_pr_media_url(url) or not url.startswith(PR_MEDIA_PREFIX):
            continue
        data = pr_download(url, fixture)
        if data is None or not pr_media_picture(data):
            print(f"pr-media: {path}: #{match['pr']} {url} is not a picture the app shows; left out", file=sys.stderr)
            return
        kind = "video" if len(data) >= 12 and data[4:8] == b"ftyp" else "image"
        highlight["media"] = [{"url": url, "sha256": hashlib.sha256(data).hexdigest(), "kind": kind,
                               "alt": highlight["title"]}]
        return


def change_item(subject, author, paths=(), descriptions=None):
    """One structured change (UPDATE-CARD): title, author, PR, and a deterministic one-line
    description from the PR body when the release job has enabled PR descriptions.
    """
    description = ""
    match = PR_SUFFIX.match(subject)
    if match and descriptions is not None:
        description = descriptions.get(int(match["pr"]), "")
    item = {"title": subject.strip(), "author": author.strip() or None,
            "internal": internal_change(subject, paths, description) or None}
    if match and match["title"].strip():
        item["title"], item["pr"] = match["title"].strip(), int(match["pr"])
        if description:
            item["description"] = description
    return {k: v for k, v in item.items() if v is not None}


def whats_new_digest(args, also=()):
    """The What's New nightly digest of the same highlights (scripts/whats-new/digest.py),
    or None when it is empty or does not validate: the notes still publish."""
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "whats-new"))
    try:
        import digest, validate
        document = digest.build(args.short, args.date, args.head, args.since, also=also)
    except (ImportError, ValueError, subprocess.CalledProcessError) as error:
        print(f"whats-new digest skipped: {error}", file=sys.stderr)
        return None
    # One entry the validator refuses (most often: no try-it action or docs link) drops only that
    # entry, not the whole digest; the notes' highlights still carry every file.
    kept = []
    for entry in document.get("entries", []):
        found = validate.validate_document(f"{args.short}.json", {**document, "entries": [entry]})
        if found:
            print(f"whats-new digest: dropped {entry.get('id')}:\n" + "\n".join(found), file=sys.stderr)
        else:
            kept.append(entry)
    document = {**document, "entries": kept}
    problems = validate.validate_document(f"{args.short}.json", document)
    if problems:
        print("whats-new digest skipped:\n" + "\n".join(problems), file=sys.stderr)
        return None
    return document if document["entries"] else None


def sentence(text):
    """`text` as a whole sentence: the validator wants a summary to end one (WRITING.md)."""
    text = text.strip()
    ending = text.rstrip(DESCRIPTION_QUOTES)
    return text if not text or (ending and ending[-1] in ".!?。！？") else text + "."


def summary_whats_new_digest(args, lines):
    """A validated nightly digest when there are summary lines but no highlight digest."""
    if not lines:
        return None
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "whats-new"))
    import validate

    document = {"schemaVersion": 1, "version": args.short, "channel": "nightly", "date": args.date,
                "headline": {"en": "Fixes and improvements"}, "entries": []}
    categories = {"new": "new", "fixed": "fixed", "changed": "improved"}
    titles = set()
    for index, line in enumerate(lines):
        # A line with no clause short enough stays out of the digest; the page shows it whole
        # from the summary lines.
        title = short_title(line.get("title", ""), validate.LIMITS["title"])
        # Two long lines can share a first clause; the digest shows each title once.
        if not title or line.get("group") not in categories or title.lower() in titles:
            continue
        # The summary says what the title leaves out, or repeats a title that is the whole line.
        full = " ".join(line["title"].split()).rstrip(". ")
        description = _validated_description(line.get("description", ""))
        if not description:
            description = _validated_description(sentence(title_tail(full, title) if title != full else full))
        entry = {"id": f"summary-{index}", "category": categories[line["group"]],
                 "title": {"en": title},
                 "summary": {"en": sentence(description or (title_tail(full, title) if title != full else full))},
                 "platforms": ["macos"], "audience": "all", "docs": "https://cmux.com/docs/changelog"}
        problems = validate.validate_document(f"{args.short}.json", {**document, "entries": [entry]})
        if problems:
            entry["summary"] = {"en": sentence(title)}
            problems = validate.validate_document(f"{args.short}.json", {**document, "entries": [entry]})
        if problems:
            print(f"whats-new summary: dropped {entry['id']}:\n" + "\n".join(problems), file=sys.stderr)
            continue
        document["entries"].append(entry)
        titles.add(title.lower())
    if not document["entries"]:
        return None
    document["headline"] = {"en": document["entries"][0]["title"]["en"]}
    problems = validate.validate_document(f"{args.short}.json", document)
    if problems:
        print("whats-new summary skipped:\n" + "\n".join(problems), file=sys.stderr)
        return None
    return document


REPO = "manaflow-ai/cmux"
# The generic entry, all but its docs link (the span's commits). `check` knows it by every field,
# so a real highlight that happens to share its id is never taken for it.
GENERIC_ENTRY = {"id": "fixes-and-improvements", "category": "improved", "title": {"en": "Fixes and improvements"},
                 "summary": {"en": "This build brings fixes and improvements. The link lists every change in it."},
                 "platforms": ["macos"], "audience": "all"}


def generic_whats_new_digest(args):
    """The digest of a build with nothing user-facing to say: one "Fixes and improvements" entry
    whose link lists the span's commits. claude-sr2, 2026-10-27: a build with no What's New entry
    publishes with this instead of failing publish-nightly (9 of 79 attempts threw away a notarized
    build); `check` warns about it."""
    link = (f"https://github.com/{REPO}/compare/{args.since}...{args.head}" if args.since
            else f"https://github.com/{REPO}/commits/{args.head}")
    return {"schemaVersion": 1, "version": args.short, "channel": "nightly", "date": args.date,
            "headline": {"en": "Fixes and improvements"}, "entries": [{**GENERIC_ENTRY, "docs": link}]}


def is_generic(entries):
    """Whether `entries` is exactly the generic entry generic_whats_new_digest writes."""
    if len(entries) != 1:
        return False
    entry = dict(entries[0])
    docs = entry.pop("docs", "")
    return entry == GENERIC_ENTRY and isinstance(docs, str) and (
        docs.startswith(f"https://github.com/{REPO}/compare/") or docs.startswith(f"https://github.com/{REPO}/commits/"))


def write_community_summary(digest, args):
    """notes/community-<build>.md: a short Discord/X summary a human posts (K2); the
    release-notes artifact keeps it and the R2 upload publishes it with the notes."""
    import community
    text = community.summary(digest, f"https://cmux.com/whats-new/{digest['version']}")
    if text:
        os.makedirs(args.out, exist_ok=True)
        with open(os.path.join(args.out, f"community-{args.build}.md"), "w", encoding="utf-8") as out:
            out.write(text)


def commits_with_authors(since, head, limit=MAX_CHANGES):
    """(subject, author) of each non-merge commit in the span, newest first, at most `limit` (None: all)."""
    return [(subject, author) for subject, author, _ in span_commits(since, head, limit)]


def span_commits(since, head, limit=MAX_CHANGES):
    """(subject, author, paths) of each non-merge commit in the span, newest first, at most `limit`
    (None: all). `paths` are the files the commit touches (none for an empty commit). NUL-separated
    and keyed by hash, so no subject or file name can shift a path onto another commit."""
    span = rev_range(since, head)
    commits = []
    for record in git("log", "--no-merges", "-z", "--format=%H%x1f%an%x1f%s", span).split("\0"):
        sha, _, rest = record.strip("\n").partition("\x1f")
        author, _, subject = rest.partition("\x1f")
        if sha:
            commits.append((sha, subject, author))
    paths, current = {sha: [] for sha, _, _ in commits}, None
    # "-z --name-only": each commit's marked hash, then "\n" and its files, every field ended by NUL.
    # The marker (\x01) keeps a file named like a hash from passing for a commit.
    # --no-renames: a moved file counts at both ends, so a move into tests/ is not tooling alone.
    for field in git("log", "--no-merges", "--no-renames", "-z", "--name-only", "--format=%x01%H%x01", span).split("\0"):
        name = field[1:] if field.startswith("\n") else field
        marked = name[1:-1] if len(name) == 42 and name[0] == name[-1] == "\x01" else None
        if marked in paths:
            current = marked
        elif name and current:
            paths[current].append(name)
    return [(subject, author, paths[sha]) for sha, subject, author in commits if subject.strip()][:limit]


def pr_lines(items, repo, limit=PR_LIMIT):
    """The GitHub release body's "PRs in this build" section: one line per PR (newest first, each
    PR once), at most `limit`, then "and K more"; commits without a "(#1234)" suffix are counted."""
    seen, prs = set(), []
    for item in items:
        if "pr" in item and item["pr"] not in seen:
            seen.add(item["pr"])
            prs.append(item)
    without = sum(1 for item in items if "pr" not in item)
    if not prs and not without:
        return ""
    lines = ["### PRs in this build", ""]
    # A subject's "@login" would ping that person and a "<" could open an HTML comment.
    escape = lambda text: text.replace("&", "&amp;").replace("<", "&lt;").replace("@", "&#64;")
    lines += [f'- [#{i["pr"]}](https://github.com/{repo}/pull/{i["pr"]}) {escape(i["title"])}' for i in prs[:limit]]
    if len(prs) > limit:
        lines.append(f"- and {len(prs) - limit} more")
    if not prs:
        lines.append("No PRs.")
    if without:
        lines += ["", f"{without} commit{'s' if without != 1 else ''} without a PR number not listed."]
    return "\n".join(lines) + "\n"


def prs(args):
    # The whole span, not MAX_CHANGES: "and K more" and the no-PR count must cover every commit.
    commits = commits_with_authors(args.since, args.head, limit=None)
    print(pr_lines([change_item(s, a) for s, a in commits], args.repo, args.limit), end="")


def build(args):
    span = rev_range(args.since, args.head)
    commits = span_commits(args.since, args.head)
    changes = [subject for subject, _, _ in commits]
    descriptions = {}
    pr_descriptions = {}
    if args.pr_descriptions:
        fixture_path = os.environ.get("CMUX_RELEASE_NOTES_PR_FIXTURE")
        fixture = json.loads(Path(fixture_path).read_text()) if fixture_path else None
        description_deadline = time.monotonic() + PR_DESCRIPTION_BUDGET
        for subject, _, _ in commits:
            match = PR_SUFFIX.match(subject)
            if not match:
                continue
            number = int(match["pr"])
            if number not in pr_descriptions:
                fallback = summary_entry(match["title"])
                fallback_title = fallback[1] if fallback else match["title"]
                pr_descriptions[number] = pr_description(pr_body(number, fixture, description_deadline), fallback_title)
            descriptions[subject] = pr_descriptions[number]
    items = [change_item(subject, author, paths, pr_descriptions if args.pr_descriptions else None)
             for subject, author, paths in commits]
    # The summary (and the What's New digest made from it) never names tooling-only or backend-only commits.
    user_changes = [subject for subject, _, paths in commits
                    if not internal_change(subject, paths, descriptions.get(subject, ""))]
    added = git("log", "--diff-filter=A", "--name-only", "--format=", span, "--", HIGHLIGHTS).split()
    highlights = []
    deadline = time.monotonic() + PR_MEDIA_BUDGET
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "whats-new"))
    from digest import surviving_highlights
    added = surviving_highlights(args.head, added)
    again = reannounced(args.since, args.head, added)
    for path in sorted(added | set(again)):
        highlight = parse_highlight(path, git("show", f"{args.head}:{path}"))
        if highlight["media"]:
            clip_caption(highlight, args.head)
        elif args.pr_media and highlight.get("category", "new") in {"new", "improved"}:
            add_pr_media(highlight, path, args.head, deadline)
        highlights.append(highlight)
    # "head": the commit these notes end at; the next build's span starts there (`since`), so a
    # build whose notes never published loses no change to the build after it.
    notes = {"version": 1, "build": args.build, "shortVersion": args.short, "date": args.date, "head": args.head,
             "highlights": highlights, "changes": changes, "items": items, "summary": summarize_changes(user_changes, descriptions=descriptions)}
    digest = whats_new_digest(args, again)
    if digest is None:
        digest = summary_whats_new_digest(args, notes["summary"])
    generic = digest is None and not highlights
    if generic:
        # Nothing user-facing in the span. A span whose highlight files all failed validation
        # keeps no digest, so `check` still fails it.
        digest = generic_whats_new_digest(args)
    if digest is not None:
        notes["whatsNew"] = digest
        if not generic:
            write_community_summary(digest, args)
    # When the build was made, to the second: the Updated card names the build by it ("Nightly · Oct 26,
    # 7:38 PM" in the person's time zone; Leo 2026-10-26: "it just says updated to nightly").
    notes["builtAt"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    os.makedirs(args.out, exist_ok=True)
    path = os.path.join(args.out, f"{args.build}.json")
    with open(path, "w", encoding="utf-8") as out:
        json.dump(notes, out, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    print(path)


def appcast(args):
    """Writes the build's short changelog into its item in every published appcast."""
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "ci"))
    from nightly_release_notes import update_appcasts
    lines = summarize_changes(commit_subjects(args.since, args.head))
    text = summary_text(lines) or "Maintenance and internal improvements."
    update_appcasts(Path(args.appcasts), args.build, text, tuple(args.feeds))
    print(text)


def index(args):
    with open(args.notes, encoding="utf-8") as f:
        notes = json.load(f)
    builds = []
    if args.previous and os.path.exists(args.previous):
        with open(args.previous, encoding="utf-8") as f:
            builds = json.load(f).get("builds", [])
    entry = {"build": notes["build"], "shortVersion": notes["shortVersion"], "date": notes["date"],
             "highlights": len(notes["highlights"])}
    if re.fullmatch(r"[0-9a-f]{40}", notes.get("head") or ""):
        entry["head"] = notes["head"]
    builds = [entry] + [b for b in builds if b.get("build") != notes["build"]]
    with open(args.out, "w", encoding="utf-8") as out:
        json.dump({"version": 1, "builds": builds[: args.keep]}, out, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    print(args.out)


def since(args):
    """Prints the head commit of the newest build in a (verified) index that records one, else
    nothing. `--not` skips a head (a rerun of the job whose own notes are already published)."""
    with open(args.index, encoding="utf-8") as f:
        builds = json.load(f).get("builds", [])
    for entry in builds:
        head = entry.get("head")
        if isinstance(head, str) and re.fullmatch(r"[0-9a-f]{40}", head) and head != args.skip:
            print(entry["head"])
            return 0
    return 0


def sign(args):
    for path in args.files:
        raw = subprocess.run(["openssl", "pkeyutl", "-sign", "-inkey", args.key, "-rawin", "-in", path],
                             capture_output=True, check=True).stdout
        with open(path + ".sig", "w") as out:
            out.write(base64.b64encode(raw).decode() + "\n")
        print(path + ".sig")


def backfill(args):
    """Published notes from before summary lines and structured items get them (cx-urd.61.6): for
    each build in the index that has no file in --out yet, fetch its notes from the first --base that
    serves a copy whose signature verifies, add "summary" and "items" from its commit subjects when
    missing, and write it to --out for re-signing. Prints the written paths. Never fails the job: a
    build that cannot be fetched or verified is skipped."""
    with open(args.index, encoding="utf-8") as f:
        builds = [b.get("build", "") for b in json.load(f).get("builds", []) if isinstance(b, dict)][: args.limit]
    written = []
    for build in builds:
        out_path = os.path.join(args.out, f"{build}.json")
        if not re.fullmatch(r"[0-9.]+", build) or os.path.exists(os.path.join(args.existing or args.out, f"{build}.json")):
            continue
        try:
            notes = fetch_verified_notes(build, args.base, args.public_key)
        except Exception as error:  # one bad build never stops the others or the job
            print(f"backfill: skipped {build}: {error}", file=sys.stderr)
            continue
        if not isinstance(notes, dict) or notes.get("build") != build or ("summary" in notes and "items" in notes):
            continue
        changes = [c for c in notes.get("changes", []) if isinstance(c, str)]
        notes.setdefault("summary", summarize_changes(changes))
        notes.setdefault("items", [change_item(c, "") for c in changes])
        with open(out_path, "w", encoding="utf-8") as out:
            json.dump(notes, out, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
        written.append(out_path)
    print("\n".join(written))
    return 0


def fetch_verified_notes(build, bases, public_key):
    """The notes of `build` from the first base whose copy verifies, else None."""
    import urllib.request
    for base in bases:
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, f"{build}.json")
            try:
                for name in (f"{build}.json", f"{build}.json.sig"):
                    request = urllib.request.Request(f"{base.rstrip('/')}/notes/{name}", headers={"User-Agent": "cmux-release-notes/1"})
                    with urllib.request.urlopen(request, timeout=20) as response, open(os.path.join(tmp, name), "wb") as f:
                        f.write(response.read())
                if not verified(path, public_key):
                    continue
            except Exception:
                continue
            with open(path, encoding="utf-8") as f:
                return json.load(f)
    return None


def verified(path, public_key):
    """Whether path + ".sig" is a valid Ed25519 signature of path by public_key (raw, base64)."""
    der = bytes.fromhex("302a300506032b6570032100") + base64.b64decode(public_key)
    with tempfile.TemporaryDirectory() as tmp:
        key_der, key_pem, sig = (os.path.join(tmp, n) for n in ("pub.der", "pub.pem", "sig.bin"))
        with open(key_der, "wb") as f:
            f.write(der)
        subprocess.run(["openssl", "pkey", "-pubin", "-inform", "DER", "-in", key_der, "-out", key_pem], check=True, capture_output=True)
        with open(path + ".sig") as f, open(sig, "wb") as out:
            out.write(base64.b64decode(f.read().strip()))
        return subprocess.run(["openssl", "pkeyutl", "-verify", "-pubin", "-inkey", key_pem, "-rawin", "-in", path,
                               "-sigfile", sig], capture_output=True).returncode == 0


def verify(args):
    ok = verified(args.file, args.public_key)
    print("verified" if ok else "BAD SIGNATURE")
    return 0 if ok else 1


def check(args):
    """The release gate (2026-10-20, Lawrence: "the change log needs to be better at all times"):
    the whole digest validates, so a malformed entry fails the release. A build with nothing
    user-facing carries the generic "Fixes and improvements" entry (generic_whats_new_digest) and
    passes with a warning (claude-sr2, 2026-10-27). Notes with no entry at all, which `build` now
    leaves only when every highlight file failed validation, still fail."""
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "whats-new"))
    import validate

    notes = json.loads(Path(args.notes).read_text())
    digest = notes.get("whatsNew") or {}
    entries = digest.get("entries") or []
    if not entries:
        print(f"{args.notes}: no What's New entries for {notes.get('shortVersion')}: its highlight files did not "
              "validate (the build log names each dropped one). Fix them (see release-notes/next/WRITING.md).",
              file=sys.stderr)
        return 1
    problems = validate.validate_document(f"{digest.get('version')}.json", digest)
    if problems:
        print("\n".join(problems), file=sys.stderr)
        return 1
    if is_generic(entries):
        message = (f"No What's New entries for {notes.get('shortVersion')}: publishing the generic \"Fixes and "
                   f"improvements\" entry ({entries[0]['docs']}). Land a user-facing commit or add "
                   "release-notes/next/highlights/<name>.md (see release-notes/next/WRITING.md).")
        print(f"::warning title=Generic What's New entry::{message}")
        summary = os.environ.get("GITHUB_STEP_SUMMARY")
        if summary:
            with open(summary, "a", encoding="utf-8") as out:
                out.write(f"### Generic What's New entry\n\n{message}\n")
        return 0
    print(f"ok: {len(entries)} What's New entries: " + "; ".join(e["title"]["en"] for e in entries[:3]))
    return 0


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build")
    b.add_argument("--build", required=True)
    b.add_argument("--short", required=True)
    b.add_argument("--date", required=True)
    b.add_argument("--head", required=True)
    b.add_argument("--since", default="")
    b.add_argument("--out", default="notes")
    b.add_argument("--pr-media", action="store_true",
                   help="give each highlight the first pr-media picture of the pull request that added it (needs gh)")
    b.add_argument("--pr-descriptions", action="store_true",
                   help="derive one-line descriptions from PR bodies at release time (needs gh)")
    a = sub.add_parser("appcast")
    a.add_argument("--head", required=True)
    a.add_argument("--since", default="")
    a.add_argument("--appcasts", required=True)
    a.add_argument("--build", required=True)
    a.add_argument("--feeds", nargs="+", required=True)
    p = sub.add_parser("prs")
    p.add_argument("--head", required=True)
    p.add_argument("--since", default="")
    p.add_argument("--repo", default="manaflow-ai/cmux")
    p.add_argument("--limit", type=int, default=PR_LIMIT)
    i = sub.add_parser("index")
    i.add_argument("--notes", required=True)
    i.add_argument("--previous")
    i.add_argument("--keep", type=int, default=50)
    i.add_argument("--out", required=True)
    f = sub.add_parser("backfill")
    f.add_argument("--index", required=True)
    f.add_argument("--base", action="append", required=True)
    f.add_argument("--public-key", required=True)
    f.add_argument("--out", required=True)
    f.add_argument("--existing", help="a folder whose notes are not backfilled (this build's)")
    f.add_argument("--limit", type=int, default=50)
    n = sub.add_parser("since")
    n.add_argument("--index", required=True)
    n.add_argument("--not", dest="skip", default="")
    s = sub.add_parser("sign")
    s.add_argument("--key", required=True)
    s.add_argument("files", nargs="+")
    v = sub.add_parser("verify")
    v.add_argument("--public-key", required=True)
    v.add_argument("file")
    c = sub.add_parser("check")
    c.add_argument("--notes", required=True)
    args = parser.parse_args()
    return {"build": build, "appcast": appcast, "prs": prs, "index": index, "since": since, "backfill": backfill,
            "sign": sign, "verify": verify, "check": check}[args.cmd](args) or 0


if __name__ == "__main__":
    sys.exit(main())
