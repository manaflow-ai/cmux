#!/usr/bin/env python3
"""Process-level integration: cmuxd-remote stdio session resize coordinator."""

from __future__ import annotations

import json
import select
import shutil
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmuxError


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _daemon_module_dir() -> Path:
    return Path(__file__).resolve().parents[1] / "daemon" / "remote"


def _rpc(
    proc: subprocess.Popen[str],
    req_id: int,
    method: str,
    params: dict,
    *,
    timeout_s: float = 5.0,
) -> dict:
    if proc.stdin is None or proc.stdout is None:
        raise cmuxError("daemon subprocess stdio pipes are not available")

    payload = {"id": req_id, "method": method, "params": params}
    proc.stdin.write(json.dumps(payload, separators=(",", ":")) + "\n")
    proc.stdin.flush()

    deadline = time.time() + timeout_s
    while time.time() < deadline:
        wait_s = max(0.0, min(0.2, deadline - time.time()))
        ready, _, _ = select.select([proc.stdout], [], [], wait_s)
        if not ready:
            continue
        line = proc.stdout.readline()
        if line == "":
            stderr = ""
            if proc.stderr is not None:
                try:
                    stderr = proc.stderr.read().strip()
                except Exception:
                    stderr = ""
            raise cmuxError(f"cmuxd-remote exited while waiting for {method} response: {stderr}")
        try:
            resp = json.loads(line)
        except Exception as exc:  # noqa: BLE001
            raise cmuxError(f"Invalid JSON response for {method}: {line!r} ({exc})")
        _must(resp.get("id") == req_id, f"Response id mismatch for {method}: {resp}")
        return resp

    raise cmuxError(f"Timed out waiting for cmuxd-remote response: {method}")


def _as_int(value: object, field: str) -> int:
    if isinstance(value, bool):
        raise cmuxError(f"{field} should be numeric, got bool")
    if isinstance(value, int):
        return value
    if isinstance(value, float):
        if not value.is_integer():
            raise cmuxError(f"{field} should be an integer value, got float {value!r}")
        return int(value)
    raise cmuxError(f"{field} has unexpected type {type(value).__name__}: {value!r}")


def _assert_effective(resp: dict, want_cols: int, want_rows: int, label: str) -> None:
    _must(resp.get("ok") is True, f"{label} should return ok=true: {resp}")
    result = resp.get("result") or {}
    got_cols = _as_int(result.get("effective_cols"), "effective_cols")
    got_rows = _as_int(result.get("effective_rows"), "effective_rows")
    _must(
        got_cols == want_cols and got_rows == want_rows,
        f"{label} effective size mismatch: got {got_cols}x{got_rows}, want {want_cols}x{want_rows} ({resp})",
    )


def main() -> int:
    if shutil.which("go") is None:
        print("SKIP: go is not available")
        return 0

    daemon_dir = _daemon_module_dir()
    _must(daemon_dir.is_dir(), f"Missing daemon module directory: {daemon_dir}")

    proc = subprocess.Popen(
        ["go", "run", "./cmd/cmuxd-remote", "serve", "--stdio"],
        cwd=str(daemon_dir),
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )

    try:
        hello = _rpc(proc, 1, "hello", {})
        _must(hello.get("ok") is True, f"hello should return ok=true: {hello}")
        capabilities = {str(item) for item in ((hello.get("result") or {}).get("capabilities") or [])}
        _must("session.basic" in capabilities, f"hello missing session.basic capability: {hello}")
        _must("session.resize.min" in capabilities, f"hello missing session.resize.min capability: {hello}")

        open_resp = _rpc(proc, 2, "session.open", {"session_id": "sess-e2e"})
        _assert_effective(open_resp, 0, 0, "session.open")

        attach_small = _rpc(
            proc,
            3,
            "session.attach",
            {"session_id": "sess-e2e", "attachment_id": "a-small", "cols": 90, "rows": 30},
        )
        _assert_effective(attach_small, 90, 30, "session.attach(a-small)")

        attach_large = _rpc(
            proc,
            4,
            "session.attach",
            {"session_id": "sess-e2e", "attachment_id": "a-large", "cols": 140, "rows": 50},
        )
        _assert_effective(attach_large, 90, 30, "session.attach(a-large)")

        resize_large = _rpc(
            proc,
            5,
            "session.resize",
            {"session_id": "sess-e2e", "attachment_id": "a-large", "cols": 200, "rows": 80},
        )
        _assert_effective(resize_large, 90, 30, "session.resize(a-large)")

        detach_small = _rpc(
            proc,
            6,
            "session.detach",
            {"session_id": "sess-e2e", "attachment_id": "a-small"},
        )
        _assert_effective(detach_small, 200, 80, "session.detach(a-small)")

        detach_large = _rpc(
            proc,
            7,
            "session.detach",
            {"session_id": "sess-e2e", "attachment_id": "a-large"},
        )
        _assert_effective(detach_large, 200, 80, "session.detach(a-large)")

        reattach = _rpc(
            proc,
            8,
            "session.attach",
            {"session_id": "sess-e2e", "attachment_id": "a-reconnect", "cols": 110, "rows": 40},
        )
        _assert_effective(reattach, 110, 40, "session.attach(a-reconnect)")

        status = _rpc(proc, 9, "session.status", {"session_id": "sess-e2e"})
        _assert_effective(status, 110, 40, "session.status")
        attachments = (status.get("result") or {}).get("attachments") or []
        _must(len(attachments) == 1, f"session.status should report one active attachment after reattach: {status}")

        print("PASS: cmuxd-remote stdio session.resize coordinator enforces smallest-screen-wins semantics")
        return 0
    finally:
        try:
            if proc.stdin is not None:
                proc.stdin.close()
        except Exception:
            pass
        try:
            proc.terminate()
            proc.wait(timeout=2.0)
        except Exception:
            try:
                proc.kill()
            except Exception:
                pass


if __name__ == "__main__":
    raise SystemExit(main())
