#!/usr/bin/env python3
"""Generate shell completion scripts for the `cmux` CLI.

The completions are *derived*, never hand-maintained:

- Command names come from the authoritative `topLevelCommandNames` registry in
  `CLI/cmux.swift` (a flat `Set<String>` literal).
- Per-command flags, subcommands, and enum values are parsed best-effort from
  the `Commands:` section of the `usage()` help text in the same file (the same
  text the help contract test in `tests/test_cli_contract_help.py` probes from
  the built binary).

This split keeps command-name completion exact while letting flag completion
ride on the human-curated help text. When `CLI/cmux.swift` migrates to Swift
ArgumentParser (see #3254), the registry/help inputs can be replaced by
`--generate-completion-script` with no change to the emitted artifacts' shape.

Usage:
    # Regenerate the checked-in scripts from the source registry + heredoc:
    scripts/generate-cli-completions.py --write

    # Probe a built binary instead of the source heredoc:
    scripts/generate-cli-completions.py --write --cmux-bin /path/to/cmux

    # Emit one shell to stdout (for diffing in CI):
    scripts/generate-cli-completions.py --shell bash

Outputs (with --write): completions/cmux.bash, completions/cmux.zsh,
completions/cmux.fish
"""

from __future__ import annotations

import argparse
import glob
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_SOURCE = REPO_ROOT / "CLI" / "cmux.swift"
DEFAULT_OUT_DIR = REPO_ROOT / "completions"

# Commands the registry lists but that are internal plumbing, not meant to be
# typed by a human. Anything `__`-prefixed is filtered separately.
INTERNAL_COMMANDS = {
    "claude-hook",
    "codex-hook",
    "feed-hook",
    "set-hook",
    "setup-hooks",
    "uninstall-hooks",
    "ssh-pty-attach",
    "vm-pty-attach",
    "vm-pty-connect",
    "vm-ssh-attach",
    "ssh-session-end",
}

REGISTRY_RE = re.compile(r'^\s*"([^"]+)",\s*$')
FLAG_RE = re.compile(r"(--[a-z][a-z0-9-]*|-[A-Za-z])\b")
# `<a|b|c>` or `[a|b|c]` grammar groups (enum choices).
CHOICE_RE = re.compile(r"[<\[]([a-z][a-z0-9-]*(?:\|[a-z][a-z0-9-]*)+)[>\]]")
# `--flag <a|b|c>` flag-value enums.
FLAG_VALUE_RE = re.compile(r"(--[a-z][a-z0-9-]*)\s+<([a-z][a-z0-9-]*(?:\|[a-z][a-z0-9-]*)+)>")
# Leading command token of a help line, plus space-delimited `a | b | c` alias
# groups (the cmux convention for top-level aliases). Stops before a `cmd
# sub|sub` subcommand group, which has no spaces around its pipes.
LEAD_COMMAND_RE = re.compile(r"^[a-z][a-z0-9-]*(?:\s*\|\s*[a-z][a-z0-9-]*)*")

# Value-bearing global options parsed before the command word in
# CLI/cmux.swift run() (each consumes the following token). The command scan in
# each emitter skips these plus their values; boolean globals like `--json` need
# no special handling because the scan already skips any leading `-option`.
GLOBAL_VALUE_FLAGS = ("--socket", "--id-format", "--window", "--password")

# Type-descriptor tokens that appear inside `<...>` as metavariables, NOT as
# literal values a user would type (e.g. `--pane <id|ref|index>`). A choice
# group containing any of these is a placeholder, not a completable enum.
METAVARS = {
    "id", "ref", "index", "uuid", "n", "path", "text", "url", "name", "title",
    "points", "ms", "seconds", "count", "hex", "cmd", "command", "script",
    "selector", "css", "key", "value", "query", "email", "body", "image",
    "level", "target", "profile", "args", "opt", "host", "port", "ws", "event",
}


def is_real_enum(tokens: list[str]) -> bool:
    """A choice group is a completable enum only if no token is a metavar."""
    return bool(tokens) and not any(t in METAVARS for t in tokens)


@dataclass
class CommandSpec:
    name: str
    flags: set[str] = field(default_factory=set)
    subcommands: set[str] = field(default_factory=set)
    flag_values: dict[str, list[str]] = field(default_factory=dict)


def resolve_cmux_bin(explicit: str | None) -> str:
    """Locate a cmux binary to probe, mirroring the help-contract test."""
    if explicit:
        if os.path.exists(explicit) and os.access(explicit, os.X_OK):
            return explicit
        raise SystemExit(f"--cmux-bin not found or not executable: {explicit}")
    env = os.environ.get("CMUX_CLI_BIN") or os.environ.get("CMUX_CLI")
    if env and os.path.exists(env) and os.access(env, os.X_OK):
        return env
    candidates = glob.glob(
        os.path.expanduser(
            "~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/cmux"
        )
    )
    candidates = [c for c in candidates if os.path.exists(c) and os.access(c, os.X_OK)]
    if candidates:
        candidates.sort(key=os.path.getmtime, reverse=True)
        return candidates[0]
    from shutil import which

    found = which("cmux")
    if found:
        return found
    raise SystemExit(
        "No cmux binary found. Pass --cmux-bin, set CMUX_CLI_BIN, or use --help-file."
    )


def extract_usage_heredoc(source_path: Path) -> str:
    """Return the help text from the `usage()` heredoc in CLI/cmux.swift.

    This is the canonical input for regeneration: it is the exact string
    `cmux help` prints, lives in the same file as the command registry, and is
    available in CI without building the binary -- so `--write` and the
    contract test always agree on one source of truth (no binary/source skew).
    """
    text = source_path.read_text(encoding="utf-8")
    anchor = text.find("private func usage()")
    if anchor == -1:
        raise SystemExit(f"usage() not found in {source_path}")
    open_q = text.find('"""', anchor)
    close_q = text.find('"""', open_q + 3)
    if open_q == -1 or close_q == -1:
        raise SystemExit("Could not bound the usage() heredoc")
    heredoc = text[open_q + 3 : close_q]
    if "Commands:" not in heredoc:
        raise SystemExit("usage() heredoc has no Commands section")
    return heredoc


def load_help_text(args: argparse.Namespace) -> str:
    if args.help_file:
        return Path(args.help_file).read_text(encoding="utf-8")
    if args.cmux_bin:
        binary = resolve_cmux_bin(args.cmux_bin)
        proc = subprocess.run(  # noqa: S603
            [binary, "help"], capture_output=True, text=True, timeout=30, check=False
        )
        # `cmux help` prints usage without needing a socket.
        text = proc.stdout or proc.stderr
        if "Commands:" not in text:
            raise SystemExit(
                f"`{binary} help` did not produce a Commands section:\n{text[:400]}"
            )
        return text
    # Canonical default: parse the heredoc straight from source.
    return extract_usage_heredoc(Path(args.source))


def parse_registry(source_path: Path) -> list[str]:
    """Extract command names from the `topLevelCommandNames` Set literal."""
    text = source_path.read_text(encoding="utf-8")
    start = text.find("topLevelCommandNames: Set<String> = [")
    if start == -1:
        raise SystemExit(f"topLevelCommandNames not found in {source_path}")
    end = text.find("]", start)
    block = text[start:end]
    names = []
    for line in block.splitlines():
        m = REGISTRY_RE.match(line)
        if m:
            names.append(m.group(1))
    if not names:
        raise SystemExit("Parsed zero command names from registry")
    return names


def visible_commands(registry: list[str]) -> list[str]:
    out = [
        c
        for c in registry
        if not c.startswith("__") and c not in INTERNAL_COMMANDS
    ]
    return sorted(set(out))


def help_commands_region(help_text: str) -> list[str]:
    """Lines under the `Commands:` header, up to the next top-level section.

    Works whether the help text is dedented (`cmux help` from the binary, where
    section headers sit at column 0) or raw from the source heredoc (where every
    line keeps its Swift source indentation). A new section is any line that ends
    with `:` and is indented no more than the `Commands:` header itself, so it
    stops at `Environment:` in both modes.
    """
    lines = help_text.splitlines()
    start = None
    header_indent = 0
    for i, line in enumerate(lines):
        if line.strip() == "Commands:":
            start = i
            header_indent = len(line) - len(line.lstrip())
            break
    if start is None:
        return []
    region = []
    for line in lines[start + 1 :]:
        stripped = line.strip()
        indent = len(line) - len(line.lstrip())
        if stripped and indent <= header_indent and stripped.endswith(":"):
            break  # next top-level section (e.g. "Environment:")
        region.append(line)
    return region


def parse_help(help_text: str, known: set[str]) -> dict[str, CommandSpec]:
    """Best-effort enrichment of flags/subcommands/enums per command.

    A help line is attributed to a command when its first bare-word token (or
    a `|`-separated alias group of bare words) is in the known command set.
    """
    specs: dict[str, CommandSpec] = {}
    for raw in help_commands_region(help_text):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        tokens = line.split()
        if not tokens:
            continue
        head = tokens[0]
        # Alias group like `disable-browser | enable-browser | browser-status`.
        alias_group = re.split(r"\s*\|\s*", line.split("  ")[0].split("[")[0].split("<")[0].strip())
        targets: list[str] = []
        if all(re.fullmatch(r"[a-z][a-z0-9-]*", a or "") and a in known for a in alias_group) and len(alias_group) > 1:
            targets = alias_group
        elif head in known:
            targets = [head]
        else:
            continue

        # Subcommand: a bare word, an unbracketed `a|b|c` group, or a bracketed
        # choice group immediately after a single command.
        sub: set[str] = set()
        if len(targets) == 1 and len(tokens) > 1:
            nxt = tokens[1]
            pipe_parts = nxt.split("|")
            if re.fullmatch(r"[a-z][a-z0-9-]*", nxt) and nxt not in METAVARS:
                sub.add(nxt)
            elif len(pipe_parts) > 1 and all(
                re.fullmatch(r"[a-z][a-z0-9-]*", p) for p in pipe_parts
            ):
                # Unbracketed pipe group of bare words = literal subcommand
                # alternatives (e.g. `feed tui|clear`, `browser goto|navigate`,
                # `browser url|get-url`). Placeholders are conventionally
                # bracketed, so the METAVARS filter does not apply here.
                sub.update(pipe_parts)
            for grp in CHOICE_RE.findall(" ".join(tokens[1:2])):
                choices = grp.split("|")
                if is_real_enum(choices):
                    sub.update(choices)

        flags = set(m for m in FLAG_RE.findall(line) if m.startswith("--"))
        flag_values = {
            fl: vals.split("|")
            for fl, vals in FLAG_VALUE_RE.findall(line)
            if is_real_enum(vals.split("|"))
        }

        for name in targets:
            spec = specs.setdefault(name, CommandSpec(name))
            spec.flags.update(f for f in flags if f.startswith("--"))
            spec.subcommands.update(sub)
            for fl, vals in flag_values.items():
                spec.flag_values.setdefault(fl, vals)
    return specs


def help_top_level_commands(help_text: str) -> list[str]:
    """Top-level command names documented in the `Commands:` help section.

    The leading token of each command line, plus space-delimited `a | b | c`
    alias groups (but not `cmd sub|sub` subcommand groups). Used to verify the
    registry covers every documented command.
    """
    names: set[str] = set()
    for raw in help_commands_region(help_text):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        m = LEAD_COMMAND_RE.match(line)
        if not m:
            continue
        for tok in re.split(r"\s*\|\s*", m.group(0)):
            if re.fullmatch(r"[a-z][a-z0-9-]*", tok):
                names.add(tok)
    return sorted(names)


def registry_coverage_gaps(source_path: Path) -> list[str]:
    """Commands documented in help but absent from the registry.

    `topLevelCommandNames` is the source of truth for command names; help must
    not document a top-level command the registry is unaware of, or completions
    silently miss it (the byte-diff drift check would not catch that, since both
    the committed scripts and the regeneration ride on the same registry).
    Returns the missing names so the contract test can fail loudly.
    """
    registry = set(parse_registry(source_path))
    documented = help_top_level_commands(extract_usage_heredoc(source_path))
    return sorted(c for c in documented if c not in registry)


# ---------------------------------------------------------------------------
# Emitters
# ---------------------------------------------------------------------------

HEADER = """# cmux shell completions ({shell}) -- AUTO-GENERATED, DO NOT EDIT.
#
# Regenerate with:  scripts/generate-cli-completions.py --write
# Source of truth:  topLevelCommandNames in CLI/cmux.swift + its usage() help.
"""


def emit_bash(commands: list[str], specs: dict[str, CommandSpec]) -> str:
    cmds = " ".join(commands)
    lines = [HEADER.format(shell="bash"), "_cmux() {"]
    lines.append("    local cur prev words cword")
    lines.append("    _init_completion 2>/dev/null || {")
    lines.append("        cur=\"${COMP_WORDS[COMP_CWORD]}\"")
    lines.append("        prev=\"${COMP_WORDS[COMP_CWORD-1]}\"")
    lines.append("        cword=$COMP_CWORD")
    lines.append("    }")
    lines.append("    # Locate the command word: first non-option after `cmux`,")
    lines.append("    # skipping value-bearing global options and their values.")
    lines.append("    local i cmd=\"\"")
    lines.append("    for ((i=1; i < COMP_CWORD; i++)); do")
    lines.append("        case \"${COMP_WORDS[i]}\" in")
    lines.append(f"            {'|'.join(GLOBAL_VALUE_FLAGS)}) ((i++)) ;;")
    lines.append("            -*) ;;")
    lines.append("            *) cmd=\"${COMP_WORDS[i]}\"; break ;;")
    lines.append("        esac")
    lines.append("    done")
    lines.append(f"    local commands=\"{cmds}\"")
    lines.append("    if [[ -z $cmd ]]; then")
    lines.append("        COMPREPLY=( $(compgen -W \"$commands\" -- \"$cur\") )")
    lines.append("        return")
    lines.append("    fi")
    lines.append("    case \"$cmd\" in")
    for name in commands:
        spec = specs.get(name)
        if not spec or (not spec.flags and not spec.subcommands):
            continue
        words = sorted(spec.subcommands) + sorted(spec.flags)
        lines.append(f"        {name})")
        # Flag value enums.
        for fl, vals in sorted(spec.flag_values.items()):
            lines.append(f"            if [[ $prev == {fl} ]]; then")
            lines.append(f"                COMPREPLY=( $(compgen -W \"{' '.join(vals)}\" -- \"$cur\") ); return")
            lines.append("            fi")
        lines.append(f"            COMPREPLY=( $(compgen -W \"{' '.join(words)}\" -- \"$cur\") ); return ;;")
    lines.append("    esac")
    lines.append("}")
    lines.append("complete -F _cmux cmux")
    lines.append("")
    return "\n".join(lines)


def emit_zsh(commands: list[str], specs: dict[str, CommandSpec]) -> str:
    lines = ["#compdef cmux", HEADER.format(shell="zsh"), "_cmux() {"]
    lines.append("    local -a commands")
    lines.append("    commands=(")
    for name in commands:
        lines.append(f"        '{name}'")
    lines.append("    )")
    # Locate the command word, skipping value-bearing global options and their
    # values, so completion works after `cmux --socket <path> ...` etc.
    lines.append("    local i cmd=\"\"")
    lines.append("    for (( i = 2; i < CURRENT; i++ )); do")
    lines.append("        case ${words[i]} in")
    lines.append(f"            {'|'.join(GLOBAL_VALUE_FLAGS)}) (( i++ )) ;;")
    lines.append("            -*) ;;")
    lines.append("            *) cmd=${words[i]}; break ;;")
    lines.append("        esac")
    lines.append("    done")
    lines.append("    if [[ -z $cmd ]]; then")
    lines.append("        _describe -t commands 'cmux command' commands")
    lines.append("        return")
    lines.append("    fi")
    lines.append("    local prev=${words[CURRENT-1]}")
    lines.append("    case $cmd in")
    for name in commands:
        spec = specs.get(name)
        if not spec or (not spec.flags and not spec.subcommands):
            continue
        comp_words = sorted(spec.subcommands) + sorted(spec.flags)
        joined = " ".join(comp_words)
        lines.append(f"        {name})")
        # Flag value enums (context-sensitive on the previous word), matching
        # the bash and fish emitters.
        for fl, vals in sorted(spec.flag_values.items()):
            lines.append(f"            if [[ $prev == {fl} ]]; then")
            lines.append(f"                compadd -- {' '.join(vals)}; return")
            lines.append("            fi")
        lines.append(f"            compadd -- {joined} ;;")
    lines.append("    esac")
    lines.append("}")
    lines.append("_cmux \"$@\"")
    lines.append("")
    return "\n".join(lines)


def emit_fish(commands: list[str], specs: dict[str, CommandSpec]) -> str:
    global_value_cases = " ".join(f"'{fl}'" for fl in GLOBAL_VALUE_FLAGS)
    lines = [HEADER.format(shell="fish")]
    # Resolve the active top-level cmux command by position (skipping global
    # options and the values of value-bearing ones), rather than matching a word
    # anywhere on the line -- so `cmux docs browser <Tab>` does not also trigger
    # the top-level `browser` completions.
    lines.append("function __cmux_command")
    lines.append("    set -l toks (commandline -opc)")
    lines.append("    set -l i 2")
    lines.append("    while test $i -le (count $toks)")
    lines.append("        switch $toks[$i]")
    lines.append(f"            case {global_value_cases}")
    lines.append("                set i (math $i + 2)")
    lines.append("            case '-*'")
    lines.append("                set i (math $i + 1)")
    lines.append("            case '*'")
    lines.append("                echo $toks[$i]")
    lines.append("                return")
    lines.append("        end")
    lines.append("    end")
    lines.append("end")
    lines.append("")
    lines.append("function __cmux_needs_command")
    lines.append("    set -l cmd (__cmux_command)")
    lines.append("    test -z \"$cmd\"")
    lines.append("end")
    lines.append("")
    lines.append("function __cmux_command_is")
    lines.append("    set -l cmd (__cmux_command)")
    lines.append("    test \"$cmd\" = \"$argv[1]\"")
    lines.append("end")
    lines.append("")
    for name in commands:
        lines.append(
            f"complete -c cmux -n __cmux_needs_command -f -a '{name}'"
        )
    lines.append("")
    for name in commands:
        spec = specs.get(name)
        if not spec:
            continue
        cond = f"__cmux_command_is {name}"
        for sub in sorted(spec.subcommands):
            lines.append(f"complete -c cmux -n '{cond}' -f -a '{sub}'")
        for flag in sorted(spec.flags):
            long = flag.lstrip("-")
            vals = spec.flag_values.get(flag)
            if vals:
                lines.append(
                    f"complete -c cmux -n '{cond}' -l {long} -f -a '{' '.join(vals)}'"
                )
            else:
                lines.append(f"complete -c cmux -n '{cond}' -l {long}")
    lines.append("")
    return "\n".join(lines)


EMITTERS = {"bash": emit_bash, "zsh": emit_zsh, "fish": emit_fish}
EXTENSIONS = {"bash": "bash", "zsh": "zsh", "fish": "fish"}


def build(args: argparse.Namespace) -> dict[str, str]:
    registry = parse_registry(Path(args.source))
    commands = visible_commands(registry)
    help_text = load_help_text(args)
    specs = parse_help(help_text, set(commands))
    return {shell: EMITTERS[shell](commands, specs) for shell in EMITTERS}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--source", default=str(DEFAULT_SOURCE), help="Path to CLI/cmux.swift")
    ap.add_argument("--cmux-bin", default=None, help="Probe `cmux help` from this built binary instead of the source heredoc")
    ap.add_argument("--help-file", default=None, help="Read `cmux help` text from a file instead of the source heredoc")
    ap.add_argument("--out-dir", default=str(DEFAULT_OUT_DIR), help="Output directory for --write")
    ap.add_argument("--shell", choices=sorted(EMITTERS), help="Emit one shell to stdout")
    ap.add_argument("--write", action="store_true", help="Write all scripts to --out-dir")
    ap.add_argument("--list-commands", action="store_true", help="Print visible command names, one per line, and exit")
    ap.add_argument("--check", action="store_true", help="Verify topLevelCommandNames covers every command documented in usage(); exit nonzero on drift")
    args = ap.parse_args()

    if args.list_commands:
        for name in visible_commands(parse_registry(Path(args.source))):
            print(name)
        return 0

    if args.check:
        gaps = registry_coverage_gaps(Path(args.source))
        if gaps:
            print(
                "Commands documented in usage() but missing from "
                f"topLevelCommandNames: {', '.join(gaps)}",
                file=sys.stderr,
            )
            return 1
        print("OK: topLevelCommandNames covers all documented commands")
        return 0

    outputs = build(args)

    if args.shell:
        sys.stdout.write(outputs[args.shell])
        return 0
    if args.write:
        out_dir = Path(args.out_dir)
        out_dir.mkdir(parents=True, exist_ok=True)
        for shell, content in outputs.items():
            dest = out_dir / f"cmux.{EXTENSIONS[shell]}"
            dest.write_text(content, encoding="utf-8")
            print(f"wrote {dest.relative_to(REPO_ROOT)}")
        return 0
    # Default: summary to stderr so it doesn't pollute a piped shell script.
    print("Nothing emitted. Pass --shell <bash|zsh|fish> or --write.", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
