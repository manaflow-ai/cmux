from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any


AUTH_BRIDGE_BACKEND = "cmux_auth_core_bridge"
AUTH_LOCAL_BACKEND = "linux_local_state"


def auth_bridge_command(bridge_path: str | Path) -> list[str]:
    path = Path(bridge_path)
    return [str(path), "auth-bridge"] if path.name == "cmux" else [str(path)]


def bundled_auth_bridge_path() -> Path:
    return (Path(__file__).resolve().parents[2] / "bin" / "cmux").resolve()


def repo_auth_bridge_path() -> Path:
    return (Path(__file__).resolve().parents[3] / "CLI" / ".build" / "release" / "cmux").resolve()


def auth_bridge_candidates() -> list[Path]:
    explicit = os.environ.get("CMUX_LINUX_AUTH_BRIDGE") or os.environ.get("CMUX_AUTH_BRIDGE")
    if explicit:
        return [Path(explicit).expanduser()]
    return [bundled_auth_bridge_path(), repo_auth_bridge_path()]


def auth_bridge_candidate_is_script(path: Path) -> bool:
    try:
        with path.open("rb") as handle:
            return handle.read(2) == b"#!"
    except OSError:
        return False


def find_auth_bridge_binary() -> Path | None:
    explicit = os.environ.get("CMUX_LINUX_AUTH_BRIDGE") or os.environ.get("CMUX_AUTH_BRIDGE")
    for candidate in auth_bridge_candidates():
        if candidate.is_file() and os.access(candidate, os.X_OK):
            if explicit is None and auth_bridge_candidate_is_script(candidate):
                continue
            return candidate.resolve()
    return None


def build_auth_bridge_invocation(bridge_path: str | Path, method: str, params: dict[str, Any]) -> dict[str, Any]:
    request = {"method": method, "params": dict(params)}
    return {
        "command": auth_bridge_command(bridge_path),
        "stdin": json.dumps(request, separators=(",", ":")).encode("utf-8"),
    }


def normalize_auth_bridge_result(value: dict[str, Any]) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ValueError("auth_bridge_returned_non_object")
    result = value.get("result", value)
    if not isinstance(result, dict):
        raise ValueError("auth_bridge_result_returned_non_object")
    signed_in = bool(result.get("signed_in") or result.get("authenticated"))
    return {
        "signed_in": signed_in,
        "authenticated": signed_in,
        "required": False,
        "is_restoring_session": False,
        "is_loading": False,
        "timed_out": False,
        "user": None,
        "teams": [],
        "selected_team_id": None,
        "detail": "auth_bridge_available",
        **result,
        "platform": "linux",
        "backend": AUTH_BRIDGE_BACKEND,
        "mode": "bridge",
    }


def build_local_auth_status_payload(
    *,
    signed_in: bool,
    signed_in_at: float | None,
    timed_out: bool,
    detail: str,
) -> dict[str, Any]:
    return {
        "signed_in": signed_in,
        "authenticated": signed_in,
        "required": False,
        "is_restoring_session": False,
        "is_loading": False,
        "timed_out": timed_out,
        "user": None,
        "teams": [],
        "selected_team_id": None,
        "platform": "linux",
        "backend": AUTH_LOCAL_BACKEND,
        "mode": "local_fallback",
        "detail": detail,
        "signed_in_at": signed_in_at,
    }
