#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import shutil
import shlex
import subprocess
import sys
from collections import Counter
from pathlib import Path
from typing import Any


VALID_AGENTS = {"claude", "codex", "opencode", "pi"}
VALID_STATUSES = {"awaiting", "working", "completed"}


def fail(message: str) -> None:
    raise SystemExit(f"FAIL: {message}")


def load_json(path: Path) -> dict[str, Any]:
    try:
        with path.open("r", encoding="utf-8") as handle:
            value = json.load(handle)
    except FileNotFoundError:
        fail(f"missing state file: {path}")
    except json.JSONDecodeError as error:
        fail(f"invalid JSON in {path}: {error}")
    if not isinstance(value, dict):
        fail("state root must be an object")
    return value


def require_string(obj: dict[str, Any], key: str, context: str) -> str:
    value = obj.get(key)
    if not isinstance(value, str) or not value.strip():
        fail(f"{context}.{key} must be a non-empty string")
    return value


def require_command(obj: dict[str, Any], key: str, context: str) -> None:
    value = obj.get(key)
    if not isinstance(value, list) or not value:
        fail(f"{context}.{key} must be a non-empty command array")
    if not all(isinstance(part, str) and part for part in value):
        fail(f"{context}.{key} must contain only non-empty strings")


def validate_state(state: dict[str, Any]) -> tuple[Counter[str], Counter[str]]:
    if state.get("schemaVersion") != 1:
        fail("schemaVersion must be 1")
    require_string(state, "generatedAt", "state")

    source = state.get("source")
    if not isinstance(source, dict):
        fail("state.source must be an object")
    require_string(source, "kind", "state.source")

    adapters = state.get("adapters")
    if not isinstance(adapters, dict):
        fail("state.adapters must be an object")
    for agent in sorted(VALID_AGENTS):
        adapter = adapters.get(agent)
        if not isinstance(adapter, dict):
            fail(f"adapters.{agent} must be present")
        if adapter.get("id") != agent:
            fail(f"adapters.{agent}.id must equal {agent}")
        for key in ["displayName", "sessionStorePath"]:
            require_string(adapter, key, f"adapters.{agent}")
        for key in ["installCommand", "resumeCommandTemplate", "dispatchCommandTemplate"]:
            require_command(adapter, key, f"adapters.{agent}")

    sessions = state.get("sessions")
    if not isinstance(sessions, list):
        fail("state.sessions must be an array")

    session_ids: set[str] = set()
    status_counts: Counter[str] = Counter()
    agent_counts: Counter[str] = Counter()

    for index, raw in enumerate(sessions):
        if not isinstance(raw, dict):
            fail(f"sessions[{index}] must be an object")
        context = f"sessions[{index}]"
        session_id = require_string(raw, "id", context)
        if session_id in session_ids:
            fail(f"duplicate session id: {session_id}")
        session_ids.add(session_id)

        agent = require_string(raw, "agent", context)
        if agent not in VALID_AGENTS:
            fail(f"{context}.agent is unknown: {agent}")
        status = require_string(raw, "status", context)
        if status not in VALID_STATUSES:
            fail(f"{context}.status is unknown: {status}")

        require_string(raw, "agentSessionId", context)
        require_string(raw, "title", context)
        require_string(raw, "updatedAt", context)

        workspace = raw.get("workspace")
        if not isinstance(workspace, dict):
            fail(f"{context}.workspace must be an object")
        require_string(workspace, "id", f"{context}.workspace")
        require_string(workspace, "cwd", f"{context}.workspace")

        surface = raw.get("surface")
        if not isinstance(surface, dict):
            fail(f"{context}.surface must be an object")
        require_string(surface, "id", f"{context}.surface")
        require_string(surface, "kind", f"{context}.surface")

        activity = raw.get("activity")
        if not isinstance(activity, dict):
            fail(f"{context}.activity must be an object")
        require_string(activity, "phase", f"{context}.activity")
        require_string(activity, "confidence", f"{context}.activity")

        for action_key in ["resume", "dispatch"]:
            action = raw.get(action_key)
            if not isinstance(action, dict):
                fail(f"{context}.{action_key} must be an object")
            require_command(action, "command", f"{context}.{action_key}")
            require_string(action, "confidence", f"{context}.{action_key}")

        focus = raw.get("focus")
        if not isinstance(focus, dict):
            fail(f"{context}.focus must be an object")
        commands = focus.get("commands")
        if not isinstance(commands, list) or not commands:
            fail(f"{context}.focus.commands must be a non-empty array")
        for command_index, command in enumerate(commands):
            if not isinstance(command, list) or not command:
                fail(f"{context}.focus.commands[{command_index}] must be a command array")
            if not all(isinstance(part, str) and part for part in command):
                fail(f"{context}.focus.commands[{command_index}] must contain only non-empty strings")

        attention = raw.get("attention")
        if status == "awaiting" and not isinstance(attention, dict):
            fail(f"{context}.attention is required for awaiting sessions")
        if status != "awaiting" and attention is not None:
            fail(f"{context}.attention must be null unless status is awaiting")

        status_counts[status] += 1
        agent_counts[agent] += 1

    groups = state.get("groups")
    if not isinstance(groups, list):
        fail("state.groups must be an array")
    seen_groups: set[str] = set()
    grouped_ids: set[str] = set()
    for index, raw in enumerate(groups):
        if not isinstance(raw, dict):
            fail(f"groups[{index}] must be an object")
        group_id = require_string(raw, "id", f"groups[{index}]")
        if group_id not in VALID_STATUSES:
            fail(f"groups[{index}].id is unknown: {group_id}")
        seen_groups.add(group_id)
        ids = raw.get("sessionIds")
        if not isinstance(ids, list):
            fail(f"groups[{index}].sessionIds must be an array")
        for session_id in ids:
            if not isinstance(session_id, str) or not session_id:
                fail(f"groups[{index}].sessionIds contains a non-string id")
            if session_id not in session_ids:
                fail(f"groups[{index}] references unknown session id: {session_id}")
            session = next(item for item in sessions if item["id"] == session_id)
            if session["status"] != group_id:
                fail(f"{session_id} is in group {group_id} but has status {session['status']}")
            grouped_ids.add(session_id)

    missing_groups = VALID_STATUSES - seen_groups
    if missing_groups:
        fail(f"missing groups: {', '.join(sorted(missing_groups))}")

    ungrouped = session_ids - grouped_ids
    if ungrouped:
        fail(f"ungrouped sessions: {', '.join(sorted(ungrouped))}")

    return status_counts, agent_counts


def command_exists(command: list[str]) -> bool:
    if not command:
        return False
    first = command[0]
    if "/" in first:
        return Path(first).exists()
    return shutil.which(first) is not None


def env_candidates() -> list[tuple[str, list[str]]]:
    candidates: list[tuple[str, list[str]]] = []
    single = os.environ.get("CMUX_HOME_IMPL", "").strip()
    if single:
        candidates.append(("env:CMUX_HOME_IMPL", shlex.split(single)))
    many = os.environ.get("CMUX_HOME_IMPLS", "").strip()
    if many:
        for index, line in enumerate(many.splitlines(), start=1):
            line = line.strip()
            if line:
                candidates.append((f"env:CMUX_HOME_IMPLS[{index}]", shlex.split(line)))
    return candidates


def discovered_candidates(root: Path) -> list[tuple[str, list[str]]]:
    candidates: list[tuple[str, list[str]]] = []

    rust_debug = root / "rust" / "target" / "debug" / "cmux-home"
    rust_release = root / "rust" / "target" / "release" / "cmux-home"
    for label, binary in [("rust debug", rust_debug), ("rust release", rust_release)]:
        if binary.exists() and os.access(binary, os.X_OK):
            candidates.append((label, [str(binary)]))
    rust_manifest = root / "rust" / "Cargo.toml"
    if rust_manifest.exists() and shutil.which("cargo"):
        candidates.append(("rust cargo", ["cargo", "run", "--quiet", "--manifest-path", str(rust_manifest), "--"]))

    go_binary = root / "go" / "cmux-home"
    if go_binary.exists() and os.access(go_binary, os.X_OK):
        candidates.append(("go binary", [str(go_binary)]))
    go_main = root / "go" / "cmd" / "cmux-home"
    if go_main.exists() and shutil.which("go"):
        candidates.append(("go run", ["go", "-C", str(root / "go"), "run", "./cmd/cmux-home"]))

    ts_dist = root / "typescript" / "dist" / "cli.js"
    if ts_dist.exists() and shutil.which("node"):
        candidates.append(("typescript dist", ["node", str(ts_dist)]))
    for entry in ["cli.ts", "index.ts", "src/cli.ts", "src/index.ts"]:
        ts_entry = root / "typescript" / entry
        if ts_entry.exists() and shutil.which("bun"):
            candidates.append((f"typescript bun {entry}", ["bun", "run", str(ts_entry)]))
            break

    return candidates


def unsupported_flags(result: subprocess.CompletedProcess[str]) -> bool:
    text = f"{result.stdout}\n{result.stderr}".lower()
    markers = [
        "unknown argument",
        "unknown option",
        "unrecognized option",
        "flag provided but not defined",
        "unexpected argument",
    ]
    return any(marker in text for marker in markers)


def run_once(label: str, command: list[str], args: list[str]) -> subprocess.CompletedProcess[str]:
    full_command = command + args
    print(f"RUN {label}: {' '.join(shlex.quote(part) for part in full_command)}")
    result = subprocess.run(full_command, text=True, capture_output=True)
    if result.stdout.strip():
        print(result.stdout.rstrip())
    if result.stderr.strip():
        print(result.stderr.rstrip(), file=sys.stderr)
    return result


def run_candidate(label: str, command: list[str], state_path: Path) -> bool:
    if not command_exists(command):
        print(f"SKIP {label}: command not found: {command[0]}")
        return False

    attempts = [
        ["--data", str(state_path), "--once"],
        ["--state", str(state_path), "--summary", "--non-interactive"],
    ]

    result = run_once(label, command, attempts[0])
    if result.returncode != 0:
        if unsupported_flags(result):
            result = run_once(f"{label} alias", command, attempts[1])
        if result.returncode != 0:
            fail(f"{label} exited {result.returncode}")
    print(f"PASS {label}")
    return True


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description="Validate and smoke-test cmux home state.")
    parser.add_argument("--state", default=str(root / "examples" / "state.sample.json"))
    parser.add_argument("--require-implementation", action="store_true")
    parser.add_argument("--list", action="store_true", help="List discovered implementation commands and exit.")
    args = parser.parse_args()

    state_path = Path(args.state).expanduser().resolve()
    state = load_json(state_path)
    status_counts, agent_counts = validate_state(state)

    print(
        "PASS state: "
        + " ".join(f"{key}={status_counts.get(key, 0)}" for key in ["awaiting", "working", "completed"])
        + " sessions="
        + str(sum(status_counts.values()))
    )
    print("PASS agents: " + " ".join(f"{key}={agent_counts.get(key, 0)}" for key in sorted(VALID_AGENTS)))

    candidates = env_candidates() or discovered_candidates(root)
    if args.list:
        for label, command in candidates:
            print(f"{label}: {' '.join(shlex.quote(part) for part in command)}")
        return 0

    ran_any = False
    for label, command in candidates:
        ran_any = run_candidate(label, command, state_path) or ran_any

    if not ran_any:
        message = "no cmux home implementation found"
        if args.require_implementation:
            fail(message)
        print(f"SKIP implementations: {message}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
