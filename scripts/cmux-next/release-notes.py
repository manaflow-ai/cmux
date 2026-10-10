#!/usr/bin/env python3
"""Signed release notes for the cmux-next in-app changelog (R114).

Each published build gets `notes/<build>.json` and a detached Ed25519
signature `notes/<build>.json.sig` (base64, the `content-signing` key), plus
a signed `notes/index.json` listing recent builds for the full history.

The notes also carry the build's What's New digest ("whatsNew", decision
WHATS-NEW-AFTER-UPDATE W3; scripts/whats-new/digest.py) built from the same
highlight files, when they validate.

Highlights are human-written: one Markdown file per highlight under
release-notes/next/highlights/. A highlight belongs to the first build whose
commit range adds its file, so writing the file is all a person does. Front
matter (lines before the first blank line):

    title: Updates you barely notice
    action: palette.checkForUpdates | Try it      (optional "Try it" button)

The rest is the body (Markdown). A build with no new highlight file ships
only its commit subjects (full history, no what's-new card). Each commit is
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
  release-notes.py index --notes DIR/B.json [--previous index.json] [--keep 50] --out DIR/index.json
  release-notes.py sign --key KEY.pem FILE...       writes FILE.sig
  release-notes.py verify --public-key BASE64 FILE  checks FILE.sig
"""
import argparse, base64, json, os, re, subprocess, sys, tempfile
from pathlib import Path

HIGHLIGHTS = "release-notes/next/highlights"
MAX_CHANGES = 200
SUMMARY_LIMIT = 8
GROUP_TITLES = {"new": "New", "fixed": "Fixed", "changed": "Changed"}
# Conventional types that never reach a person.
INTERNAL_TYPES = {"ci", "test", "tests", "refactor", "docs", "doc", "chore", "style", "build", "lint", "release-note",
                  "release-notes", "revert", "merge", "bench", "gallery"}
# Scopes of fix/feat commits that are about the pipeline or plumbing, not the app.
INTERNAL_SCOPES = {"ci", "nightly", "fleet", "release", "build", "tests", "test", "gallery", "crash", "lint", "docs",
                   "feat-cmux-next", "browser-parity", "first-party-apps", "browser-automation", "automation", "daemon",
                   "protocol", "sdk", "cmux-tui", "app-ffi", "backend"}
# Subject words that mark internal work even without a type.
INTERNAL_WORDS = re.compile(
    r"\b(red|unit tests?|tests?|godfile|crash ratchet|baseline|index_subscript|int_conversion|lint|repin|re-pin|pin|"
    r"canary|fleet|review findings|move-only|ci|testbox|bisect|fixture|snapshot tests?|tree key|r2|ffi pin|budget|"
    r"isolated|wiring|socket|daemon|capabilit\w*|struct|type|owner|protocol|schema|sdk|refactor|smoke|acpmux|optchat-chief)\b", re.I)
# Code-looking subjects (dotted names, snake_case, versioned ids, backticks) are internal.
CODE_LIKE = re.compile(r"`|\b\w+\.\w+\b|\w_\w|\w-v\d\b|\[cx-")
CONVENTIONAL = re.compile(r"^(?P<type>[A-Za-z-]+)(?:\((?P<scope>[^)]*)\))?!?:\s*(?P<rest>.+)$")
AREA_PREFIX = re.compile(r"^(cmux-next|cmuxnext|cmux next|acpmux|apps?|browser|gallery|release notes?|cx-[\w.]+|feed [\d.]+)\s*:\s*", re.I)
# "(#123)", "(cx-abc)", "(cx-2y2 items 6, 10)", "(red)": references, anywhere in the subject.
REFS = re.compile(r"\s*\((?:[^()]*\bcx-[\w.]+[^()]*|#\d+|red)\)", re.I)

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
    text = AREA_PREFIX.sub("", text)
    text = REFS.sub("", text).strip(" .")
    if not text or INTERNAL_WORDS.search(text) or CODE_LIKE.search(text):
        return None
    if group == "changed" and re.match(r"^(add|adds|new|introduce|support|show)\b", text, re.I):
        group = "new"
    elif group == "changed" and re.match(r"^(fix|fixes|repair|stop|keep)\b", text, re.I):
        group = "fixed"
    if len(text) > 90:
        text = text[:89].rsplit(" ", 1)[0] + "…"
    return group, text[:1].upper() + text[1:]


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
    problems = validate.validate_document(f"{args.short}.json", document)
    if problems:
        print("whats-new digest skipped:\n" + "\n".join(problems), file=sys.stderr)
        return None
    return document if document["entries"] else None


def write_community_summary(digest, args):
    """notes/community-<build>.md: a short Discord/X summary a human posts (K2); the
    release-notes artifact keeps it and the R2 upload publishes it with the notes."""
    import community
    text = community.summary(digest, f"https://cmux.com/whats-new/{digest['version']}")
    if text:
        os.makedirs(args.out, exist_ok=True)
        with open(os.path.join(args.out, f"community-{args.build}.md"), "w", encoding="utf-8") as out:
            out.write(text)


def build(args):
    span = rev_range(args.since, args.head)
    commits = [line.split("\x1f", 1) for line in git("log", "--no-merges", "--format=%s%x1f%an", span).splitlines() if line.strip()]
    commits = [(c[0], c[1] if len(c) > 1 else "") for c in commits if c[0].strip()][:MAX_CHANGES]
    changes = [subject for subject, _ in commits]
    items = [change_item(subject, author) for subject, author in commits]
    added = git("log", "--diff-filter=A", "--name-only", "--format=", span, "--", HIGHLIGHTS).split()
    highlights = []
    for path in sorted(set(p for p in added if p.endswith(".md"))):
        highlights.append(parse_highlight(path, git("show", f"{args.head}:{path}")))
    notes = {"version": 1, "build": args.build, "shortVersion": args.short, "date": args.date,
             "highlights": highlights, "changes": changes, "items": items, "summary": summarize_changes(changes)}
    digest = whats_new_digest(args)
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
    builds = [entry] + [b for b in builds if b.get("build") != notes["build"]]
    with open(args.out, "w", encoding="utf-8") as out:
        json.dump({"version": 1, "builds": builds[: args.keep]}, out, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    print(args.out)


def sign(args):
    for path in args.files:
        raw = subprocess.run(["openssl", "pkeyutl", "-sign", "-inkey", args.key, "-rawin", "-in", path],
                             capture_output=True, check=True).stdout
        with open(path + ".sig", "w") as out:
            out.write(base64.b64encode(raw).decode() + "\n")
        print(path + ".sig")


def verify(args):
    der = bytes.fromhex("302a300506032b6570032100") + base64.b64decode(args.public_key)
    with tempfile.TemporaryDirectory() as tmp:
        key_der, key_pem, sig = (os.path.join(tmp, n) for n in ("pub.der", "pub.pem", "sig.bin"))
        with open(key_der, "wb") as f:
            f.write(der)
        subprocess.run(["openssl", "pkey", "-pubin", "-inform", "DER", "-in", key_der, "-out", key_pem], check=True, capture_output=True)
        with open(args.file + ".sig") as f, open(sig, "wb") as out:
            out.write(base64.b64decode(f.read().strip()))
        ok = subprocess.run(["openssl", "pkeyutl", "-verify", "-pubin", "-inkey", key_pem, "-rawin", "-in", args.file,
                             "-sigfile", sig], capture_output=True).returncode == 0
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
    i = sub.add_parser("index")
    i.add_argument("--notes", required=True)
    i.add_argument("--previous")
    i.add_argument("--keep", type=int, default=50)
    i.add_argument("--out", required=True)
    s = sub.add_parser("sign")
    s.add_argument("--key", required=True)
    s.add_argument("files", nargs="+")
    v = sub.add_parser("verify")
    v.add_argument("--public-key", required=True)
    v.add_argument("file")
    args = parser.parse_args()
    return {"build": build, "appcast": appcast, "index": index, "sign": sign, "verify": verify}[args.cmd](args) or 0


if __name__ == "__main__":
    sys.exit(main())
