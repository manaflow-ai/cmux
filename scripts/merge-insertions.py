#!/usr/bin/env python3
"""Git merge driver for files that branches grow by inserting lines at the same place.

Two branches that each add a different entry where a list, a log or a module ends
both insert lines between the same two base lines. A line merge cannot order the
two insertions, so it stops with a conflict even though nothing was changed by both
sides: a 7-day replay of every base merge on cmux pull requests (2026-10-31 to
2026-11-07) found 799 of about 3,000 conflicted file merges were only that
(owner logs, `pub mod` lists, Cargo members, appended tests, registries).

This runs git's own three-way merge (`git merge-file --diff3`) and then settles
each conflict whose base side is empty, an insertion on both sides, by keeping
all of ours and then all of theirs. Every other conflict (a line both sides changed, a delete
against a change) stays an ordinary conflict for the author. A .json or .toml
result, settled or clean, that no longer parses or names a key twice is written
back as the plain line merge and left conflicted, so a missing comma or a
doubled key never merges silently.

Usage (git): merge-insertions.py %O %A %B %P %L; writes the result to %A and
exits 1 when a conflict remains.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys


def plain_merge(ours: str, base: str, theirs: str, size: int) -> tuple[bytes, int]:
    result = subprocess.run(
        ["git", "merge-file", "-p", f"--marker-size={size}",
         "-L", "ours", "-L", "base", "-L", "theirs", ours, base, theirs],
        capture_output=True,
    )
    return result.stdout, result.returncode


def merge_file(ours: str, base: str, theirs: str, path: str, size: int) -> tuple[bytes, int]:
    result = subprocess.run(
        ["git", "merge-file", "-p", "--diff3", f"--marker-size={size}",
         "-L", "ours", "-L", "base", "-L", "theirs", ours, base, theirs],
        capture_output=True,
    )
    if result.returncode < 0 or result.returncode > 127:
        raise SystemExit(f"merge-insertions: git merge-file failed on {path}: {result.stderr.decode(errors='replace')}")
    return result.stdout, result.returncode


# git writes its markers for the parse longer than any run of marker characters that
# starts a line in the three inputs, so a line of the file that looks like a marker
# (a Markdown `=======` underline) is never read as one.
MIN_PARSE_MARKER = 51
MARKER_RUN = re.compile(rb"^([<|=>])\1*", re.MULTILINE)


def parse_marker_size(*paths: str) -> int:
    longest = 0
    for path in paths:
        with open(path, "rb") as handle:
            for match in MARKER_RUN.finditer(handle.read()):
                longest = max(longest, len(match.group(0)))
    return max(MIN_PARSE_MARKER, longest + 1)


def is_toml_header(line: bytes) -> bool:
    return line.lstrip().startswith(b"[") and not line.lstrip().startswith(b"[]")


def toml_union(ours: list[bytes], theirs: list[bytes]) -> list[bytes] | None:
    """Both insertions in TOML: key lines before a side's first table header belong to the
    table above the hunk, so they go first; tables follow. None when both sides insert such
    keys and a table, where no order keeps every key in its own table."""
    def split(block):
        for index, line in enumerate(block):
            if is_toml_header(line):
                return block[:index], block[index:]
        return block, []

    def has_keys(lines):
        return any(line.strip() and not line.lstrip().startswith(b"#") for line in lines)

    (our_lead, our_tables), (their_lead, their_tables) = split(ours), split(theirs)
    if has_keys(our_lead) and has_keys(their_lead) and (our_tables or their_tables):
        return None
    if not our_tables and not their_tables:
        return ours + theirs
    return our_lead + their_lead + our_tables + their_tables


# Two insertions that share this much of their substantive lines are one change made twice
# (a file or function both branches got from one commit, then edited): kept both, the file
# would hold it twice, so that stays a conflict.
SAME_CHANGE_SHARE = 0.3


def same_change(ours: list[bytes], theirs: list[bytes]) -> bool:
    def substantive(block):
        return {line.strip() for line in block if len(line.strip()) > 3}
    a, b = substantive(ours), substantive(theirs)
    return bool(a and b) and len(a & b) >= SAME_CHANGE_SHARE * min(len(a), len(b))


def settle(text: bytes, size: int, marker: int, toml: bool = False) -> tuple[bytes, int, int]:
    """Resolve both-sides-inserted hunks in merge-file output written with `marker`-long
    markers; return the text (remaining conflicts rewritten with `size` markers), how many
    conflicts remain, and how many hunks were read."""
    start, mid_base, mid, end = (c * marker for c in (b"<", b"|", b"=", b">"))
    out_start, out_mid, out_end = (c * size for c in (b"<", b"=", b">"))
    out: list[bytes] = []
    remaining = hunks = 0
    lines = text.splitlines(keepends=True)
    i = 0
    while i < len(lines):
        line = lines[i]
        if not line.startswith(start + b" "):
            out.append(line)
            i += 1
            continue
        # One diff3 hunk: <<< ours ||| base === theirs >>>.
        sections: dict[str, list[bytes]] = {"ours": [], "base": [], "theirs": []}
        part, j, closed = "ours", i + 1, False
        while j < len(lines):
            current = lines[j]
            if part == "ours" and current.startswith(mid_base + b" "):
                part = "base"
            elif part == "base" and current.rstrip(b"\r\n") == mid:
                part = "theirs"
            elif part == "theirs" and current.startswith(end + b" "):
                closed = True
                break
            else:
                sections[part].append(current)
            j += 1
        if not closed:  # not a hunk git wrote; the caller falls back to the plain merge
            out.extend(lines[i:])
            remaining += 1
            break
        hunks += 1
        if sections["base"]:
            # Something both sides changed: keep git's conflict, without the base section.
            out.append(out_start + b" ours\n")
            out.extend(sections["ours"])
            out.append(out_mid + b"\n")
            out.extend(sections["theirs"])
            out.append(out_end + b" theirs\n")
            remaining += 1
        else:
            # Every line of both insertions, ours first. Lines both sides inserted
            # alike are not merged into one: two appended functions both end in `}`,
            # and each needs its own.
            for block in (sections["ours"], sections["theirs"]):
                if block and not block[-1].endswith(b"\n"):
                    block[-1] += b"\n"
            if same_change(sections["ours"], sections["theirs"]):
                joined = None
            else:
                joined = (toml_union(sections["ours"], sections["theirs"]) if toml
                          else sections["ours"] + sections["theirs"])
            if joined is None:
                out.append(out_start + b" ours\n")
                out.extend(sections["ours"])
                out.append(out_mid + b"\n")
                out.extend(sections["theirs"])
                out.append(out_end + b" theirs\n")
                remaining += 1
            else:
                out.extend(joined)
        i = j + 1
    return b"".join(out), remaining, hunks


def unique_keys(pairs):
    keys = [key for key, _ in pairs]
    if len(keys) != len(set(keys)):
        raise ValueError("duplicate key")
    return dict(pairs)


def parses(path: str, text: bytes) -> bool:
    """A .json result must parse with no key twice in one object (both sides added the same
    key); .toml rejects a repeated key itself."""
    try:
        if path.endswith(".json"):
            json.loads(text, object_pairs_hook=unique_keys)
        elif path.endswith(".toml"):
            import tomllib  # Python 3.11+; an older python3 cannot check, so the merge stays a conflict
            tomllib.loads(text.decode("utf-8"))
    except (ValueError, UnicodeDecodeError, ImportError):
        return False
    return True


# TypeScript: two branches that each import a new name from one module both change that
# module's one import line, a changed-line conflict no union settles. A 7-day replay of the
# agent pane's App.tsx (2026-11-01 to 2026-11-11) found a quarter of its conflicted merges
# were only that. So a .ts or .tsx file's leading imports merge per statement and per name:
# a name either side added is kept, one either side removed is dropped, and the rest of the
# file is the ordinary merge below. Anything the reader does not know (a comment inside a
# statement, a default import both sides changed, CRLF, a line among the imports that is not
# one) leaves the whole file to that merge, so it is never worse than the line merge.
IMPORT_FILE = re.compile(r"\.(ts|tsx|mts|cts)$")
IMPORT_STATEMENT = re.compile(
    r"import\s+(type\s+)?(?:([A-Za-z_$][\w$]*)\s*,?\s*)?(?:\*\s+as\s+([A-Za-z_$][\w$]*)|\{([^{}]*)\})?\s*"
    r"from\s*([\"'])([^\"']+)\5;?", re.S)
SIDE_EFFECT_IMPORT = re.compile(r"import\s*([\"'])([^\"']+)\1;?")
# `import type from "t"` is a default import named `type`, which the pattern would read as
# the type-only keyword with nothing imported.
DEFAULT_NAMED_TYPE = re.compile(r"import\s+type\s*(,|from\b)")
PRINT_WIDTH = 120  # config/vite-plus/check.ts


class Import:
    def __init__(self, lead: str, text: str):
        self.lead, self.text = lead, text
        side = SIDE_EFFECT_IMPORT.fullmatch(text.strip())
        if side:
            self.type_only, self.default, self.namespace, self.quote, self.module = "", None, None, side.group(1), side.group(2)
            self.names: list[str] = []
            self.kind = "side"
            return
        match = IMPORT_STATEMENT.fullmatch(text.strip())
        if not match or "//" in text or "/*" in text or DEFAULT_NAMED_TYPE.match(text.strip()):
            raise ValueError(text)
        self.type_only = match.group(1) or ""
        self.default, self.namespace, self.quote, self.module = match.group(2), match.group(3), match.group(5), match.group(6)
        self.names = [" ".join(name.split()) for name in (match.group(4) or "").split(",") if name.strip()]
        self.kind = "type" if self.type_only else "namespace" if self.namespace else "value"

    def binds(self) -> list[str]:
        """The local names the statement declares."""
        names = [name.split()[-1] for name in self.names]
        return names + [name for name in (self.default, self.namespace) if name]

    def render(self, default, namespace, names) -> str:
        head = "import " + self.type_only + (default or "")
        tail = f' from {self.quote}{self.module}{self.quote};'
        if namespace:
            return head + ("" if not default else ", ") + "* as " + namespace + tail + "\n"
        if not names:
            return head + tail + "\n"
        joiner = ", " if default else ""
        line = head + joiner + "{ " + ", ".join(names) + " }" + tail
        if len(line) <= PRINT_WIDTH:
            return line + "\n"
        return head + joiner + "{\n" + "".join(f"  {name},\n" for name in names) + "}" + tail + "\n"


def split_imports(text: str) -> tuple[list[Import], str] | None:
    """The leading import statements (each with the comments and blank lines above it) and the
    rest of the file, or None when a statement there is not one the merge reads, or when an
    import follows the first other line: a side that put a line (a directive, a block comment,
    an export) among the imports would move the ones below it into its body, where the per-name
    merge cannot see them."""
    lines = text.splitlines(keepends=True)
    imports: list[Import] = []
    lead: list[str] = []
    i = 0
    while i < len(lines):
        line = lines[i]
        if not line.strip() or line.lstrip().startswith("//"):
            lead.append(line)
            i += 1
            continue
        if not line.startswith("import ") or line.startswith("import ("):
            break
        j = i
        while not re.search(r"[\"'];?\s*$", lines[j]) or not re.search(r"(from\s*|^import\s*)[\"'][^\"']+[\"'];?\s*$", lines[j]):
            j += 1
            if j == len(lines) or j - i > 400:
                return None
        try:
            imports.append(Import("".join(lead), "".join(lines[i:j + 1])))
        except ValueError:
            return None
        lead, i = [], j + 1
    if any(re.match(r"import[\s{*\"']", line) for line in lines[i:]):
        return None
    return imports, "".join(lead) + "".join(lines[i:])


def keyed(imports: list[Import]) -> dict[tuple, Import]:
    seen: dict[tuple, int] = {}
    out = {}
    for statement in imports:
        ordinal = seen.get((statement.module, statement.kind), 0)
        seen[(statement.module, statement.kind)] = ordinal + 1
        out[(statement.module, statement.kind, ordinal)] = statement
    return out


def three_way(base, ours, theirs):
    if ours == theirs or theirs == base:
        return ours
    if ours == base:
        return theirs
    raise ValueError("both changed")


def merge_imports(base: list[Import], ours: list[Import], theirs: list[Import]) -> str | None:
    """One import header from three, or None when the three cannot be settled per name."""
    def whole(imports):
        return "".join(statement.lead + statement.text for statement in imports)
    b, o, t = (keyed(side) for side in (base, ours, theirs))
    # A module imported by more than one statement is matched by its place among them; a
    # side that adds or drops one of them would shift that, so the file takes the line merge.
    for key in set(b) | set(o) | set(t):
        module, kind, _ = key
        counts = {sum(1 for k in side if k[:2] == (module, kind)) for side in (b, o, t)}
        if len(counts) > 1 and max(counts) > 1:
            return None
    # The statements' order is a three-way merge too (side-effect imports run in it): the side
    # that moved statements sets it, and both moving them is a conflict.
    shared = [k for k in b if k in o and k in t]
    sequence = {name: [k for k in side if k in shared] for name, side in (("b", b), ("o", o), ("t", t))}
    if sequence["o"] == sequence["b"]:
        first, second = t, o
    elif sequence["t"] in (sequence["b"], sequence["o"]):
        first, second = o, t
    else:
        return None
    order = list(first)
    for index, key in enumerate(second):
        if key in first:
            continue
        before = [k for k in list(second)[:index] if k in order]
        order.insert(order.index(before[-1]) + 1 if before else 0, key)
    # A statement each side added under the same comment or blank line would carry it twice.
    added_leads = [any(k not in b and side[k].lead for k in side) for side in (o, t)]
    if all(added_leads):
        return None
    out = []
    binds: list[str] = []
    try:
        for key in order:
            sides = [side.get(key) for side in (b, o, t)]
            if sides[0] and (not sides[1] or not sides[2]):
                kept_side = sides[1] or sides[2]
                if kept_side is None or (kept_side.lead + kept_side.text == sides[0].lead + sides[0].text):
                    continue  # removed by one side (or both), left as it was by the other
                raise ValueError("removed by one side, changed by the other")
            names = [set(s.names) if s else set() for s in sides]
            dropped = (names[0] - names[1]) | (names[0] - names[2])
            kept = [n for n in (sides[1].names if sides[1] else []) + (sides[2].names if sides[2] else []) if n not in dropped]
            kept = list(dict.fromkeys(kept))
            default = three_way(*(s.default if s else None for s in sides))
            namespace = three_way(*(s.namespace if s else None for s in sides))
            lead = three_way(*(s.lead if s else None for s in sides)) or ""
            shape = next(s for s in (sides[1], sides[2]) if s)
            if not kept and not default and not namespace and shape.kind != "side":
                continue
            for side in (sides[1], sides[2]):
                if side and side.names == kept and side.default == default and side.namespace == namespace:
                    statement = side.text
                    break
            else:
                statement = shape.render(default, namespace, kept)
            out.append(lead + statement)
            binds += Import(lead, statement).binds()
    except ValueError:
        return None
    # Both sides importing one name (`B` and `type B`, or from two modules) declares it twice.
    if len(binds) != len(set(binds)):
        return None
    merged = "".join(out)
    # Read back what was written: a header the reader cannot parse again is no result.
    again = split_imports(merged)
    if again is None or whole(again[0]) != merged:
        return None
    return merged


def merge_typescript(base: str, ours: str, theirs: str, path: str, size: int) -> tuple[bytes, int] | None:
    """The import header merged per name and the body by the insertions merge, or None for
    the whole-file merge."""
    texts = []
    for name in (base, ours, theirs):
        with open(name, "rb") as handle:
            raw = handle.read()
        # The header is rebuilt with LF endings, so a CRLF file keeps the line merge.
        if b"\r" in raw or raw.startswith(b"\xef\xbb\xbf"):
            return None
        try:
            texts.append(raw.decode("utf-8"))
        except UnicodeDecodeError:
            return None
    parts = [split_imports(text) for text in texts]
    if any(part is None for part in parts):
        return None
    header = merge_imports(*(part[0] for part in parts))
    if header is None:
        return None
    import tempfile
    with tempfile.TemporaryDirectory(prefix="cmux-merge-imports-") as scratch:
        bodies = []
        for label, part in zip(("base", "ours", "theirs"), parts):
            body = os.path.join(scratch, label)
            with open(body, "wb") as handle:
                handle.write(part[1].encode("utf-8"))
            bodies.append(body)
        result, remaining = merge_lines(bodies[1], bodies[0], bodies[2], path, size)
    return header.encode("utf-8") + result, remaining


def merge_lines(ours: str, base: str, theirs: str, path: str, size: int) -> tuple[bytes, int]:
    marker = parse_marker_size(base, ours, theirs)
    merged, status = merge_file(ours, base, theirs, path, marker)
    if status == 0:
        return merged, 0
    result, remaining, hunks = settle(merged, size, marker, toml=path.endswith(".toml"))
    # git's exit status is its conflict count: a parse that read a different number
    # of hunks keeps git's own conflict instead.
    if hunks != status:
        return plain_merge(ours, base, theirs, size)[0], 1
    return result, remaining


def main(argv: list[str]) -> int:
    if len(argv) not in (5, 6):
        print("usage: merge-insertions.py %O %A %B %P [%L]", file=sys.stderr)
        return 2
    base, ours, theirs, path = argv[1:5]
    size = int(argv[5]) if len(argv) == 6 else 7
    if os.path.getsize(base) == 0:
        # Both branches created the file: two versions of it are not two insertions.
        result, status = plain_merge(ours, base, theirs, size)
        remaining = 1 if status else 0
    else:
        typescript = merge_typescript(base, ours, theirs, path, size) if IMPORT_FILE.search(path) else None
        result, remaining = typescript or merge_lines(ours, base, theirs, path, size)
    # A .json or .toml result, settled or merged clean (both sides adding one key in
    # different places), must parse with no key twice, and a python3 with no tomllib
    # cannot say it does. Otherwise it is git's plain merge, marked conflicted for the
    # author, even when a side was already malformed.
    if remaining == 0 and not parses(path, result):
        result, remaining = plain_merge(ours, base, theirs, size)[0], 1
    with open(ours, "wb") as handle:
        handle.write(result)
    return 1 if remaining else 0

if __name__ == "__main__":
    sys.exit(main(sys.argv))
