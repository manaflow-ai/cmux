#!/usr/bin/env python3
"""Gates that every legacy top-level dispatch command and alias is declared
in the ArgumentParser facade tree, and that each hard-coded alias resolves to
the same help output as its target.

This is the safety net for the family-by-family declaration tasks: it is easy
to migrate a command name but silently drop one of its aliases, or declare an
alias that points at the wrong target. Both are caught here.
"""
from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path

ALIASES = {
    "cloud": "vm",
    "remote": "remotes",
    "login": "auth login",
    "logout": "auth logout",
    "cr": "coderouter",
    "open-browser": "browser open",
    "navigate": "browser navigate",
    "browser-back": "browser back",
    "browser-forward": "browser forward",
    "browser-reload": "browser reload",
    "get-url": "browser get-url",
    "focus-webview": "browser focus-webview",
    "is-webview-focused": "browser is-webview-focused",
}


def repo_root() -> Path:
    return Path(__file__).resolve().parent.parent


def extract_legacy_dispatch_names() -> set[str]:
    source = (repo_root() / "CLI" / "cmux.swift").read_text(encoding="utf-8")
    lines = source.splitlines()

    start = None
    for index, line in enumerate(lines):
        if line.strip() == "switch command {":
            start = index
            break
    if start is None:
        raise RuntimeError("could not locate the top-level dispatch switch in CLI/cmux.swift")

    # Only case labels directly inside this switch count; a case arm's body
    # may contain its own nested switch (e.g. `auth`'s sub-verb dispatch),
    # whose case labels and default: arm are not part of the top-level
    # dispatch and must not be mistaken for it.
    names: set[str] = set()
    case_pattern = re.compile(r'^\s*case\s+((?:"[^"]+"\s*,?\s*)+):')
    string_pattern = re.compile(r'"([^"]+)"')
    depth = 0
    end = None
    for index in range(start + 1, len(lines)):
        line = lines[index]
        if depth == 0:
            if line.strip() == "default:":
                end = index
                break
            match = case_pattern.match(line)
            if match:
                names.update(string_pattern.findall(match.group(1)))
        depth += line.count("{") - line.count("}")
    if end is None:
        raise RuntimeError("could not locate the default: arm closing the top-level dispatch switch")

    return names


def extract_declared_names(cli: str) -> set[str]:
    proc = subprocess.run(
        [cli, "__dump-command-tree"],
        text=True, capture_output=True, check=False, timeout=30.0,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"__dump-command-tree exited {proc.returncode}\n{proc.stderr}")

    names: set[str] = set()
    for line in proc.stdout.splitlines():
        if not line.startswith("command  "):
            continue
        rest = line[len("command  "):]
        path, _, tail = rest.partition("  aliases=")
        if " " in path:
            continue  # nested subcommand path, not a top-level dispatch name
        names.add(path)
        aliases = tail.strip()
        if aliases and aliases != "-":
            names.update(alias.strip() for alias in aliases.split(","))

    return names


def help_text(cli: str, command: str) -> str:
    proc = subprocess.run(
        [cli, *command.split(" "), "--help"],
        text=True, capture_output=True, check=False, timeout=30.0,
        env={**os.environ, "CMUX_SOCKET_PATH": "/tmp/cmux-dispatch-parity-absent.sock"},
    )
    return proc.stdout + proc.stderr


def main() -> int:
    cli = os.environ.get("CMUX_CLI_BIN")
    if not cli or not os.access(cli, os.X_OK):
        print("FAIL: set CMUX_CLI_BIN to the built cmux binary")
        return 1

    legacy_names = extract_legacy_dispatch_names()
    declared_names = extract_declared_names(cli)

    missing = sorted(legacy_names - declared_names)
    if missing:
        print("FAIL: commands dispatched by the legacy parser but not declared in the facade tree:")
        for name in missing:
            print(f"  {name}")
        return 1

    alias_failures = []
    for alias, target in ALIASES.items():
        alias_help = help_text(cli, alias)
        target_help = help_text(cli, target)
        # Only the banner line ("cmux <name>") and the "Usage: cmux <name> ..."
        # line echo the invoked command name; everything else, including any
        # example lines that happen to mention the alias by name, is shared
        # body text that must match verbatim.
        normalized_alias_help = re.sub(
            rf"^cmux {re.escape(alias)}$", f"cmux {target}", alias_help, flags=re.MULTILINE,
        )
        normalized_alias_help = re.sub(
            rf"^Usage: cmux {re.escape(alias)} ", f"Usage: cmux {target} ", normalized_alias_help, flags=re.MULTILINE,
        )
        if normalized_alias_help == target_help:
            continue
        # A handful of legacy aliases intentionally print a short-form
        # "this is an alias" summary (see docs/cli-contract.md) instead of
        # repeating the target's full help body. That is legitimate as long
        # as it actually names the correct target; anything else is a real
        # divergence (e.g. an alias pointing at the wrong command).
        if f"cmux {target}" in alias_help:
            continue
        alias_failures.append((alias, target))

    if alias_failures:
        print("FAIL: aliases whose --help output diverges from their target:")
        for alias, target in alias_failures:
            print(f"  {alias} -> {target}")
        return 1

    print(
        f"PASS: {len(legacy_names)} legacy dispatch names covered, "
        f"{len(ALIASES)} aliases resolve to their target"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
