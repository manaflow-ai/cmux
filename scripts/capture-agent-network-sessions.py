#!/usr/bin/env python3
"""Capture real agent CLI network sessions and write a sanitized HAR fixture.

This script intentionally runs the installed CLIs. It does not synthesize
provider requests. Raw HAR files stay in a temporary directory unless
--keep-raw is passed.
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import urllib.parse
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any


def sensitive_key_token(value: str) -> str:
    return re.sub(r"[^a-z0-9]", "", value.lower())


PROMPT = "Reply with exactly: cmux-network-capture-ok"
MARKER = "cmux-network-capture-ok"
MAX_BODY_BYTES = 12_000
DEFAULT_OUTPUT = pathlib.Path("cmuxTests/Fixtures/AgentNetworkCaptures.json")
CAPTURE_ROOT_REPLACEMENTS: set[str] = set()
REQUIRED_CAPTURE_AGENTS = {"claude", "codex", "opencode"}
MAX_PROXY_START_ATTEMPTS = 3
UTF8_MOJIBAKE_RE = re.compile(r"(?:[\u00C2\u00C3][\u0080-\u00BF]|\u00E2[\u0080-\u00BF]{2})")
JSON_DROPPED_KEYS = {
    "additional_rate_limits",
    "api_key",
    "apikey",
    "access_token",
    "authorization",
    "client_secret",
    "cache_creation",
    "cache_creation_input_tokens",
    "cache_read_input_tokens",
    "cached_tokens",
    "code_review_rate_limits",
    "client_metadata",
    "context_management",
    "credits",
    "diagnostics",
    "ephemeral_1h_input_tokens",
    "ephemeral_5m_input_tokens",
    "encrypted_content",
    "id_token",
    "include",
    "inference_geo",
    "input_tokens",
    "input_tokens_details",
    "iterations",
    "max_output_tokens",
    "metadata",
    "obfuscation",
    "output_tokens",
    "output_tokens_details",
    "password",
    "plan_type",
    "prompt_cache_key",
    "prompt_cache_retention",
    "promo",
    "rate_limits",
    "reasoning",
    "reasoning_tokens",
    "refresh_token",
    "safety_identifier",
    "service_tier",
    "session_token",
    "signature",
    "thinking",
    "tool_usage",
    "tools",
    "total_tokens",
    "usage",
}
JSON_DROPPED_KEY_TOKENS = {
    sensitive_key_token(key)
    for key in JSON_DROPPED_KEYS
}
JSON_REDACTED_KEYS = {
    "instructions",
    "system",
    "system_instruction",
}
JSON_REDACTED_KEY_TOKENS = {
    sensitive_key_token(key)
    for key in JSON_REDACTED_KEYS
}
JSON_DROPPED_WEBSOCKET_TYPES = {
    "codex.rate_limits",
}
SENSITIVE_QUERY_KEYS = {
    "access_token",
    "api_key",
    "apikey",
    "auth",
    "authorization",
    "bearer",
    "client_secret",
    "code",
    "cookie",
    "id_token",
    "key",
    "password",
    "refresh_token",
    "session",
    "session_token",
    "signature",
    "sig",
    "token",
}
SENSITIVE_QUERY_KEY_TOKENS = {
    sensitive_key_token(key)
    for key in SENSITIVE_QUERY_KEYS
}
URL_RE = re.compile(r"https?://[^\s\"'<>]+")
SENSITIVE_ASSIGNMENT_RE = re.compile(
    r"\b(?:access_token|api_key|apikey|auth|authorization|bearer|client_secret|code|cookie|id_token|key|password|refresh_token|session|session_token|sig|signature|token)=([^&\s\"'<>]+)",
    re.IGNORECASE,
)


@dataclass
class AgentSpec:
    agent: str
    command: list[str]
    version_command: list[str]
    timeout: int = 120
    extra_env: dict[str, str] = field(default_factory=dict)
    mcp_config: bool = False


def repo_root() -> pathlib.Path:
    result = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        check=True,
        text=True,
        capture_output=True,
    )
    return pathlib.Path(result.stdout.strip())


def which(name: str) -> str | None:
    return shutil.which(name)


def register_capture_root(path: pathlib.Path) -> None:
    CAPTURE_ROOT_REPLACEMENTS.add(str(path))
    try:
        CAPTURE_ROOT_REPLACEMENTS.add(str(path.resolve()))
    except OSError:
        pass


def repair_utf8_mojibake(value: str) -> str:
    def replacement(match: re.Match[str]) -> str:
        matched = match.group(0)
        try:
            return matched.encode("latin-1").decode("utf-8")
        except UnicodeError:
            return matched

    return UTF8_MOJIBAKE_RE.sub(replacement, value)


def run_text(argv: list[str], timeout: int = 10) -> str:
    try:
        proc = subprocess.run(argv, text=True, capture_output=True, timeout=timeout)
    except Exception as exc:
        return f"unavailable: {type(exc).__name__}"
    text = (proc.stdout or proc.stderr or "").strip()
    return text.splitlines()[0] if text else f"exit {proc.returncode}"


def wait_for_proxy(port: int, cert_path: pathlib.Path, deadline: float) -> bool:
    while time.time() < deadline:
        port_ready = False
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                port_ready = True
        except OSError:
            pass
        if port_ready and cert_path.exists():
            return True
        time.sleep(0.2)
    return False


def available_tcp_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def cleanup_agent_artifacts(agent_dir: pathlib.Path, keep_raw: bool) -> None:
    if keep_raw:
        return
    shutil.rmtree(agent_dir, ignore_errors=True)


def sensitive_header(name: str) -> bool:
    lowered = name.lower()
    safe_names = {
        "accept",
        "accept-encoding",
        "cache-control",
        "connection",
        "content-encoding",
        "content-length",
        "content-security-policy",
        "content-type",
        "cross-origin-opener-policy",
        "date",
        "expires",
        "host",
        "originator",
        "pragma",
        "referrer-policy",
        "server",
        "strict-transport-security",
        "transfer-encoding",
        "user-agent",
        "vary",
        "x-app",
        "x-content-type-options",
        "anthropic-dangerous-direct-browser-access",
        "anthropic-version",
    }
    safe_prefixes = ("x-stainless-",)
    return lowered not in safe_names and not lowered.startswith(safe_prefixes)


def sanitize_text(value: str) -> str:
    home = str(pathlib.Path.home())
    replacements = [
        (home, "${HOME}"),
        (os.environ.get("CLAUDE_CONFIG_DIR", ""), "${CLAUDE_CONFIG_DIR}"),
    ]
    replacements.extend(
        (path, "${CAPTURE_ROOT}")
        for path in sorted(CAPTURE_ROOT_REPLACEMENTS, key=len, reverse=True)
    )
    result = value
    for old, new in replacements:
        if old:
            result = result.replace(old, new)
    result = repair_utf8_mojibake(result)
    result = re.sub(
        r"<system-reminder>\s*USD budget:.*?</system-reminder>",
        "<redacted-budget>",
        result,
        flags=re.DOTALL,
    )
    result = re.sub(
        r"<system-reminder>\s*As you answer.*?</system-reminder>",
        "<redacted-local-instructions>",
        result,
        flags=re.DOTALL,
    )
    for tag in [
        "apps_instructions",
        "collaboration_mode",
        "environment_context",
        "permissions instructions",
        "plugins_instructions",
        "skills_instructions",
    ]:
        result = re.sub(
            rf"<{re.escape(tag)}>.*?</{re.escape(tag)}>",
            "<redacted-runtime-instructions>",
            result,
            flags=re.DOTALL,
        )

    patterns = [
        (r"/var/folders/[^\"'\s]+/cmux-agent-network-captures\.[^/\"'\s]+", "${CAPTURE_ROOT}"),
        (r"x-anthropic-billing-header:[^\"\\\r\n]+", "<redacted-provider-metadata>"),
        (r"Bearer\s+[A-Za-z0-9._~+/=-]+", "<redacted-bearer>"),
        (r"sk-[A-Za-z0-9_-]{12,}", "sk-<redacted>"),
        (r"sess-[A-Za-z0-9_-]{12,}", "sess-<redacted>"),
        (r"\b(user|org|acct|proj|ses)-[A-Za-z0-9_-]{12,}\b", "<redacted-id>"),
        (r"\b(user|org|acct|proj|ses)_[A-Za-z0-9_-]{12,}\b", "<redacted-id>"),
        (r"\b(req|msg|resp|evt|call|rs)_[A-Za-z0-9_-]{12,}\b", "<redacted-id>"),
        (r"eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9._-]{20,}", "<redacted-jwt>"),
        (r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}", "<redacted-email>"),
        (r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b", "<redacted-uuid>"),
        (r"\b[0-9a-fA-F]{32,}\b", "<redacted-hex>"),
    ]
    for pattern, replacement in patterns:
        result = re.sub(pattern, replacement, result)
    return result


def sanitize_url(value: str) -> str:
    sanitized = sanitize_text(value)
    try:
        parts = urllib.parse.urlsplit(sanitized)
    except ValueError:
        return sanitized
    if not parts.scheme or not parts.netloc:
        return sanitized

    query_items = urllib.parse.parse_qsl(parts.query, keep_blank_values=True)
    kept_query_items = [
        (key, val)
        for key, val in query_items
        if key.lower() not in SENSITIVE_QUERY_KEYS
        and sensitive_key_token(key) not in SENSITIVE_QUERY_KEY_TOKENS
    ]
    query = urllib.parse.urlencode(kept_query_items, doseq=True)
    return urllib.parse.urlunsplit((
        parts.scheme,
        parts.netloc,
        parts.path,
        query,
        "",
    ))


def sanitize_failure_line(value: str) -> str:
    text = URL_RE.sub(lambda match: sanitize_url(match.group(0)), value)
    text = sanitize_text(text)
    return SENSITIVE_ASSIGNMENT_RE.sub("<redacted-secret-param>", text)


def is_reasoning_json_value(value: Any) -> bool:
    if not isinstance(value, dict):
        return False
    event_type = value.get("type")
    if event_type == "reasoning":
        return True
    if isinstance(event_type, str) and "reasoning" in event_type:
        return True
    for key in ("item", "delta", "output_item"):
        item = value.get(key)
        if isinstance(item, dict) and item.get("type") == "reasoning":
            return True
    return False


def redact_json_value(value: Any) -> Any:
    if isinstance(value, dict):
        redacted: dict[str, Any] = {}
        role = value.get("role")
        role_lower = role.lower() if isinstance(role, str) else None
        for key, item in value.items():
            lowered = key.lower()
            key_token = sensitive_key_token(key)
            if lowered in JSON_DROPPED_KEYS or key_token in JSON_DROPPED_KEY_TOKENS:
                continue
            if lowered == "content" and role_lower in {"developer", "system"}:
                redacted[key] = (
                    "<redacted-runtime-instructions>"
                    if role_lower == "developer"
                    else "<redacted-provider-metadata>"
                )
            elif lowered in JSON_REDACTED_KEYS or key_token in JSON_REDACTED_KEY_TOKENS:
                redacted[key] = "<redacted-provider-metadata>"
            else:
                redacted[key] = redact_json_value(item)
        return redacted
    if isinstance(value, list):
        return [
            redact_json_value(item)
            for item in value
            if not is_reasoning_json_value(item)
        ]
    if isinstance(value, str):
        stripped = value.lstrip()
        if stripped.startswith("# AGENTS.md instructions for ") or stripped.startswith("# CLAUDE.md instructions for "):
            return "<redacted-local-instructions>"
        return sanitize_text(value)
    return value


def sanitize_json_text(value: str) -> str | None:
    try:
        parsed = json.loads(value)
    except json.JSONDecodeError:
        return None
    return json.dumps(redact_json_value(parsed), separators=(",", ":"), sort_keys=True)


def should_drop_sse_json_payload(value: str) -> bool:
    try:
        parsed = json.loads(value)
    except json.JSONDecodeError:
        return False
    if not isinstance(parsed, dict):
        return False
    if parsed.get("type") == "content_block_start":
        content_block = parsed.get("content_block")
        if isinstance(content_block, dict) and content_block.get("type") == "thinking":
            return True
    if parsed.get("type") == "content_block_delta":
        delta = parsed.get("delta")
        if isinstance(delta, dict) and delta.get("type") in {"thinking_delta", "signature_delta"}:
            return True
    if is_reasoning_json_value(parsed):
        return True
    return False


def sanitize_sse_json_lines(value: str) -> str:
    sanitized_lines: list[str] = []
    pending_event_lines: list[str] = []
    for line in value.splitlines():
        if not line.startswith("data:"):
            pending_event_lines.append(line)
            continue
        prefix, payload = line.split(":", 1)
        stripped = payload.lstrip()
        if should_drop_sse_json_payload(stripped):
            pending_event_lines = []
            continue
        sanitized_payload = sanitize_json_text(stripped)
        sanitized_lines.extend(pending_event_lines)
        pending_event_lines = []
        if sanitized_payload is None:
            sanitized_lines.append(line)
        else:
            padding = payload[: len(payload) - len(stripped)]
            sanitized_lines.append(f"{prefix}:{padding}{sanitized_payload}")
    sanitized_lines.extend(pending_event_lines)
    suffix = "\n" if value.endswith("\n") else ""
    return "\n".join(sanitized_lines) + suffix


def sanitize_body_text(value: str) -> str:
    sanitized = sanitize_text(value)
    json_text = sanitize_json_text(sanitized)
    if json_text is not None:
        return json_text
    return sanitize_sse_json_lines(sanitized)


def trim_text(value: str) -> tuple[str, bool]:
    encoded = value.encode("utf-8")
    if len(encoded) <= MAX_BODY_BYTES:
        return value, False
    trimmed = encoded[:MAX_BODY_BYTES].decode("utf-8", errors="ignore")
    return trimmed + "\n<cmux-truncated>", True


def sanitize_headers(headers: list[dict[str, Any]]) -> list[dict[str, str]]:
    sanitized: list[dict[str, str]] = []
    for header in headers:
        name = str(header.get("name", ""))
        value = str(header.get("value", ""))
        if sensitive_header(name):
            continue
        value = sanitize_text(value)
        sanitized.append({"name": name, "value": value})
    return sanitized


def strip_decoded_response_encoding_headers(
    headers: list[dict[str, str]],
    body: dict[str, Any] | None,
) -> list[dict[str, str]]:
    text = body.get("text") if body else None
    if not isinstance(text, str):
        return headers
    decoded_body_headers = {
        "content-encoding",
        "transfer-encoding",
    }
    return [
        header
        for header in headers
        if header["name"].lower() not in decoded_body_headers
    ]


def synchronize_content_length(
    headers: list[dict[str, str]],
    body: dict[str, Any] | None,
) -> list[dict[str, str]]:
    text = body.get("text") if body else None
    is_truncated = bool(body.get("_cmuxBodyTruncated")) if body else False
    if not isinstance(text, str) or is_truncated:
        return [header for header in headers if header["name"].lower() != "content-length"]

    byte_count = str(len(text.encode("utf-8")))
    return [
        {**header, "value": byte_count}
        if header["name"].lower() == "content-length"
        else header
        for header in headers
    ]


def sanitize_post_data(post_data: dict[str, Any] | None) -> dict[str, Any] | None:
    if not post_data:
        return None
    source_truncated = bool(post_data.get("_cmuxBodyTruncated"))
    text = post_data.get("text")
    if not isinstance(text, str) or not text:
        return None
    text, truncated = trim_text(sanitize_body_text(text))
    result: dict[str, Any] = {
        "mimeType": post_data.get("mimeType", "application/octet-stream"),
        "text": text,
    }
    if truncated or source_truncated or "<cmux-truncated>" in text:
        result["_cmuxBodyTruncated"] = True
    return result


def sanitize_content(content: dict[str, Any]) -> dict[str, Any]:
    text = content.get("text")
    source_truncated = bool(content.get("_cmuxBodyTruncated"))
    result: dict[str, Any] = {
        "mimeType": content.get("mimeType", "application/octet-stream"),
        "size": 0,
    }
    if isinstance(text, str) and text:
        text, truncated = trim_text(sanitize_body_text(text))
        result["size"] = len(text.encode("utf-8"))
        result["text"] = text
        if truncated or source_truncated or "<cmux-truncated>" in text:
            result["_cmuxBodyTruncated"] = True
    else:
        result["text"] = ""
    return result


def has_request_response_body(entry: dict[str, Any]) -> bool:
    request_post_data = entry.get("request", {}).get("postData") or {}
    response_content = entry.get("response", {}).get("content") or {}
    request_text = (
        request_post_data.get("text", "")
    )
    response_text = (
        response_content.get("text", "")
    )
    return bool(request_text) and bool(response_text)


def websocket_message_text(entry: dict[str, Any], direction: str | None = None) -> str:
    messages = entry.get("_webSocketMessages", [])
    if not isinstance(messages, list):
        return ""
    parts: list[str] = []
    for message in messages:
        if not isinstance(message, dict):
            continue
        if direction is not None and message.get("type") != direction:
            continue
        if isinstance(message.get("data"), str):
            parts.append(message["data"])
    return "\n".join(parts)


def response_payload_text(entry: dict[str, Any]) -> str:
    response_content = entry.get("response", {}).get("content") or {}
    response_text = (
        response_content.get("text", "")
    )
    return f"{response_text}\n{websocket_message_text(entry, direction='receive')}"


def has_replayable_payload(entry: dict[str, Any]) -> bool:
    return has_request_response_body(entry) or bool(websocket_message_text(entry))


def score_entry(agent: str, entry: dict[str, Any]) -> int:
    request = entry.get("request", {})
    url = str(request.get("url", ""))
    score = 0
    if MARKER in response_payload_text(entry):
        score += 120
    if agent == "claude" and "/v1/messages" in url:
        score += 50
    if agent == "opencode" and "chatgpt.com" in url:
        score += 50
    if agent == "codex" and "backend-api" in url:
        score += 40
    if agent == "codex" and "/v1/responses" in url:
        score += 60
    if has_request_response_body(entry):
        score += 20
    if websocket_message_text(entry):
        score += 30
    return score


def should_drop_websocket_message(data: str) -> bool:
    try:
        parsed = json.loads(data)
    except json.JSONDecodeError:
        return False
    if not isinstance(parsed, dict):
        return False
    event_type = parsed.get("type")
    if event_type in JSON_DROPPED_WEBSOCKET_TYPES:
        return True
    return is_reasoning_json_value(parsed)


def sanitize_websocket_messages(entry: dict[str, Any]) -> list[dict[str, Any]]:
    messages = entry.get("_webSocketMessages", [])
    if not isinstance(messages, list):
        return []
    sanitized: list[dict[str, Any]] = []
    for message in messages:
        if not isinstance(message, dict):
            continue
        data = message.get("data", "")
        if not isinstance(data, str):
            continue
        if should_drop_websocket_message(data):
            continue
        text, truncated = trim_text(sanitize_body_text(data))
        sanitized_message: dict[str, Any] = {
            "type": message.get("type", ""),
            "time": message.get("time", 0),
            "opcode": message.get("opcode", 0),
            "data": text,
        }
        if truncated or "<cmux-truncated>" in text:
            sanitized_message["_cmuxBodyTruncated"] = True
        sanitized.append(sanitized_message)
    return sanitized


def sanitize_entry(entry: dict[str, Any]) -> dict[str, Any]:
    request = entry.get("request", {})
    response = entry.get("response", {})
    request_post_data = sanitize_post_data(request.get("postData"))
    response_content = sanitize_content(response.get("content", {}))
    sanitized = {
        "startedDateTime": entry.get("startedDateTime", ""),
        "time": entry.get("time", 0),
        "request": {
            "method": request.get("method", "GET"),
            "url": sanitize_url(str(request.get("url", ""))),
            "httpVersion": request.get("httpVersion", "HTTP/1.1"),
            "headers": synchronize_content_length(
                sanitize_headers(request.get("headers", [])),
                request_post_data,
            ),
            "postData": request_post_data,
        },
        "response": {
            "status": response.get("status", 0),
            "statusText": response.get("statusText", ""),
            "httpVersion": response.get("httpVersion", "HTTP/1.1"),
            "headers": synchronize_content_length(
                strip_decoded_response_encoding_headers(
                    sanitize_headers(response.get("headers", [])),
                    response_content,
                ),
                response_content,
            ),
            "content": response_content,
        },
    }
    if entry.get("_resourceType"):
        sanitized["_resourceType"] = entry.get("_resourceType")
    websocket_messages = sanitize_websocket_messages(entry)
    if websocket_messages:
        sanitized["_webSocketMessages"] = websocket_messages
    return sanitized


def selected_entries(agent: str, har_path: pathlib.Path) -> list[dict[str, Any]]:
    if not har_path.exists():
        return []
    try:
        data = json.loads(har_path.read_text(errors="replace"))
    except (OSError, ValueError) as exc:
        print(
            f"warning: could not parse HAR for {agent} at {sanitize_text(str(har_path))}: {type(exc).__name__}: {exc}",
            file=sys.stderr,
        )
        return []
    entries = data.get("log", {}).get("entries", [])
    candidates = [entry for entry in entries if has_replayable_payload(entry)]
    response_marker_entries = [
        entry for entry in candidates
        if MARKER in response_payload_text(entry)
    ]
    if not response_marker_entries:
        return []
    candidates = response_marker_entries
    preferred = [
        entry for entry in candidates
        if (
            agent == "claude"
            and "/v1/messages" in str(entry.get("request", {}).get("url", ""))
        ) or (
            agent == "opencode"
            and "chatgpt.com/backend-api/codex/responses" in str(entry.get("request", {}).get("url", ""))
        ) or (
            agent == "codex"
            and (
                "backend-api" in str(entry.get("request", {}).get("url", ""))
                or "/v1/responses" in str(entry.get("request", {}).get("url", ""))
            )
        )
    ]
    if preferred:
        candidates = preferred
    candidates.sort(key=lambda entry: score_entry(agent, entry), reverse=True)

    selected: list[dict[str, Any]] = []
    seen_keys: set[tuple[str, str]] = set()
    limit = 2 if agent == "codex" else 1
    for entry in candidates:
        request = entry.get("request", {})
        key = (str(request.get("method", "")), str(request.get("url", "")))
        if key in seen_keys:
            continue
        seen_keys.add(key)
        selected.append(sanitize_entry(entry))
        if len(selected) >= limit:
            break
    return selected


def capture_agent(
    spec: AgentSpec,
    root: pathlib.Path,
    port: int,
    cwd: pathlib.Path,
    keep_raw: bool,
) -> tuple[dict[str, Any] | None, dict[str, str] | None]:
    if not shutil.which(spec.command[0]) and not pathlib.Path(spec.command[0]).exists():
        return None, {"agent": spec.agent, "reason": f"No {spec.command[0]} executable was available on PATH."}

    agent_dir = root / spec.agent
    agent_dir.mkdir(parents=True, exist_ok=True)
    confdir = agent_dir / "mitm"
    confdir.mkdir()
    har_path = agent_dir / f"{spec.agent}.har"
    cert_path = confdir / "mitmproxy-ca-cert.pem"

    command = list(spec.command)
    if spec.mcp_config:
        mcp_config = agent_dir / "mcp.json"
        mcp_config.write_text('{"mcpServers":{}}')
        command = [
            *command[: command.index("--mcp-config") + 1],
            str(mcp_config),
            *command[command.index("--mcp-config") + 2 :],
        ]

    uvx = which("uvx")
    if not uvx:
        return None, {"agent": spec.agent, "reason": "mitm unavailable: uvx executable was not available on PATH."}

    mitm_stdout = (agent_dir / "mitm.out").open("wb")
    mitm_stderr = (agent_dir / "mitm.err").open("wb")
    mitm_cmd = [
        uvx,
        "--from",
        "mitmproxy",
        "mitmdump",
        "--set",
        f"confdir={confdir}",
        "--listen-host",
        "127.0.0.1",
        "--listen-port",
        str(port),
        "--set",
        f"hardump={har_path}",
        "--set",
        "termlog_verbosity=error",
        "--set",
        "flow_detail=0",
    ]
    try:
        mitm = subprocess.Popen(mitm_cmd, stdout=mitm_stdout, stderr=mitm_stderr)
    except OSError as exc:
        mitm_stdout.close()
        mitm_stderr.close()
        cleanup_agent_artifacts(agent_dir, keep_raw)
        return None, {
            "agent": spec.agent,
            "reason": (
                "mitm unavailable: failed to launch uvx/mitmdump "
                f"on port {port} with confdir {sanitize_text(str(confdir))} "
                f"and HAR {sanitize_text(str(har_path))}: {type(exc).__name__}"
            ),
        }

    proxy_ready = wait_for_proxy(port, cert_path, time.time() + 60)
    env = os.environ.copy()
    env.update(
        {
            "HTTPS_PROXY": f"http://127.0.0.1:{port}",
            "HTTP_PROXY": f"http://127.0.0.1:{port}",
            "ALL_PROXY": f"http://127.0.0.1:{port}",
            "https_proxy": f"http://127.0.0.1:{port}",
            "http_proxy": f"http://127.0.0.1:{port}",
            "all_proxy": f"http://127.0.0.1:{port}",
            "NO_PROXY": "",
            "no_proxy": "",
            "NODE_EXTRA_CA_CERTS": str(cert_path),
            "SSL_CERT_FILE": str(cert_path),
            "REQUESTS_CA_BUNDLE": str(cert_path),
            "CURL_CA_BUNDLE": str(cert_path),
            "CMUX_CODEX_HOOKS_DISABLED": "1",
            "CMUX_CLAUDE_HOOKS_DISABLED": "1",
            "CMUX_GEMINI_HOOKS_DISABLED": "1",
            "CMUX_OPENCODE_HOOKS_DISABLED": "1",
            "CMUX_ANTIGRAVITY_HOOKS_DISABLED": "1",
        }
    )
    env.update(spec.extra_env)

    stdout_path = agent_dir / "stdout.txt"
    stderr_path = agent_dir / "stderr.txt"
    return_code: int | str = "proxy_not_ready"
    started = time.time()
    duration_ms = 0
    timed_out = False
    run_error: str | None = None
    try:
        if proxy_ready:
            with stdout_path.open("wb") as stdout, stderr_path.open("wb") as stderr:
                proc = subprocess.run(
                    command,
                    cwd=cwd,
                    env=env,
                    stdout=stdout,
                    stderr=stderr,
                    timeout=spec.timeout,
                )
                return_code = proc.returncode
    except subprocess.TimeoutExpired:
        return_code = "timeout"
        timed_out = True
    except Exception as exc:
        return_code = f"error:{type(exc).__name__}"
        run_error = sanitize_failure_line(str(exc))
    finally:
        duration_ms = int((time.time() - started) * 1000)
        time.sleep(1)
        if mitm.poll() is None:
            mitm.send_signal(signal.SIGINT)
            try:
                mitm.wait(timeout=10)
            except subprocess.TimeoutExpired:
                mitm.kill()
                mitm.wait(timeout=5)
        mitm_stdout.close()
        mitm_stderr.close()

    stdout_text = stdout_path.read_text(errors="replace") if stdout_path.exists() else ""
    stderr_text = stderr_path.read_text(errors="replace") if stderr_path.exists() else ""
    marker_observed = MARKER in stdout_text
    entries = selected_entries(spec.agent, har_path)

    if return_code != 0 or not marker_observed or not entries:
        reason_parts = [f"exit={return_code}", f"marker={marker_observed}", f"entries={len(entries)}"]
        if run_error:
            reason_parts.append(run_error[:200])
        if stderr_text.strip():
            reason_parts.append(sanitize_failure_line(stderr_text.strip()).splitlines()[0][:200])
        if stdout_text.strip() and not marker_observed:
            reason_parts.append(sanitize_failure_line(stdout_text.strip()).splitlines()[0][:200])
        cleanup_agent_artifacts(agent_dir, keep_raw)
        return None, {"agent": spec.agent, "reason": "; ".join(reason_parts)}

    capture = {
        "name": f"{spec.agent}-real-cli-network-turn",
        "agent": spec.agent,
        "capturedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "cliVersion": run_text(spec.version_command),
        "command": [sanitize_text(part) for part in command],
        "captureBackend": "mitmproxy-hardump",
        "status": "captured",
        "exitCode": return_code,
        "durationMs": duration_ms,
        "markerObserved": marker_observed,
        "har": {
            "log": {
                "version": "1.2",
                "creator": {"name": "mitmproxy hardump via capture-agent-network-sessions.py", "version": "1"},
                "entries": entries,
            }
        },
    }

    cleanup_agent_artifacts(agent_dir, keep_raw)
    return capture, None


def should_retry_proxy_start_failure(failed: dict[str, str] | None) -> bool:
    if not failed:
        return False
    reason = failed.get("reason", "").lower()
    return (
        "exit=proxy_not_ready" in reason
        or "address already in use" in reason
        or "eaddrinuse" in reason
    )


def capture_agent_with_proxy_retries(
    spec: AgentSpec,
    root: pathlib.Path,
    cwd: pathlib.Path,
    keep_raw: bool,
) -> tuple[dict[str, Any] | None, dict[str, str] | None]:
    failures: list[str] = []
    for attempt in range(1, MAX_PROXY_START_ATTEMPTS + 1):
        capture, failed = capture_agent(
            spec=spec,
            root=root,
            port=available_tcp_port(),
            cwd=cwd,
            keep_raw=keep_raw,
        )
        if capture or not should_retry_proxy_start_failure(failed):
            return capture, failed
        failures.append(f"attempt {attempt}: {failed['reason']}")

    return None, {
        "agent": spec.agent,
        "reason": (
            f"proxy failed after {MAX_PROXY_START_ATTEMPTS} attempts: "
            + " | ".join(failures)
        ),
    }


def agent_specs() -> tuple[list[AgentSpec], list[dict[str, str]]]:
    unavailable: list[dict[str, str]] = []

    claude = which("claude") or "claude"

    specs = [
        AgentSpec(
            agent="claude",
            command=[
                claude,
                "-p",
                "--output-format",
                "json",
                "--max-budget-usd",
                "0.05",
                "--model",
                "haiku",
                "--tools",
                "",
                "--strict-mcp-config",
                "--mcp-config",
                "__MCP_CONFIG__",
                "--disable-slash-commands",
                "--no-session-persistence",
                PROMPT,
            ],
            version_command=[claude, "--version"],
            timeout=90,
            mcp_config=True,
        ),
        AgentSpec(
            agent="codex",
            command=[
                "codex",
                "exec",
                "--json",
                "--sandbox",
                "read-only",
                "--skip-git-repo-check",
                "--ephemeral",
                PROMPT,
            ],
            version_command=["codex", "--version"],
            timeout=120,
        ),
        AgentSpec(
            agent="opencode",
            command=[
                "opencode",
                "run",
                "--format",
                "json",
                "--model",
                "openai/gpt-5.4-mini-fast",
                PROMPT,
            ],
            version_command=["opencode", "--version"],
            timeout=120,
        ),
    ]

    if which("gemini"):
        specs.append(
            AgentSpec(
                agent="gemini",
                command=[
                    "gemini",
                    "-p",
                    PROMPT,
                    "--output-format",
                    "json",
                    "--model",
                    "gemini-2.5-flash",
                ],
                version_command=["gemini", "--version"],
                timeout=90,
                extra_env={"NO_BROWSER": "1"},
            )
        )
    else:
        unavailable.append({"agent": "gemini", "reason": "No gemini executable was available on PATH."})

    antigravity = which("agy") or which("antigravity")
    if antigravity:
        specs.append(
            AgentSpec(
                agent="antigravity",
                command=[antigravity, PROMPT],
                version_command=[antigravity, "--version"],
                timeout=120,
            )
        )
    else:
        unavailable.append({"agent": "antigravity", "reason": "No agy or antigravity executable was available on PATH."})

    return specs, unavailable


def merge_existing_fixture(
    output: pathlib.Path,
    selected_agents: set[str] | None,
    captures: list[dict[str, Any]],
    unavailable: list[dict[str, str]],
) -> tuple[list[dict[str, Any]], list[dict[str, str]]]:
    if not selected_agents or not output.exists():
        return captures, unavailable

    existing = json.loads(output.read_text())
    preserved_captures = [
        item
        for item in existing.get("captures", [])
        if item.get("agent") not in selected_agents
    ]
    preserved_unavailable = [
        item
        for item in existing.get("unavailable", [])
        if item.get("agent") not in selected_agents
    ]
    return preserved_captures + captures, preserved_unavailable + unavailable


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=pathlib.Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--keep-raw", action="store_true")
    parser.add_argument("--agent", action="append", help="Capture only this agent. May be repeated.")
    args = parser.parse_args()

    root = repo_root()
    output = args.output if args.output.is_absolute() else root / args.output
    capture_root = pathlib.Path(tempfile.mkdtemp(prefix="cmux-agent-network-captures."))
    register_capture_root(capture_root)

    specs, unavailable = agent_specs()
    selected_agents: set[str] | None = None
    if args.agent:
        selected_agents = set(args.agent)
        known_agents = {spec.agent for spec in specs} | {item["agent"] for item in unavailable}
        unknown_agents = sorted(selected_agents - known_agents)
        if unknown_agents:
            print(
                f"unknown agent selection: {', '.join(unknown_agents)}",
                file=sys.stderr,
            )
            print(
                f"known agents: {', '.join(sorted(known_agents))}",
                file=sys.stderr,
            )
            return 2
        specs = [spec for spec in specs if spec.agent in selected_agents]
        unavailable = [item for item in unavailable if item["agent"] in selected_agents]

    captures: list[dict[str, Any]] = []
    try:
        for spec in specs:
            capture, failed = capture_agent_with_proxy_retries(
                spec=spec,
                root=capture_root,
                cwd=root,
                keep_raw=args.keep_raw,
            )
            if capture:
                captures.append(capture)
            elif failed:
                if failed["agent"] == "gemini" and "entries=0" in failed["reason"]:
                    failed["reason"] = (
                        "Gemini CLI opened an auth flow and produced no HAR entries "
                        "with the current local configuration."
                    )
                unavailable.append(failed)

        captures, unavailable = merge_existing_fixture(output, selected_agents, captures, unavailable)
        captured_agents = {item["agent"] for item in captures}
        required_agents = REQUIRED_CAPTURE_AGENTS if selected_agents is None else REQUIRED_CAPTURE_AGENTS & selected_agents
        missing_required = sorted(required_agents - captured_agents)
        if missing_required:
            print(
                f"missing required captures: {', '.join(missing_required)}",
                file=sys.stderr,
            )
            for item in sorted(unavailable, key=lambda value: value["agent"]):
                if item["agent"] in missing_required:
                    print(f"{item['agent']}: {item['reason']}", file=sys.stderr)
            return 1

        fixture = {
            "version": 1,
            "captureSource": "real-cli-mitm-har",
            "prompt": PROMPT,
            "generatedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
            "captures": sorted(captures, key=lambda item: item["agent"]),
            "unavailable": sorted(unavailable, key=lambda item: item["agent"]),
        }
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(fixture, indent=2, sort_keys=True) + "\n")
        print(f"wrote {output}")
        print(f"captured agents: {', '.join(item['agent'] for item in fixture['captures']) or 'none'}")
        print(f"unavailable agents: {', '.join(item['agent'] for item in fixture['unavailable']) or 'none'}")
        if args.keep_raw:
            print(f"raw captures: {capture_root}")
        return 0
    finally:
        if not args.keep_raw:
            shutil.rmtree(capture_root, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
