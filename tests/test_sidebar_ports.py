#!/usr/bin/env python3
"""
End-to-end test for sidebar listening ports auto-detection.

This covers regressions where a listening server (e.g. `python3 -m http.server`)
doesn't show up in the sidebar ports row.

Run with a tagged instance to avoid unix socket conflicts:
  CMUX_TAG=<tag> python3 tests/test_sidebar_ports.py
"""

from __future__ import annotations

import os
import shutil
import socket
import subprocess
import sys
import time
from pathlib import Path

# Add the directory containing cmux.py to the path
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from cmux import cmux, cmuxError  # noqa: E402


# Historically, ports detection only checked a small allowlist. This test
# intentionally uses a port outside that set to avoid regressions where ports
# "work" only for the allowlist.
_HISTORICAL_ALLOWLIST = {8000, 8080, 8888, 5173, 3000, 3001, 5000, 5432}
_PREFERRED_BIND_HOST = "127.0.0.1"


def _parse_sidebar_state(text: str) -> dict[str, str]:
    data: dict[str, str] = {}
    for raw in (text or "").splitlines():
        line = raw.rstrip("\n")
        if not line or line.startswith("  "):
            continue
        if "=" not in line:
            continue
        k, v = line.split("=", 1)
        data[k.strip()] = v.strip()
    return data


def _wait_for(predicate, timeout: float, interval: float, label: str):
    start = time.time()
    last_error: Exception | None = None
    while time.time() - start < timeout:
        try:
            value = predicate()
            if value:
                return value
        except Exception as e:
            last_error = e
        time.sleep(interval)
    if last_error is not None:
        raise AssertionError(f"Timed out waiting for {label}. Last error: {last_error}")
    raise AssertionError(f"Timed out waiting for {label}.")


def _find_free_allowed_port() -> int:
    # Prefer a random ephemeral port to avoid flakiness from well-known ports
    # being grabbed by background services.
    for _ in range(50):
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            s.bind((_PREFERRED_BIND_HOST, 0))
            port = int(s.getsockname()[1])
            if port not in _HISTORICAL_ALLOWLIST:
                return port
        finally:
            try:
                s.close()
            except Exception:
                pass

    raise RuntimeError("Failed to find a free test port (outside historical allowlist).")


def _start_external_server(base: Path, port: int) -> subprocess.Popen:
    """
    Start an http.server outside cmuxterm and ensure it is actually listening.
    Retries are handled by the caller by picking a different port.
    """
    proc = subprocess.Popen(
        [sys.executable, "-m", "http.server", str(port), "--bind", _PREFERRED_BIND_HOST],
        cwd=str(base),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    _wait_for_lsof_listen_pid(port, expected_pid=proc.pid, timeout=6.0)
    return proc


def _wait_for_port(client: cmux, port: int, timeout: float = 18.0) -> dict[str, str]:
    def pred():
        state = _parse_sidebar_state(client.sidebar_state())
        raw = state.get("ports", "")
        if raw == "none" or not raw:
            return None
        ports = []
        for item in raw.split(","):
            item = item.strip()
            if not item:
                continue
            try:
                ports.append(int(item))
            except ValueError:
                continue
        return state if port in ports else None

    return _wait_for(pred, timeout=timeout, interval=0.15, label=f"ports include {port}")


def _wait_for_port_absent(client: cmux, port: int, timeout: float = 18.0) -> dict[str, str]:
    def pred():
        state = _parse_sidebar_state(client.sidebar_state())
        raw = state.get("ports", "")
        if raw == "none" or not raw:
            return state
        ports = []
        for item in raw.split(","):
            item = item.strip()
            if not item:
                continue
            try:
                ports.append(int(item))
            except ValueError:
                continue
        return state if port not in ports else None

    return _wait_for(pred, timeout=timeout, interval=0.15, label=f"ports do not include {port}")


def _assert_port_absent_for_duration(client: cmux, port: int, duration: float = 6.0, interval: float = 0.15) -> None:
    """
    Assert the port does not appear in sidebar_state during the full duration.
    This is important to catch "machine-wide ports" leaking into a fresh tab.
    """
    start = time.time()
    while time.time() - start < duration:
        state = _parse_sidebar_state(client.sidebar_state())
        raw = state.get("ports", "")
        if raw and raw != "none":
            try:
                ports = {int(p.strip()) for p in raw.split(",") if p.strip()}
            except ValueError:
                ports = set()
            if port in ports:
                raise AssertionError(f"Port {port} unexpectedly appeared in sidebar ports: {raw}")
        time.sleep(interval)


def _wait_for_lsof_listen_pid(port: int, expected_pid: int | None, timeout: float = 8.0) -> int:
    """
    Wait until `lsof -iTCP:<port> -sTCP:LISTEN` returns a pid.
    If expected_pid is provided, require that pid to be present.
    """

    def pred():
        result = subprocess.run(
            ["lsof", "-nP", f"-iTCP:{port}", "-sTCP:LISTEN", "-t"],
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            return None
        pids = []
        for line in (result.stdout or "").splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                pids.append(int(line))
            except ValueError:
                continue
        if not pids:
            return None
        if expected_pid is not None and expected_pid not in pids:
            return None
        return expected_pid if expected_pid is not None else pids[0]

    value = _wait_for(pred, timeout=timeout, interval=0.15, label=f"lsof LISTEN pid for {port}")
    return int(value)


def _wait_for_lsof_listen_gone(port: int, timeout: float = 8.0) -> None:
    def pred():
        result = subprocess.run(
            ["lsof", "-nP", f"-iTCP:{port}", "-sTCP:LISTEN", "-t"],
            capture_output=True,
            text=True,
        )
        return result.returncode != 0 or not (result.stdout or "").strip()

    _wait_for(pred, timeout=timeout, interval=0.15, label=f"lsof no LISTEN for {port}")


def main() -> int:
    tag = os.environ.get("CMUX_TAG") or os.environ.get("CMUXTERM_TAG") or ""
    if not tag:
        print("Tip: set CMUX_TAG=<tag> when running this test to avoid socket conflicts.")

    base = Path("/tmp") / f"cmux_ports_test_{os.getpid()}"
    pid_file = base / "server.pid"
    log_file = base / "server.log"
    external_proc: subprocess.Popen | None = None

    try:
        if base.exists():
            shutil.rmtree(base)
        base.mkdir(parents=True, exist_ok=True)

        # Start a listening server outside cmuxterm. A fresh tab should NOT show this port,
        # since ports should be attributed to the shell session in the tab.
        port = None
        last_start_err: Exception | None = None
        for _ in range(8):
            try:
                port = _find_free_allowed_port()
                external_proc = _start_external_server(base, port)
                break
            except Exception as e:
                last_start_err = e
                if external_proc is not None:
                    try:
                        external_proc.kill()
                    except Exception:
                        pass
                    external_proc = None
                continue
        if port is None or external_proc is None:
            raise RuntimeError(f"Failed to start external http.server. Last error: {last_start_err}")

        with cmux() as client:
            new_tab_id = client.new_tab()
            client.select_tab(new_tab_id)
            time.sleep(0.8)

            # Trigger a prompt cycle (and thus a ports scan burst) before checking absence.
            client.send("echo cmux_ports_test\n")
            _assert_port_absent_for_duration(client, port, duration=6.0)

            # Stop the external server, then reuse the port inside the tab.
            external_proc.terminate()
            try:
                external_proc.wait(timeout=3.0)
            except subprocess.TimeoutExpired:
                external_proc.kill()
            external_proc = None
            _wait_for_lsof_listen_gone(port, timeout=8.0)

            # Start a server in the background and capture its PID so we can clean up.
            client.send(f"rm -f {pid_file} {log_file}\n")
            client.send(
                f"python3 -m http.server {port} --bind {_PREFERRED_BIND_HOST} > {log_file} 2>&1 & echo $! > {pid_file}\n"
            )

            _wait_for(lambda: pid_file.exists(), timeout=4.0, interval=0.1, label="pid file")
            pid = int(pid_file.read_text(encoding="utf-8").strip())

            # Ensure the server is actually listening (sanity check + reduces flakiness).
            _wait_for_lsof_listen_pid(port, expected_pid=pid, timeout=8.0)

            # Wait for the sidebar to report the port.
            _wait_for_port(client, port, timeout=18.0)

            # Cleanup server.
            client.send(f"kill {pid} >/dev/null 2>&1 || true\n")

            _wait_for_lsof_listen_gone(port, timeout=8.0)
            _wait_for_port_absent(client, port, timeout=18.0)

            try:
                client.close_tab(new_tab_id)
            except Exception:
                pass

        print("Sidebar ports test passed.")
        return 0

    except (cmuxError, AssertionError, RuntimeError, ValueError) as e:
        print(f"Sidebar ports test failed: {e}")
        return 1
    finally:
        if external_proc is not None:
            try:
                external_proc.terminate()
                external_proc.wait(timeout=2.0)
            except Exception:
                try:
                    external_proc.kill()
                except Exception:
                    pass
        try:
            shutil.rmtree(base)
        except Exception:
            pass


if __name__ == "__main__":
    raise SystemExit(main())
