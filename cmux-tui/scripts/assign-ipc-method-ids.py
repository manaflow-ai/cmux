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
  clients      sdk for every command; macos for the request types' `static let command`
               names, the `static let commandName: DaemonCommandName` names, the
               MACOS_CALL_SITES names and the raw `"cmd": "<name>"`
               lines the Swift app writes, cli for the CLI's `"cmd": "<name>"` lines and
               CLI_CALL_HELPER_SENDS, ios for the cases of the
               iOS client's command table (IOS_COMMAND_TABLE)

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
SWIFT_SOURCES = "Packages/macOS/CmuxNext/Sources"
# The iOS cmux-tui client names every command it sends in this enum.
IOS_COMMAND_TABLE = "Packages/iOS/CmuxMobileSSH/Sources/CmuxMobileSSH/CmuxTUI/CmuxTUICommand.swift"

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
        "debug-daemon-locks", "server-threads", "server-blocking",
        "subscribe-activity", "ws-listen", "page-credential", "pairing-response",
        "set-default-colors", "set-window-title", "clear-window-title", "trace-*",
        "memory-report",
    )),
    "clients": (0x02, "Connected clients and their focus.", (
        "set-client-info", "list-clients", "detach-client", "client-focus", "report-focus",
        "client-hello", "bridge-hello",
    )),
    "terminal-io": (0x03, "Terminal input, output streams, screen reads and terminal requests to the frontend.", (
        "send", "send-key", "paste-image", "read-screen", "read-scrollback", "wait-for", "copy",
        "clear-history", "vt-state", "scroll-surface", "snapshot-request", "terminal-history",
        "terminal-read-range", "terminal-events", "attach-surface", "cancel-stream",
        "set-stream-priority", "subscribe",
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
    "agents": (0x0E, "Agents in terminals, the local feed, agent CLI updates and the agent CLI inventory.", (
        "list-agents", "report-agent", "feed-local-*", "agent-cli-intents-*", "agent-cli-update-job*",
        "agent-inventory", "agent-inventory-*",
    )),
    "conversations": (0x0F, "Local conversations, runs, attachments, inbox and search.", (
        "conversation-*", "home-inbox", "history-search", "chief-inspect",
    )),
    "cloud": (0x10, "cmux Cloud session, host replica, conversations and inbox.", ("cloud-*",)),
    "assets": (0x11, "Content-addressed icon assets.", ("put-blob", "get-blob")),
    "apps": (0x12, "The app supervisor (apps-v1, server/apps.rs): installs, mounts, runs, logs and app op providers.", (
        "apps-*", "cancel-request",
    )),
    "agent-sessions": (0x13, "Agent chat tabs attached to this machine's acpmux sessions.", (
        "agent-session-*",
    )),
    "loopback": (0x14, "TCP streams to the daemon machine's loopback services (loopback-forward-v1).", (
        "loopback-*",
    )),
    "agent-machine": (0x15, "This machine's acpmux for the app: chat moves, Cloud access requests and agent CLI updates.", (
        "agent-transfer-*", "access-request", "access-request-*", "agent-update-*",
    )),
    "files": (0x16, "File ops on a cmux Cloud host's roots (fs-v1).", ("fs.*",)),
    "scripts": (0x17, "Script runs and REPL sessions in the daemon's script host.", ("script-*",)),
}

EVENT_FAMILIES: dict[str, tuple[int, str, tuple[str, ...]]] = {
    "terminal-stream-events": (0xC0, "Content of an attach stream: output, render state, frames and sizes.", (
        "output", "render-delta", "render-state", "frame", "browser-state", "vt-state", "resized",
        "colors-changed", "detached", "overflow", "scroll-changed", "size-state", "stream-end",
        "input-failed",
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
        "server-diagnostic-site",
    )),
    "agent-events": (0xC3, "Agents and the agent inventory.", ("agent-*",)),
    "personal-events": (0xC4, "Personal profiles, bookmarks and history.", (
        "personal-changed", "bookmarks-changed", "history-changed",
    )),
    "conversation-events": (0xC5, "Local conversations, runs, drafts and Chief.", (
        "conversation-*", "participant-avatar-changed", "chief-changed",
    )),
    "cloud-events": (0xC6, "cmux Cloud session, conversations and inbox.", ("cloud-*",)),
    "loopback-events": (0xC7, "Data, credit and end of loopback-forward-v1 streams.", ("loopback-*",)),
    "script-events": (0xC8, "Console output of script runs and REPL cells.", ("script-*",)),
}

# Priority (p05-ipc design 3.4) -----------------------------------------------
# Commands: the p05-ipc-011 table. input: the person's keys, pointer and
# scroll; every command that writes a surface's PTY input (send, send-key,
# paste-image) shares it, because the client keeps call order only inside one
# priority (Chrome sends all of a widget's input through one
# WidgetInputHandler, content/common/input/widget_input_handler.mojom).
# bulk: large reads (journal and history reads, attachment bytes, icon
# assets); a write stays control, so a later control command that names what
# it wrote cannot pass it, unless BULK_STREAM_WRITES names it. background:
# stats and the agent inventory registry refresh, which waits on the network
# for seconds; else control. An agent chat's prompt, cancel and permission
# answer are the person's input to the attached session (input
# for attach data, control otherwise).

COMMAND_PRIORITY: dict[str, tuple[str, ...]] = {
    "input": (
        "send", "send-key", "paste-image", "browser-key", "browser-key-press", "browser-mouse",
        "browser-mouse-guarded", "browser-wheel", "browser-wheel-guarded", "browser-insert-text",
        "resize-attached-view", "scroll-surface",
        # Focus and visibility of an attach stream: a tab switch is the person's.
        "set-stream-priority",
        "agent-session-prompt", "agent-session-cancel", "agent-session-permission",
    ),
    "bulk": (
        "terminal-events", "terminal-history", "terminal-read-range", "read-scrollback",
        "list-terminal-commands", "get-frontend-browser-history", "conversation-history",
        "cloud-conversation-history", "conversation-attachment-read", "cloud-attachment-read",
        "get-blob", "loopback-data", "loopback-shutdown",
        # File and bundle reads: up to 16 MiB per fs.read, 4 MiB per
        # agent-transfer-read page. fs.list stays control: it keeps a listing
        # snapshot, so it is not read_only. fs.stat stays control: its answer
        # is one fixed-size entry, nothing a control reply waits behind. Their
        # writes stay control by the rule above: fs.write (12 MiB) is followed
        # by an fs.rename of its part, and agent-transfer-write (4 MiB pages) by
        # the agent-transfer-finish that lands them; a bulk write would let
        # that control command pass the bytes it names.
        "fs.read", "agent-transfer-read",
    ),
    "background": (
        "server-stats", "debug-daemon-locks", "server-threads", "server-blocking", "machine-usage",
        "terminal-resources", "agent-inventory-refresh", "memory-report",
    ),
}

# Bulk writes: the bytes of a data stream and its half close, like a Mojo
# data pipe beside the message pipe (mojo/public/cpp/system/data_pipe.h). They
# share bulk, so the half close follows the queued bytes; the open that names
# the stream is control and goes first. The abort, loopback-close, is control,
# like closing a data pipe handle: it may pass the stream's queued bytes, and
# it frees the slot a later open takes (RELEASES_SLOT).
_LOOPBACK_STREAM = (
    "Bytes or half close of a loopback stream: loopback-data and -shutdown share bulk, so the "
    "half close follows the bytes; loopback-open precedes them on control and neither frees "
    "the stream's slot."
)
BULK_STREAM_WRITES: dict[str, str] = {
    "loopback-data": _LOOPBACK_STREAM,
    "loopback-shutdown": _LOOPBACK_STREAM,
}

# Writes that free a per-connection slot, and the command of their family
# that takes one. Both stay control: on bulk, a later take could pass the
# write that frees its slot (a client at MAX_STREAMS_PER_CLIENT sends close(A)
# then open(B), server/loopback_forward.rs).
RELEASES_SLOT: dict[str, str] = {
    "loopback-close": "loopback-open",
}

# Events: what draws the person's terminal rides input (the key echo path,
# IPC-5); the subscribe copy of output is bulk; usage and inventory refreshes
# are background; loopback stream bytes and EOF are bulk (one ordered outbound
# stream per loopback stream, server/loopback_forward.rs). Their credit and
# loopback-closed are control: an error close is a stream terminal the daemon
# sends on the control FIFO (ForwardStream::fail, unknown_stream, the overflow
# text in bounded_outbound.rs), so it may pass the stream's queued bytes. Else
# control. script-log stays control: a cell's console lines must
# arrive before its control reply.
EVENT_PRIORITY: dict[str, tuple[str, ...]] = {
    "input": ("output", "render-delta", "render-state", "frame"),
    "bulk": ("surface-output", "loopback-data", "loopback-eof"),
    "background": (
        "machine-usage-changed", "activity-changed", "agent-inventory-changed", "server-diagnostic-site",
    ),
}

# Ordering --------------------------------------------------------------------
# Reads that observe nothing this connection's own earlier requests change, so
# they may pass the connection's control sequence. Each one is read_only and
# names no stream target (validate.py rejects anything else). A cloud command
# is never here: it needs the lease this connection set with cloud-session-set.
# fs.read and fs.stat are not here: they observe the files this connection's
# own fs.write, fs.mkdir, fs.rename and fs.delete change (sync_cli's push
# stats a folder its failed mkdir found, and reads back what it wrote).
INDEPENDENT = (
    "server-stats", "debug-daemon-locks", "server-threads", "server-blocking", "machine-usage",
    "machine-listening-tcp",
)

# Durability --------------------------------------------------------------------
# read_only: changes no daemon state. memory: changes state the journal never
# records (input, streams, presence, leases, subscriptions). reply_after_journal:
# the reply reports the journal commit. Every other command is a journaled
# mutation that replies before its journal write (F10).
READ_ONLY = (
    "list-*", "get-*", "read-*", "ids", "identify", "ping", "export-layout", "vt-state",
    "resolve-terminal", "process-info", "terminal-ports", "terminal-resources",
    "terminal-history", "terminal-read-range", "terminal-events", "server-stats",
    "debug-daemon-locks", "server-threads", "server-blocking", "machine-*",
    "wait-for", "pane-neighbor", "remote-terminal-snapshot",
    "conversation-list", "conversation-snapshot", "conversation-history", "conversation-thread",
    "conversation-search", "conversation-link-resolve", "conversation-runs", "conversation-run",
    "conversation-attachment-read", "history-search", "home-inbox", "chief-inspect",
    "cloud-session-status", "cloud-host-replica-status", "cloud-inbox-list", "cloud-requests-list",
    "cloud-conversation-snapshot", "cloud-conversation-history",
    "cloud-conversation-thread", "cloud-conversation-runs", "cloud-conversation-run",
    "cloud-participant-avatar-get", "cloud-attachment-read", "feed-local-list", "trace-status",
    "memory-report",
    "agent-cli-intents-list", "agent-cli-update-job-resolve",
    "agent-session-events", "agent-session-media",
    "loopback-status", "browser-runtime-status",
    "fs.stat", "fs.read", "agent-transfer-source", "access-request-list",
    # Pages a bundle file the begin recorded; it only refreshes the move's
    # idle time.
    "agent-transfer-read",
    # Asks this machine's acpmux; a plan never starts it.
    "agent-update-plan",
    # Ask this machine's acpmux owner; nothing in the daemon changes.
    "agent-inventory", "agent-inventory-refresh",
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
    "subscribe-activity", "agent-inventory-watch",
    # Start or stop a trace recording: process memory and ring files, never the journal.
    "trace-start", "trace-stop",
    # The app supervisor's connection state: every apps-* request registers
    # the connection for apps events; mounts, runs, follows and providers live
    # until the connection closes. Nothing here is journaled.
    "apps-list", "apps-terminal-links", "apps-logs", "apps-mount", "apps-unmount", "apps-dispatch",
    "apps-run", "apps-link-changed", "apps-provider-register", "apps-agent-inventory-changed",
    "apps-provider-result",
    # Cancels an in-flight apps-run or script cell of this connection only.
    "cancel-request",
    # Connection state that ends with the connection: its role and proof, its
    # bridge kind, its loopback streams, its browser hosts and its machine
    # catalog lease.
    "client-hello", "bridge-hello", "loopback-open", "loopback-data", "loopback-credit",
    "loopback-shutdown", "loopback-close", "browser-runtime-start", "browser-runtime-stop", "machine-catalog-publish",
    # Writes the lease's account, bumps its generation and reconnects sockets.
    "cloud-selfhost-info",
    # Binds the browser host's sockets and starts the host process.
    "browser-host-provider",
    # Admits a snapshot on the stream's gate (collapse and 500 ms throttle).
    "snapshot-request",
    # Ends one attach stream of this connection and removes its view.
    "cancel-stream",
    # The lane and sequence priority of one attach stream of this connection.
    "set-stream-priority",
    # Agent chat attachments and what they send to acpmux, which keeps the
    # session and the folder trust itself; children also records the chats
    # the tab may file. agent-session-start binds the tab, a journaled write.
    "agent-session-attach", "agent-session-observe", "agent-session-detach",
    "agent-session-prompt", "agent-session-cancel", "agent-session-permission",
    "agent-session-children", "agent-session-trust",
    # Keeps a listing snapshot per caller for its paging.
    "fs.list",
    # Kept in daemon memory or in acpmux, never in the journal: a receive's
    # pages and abort, a move's begin, commit and abort (acpmux keeps the
    # move), access requests (a status read takes a delivered secret), the
    # script host's cells and sessions, and the CLI updates acpmux runs.
    # receive and finish also write the askable-receive and landed-chat
    # records (agent_transfer/askable.rs, landed.rs), and begin forgets a
    # landed chat, but best effort: a failed save is only logged and the
    # reply still says ok, so the reply never reports a commit.
    "agent-transfer-receive", "agent-transfer-finish",
    "agent-transfer-write", "agent-transfer-receive-abort", "agent-transfer-begin",
    "agent-transfer-commit", "agent-transfer-abort",
    "access-request", "access-request-status", "access-request-answer",
    "script-*", "agent-update-apply",
)
# apps-set and the App Store mutations of apps-store write apps.json before
# they apply and reply (apps/supervisor.rs `set`). The agent CLI update ledger
# and job reply after their SQLite commit: the app records an intent before it
# contacts an owner so a restarted app resumes the same update, and a job's
# receipt names a durable creation record (commands.md "Update intent ledger").
REPLY_AFTER_JOURNAL = (
    "journal-frontend-event", "apps-set", "apps-store", "agent-cli-intents-record",
    "agent-cli-intents-settle", "agent-cli-intents-attach", "agent-cli-update-job",
    # fs.write and fs.rename answer after their change is fsynced (the file
    # system is their journal); fs.mkdir and fs.delete do not fsync, so they
    # keep the default.
    "fs.write", "fs.rename",
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

# CLI senders without a "cmd" line --------------------------------------------------
# Wire names the Rust CLI sends through a call helper that takes the name as
# an argument (`RemoteMachine::call`, `sync_cli::machine_call`, the move pump's
# `call` and `call_once`), not on a hand-built `"cmd": "..."` line, so
# cli_cmd_line_names does not see them. name -> the CLI file (under crates/cmux-tui/src) that
# sends it; the script refuses an entry whose file stops naming it.
CLI_SRC = ROOT / "cmux-tui/crates/cmux-tui/src"
_SYNC_REMOTE = "link/sync_cli/remote.rs"
_MOVE_PUMP = "link/agent_cli.rs"
_ACCESS_CLI = "link/access_cli/requests.rs"
CLI_CALL_HELPER_SENDS: dict[str, str] = {
    "fs.stat": _SYNC_REMOTE, "fs.list": _SYNC_REMOTE, "fs.read": _SYNC_REMOTE,
    "fs.write": _SYNC_REMOTE, "fs.mkdir": _SYNC_REMOTE, "fs.rename": _SYNC_REMOTE,
    "fs.delete": _SYNC_REMOTE,
    "agent-transfer-receive": _MOVE_PUMP, "agent-transfer-write": _MOVE_PUMP,
    "agent-transfer-finish": _MOVE_PUMP, "agent-transfer-receive-abort": _MOVE_PUMP,
    "agent-transfer-begin": _MOVE_PUMP, "agent-transfer-source": _MOVE_PUMP,
    "agent-transfer-read": _MOVE_PUMP, "agent-transfer-commit": _MOVE_PUMP,
    "agent-transfer-abort": _MOVE_PUMP,
    "access-request": _ACCESS_CLI, "access-request-status": _ACCESS_CLI,
    "access-request-list": _ACCESS_CLI, "access-request-answer": _ACCESS_CLI,
}

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


def grep_names(pattern: str, name: str, *pathspecs: str) -> set[str]:
    """Group 1 of `name` on each line that `git grep -E PATTERN -- PATHSPECS` prints."""

    result = subprocess.run(
        ["git", "grep", "--no-color", "-h", "-E", pattern, "--", *pathspecs],
        cwd=ROOT, capture_output=True, text=True, check=False,
    )
    if result.returncode not in (0, 1):
        raise AssignError(f"git grep {pattern!r} failed: {result.stderr.strip()}")
    return {found.group(1) for line in result.stdout.splitlines() if (found := re.search(name, line))}


def swift_request_type_names() -> set[str]:
    """Commands named by a Swift request type's `static let command(Name) = "..."`."""

    return grep_names(
        r'static (let|var) command(Name)?(: (String|DaemonCommandName))? = "',
        r'command(?:Name)?(?:: (?:String|DaemonCommandName))? = "([^"]*)"',
        SWIFT_SOURCES, ":!*.generated.swift",
    )


def cli_cmd_line_names() -> set[str]:
    """Commands on the Rust CLI's hand-built `"cmd": "<name>"` lines."""

    return grep_names('"cmd"', r'"cmd"\s*:\s*"([^"]+)"', "cmux-tui/crates/cmux-tui/src")


# Swift clients that send daemon commands by wire name (`call("name", ...)`),
# not through a request type with `static let command`, the only form
# swift_request_type_names sees. The file's literals with the prefix are macos names; a pushed event
# name among them names no command and changes nothing.
MACOS_CALL_SITES: dict[str, str] = {
    f"{SWIFT_SOURCES}/CmuxNextDaemon/AgentSession/AgentSessionAttachClient.swift": "agent-session-",
}


def swift_call_site_names() -> set[str]:
    """The wire names the MACOS_CALL_SITES Swift files spell."""

    names: set[str] = set()
    for relative, prefix in MACOS_CALL_SITES.items():
        try:
            text = (ROOT / relative).read_text(encoding="utf-8")
        except (OSError, UnicodeError) as error:
            raise AssignError(f"MACOS_CALL_SITES: cannot read {relative}: {error}") from error
        found = set(re.findall(rf'"({re.escape(prefix)}[a-z0-9-]+)"', text))
        if not found:
            raise AssignError(f"MACOS_CALL_SITES: {relative} spells no {prefix}* name")
        names |= found
    return names


def cli_call_helper_names() -> set[str]:
    """CLI_CALL_HELPER_SENDS, each checked against the file that sends it."""

    for name, relative in CLI_CALL_HELPER_SENDS.items():
        try:
            text = (CLI_SRC / relative).read_text(encoding="utf-8")
        except (OSError, UnicodeError) as error:
            raise AssignError(f"CLI_CALL_HELPER_SENDS: cannot read {relative} for {name!r}: {error}") from error
        if f'"{name}"' not in text:
            raise AssignError(f"CLI_CALL_HELPER_SENDS: {relative} no longer names {name!r}; remove or move the entry")
    return set(CLI_CALL_HELPER_SENDS)


_CLIENT_USE = re.compile(r"\bcmux_ipc::client::(?:\{([^}]*)\}|(\w+))")


def _pascal(name: str) -> str:
    """The Rust type stem cmux-ipc's build.rs gives a command (build-support/client_requests.rs)."""

    return "".join(part[:1].upper() + part[1:] for part in re.split(r"[-_.]", name))


def cli_typed_request_names(commands: Iterable[str]) -> set[str]:
    """Wire names of the generated `<Command>Request` types (cmux_ipc::client) the
    Rust CLI imports. A command the CLI sends through its typed request has no
    `"cmd"` literal for cli_cmd_line_names to see, so without this the migrated commands
    would lose `cli`, and with it the very types the CLI imports."""

    by_type = {f"{_pascal(name)}Request": name for name in commands}
    listed = subprocess.run(
        ["git", "ls-files", "-z", "--", "*.rs"],
        cwd=CLI_SRC, capture_output=True, check=True,
    ).stdout.decode().split("\0")
    names: set[str] = set()
    for relative in filter(None, listed):
        try:
            text = (CLI_SRC / relative).read_text(encoding="utf-8")
        except (OSError, UnicodeError) as error:
            raise AssignError(f"cannot read {relative}: {error}") from error
        for group, single in _CLIENT_USE.findall(text):
            for ident in re.findall(r"\w+", group or single):
                if ident in by_type:
                    names.add(by_type[ident])
    return names


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


_RAW_LINE = re.compile(r'"cmd":\s*"([a-z][a-z0-9-]*)"')


def swift_line_commands() -> set[str]:
    """Wire names the Swift app writes as raw `"cmd": "<name>"` lines instead
    of a request type (LoopbackForwardLine), which swift_request_type_names does not see."""

    listed = subprocess.run(
        ["git", "ls-files", "-z", "--", f"{SWIFT_SOURCES}/*.swift"],
        cwd=ROOT, capture_output=True, check=True,
    ).stdout.decode().split("\0")
    return {
        found.group(1)
        for path in listed
        if path and not path.endswith(".generated.swift")
        for found in _RAW_LINE.finditer((ROOT / path).read_text())
    }


_IOS_CASE = re.compile(r'^\s*case\s+(\w+)(?:\s*=\s*"([^"]*)")?\s*$', re.MULTILINE)


def ios_command_names() -> set[str]:
    """The wire names of IOS_COMMAND_TABLE's cases: a case's raw value, else its name.

    The table holds one case per line, so a line that starts with `case` and is not one
    simple case (a list, an associated value) is refused rather than misread.
    """

    try:
        text = (ROOT / IOS_COMMAND_TABLE).read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        raise AssignError(f"IOS_COMMAND_TABLE: cannot read {IOS_COMMAND_TABLE}: {error}") from error
    lines = [line for line in text.splitlines() if line.strip().startswith("case ")]
    found = [_IOS_CASE.match(line) for line in lines]
    if not found or not all(found):
        bad = [line.strip() for line, match in zip(lines, found) if not match]
        raise AssignError(f"IOS_COMMAND_TABLE: {IOS_COMMAND_TABLE} must list one simple case per line: {bad}")
    return {match.group(2) or match.group(1) for match in found if match}


_TYPED_COMMAND = re.compile(r'static\s+(?:let|var)\s+commandName(?:\s*:\s*DaemonCommandName)?\s*=\s*"([a-z][a-z0-9-]*)"')


def swift_typed_commands() -> set[str]:
    """Wire names of the Swift request types that declare
    `static let commandName: DaemonCommandName = "<name>"`. Census Q1 counts only
    the older hand-written `static let command = "<name>"` form it queues for
    migration, so the migrated types are read here."""

    listed = subprocess.run(
        ["git", "ls-files", "-z", "--", f"{SWIFT_SOURCES}/*.swift"],
        cwd=ROOT, capture_output=True, check=True,
    ).stdout.decode().split("\0")
    names: set[str] = set()
    for relative in filter(None, listed):
        if relative.endswith(".generated.swift"):
            continue
        try:
            text = (ROOT / relative).read_text(encoding="utf-8")
        except (OSError, UnicodeError) as error:
            raise AssignError(f"cannot read {relative}: {error}") from error
        names.update(_TYPED_COMMAND.findall(text))
    return names


_SPAWNING = re.compile(r"\b(?:struct|extension)\s+(\w+)\s*:[^{]*\bTerminalSpawningRequest\b")
_STRUCT = re.compile(r"\bstruct\s+(\w+)\b[^{]*\{")
# `static let commandName: DaemonCommandName = "..."`, or the older `static let command = "..."`.
_COMMAND = re.compile(r'static\s+(?:let|var)\s+command(?:Name)?(?:\s*:\s*\w+)?\s*=\s*"([^"]+)"')


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


def _schema_commands() -> list[str]:
    """The command names of the committed schema, to resolve the CLI's request types."""

    try:
        return list(json.loads(SCHEMA.read_text(encoding="utf-8"))["commands"])
    except (OSError, UnicodeError, ValueError, KeyError) as error:
        raise AssignError(f"cannot read the commands of {SCHEMA}: {error}") from error


@dataclass
class Sources:
    """The name sets read outside the schema, loaded only when a command needs them."""

    macos: Callable[[], set[str]] = (
        lambda: swift_request_type_names() | swift_typed_commands() | swift_call_site_names() | swift_line_commands()
    )
    cli: Callable[[], set[str]] = lambda: (
        cli_cmd_line_names() | cli_call_helper_names() | cli_typed_request_names(_schema_commands())
    )
    ios: Callable[[], set[str]] = ios_command_names
    swift_spawning: Callable[[], set[str]] = swift_spawning_commands


class Assigner:
    def __init__(self, document: dict[str, Any], sources: Sources | None = None):
        self.document = document
        self.changes: list[str] = []
        self.sources = sources or Sources()
        self._clients: tuple[set[str], set[str], set[str]] | None = None

    def clients_of(self, name: str) -> list[str]:
        """The clients whose sources send the command, and `sdk` for every command."""

        macos, ios, cli = self.client_sources()
        members = (("macos", name in macos), ("ios", name in ios), ("cli", name in cli), ("sdk", True))
        return [client for client, member in members if member]

    def client_sources(self) -> tuple[set[str], set[str], set[str]]:
        if self._clients is None:
            self._clients = (self.sources.macos(), self.sources.ios(), self.sources.cli())
        return self._clients

    def check_ios(self) -> None:
        """Every name in the iOS client's command table is a schema command."""

        unknown = sorted(self.client_sources()[1] - set(self.document["commands"]))
        if unknown:
            raise AssignError(f"{IOS_COMMAND_TABLE} names {', '.join(unknown)}, which sdk-schema.json does not declare")

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
        self.follow("commands", name, entry, "clients", self.clients_of(name))

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
        self.check_ios()
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
            ("CLI_CALL_HELPER_SENDS", list(CLI_CALL_HELPER_SENDS), commands),
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
            if durability_of(name) != "read_only" and name not in BULK_STREAM_WRITES:
                raise AssignError(f"COMMAND_PRIORITY bulk: {name!r} is a write; writes stay control")
        for name in BULK_STREAM_WRITES:
            if name not in COMMAND_PRIORITY["bulk"]:
                raise AssignError(f"BULK_STREAM_WRITES: {name!r} is not bulk")
        for name, taker in RELEASES_SLOT.items():
            for command in (name, taker):
                if command not in commands:
                    raise AssignError(f"RELEASES_SLOT: {command!r} is not a schema command")
                entry = self.document["commands"][command]
                if {priority_of(command, COMMAND_PRIORITY), entry.get("priority", "control")} != {
                    "control"
                }:
                    raise AssignError(
                        f"RELEASES_SLOT: {name!r} frees the slot {taker!r} takes; both stay control"
                    )


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
