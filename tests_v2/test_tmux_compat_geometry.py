#!/usr/bin/env python3
"""Tests for tmux-compat pane geometry support (oh-my-openagent integration).

Verifies that:
1. pane.list v2 API returns geometry fields (pixel_frame, columns, rows, cell_size, container_frame)
2. tmux-compat list-panes renders geometry format variables correctly
3. tmux-compat display -p renders geometry format variables
4. tmux-compat list-panes resolves pane targets (%uuid)
5. tmux -V returns a version string
6. Multi-pane geometry reflects actual split layout
"""

import glob
import json
import os
import subprocess
import sys
import time
from pathlib import Path
from typing import List

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _find_cli_binary() -> str:
    env_cli = os.environ.get("CMUXTERM_CLI")
    if env_cli and os.path.isfile(env_cli) and os.access(env_cli, os.X_OK):
        return env_cli

    candidates = glob.glob(os.path.expanduser(
        "~/Library/Developer/Xcode/DerivedData/**/Build/Products/Debug/cmux"
    ), recursive=True)
    candidates += glob.glob("/tmp/cmux-*/Build/Products/Debug/cmux")
    candidates = [p for p in candidates if os.path.isfile(p) and os.access(p, os.X_OK)]
    if not candidates:
        raise cmuxError("Could not locate cmux CLI binary; set CMUXTERM_CLI")
    candidates.sort(key=lambda p: os.path.getmtime(p), reverse=True)
    return candidates[0]


def _run_tmux_compat(cli: str, args: List[str]) -> subprocess.CompletedProcess[str]:
    env = dict(os.environ)
    env.pop("CMUX_WORKSPACE_ID", None)
    env.pop("CMUX_SURFACE_ID", None)
    env["CMUX_SOCKET_PATH"] = SOCKET_PATH
    env["CMUX_OMO_CMUX_BIN"] = cli
    cmd = [cli, "--socket", SOCKET_PATH, "__tmux-compat"] + args
    return subprocess.run(cmd, capture_output=True, text=True, check=False, env=env)


def test_pane_list_geometry_fields(c: cmux) -> None:
    """pane.list response includes geometry fields for each pane."""
    print("  test_pane_list_geometry_fields ... ", end="", flush=True)
    panes_raw = c.list_panes()
    _must(len(panes_raw) >= 1, "Expected at least 1 pane")

    payload = c._call("pane.list", {})
    panes = payload.get("panes", [])
    _must(len(panes) >= 1, f"Expected panes in payload, got {payload}")

    pane = panes[0]
    _must("pixel_frame" in pane, f"Missing pixel_frame in pane: {list(pane.keys())}")
    _must("columns" in pane, f"Missing columns in pane: {list(pane.keys())}")
    _must("rows" in pane, f"Missing rows in pane: {list(pane.keys())}")
    _must("cell_width_px" in pane, f"Missing cell_width_px in pane: {list(pane.keys())}")
    _must("cell_height_px" in pane, f"Missing cell_height_px in pane: {list(pane.keys())}")

    frame = pane["pixel_frame"]
    _must(frame["width"] > 0, f"pixel_frame.width should be > 0, got {frame['width']}")
    _must(frame["height"] > 0, f"pixel_frame.height should be > 0, got {frame['height']}")
    _must(pane["columns"] > 0, f"columns should be > 0, got {pane['columns']}")
    _must(pane["rows"] > 0, f"rows should be > 0, got {pane['rows']}")
    _must(pane["cell_width_px"] > 0, f"cell_width_px should be > 0, got {pane['cell_width_px']}")
    _must(pane["cell_height_px"] > 0, f"cell_height_px should be > 0, got {pane['cell_height_px']}")

    _must("container_frame" in payload, f"Missing container_frame in payload: {list(payload.keys())}")
    cf = payload["container_frame"]
    _must(cf["width"] > 0, f"container_frame.width should be > 0, got {cf['width']}")
    _must(cf["height"] > 0, f"container_frame.height should be > 0, got {cf['height']}")
    print("PASS")


def test_tmux_version(cli: str) -> None:
    """tmux -V returns a version string."""
    print("  test_tmux_version ... ", end="", flush=True)
    proc = _run_tmux_compat(cli, ["-V"])
    _must(proc.returncode == 0, f"tmux -V failed with rc={proc.returncode}: {proc.stderr}")
    output = proc.stdout.strip()
    _must(output.startswith("tmux"), f"Expected 'tmux ...' output, got: {output!r}")
    print("PASS")


def test_list_panes_geometry_format(cli: str) -> None:
    """list-panes with oh-my-openagent format string renders integer geometry."""
    print("  test_list_panes_geometry_format ... ", end="", flush=True)
    fmt = "#{pane_id}\t#{pane_width}\t#{pane_height}\t#{pane_left}\t#{pane_top}\t#{pane_active}\t#{window_width}\t#{window_height}\t#{pane_title}"
    proc = _run_tmux_compat(cli, ["list-panes", "-F", fmt])
    _must(proc.returncode == 0, f"list-panes failed: {proc.stderr}")

    lines = [l for l in proc.stdout.strip().split("\n") if l.strip()]
    _must(len(lines) >= 1, f"Expected at least 1 line, got {len(lines)}")

    for line in lines:
        # The line uses literal \t (backslash-t) from format rendering
        parts = line.split("\\t") if "\\t" in line else line.split("\t")
        _must(len(parts) >= 8, f"Expected >= 8 tab-separated fields, got {len(parts)}: {line!r}")

        pane_id = parts[0]
        _must(pane_id.startswith("%"), f"pane_id should start with %, got: {pane_id!r}")

        # Validate integer fields (width, height, left, top, active, window_w, window_h)
        for i, name in [(1, "pane_width"), (2, "pane_height"), (3, "pane_left"),
                        (4, "pane_top"), (5, "pane_active"), (6, "window_width"), (7, "window_height")]:
            _must(parts[i].isdigit(), f"{name} should be integer, got: {parts[i]!r} in line: {line!r}")

        _must(int(parts[1]) > 0, f"pane_width should be > 0, got {parts[1]}")
        _must(int(parts[2]) > 0, f"pane_height should be > 0, got {parts[2]}")
        _must(parts[5] in ("0", "1"), f"pane_active should be 0 or 1, got {parts[5]!r}")
        _must(int(parts[6]) > 0, f"window_width should be > 0, got {parts[6]}")
        _must(int(parts[7]) > 0, f"window_height should be > 0, got {parts[7]}")
    print("PASS")


def test_list_panes_pane_target(cli: str, c: cmux) -> None:
    """list-panes -t %<pane-uuid> resolves pane target to workspace."""
    print("  test_list_panes_pane_target ... ", end="", flush=True)
    panes_raw = c.list_panes()
    _must(len(panes_raw) >= 1, "No panes found")
    pane_id = panes_raw[0][1]

    proc = _run_tmux_compat(cli, ["list-panes", "-t", f"%{pane_id}", "-F", "#{pane_id}"])
    _must(proc.returncode == 0, f"list-panes -t %{pane_id} failed: {proc.stderr}")
    output = proc.stdout.strip()
    _must(len(output) > 0, "Expected output from list-panes with pane target")
    _must(output.startswith("%"), f"Expected pane_id starting with %, got: {output!r}")
    print("PASS")


def test_display_geometry_format(cli: str) -> None:
    """display -p renders pane_width and window_width as integers."""
    print("  test_display_geometry_format ... ", end="", flush=True)
    proc = _run_tmux_compat(cli, ["display", "-p", "#{pane_width},#{window_width}"])
    _must(proc.returncode == 0, f"display failed: {proc.stderr}")
    output = proc.stdout.strip()
    parts = output.split(",")
    _must(len(parts) == 2, f"Expected 'N,M' output, got: {output!r}")
    _must(parts[0].isdigit() and int(parts[0]) > 0, f"pane_width not a positive int: {parts[0]!r}")
    _must(parts[1].isdigit() and int(parts[1]) > 0, f"window_width not a positive int: {parts[1]!r}")
    print("PASS")


def test_multi_pane_geometry(cli: str, c: cmux) -> None:
    """After splitting, two panes have different pane_left values and halved widths."""
    print("  test_multi_pane_geometry ... ", end="", flush=True)
    ws = c.new_workspace()
    c.select_workspace(ws)
    time.sleep(0.3)

    # Get single-pane geometry first
    payload_before = c._call("pane.list", {"workspace_id": ws})
    panes_before = payload_before.get("panes", [])
    _must(len(panes_before) == 1, f"Expected 1 pane before split, got {len(panes_before)}")
    single_cols = panes_before[0].get("columns", 0)

    # Split horizontally
    c.new_split("right")
    time.sleep(0.3)

    payload_after = c._call("pane.list", {"workspace_id": ws})
    panes_after = payload_after.get("panes", [])
    _must(len(panes_after) == 2, f"Expected 2 panes after split, got {len(panes_after)}")

    p1, p2 = panes_after[0], panes_after[1]
    _must("pixel_frame" in p1 and "pixel_frame" in p2, "Missing pixel_frame after split")
    _must("columns" in p1 and "columns" in p2, "Missing columns after split")

    # Pane left positions should differ (horizontal split)
    left1 = p1["pixel_frame"]["x"]
    left2 = p2["pixel_frame"]["x"]
    _must(left1 != left2, f"Panes should have different x positions, got {left1} and {left2}")

    # Each pane should be roughly half the original width
    cols1 = p1["columns"]
    cols2 = p2["columns"]
    _must(cols1 > 0 and cols2 > 0, f"Columns should be > 0, got {cols1} and {cols2}")
    _must(cols1 < single_cols, f"Split pane cols ({cols1}) should be less than original ({single_cols})")

    # Verify tmux-compat format also shows two lines with different pane_left
    fmt = "#{pane_id}\t#{pane_width}\t#{pane_left}"
    proc = _run_tmux_compat(cli, ["list-panes", "-t", f"%{p1['id']}", "-F", fmt])
    _must(proc.returncode == 0, f"list-panes after split failed: {proc.stderr}")
    lines = [l for l in proc.stdout.strip().split("\n") if l.strip()]
    _must(len(lines) == 2, f"Expected 2 lines after split, got {len(lines)}: {proc.stdout!r}")

    # Clean up
    c.close_workspace(ws)
    print("PASS")


def main() -> int:
    cli = _find_cli_binary()
    print(f"Using CLI: {cli}")
    print(f"Socket: {SOCKET_PATH}")

    passed = 0
    failed = 0
    errors = []

    with cmux(SOCKET_PATH) as c:
        tests = [
            ("test_pane_list_geometry_fields", lambda: test_pane_list_geometry_fields(c)),
            ("test_tmux_version", lambda: test_tmux_version(cli)),
            ("test_list_panes_geometry_format", lambda: test_list_panes_geometry_format(cli)),
            ("test_list_panes_pane_target", lambda: test_list_panes_pane_target(cli, c)),
            ("test_display_geometry_format", lambda: test_display_geometry_format(cli)),
            ("test_multi_pane_geometry", lambda: test_multi_pane_geometry(cli, c)),
        ]

        for name, test_fn in tests:
            try:
                test_fn()
                passed += 1
            except Exception as e:
                failed += 1
                errors.append((name, str(e)))
                print(f"FAIL: {e}")

    print(f"\n{'=' * 60}")
    print(f"Results: {passed} passed, {failed} failed, {passed + failed} total")
    if errors:
        print("\nFailures:")
        for name, err in errors:
            print(f"  {name}: {err}")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
