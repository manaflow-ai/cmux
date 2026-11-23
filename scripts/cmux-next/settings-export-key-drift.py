#!/usr/bin/env python3
"""Refuse a settings export that lost a key its source declares, gained one no source has, or missed this change's own.

The settings exports (schemas/settings/settings-schema.json, the docs settings reference and the MDM
manifests in docs/mdm/) are written on a Mac by regenerate-settings-exports.sh. A pull request that
regenerates them at an older tree and then merges the base carries the old tree's key set: #43022 and
#43027 (2026-11-15) both dropped tabs.newTabApp, which schemas/settings/source/tabs.json still declared.
The Mac comparison (cmux-next generated files) is red on the base for other reasons, so nobody read it.

This reads only git objects, no build. It compares each export's key set at HEAD with BASE's and with
HEAD's sources (schemas/settings/source/*.json rows, schemas/settings/retired-keys.json):

  dropped  a key BASE's export has and HEAD's sources still declare with the same row as BASE's, missing from
           HEAD's export (a row the change edits, such as its consumers or whether the docs list it, may leave
           an export on purpose)
  extra    a key in HEAD's export that BASE's export lacks and no HEAD source declares
           (or that schemas/settings/retired-keys.json retires)

  unexported  a key HEAD's sources add (BASE's sources lack it) that HEAD's settings-schema.json lacks
  unremoved   a key HEAD's sources drop (BASE's sources had it) that HEAD's settings-schema.json still lists

Only keys count, never values or order. settings-schema.json alone is judged for the last two: it lists every source
row (gen-settings-sources.py --check), while the docs reference and the MDM files list only the rows they document.
Those two used to pass, on the promise that the PR autofix or the base autofix exports the change after the merge.
It did not: #44894 (appearance.themeFileExceptions) and the MCP Servers commit (agents.mcpServers.enabled) merged
unexported on 2026-11-18, every base autofix run after them was cancelled, and the base export lacked both keys for
two days, so every later pull request that added a setting failed its schema tests (cmuxterm-hq
docs/handbook/settings-export-from-an-older-base.md). With HEAD equal to BASE nothing can be found, so the check is
never red on the base.

Usage: settings-export-key-drift.py --repo DIR --base REV --head REV
Prints `drift: <export>: ...` per finding and exits 1 when it finds any, 0 when it finds none, 2 on error.
"""
from __future__ import annotations  # PEP 604 annotations on macOS's /usr/bin/python3 3.9

import argparse
import json
import plistlib
import re
import subprocess
import sys
import tempfile

SOURCE_DIR = "schemas/settings/source"
RETIRED = "schemas/settings/retired-keys.json"
# A cmux.json key path; MDM policy keys (capitalized, such as PayloadType) are not settings.
SETTING = re.compile(r"^[a-z][A-Za-z0-9_-]*(?:\.[A-Za-z0-9_-]+)+$")
MD_ROW = re.compile(r"^\| `([^`]+)` \|", re.MULTILINE)


def schema_keys(data: bytes) -> set[str]:
    return {row["key"] for row in json.loads(data)["rows"]}


def reference_keys(data: bytes) -> set[str]:
    return {row["key"] for section in json.loads(data)["sections"] for row in section["rows"]}


def mdm_json_keys(data: bytes) -> set[str]:
    return set(json.loads(data)["properties"])


def mdm_plist_keys(data: bytes) -> set[str]:
    return {entry["pfm_name"] for entry in plistlib.loads(data)["pfm_subkeys"] if "pfm_name" in entry}


def mdm_markdown_keys(data: bytes) -> set[str]:
    return set(MD_ROW.findall(data.decode("utf-8")))


SCHEMA = "schemas/settings/settings-schema.json"

# Every export that lists settings by key, and how to read its keys.
EXPORTS = {
    "schemas/settings/settings-schema.json": schema_keys,
    "web/data/next-docs/settings-reference.generated.json": reference_keys,
    "docs/mdm/com.manaflow.cmux.json": mdm_json_keys,
    "docs/mdm/com.manaflow.cmux.plist": mdm_plist_keys,
    "docs/mdm/managed-preferences.md": mdm_markdown_keys,
}


def settings(keys: set[str]) -> set[str]:
    return {key for key in keys if SETTING.match(key)}


def source_rows(files: dict[str, bytes]) -> dict[str, str]:
    """key -> the row's canonical JSON, for the source files FILES (path -> bytes): each one with a `lists` of rows."""
    rows = {}
    for data in files.values():
        loaded = json.loads(data)
        lists = loaded.get("lists") if isinstance(loaded, dict) else None
        for entry in lists if isinstance(lists, list) else []:
            if not isinstance(entry, dict) or not isinstance(entry.get("rows", []), list):
                raise ValueError("a `lists` entry is not {name, rows: [...]}: %r" % (entry,))
            for row in entry.get("rows", []):
                rows[row["key"]] = json.dumps(row, sort_keys=True)
    return rows


def retired_keys(data: bytes | None) -> set[str]:
    return {entry["key"] for entry in json.loads(data)["retired"]} if data else set()


def drift(base: dict[str, set[str]], head: dict[str, set[str]], base_rows: dict[str, str], head_rows: dict[str, str],
          retired: set[str]) -> list[str]:
    """`<export>: ...` per export whose HEAD keys (HEAD) lost a declared key BASE had, or gained an undeclared one.

    BASE and HEAD map an export path to its keys (an export missing at a side is left out of that side); BASE_ROWS
    and HEAD_ROWS map each source key to its row at that side."""
    sources = set(head_rows)
    unchanged = {key for key, row in head_rows.items() if base_rows.get(key) == row}
    found = []
    schema = head.get(SCHEMA)
    if schema is not None:
        unexported = (sources - set(base_rows)) - schema
        unremoved = (set(base_rows) - sources) & schema
        if unexported:
            found.append("%s: lacks %s, which this change adds to the sources (export it in this change)"
                         % (SCHEMA, ", ".join(sorted(unexported))))
        if unremoved:
            found.append("%s: still lists %s, which this change removes from the sources (export it in this change)"
                         % (SCHEMA, ", ".join(sorted(unremoved))))
    for path in sorted(head):
        if path not in base:
            continue
        dropped = (base[path] & unchanged) - head[path]
        extra = settings(head[path] - base[path]) - (sources - retired)
        if dropped:
            found.append("%s: drops %s, which the sources still declare" % (path, ", ".join(sorted(dropped))))
        if extra:
            found.append("%s: adds %s, which no source declares" % (path, ", ".join(sorted(extra))))
    return found


def git_show(repo: str, rev: str, path: str) -> bytes | None:
    return git_show_many(repo, rev, [path])[path]


def git_show_many(repo: str, rev: str, paths: list[str]) -> dict[str, bytes | None]:
    """{path: its blob at REV, or None} in one `cat-file --batch`: a `git show` a file cost about 0.5 s on big-red's
    cmux mirror (2026-11-21: this check's 120 of them took 106 s of a merge push's pre-push gate). The request goes
    through a file, never a pipe (git_batch.py: a big piped stdin can hang)."""
    if not paths:
        return {}
    with tempfile.TemporaryFile() as stdin:
        stdin.write("".join("%s:%s\n" % (rev, path) for path in paths).encode("utf-8", "surrogateescape"))
        stdin.seek(0)
        out = subprocess.run(["git", "-C", repo, "cat-file", "--batch"], stdin=stdin, capture_output=True,
                             check=True).stdout
    found, pos = {}, 0
    for path in paths:
        end = out.index(b"\n", pos)
        header = out[pos:end].split()
        pos = end + 1
        if len(header) != 3 or header[1] not in (b"blob", b"tree", b"commit", b"tag"):
            found[path] = None  # "<rev>:<path> missing", or an answer this parser does not know
            continue
        size = int(header[2])
        found[path] = out[pos:pos + size] if header[1] == b"blob" else None
        pos += size + 1
    return found


def exports_at(repo: str, rev: str) -> dict[str, set[str]]:
    texts = git_show_many(repo, rev, list(EXPORTS))
    return {path: read(texts[path]) for path, read in EXPORTS.items() if texts[path] is not None}


def sources_at(repo: str, rev: str) -> dict[str, bytes]:
    names = subprocess.run(["git", "-C", repo, "ls-tree", "--name-only", "-z", rev, SOURCE_DIR + "/"],
                           capture_output=True, check=True).stdout.decode("utf-8").split("\0")
    names = [name for name in names if name.endswith(".json")]
    return {name: text or b"{}" for name, text in git_show_many(repo, rev, names).items()}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", default=".")
    parser.add_argument("--base", required=True)
    parser.add_argument("--head", required=True)
    args = parser.parse_args(argv)
    try:
        found = drift(exports_at(args.repo, args.base), exports_at(args.repo, args.head),
                      source_rows(sources_at(args.repo, args.base)), source_rows(sources_at(args.repo, args.head)),
                      retired_keys(git_show(args.repo, args.head, RETIRED)))
    except (subprocess.CalledProcessError, ValueError, KeyError, TypeError, AttributeError,
            plistlib.InvalidFileException) as error:
        print("settings-export-key-drift: cannot read the exports or sources: %r" % (error,), file=sys.stderr)
        return 2
    for line in found:
        print("drift: " + line)
    if found:
        print("regenerate the exports at this head: scripts/cmux-next/regenerate-settings-exports.sh (its header has "
              "the fleet command); never hand-edit them", file=sys.stderr)
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
