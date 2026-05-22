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
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any


PROMPT = "Reply with exactly: cmux-network-capture-ok"
MARKER = "cmux-network-capture-ok"
MAX_BODY_BYTES = 12_000
DEFAULT_OUTPUT = pathlib.Path("cmuxTests/Fixtures/AgentNetworkCaptures.json")


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


def sensitive_header(name: str) -> bool:
    lowered = name.lower()
    needles = [
        "authorization",
        "cookie",
        "token",
        "secret",
        "api-key",
        "x-api-key",
        "account",
        "credit",
        "limit",
        "organization",
        "plan",
        "request-id",
        "ratelimit",
        "reset-at",
        "reset-after",
        "session",
        "csrf",
        "sentry",
        "used-percent",
        "datadog",
    ]
    return any(needle in lowered for needle in needles)


def sanitize_text(value: str) -> str:
    home = str(pathlib.Path.home())
    replacements = [
        (home, "${HOME}"),
        (os.environ.get("CLAUDE_CONFIG_DIR", ""), "${CLAUDE_CONFIG_DIR}"),
    ]
    result = value
    for old, new in replacements:
        if old:
            result = result.replace(old, new)

    patterns = [
        (r"/var/folders/[^\"'\s]+/cmux-agent-network-captures\.[^/\"'\s]+", "${CAPTURE_ROOT}"),
        (r"Bearer\s+[A-Za-z0-9._~+/=-]+", "Bearer <redacted>"),
        (r"sk-[A-Za-z0-9_-]{12,}", "sk-<redacted>"),
        (r"sess-[A-Za-z0-9_-]{12,}", "sess-<redacted>"),
        (r"\b(user|org|acct|proj|ses)-[A-Za-z0-9_-]{12,}\b", "<redacted-id>"),
        (r"\b(user|org|acct|proj|ses)_[A-Za-z0-9_-]{12,}\b", "<redacted-id>"),
        (r"\b(req|msg|resp|evt|call)_[A-Za-z0-9_-]{12,}\b", "<redacted-id>"),
        (r"eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9._-]{20,}", "<redacted-jwt>"),
        (r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}", "<redacted-email>"),
        (r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b", "<redacted-uuid>"),
        (r"\b[0-9a-fA-F]{32,}\b", "<redacted-hex>"),
    ]
    for pattern, replacement in patterns:
        result = re.sub(pattern, replacement, result)
    return result


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


def sanitize_post_data(post_data: dict[str, Any] | None) -> dict[str, Any] | None:
    if not post_data:
        return None
    source_truncated = bool(post_data.get("_cmuxBodyTruncated"))
    text = post_data.get("text")
    if not isinstance(text, str) or not text:
        return None
    text, truncated = trim_text(sanitize_text(text))
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
        "size": content.get("size", 0),
    }
    if isinstance(text, str) and text:
        text, truncated = trim_text(sanitize_text(text))
        result["text"] = text
        if truncated or source_truncated or "<cmux-truncated>" in text:
            result["_cmuxBodyTruncated"] = True
    else:
        result["text"] = ""
    return result


def has_request_response_body(entry: dict[str, Any]) -> bool:
    request_text = (
        entry.get("request", {})
        .get("postData", {})
        .get("text", "")
    )
    response_text = (
        entry.get("response", {})
        .get("content", {})
        .get("text", "")
    )
    return bool(request_text) and bool(response_text)


def score_entry(agent: str, entry: dict[str, Any]) -> int:
    request = entry.get("request", {})
    response = entry.get("response", {})
    url = str(request.get("url", ""))
    body = json.dumps(
        {
            "request": request.get("postData", {}),
            "response": response.get("content", {}),
        },
        sort_keys=True,
    )
    score = 0
    if MARKER in body:
        score += 100
    if agent == "claude" and "/v1/messages" in url:
        score += 50
    if agent == "opencode" and "chatgpt.com" in url:
        score += 50
    if agent == "codex" and "backend-api" in url:
        score += 40
    if has_request_response_body(entry):
        score += 20
    return score


def sanitize_entry(entry: dict[str, Any]) -> dict[str, Any]:
    request = entry.get("request", {})
    response = entry.get("response", {})
    return {
        "startedDateTime": entry.get("startedDateTime", ""),
        "time": entry.get("time", 0),
        "request": {
            "method": request.get("method", "GET"),
            "url": sanitize_text(str(request.get("url", ""))),
            "httpVersion": request.get("httpVersion", "HTTP/1.1"),
            "headers": sanitize_headers(request.get("headers", [])),
            "postData": sanitize_post_data(request.get("postData")),
        },
        "response": {
            "status": response.get("status", 0),
            "statusText": response.get("statusText", ""),
            "httpVersion": response.get("httpVersion", "HTTP/1.1"),
            "headers": sanitize_headers(response.get("headers", [])),
            "content": sanitize_content(response.get("content", {})),
        },
    }


def selected_entries(agent: str, har_path: pathlib.Path) -> list[dict[str, Any]]:
    if not har_path.exists():
        return []
    data = json.loads(har_path.read_text(errors="replace"))
    entries = data.get("log", {}).get("entries", [])
    candidates = [entry for entry in entries if has_request_response_body(entry)]
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
            and "backend-api" in str(entry.get("request", {}).get("url", ""))
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

    mitm_stdout = (agent_dir / "mitm.out").open("wb")
    mitm_stderr = (agent_dir / "mitm.err").open("wb")
    mitm = subprocess.Popen(
        [
            "uvx",
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
        ],
        stdout=mitm_stdout,
        stderr=mitm_stderr,
    )

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
    timed_out = False
    if proxy_ready:
        with stdout_path.open("wb") as stdout, stderr_path.open("wb") as stderr:
            try:
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
        if stderr_text.strip():
            reason_parts.append(sanitize_text(stderr_text.strip()).splitlines()[0][:200])
        if stdout_text.strip() and not marker_observed:
            reason_parts.append(sanitize_text(stdout_text.strip()).splitlines()[0][:200])
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

    if not keep_raw:
        for path in [har_path, stdout_path, stderr_path, agent_dir / "mitm.out", agent_dir / "mitm.err"]:
            path.unlink(missing_ok=True)
        shutil.rmtree(confdir, ignore_errors=True)
    return capture, None


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


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=pathlib.Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--keep-raw", action="store_true")
    parser.add_argument("--agent", action="append", help="Capture only this agent. May be repeated.")
    args = parser.parse_args()

    root = repo_root()
    output = args.output if args.output.is_absolute() else root / args.output
    capture_root = pathlib.Path(tempfile.mkdtemp(prefix="cmux-agent-network-captures."))

    specs, unavailable = agent_specs()
    if args.agent:
        wanted = set(args.agent)
        specs = [spec for spec in specs if spec.agent in wanted]
        unavailable = [item for item in unavailable if item["agent"] in wanted]

    captures: list[dict[str, Any]] = []
    try:
        for index, spec in enumerate(specs, start=1):
            capture, failed = capture_agent(
                spec=spec,
                root=capture_root,
                port=19400 + index,
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
        else:
            shutil.rmtree(capture_root, ignore_errors=True)
        return 0
    except Exception:
        if not args.keep_raw:
            shutil.rmtree(capture_root, ignore_errors=True)
        raise


if __name__ == "__main__":
    sys.exit(main())
