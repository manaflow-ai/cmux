#!/usr/bin/env python3
"""Refuse `cargo ... -p CRATE` run from a Cargo workspace that does not have CRATE as a member.

2026-11-16, run 43881963559: `cargo test -p cmux-rd-host` in directory cmux-tui. cmux-tui/Cargo.toml lists
crates/cmux-rd-host under [workspace] exclude (the crate is its own workspace, with its own Cargo.lock), and the only
edge to it is a cfg(target_os = "macos") dependency. On Linux cargo 1.95 does not say "package not found": it panics
(exit 101) in cargo/core/resolver/features.rs with "did not find features for (PackageId { name: \"cmux-rd-host\" ...
}, NormalOrDev) within activated_features", which reads like a cargo bug and cost a lane an hour.

    cargo_package_workspace_check.py --command CMD [--directory DIR] [--root ROOT]

CMD is the shell command fast checks runs, DIR its directory relative to ROOT (the checkout, default the current
directory). Each simple command of CMD (split on && || ; | and newlines; `cd DIR` moves it; `bash -c '...'` is read
inside) that runs cargo with -p/--package NAME is checked against the workspace cargo would pick: the nearest
Cargo.toml with a [workspace] table at or above its directory, inside ROOT. When NAME's crate (a Cargo.toml with
package.name NAME under that root) sits under a [workspace] exclude path, or has its own [workspace] table, the
request is refused with exit 2 and the directory and command to run instead. Anything this cannot read (a package
not found, no workspace, an unreadable manifest or command) is left to cargo: exit 0. It reads only manifests
(tomllib); `cargo metadata` would hit the same panic.
"""

from __future__ import annotations

import argparse
import os
import shlex
import sys
import tomllib
from pathlib import Path

COMMAND_PREFIXES = ("env", "exec", "time", "command", "nice")
OPERATORS = ("&&", "||", ";", "|", "&", ";;")
SKIP_DIRS = ("target", "node_modules", ".git")
PANIC = ("did not find features for (PackageId { name: ... }, NormalOrDev) within activated_features "
         "(cargo/core/resolver/features.rs, exit 101)")


def segments(command: str) -> list[list[str]]:
    """The simple commands of COMMAND as word lists, in order; [] when shlex cannot read it."""
    lexer = shlex.shlex(command.replace("\n", " ; "), posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    lexer.commenters = "#"
    out: list[list[str]] = [[]]
    try:
        for word in lexer:
            if word in OPERATORS or set(word) <= set("&|;"):
                out.append([])
            else:
                out[-1].append(word)
    except ValueError:
        return []
    return [words for words in out if words]


def strip_prefixes(words: list[str]) -> list[str]:
    i = 0
    while i < len(words) and (words[i] in COMMAND_PREFIXES or ("=" in words[i] and not words[i].startswith("-")
                                                             and words[i].split("=", 1)[0].isidentifier())):
        i += 1
    return words[i:]


def cargo_requests(command: str, directory: str) -> list[tuple[str, list[str], list[str]]]:
    """(directory, cargo words, package names) for each cargo run in COMMAND that names packages."""
    found: list[tuple[str, list[str], list[str]]] = []
    for words in segments(command):
        words = strip_prefixes(words)
        if not words:
            continue
        name = os.path.basename(words[0])
        if name == "cd" and len(words) == 2:
            directory = os.path.normpath(os.path.join(directory, words[1]))
        elif name in ("bash", "sh") and len(words) >= 3 and words[1] == "-c":
            found += cargo_requests(words[2], directory)
        elif name == "cargo":
            packages = package_names(words[1:])
            if packages:
                found.append((directory, words, packages))
    return found


def package_names(args: list[str]) -> list[str]:
    names = []
    for i, word in enumerate(args):
        if word == "--":
            break
        value = None
        if word in ("-p", "--package"):
            value = args[i + 1] if i + 1 < len(args) else None
        elif word.startswith("--package="):
            value = word.split("=", 1)[1]
        elif word.startswith("-p") and not word.startswith("--") and len(word) > 2:
            value = word[2:]
        if value and not any(c in value for c in "*?["):
            names.append(value.split("@", 1)[0])
    return names


def without_package(words: list[str], name: str) -> list[str]:
    """WORDS (a cargo command) with every -p/--package flag naming NAME removed."""
    out, i = [], 0
    while i < len(words):
        word = words[i]
        if word == "--":
            out += words[i:]
            break
        if word in ("-p", "--package") and i + 1 < len(words) and words[i + 1].split("@", 1)[0] == name:
            i += 2
            continue
        if (word.startswith("--package=") and word.split("=", 1)[1].split("@", 1)[0] == name) or \
                (word.startswith("-p") and not word.startswith("--") and word[2:].split("@", 1)[0] == name):
            i += 1
            continue
        out.append(word)
        i += 1
    return out


def manifest(path: Path) -> dict | None:
    try:
        return tomllib.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def workspace_root(directory: Path, root: Path) -> tuple[Path, dict] | None:
    """The nearest directory at or above DIRECTORY, inside ROOT, whose Cargo.toml has a [workspace] table."""
    here = directory
    while True:
        data = manifest(here / "Cargo.toml")
        if data is not None and isinstance(data.get("workspace"), dict):
            return here, data
        if here == root or root not in here.parents:
            return None
        here = here.parent


def crate_dirs(workspace: Path, name: str) -> list[tuple[Path, dict]]:
    found = []
    for top, dirs, files in os.walk(workspace):
        dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS and not d.startswith("."))
        if "Cargo.toml" in files:
            data = manifest(Path(top) / "Cargo.toml")
            package = (data or {}).get("package")
            if isinstance(package, dict) and package.get("name") == name:
                found.append((Path(top), data))
    return found


def outside_reason(workspace: Path, config: dict, crate: Path, data: dict) -> str | None:
    """Why CRATE is not a member of WORKSPACE (CONFIG its [workspace] table), or None when it may be one."""
    if crate == workspace:
        return None
    rel = crate.relative_to(workspace)
    for entry in config.get("exclude") or []:
        parts = Path(os.path.normpath(str(entry))).parts
        if rel.parts[:len(parts)] == parts:
            return f"{workspace.name}/Cargo.toml lists {entry} under [workspace] exclude"
    if isinstance(data.get("workspace"), dict):
        return f"{rel}/Cargo.toml has its own [workspace]"
    return None


def check(command: str, directory: str, root: Path) -> list[str]:
    """One refusal message per cargo -p request in COMMAND whose package is outside its workspace."""
    root = root.resolve()
    refusals = []
    for where, words, packages in cargo_requests(command, os.path.normpath(directory or ".")):
        start = (root / where).resolve()
        if start != root and root not in start.parents:
            continue
        found = workspace_root(start, root)
        if found is None:
            continue
        workspace, data = found
        config = data["workspace"]
        for name in packages:
            crates = crate_dirs(workspace, name)
            reasons = [(crate, outside_reason(workspace, config, crate, manifest_data)) for crate, manifest_data in crates]
            if not reasons or any(reason is None for _, reason in reasons):
                continue
            crate, reason = reasons[0]
            rest = without_package(words, name)
            refusals.append(
                f"{name} is not a member of the workspace at {workspace.relative_to(root)} ({reason}), and "
                f"`cargo -p {name}` from there does not say so on Linux: cargo panics with \"{PANIC}\". "
                f"Nothing was run. Next step: run it in the crate's own workspace: "
                f"directory={crate.relative_to(root)}, command: {shlex.join(rest)} "
                f"(cmux-ci test: cd {crate.relative_to(root)} && cmux-ci test -- {shlex.join(rest)})")
    return refusals


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--command", required=True)
    parser.add_argument("--directory", default=".")
    parser.add_argument("--root", default=".")
    args = parser.parse_args(argv)
    refusals = check(args.command, args.directory, Path(args.root))
    for message in refusals:
        print(f"::error title=cargo -p outside its workspace::{message}", file=sys.stderr, flush=True)
    return 2 if refusals else 0


if __name__ == "__main__":
    raise SystemExit(main())
