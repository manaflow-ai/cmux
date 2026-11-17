"""The signed-in account's cached Claude login, for an unattended run's own app (cloud-chat-proof.py and
cloud-chat-matrix.py on CI).

A Cloud start gives the machine the person's Claude login when cmux holds one for the account
(harness_login.rs `step_and_reason`: a cached login installs on a DEV build with no prompt, and on a Release
build once the one-time consent says yes). The app keeps that login in the login Keychain under the
`cmux-cloud-secret` service, written by `cmux cloud secret set NAME` (CloudCredentialLogin.swift: `name`,
`store`, `load`). CI has no person to run `claude setup-token`, so the run stores the agent test account's
`CLAUDE_CODE_OAUTH_TOKEN` (a repository secret) there itself, the way the app would, and removes it when
it ends. The token is read from the environment only, goes to the CLI on stdin only, and is never printed.
"""
from __future__ import annotations

import base64
import hashlib
import json
import subprocess
import time

TOKEN_ENV = "CLAUDE_CODE_OAUTH_TOKEN"


def token_from(env) -> str:
    return (env.get(TOKEN_ENV) or "").strip()


def valid(token: str) -> bool:
    """CloudCredentialTransfer.validate's Claude rule: a `claude setup-token` login, printable ASCII."""
    return (token.startswith("sk-ant-oat01-") and 32 <= len(token) <= 12_000
            and all(32 < ord(c) < 127 for c in token))


def name(user_id: str, team_id: str | None) -> str:
    """CloudCredentialLogin.name for Claude: the first 12 bytes of sha256("user:team-or-personal:"), in hex."""
    scope = hashlib.sha256(f"{user_id}:{team_id or 'personal'}:".encode()).digest()[:12].hex()
    return f"CLAUDE_TRANSFER_{scope}"


def names(status: dict) -> list[str]:
    """The entries a start reads for the account `auth.status` names: its team's, then its personal scope.
    Empty when the status names no user."""
    user_id = status.get("user_id")
    if not isinstance(user_id, str) or not user_id:
        return []
    team = status.get("team_id") if isinstance(status.get("team_id"), str) and status.get("team_id") else None
    return list(dict.fromkeys([name(user_id, team), name(user_id, None)]))


def envelope(token: str, now: float | None = None) -> str:
    """CloudCredentialLogin.store's envelope: {"created": T, "credential": BASE64}."""
    return json.dumps({"created": now if now is not None else time.time(),
                       "credential": base64.b64encode(token.encode()).decode()}, separators=(",", ":"))


def store(cli: str, env: dict, entry: str, token: str, timeout: int = 70) -> tuple[int, str]:
    """`cmux cloud secret set ENTRY` with the envelope on stdin. (exit code, stderr)."""
    try:
        done = subprocess.run([cli, "cloud", "secret", "set", entry], env=env, input=envelope(token),
                              capture_output=True, text=True, timeout=timeout)
        return done.returncode, done.stderr
    except subprocess.TimeoutExpired:
        return 124, f"timed out after {timeout}s"


def remove(cli: str, env: dict, entry: str, timeout: int = 30) -> tuple[int, str]:
    """`cmux cloud secret rm ENTRY`. (exit code, stderr)."""
    try:
        done = subprocess.run([cli, "cloud", "secret", "rm", entry], env=env, capture_output=True, text=True,
                              timeout=timeout)
        return done.returncode, done.stderr
    except subprocess.TimeoutExpired:
        return 124, f"timed out after {timeout}s"
