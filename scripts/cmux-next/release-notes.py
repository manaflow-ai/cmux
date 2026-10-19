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

  release-notes.py build --build B --short S --date D --head SHA [--since SHA] [--out DIR]
  release-notes.py appcast --head SHA [--since SHA] --appcasts DIR --build B --feeds F...
  release-notes.py prs --head SHA [--since SHA] [--repo O/R] [--limit N]   the GitHub release's "PRs in this build"
  release-notes.py index --notes DIR/B.json [--previous index.json] [--keep 50] --out DIR/index.json
  release-notes.py backfill --index I --base URL... --public-key K --out DIR   adds summary/items to old notes
  release-notes.py since --index index.json [--not SHA]  prints the newest build's head commit (the next span's start)
  release-notes.py sign --key KEY.pem FILE...       writes FILE.sig
  release-notes.py verify --public-key BASE64 FILE  checks FILE.sig
"""
import argparse, base64, json, os, re, subprocess, sys, tempfile
from pathlib import Path

HIGHLIGHTS = "release-notes/next/highlights"
MAX_CHANGES = 200
SUMMARY_LIMIT = 8
PR_LIMIT = 40
GROUP_TITLES = {"new": "New", "fixed": "Fixed", "changed": "Changed"}
# Conventional types that never reach a person.
INTERNAL_TYPES = {"ci", "test", "tests", "refactor", "docs", "doc", "chore", "style", "build", "lint", "release-note",
                  "release-notes", "revert", "merge", "bench", "gallery"}
# Scopes of fix/feat commits that are about the pipeline or plumbing, not the app.
INTERNAL_SCOPES = {"ci", "nightly", "fleet", "release", "build", "tests", "test", "gallery", "crash", "lint", "docs",
                   "feat-cmux-next", "browser-parity", "first-party-apps", "browser-automation", "automation", "daemon",
                   "protocol", "sdk", "cmux-tui", "app-ffi", "backend", "nightly-next", "e2e", "harness", "deps"}
# Subject words that mark internal work even without a type.
INTERNAL_WORDS = re.compile(
    r"\b(red|unit tests?|tests?|godfile|crash ratchet|baseline|index_subscript|int_conversion|lint|repin|re-pin|pin|"
    r"canary|fleet|review findings|move-only|ci|testbox|bisect|fixture|snapshot tests?|tree key|r2|ffi pin|budget|"
    r"isolated|wiring|socket|daemon|capabilit\w*|struct|type|owner|protocol|schema|sdk|refactor|smoke|acpmux|optchat-chief|"
    r"e2e|gallery|release notes?|publish\w*|pipeline|workflow|telemetry|crash reporting|exception reporting|benchmark|"
    r"frame budget|osc \d+|terminal host|seed|record\w*|nightly|headless|ffi|rust|regenerate|decode|renderer|texture|"
    r"machine code|scene captures?|policy log|host log|force unwrap|store intent|property model|false positive|inventory|"
    r"boundary|on the wire|debug reports?|dom events?|keybind actions?|main actor|shims?|"
    r"consumers?|metrics|review fixes|base reds?|feat-cmux-next|compile fix(?:es)?)\b", re.I)
# Product names whose casing is not code ("MacOS": a title capitalized before LEADING_BRAND).
BRANDS = re.compile(r"\b(?:[Mm]acOS|[Ii]OS|[Ii]PadOS|[Ii]Cloud|[Ii]Phone|[Ii]Pad|GitHub|YouTube|SwiftUI|WebKit|JavaScript|TypeScript|ChatGPT|OpenAI)\b")
# Code-looking subjects (dotted names, snake_case, versioned ids, bead ids, backticks) are internal.
CODE_LIKE = re.compile(r"`|\b[A-Za-z_]\w*\.[A-Za-z_]\w*\b|\w_\w|\w-v\d\b|\[cx-|\bcx-[a-z0-9]{3,}|\b[a-z]+[A-Z]\w*|\b[A-Z][a-z]+[A-Z]\w*|\b[A-Z]{2,}(?:-[A-Z]+)+\b|\{\w+\}")
CONVENTIONAL = re.compile(r"^(?P<type>[A-Za-z-]+)(?:\((?P<scope>[^)]*)\))?!?:\s*(?P<rest>.+)$")
AREA_PREFIX = re.compile(r"^(cmux-next(?: \w+){0,2}|cmuxnext|cmux next|acpmux|apps?|browser|gallery|release notes?|cx-[\w.]+|feed [\d.]+|cmux-tui)\s*:\s*", re.I)
# "area words: rest" after the conventional type: "cmux NEXT perf-split: review: …", "cmux-next strip: …".
LABEL = re.compile(r"^(?P<area>[A-Za-z][\w-]*(?: [A-Za-z][\w-]*){0,2})(?:\((?P<scope>[^)]*)\))?!?:\s+(?P<rest>\S.*)$")
# Work streams that measure or check the app (perf-split, perf-gate, motion-record, strip-scroll-check).
INTERNAL_AREA_SHAPE = re.compile(r"^(?:perf-[\w-]+|[\w-]+-(?:check|record|gate|bench|probe)|motion-record|review|gate|base-red)$", re.I)
PRODUCT_WORDS = {"cmux", "next", "cmux-next", "cmuxnext"}
# "(#123)", "(hq#45)", "(cx-abc)", "(cx-2y2 items 6, 10)", "(red)", "(review)", anywhere in the
# subject, and a bead reference cut off at the end.
REFS = re.compile(r"\s*\((?:[^()]*\bcx-[\w.]+[^()]*|[\w-]*#\d+|red|review)\)|\s*\((?:[^()]*\b)?cx-[\w.]*$", re.I)

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
        if any(INTERNAL_AREA_SHAPE.match(w) for w in words + scopes):
            return None
        text = label["rest"]
    text = AREA_PREFIX.sub("", text)
    text = REFS.sub("", text).strip(" .")
    if not text or INTERNAL_WORDS.search(text) or CODE_LIKE.search(BRANDS.sub("", text)):
        return None
    if group == "changed" and re.match(r"^(add|adds|new|introduce|support|show)\b", text, re.I):
        group = "new"
    elif group == "changed" and re.match(r"^(fix|fixes|repair|stop|keep)\b", text, re.I):
        group = "fixed"
    # Whole: the page wraps a long line, and short_title gives the digest a title that fits.
    return group, capitalized(text)


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


def summarize_changes(subjects, limit=SUMMARY_LIMIT):
    """The user-facing lines, New then Fixed then Changed, newest first, deduplicated, at most `limit`."""
    seen, groups = set(), {"new": [], "fixed": [], "changed": []}
    for subject in subjects:
        entry = summary_entry(subject)
        if entry is None or entry[1].lower() in seen:
            continue
        seen.add(entry[1].lower())
        groups[entry[0]].append(entry[1])
    # A fair share per group first (New 3, Fixed 3, Changed 2), then the rest in order.
    chosen = {g: groups[g][:n] for g, n in (("new", 3), ("fixed", 3), ("changed", 2))}
    rest = [(g, t) for g in ("new", "fixed", "changed") for t in groups[g][len(chosen[g]):]]
    while sum(map(len, chosen.values())) < limit and rest:
        g, t = rest.pop(0)
        chosen[g].append(t)
    return [{"group": g, "title": t} for g in ("new", "fixed", "changed") for t in chosen[g]][:limit]


def summary_text(lines):
    """The appcast <description>: one plain line per change, "New: …"."""
    return "\n".join(f'{GROUP_TITLES[line["group"]]}: {line["title"]}' for line in lines)


def commit_subjects(since, head):
    span = rev_range(since, head)
    return [line for line in git("log", "--no-merges", "--format=%s", span).splitlines() if line.strip()][:MAX_CHANGES]


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
    return item


PR_SUFFIX = re.compile(r"^(?P<title>.*?)\s*\(#(?P<pr>\d+)\)\s*$")


def change_item(subject, author):
    """One structured change (UPDATE-CARD "What's changed"): the subject's
    title without its "(#1234)" suffix, the commit author, the PR number."""
    item = {"title": subject.strip(), "author": author.strip() or None}
    match = PR_SUFFIX.match(subject)
    if match and match["title"].strip():
        item["title"], item["pr"] = match["title"].strip(), int(match["pr"])
    return {k: v for k, v in item.items() if v is not None}


def whats_new_digest(args):
    """The What's New nightly digest of the same highlights (scripts/whats-new/digest.py),
    or None when it is empty or does not validate: the notes still publish."""
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "whats-new"))
    try:
        import digest, validate
        document = digest.build(args.short, args.date, args.head, args.since)
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


def summary_whats_new_digest(args, lines):
    """A validated nightly digest when there are summary lines but no highlight digest."""
    if not lines:
        return None
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "whats-new"))
    import validate

    document = {"schemaVersion": 1, "version": args.short, "channel": "nightly", "date": args.date,
                "headline": {"en": "Fixes and improvements"}, "entries": []}
    categories = {"new": "new", "fixed": "fixed", "changed": "improved"}
    for index, line in enumerate(lines):
        # A line with no clause short enough stays out of the digest; the page shows it whole
        # from the summary lines.
        title = short_title(line.get("title", ""), validate.LIMITS["title"])
        if not title or line.get("group") not in categories:
            continue
        # The summary says what the title leaves out, or repeats a title that is the whole line.
        full = " ".join(line["title"].split()).rstrip(". ")
        entry = {"id": f"summary-{index}", "category": categories[line["group"]],
                 "title": {"en": title}, "summary": {"en": title_tail(full, title) if title != full else full},
                 "platforms": ["macos"], "audience": "all", "docs": "https://cmux.com/docs/changelog"}
        problems = validate.validate_document(f"{args.short}.json", {**document, "entries": [entry]})
        if problems:
            print(f"whats-new summary: dropped {entry['id']}:\n" + "\n".join(problems), file=sys.stderr)
            continue
        document["entries"].append(entry)
    if not document["entries"]:
        return None
    document["headline"] = {"en": document["entries"][0]["title"]["en"]}
    problems = validate.validate_document(f"{args.short}.json", document)
    if problems:
        print("whats-new summary skipped:\n" + "\n".join(problems), file=sys.stderr)
        return None
    return document


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
    span = rev_range(since, head)
    commits = [line.split("\x1f", 1) for line in git("log", "--no-merges", "--format=%s%x1f%an", span).splitlines() if line.strip()]
    return [(c[0], c[1] if len(c) > 1 else "") for c in commits if c[0].strip()][:limit]


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
    commits = commits_with_authors(args.since, args.head)
    changes = [subject for subject, _ in commits]
    items = [change_item(subject, author) for subject, author in commits]
    added = git("log", "--diff-filter=A", "--name-only", "--format=", span, "--", HIGHLIGHTS).split()
    highlights = []
    for path in sorted(set(p for p in added if p.endswith(".md"))):
        highlights.append(parse_highlight(path, git("show", f"{args.head}:{path}")))
    # "head": the commit these notes end at; the next build's span starts there (`since`), so a
    # build whose notes never published loses no change to the build after it.
    notes = {"version": 1, "build": args.build, "shortVersion": args.short, "date": args.date, "head": args.head,
             "highlights": highlights, "changes": changes, "items": items, "summary": summarize_changes(changes)}
    digest = whats_new_digest(args)
    if digest is None:
        digest = summary_whats_new_digest(args, notes["summary"])
    if digest is not None:
        notes["whatsNew"] = digest
        write_community_summary(digest, args)
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
    args = parser.parse_args()
    return {"build": build, "appcast": appcast, "prs": prs, "index": index, "since": since, "backfill": backfill, "sign": sign, "verify": verify}[args.cmd](args) or 0


if __name__ == "__main__":
    sys.exit(main())
