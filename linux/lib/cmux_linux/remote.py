from __future__ import annotations

import hashlib
import hmac
import json
import shlex
import secrets
from collections.abc import Iterable, Mapping
from typing import Any

REMOTE_SOCKET_ADDR_PATH = "~/.cmux/socket_addr"
REMOTE_RELAY_DIR = "~/.cmux/relay"
RELAY_AUTH_FILE_MODE = "0600"
RELAY_HMAC_ALGORITHM = "HMAC-SHA256"
RELAY_AUTH_PROTOCOL = "cmux-relay-auth"
RELAY_AUTH_VERSION = 1
RELAY_ID_MAX_LENGTH = 128
RELAY_ID_ALLOWED_CHARS = frozenset(
    "abcdefghijklmnopqrstuvwxyz"
    "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    "0123456789"
    "._:-"
)
REMOTE_CMUX_BIN_PATH = "~/.cmux/bin/cmux"
REMOTE_DAEMON_CURRENT_PATH = "~/.cmux/bin/cmuxd-remote-current"
DEFAULT_SSH_OPTIONS = {
    "BatchMode": "yes",
    "ExitOnForwardFailure": "yes",
    "ServerAliveInterval": "15",
    "ServerAliveCountMax": "3",
    "StrictHostKeyChecking": "accept-new",
}


def validate_ssh_destination(destination: str) -> None:
    if not destination:
        raise ValueError("Missing SSH destination.")
    if destination.startswith("-") or any(character.isspace() for character in destination):
        raise ValueError("Invalid SSH destination.")
    forbidden = set(";|&`$<>")
    if any(character in forbidden for character in destination):
        raise ValueError("Invalid SSH destination.")


def validate_relay_token(relay_token: str) -> None:
    if len(relay_token) != 64 or any(char not in "0123456789abcdef" for char in relay_token):
        raise ValueError("relay_token must be 64 lowercase hex characters.")


def validate_relay_id(relay_id: str) -> None:
    if not relay_id:
        raise ValueError("relay_id is required.")
    if len(relay_id) > RELAY_ID_MAX_LENGTH:
        raise ValueError("relay_id is too long.")
    if any(character not in RELAY_ID_ALLOWED_CHARS for character in relay_id):
        raise ValueError("relay_id contains invalid characters.")


def relay_auth_file_payload(*, relay_id: str, relay_token: str) -> dict[str, Any]:
    validate_relay_token(relay_token)
    validate_relay_id(relay_id)
    return {
        "relay_id": relay_id,
        "relay_token": relay_token,
        "hmac_algorithm": RELAY_HMAC_ALGORITHM,
    }


def relay_auth_challenge(*, relay_id: str, nonce: str | None = None) -> dict[str, Any]:
    validate_relay_id(relay_id)
    return {
        "protocol": RELAY_AUTH_PROTOCOL,
        "version": RELAY_AUTH_VERSION,
        "relay_id": relay_id,
        "nonce": nonce or secrets.token_hex(16),
    }


def compute_relay_auth_mac(
    *,
    relay_id: str,
    relay_token: str,
    nonce: str,
    version: int = RELAY_AUTH_VERSION,
) -> str:
    validate_relay_token(relay_token)
    validate_relay_id(relay_id)
    token = bytes.fromhex(relay_token)
    message = f"relay_id={relay_id}\nnonce={nonce}\nversion={version}".encode("utf-8")
    return hmac.new(token, message, hashlib.sha256).hexdigest()


def verify_relay_auth_response(
    *,
    relay_id: str,
    relay_token: str,
    nonce: str,
    response: Mapping[str, Any],
    version: int = RELAY_AUTH_VERSION,
) -> bool:
    validate_relay_id(relay_id)
    if response.get("relay_id") != relay_id:
        return False
    received = response.get("mac")
    if not isinstance(received, str):
        return False
    expected = compute_relay_auth_mac(
        relay_id=relay_id,
        relay_token=relay_token,
        nonce=nonce,
        version=version,
    )
    return hmac.compare_digest(received.lower(), expected)


def build_relay_metadata(*, relay_port: int, relay_id: str, relay_token: str, daemon_path: str | None) -> dict[str, Any]:
    validate_relay_token(relay_token)
    validate_relay_id(relay_id)
    if relay_port < 1 or relay_port > 65_535:
        raise ValueError("relay_port must be 1-65535.")
    token_sha256 = hashlib.sha256(relay_token.encode("utf-8")).hexdigest()
    return {
        "relay_id": relay_id,
        "relay_port": relay_port,
        "socket_addr": f"127.0.0.1:{relay_port}",
        "remote_socket_addr_path": REMOTE_SOCKET_ADDR_PATH,
        "relay_auth_path": f"{REMOTE_RELAY_DIR}/{relay_port}.auth",
        "relay_daemon_path_path": f"{REMOTE_RELAY_DIR}/{relay_port}.daemon_path",
        "auth_file_mode": RELAY_AUTH_FILE_MODE,
        "token_sha256": token_sha256,
        "daemon_path": daemon_path,
        "hmac": {
            "algorithm": RELAY_HMAC_ALGORITHM,
            "challenge_response": True,
        },
        "reverse_forward": {
            "host": "127.0.0.1",
            "port": relay_port,
        },
    }


def build_remote_lifecycle_plan(
    *,
    destination: str,
    port: int | None,
    identity_file: str | None,
    ssh_options: list[str],
    local_proxy_port: int | None,
    relay: Mapping[str, Any] | None,
    daemon_path: str | None,
    auto_connect: bool,
) -> dict[str, Any]:
    validate_ssh_destination(destination)
    validated_options = validate_ssh_options(ssh_options)
    effective_options = effective_ssh_options(validated_options)
    probe_argv = build_ssh_argv(
        destination=destination,
        port=port,
        identity_file=identity_file,
        ssh_options=effective_options,
        remote_command=f"{sh_path(daemon_path or REMOTE_DAEMON_CURRENT_PATH)} serve --stdio",
    )
    reverse_forward = None
    if relay is not None and local_proxy_port is not None:
        relay_port = int(relay.get("relay_port") or 0)
        reverse_forward = build_reverse_forward_argv(
            destination=destination,
            port=port,
            identity_file=identity_file,
            ssh_options=effective_options,
            relay_port=relay_port,
            local_proxy_port=local_proxy_port,
        )
    return {
        "mode": "auto" if auto_connect else "planned",
        "state": "planned",
        "ssh": {
            "destination": destination,
            "port": port,
            "has_identity_file": bool(identity_file),
            "option_keys": ssh_option_keys(effective_options),
            "default_option_keys": sorted(DEFAULT_SSH_OPTIONS),
            "argv": redact_ssh_argv(probe_argv),
        },
        "bootstrap": build_remote_bootstrap_plan(relay=relay, daemon_path=daemon_path),
        "daemon": {
            "path": daemon_path or REMOTE_DAEMON_CURRENT_PATH,
            "serve_stdio_argv": redact_ssh_argv(probe_argv),
            "probe_methods": ["hello", "ping"],
        },
        "proxy": {
            "state": "planned" if reverse_forward else "disabled",
            "local_proxy_port": local_proxy_port,
            "reverse_forward_argv": redact_ssh_argv(reverse_forward) if reverse_forward else None,
        },
    }


def build_remote_bootstrap_plan(*, relay: Mapping[str, Any] | None, daemon_path: str | None) -> dict[str, Any]:
    writes: list[dict[str, Any]] = [
        {"path": "~/.cmux/bin", "kind": "directory", "mode": "0700"},
        {"path": REMOTE_RELAY_DIR, "kind": "directory", "mode": "0700"},
    ]
    if relay is not None:
        writes = [
            *writes,
            {
                "path": relay.get("remote_socket_addr_path"),
                "kind": "file",
                "mode": "0644",
                "content": relay.get("socket_addr"),
            },
            {
                "path": relay.get("relay_daemon_path_path"),
                "kind": "file",
                "mode": "0644",
                "content": daemon_path or REMOTE_DAEMON_CURRENT_PATH,
            },
            {
                "path": relay.get("relay_auth_path"),
                "kind": "file",
                "mode": RELAY_AUTH_FILE_MODE,
                "contains_relay_token": True,
                "redacted": True,
            },
        ]
    return {
        "state": "planned",
        "cmux_wrapper_path": REMOTE_CMUX_BIN_PATH,
        "daemon_current_path": daemon_path or REMOTE_DAEMON_CURRENT_PATH,
        "writes": writes,
    }


def build_remote_bootstrap_script(
    *,
    relay: Mapping[str, Any] | None,
    relay_token: str | None,
    daemon_path: str | None,
) -> str:
    daemon_target = daemon_path or REMOTE_DAEMON_CURRENT_PATH
    daemon_exec = remote_shell_path(daemon_target)
    lines = [
        "set -eu",
        "umask 077",
        'mkdir -p "$HOME/.cmux/bin" "$HOME/.cmux/relay"',
        "cat > \"$HOME/.cmux/bin/cmux\" <<'CMUX_WRAPPER'",
        "#!/bin/sh",
        f"exec {daemon_exec} cli \"$@\"",
        "CMUX_WRAPPER",
        'chmod 0700 "$HOME/.cmux/bin/cmux"',
        f"printf '%s\\n' {sh_quote(daemon_target)} > \"$HOME/.cmux/relay/current.daemon_path\"",
    ]
    if relay is not None:
        token = relay_token or ""
        auth_payload = relay_auth_file_payload(
            relay_id=str(relay.get("relay_id") or ""),
            relay_token=token,
        )
        socket_addr = str(relay.get("socket_addr") or "")
        relay_port = int(relay.get("relay_port") or 0)
        validate_port(relay_port)
        auth_path = f"$HOME/.cmux/relay/{relay_port}.auth"
        daemon_path_file = f"$HOME/.cmux/relay/{relay_port}.daemon_path"
        lines = [
            *lines,
            f"printf '%s\\n' {sh_quote(socket_addr)} > \"$HOME/.cmux/socket_addr\"",
            f"printf '%s\\n' {sh_quote(daemon_target)} > \"{daemon_path_file}\"",
            f"cat > \"{auth_path}\" <<'CMUX_RELAY_AUTH'",
            json.dumps(auth_payload, sort_keys=True, separators=(",", ":")),
            "CMUX_RELAY_AUTH",
            f"chmod {RELAY_AUTH_FILE_MODE} \"{auth_path}\"",
        ]
    return "\n".join(lines) + "\n"


def build_remote_bootstrap_invocation(
    *,
    destination: str,
    port: int | None,
    identity_file: str | None,
    ssh_options: list[str],
    relay: Mapping[str, Any] | None,
    relay_token: str | None,
    daemon_path: str | None,
) -> dict[str, Any]:
    command = build_ssh_argv(
        destination=destination,
        port=port,
        identity_file=identity_file,
        ssh_options=effective_ssh_options(ssh_options),
        remote_command="sh -s",
    )
    script = build_remote_bootstrap_script(
        relay=relay,
        relay_token=relay_token,
        daemon_path=daemon_path,
    )
    return {"command": command, "stdin": script.encode("utf-8")}


def build_remote_stdio_probe_request() -> bytes:
    request = (
        json.dumps({"id": "hello", "method": "hello", "params": {}}, separators=(",", ":"))
        + "\n"
        + json.dumps({"id": "ping", "method": "ping", "params": {}}, separators=(",", ":"))
        + "\n"
    )
    return request.encode("utf-8")


def build_remote_stdio_probe_invocation(
    *,
    destination: str,
    port: int | None,
    identity_file: str | None,
    ssh_options: list[str],
    daemon_path: str | None,
) -> dict[str, Any]:
    command = build_ssh_argv(
        destination=destination,
        port=port,
        identity_file=identity_file,
        ssh_options=effective_ssh_options(ssh_options),
        remote_command=f"{sh_path(daemon_path or REMOTE_DAEMON_CURRENT_PATH)} serve --stdio",
    )
    return {"command": command, "stdin": build_remote_stdio_probe_request()}


def build_ssh_argv(
    *,
    destination: str,
    port: int | None,
    identity_file: str | None,
    ssh_options: list[str],
    remote_command: str | None = None,
) -> list[str]:
    validate_ssh_destination(destination)
    argv = ["ssh", "-T", *validate_ssh_options(ssh_options)]
    if port is not None:
        validate_port(port)
        argv = [*argv, "-p", str(port)]
    if identity_file:
        validate_identity_file(identity_file)
        argv = [*argv, "-i", identity_file]
    argv = [*argv, destination]
    if remote_command:
        argv = [*argv, remote_command]
    return argv


def build_reverse_forward_argv(
    *,
    destination: str,
    port: int | None,
    identity_file: str | None,
    ssh_options: list[str],
    relay_port: int,
    local_proxy_port: int,
) -> list[str]:
    validate_port(relay_port)
    validate_port(local_proxy_port)
    validate_ssh_destination(destination)
    argv = [
        "ssh",
        "-T",
        "-N",
        "-R",
        f"127.0.0.1:{relay_port}:127.0.0.1:{local_proxy_port}",
        *validate_ssh_options(ssh_options),
    ]
    if port is not None:
        validate_port(port)
        argv = [*argv, "-p", str(port)]
    if identity_file:
        validate_identity_file(identity_file)
        argv = [*argv, "-i", identity_file]
    return [*argv, destination]


def effective_ssh_options(ssh_options: list[str]) -> list[str]:
    options = validate_ssh_options(ssh_options)
    existing_keys = {key.lower() for key in ssh_option_keys(options)}
    injected: list[str] = []
    for key, value in DEFAULT_SSH_OPTIONS.items():
        if key.lower() not in existing_keys:
            injected = [*injected, "-o", f"{key}={value}"]
    return [*injected, *options]


def ssh_option_keys(ssh_options: list[str]) -> list[str]:
    keys: list[str] = []
    index = 0
    while index < len(ssh_options):
        option = ssh_options[index]
        key_source = ""
        if option == "-o" and index + 1 < len(ssh_options):
            key_source = ssh_options[index + 1]
            index += 2
        elif option.startswith("-o") and len(option) > 2:
            key_source = option[2:]
            index += 1
        else:
            index += 1
        if key_source:
            key = key_source.split("=", 1)[0].strip()
            if key and key not in keys:
                keys = [*keys, key]
    return keys


def validate_ssh_options(ssh_options: list[str]) -> list[str]:
    if not isinstance(ssh_options, list) or not all(isinstance(item, str) for item in ssh_options):
        raise ValueError("ssh_options must be an array of strings.")
    validated: list[str] = []
    for option in ssh_options:
        if not option or "\x00" in option or "\n" in option or "\r" in option:
            raise ValueError("Invalid SSH option.")
        validated = [*validated, option]
    return validated


def validate_identity_file(identity_file: str) -> None:
    if identity_file.startswith("-") or "\x00" in identity_file or "\n" in identity_file or "\r" in identity_file:
        raise ValueError("Invalid identity file.")


def validate_port(port: int) -> None:
    if port < 1 or port > 65_535:
        raise ValueError("port must be 1-65535.")


def redact_ssh_argv(argv: list[str] | None) -> list[str] | None:
    if argv is None:
        return None
    redacted: list[str] = []
    skip_identity = False
    for item in argv:
        if skip_identity:
            redacted = [*redacted, "<identity_file>"]
            skip_identity = False
            continue
        redacted = [*redacted, item]
        if item == "-i":
            skip_identity = True
    return redacted


def sh_quote(value: str) -> str:
    return shlex.quote(value)


def sh_path(value: str) -> str:
    if value.startswith("~/"):
        return "$HOME/" + shlex.quote(value[2:])
    return shlex.quote(value)


def remote_shell_path(value: str) -> str:
    if value.startswith("~/"):
        return '"$HOME"/' + shlex.quote(value[2:])
    return shlex.quote(value)


def active_terminal_sessions(surfaces: Iterable[Any], terminal_session_ends: Iterable[Mapping[str, Any]]) -> dict[str, Any]:
    ended_surface_ids = {
        str(event.get("surface_id") or "")
        for event in terminal_session_ends
        if isinstance(event.get("surface_id"), str) and not isinstance(event.get("pane_id"), str)
    }
    ended_pane_ids = {
        str(event.get("pane_id") or "")
        for event in terminal_session_ends
        if isinstance(event.get("pane_id"), str)
    }
    sessions: list[dict[str, Any]] = []
    for surface in surfaces:
        surface_id = str(_remote_field(surface, "id") or "")
        if not surface_id or surface_id in ended_surface_ids:
            continue
        panes = _remote_field(surface, "panes")
        pane_values = panes.values() if isinstance(panes, Mapping) else panes if isinstance(panes, Iterable) else []
        for pane in pane_values:
            if _remote_field(pane, "kind") != "terminal":
                continue
            pane_id = str(_remote_field(pane, "id") or "")
            if pane_id and pane_id in ended_pane_ids:
                continue
            sessions.append(
                {
                    "surface_id": surface_id,
                    "surface_ref": f"surface:{surface_id}",
                    "pane_id": pane_id,
                    "pane_ref": f"pane:{pane_id}" if pane_id else None,
                    "title": _remote_field(pane, "title") or "Terminal",
                    "state": "active",
                }
            )
    return {"count": len(sessions), "sessions": sessions}


def remote_foreground_auth_transition(
    *,
    configuration: Mapping[str, Any],
    has_token: bool,
    ready_at: float,
    proxy_running: bool,
) -> dict[str, Any]:
    lifecycle = configuration.get("lifecycle") if isinstance(configuration.get("lifecycle"), Mapping) else {}
    proxy = lifecycle.get("proxy") if isinstance(lifecycle.get("proxy"), Mapping) else {}
    next_lifecycle = {
        **lifecycle,
        "state": "foreground_auth_ready",
        "foreground_auth_ready_at": ready_at,
        "proxy": dict(proxy),
        "updated_at": ready_at,
    }
    next_configuration = {
        **configuration,
        "has_foreground_auth_token": has_token or bool(configuration.get("has_foreground_auth_token")),
        "foreground_auth_ready_at": ready_at,
        "lifecycle": next_lifecycle,
    }
    return {
        "configuration": next_configuration,
        "should_connect": bool(configuration.get("auto_connect")) and not proxy_running,
    }


def remote_proxy_runtime_status(
    *,
    relay_configured: bool,
    process_pid: int | None,
    process_returncode: int | None,
    workspace_state: str,
    heartbeat: Mapping[str, Any] | None,
    now: float,
) -> dict[str, Any]:
    running = process_pid is not None and process_returncode is None
    exited = process_returncode is not None
    if running:
        proxy_state = "running"
        daemon_state = "running"
    elif exited:
        proxy_state = "exited"
        daemon_state = "exited"
    elif relay_configured and workspace_state == "disconnected":
        proxy_state = "disconnected"
        daemon_state = "not_running"
    elif relay_configured:
        proxy_state = "configured"
        daemon_state = "not_running"
    else:
        proxy_state = "disabled"
        daemon_state = "not_running"
    last_seen_at = heartbeat.get("last_seen_at") if isinstance(heartbeat, Mapping) else None
    age_seconds = None
    if isinstance(last_seen_at, (int, float)):
        age_seconds = round(now - float(last_seen_at), 3)
    return {
        "connected": running,
        "daemon": {
            "state": daemon_state,
            "pid": process_pid,
            "returncode": process_returncode,
        },
        "proxy": {
            "state": proxy_state,
            "error_code": f"process_exited_{process_returncode}" if exited else None,
        },
        "heartbeat": {
            "count": int(heartbeat.get("count") or 0) if isinstance(heartbeat, Mapping) else 0,
            "last_seen_at": last_seen_at,
            "age_seconds": age_seconds,
        },
    }


def _remote_field(value: Any, key: str) -> Any:
    if isinstance(value, Mapping):
        return value.get(key)
    return getattr(value, key, None)
