#!/usr/bin/env python3
"""
Regression: report_ports/report_pwd must validate panel IDs.

If shell-integration hooks fire late (after a split is closed) they can report
ports/cwd for a stale surface UUID. These updates should not pollute the sidebar
state (stale ports/cwd).

Run with a tagged instance to avoid unix socket conflicts:
  CMUX_TAG=<tag> python3 tests/test_sidebar_invalid_panel.py
"""

from __future__ import annotations

import os
import random
import subprocess
import sys
import time
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from cmux import cmux, cmuxError  # noqa: E402


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


def _parse_ports(raw: str) -> set[int]:
    raw = (raw or "").strip()
    if not raw or raw == "none":
        return set()
    ports: set[int] = set()
    for item in raw.split(","):
        item = item.strip()
        if not item:
            continue
        try:
            ports.add(int(item))
        except ValueError:
            continue
    return ports


def _pick_absent_port(exclude: set[int]) -> int:
    # Pick a random port that isn't already showing and also isn't currently
    # listening machine-wide (avoid false failures if something is bound).
    for _ in range(200):
        port = random.randint(20000, 65000)
        if port in exclude:
            continue
        result = subprocess.run(
            ["lsof", "-nP", f"-iTCP:{port}", "-sTCP:LISTEN", "-t"],
            capture_output=True,
            text=True,
        )
        if result.returncode != 0 and not (result.stdout or "").strip():
            return port
    # Fall back to a fixed high port; still validate against exclude.
    for port in (54321, 54322, 54323, 61999):
        if port not in exclude:
            return port
    return 65000


def main() -> int:
    try:
        with cmux() as client:
            tab_id = client.new_tab()
            client.select_tab(tab_id)
            time.sleep(0.8)

            initial_state = client.sidebar_state(tab_id)
            initial_ports = _parse_ports(_parse_sidebar_state(initial_state).get("ports", ""))
            test_port = _pick_absent_port(initial_ports)

            surface_ids = {surface_id for _, surface_id, _ in client.list_surfaces(tab_id)}
            fake_panel = uuid.uuid4()
            while str(fake_panel) in surface_ids:
                fake_panel = uuid.uuid4()

            # Ports: reporting against a bogus panel must not update the union.
            client._send_command(f"report_ports {test_port} --tab={tab_id} --panel={fake_panel}")
            time.sleep(0.3)
            state = client.sidebar_state(tab_id)
            ports = _parse_ports(_parse_sidebar_state(state).get("ports", ""))
            if test_port in ports:
                print(f"FAIL: invalid panel report_ports leaked into sidebar ports: {ports}")
                return 1

            # CWD: reporting against a bogus panel must not set cwd to that value.
            unique_dir = f"/tmp/cmux_invalid_pwd_{os.getpid()}"
            client._send_command(f"report_pwd {unique_dir} --tab={tab_id} --panel={fake_panel}")
            time.sleep(0.3)
            state = client.sidebar_state(tab_id)
            if unique_dir in state:
                print("FAIL: invalid panel report_pwd leaked into sidebar_state")
                print(state)
                return 1

            try:
                client.close_tab(tab_id)
            except cmuxError:
                pass

        print("PASS: invalid panel reports do not pollute sidebar metadata")
        return 0

    except (cmuxError, RuntimeError, ValueError) as e:
        print(f"FAIL: {e}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

