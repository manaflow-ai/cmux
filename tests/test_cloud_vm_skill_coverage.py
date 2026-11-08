#!/usr/bin/env python3
"""
Keeps the Cloud skill and the affected CLI references in lockstep with the
current CLI and guest dispatcher.

Ground truth is the CLI, guest, and plugin source (no binary needed, so this
runs on the Linux guard lane):

  - every `cmux vm <verb>` (and alias) the dispatcher accepts,
  - every `cmux vm workspace|terminal <sub>` and `cmux surface <sub>`,
  - the `cmux vm` usage line and its probe in docs/cli-contract.md,
  - every `vm.*` / `surface.*` socket method the app advertises,
  - aliases, guest-only grammar, help options, and socket defaults called out
    by the CLI documentation.

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
CLI_TASK_HELP = ROOT / "CLI" / "CMUXCLI+TaskHelp.swift"
CLI_CODEROUTER = ROOT / "CLI" / "CMUXCLI+Coderouter.swift"
CLI_HIBERNATION = ROOT / "CLI" / "CMUXCLI+AgentHibernation.swift"
GUEST_CLI = ROOT / "web" / "services" / "vms" / "guestCli.ts"
OPENCODE_PLUGIN = ROOT / "Resources" / "opencode-plugin.js"
CAPABILITIES = ROOT / "Sources" / "TerminalController+Capabilities.swift"
CONTRACT = ROOT / "docs" / "cli-contract.md"
FEED_DOC = ROOT / "docs" / "feed.md"
WORKSPACE_SKILL = ROOT / "skills" / "cmux-workspace" / "SKILL.md"
BROWSER_COMMANDS = ROOT / "skills" / "cmux-browser" / "references" / "commands.md"
SKILL_DIR = ROOT / "skills" / "cmux-cloud-vm"
COMMANDS_MD = SKILL_DIR / "references" / "commands.md"
BUNDLED_SKILL = ROOT / "Resources" / "en.lproj" / "cloud-agent-skill.md"

# Every skill file whose `cmux vm …` examples must name real verbs.
SKILL_FILES = [
    SKILL_DIR / "SKILL.md",
    SKILL_DIR / "references" / "commands.md",
    SKILL_DIR / "references" / "agent-workflows.md",
    SKILL_DIR / "references" / "sidebar-parity.md",
    SKILL_DIR / "agents" / "openai.yaml",
    BUNDLED_SKILL,
]
SKILL_FILES.extend(path for path in sorted(SKILL_DIR.rglob("*.md")) if path not in SKILL_FILES)
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


CLOUD_SURFACE_METHODS = {"surface.catalog", "surface.project", "surface.new_terminal", "surface.new_display"}


def advertised_methods(source: str) -> tuple[set[str], set[str]]:
    """(cloud methods the reference must cover, every method the app advertises)."""
    start = source.find('"vm.list",')
    if start < 0:
        raise RuntimeError("cannot find the vm.* capabilities list in Sources/TerminalController+Capabilities.swift")
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


def cli_docs_drift_failures() -> list[str]:
    """Check the command details that verb coverage alone cannot validate."""
    failures: list[str] = []
    commands = COMMANDS_MD.read_text(encoding="utf-8")
    contract = CONTRACT.read_text(encoding="utf-8")
    task_help = CLI_TASK_HELP.read_text(encoding="utf-8")
    coderouter = CLI_CODEROUTER.read_text(encoding="utf-8")
    hibernation = CLI_HIBERNATION.read_text(encoding="utf-8")
    guest_cli = GUEST_CLI.read_text(encoding="utf-8")
    opencode_plugin = OPENCODE_PLUGIN.read_text(encoding="utf-8")
    feed = FEED_DOC.read_text(encoding="utf-8")
    workspace = WORKSPACE_SKILL.read_text(encoding="utf-8")
    browser_commands = BROWSER_COMMANDS.read_text(encoding="utf-8")

    # These are executable aliases/grammars, not merely prose. Keep the
    # references tied to the dispatchers that agents will actually run.
    guest_vm = re.search(r'case "\\\$sub" in\n(?P<body>.*?)\n      connect\)', guest_cli, re.S)
    if guest_vm is None or not re.search(r"\bls\|list\|peers\|links\b", guest_vm.group("body")):
        failures.append("guest vm dispatcher no longer exposes ls/list/peers/links")
    if "`cmux cloud ls` == `cmux vm ls`" not in commands:
        failures.append("cloud ls reference does not document the vm ls alias")
    if "guest `cmux vm ls` lists the team's machines" not in commands:
        failures.append("cloud reference does not use the guest vm ls grammar")
    if "guest `cmux vm self` lists the team's machines" in commands:
        failures.append("cloud reference still claims guest vm self lists machines")

    owned = re.search(r"cmuxOwnedCoderouterVerbs: Set<String> = \[(?P<verbs>[^]]+)\]", coderouter)
    if owned is None or "agent" not in QUOTED_RE.findall(owned.group("verbs")):
        failures.append("coderouter source no longer declares agent as an owned verb")
    if "`cmux coderouter <status\\|machines\\|claude\\|agent>`" not in contract:
        failures.append("cli contract omits the app-owned coderouter agent verb")

    hibernation_has_target_form = "cmux agent-hibernation <hibernate|wake> <surface>" in hibernation
    if hibernation_has_target_form and "cmux agent-hibernation <hibernate|wake> <surface>" not in contract:
        failures.append("cli contract omits the agent-hibernation target form")
    close_help = re.search(r'case "close-window":\n\s+return """\n\s+(Usage: cmux close-window [^\n]+)', CLI_MAIN.read_text(encoding="utf-8"))
    if close_help is None:
        failures.append("could not read close-window usage from the CLI")
    elif f"`cmux close-window --help` -> `{close_help.group(1)}`" not in contract:
        failures.append("cli contract close-window probe omits the live usage options")

    design_mode = re.search(r"browser design-mode ([a-z|]+) \[--surface", task_help)
    if design_mode is None:
        failures.append("could not read browser design-mode verbs from task help")
    elif f"design-mode {design_mode.group(1)}" not in browser_commands:
        failures.append("browser skill design-mode verbs differ from task help")

    default_socket = re.search(
        r"CMUX_SOCKET_PATH\s+Override the Unix socket path\. Without this, the CLI defaults\s+to (~/\.local/state/cmux/cmux\.sock)",
        task_help,
    )
    if default_socket is None:
        failures.append("could not read the CLI's default socket path")
    else:
        path = default_socket.group(1)
        if path not in feed:
            failures.append("feed docs use a stale socket path")
        if ".local/state/cmux/cmux.sock" not in workspace or "/tmp/cmux.sock" in workspace:
            failures.append("workspace skill uses a stale socket fallback")
        if "auto-discovers tagged/debug sockets" not in task_help:
            failures.append("could not read the CLI's tagged/debug socket discovery guidance")
        elif "auto-discovers tagged/debug sockets" not in feed or "auto-discovers tagged/debug sockets" not in workspace:
            failures.append("socket docs omit the CLI's tagged/debug socket discovery guidance")
        plugin_default = re.search(
            r"const DEFAULT_SOCKET = `\$\{os\.homedir\(\)\}(/\.config/cmux/cmux\.sock)`",
            opencode_plugin,
        )
        if plugin_default is None:
            failures.append("could not read the OpenCode plugin's default socket path")
        elif f"~{plugin_default.group(1)}" not in feed:
            failures.append("feed docs omit the OpenCode plugin's default socket path")
    return failures


def main() -> int:
    """Run the source-to-reference coverage and documentation drift checks."""
    failures: list[str] = []
    cli_main = CLI_MAIN.read_text(encoding="utf-8")
    cli_tui = CLI_TUI.read_text(encoding="utf-8")

    failures.extend(cli_docs_drift_failures())

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
    advertised, every_method = advertised_methods(CAPABILITIES.read_text(encoding="utf-8"))
    mentioned = set(re.findall(r"\b((?:vm|surface)\.[a-z_]+)\b", shipped))
    for method in sorted(advertised - mentioned):
        failures.append(f"{COMMANDS_MD.relative_to(ROOT)} never mentions advertised socket method {method}")
    for method in sorted(mentioned - every_method):
        failures.append(f"{COMMANDS_MD.relative_to(ROOT)} mentions {method}, which the app does not advertise")

    if failures:
        print("FAIL: CLI documentation drifted from the source contract")
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
