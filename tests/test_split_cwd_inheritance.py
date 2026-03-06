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
    exclude_panel: str | None = None,
) -> dict[str, str]:
    """Wait for focused_cwd to match expected.

    If exclude_panel is given, also require that focused_panel differs from
    that value — ensuring we're checking the *new* pane, not the original.
    """
    def pred():
        state = _parse_sidebar_state(client.sidebar_state())
        cwd = state.get("focused_cwd", "")
        if cwd != expected:
            return None
        if exclude_panel and state.get("focused_panel", "") == exclude_panel:
            return None
        return state
    label = f"focused_cwd={expected!r}"
    if exclude_panel:
        label += f" (panel != {exclude_panel})"
    return _wait_for(pred, timeout=timeout, interval=0.3, label=label)


def _send_cd_and_wait(
    client: cmux,
    target: str,
    timeout: float = 12.0,
) -> dict[str, str]:
    """cd to target and wait for sidebar focused_cwd to reflect it."""
    client.send(f"cd {target}\n")
    return _wait_for_focused_cwd(client, target, timeout=timeout)


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

    # --- Setup: cd to test_dir_a in workspace 1 ---
    print("  [setup] cd to test_dir_a and wait for shell integration...")
    _send_cd_and_wait(client, test_dir_a)
    state = _parse_sidebar_state(client.sidebar_state())
    check("setup: focused_cwd is test_dir_a", state.get("focused_cwd") == test_dir_a,
          f"got {state.get('focused_cwd')!r}")

    # --- Test 1: New split inherits test_dir_a ---
    print("  [test1] creating right split from test_dir_a...")
    # Record the original panel so we can verify focus moves to the NEW pane.
    original_panel = state.get("focused_panel", "")
    split_result = client.new_split("right")
    if not split_result:
        check("split created", False)
        print(f"\n{passed} passed, {failed} failed")
        client.close()
        return 1
    check("split created", True)

    # Wait for the NEW pane (different panel ID) to report test_dir_a.
    time.sleep(4)  # wait for new bash to start + run PROMPT_COMMAND
    try:
        state = _wait_for_focused_cwd(
            client, test_dir_a, timeout=15.0, exclude_panel=original_panel,
        )
        new_panel = state.get("focused_panel", "")
        check("test1: focus moved to new pane", new_panel != original_panel,
              f"original={original_panel!r}, current={new_panel!r}")
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
    state = _parse_sidebar_state(client.sidebar_state())
    original_tab = state.get("tab", "")

    tab_result = client.new_tab()
    if not tab_result:
        check("new tab created", False)
        print(f"\n{passed} passed, {failed} failed")
        client.close()
        return 1
    check("new tab created", True)

    # New workspace should be a different tab AND inherit test_dir_b
    time.sleep(4)
    try:
        def _new_tab_with_cwd():
            s = _parse_sidebar_state(client.sidebar_state())
            tab_id = s.get("tab", "")
            cwd = s.get("focused_cwd", "")
            if tab_id != original_tab and cwd == test_dir_b:
                return s
            return None

        state = _wait_for(
            _new_tab_with_cwd, timeout=15.0, interval=0.3,
            label=f"new tab with focused_cwd={test_dir_b!r}",
        )
        check("test2: focus moved to new tab", state.get("tab") != original_tab,
              f"original={original_tab!r}, current={state.get('tab')!r}")
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
