#!/usr/bin/env python3
"""Assign the framed-IPC attributes of cmux-tui/spec/sdk-schema.json.

spec/transports.md, "Framed IPC method attributes", defines the attributes and
"Assigning method ids" the rules this script applies. It adds what is
missing and never changes an id, a family, a priority, an ordering or a
durability already in the schema, so a second run gives no diff and ids stay
append-only (Mojo ordinals, mojo/public/tools/bindings/README.md). A command
or event added later gets its family's `next_ordinal`, which only grows, so
the id of a removed command is never given again. `clients` and
`spawns_terminal` follow their sources on every run.

  assign-ipc-method-ids.py           write the missing attributes
  assign-ipc-method-ids.py --check   exit 1 if a run would change the schema

Rules, each a table below:
  family       FAMILIES / EVENT_FAMILIES: exactly one family per name
  ordinal      file order inside the family, from the family's next_ordinal
  priority     the p05-ipc-011 table; anything unlisted is control
  ordering     independent only for INDEPENDENT (reviewed read-only reads)
  durability   read_only / memory / reply_after_journal lists, else
               reply_before_journal
  stream       a command that names a surface, terminal or view is
               stream_scoped unless CROSSES_STREAM_OK gives the reason
  spawns       SPAWNS_TERMINAL (the daemon commands that may start a
               terminal host); it must hold every Swift
               `TerminalSpawningRequest` command
  clients      sdk for every command; macos for the ipc-census Q1 names,
               cli for the Q14 names; ios is kept when set by hand

Stdlib only, plus the schema validator in cmux-tui/bindings/codegen.
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import re
import subprocess
import sys
from collections.abc import Callable, Iterable, Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
SCHEMA = ROOT / "cmux-tui/spec/sdk-schema.json"
CENSUS = ROOT / "scripts/cmux-next/ipc-census.py"
SWIFT_SOURCES = "Packages/macOS/CmuxNext/Sources"

sys.path.insert(0, str(ROOT / "cmux-tui/bindings"))
from codegen.ipc_meta import STREAM_TARGET_FIELDS, IpcMetaValidator, family_kind  # noqa: E402
from codegen.validate import ValidationError, validate_document  # noqa: E402


class AssignError(Exception):
    pass


# Families ------------------------------------------------------------------
# name -> (id, description, patterns). Append-only: a family keeps its id
# forever; a new family takes the next free id of its range. Patterns are
# fnmatch globs over wire names; every name matches exactly one family.

FAMILIES: dict[str, tuple[int, str, tuple[str, ...]]] = {
    "daemon": (0x01, "Daemon identity, liveness, configuration and machine state.", (
        "identify", "ping", "shutdown-daemon", "reload-config", "server-stats", "machine-*",
        "subscribe-activity", "ws-listen", "page-credential", "pairing-response",
        "set-default-colors", "set-window-title", "clear-window-title",
    )),
    "clients": (0x02, "Connected clients and their focus.", (
        "set-client-info", "list-clients", "detach-client", "client-focus", "report-focus",
    )),
    "terminal-io": (0x03, "Terminal input, output streams, screen reads and terminal requests to the frontend.", (
        "send", "send-key", "paste-image", "read-screen", "read-scrollback", "wait-for", "copy",
        "clear-history", "vt-state", "scroll-surface", "snapshot-request", "terminal-history",
        "terminal-read-range", "terminal-events", "attach-surface", "subscribe",
        "mint-terminal-renderer", "mint-terminal-renderer-by-terminal", "get-cell-pixels",
        "set-cell-pixels", "url-open", "url-open-*", "terminal-clipboard-*",
    )),
    "terminals": (0x04, "Terminal hosts: lifetime, processes and command history.", (
        "list-terminals", "resolve-terminal", "close-terminal", "create-terminal", "move-terminal",
        "run", "set-terminal-*", "terminal-resume-command", "process-info", "terminal-ports",
        "terminal-resources", "list-terminal-commands", "delete-terminal-commands", "sidebar-plugin",
    )),
    "sizing": (0x05, "Surface sizes, attached views and sizing policy.", (
        "resize-surface", "release-surface-size", "resize-attached-view",
        "release-attached-view-size", "detach-attached-view", "reattach-view", "set-size-*",
        "get-size-state", "note-size-activity", "get-host-size-policy", "set-host-size-policy",
        "set-client-sizing",
    )),
    "layout": (0x06, "Panes, splits, columns, rows and layout export.", (
        "new-pane", "new-pane-right", "split", "new-row", "set-ratio", "set-split-ratio",
        "set-viewport-pane-width", "set-column-dock", "set-row-heights", "move-column",
        "undo-layout", "pane-neighbor", "focus-direction", "focus-pane", "swap-pane", "zoom-pane",
        "close-pane", "rename-pane", "export-layout", "apply-layout", "ids",
    )),
    "tabs": (0x07, "Tabs (surfaces) in panes: create, move, close, select and tab metadata.", (
        "new-tab", "new-browser-tab", "new-conversation-tab", "bind-conversation-tab-session",
        "new-frontend-browser-tab", "update-frontend-browser-tab", "new-remote-terminal-tab",
        "update-remote-terminal-tab", "remote-terminal-snapshot", "create-surface-with-receipt",
        "restart-tab", "park-tabs", "set-frontend-browser-history", "get-frontend-browser-history",
        "move-tab", "move-tab-to-*", "close-surface", "close-tabs", "rename-surface", "select-tab",
        "set-tab-pinned", "ack-tab-notifications", "list-notifications", "notify",
    )),
    "tab-groups": (0x08, "Tab groups and saved tab groups.", ("*tab-group*", "*tab-groups")),
    "screens": (0x09, "Screens, screen groups and saved screen groups.", (
        "new-screen", "set-screen-*", "move-screen", "close-screen", "rename-screen",
        "select-screen", "*screen-group*", "*screen-groups",
    )),
    "workspaces": (0x0A, "Workspaces, workspace groups and frontend projections.", (
        "list-workspaces", "new-workspace", "create-workspace", "move-workspace", "close-workspace",
        "rename-workspace", "select-workspace", "set-workspace-metadata", "*workspace-group*",
        "*workspace-groups", "move-workspace-to-group", "*provider-managed*",
        "get-frontend-projection", "put-frontend-projection", "journal-frontend-event",
    )),
    "browser": (0x0B, "Browser input, navigation, browser providers and browser profiles.", (
        "browser-*", "register-browser-provider", "get-browser-provider",
        "unregister-browser-provider", "*-browser-profile",
    )),
    "bookmarks": (0x0C, "Browser bookmarks.", ("*bookmark", "*bookmarks")),
    "personal": (0x0D, "Personal profiles, sessions, personal groups and pins.", (
        "list-personal", "create-profile", "update-profile", "move-profile", "delete-profile",
        "set-profile-follows", "pin-workspace", "unpin-workspace", "put-session",
        "forget-session", "set-session-icon", "import-session-organization",
        "*-personal-group", "set-personal-*",
    )),
    "agents": (0x0E, "Agents in terminals, the local feed and agent CLI updates.", (
        "list-agents", "report-agent", "feed-local-*", "agent-cli-intents-*", "agent-cli-update-job*",
    )),
    "conversations": (0x0F, "Local conversations, runs, attachments, inbox and search.", (
        "conversation-*", "home-inbox", "history-search", "chief-inspect",
    )),
    "cloud": (0x10, "cmux Cloud session, host replica, conversations and inbox.", ("cloud-*",)),
    "assets": (0x11, "Content-addressed icon assets.", ("put-blob", "get-blob")),
}

EVENT_FAMILIES: dict[str, tuple[int, str, tuple[str, ...]]] = {
    "terminal-stream-events": (0xC0, "Content of an attach stream: output, render state, frames and sizes.", (
        "output", "render-delta", "render-state", "frame", "browser-state", "vt-state", "resized",
        "colors-changed", "detached", "overflow", "scroll-changed", "size-state",
    )),
    "mux-events": (0xC1, "The mux tree: workspaces, screens, panes, tabs, surfaces and their state.", (
        "layout-changed", "tree-changed", "empty", "pane-*", "tab-*", "screen-*", "workspace-*",
        "title-changed", "surface-*", "bell", "notification", "status", "graphics-status",
        "frontend-projection-changed", "terminal-registry-changed", "terminal-reaped",
        "terminal-input-unclaimed", "window-title-requested", "program-status-changed",
        "url-open", "terminal-clipboard-*",
    )),
    "daemon-events": (0xC2, "Clients, daemon lifetime, settings, pairing and machine state.", (
        "client-*", "daemon-shutdown", "config-reload-requested", "keybindings-changed",
        "settings-changed", "pairing-*", "machine-usage-changed", "activity-changed",
    )),
    "agent-events": (0xC3, "Agents and the agent inventory.", ("agent-*",)),
    "personal-events": (0xC4, "Personal profiles, bookmarks and history.", (
        "personal-changed", "bookmarks-changed", "history-changed",
    )),
    "conversation-events": (0xC5, "Local conversations, runs, drafts and Chief.", (
        "conversation-*", "participant-avatar-changed", "chief-changed",
    )),
    "cloud-events": (0xC6, "cmux Cloud session, conversations and inbox.", ("cloud-*",)),
}

# Priority (p05-ipc design 3.4) -----------------------------------------------
# Commands: the p05-ipc-011 table. input: the person's keys, pointer and
# scroll; every command that writes a surface's PTY input (send, send-key,
# paste-image) shares it, because the client keeps call order only inside one
# priority (Chrome sends all of a widget's input through one
# WidgetInputHandler, content/common/input/widget_input_handler.mojom).
# bulk: large reads (journal and history reads, attachment bytes, icon
# assets); a write stays control, so a later control command that names what
# it wrote cannot pass it. background: stats; else control.

COMMAND_PRIORITY: dict[str, tuple[str, ...]] = {
    "input": (
        "send", "send-key", "paste-image", "browser-key", "browser-key-press", "browser-mouse",
        "browser-mouse-guarded", "browser-wheel", "browser-wheel-guarded", "browser-insert-text",
        "resize-attached-view", "scroll-surface",
    ),
    "bulk": (
        "terminal-events", "terminal-history", "terminal-read-range", "read-scrollback",
        "list-terminal-commands", "get-frontend-browser-history", "conversation-history",
        "cloud-conversation-history", "conversation-attachment-read", "cloud-attachment-read",
        "get-blob",
    ),
    "background": ("server-stats", "machine-usage", "terminal-resources"),
}

# Events: what draws the person's terminal rides input (the key echo path,
# IPC-5); the subscribe copy of output is bulk; usage and inventory refreshes
# are background; else control.
EVENT_PRIORITY: dict[str, tuple[str, ...]] = {
    "input": ("output", "render-delta", "render-state", "frame"),
    "bulk": ("surface-output",),
    "background": ("machine-usage-changed", "activity-changed", "agent-inventory-changed"),
}

# Ordering --------------------------------------------------------------------
# Reads that observe nothing this connection's own earlier requests change, so
# they may pass the connection's control sequence. Each one is read_only and
# names no stream target (validate.py rejects anything else). A cloud command
# is never here: it needs the lease this connection set with cloud-session-set.
INDEPENDENT = ("server-stats", "machine-usage", "machine-listening-tcp")

# Durability --------------------------------------------------------------------
# read_only: changes no daemon state. memory: changes state the journal never
# records (input, streams, presence, leases, subscriptions). reply_after_journal:
# the reply reports the journal commit. Every other command is a journaled
# mutation that replies before its journal write (F10).
READ_ONLY = (
    "list-*", "get-*", "read-*", "ids", "identify", "ping", "export-layout", "vt-state",
    "resolve-terminal", "process-info", "terminal-ports", "terminal-resources",
    "terminal-history", "terminal-read-range", "terminal-events", "server-stats", "machine-*",
    "wait-for", "pane-neighbor", "remote-terminal-snapshot",
    "conversation-list", "conversation-snapshot", "conversation-history", "conversation-thread",
    "conversation-search", "conversation-link-resolve", "conversation-runs", "conversation-run",
    "conversation-attachment-read", "history-search", "home-inbox", "chief-inspect",
    "cloud-session-status", "cloud-host-replica-status", "cloud-inbox-list", "cloud-requests-list",
    "cloud-conversation-snapshot", "cloud-conversation-history",
    "cloud-conversation-thread", "cloud-conversation-runs", "cloud-conversation-run",
    "cloud-participant-avatar-get", "cloud-attachment-read", "feed-local-list",
    "agent-cli-intents-list", "agent-cli-update-job-resolve",
)
MEMORY = (
    "send", "send-key", "paste-image", "copy", "scroll-surface", "browser-key", "browser-key-press",
    "browser-mouse", "browser-mouse-guarded", "browser-wheel", "browser-wheel-guarded",
    "browser-insert-text", "browser-frame-presented", "resize-attached-view",
    "release-attached-view-size", "detach-attached-view", "reattach-view", "note-size-activity",
    "set-size-counts", "subscribe", "attach-surface", "url-open", "url-open-*",
    "terminal-clipboard-*", "conversation-typing", "cloud-conversation-typing",
    "cloud-*-subscribe", "cloud-*-unsubscribe", "conversation-live", "cloud-conversation-live",
    "mint-terminal-renderer", "mint-terminal-renderer-by-terminal", "set-cell-pixels",
    "set-client-info", "client-focus", "report-focus", "detach-client", "set-window-title",
    "clear-window-title", "reload-config", "shutdown-daemon", "ws-listen", "page-credential",
    "subscribe-activity",
    # Writes the lease's account, bumps its generation and reconnects sockets.
    "cloud-selfhost-info",
    # Binds the browser host's sockets and starts the host process.
    "browser-host-provider",
    # Admits a snapshot on the stream's gate (collapse and 500 ms throttle).
    "snapshot-request",
)
# The agent CLI update ledger and job reply after their SQLite commit: the app
# records an intent before it contacts an owner so a restarted app resumes the
# same update, and a job's receipt names a durable creation record
# (commands.md "Update intent ledger").
REPLY_AFTER_JOURNAL = (
    "journal-frontend-event", "agent-cli-intents-record", "agent-cli-intents-settle",
    "agent-cli-intents-attach", "agent-cli-update-job",
)

# Stream barrier (p05-ipc design 3.4) -------------------------------------------
# A command naming a surface, terminal or view runs in that surface's stream
# FIFO (stream_scoped) unless it is listed here with the reason passing the
# queued stream items is safe.
_CREATES = "terminal_id names the terminal this command creates, so no stream can be open on it yet."
_PROCESS = "Reads process state of the terminal host, which changes independently of queued stream items."
CROSSES_STREAM_OK: dict[str, str] = {
    "new-tab": _CREATES,
    "new-screen": _CREATES,
    "new-pane": _CREATES,
    "new-pane-right": _CREATES,
    "new-row": _CREATES,
    "split": _CREATES,
    "create-terminal": _CREATES,
    "new-remote-terminal-tab": "terminal_id names a terminal of another session, which no stream of this connection carries.",
    "attach-surface": "Opens a new stream that starts from its own snapshot; items queued on an older stream of the surface do not change it.",
    "subscribe": "Opens an event stream; surface only filters the events it carries.",
    "url-open-subscribe": "Opens a request stream; terminal_ids only filters the requests it carries.",
    "terminal-clipboard-subscribe": "Opens a request stream; terminal_ids only filters the requests it carries.",
    "process-info": _PROCESS,
    "terminal-ports": _PROCESS,
    "terminal-resources": _PROCESS,
    "list-agents": "surface only filters the agent list, which queued stream items do not change.",
    "feed-local-list": "terminal_id only filters the feed, which queued stream items do not change.",
}

# Spawning --------------------------------------------------------------------------
# Daemon commands that may start a terminal host (transports.md
# `spawns_terminal`): their reply can carry `starting:true` and the client gives
# them the spawn timeout. move-tab-to-split and move-tab-to-column start one
# only with `respawn`, but an attribute cannot depend on a field, so both are
# listed. agent-cli-update-job opens a workspace whose terminal runs the
# prepared update. Every Swift TerminalSpawningRequest command must be here.
SPAWNS_TERMINAL = (
    "new-tab", "create-terminal", "new-screen", "new-pane", "new-pane-right", "split", "new-row",
    "new-workspace", "run", "restart-tab", "create-surface-with-receipt", "apply-layout",
    "sidebar-plugin", "reopen-saved-screen-group", "reopen-saved-tab-group", "move-tab-to-split",
    "move-tab-to-column", "agent-cli-update-job",
)

COMMAND_KEY_ORDER = (
    "method_id", "priority", "ordering", "durability", "stream_scoped", "crosses_stream_ok",
    "spawns_terminal", "clients",
)
EVENT_KEY_ORDER = ("event_id", "priority")


def matches(name: str, patterns: Iterable[str]) -> bool:
    return any(fnmatch.fnmatchcase(name, pattern) for pattern in patterns)


def family_of(name: str, families: Mapping[str, tuple[int, str, tuple[str, ...]]]) -> str:
    found = [family for family, (_, _, patterns) in families.items() if matches(name, patterns)]
    if len(found) != 1:
        where = "no family" if not found else f"families {', '.join(found)}"
        raise AssignError(f"{name!r} matches {where}; give it exactly one family in assign-ipc-method-ids.py")
    return found[0]


def priority_of(name: str, table: Mapping[str, tuple[str, ...]]) -> str:
    for priority, names in table.items():
        if matches(name, names):
            return priority
    return "control"


def durability_of(name: str) -> str:
    if matches(name, REPLY_AFTER_JOURNAL):
        return "reply_after_journal"
    if matches(name, MEMORY):
        return "memory"
    if matches(name, READ_ONLY):
        return "read_only"
    return "reply_before_journal"


# Sources outside the schema -------------------------------------------------------


def census_names(queue: str) -> set[str]:
    """Wire names of an ipc-census queue (p05-ipc-001)."""

    result = subprocess.run(
        [sys.executable, str(CENSUS), "--queue", queue],
        cwd=ROOT, capture_output=True, text=True, check=False,
    )
    if result.returncode != 0:
        raise AssignError(f"ipc-census.py --queue {queue} failed: {result.stderr.strip()}")
    return {hit["key"] for hit in json.loads(result.stdout)}


def _match_brace(text: str, open_: int) -> int:
    depth = 0
    for index in range(open_, len(text)):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return index
    return len(text)


_SPAWNING = re.compile(r"\b(?:struct|extension)\s+(\w+)\s*:[^{]*\bTerminalSpawningRequest\b")
_STRUCT = re.compile(r"\bstruct\s+(\w+)\b[^{]*\{")
_COMMAND = re.compile(r'static\s+(?:let|var)\s+command(?:\s*:\s*String)?\s*=\s*"([^"]+)"')


def swift_spawning_commands() -> set[str]:
    """Wire names of the Swift request types that conform to TerminalSpawningRequest."""

    listed = subprocess.run(
        ["git", "ls-files", "-z", "--", f"{SWIFT_SOURCES}/*.swift"],
        cwd=ROOT, capture_output=True, check=True,
    ).stdout.decode().split("\0")
    texts = [(ROOT / path).read_text() for path in listed if path and not path.endswith(".generated.swift")]
    spawning = {found.group(1) for text in texts for found in _SPAWNING.finditer(text)}
    commands: set[str] = set()
    for text in texts:
        for found in _STRUCT.finditer(text):
            if found.group(1) not in spawning:
                continue
            body = text[found.end() - 1:_match_brace(text, found.end() - 1)]
            command = _COMMAND.search(body)
            if command:
                commands.add(command.group(1))
    if not commands:
        raise AssignError(f"found no TerminalSpawningRequest commands under {SWIFT_SOURCES}")
    return commands


# Assignment ------------------------------------------------------------------------


@dataclass
class Sources:
    """The name sets read outside the schema, loaded only when a command needs them."""

    macos: Callable[[], set[str]] = lambda: census_names("Q1")
    cli: Callable[[], set[str]] = lambda: census_names("Q14")
    swift_spawning: Callable[[], set[str]] = swift_spawning_commands


class Assigner:
    def __init__(self, document: dict[str, Any], sources: Sources | None = None):
        self.document = document
        self.changes: list[str] = []
        self.sources = sources or Sources()
        self._clients: tuple[set[str], set[str]] | None = None

    def clients_of(self, name: str, current: Any) -> list[str]:
        """The census clients of a command, plus `ios` when the schema already lists it."""

        if self._clients is None:
            self._clients = (self.sources.macos(), self.sources.cli())
        macos, cli = self._clients
        ios = isinstance(current, list) and "ios" in current
        members = (("macos", name in macos), ("ios", ios), ("cli", name in cli), ("sdk", True))
        return [client for client, member in members if member]

    def check_spawning(self) -> None:
        """SPAWNS_TERMINAL holds every command the Swift client gives the spawn timeout."""

        missing = sorted(self.sources.swift_spawning() - set(SPAWNS_TERMINAL))
        if missing:
            raise AssignError(
                f"SPAWNS_TERMINAL lacks {', '.join(missing)}, whose Swift request conforms to "
                "TerminalSpawningRequest; add it once its daemon handler is seen to start a terminal host"
            )

    def families(self) -> dict[str, Any]:
        """Declare every scripted family, checking the ones already declared."""

        declared = self.document.get("families", {})
        wanted = {**FAMILIES, **EVENT_FAMILIES}
        for name, entry in declared.items():
            if name in wanted and entry.get("id") != wanted[name][0]:
                raise AssignError(
                    f"family {name!r} has id {entry.get('id')} in the schema but {wanted[name][0]} here; "
                    "family ids are never renumbered"
                )
        ids = [family_id for family_id, _, _ in wanted.values()]
        if len(set(ids)) != len(ids):
            raise AssignError("two scripted families share an id")
        table = {name: dict(entry) for name, entry in declared.items()}
        for name, (family_id, description, _) in sorted(wanted.items(), key=lambda item: item[1][0]):
            if name not in table:
                table[name] = {"id": family_id, "description": description}
                self.changes.append(f"families.{name}: id 0x{family_id:02X}")
        if "families" not in self.document:
            self.document = insert_after(self.document, "profiles", "families", table)
        else:
            self.document["families"] = table
        return table

    def wire_ids(self, section: str, key: str, families_table: Mapping[str, Any],
                 scripted: Mapping[str, tuple[int, str, tuple[str, ...]]]) -> None:
        """Give each entry without an id its family's next ordinal, then advance next_ordinal.

        next_ordinal never decreases and stays above every id in the schema, so
        an ordinal is given once: removing a family's last command does not
        free its id for the next one.
        """

        entries = self.document[section]
        kind = "command" if section == "commands" else "event"
        by_id = {entry["id"]: name for name, entry in families_table.items()
                 if family_kind(entry["id"]) == kind}
        next_ordinal = {family_id: families_table[name].get("next_ordinal", 0)
                        for family_id, name in by_id.items()}
        for entry in entries.values():
            if isinstance(entry.get(key), int):
                family, ordinal = entry[key] >> 8, entry[key] & 0xFF
                next_ordinal[family] = max(next_ordinal.get(family, 0), ordinal + 1)
        for name, entry in entries.items():  # file order
            if key in entry:
                continue
            family = families_table[family_of(name, scripted)]["id"]
            ordinal = next_ordinal.get(family, 0)
            if ordinal > 0xFF:
                raise AssignError(f"family 0x{family:02X} is full; add a new family for {name!r}")
            next_ordinal[family] = ordinal + 1
            entry[key] = family << 8 | ordinal
            self.changes.append(f"{section}.{name}.{key}: 0x{entry[key]:04X}")
        for family_id, name in by_id.items():
            family = families_table[name]
            if family.get("next_ordinal") != next_ordinal[family_id]:
                family["next_ordinal"] = next_ordinal[family_id]
                self.changes.append(f"families.{name}.next_ordinal: {next_ordinal[family_id]}")

    def set_missing(self, section: str, name: str, entry: dict[str, Any], key: str, value: Any) -> None:
        if key not in entry:
            entry[key] = value
            self.changes.append(f"{section}.{name}.{key}: {json.dumps(value)}")

    def command(self, name: str, entry: dict[str, Any], targets: set[str]) -> None:
        self.set_missing("commands", name, entry, "priority", priority_of(name, COMMAND_PRIORITY))
        if name in INDEPENDENT:
            self.set_missing("commands", name, entry, "ordering", "independent")
        self.set_missing("commands", name, entry, "durability", durability_of(name))
        if targets and "stream_scoped" not in entry and "crosses_stream_ok" not in entry:
            if name in CROSSES_STREAM_OK:
                self.set_missing("commands", name, entry, "crosses_stream_ok", CROSSES_STREAM_OK[name])
            else:
                self.set_missing("commands", name, entry, "stream_scoped", True)
        self.follow("commands", name, entry, "spawns_terminal", True if name in SPAWNS_TERMINAL else None)
        self.follow("commands", name, entry, "clients", self.clients_of(name, entry.get("clients")))

    def follow(self, section: str, name: str, entry: dict[str, Any], key: str, value: Any) -> None:
        """Set an attribute that follows a source outside the schema; None removes it."""

        if entry.get(key) == value:
            return
        if value is None:
            del entry[key]
            self.changes.append(f"{section}.{name}.{key}: removed")
        else:
            entry[key] = value
            self.changes.append(f"{section}.{name}.{key}: {json.dumps(value)}")

    def run(self) -> dict[str, Any]:
        self.check_tables()
        self.check_spawning()
        table = self.families()
        self.wire_ids("commands", "method_id", table, FAMILIES)
        self.wire_ids("events", "event_id", table, EVENT_FAMILIES)
        resolver = IpcMetaValidator(lambda path, message: None, self.document.get("types"))
        for name, entry in self.document["commands"].items():
            targets = STREAM_TARGET_FIELDS & set(resolver._object_fields(entry.get("request")))
            self.command(name, entry, targets)
            self.document["commands"][name] = ordered(entry, COMMAND_KEY_ORDER)
        for name, entry in self.document["events"].items():
            self.set_missing("events", name, entry, "priority", priority_of(name, EVENT_PRIORITY))
            self.document["events"][name] = ordered(entry, EVENT_KEY_ORDER)
        return self.document

    def check_tables(self) -> None:
        """Every table entry names a schema command or event, so a rename cannot leave a stale rule."""

        commands, events = set(self.document["commands"]), set(self.document["events"])
        named = [
            ("COMMAND_PRIORITY", [n for names in COMMAND_PRIORITY.values() for n in names], commands),
            ("EVENT_PRIORITY", [n for names in EVENT_PRIORITY.values() for n in names], events),
            ("INDEPENDENT", INDEPENDENT, commands),
            ("READ_ONLY", READ_ONLY, commands),
            ("MEMORY", MEMORY, commands),
            ("REPLY_AFTER_JOURNAL", REPLY_AFTER_JOURNAL, commands),
            ("CROSSES_STREAM_OK", list(CROSSES_STREAM_OK), commands),
            ("SPAWNS_TERMINAL", SPAWNS_TERMINAL, commands),
        ]
        for family, (family_id, _, patterns) in FAMILIES.items():
            named.append((f"FAMILIES[{family}]", patterns, commands))
            if family_kind(family_id) != "command":
                raise AssignError(f"family {family!r} id 0x{family_id:02X} is not a command family id")
        for family, (family_id, _, patterns) in EVENT_FAMILIES.items():
            named.append((f"EVENT_FAMILIES[{family}]", patterns, events))
            if family_kind(family_id) != "event":
                raise AssignError(f"family {family!r} id 0x{family_id:02X} is not an event family id")
        for table, patterns, names in named:
            for pattern in patterns:
                if not any(fnmatch.fnmatchcase(name, pattern) for name in names):
                    raise AssignError(f"{table}: {pattern!r} matches no schema name")
        for name in INDEPENDENT:
            if durability_of(name) != "read_only":
                raise AssignError(f"INDEPENDENT: {name!r} is not read_only")
        for name in SPAWNS_TERMINAL:
            if durability_of(name) == "read_only":
                raise AssignError(f"SPAWNS_TERMINAL: {name!r} is read_only")
        for name in COMMAND_PRIORITY["bulk"]:
            if durability_of(name) != "read_only":
                raise AssignError(f"COMMAND_PRIORITY bulk: {name!r} is a write; writes stay control")


def ordered(entry: dict[str, Any], keys: tuple[str, ...]) -> dict[str, Any]:
    """The entry with the scripted attributes after its other members, in a fixed order."""

    rest = {key: value for key, value in entry.items() if key not in keys}
    return {**rest, **{key: entry[key] for key in keys if key in entry}}


def insert_after(document: dict[str, Any], anchor: str, key: str, value: Any) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for name, item in document.items():
        result[name] = item
        if name == anchor:
            result[key] = value
    if key not in result:
        result[key] = value
    return result


def render(document: Mapping[str, Any]) -> str:
    return json.dumps(document, indent=1, ensure_ascii=False) + "\n"


def missing_attributes(document: Mapping[str, Any]) -> list[str]:
    """Queue Q6: commands without method_id or priority, events without event_id or priority."""

    missing = []
    for name, command in document.get("commands", {}).items():
        lacking = [key for key in ("method_id", "priority") if key not in command]
        if lacking:
            missing.append(f"command {name}: {', '.join(lacking)}")
    for name, event in document.get("events", {}).items():
        lacking = [key for key in ("event_id", "priority") if key not in event]
        if lacking:
            missing.append(f"event {name}: {', '.join(lacking)}")
    return missing


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--check", action="store_true", help="exit 1 if a run would change the schema")
    parser.add_argument("--schema", type=Path, default=SCHEMA)
    args = parser.parse_args(argv)

    original = args.schema.read_text()
    try:
        assigner = Assigner(json.loads(original))
        document = assigner.run()
        validate_document(document)
    except (AssignError, ValidationError) as error:
        print(f"assign-ipc-method-ids: {error}", file=sys.stderr)
        return 2
    gaps = missing_attributes(document)
    if gaps:
        print("assign-ipc-method-ids: Q6 is not empty:\n  " + "\n  ".join(gaps), file=sys.stderr)
        return 2
    rendered = render(document)
    if rendered == original:
        print(f"assign-ipc-method-ids: {args.schema.name} is current "
              f"({len(document['commands'])} commands, {len(document['events'])} events)")
        return 0
    if args.check:
        print(f"assign-ipc-method-ids: a run would change {args.schema.name} "
              f"({len(assigner.changes)} attribute(s) to add); run cmux-tui/scripts/assign-ipc-method-ids.py",
              file=sys.stderr)
        for change in assigner.changes[:40]:
            print(f"  {change}", file=sys.stderr)
        if len(assigner.changes) > 40:
            print(f"  ... {len(assigner.changes) - 40} more", file=sys.stderr)
        return 1
    args.schema.write_text(rendered)
    print(f"assign-ipc-method-ids: wrote {len(assigner.changes)} attribute(s) to {args.schema.name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
