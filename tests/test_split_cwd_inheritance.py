#!/usr/bin/env python3
"""
End-to-end test for split CWD inheritance.

Verifies that new split panes and new workspace tabs inherit the current
working directory from the source terminal.

Requires:
  - cmux running with allowAll socket mode
  - bash shell integration sourced (cmux-bash-integration.bash)

Run with a tagged instance:
  CMUX_TAG=<tag> python3 tests/test_split_cwd_inheritance.py
"""

from __future__ import annotations

import os
import sys
import time
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from cmux import cmux  # noqa: E402


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
    extra = ""
    if last_error is not None:
        extra = f" Last error: {last_error}"
    raise AssertionError(f"Timed out waiting for {label}.{extra}")


def _wait_for_focused_cwd(
    client: cmux,
    expected: str,
    timeout: float = 12.0,
    panel: str | None = None,
    tab: str | None = None,
) -> dict[str, str]:
    """Wait for focused_cwd to match expected.

    If panel is given, also require that focused_panel matches that panel.
    If tab is given, also require that the selected tab matches that tab.
    """
    def pred():
        state = _parse_sidebar_state(client.sidebar_state())
        cwd = state.get("focused_cwd", "")
        if cwd != expected:
            return None
        if panel and state.get("focused_panel", "") != panel:
            return None
        if tab and state.get("tab", "") != tab:
            return None
        return state
    label = f"focused_cwd={expected!r}"
    if panel:
        label += f" (panel == {panel})"
    if tab:
        label += f" (tab == {tab})"
    return _wait_for(pred, timeout=timeout, interval=0.3, label=label)


def _send_cd_and_wait(
    client: cmux,
    target: str,
    timeout: float = 12.0,
    surface: str | int | None = None,
) -> dict[str, str]:
    """cd to target and wait for sidebar focused_cwd to reflect it."""
    if surface is None:
        client.send(f"cd {target}\n")
    else:
        client.send_surface(surface, f"cd {target}\n")
    return _wait_for_focused_cwd(client, target, timeout=timeout)


def _focus_first_surface(client: cmux) -> str:
    surfaces = client.list_surfaces()
    if not surfaces:
        raise AssertionError("Current tab has no surfaces")
    surface_id = surfaces[0][1]
    client.focus_surface(surface_id)
    return surface_id


def main() -> int:
    tag = os.environ.get("CMUX_TAG", "")

    socket_path = None
    if tag:
        socket_path = f"/tmp/cmux-debug-{tag}.sock"
    client = cmux(socket_path=socket_path)
    client.connect()

    # Use resolved paths to avoid /tmp -> /private/tmp symlink mismatch on macOS
    test_dir_a = str(Path("/tmp/cmux_split_cwd_test_a").resolve())
    test_dir_b = str(Path("/tmp/cmux_split_cwd_test_b").resolve())
    os.makedirs(test_dir_a, exist_ok=True)
    os.makedirs(test_dir_b, exist_ok=True)

    passed = 0
    failed = 0

    def check(name: str, condition: bool, detail: str = ""):
        nonlocal passed, failed
        if condition:
            print(f"  PASS  {name}")
            passed += 1
        else:
            print(f"  FAIL  {name}{': ' + detail if detail else ''}")
            failed += 1

    print("=== Split CWD Inheritance Tests ===")

    print("  [setup] creating isolated workspace tab...")
    setup_tab = client.new_tab()
    client.select_tab(setup_tab)
    time.sleep(1.0)
    setup_surface = _focus_first_surface(client)
    time.sleep(0.5)

    # --- Setup: cd to test_dir_a in workspace 1 ---
    print("  [setup] cd to test_dir_a and wait for shell integration...")
    _send_cd_and_wait(client, test_dir_a, surface=setup_surface)
    state = _parse_sidebar_state(client.sidebar_state())
    check("setup: focused_cwd is test_dir_a", state.get("focused_cwd") == test_dir_a,
          f"got {state.get('focused_cwd')!r}")

    # --- Test 1: New split inherits test_dir_a ---
    print("  [test1] creating right split from test_dir_a...")
    split_result = client.new_split("right")
    if not split_result:
        check("split created", False)
        print(f"\n{passed} passed, {failed} failed")
        client.close()
        return 1
    check("split created", True)

    # Socket split commands should not steal focus; focus the returned pane
    # explicitly, then assert that pane inherited the source cwd.
    new_panel = split_result.strip()
    client.focus_surface_by_panel(new_panel)
    time.sleep(4)  # wait for new bash to start + run PROMPT_COMMAND
    try:
        state = _wait_for_focused_cwd(
            client, test_dir_a, timeout=15.0, panel=new_panel,
        )
        check("test1: split inherited test_dir_a",
              state.get("focused_cwd") == test_dir_a,
              f"focused_cwd={state.get('focused_cwd')!r}")
    except AssertionError:
        state = _parse_sidebar_state(client.sidebar_state())
        check("test1: split inherited test_dir_a", False,
              f"focused_cwd={state.get('focused_cwd')!r}, focused_panel={state.get('focused_panel')!r}")

    # --- Test 2: New workspace tab inherits CWD ---
    # First cd to test_dir_b so we have a different dir to inherit
    print("  [test2] cd to test_dir_b, then creating new workspace tab...")
    _send_cd_and_wait(client, test_dir_b)

    tab_result = client.new_tab()
    if not tab_result:
        check("new tab created", False)
        print(f"\n{passed} passed, {failed} failed")
        client.close()
        return 1
    check("new tab created", True)

    # Focus the returned workspace explicitly, then assert it inherited cwd.
    new_tab = tab_result.strip()
    client.select_tab(new_tab)
    time.sleep(4)
    try:
        state = _wait_for_focused_cwd(
            client, test_dir_b, timeout=15.0, tab=new_tab,
        )
        check("test2: new workspace inherited test_dir_b",
              state.get("focused_cwd") == test_dir_b,
              f"focused_cwd={state.get('focused_cwd')!r}")
    except AssertionError:
        state = _parse_sidebar_state(client.sidebar_state())
        check("test2: new workspace inherited test_dir_b", False,
              f"focused_cwd={state.get('focused_cwd')!r}, tab={state.get('tab')!r}")

    print(f"\n{passed} passed, {failed} failed")

    client.close()

    # Cleanup
    for d in [test_dir_a, test_dir_b]:
        try:
            os.rmdir(d)
        except OSError:
            pass

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
