#!/usr/bin/env python3
"""A ready-to-post community summary of a What's New document
(decision BOTTOM-LEFT-CARDS-AND-NIGHTLY-CHANGELOG K2).

Two sections in one Markdown file: an X post (at most 280 characters, the
headline, the top entries, the link) and a longer Discord post (every entry by
category). A human posts it; nothing here posts anything.

  community.py DOCUMENT.json [--url URL] [--out FILE]
"""
import argparse, json, sys

X_LIMIT = 280
CATEGORY_TITLES = {"new": "New", "improved": "Improved", "fixed": "Fixed", "security": "Security"}


def title_for(document):
    kind = "Nightly " if document["channel"] == "nightly" else ""
    return f"cmux {kind}{document['version']}"


def x_post(document, url):
    head = f"{title_for(document)}: {document['headline']['en']}"
    tail = f"\n\n{url}" if url else ""
    lines = [head]
    for entry in document["entries"]:
        if entry["title"]["en"] == document["headline"]["en"]:
            continue
        candidate = "\n".join(lines + [f"• {entry['title']['en']}"]) + tail
        if len(candidate) > X_LIMIT:
            break
        lines.append(f"• {entry['title']['en']}")
    text = "\n".join(lines) + tail
    if len(text) > X_LIMIT:
        text = head[: X_LIMIT - len(tail) - 1].rstrip() + "…" + tail
    return text


def discord_post(document, url):
    out = [f"**{title_for(document)}** · {document['date']}", document["headline"]["en"], ""]
    for category, label in CATEGORY_TITLES.items():
        entries = [e for e in document["entries"] if e["category"] == category]
        if not entries:
            continue
        out.append(f"__{label}__")
        out += [f"• **{e['title']['en']}**: {e['summary']['en']}" for e in entries]
        out.append("")
    if url:
        out.append(url)
    return "\n".join(out).strip() + "\n"


def summary(document, url=""):
    """The Markdown file a human posts from, or None for a document with no entries."""
    if not document.get("entries"):
        return None
    return ("<!-- Ready to post by hand. Nothing posts this automatically. -->\n\n"
            f"## X\n\n{x_post(document, url)}\n\n## Discord\n\n{discord_post(document, url)}")


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("document")
    parser.add_argument("--url", default="")
    parser.add_argument("--out")
    args = parser.parse_args(argv)
    with open(args.document, encoding="utf-8") as f:
        text = summary(json.load(f), args.url)
    if text is None:
        print("no entries: no community summary", file=sys.stderr)
        return 0
    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            f.write(text)
        print(args.out)
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
