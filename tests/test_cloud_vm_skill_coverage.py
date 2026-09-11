#!/usr/bin/env python3
"""
Keeps skills/cmux-cloud-vm in lockstep with the `cmux vm` CLI.

Ground truth is the Swift source (no binary needed, so this runs on the Linux
guard lane):

  - every `cmux vm <verb>` (and alias) the dispatcher accepts,
  - every `cmux vm workspace|terminal <sub>` and `cmux surface <sub>`,
  - the `cmux vm` usage line and its probe in docs/cli-contract.md,
  - every `vm.*` / `surface.*` socket method the app advertises.

The check fails when the skill documents a verb that does not exist, when a
verb exists that the skill does not document, when the "In flight" section
names something that already shipped, or when the usage line, the contract
probe, and the dispatcher disagree.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CLI_MAIN = ROOT / "CLI" / "cmux.swift"
CLI_TUI = ROOT / "CLI" / "CMUXCLI+VMTui.swift"
CONTROLLER = ROOT / "Sources" / "TerminalController.swift"
CONTRACT = ROOT / "docs" / "cli-contract.md"
SKILL_DIR = ROOT / "skills" / "cmux-cloud-vm"
COMMANDS_MD = SKILL_DIR / "references" / "commands.md"
BUNDLED_SKILL = ROOT / "Resources" / "cloud-agent-skill.md"

# Every skill file whose `cmux vm …` examples must name real verbs.
SKILL_FILES = [
    SKILL_DIR / "SKILL.md",
    SKILL_DIR / "references" / "commands.md",
    SKILL_DIR / "references" / "agent-workflows.md",
    SKILL_DIR / "references" / "sidebar-parity.md",
    SKILL_DIR / "agents" / "openai.yaml",
    BUNDLED_SKILL,
]

# Verbs the dispatcher accepts but the usage line deliberately omits.
USAGE_LINE_INTERNAL = {"ssh-attach"}

CASE_RE = re.compile(r'^\s*case ((?:"[a-z][a-z-]*"(?:, )?)+):', re.M)
QUOTED_RE = re.compile(r'"([a-z][a-z-]*)"')
TOKEN_RE = re.compile(r"cmux (?:vm|cloud) ([a-z][a-z-]*)(?: ([a-z][a-z-]*))?")
SURFACE_TOKEN_RE = re.compile(r"cmux surface ([a-z][a-z-]*)")
VPN_TOKEN_RE = re.compile(r"cmux vpn ([a-z][a-z-]*)")


def case_groups(block: str) -> list[set[str]]:
    return [set(QUOTED_RE.findall(match)) for match in CASE_RE.findall(block)]


def vm_dispatch_block(source: str) -> str:
    """The body of the `case "vm", "cloud":` switch in the command dispatcher."""
    marker = re.search(
        r'^        case "vm", "cloud":\n\s+let sub = commandArgs\.first\?\.lowercased\(\) \?\? "ls"\n',
        source,
        re.M,
    )
    if marker is None:
        raise RuntimeError("cannot find the `case \"vm\", \"cloud\":` dispatcher in CLI/cmux.swift")
    rest = source[marker.end():]
    end = re.search(r'^        (?:case "|default:)', rest, re.M)
    if end is None:
        raise RuntimeError("cannot find the end of the vm dispatcher")
    return rest[: end.start()]


def function_switch_block(source: str, function_name: str) -> str:
    start = source.find(f"func {function_name}(")
    if start < 0:
        raise RuntimeError(f"cannot find {function_name} in {CLI_TUI.name}")
    rest = source[start:]
    end = re.search(r"^    (?:func |static |// MARK)", rest[1:], re.M)
    return rest[: end.start() + 1] if end else rest


def sub_verbs(block: str) -> set[str]:
    verbs: set[str] = set()
    for group in case_groups(block):
        verbs |= group
    # `cmux vm terminal close` is a guard, not a switch, on today's main.
    verbs |= set(re.findall(r'positional\[0\] == "([a-z][a-z-]*)"', block))
    return verbs


def usage_line_verbs(source: str) -> list[str]:
    """The `cmux vm` overview's usage line (the one `--help` prints)."""
    match = re.search(r'return """\n\s+Usage: cmux \\\(command\) <([^>]+)> \[args\.\.\.\]', source)
    if match is None:
        raise RuntimeError("cannot find the `cmux vm` usage line in CLI/cmux.swift")
    return match.group(1).split("|")


def error_usage_verbs(source: str) -> list[str]:
    """The usage line the unknown-verb error prints; a subset, but it must not lie."""
    matches = re.findall(r'CLIError\(message: """\n\s+Usage: cmux \\\(command\) <([^>]+)> \[args\.\.\.\]', source)
    if not matches:
        raise RuntimeError("cannot find the unknown-verb error's usage line in CLI/cmux.swift")
    return [verb for match in matches for verb in match.split("|")]


def contract_probe_verbs(contract: str) -> list[str]:
    match = re.search(r"^- `cmux vm --help` -> `Usage: cmux vm <([^>]+)> \[args\.\.\.\]`$", contract, re.M)
    if match is None:
        raise RuntimeError("docs/cli-contract.md has no `cmux vm --help` probe")
    return match.group(1).split("|")


CLOUD_SURFACE_METHODS = {"surface.catalog", "surface.project", "surface.new_terminal"}


def advertised_methods(source: str) -> tuple[set[str], set[str]]:
    """(cloud methods the reference must cover, every method the app advertises)."""
    start = source.find('"vm.list",')
    if start < 0:
        raise RuntimeError("cannot find the vm.* capabilities list in Sources/TerminalController.swift")
    end = source.find("]", start)
    every = set(re.findall(r'"([a-z_]+\.[a-z_.]+)"', source[start:end]))
    cloud = {method for method in every if method.startswith("vm.")} | (CLOUD_SURFACE_METHODS & every)
    return cloud, every


def code_text(markdown: str) -> str:
    """Fenced blocks and inline code spans only, so prose cannot look like a verb."""
    fences = re.findall(r"```.*?\n(.*?)```", markdown, re.S)
    spans = re.findall(r"`([^`\n]+)`", re.sub(r"```.*?```", "", markdown, flags=re.S))
    return "\n".join(fences + spans)


def in_flight_section(markdown: str) -> str:
    match = re.search(r"^## In flight\b.*?(?=^## |\Z)", markdown, re.M | re.S)
    return match.group(0) if match else ""


def main() -> int:
    failures: list[str] = []
    cli_main = CLI_MAIN.read_text(encoding="utf-8")
    cli_tui = CLI_TUI.read_text(encoding="utf-8")

    groups = case_groups(vm_dispatch_block(cli_main))
    verbs = {verb for group in groups for verb in group}
    if not {"ls", "run", "route", "agent", "push", "pull", "wait", "tree", "workspace", "terminal"} <= verbs:
        failures.append(f"vm dispatcher parse looks wrong: {sorted(verbs)}")

    workspace_subs = sub_verbs(function_switch_block(cli_tui, "runVMWorkspaceCommand"))
    terminal_subs = sub_verbs(function_switch_block(cli_tui, "runVMTerminalCommand"))
    surface_subs = sub_verbs(function_switch_block(cli_tui, "runSurfaceCatalogCommand"))
    subs_by_verb = {"workspace": workspace_subs, "terminal": terminal_subs}
    if not workspace_subs or not terminal_subs or not surface_subs:
        failures.append(
            f"sub-verb parse looks wrong: workspace={sorted(workspace_subs)} "
            f"terminal={sorted(terminal_subs)} surface={sorted(surface_subs)}"
        )

    # The usage line, the contract probe, and the dispatcher must agree.
    usage = usage_line_verbs(cli_main)
    for verb in usage:
        if verb not in verbs:
            failures.append(f"usage line lists `{verb}` but the vm dispatcher has no such verb")
    for verb in error_usage_verbs(cli_main):
        if verb not in verbs:
            failures.append(f"the unknown-verb error lists `{verb}` but the vm dispatcher has no such verb")
    for group in groups:
        if group & USAGE_LINE_INTERNAL:
            continue
        if not group & set(usage):
            failures.append(f"usage line omits the verb group {sorted(group)}")
    probe = contract_probe_verbs(CONTRACT.read_text(encoding="utf-8"))
    if probe != usage:
        failures.append(
            "docs/cli-contract.md `cmux vm --help` probe differs from CLI/cmux.swift:\n"
            f"  probe:  {'|'.join(probe)}\n  source: {'|'.join(usage)}"
        )

    # The command reference must name every verb, alias, and sub-verb.
    commands = COMMANDS_MD.read_text(encoding="utf-8")
    shipped = code_text(commands[: commands.find("## In flight")] if "## In flight" in commands else commands)
    documented: dict[str, set[str]] = {}
    for verb, sub in TOKEN_RE.findall(shipped):
        documented.setdefault(verb, set())
        if sub:
            documented[verb].add(sub)
    for verb in sorted(verbs):
        if verb not in documented:
            failures.append(f"{COMMANDS_MD.relative_to(ROOT)} never shows `cmux vm {verb}`")
    for verb, subs in subs_by_verb.items():
        for sub in sorted(subs):
            if sub not in documented.get(verb, set()):
                failures.append(f"{COMMANDS_MD.relative_to(ROOT)} never shows `cmux vm {verb} {sub}`")
    documented_surface = set(SURFACE_TOKEN_RE.findall(shipped))
    for sub in sorted(surface_subs):
        if sub not in documented_surface:
            failures.append(f"{COMMANDS_MD.relative_to(ROOT)} never shows `cmux surface {sub}`")

    # Nothing the skill shows may be a verb that does not exist — except in the
    # "In flight" section, which may only name verbs that do not exist yet.
    for path in SKILL_FILES:
        if not path.exists():
            failures.append(f"missing skill file {path.relative_to(ROOT)}")
            continue
        text = path.read_text(encoding="utf-8")
        flight = in_flight_section(text) if path == COMMANDS_MD else ""
        shipped_text = text.replace(flight, "") if flight else text
        if path.suffix == ".md":
            shipped_text = code_text(shipped_text)
            flight = code_text(flight)
        for verb, sub in TOKEN_RE.findall(shipped_text):
            if verb not in verbs:
                failures.append(f"{path.relative_to(ROOT)} shows `cmux vm {verb}`, which the CLI does not have")
            elif verb in subs_by_verb and sub and sub not in subs_by_verb[verb]:
                failures.append(f"{path.relative_to(ROOT)} shows `cmux vm {verb} {sub}`, which the CLI does not have")
        for sub in SURFACE_TOKEN_RE.findall(shipped_text):
            if sub not in surface_subs:
                failures.append(f"{path.relative_to(ROOT)} shows `cmux surface {sub}`, which the CLI does not have")
        for verb, sub in TOKEN_RE.findall(flight):
            exists = verb in verbs and (verb not in subs_by_verb or not sub or sub in subs_by_verb[verb])
            if exists:
                failures.append(
                    f"{path.relative_to(ROOT)} lists `cmux vm {verb}{' ' + sub if sub else ''}` as in flight, "
                    "but it exists: move it into the reference"
                )

    # The vpn dispatcher (CLI/CMUXCLI+VPN.swift) and the reference must agree:
    # machines are unreachable without the tunnel, so a vpn verb the skill
    # misses (or invents) is a real gap.
    vpn_source = (ROOT / "CLI" / "CMUXCLI+VPN.swift").read_text(encoding="utf-8")
    vpn_verbs = {
        verb
        for group in case_groups(function_switch_block(vpn_source, "runVPNCommand"))
        for verb in group
    }
    if not {"up", "down", "status"} <= vpn_verbs:
        failures.append(f"vpn dispatcher parse looks wrong: {sorted(vpn_verbs)}")
    documented_vpn = set(VPN_TOKEN_RE.findall(shipped))
    for verb in sorted(vpn_verbs - documented_vpn):
        failures.append(f"{COMMANDS_MD.relative_to(ROOT)} never shows `cmux vpn {verb}`")
    for path in SKILL_FILES:
        if not path.exists():
            continue
        text = path.read_text(encoding="utf-8")
        if path == COMMANDS_MD:
            text = text.replace(in_flight_section(text), "")
        if path.suffix == ".md":
            text = code_text(text)
        for verb in VPN_TOKEN_RE.findall(text):
            if verb not in vpn_verbs:
                failures.append(f"{path.relative_to(ROOT)} shows `cmux vpn {verb}`, which the CLI does not have")

    # Socket methods: the reference names every advertised vm.*/surface.* method
    # and no method the app does not advertise.
    advertised, every_method = advertised_methods(CONTROLLER.read_text(encoding="utf-8"))
    mentioned = set(re.findall(r"\b((?:vm|surface)\.[a-z_]+)\b", shipped))
    for method in sorted(advertised - mentioned):
        failures.append(f"{COMMANDS_MD.relative_to(ROOT)} never mentions advertised socket method {method}")
    for method in sorted(mentioned - every_method):
        failures.append(f"{COMMANDS_MD.relative_to(ROOT)} mentions {method}, which the app does not advertise")

    if failures:
        print("FAIL: cmux-cloud-vm skill drifted from the CLI")
        for failure in failures:
            print(f"  - {failure}")
        return 1
    print(
        f"PASS: {len(verbs)} vm verbs, {len(workspace_subs)} workspace and {len(terminal_subs)} terminal sub-verbs, "
        f"{len(surface_subs)} surface sub-verbs, {len(vpn_verbs)} vpn verbs, {len(advertised)} socket methods covered"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
