#!/usr/bin/env python3
"""Gates that every legacy top-level dispatch command and alias, every command
`cmux help` lists, and every `vm` verb the legacy runner dispatches or
`cmux vm --help` lists is declared in the ArgumentParser facade tree; that the
generated completion offers each documented flag spelling (`--skill`); and that
each hard-coded alias resolves to the same help output as its target.

This is the safety net for the family-by-family declaration tasks: it is easy
to migrate a command name but silently drop one of its aliases, or declare an
alias that points at the wrong target. Both are caught here.

Passthrough aliases (`cr`) are gated separately: they share their target's
routing but deliberately not its help, so they are checked for alias
declaration and for never serving the target's cmux-owned help.
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
    "open-browser": "browser open",
    "navigate": "browser navigate",
    "browser-back": "browser back",
    "browser-forward": "browser forward",
    "browser-reload": "browser reload",
    "get-url": "browser get-url",
    "focus-webview": "browser focus-webview",
    "is-webview-focused": "browser is-webview-focused",
}

# Aliases that route and complete as their target but deliberately do NOT share
# its help, because the alias passes the invocation through to an external CLI.
# `cmux cr ...` is always the installed CodeRouter CLI, while `cmux coderouter`
# keeps the verbs cmux owns (`status`, `machines`, `claude`, help). See the
# passthrough branch in CLI/cmux.swift.
#
# Checking these for help equality would be wrong, but dropping them would stop
# gating the half of the contract that does hold: the alias must still be
# declared on the target in the facade tree, and it must never serve the
# target's cmux-owned help. Both are asserted below, and neither depends on the
# external CLI being installed.
PASSTHROUGH_ALIASES = {"cr": "coderouter"}

# Body text unique to the cmux-owned `coderouter` help. This must be a line
# from the help *body*, not the banner or the "Usage:" line: a genuine alias
# echoes the invoked name on those two lines (`cmux cloud` prints
# "Usage: cmux cloud ...") but repeats the body verbatim, so only a body marker
# actually detects an alias wrongly serving its target's help.
PASSTHROUGH_TARGET_HELP_MARKERS = {
    "coderouter": "Team settings for the cmux coderouter model plane",
}


def repo_root() -> Path:
    return Path(__file__).resolve().parent.parent


def legacy_source_lines() -> list[str]:
    return (repo_root() / "CLI" / "cmux.swift").read_text(encoding="utf-8").splitlines()


def extract_legacy_dispatch_names() -> set[str]:
    lines = legacy_source_lines()

    start = None
    for index, line in enumerate(lines):
        if line.strip() == "switch command {":
            start = index
            break
    if start is None:
        raise RuntimeError("could not locate the top-level dispatch switch in CLI/cmux.swift")

    return switch_case_labels(lines, start, "the top-level dispatch switch")


def extract_legacy_vm_verbs() -> set[str]:
    """Verbs and aliases the legacy `vm`/`cloud` runner dispatches on."""
    lines = legacy_source_lines()

    arm = next((i for i, line in enumerate(lines) if line.strip() == 'case "vm", "cloud":'), None)
    if arm is None:
        raise RuntimeError('could not locate the `case "vm", "cloud":` arm in CLI/cmux.swift')
    start = next((i for i in range(arm + 1, len(lines)) if lines[i].strip() == "switch sub {"), None)
    if start is None:
        raise RuntimeError("could not locate the vm verb switch in CLI/cmux.swift")

    return switch_case_labels(lines, start, "the vm verb switch")


def switch_case_labels(lines: list[str], start: int, description: str) -> set[str]:
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
        raise RuntimeError(f"could not locate the default: arm closing {description}")

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


def extract_declared_aliases(cli: str) -> dict[str, set[str]]:
    """Maps each top-level command to the aliases declared on it in the facade tree."""
    proc = subprocess.run(
        [cli, "__dump-command-tree"],
        text=True, capture_output=True, check=False, timeout=30.0,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"__dump-command-tree exited {proc.returncode}\n{proc.stderr}")

    declared: dict[str, set[str]] = {}
    for line in proc.stdout.splitlines():
        if not line.startswith("command  "):
            continue
        rest = line[len("command  "):]
        path, _, tail = rest.partition("  aliases=")
        if " " in path:
            continue  # nested subcommand path, not a top-level dispatch name
        aliases = tail.strip()
        declared[path] = (
            set() if not aliases or aliases == "-"
            else {alias.strip() for alias in aliases.split(",")}
        )
    return declared


def extract_declared_subcommand_names(cli: str, parent: str) -> set[str]:
    """Names and aliases of the subcommands declared directly under `parent`."""
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
        path, _, tail = line[len("command  "):].partition("  aliases=")
        words = path.split(" ")
        if len(words) != 2 or words[0] != parent:
            continue
        names.add(words[1])
        aliases = tail.strip()
        if aliases and aliases != "-":
            names.update(alias.strip() for alias in aliases.split(","))

    return names


def extract_documented_entries(cli: str, argv: list[str], header: str) -> tuple[set[str], set[str]]:
    """Command names and `--flag` spellings a help section advertises.

    The dispatch-switch scans cannot see what the legacy parser handles before
    those switches (`sudo`, `guide`, `sessions`, `vm guide`, `--skill`, ...).
    That is still the documented surface, and an undeclared spelling silently
    drops out of shell completion and typo suggestions while still running,
    so nothing else notices.
    """
    proc = subprocess.run(
        [cli, *argv],
        text=True, capture_output=True, check=False, timeout=30.0,
        env={**os.environ, "CMUX_SOCKET_PATH": "/tmp/cmux-dispatch-parity-absent.sock"},
    )
    if proc.returncode != 0:
        raise RuntimeError(f"`cmux {' '.join(argv)}` exited {proc.returncode}\n{proc.stderr}")
    _, found, section = proc.stdout.partition(f"\n{header}\n")
    if not found:
        raise RuntimeError(f"could not locate the {header} section in `cmux {' '.join(argv)}`")

    name_pattern = re.compile(r"[a-z][a-z0-9-]*")
    flag_pattern = re.compile(r"--([a-z][a-z0-9-]*)")
    names: set[str] = set()
    flags: set[str] = set()
    for line in section.splitlines():
        if line and not line.startswith(" "):
            break  # the next section (Environment:, Env:) starts unindented
        if not line.startswith("  ") or line.startswith("   "):
            continue  # blank, or a wrapped description continuing the entry above
        entry = line.strip()
        if entry.startswith("#"):
            continue
        # `a | b | c` lists sibling spellings only when the first alternative is
        # a bare word (`login | logout`, `guide | --skill`). Otherwise the
        # alternatives are forms of one command (`browser disable | enable |
        # status`), so only the leading word is a name.
        alternatives = entry.split(" | ")
        heads = [alternatives[0].split(" ")[0]]
        if " " not in alternatives[0]:
            heads = [alternative.split(" ")[0] for alternative in alternatives]
        for head in heads:
            if name_pattern.fullmatch(head):
                names.add(head)
            elif flag_match := flag_pattern.fullmatch(head):
                flags.add(flag_match.group(1))

    return names, flags


def extract_offered_long_flags(cli: str, path: str) -> set[str]:
    """Long flags the generated fish completion offers at exactly `path`.

    The command-tree dump omits the root command's own options, so the
    completion script is the one place both `cmux --skill` and
    `cmux vm --skill` can be observed the way a user reaches them.
    """
    proc = subprocess.run(
        [cli, "completion", "fish"],
        text=True, capture_output=True, check=False, timeout=30.0,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"`cmux completion fish` exited {proc.returncode}\n{proc.stderr}")
    pattern = re.compile(
        rf"__cmux_should_offer_completions_for_flags_or_options \"{re.escape(path)}\" [^']*' -l '([^']+)'"
    )
    return {match.group(1) for match in pattern.finditer(proc.stdout)}


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

    documented_names, documented_flags = extract_documented_entries(cli, ["help"], "Commands:")
    undeclared_documented = sorted(documented_names - declared_names)
    if undeclared_documented:
        print("FAIL: commands listed by `cmux help` but not declared in the facade tree:")
        for name in undeclared_documented:
            print(f"  {name}")
        return 1

    legacy_vm_verbs = extract_legacy_vm_verbs()
    documented_vm_verbs, documented_vm_flags = extract_documented_entries(cli, ["vm", "--help"], "Subcommands:")
    declared_vm_verbs = extract_declared_subcommand_names(cli, "vm")
    missing_vm = sorted((legacy_vm_verbs | documented_vm_verbs) - declared_vm_verbs)
    if missing_vm:
        print("FAIL: vm verbs dispatched by the legacy runner or listed by `cmux vm --help` "
              "but not declared under vm in the facade tree:")
        for name in missing_vm:
            print(f"  {name}")
        return 1

    flag_failures = [
        f"cmux --{flag}" for flag in sorted(documented_flags - extract_offered_long_flags(cli, "cmux"))
    ] + [
        f"cmux vm --{flag}" for flag in sorted(documented_vm_flags - extract_offered_long_flags(cli, "cmux vm"))
    ]
    if flag_failures:
        print("FAIL: documented flag spellings the generated completion does not offer:")
        for failure in flag_failures:
            print(f"  {failure}")
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
        # "this is an alias" banner (see docs/cli-contract.md) instead of
        # repeating the target's full help body. Match that banner
        # structurally, in either of its two wordings, so an unrelated
        # example mentioning the target elsewhere in the help body cannot
        # pass this check.
        alias_banner_patterns = (
            rf"^Legacy alias for 'cmux {re.escape(target)}'\.",
            rf"^Alias for `cmux {re.escape(target)}`\.",
        )
        if any(re.search(pattern, alias_help, flags=re.MULTILINE) for pattern in alias_banner_patterns):
            continue
        alias_failures.append((alias, target))

    if alias_failures:
        print("FAIL: aliases whose --help output diverges from their target:")
        for alias, target in alias_failures:
            print(f"  {alias} -> {target}")
        return 1

    declared_aliases = extract_declared_aliases(cli)
    passthrough_failures = []
    for alias, target in PASSTHROUGH_ALIASES.items():
        if alias not in declared_aliases.get(target, set()):
            passthrough_failures.append(
                f"{alias} is not declared as an alias of {target} in the facade tree"
            )
        marker = PASSTHROUGH_TARGET_HELP_MARKERS[target]
        if marker in help_text(cli, alias):
            passthrough_failures.append(
                f"`cmux {alias} --help` served {target}'s cmux-owned help "
                f"(found {marker!r}); it must pass through to the external CLI"
            )
        if marker not in help_text(cli, target):
            passthrough_failures.append(
                f"`cmux {target} --help` no longer contains {marker!r}; "
                "update PASSTHROUGH_TARGET_HELP_MARKERS"
            )

    if passthrough_failures:
        print("FAIL: passthrough alias contract violated:")
        for failure in passthrough_failures:
            print(f"  {failure}")
        return 1

    print(
        f"PASS: {len(legacy_names)} legacy dispatch names covered, "
        f"{len(documented_names)} documented commands declared, "
        f"{len(legacy_vm_verbs | documented_vm_verbs)} vm verbs declared, "
        f"{len(documented_flags) + len(documented_vm_flags)} documented flag spellings completed, "
        f"{len(ALIASES)} aliases resolve to their target, "
        f"{len(PASSTHROUGH_ALIASES)} passthrough aliases keep their contract"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
