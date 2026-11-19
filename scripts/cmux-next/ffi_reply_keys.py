#!/usr/bin/env python3
"""A Swift reply type may not require a key the pinned Rust FFI never writes.

The app links the Rust FFI from the release app-ffi-pin.json pins, not from the tree it is built with. A Swift reply
type that makes a key required (a stored property that is not Optional) decodes nothing when the pinned library never
writes that key: `try? JSONDecoder().decode` answers nil and the caller falls back without a word. cmux#46136 made the
sidebar planner reply require `selection_spared` in the PR that taught Rust to write it, and until a re-pin carried
it every sidebar customization setting did nothing on feat-cmux-next (cmux#47028 decodes it optionally).

Git objects only, no build. Each Swift reply type passed as `X.call("op", ..., as: T.self)` in a Sources file that
BASE..HEAD changes gives its required JSON keys (and those of the types it holds, when that file declares them; a
type with its own `init(from:)` decides for itself). A key no Rust file under cmux-tui/crates names at HEAD's pinned
FFI source commit cannot be in the pinned library's replies. A camelCase key also counts as named under its
snake_case form (serde rename_all, or a decoder converting from snake case). A key Rust names elsewhere may still be
missing from that reply: this catches the new-key case, which is the one a change to both Rust and Swift makes.

    python3 scripts/cmux-next/ffi_reply_keys.py --repo DIR --base BASE --head HEAD

Prints `skew: <file>: ...` for each key HEAD requires and BASE did not already require-and-lack, exit 1 when there
is one. `note: ...` and exit 0 when it cannot judge (no pin, the pinned commit not in this clone, a grep past its
bound): the pinned commit is a feat-cmux-next ancestor, so a normal clone has it.
"""
from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

SOURCES = "Packages/macOS/CmuxNext/Sources/"
PIN_FILE = "Packages/macOS/CmuxNext/app-ffi-pin.json"
RUST = "cmux-tui/crates"
GREP_SECONDS = 90

CALL = re.compile(r'\.\w+\(\s*"([a-z][a-z0-9_]*)"[^;\n]*?\bas:\s*([A-Z]\w*(?:\.[A-Z]\w*)*)\.self')
STRUCT = re.compile(r"\bstruct\s+([A-Z]\w*)\s*(?:<[^>{]*>)?\s*:\s*([^{]*)\{")
PROPERTY = re.compile(r"^\s*(?:(?:public|private|fileprivate|internal|package|nonisolated)\s+)*(var|let)\s+(\w+)\s*:"
                      r"\s*([^={]+?)\s*(=.*)?$")
OWN_DECODER = re.compile(r"\binit\s*\(\s*from\s+\w+\s*:\s*(?:any\s+)?Decoder\b")


def body(text: str, open_index: int) -> str:
    """The text between the brace at open_index and its match."""
    depth = 0
    for index in range(open_index, len(text)):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return text[open_index + 1:index]
    return text[open_index + 1:]


def top_level_lines(block: str) -> list[str]:
    """The lines of block at its own brace depth (nested types' and functions' bodies left out)."""
    lines, depth = [], 0
    for line in block.splitlines():
        if depth == 0:
            lines.append(line)
        depth += line.count("{") - line.count("}")
    return lines


def structs(text: str) -> dict[str, str]:
    """Each Decodable struct in text: name -> its body (the first declaration of a name wins)."""
    found: dict[str, str] = {}
    for match in STRUCT.finditer(text):
        if re.search(r"\b(Decodable|Codable)\b", match[2]):
            found.setdefault(match[1], body(text, match.end() - 1))
    return found


def coding_keys(block: str) -> dict[str, str] | None:
    """A CodingKeys enum's case -> JSON key, or None without one."""
    keys = re.search(r"\benum\s+CodingKeys\b[^{]*\{", block)
    if not keys:
        return None
    coding = {}
    for line in body(block, keys.end() - 1).splitlines():
        case = re.match(r"^\s*case\s+(.+)$", line.split("//")[0])
        for item in case[1].split(",") if case else ():
            label, _, raw = item.partition("=")
            coding[label.strip()] = raw.strip().strip('"') or label.strip()
    return coding


def required_keys(name: str, types: dict[str, str], seen: set[str]) -> list[tuple[str, str]]:
    """(type, JSON key) for each key the synthesized decoder of NAME requires, this file's nested types included."""
    if name in seen or name not in types:
        return []
    seen.add(name)
    block = types[name]
    if OWN_DECODER.search(block):
        return []
    coding = coding_keys(block)
    out = []
    for line in top_level_lines(block):
        code = line.split("//")[0].rstrip()
        prop = PROPERTY.match(code)
        if not prop or re.match(r"^\s*(?:static|class|@)", code) or code.rstrip().endswith("{"):
            continue  # not a stored property
        kind, label, declared, default = prop.groups()
        if (kind == "let" and default) or (coding is not None and label not in coding):
            continue  # never decoded
        declared = declared.strip()
        if not (declared.endswith("?") or declared.startswith("Optional<")):
            out.append((name, coding[label] if coding else label))
        for inner in re.findall(r"[A-Z]\w*", declared):
            out.extend(required_keys(inner, types, seen))
    return out


def file_keys(text: str) -> set[tuple[str, str, str]]:
    """(op, type, key) for every key a Rust FFI reply decoded in this Swift file must carry."""
    types = structs(text)
    return {(op, owner, key) for op, type_name in CALL.findall(text)
            for owner, key in required_keys(type_name.split(".")[-1], types, set())}


def snake(key: str) -> str:
    return re.sub(r"(?<=[a-z0-9])([A-Z])", r"_\1", key).lower()


class Unjudged(Exception):
    pass


def git(repo: str, *args: str) -> str:
    result = subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True)
    if result.returncode:
        raise Unjudged(f"git {' '.join(args[:2])}: {result.stderr.strip()[:200]}")
    return result.stdout


def show(repo: str, rev: str, path: str) -> str | None:
    result = subprocess.run(["git", "-C", repo, "show", f"{rev}:{path}"], capture_output=True, text=True)
    return result.stdout if result.returncode == 0 else None


def rust_names(repo: str, sha: str, keys: set[str]) -> set[str]:
    """Which of KEYS (or their snake_case forms) some Rust file under cmux-tui/crates names at SHA."""
    wanted = sorted({form for key in keys for form in (key, snake(key))})
    patterns = [arg for form in wanted for arg in ("-e", form)]
    try:
        result = subprocess.run(["git", "-C", repo, "grep", "-h", "-o", "-w", "-F", *patterns, sha, "--",
                                 f"{RUST}/*.rs"], capture_output=True, text=True, timeout=GREP_SECONDS)
    except subprocess.TimeoutExpired:
        raise Unjudged(f"reading the pinned Rust took over {GREP_SECONDS} s (a blob-less clone fetches each file)")
    if result.returncode not in (0, 1):
        raise Unjudged(f"git grep at {sha[:12]}: {result.stderr.strip()[:200]}")
    return {line.rsplit(":", 1)[-1] for line in result.stdout.split()} & set(wanted)


def findings(repo: str, base: str, head: str) -> list[str]:
    changed = [p for p in git(repo, "diff", "--name-only", "--no-renames", base, head, "--", SOURCES).split()
               if p.endswith(".swift")]
    at = {}
    for rev in (base, head):
        at[rev] = {(path, *use) for path in changed for use in file_keys(show(repo, rev, path) or "")}
    fresh = at[head] - at[base]
    if not fresh:
        return []
    pin = show(repo, head, PIN_FILE) or ""
    found = re.search(r"cmux-app-ffi-([0-9a-f]{40})/", pin)
    if not found:
        raise Unjudged(f"no pinned source sha in {PIN_FILE} at {head[:12]}")
    sha = found[1]
    if subprocess.run(["git", "-C", repo, "cat-file", "-e", f"{sha}^{{commit}}"], capture_output=True).returncode:
        raise Unjudged(f"the pinned FFI source commit {sha[:12]} is not in this clone")
    named = rust_names(repo, sha, {key for *_, key in fresh})
    return [f"{path}: {owner} requires `{key}` in the Rust `{op}` reply, but no Rust file under {RUST} names it at "
            f"the pinned FFI source {sha[:12]}, so every reply from the pinned library fails to decode. Decode it "
            "optionally (an Optional, or decodeIfPresent with a default) until a re-pin carries it, or land the "
            "Rust first and this Swift after the re-pin."
            for path, op, owner, key in sorted(fresh) if key not in named and snake(key) not in named]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", default=str(Path(__file__).resolve().parents[2]))
    parser.add_argument("--base", required=True)
    parser.add_argument("--head", default="HEAD")
    args = parser.parse_args()
    try:
        found = findings(args.repo, args.base, args.head)
    except Unjudged as why:
        print(f"note: ffi reply keys not judged: {why}")
        return 0
    for line in found:
        print(f"skew: {line}")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
