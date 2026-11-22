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
# The cargo commands whose -p/--package picks workspace members to build or run (`cargo update -p` or `cargo tree -p`
# may name any package in the lockfile, an excluded path dependency included, and are left alone).
SELECTING = {"build", "b", "check", "c", "test", "t", "bench", "run", "r", "clippy", "doc", "d", "rustc", "rustdoc",
             "fix", "nextest", "llvm-cov", "miri"}
SKIP_DIRS = ("target", "node_modules", ".git")
PANIC = ("did not find features for (PackageId { name: ... }, NormalOrDev) within activated_features "
         "(cargo/core/resolver/features.rs, exit 101)")


def segments(command: str) -> list[list[str]]:
    """The simple commands of COMMAND as word lists, in order; [] when shlex cannot read it."""
    # A newline ends a comment and a command: keep it (the comment needs it) and add a separator after it.
    lexer = shlex.shlex(command.replace("\n", "\n;\n"), posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    lexer.commenters = "#"
    out: list[list[str]] = [[]]
    try:
        for word in lexer:
            if word in OPERATORS or set(word) <= set("&|;"):
                out.append([])
            elif set(word) <= set("()"):
                # Each subshell paren is its own segment, so a `cd` inside one is scoped to it.
                out += [[ch] for ch in word]
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
    stack: list[str] = []
    for words in segments(command):
        if words == ["("]:
            stack.append(directory)
            continue
        if words == [")"]:
            directory = stack.pop() if stack else directory
            continue
        while words and words[0] in ("{", "}"):  # a brace group does not scope `cd`
            words = words[1:]
        words = strip_prefixes(words)
        if not words:
            continue
        name = os.path.basename(words[0])
        if name == "cd" and len(words) == 2:
            directory = os.path.normpath(os.path.join(directory, words[1]))
        elif name in ("bash", "sh") and len(words) >= 3 and words[1] == "-c":
            found += cargo_requests(words[2], directory)
        elif name == "cargo" and selects_members(words[1:]):
            packages = package_names(words[1:])
            if packages:
                found.append((directory, words, packages))
    return found


def selects_members(args: list[str]) -> bool:
    """Whether cargo ARGS is a subcommand whose -p picks workspace members, run from the directory's workspace:
    False for another subcommand, or one that names its manifest or directory itself (--manifest-path, -C)."""
    if any(a == "--manifest-path" or a.startswith("--manifest-path=") or a == "-C" for a in
           args[:args.index("--") if "--" in args else len(args)]):
        return False
    sub = next((a for a in args if not a.startswith(("-", "+"))), None)
    return sub in SELECTING


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


def without_packages(words: list[str]) -> list[str]:
    """WORDS (a cargo command) with every -p/--package flag removed."""
    out, i = [], 0
    while i < len(words):
        word = words[i]
        if word == "--":
            out += words[i:]
            break
        if word in ("-p", "--package"):
            i += 2
            continue
        if word.startswith("--package=") or (word.startswith("-p") and not word.startswith("--") and len(word) > 2):
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
    """The workspace cargo picks from DIRECTORY (inside ROOT), as (its directory, its manifest), when it is an
    ancestor's: the nearest Cargo.toml at or above DIRECTORY is a [workspace], or a package whose nearest
    [workspace] ancestor neither excludes it nor is overridden by a package.workspace key. None when cargo runs a
    standalone package there (excluded, or its own workspace) or there is no workspace at all."""
    def up(start: Path):
        here = start
        while True:
            yield here
            if here == root or root not in here.parents:
                return
            here = here.parent

    package_dir = None
    for here in up(directory):
        data = manifest(here / "Cargo.toml")
        if data is None:
            continue
        if isinstance(data.get("workspace"), dict):
            if package_dir is not None and member_reason(here, data["workspace"], package_dir) is not None:
                return None  # that workspace excludes the package cargo starts from: it runs standalone
            return here, data
        if package_dir is None:
            if isinstance(data.get("package"), dict) and "workspace" in data["package"]:
                return None  # package.workspace names the root itself; not followed here
            package_dir = here
    return None


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


def member_reason(workspace: Path, config: dict, crate: Path) -> str | None:
    """Why WORKSPACE's [workspace] (CONFIG) excludes CRATE, or None. A path listed literally in members wins over
    an exclude, as in cargo."""
    if crate == workspace:
        return None
    rel = crate.relative_to(workspace)
    if any(Path(os.path.normpath(str(m))).parts == rel.parts for m in config.get("members") or []):
        return None
    for entry in config.get("exclude") or []:
        parts = Path(os.path.normpath(str(entry))).parts
        if rel.parts[:len(parts)] == parts:
            return f"{workspace.name}/Cargo.toml lists {entry} under [workspace] exclude"
    return None


def outside_reason(workspace: Path, config: dict, crate: Path, data: dict) -> str | None:
    """Why CRATE is not a member of WORKSPACE (CONFIG its [workspace] table), or None when it may be one."""
    if crate == workspace:
        return None
    rel = crate.relative_to(workspace)
    excluded = member_reason(workspace, config, crate)
    if excluded:
        return excluded
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
            rest = without_packages(words)
            others = [other for other in packages if other != name]
            refusals.append(
                f"{name} is not a member of the workspace at {workspace.relative_to(root)} ({reason}), and "
                f"`cargo -p {name}` from there does not say so on Linux: cargo panics with \"{PANIC}\". "
                f"Nothing was run. Next step: run it in the crate's own workspace: "
                f"directory={crate.relative_to(root)}, command: {shlex.join(rest)} "
                f"(cmux-ci test: cd {crate.relative_to(root)} && cmux-ci test -- {shlex.join(rest)})"
                + (f"; run the other packages ({', '.join(others)}) apart, in {workspace.relative_to(root)}"
                   if others else ""))
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
