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

  release-notes.py build --build B --short S --date D --head SHA [--since SHA] [--out DIR]
  release-notes.py index --notes DIR/B.json [--previous index.json] [--keep 50] --out DIR/index.json
  release-notes.py sign --key KEY.pem FILE...       writes FILE.sig
  release-notes.py verify --public-key BASE64 FILE  checks FILE.sig
"""
import argparse, base64, json, os, re, subprocess, sys, tempfile

HIGHLIGHTS = "release-notes/next/highlights"
MAX_CHANGES = 200


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
             "highlights": highlights, "changes": changes, "items": items}
    digest = whats_new_digest(args)
    if digest is not None:
        notes["whatsNew"] = digest
        write_community_summary(digest, args)
    os.makedirs(args.out, exist_ok=True)
    path = os.path.join(args.out, f"{args.build}.json")
    with open(path, "w", encoding="utf-8") as out:
        json.dump(notes, out, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    print(path)


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
    return {"build": build, "index": index, "sign": sign, "verify": verify}[args.cmd](args) or 0


if __name__ == "__main__":
    sys.exit(main())
