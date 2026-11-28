#!/usr/bin/env python3
"""The nightly What's New digest (decision WHATS-NEW-AFTER-UPDATE W3).

A nightly needs no human review: its digest is built from the highlight files
added in the nightly's commit range (release-notes/next/highlights/*.md, the
same files the signed release notes use). Each file is one entry:

    title: Updates you barely notice
    category: improved                      (new | improved | fixed | security; default new)
    action: palette.checkForUpdates | Try it   (optional try-it action)
    docs: https://cmux.com/docs/updates        (optional)
    platforms: macos, cli                      (optional; default macos)
    audience: all                              (optional; default all)

    One or two sentences for users, benefit first.

English only (nightly); stable and RC files are written by the release skill
and reviewed. The result passes validate.py with channel nightly; a range with
no highlight file gives a digest with no entries, which the app does not show.

  digest.py --version 1.0.0-nightly.N --date YYYY-MM-DD --head SHA [--since SHA] [--out FILE]
"""
import argparse, json, os, re, subprocess, sys

HIGHLIGHTS = "release-notes/next/highlights"
HEADLINE_ONE = "{title}"
HEADLINE_MANY = "{title}, and {count} more"
HEADLINE_NONE = "Fixes and improvements"


def git(*args):
    return subprocess.run(["git", *args], capture_output=True, text=True, check=True).stdout


def parse(path, text):
    """One highlight file as a digest entry (raises ValueError on a bad file)."""
    head, _, body = text.partition("\n\n")
    meta = {}
    for line in head.splitlines():
        key, sep, value = line.partition(":")
        if sep:
            meta[key.strip().lower()] = value.strip()
    if "title" not in meta:
        raise ValueError(f"{path}: a highlight needs a 'title:' line")
    summary = " ".join(body.split())
    if not summary:
        raise ValueError(f"{path}: a highlight needs a body (one or two sentences)")
    entry_id = re.sub(r"[^a-z0-9]+", "-", os.path.splitext(os.path.basename(path))[0].lower()).strip("-")
    entry = {
        "id": entry_id,
        "category": meta.get("category", "new"),
        "title": {"en": meta["title"]},
        "summary": {"en": summary},
        "platforms": [p.strip() for p in meta.get("platforms", "macos").split(",") if p.strip()],
        "audience": meta.get("audience", "all"),
    }
    if meta.get("action"):
        entry["tryIt"] = {"action": meta["action"].partition("|")[0].strip()}
    if meta.get("docs"):
        entry["docs"] = meta["docs"]
    return entry


def headline(entries):
    if not entries:
        return HEADLINE_NONE
    first = entries[0]["title"]["en"]
    if len(entries) == 1:
        return HEADLINE_ONE.format(title=first)
    return HEADLINE_MANY.format(title=first, count=len(entries) - 1)


def entry_problems(entry):
    """The validator's problems for one entry alone (a nightly document around it)."""
    import validate
    document = {"schemaVersion": 1, "version": "0.0.0-nightly.1", "channel": "nightly", "date": "2026-01-01",
                "headline": {"en": "Highlights"}, "entries": [entry]}
    return validate.validate_document("0.0.0-nightly.1.json", document)


def build(version, date, head, since="", report=lambda line: print(line, file=sys.stderr)):
    """The digest of the highlight files added in since..head. A file that does not
    parse or validate is skipped with a report, so one bad file never empties the digest."""
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    span = f"{since}..{head}" if since else head
    added = git("log", "--diff-filter=A", "--name-only", "--format=", span, "--", HIGHLIGHTS).split()
    entries = []
    for path in sorted({p for p in added if p.endswith(".md")}):
        try:
            entry = parse(path, git("show", f"{head}:{path}"))
        except ValueError as error:
            report(f"skipped {path}: {error}")
            continue
        problems = entry_problems(entry)
        if problems:
            report(f"skipped {path}: " + "; ".join(p.split(": ", 2)[-1] for p in problems))
            continue
        entries.append(entry)
    # New features first, then improved, fixed, security; file order inside a category.
    order = {"new": 0, "improved": 1, "fixed": 2, "security": 3}
    entries.sort(key=lambda entry: order.get(entry["category"], 9))
    return {"schemaVersion": 1, "version": version, "channel": "nightly", "date": date,
            "headline": {"en": headline(entries)}, "entries": entries}


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", required=True)
    parser.add_argument("--date", required=True)
    parser.add_argument("--head", required=True)
    parser.add_argument("--since", default="")
    parser.add_argument("--out")
    args = parser.parse_args(argv)
    import validate
    document = build(args.version, args.date, args.head, args.since)
    problems = validate.validate_document(f"{args.version}.json", document)
    if problems:
        print("\n".join(problems), file=sys.stderr)
        return 1
    text = json.dumps(document, ensure_ascii=False, indent=2) + "\n"
    if args.out:
        with open(args.out, "w", encoding="utf-8") as out:
            out.write(text)
        print(args.out)
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
