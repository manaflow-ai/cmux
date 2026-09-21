#!/usr/bin/env python3
"""Live divider matrix: two round trips in each axis with pane-size assertions.

Run only on an isolated GUI Mac with the tagged app and its helper running.
Prepare two workspaces, each containing exactly two terminal panes: one split
right and one split down. Snapshot each window with the helper before choosing
coordinates. --plan is a JSON object with horizontal and vertical entries:
{"horizontal": {"workspace": "UUID", "from": [500, 300], "to": [600, 300]},
 "vertical": {"workspace": "UUID", "from": [500, 300], "to": [500, 400]}}
The example coordinates are illustrative; use observed screenshot pixels.

Pass --driver/--socket/--feed/--pid/--window-id as for test_cmux_cua_drag_cursor.py,
plus --cmux-cli, --cmux-socket, --plan and --out-dir. The suite selects each
workspace, runs both directions twice through that shared drag harness, and
retains each cursor trace and the before/after pane geometry in summary.json.
It does not build, launch, or provision a Mac or substitute synthetic input.
"""

import argparse
import json
import math
import os
import subprocess
import sys
import time
from pathlib import Path


def cmux_command(args, *command):
    """Target the explicit tagged socket without ambient workspace routing."""
    env = {key: value for key, value in os.environ.items() if not key.startswith("CMUX_")}
    result = subprocess.run(
        [args.cmux_cli, "--socket", args.cmux_socket, "--json", *command],
        env=env, capture_output=True, text=True, timeout=15, check=True,
    )
    return json.loads(result.stdout)


def pane_frames(payload, axis):
    """Validate and order the two visible pane frames along the drag axis."""
    panes = [pane for pane in payload["panes"] if not pane.get("dock_scope")]
    assert len(panes) == 2, f"Expected exactly two workspace panes: {panes}"
    for pane in panes:
        frame = pane["pixel_frame"]
        assert all(type(frame[key]) in (int, float) and math.isfinite(frame[key])
                   for key in ("x", "y", "width", "height")), frame
        assert frame["width"] > 0 and frame["height"] > 0, frame
    coordinate = "x" if axis == "horizontal" else "y"
    return sorted(panes, key=lambda pane: pane["pixel_frame"][coordinate])


def verify_resize(before, after, axis, direction):
    """Require opposing pane-size changes with stable identity and outer bounds."""
    before_panes, after_panes = pane_frames(before, axis), pane_frames(after, axis)
    assert before["workspace_id"] == after["workspace_id"], "Workspace changed during drag"
    assert [pane["id"] for pane in before_panes] == [pane["id"] for pane in after_panes], (
        "Pane identities/order changed during drag"
    )
    coordinate, size, cross, cross_size = (
        ("x", "width", "y", "height") if axis == "horizontal"
        else ("y", "height", "x", "width")
    )
    first, second = [pane["pixel_frame"] for pane in before_panes]
    moved_first, moved_second = [pane["pixel_frame"] for pane in after_panes]
    for a, b in ((first, second), (moved_first, moved_second)):
        gap = b[coordinate] - (a[coordinate] + a[size])
        assert -1 <= gap <= 16, f"Panes do not share a divider: gap={gap}"
        assert abs(a[cross] - b[cross]) <= 1 and abs(a[cross_size] - b[cross_size]) <= 1, (
            "Panes are not aligned across the requested divider"
        )
    delta = moved_first[size] - first[size]
    other_delta = moved_second[size] - second[size]
    assert direction * delta >= 10, f"Divider did not move in the requested direction: {delta}"
    assert abs(delta + other_delta) <= 2, "Neighbor pane did not resize by the opposite amount"
    assert abs(moved_first[coordinate] - first[coordinate]) <= 1, "Outer pane origin moved"
    assert abs(moved_second[coordinate] + moved_second[size] - second[coordinate] - second[size]) <= 1, (
        "Outer pane edge moved"
    )
    for old, new in ((first, moved_first), (second, moved_second)):
        assert abs(old[cross] - new[cross]) <= 1 and abs(old[cross_size] - new[cross_size]) <= 1, (
            "Pane geometry changed on the other axis"
        )
    return {"first_pane_delta": delta, "second_pane_delta": other_delta}


def run_case(args, case, axis, start, end, output):
    """Run the shared native-drag check and wait for the requested pane resize."""
    before = cmux_command(args, "list-panes", "--workspace", case["workspace"])
    pane_frames(before, axis)
    command = [
        sys.executable, str(Path(__file__).with_name("test_cmux_cua_drag_cursor.py")),
        "--driver", args.driver, "--socket", args.socket, "--feed", str(args.feed),
        "--pid", str(args.pid), "--window-id", str(args.window_id),
        "--session", args.session, "--from", *map(str, start), "--to", *map(str, end),
        "--out", str(output),
    ]
    result = subprocess.run(command, capture_output=True, text=True, timeout=55)
    evidence = {"command": command, "returncode": result.returncode,
                "stdout": result.stdout, "stderr": result.stderr, "before": before}
    direction = 1 if end[0 if axis == "horizontal" else 1] > start[0 if axis == "horizontal" else 1] else -1
    deadline = time.monotonic() + 2
    while True:
        evidence["after"] = cmux_command(args, "list-panes", "--workspace", case["workspace"])
        try:
            evidence["resize"] = verify_resize(before, evidence["after"], axis, direction)
            break
        except AssertionError as error:
            if time.monotonic() >= deadline:
                evidence["geometry_error"] = str(error)
                break
            time.sleep(0.05)
    evidence["passed"] = result.returncode == 0 and "resize" in evidence
    return evidence


def main():
    """Execute eight real divider drags and save a matrix report even on failure."""
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("driver", "socket", "cmux-cli", "cmux-socket"):
        parser.add_argument(f"--{name}", required=True)
    for name in ("pid", "window-id"):
        parser.add_argument(f"--{name}", required=True, type=int)
    for name in ("feed", "plan", "out-dir"):
        parser.add_argument(f"--{name}", required=True, type=Path)
    parser.add_argument("--session", default="issue-12663-divider-matrix")
    args = parser.parse_args()
    plan = json.loads(args.plan.read_text())
    # Check every path before the first native input; reverse drags retrace it.
    for axis, index in (("horizontal", 0), ("vertical", 1)):
        case = plan[axis]
        assert case["workspace"], f"Missing {axis} workspace"
        start, end = case["from"], case["to"]
        assert len(start) == len(end) == 2
        assert all(type(value) in (int, float) and math.isfinite(value) for value in start + end)
        assert start[1 - index] == end[1 - index], f"Expected a straight {axis} drag"
        assert abs(end[index] - start[index]) >= 40, "Drag must cover at least 40 screenshot pixels"
    args.out_dir.mkdir(parents=True, exist_ok=True)
    report = {"plan": plan, "cases": [], "passed": False}
    try:
        for axis in ("horizontal", "vertical"):
            case = plan[axis]
            cmux_command(args, "select-workspace", "--workspace", case["workspace"])
            for iteration in range(2):
                for reverse in (False, True):
                    label = f"{axis}-{iteration + 1}-{'reverse' if reverse else 'forward'}"
                    start, end = (case["to"], case["from"]) if reverse else (case["from"], case["to"])
                    evidence = run_case(args, case, axis, start, end, args.out_dir / f"{label}.json")
                    report["cases"].append({"name": label, **evidence})
                    assert evidence["passed"], f"{label} failed: {evidence}"
        report["passed"] = True
    finally:
        (args.out_dir / "summary.json").write_text(json.dumps(report, indent=2) + "\n")
    print("PASS: eight native divider drags, both directions and axes, cursor and pane geometry")


if __name__ == "__main__":
    main()
