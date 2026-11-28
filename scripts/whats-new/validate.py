#!/usr/bin/env python3
"""Validates cmux What's New documents (decision WHATS-NEW-AFTER-UPDATE W2/W3).

A document is whats-new/<version>.json (schema: schemas/whats-new/v1.schema.json).
This is the release gate: the release scripts refuse to cut a stable or RC
build unless the file for its version exists and this script exits 0.

Checks, beyond the schema shape:
  - the file name equals the version; the channel matches the version suffix
  - every entry has a try-it action/deeplink or a docs link
  - user text carries no internal names: bead ids, PR or issue numbers,
    commit SHAs, branch/lane names, spec ids, decision codenames
  - length limits (headline, title, summary; a summary is 1-2 sentences)
  - stable/rc: every supported language present in every localized field;
    nightly: English is enough (machine digest, no review)
  - stable/rc: every "new" entry has media; media files exist (light + dark)

  validate.py [--root DIR] [--require-version V] [--draft] FILE...
  validate.py --root whats-new --require-version 0.66.0     the release gate
--draft checks a release skill draft before localization and media capture:
every rule except "every language present" and "new entries need media".
Exit 0 when every file passes; 1 with one line per problem otherwise.
"""
import argparse, json, os, re, sys

SCHEMA_VERSION = 1
# The languages every cmux string table ships (scripts/cmux-next/check-l10n.sh).
LANGUAGES = ("en", "ar", "bs", "da", "de", "es", "fr", "it", "ja", "km", "ko", "nb",
             "pl", "pt-BR", "ru", "th", "tr", "uk", "vi", "zh-Hans", "zh-Hant")
CHANNELS = ("stable", "rc", "nightly")
CATEGORIES = ("new", "improved", "fixed", "security")
PLATFORMS = ("macos", "ios", "cli", "web")
AUDIENCES = ("all", "teams", "enterprise")
VERSION = re.compile(r"^(\d+)\.(\d+)\.(\d+)(?:-(rc|nightly)\.(\d+))?$")
ENTRY_ID = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")
ACTION_ID = re.compile(r"^[A-Za-z][A-Za-z0-9_.-]*$")
MEDIA_PATH = re.compile(r"^media/[A-Za-z0-9._/-]+$")
IMAGE_EXT = (".png", ".jpg", ".jpeg", ".webp")
VIDEO_EXT = (".mp4", ".mov")
MAX_MEDIA_BYTES = 8 * 1024 * 1024
MAX_ENTRIES = 24
# English limits in characters; other languages get 1.6x (CJK is shorter,
# German and Russian run longer than English).
LIMITS = {"headline": 90, "title": 60, "summary": 240, "alt": 160}
FOREIGN_SLACK = 1.6
TOP_LEVEL = {"schemaVersion", "version", "channel", "date", "headline", "entries"}
ENTRY_KEYS = {"id", "category", "title", "summary", "media", "tryIt", "docs", "platforms", "audience"}

# Internal names that never reach users. Each is (pattern, what it is).
INTERNAL = [
    (re.compile(r"\bcx-[a-z0-9]+(\.[0-9]+)*\b", re.I), "a beads issue id"),
    (re.compile(r"(?<![\w&])#\d{2,}\b"), "an issue or PR number"),
    (re.compile(r"\b(PR|pull request|issue)\s*#?\d+\b", re.I), "an issue or PR number"),
    (re.compile(r"github\.com/[^\s]+/(pull|issues)/\d+", re.I), "a PR or issue link"),
    (re.compile(r"\b[0-9a-f]{10,40}\b"), "a commit SHA"),
    (re.compile(r"\bfeat-[a-z0-9-]+\b", re.I), "a branch name"),
    (re.compile(r"\bcmux-next\b", re.I), "the internal rewrite name"),
    (re.compile(r"\bcmux-tui\b", re.I), "an internal crate name"),
    (re.compile(r"\bcmuxterm-hq\b|\bhq-[0-9a-z]{2,3}\b", re.I), "an internal repo or lane name"),
    (re.compile(r"\b(lane|coordinator|testbox|cmux-ci|nx-remote|beads?)\b", re.I), "internal process vocabulary"),
    (re.compile(r"\bR\d{2,3}\b"), "a spec requirement id"),
    (re.compile(r"\b[A-Z][A-Z0-9]+(?:-[A-Z0-9]+){2,}\b"), "a decision codename"),
    (re.compile(r"\b(TODO|TBD|FIXME|lorem ipsum)\b", re.I), "a placeholder"),
]
SENTENCE_END = re.compile(r"[.!?。！？](?=\s|$)")


class Problems:
    def __init__(self, path):
        self.path = path
        self.items = []

    def add(self, where, message):
        self.items.append(f"{self.path}: {where}: {message}")


def strict_channel(channel, draft=False):
    return channel in ("stable", "rc") and not draft


def check_text(problems, where, text, kind, language):
    if not isinstance(text, str) or not text.strip():
        problems.add(where, f"{language} is empty")
        return
    if text != text.strip():
        problems.add(where, f"{language} has leading or trailing space")
    limit = LIMITS[kind] if language == "en" else int(LIMITS[kind] * FOREIGN_SLACK)
    if len(text) > limit:
        problems.add(where, f"{language} is {len(text)} characters (limit {limit})")
    for pattern, what in INTERNAL:
        found = pattern.search(text)
        if found:
            problems.add(where, f"{language} names {what} ({found.group(0)!r}); write it for users")
    if kind == "summary" and language == "en" and len(SENTENCE_END.findall(text)) > 2:
        problems.add(where, "en has more than 2 sentences")
    if kind in ("title", "headline") and text.endswith("."):
        problems.add(where, f"{language} ends with a period")


def check_localized(problems, where, value, kind, channel, draft=False):
    if not isinstance(value, dict) or not value:
        problems.add(where, "must be an object of language -> text")
        return
    if "en" not in value:
        problems.add(where, "has no en text")
    unknown = sorted(set(value) - set(LANGUAGES))
    if unknown:
        problems.add(where, f"unknown languages {unknown} (use {', '.join(LANGUAGES)})")
    if strict_channel(channel, draft):
        missing = [language for language in LANGUAGES if language not in value]
        if missing:
            problems.add(where, f"missing languages {missing}")
    for language, text in value.items():
        if language in LANGUAGES:
            check_text(problems, where, text, kind, language)


def check_media(problems, where, media, channel, root, draft=False):
    if not isinstance(media, dict):
        problems.add(where, "media must be an object")
        return
    extra = sorted(set(media) - {"kind", "light", "dark", "alt"})
    if extra:
        problems.add(where, f"media has unknown keys {extra}")
    kind = media.get("kind")
    if kind not in ("image", "video"):
        problems.add(where, "media.kind must be image or video")
    extensions = IMAGE_EXT if kind == "image" else VIDEO_EXT
    for appearance in ("light", "dark"):
        path = media.get(appearance)
        if not isinstance(path, str) or not MEDIA_PATH.match(path) or ".." in path.split("/"):
            problems.add(where, f"media.{appearance} must be a path under media/")
            continue
        if not path.lower().endswith(extensions):
            problems.add(where, f"media.{appearance} must end with one of {extensions}")
        if root is not None:
            full = os.path.join(root, path)
            if not os.path.isfile(full):
                problems.add(where, f"media.{appearance} file {path} does not exist")
            elif os.path.getsize(full) > MAX_MEDIA_BYTES:
                problems.add(where, f"media.{appearance} is over {MAX_MEDIA_BYTES // (1024 * 1024)} MB")
    if media.get("light") and media.get("light") == media.get("dark"):
        problems.add(where, "media.light and media.dark are the same file")
    check_localized(problems, f"{where}.alt", media.get("alt"), "alt", channel, draft)


def check_entry(problems, index, entry, channel, root, seen, draft=False):
    where = f"entries[{index}]"
    if not isinstance(entry, dict):
        problems.add(where, "must be an object")
        return
    entry_id = entry.get("id")
    if isinstance(entry_id, str):
        where = f"entries[{index}] ({entry_id})"
    extra = sorted(set(entry) - ENTRY_KEYS)
    if extra:
        problems.add(where, f"unknown keys {extra}")
    if not isinstance(entry_id, str) or not ENTRY_ID.match(entry_id):
        problems.add(where, "id must be lowercase words joined by '-'")
    elif entry_id in seen:
        problems.add(where, "id is used twice")
    else:
        seen.add(entry_id)
    if entry.get("category") not in CATEGORIES:
        problems.add(where, f"category must be one of {CATEGORIES}")
    check_localized(problems, f"{where}.title", entry.get("title"), "title", channel, draft)
    check_localized(problems, f"{where}.summary", entry.get("summary"), "summary", channel, draft)
    platforms = entry.get("platforms")
    if not isinstance(platforms, list) or not platforms or any(p not in PLATFORMS for p in platforms) \
            or len(set(platforms)) != len(platforms):
        problems.add(where, f"platforms must be a non-empty list of distinct {PLATFORMS}")
    if entry.get("audience") not in AUDIENCES:
        problems.add(where, f"audience must be one of {AUDIENCES}")
    try_it, docs = entry.get("tryIt"), entry.get("docs")
    if try_it is not None:
        if not isinstance(try_it, dict) or len(try_it) != 1 or not set(try_it) <= {"action", "deeplink"}:
            problems.add(where, "tryIt must have exactly one of action or deeplink")
        elif "action" in try_it and not (isinstance(try_it["action"], str) and ACTION_ID.match(try_it["action"])):
            problems.add(where, "tryIt.action must be a registry action id")
        elif "deeplink" in try_it and not (isinstance(try_it["deeplink"], str) and try_it["deeplink"].startswith("cmux://")):
            problems.add(where, "tryIt.deeplink must start with cmux://")
    if docs is not None and not (isinstance(docs, str) and re.match(r"^https://[^\s]+$", docs)):
        problems.add(where, "docs must be an https URL")
    if try_it is None and docs is None:
        problems.add(where, "needs a tryIt action/deeplink or a docs link")
    media = entry.get("media")
    if media is not None:
        check_media(problems, f"{where}.media", media, channel, root, draft)
    elif strict_channel(channel, draft) and entry.get("category") == "new":
        problems.add(where, "a new feature needs media (light and dark screenshot or video)")


def validate_document(path, document, root=None, draft=False):
    """The problems of one parsed document (list of strings, empty when valid).
    draft: skip the language-completeness and media-required rules (a release
    skill draft before its localization and capture passes)."""
    problems = Problems(path)
    if not isinstance(document, dict):
        problems.add("document", "must be a JSON object")
        return problems.items
    extra = sorted(set(document) - TOP_LEVEL)
    if extra:
        problems.add("document", f"unknown keys {extra}")
    missing = sorted(TOP_LEVEL - set(document))
    if missing:
        problems.add("document", f"missing keys {missing}")
    if document.get("schemaVersion") != SCHEMA_VERSION:
        problems.add("schemaVersion", f"must be {SCHEMA_VERSION}")
    version = document.get("version")
    match = VERSION.match(version) if isinstance(version, str) else None
    channel = document.get("channel")
    if not match:
        problems.add("version", "must be X.Y.Z, X.Y.Z-rc.N or X.Y.Z-nightly.N")
    else:
        expected = match.group(4) or "stable"
        if channel != expected:
            problems.add("channel", f"is {channel!r} but version {version} is {expected!r}")
        name = os.path.basename(path)
        if name.endswith(".json") and name != f"{version}.json":
            problems.add("version", f"file must be named {version}.json")
    if channel not in CHANNELS:
        problems.add("channel", f"must be one of {CHANNELS}")
    if not (isinstance(document.get("date"), str) and re.match(r"^\d{4}-\d{2}-\d{2}$", document["date"])):
        problems.add("date", "must be YYYY-MM-DD")
    check_localized(problems, "headline", document.get("headline"), "headline", channel, draft)
    entries = document.get("entries")
    if not isinstance(entries, list):
        problems.add("entries", "must be a list")
        return problems.items
    if strict_channel(channel) and not entries:
        problems.add("entries", "a stable or rc release needs at least one entry")
    if len(entries) > MAX_ENTRIES:
        problems.add("entries", f"has {len(entries)} entries (limit {MAX_ENTRIES}); group related changes")
    seen = set()
    for index, entry in enumerate(entries):
        check_entry(problems, index, entry, channel, root, seen, draft)
    return problems.items


def validate_file(path, root=None, draft=False):
    try:
        with open(path, encoding="utf-8") as f:
            document = json.load(f)
    except (OSError, ValueError) as error:
        return [f"{path}: unreadable JSON ({error})"]
    if root is None:
        root = os.path.dirname(os.path.abspath(path))
    return validate_document(path, document, root, draft)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", help="the whats-new directory (media paths resolve here)")
    parser.add_argument("--require-version", help="fail unless <root>/<version>.json exists and passes")
    parser.add_argument("--draft", action="store_true", help="skip the language and media completeness rules")
    parser.add_argument("files", nargs="*")
    args = parser.parse_args(argv)
    files = list(args.files)
    problems = []
    if args.require_version:
        root = args.root or "whats-new"
        required = os.path.join(root, f"{args.require_version}.json")
        if not os.path.isfile(required):
            problems.append(f"{required}: missing. Run the release skill's whats-new step and merge its PR first.")
        elif required not in files:
            files.append(required)
    if not files and not problems:
        parser.error("name a file or --require-version")
    for path in files:
        problems.extend(validate_file(path, args.root, args.draft and not args.require_version))
    for line in problems:
        print(line)
    if not problems:
        print(f"ok: {len(files)} document(s) valid")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
