#!/usr/bin/env python3
"""
E2E tests for tab dragging functionality.

Tests that terminal content remains visible and functional after:
1. Creating splits
2. Moving tabs between panes
3. Reordering tabs within a pane

These tests use the cmux socket interface to:
- Create splits and tabs
- Send commands to terminals
- Verify terminal responsiveness by checking for marker files

Usage:
    python3 test_tab_dragging.py

Requirements:
    - cmux must be running with the socket controller enabled
"""

import os
import sys
import time
import tempfile
from pathlib import Path

# Add the directory containing cmux.py to the path
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from cmux import cmux, cmuxError


class TestResult:
    def __init__(self, name: str):
        self.name = name
        self.passed = False
        self.message = ""

    def success(self, msg: str = ""):
        self.passed = True
        self.message = msg

    def failure(self, msg: str):
        self.passed = False
        self.message = msg


def ensure_focused_terminal(client: cmux) -> None:
    """
    Make sure the currently selected workspace has a focused terminal surface.

    Developer sessions (and some prior tests) may leave the browser focused,
    causing send/send_key to fail with "No focused terminal".
    """
    # Start from a clean workspace so indices are predictable.
    try:
        ws_id = client.new_workspace()
        client.select_workspace(ws_id)
        time.sleep(0.5)
    except Exception:
        pass

    try:
        health = client.surface_health()
        term = next((h for h in health if h.get("type") == "terminal"), None)
        if term is None:
            # Fallback: create a terminal surface.
            client.new_surface(panel_type="terminal")
            time.sleep(0.3)
            health = client.surface_health()
            term = next((h for h in health if h.get("type") == "terminal"), None)
        if term is not None:
            client.focus_surface(term["index"])
            time.sleep(0.2)
            wait_for_terminal_in_window(client, term["index"], timeout=5.0)
    except Exception:
        pass


def wait_for_terminal_in_window(client: cmux, surface_idx: int, timeout: float = 5.0) -> bool:
    """Wait until a terminal surface index reports in_window=true via surface_health()."""
    start = time.time()
    while time.time() - start < timeout:
        try:
            health = client.surface_health()
        except Exception:
            health = []
        for h in health:
            if h.get("index") == surface_idx and h.get("type") == "terminal" and h.get("in_window"):
                return True
        time.sleep(0.2)
    return False


def wait_for_marker(marker: Path, timeout: float = 5.0) -> bool:
    """Wait for a marker file to appear."""
    start = time.time()
    while time.time() - start < timeout:
        if marker.exists():
            return True
        time.sleep(0.1)
    return False


def clear_marker(marker: Path):
    """Remove marker file if it exists."""
    marker.unlink(missing_ok=True)


def verify_terminal_responsive(client: cmux, marker: Path, surface_idx: int = None, retries: int = 3) -> bool:
    """
    Verify a terminal is responsive by running a command.
    Returns True if the terminal executed the command successfully.
    """
    for attempt in range(retries):
        clear_marker(marker)

        # Send Ctrl+C first to clear any pending state
        try:
            if surface_idx is not None:
                client.send_key_surface(surface_idx, "ctrl-c")
            else:
                client.send_key("ctrl-c")
        except Exception:
            # Surface may be transiently unavailable during layout/tree updates.
            time.sleep(0.5)
            continue
        time.sleep(0.3)

        # Send command to create marker
        cmd = f"touch {marker}\n"
        try:
            if surface_idx is not None:
                client.send_surface(surface_idx, cmd)
            else:
                client.send(cmd)
        except Exception:
            time.sleep(0.5)
            continue

        if wait_for_marker(marker, timeout=3.0):
            return True

        # Wait a bit before retry
        time.sleep(0.5)

    return False


def test_connection(client: cmux) -> TestResult:
    """Test that we can connect and ping the server."""
    result = TestResult("Connection")
    try:
        if client.ping():
            result.success("Connected and received PONG")
        else:
            result.failure("Ping failed")
    except Exception as e:
        result.failure(str(e))
    return result


def test_initial_terminal_responsive(client: cmux) -> TestResult:
    """Test that the initial terminal is responsive."""
    result = TestResult("Initial Terminal Responsive")
    marker = Path(tempfile.gettempdir()) / f"cmux_init_{os.getpid()}"

    try:
        # Prefer targeting a specific terminal surface by index so this test
        # doesn't depend on "focused terminal" state.
        term_idx = None
        try:
            health = client.surface_health()
            term = next((h for h in health if h.get("type") == "terminal"), None)
            if term is not None:
                term_idx = term.get("index")
                client.focus_surface(term_idx)
                wait_for_terminal_in_window(client, term_idx, timeout=5.0)
        except Exception:
            term_idx = None

        if verify_terminal_responsive(client, marker, surface_idx=term_idx):
            result.success("Initial terminal is responsive")
            clear_marker(marker)
        else:
            result.failure("Initial terminal not responsive")
    except Exception as e:
        result.failure(f"Exception: {e}")
        clear_marker(marker)

    return result


def test_split_right_responsive(client: cmux) -> TestResult:
    """Test that both terminals remain responsive after horizontal split."""
    result = TestResult("Split Right - Both Responsive")
    marker0 = Path(tempfile.gettempdir()) / f"cmux_split0_{os.getpid()}"
    marker1 = Path(tempfile.gettempdir()) / f"cmux_split1_{os.getpid()}"

    try:
        # Create split
        client.new_split("right")
        time.sleep(0.8)
        # Wait for both terminal views to attach so send_surface works reliably.
        wait_for_terminal_in_window(client, 0, timeout=5.0)
        wait_for_terminal_in_window(client, 1, timeout=5.0)

        # Get list of surfaces
        surfaces = client.list_surfaces()
        if len(surfaces) < 2:
            result.failure(f"Expected 2 surfaces after split, got {len(surfaces)}")
            return result

        # Test first surface
        client.focus_surface(0)
        time.sleep(0.3)
        if not verify_terminal_responsive(client, marker0, surface_idx=0):
            result.failure("First terminal not responsive after split")
            clear_marker(marker0)
            clear_marker(marker1)
            return result

        # Test second surface
        client.focus_surface(1)
        time.sleep(0.3)
        if not verify_terminal_responsive(client, marker1, surface_idx=1):
            result.failure("Second terminal not responsive after split")
            clear_marker(marker0)
            clear_marker(marker1)
            return result

        result.success("Both terminals responsive after horizontal split")
        clear_marker(marker0)
        clear_marker(marker1)

    except Exception as e:
        result.failure(f"Exception: {e}")
        clear_marker(marker0)
        clear_marker(marker1)

    return result


def test_split_down_responsive(client: cmux) -> TestResult:
    """Test that both terminals remain responsive after vertical split."""
    result = TestResult("Split Down - Both Responsive")
    marker0 = Path(tempfile.gettempdir()) / f"cmux_splitv0_{os.getpid()}"
    marker1 = Path(tempfile.gettempdir()) / f"cmux_splitv1_{os.getpid()}"

    try:
        # First create a new tab to have a clean state
        client.new_workspace()
        time.sleep(0.5)

        # Create vertical split
        client.new_split("down")
        time.sleep(0.8)
        wait_for_terminal_in_window(client, 0, timeout=5.0)
        wait_for_terminal_in_window(client, 1, timeout=5.0)

        # Get list of surfaces
        surfaces = client.list_surfaces()
        if len(surfaces) < 2:
            result.failure(f"Expected 2 surfaces after split, got {len(surfaces)}")
            return result

        # Test first surface
        client.focus_surface(0)
        time.sleep(0.3)
        if not verify_terminal_responsive(client, marker0, surface_idx=0):
            result.failure("First terminal not responsive after vertical split")
            clear_marker(marker0)
            clear_marker(marker1)
            return result

        # Test second surface
        client.focus_surface(1)
        time.sleep(0.3)
        if not verify_terminal_responsive(client, marker1, surface_idx=1):
            result.failure("Second terminal not responsive after vertical split")
            clear_marker(marker0)
            clear_marker(marker1)
            return result

        result.success("Both terminals responsive after vertical split")
        clear_marker(marker0)
        clear_marker(marker1)

    except Exception as e:
        result.failure(f"Exception: {e}")
        clear_marker(marker0)
        clear_marker(marker1)

    return result


def test_multiple_splits_responsive(client: cmux) -> TestResult:
    """Test that all terminals remain responsive after multiple splits."""
    result = TestResult("Multiple Splits - All Responsive")
    markers = [
        Path(tempfile.gettempdir()) / f"cmux_multi{i}_{os.getpid()}"
        for i in range(4)
    ]

    try:
        # Create a new tab for clean state
        client.new_workspace()
        time.sleep(0.5)

        # Create 2x2 grid: split right, then split each down
        client.new_split("right")
        time.sleep(0.8)

        # Focus first pane and split down
        client.focus_surface(0)
        time.sleep(0.3)
        client.new_split("down")
        time.sleep(0.8)

        # Focus third surface (top-right) and split down
        surfaces = client.list_surfaces()
        # Find the right pane (should be index 2 after the first split down)
        if len(surfaces) >= 3:
            client.focus_surface(2)
            time.sleep(0.3)
            client.new_split("down")
            time.sleep(0.8)

        # Get final surface list
        surfaces = client.list_surfaces()
        expected_count = 4

        if len(surfaces) < expected_count:
            result.failure(f"Expected {expected_count} surfaces, got {len(surfaces)}")
            for m in markers:
                clear_marker(m)
            return result

        # Test each surface
        for i in range(min(len(surfaces), len(markers))):
            client.focus_surface(i)
            time.sleep(0.3)
            if not verify_terminal_responsive(client, markers[i], surface_idx=i):
                result.failure(f"Terminal {i} not responsive after multiple splits")
                for m in markers:
                    clear_marker(m)
                return result

        result.success(f"All {len(surfaces)} terminals responsive after multiple splits")
        for m in markers:
            clear_marker(m)

    except Exception as e:
        result.failure(f"Exception: {e}")
        for m in markers:
            clear_marker(m)

    return result


def test_focus_switching(client: cmux) -> TestResult:
    """Test that focus switching between panes works correctly."""
    result = TestResult("Focus Switching")
    markers = [
        Path(tempfile.gettempdir()) / f"cmux_focus{i}_{os.getpid()}"
        for i in range(3)
    ]

    try:
        # Create a new tab
        client.new_workspace()
        time.sleep(0.5)

        # Create two splits
        client.new_split("right")
        time.sleep(0.8)
        client.focus_surface(0)
        time.sleep(0.3)
        client.new_split("down")
        time.sleep(0.8)

        # Rapidly switch focus between panes and verify each is responsive
        for cycle in range(2):
            for i in range(3):
                client.focus_surface(i)
                time.sleep(0.15)

        # Allow terminals to stabilize after rapid switching
        time.sleep(0.5)

        # After rapid switching, verify all are still responsive
        for i in range(3):
            client.focus_surface(i)
            time.sleep(0.5)  # Give more time for focus to settle
            if not verify_terminal_responsive(client, markers[i], surface_idx=i):
                # Retry once if it fails (timing-related issues)
                time.sleep(0.5)
                if not verify_terminal_responsive(client, markers[i], surface_idx=i):
                    result.failure(f"Terminal {i} not responsive after focus switching")
                    for m in markers:
                        clear_marker(m)
                    return result

        result.success("All terminals responsive after rapid focus switching")
        for m in markers:
            clear_marker(m)

    except Exception as e:
        result.failure(f"Exception: {e}")
        for m in markers:
            clear_marker(m)

    return result


def test_split_ratio_50_50(client: cmux) -> TestResult:
    """Test that splits create 50/50 pane ratios."""
    result = TestResult("Split Ratio 50/50")
    cols_file_0 = Path(tempfile.gettempdir()) / f"cmux_cols0_{os.getpid()}"
    cols_file_1 = Path(tempfile.gettempdir()) / f"cmux_cols1_{os.getpid()}"

    try:
        # Create a new tab for clean state
        client.new_workspace()
        time.sleep(0.5)

        # Create a horizontal split
        client.new_split("right")
        time.sleep(2.0)  # Wait for animation and layout to complete

        # Retry logic for getting column counts
        for attempt in range(3):
            # Get column counts from each terminal
            clear_marker(cols_file_0)
            clear_marker(cols_file_1)

            # Get columns from first terminal
            client.focus_surface(0)
            time.sleep(0.5)
            client.send_key("ctrl-c")
            time.sleep(0.3)
            # Use echo with command substitution to ensure it works
            client.send(f"echo $(tput cols) > {cols_file_0}\n")
            time.sleep(1.5)

            # Get columns from second terminal
            client.focus_surface(1)
            time.sleep(0.5)
            client.send_key("ctrl-c")
            time.sleep(0.3)
            client.send(f"echo $(tput cols) > {cols_file_1}\n")
            time.sleep(1.5)

            # Wait for files to be written
            for _ in range(15):
                if cols_file_0.exists() and cols_file_1.exists():
                    # Also check files have content
                    try:
                        c0 = cols_file_0.read_text().strip()
                        c1 = cols_file_1.read_text().strip()
                        if c0 and c1:
                            break
                    except:
                        pass
                time.sleep(0.2)

            # Read the column counts
            if cols_file_0.exists() and cols_file_1.exists():
                try:
                    cols0 = int(cols_file_0.read_text().strip())
                    cols1 = int(cols_file_1.read_text().strip())

                    # Check if columns are approximately equal (within 5 columns tolerance)
                    diff = abs(cols0 - cols1)
                    if diff <= 5:
                        result.success(f"Splits are ~50/50: {cols0} vs {cols1} cols (diff={diff})")
                    else:
                        result.failure(f"Splits are NOT 50/50: {cols0} vs {cols1} cols (diff={diff})")

                    clear_marker(cols_file_0)
                    clear_marker(cols_file_1)
                    return result
                except (ValueError, OSError) as e:
                    if attempt == 2:
                        result.failure(f"Could not parse column counts: {e}")
                    # Retry
                    continue

            if attempt < 2:
                time.sleep(1.0)  # Wait before retry

        # All retries failed
        if not result.passed and not result.message:
            result.failure(f"Could not get column counts from terminals (file0={cols_file_0.exists()}, file1={cols_file_1.exists()})")

        clear_marker(cols_file_0)
        clear_marker(cols_file_1)

    except Exception as e:
        result.failure(f"Exception: {e}")
        clear_marker(cols_file_0)
        clear_marker(cols_file_1)

    return result


def test_new_surfaces(client: cmux) -> TestResult:
    """Test creating new surfaces in a pane."""
    result = TestResult("New Surfaces")
    markers = [
        Path(tempfile.gettempdir()) / f"cmux_bonsplit{i}_{os.getpid()}"
        for i in range(3)
    ]

    try:
        # Create a new workspace for clean state
        client.new_workspace()
        time.sleep(0.5)

        # Create two additional surfaces
        try:
            _ = client.new_surface(panel_type="terminal")
        except Exception as e:
            result.failure(f"Failed to create surface: {e}")
            return result
        time.sleep(0.5)

        try:
            _ = client.new_surface(panel_type="terminal")
        except Exception as e:
            result.failure(f"Failed to create second surface: {e}")
            return result
        time.sleep(0.5)

        # Smoke: list panes/surfaces without throwing.
        _ = client.list_panes()
        _ = client.list_pane_surfaces()

        # Verify the initial terminal is responsive
        if not verify_terminal_responsive(client, markers[0]):
            result.failure("Terminal not responsive after creating surfaces")
            for m in markers:
                clear_marker(m)
            return result

        result.success("Surfaces created and terminal responsive")
        for m in markers:
            clear_marker(m)

    except Exception as e:
        result.failure(f"Exception: {e}")
        for m in markers:
            clear_marker(m)

    return result


def test_pane_commands(client: cmux) -> TestResult:
    """Test the new pane commands (list_panes, focus_pane)."""
    result = TestResult("Pane Commands")
    marker = Path(tempfile.gettempdir()) / f"cmux_pane_{os.getpid()}"

    try:
        # Create a new tab
        client.new_workspace()
        time.sleep(0.5)

        # Create a split to have multiple panes
        client.new_split("right")
        time.sleep(0.8)

        # List panes
        panes = client.list_panes()
        if len(panes) < 2:
            result.failure(f"Expected 2 panes, got {len(panes)}: {panes}")
            return result

        # Focus first pane and verify terminal works
        pane_id = panes[0][1]
        try:
            client.focus_pane(pane_id)
        except Exception:
            # Fallback to index-based focus if the pane UUID changed unexpectedly.
            client.focus_pane(0)

        time.sleep(0.3)
        if not verify_terminal_responsive(client, marker):
            result.failure("Terminal not responsive after focus_pane")
            clear_marker(marker)
            return result

        result.success("Pane commands working correctly")
        clear_marker(marker)

    except Exception as e:
        result.failure(f"Exception: {e}")
        clear_marker(marker)

    return result


def test_close_horizontal_split(client: cmux) -> TestResult:
    """Test that closing one side of a horizontal split preserves the other terminal."""
    result = TestResult("Close Horizontal Split")
    marker0 = Path(tempfile.gettempdir()) / f"cmux_close_h0_{os.getpid()}"
    marker1 = Path(tempfile.gettempdir()) / f"cmux_close_h1_{os.getpid()}"

    try:
        # Create a new tab for clean state
        client.new_workspace()
        time.sleep(0.5)
        # Wait for the initial surface view to attach so send/send_key are reliable.
        wait_for_terminal_in_window(client, 0, timeout=5.0)
        client.focus_surface(0)
        time.sleep(0.2)

        # Verify initial terminal works
        if not verify_terminal_responsive(client, marker0, surface_idx=0):
            result.failure("Initial terminal not responsive")
            clear_marker(marker0)
            clear_marker(marker1)
            return result

        # Create a horizontal split
        client.new_split("right")
        time.sleep(2.0)

        # Get surface count
        surfaces = client.list_surfaces()
        if len(surfaces) < 2:
            result.failure(f"Expected 2 surfaces after split, got {len(surfaces)}")
            clear_marker(marker0)
            clear_marker(marker1)
            return result

        # Verify both terminals work before close
        client.focus_surface(0)
        time.sleep(0.3)
        if not verify_terminal_responsive(client, marker0, surface_idx=0):
            result.failure("First terminal not responsive before close")
            clear_marker(marker0)
            clear_marker(marker1)
            return result

        client.focus_surface(1)
        time.sleep(0.3)
        if not verify_terminal_responsive(client, marker1, surface_idx=1):
            result.failure("Second terminal not responsive before close")
            clear_marker(marker0)
            clear_marker(marker1)
            return result

        # Close the second (right) surface
        client.close_surface(1)
        time.sleep(1.5)

        # Verify we now have 1 surface (with retry for timing)
        for _ in range(5):
            surfaces = client.list_surfaces()
            if len(surfaces) == 1:
                break
            time.sleep(0.3)

        if len(surfaces) != 1:
            result.failure(f"Expected 1 surface after close, got {len(surfaces)}")
            clear_marker(marker0)
            clear_marker(marker1)
            return result

        # Verify remaining terminal is responsive
        clear_marker(marker0)
        client.focus_surface(0)
        time.sleep(0.2)
        if not verify_terminal_responsive(client, marker0, surface_idx=0):
            result.failure("Remaining terminal not responsive after close")
            clear_marker(marker0)
            clear_marker(marker1)
            return result

        result.success("Horizontal split closed, remaining terminal responsive")
        clear_marker(marker0)
        clear_marker(marker1)

    except Exception as e:
        result.failure(f"Exception: {e}")
        clear_marker(marker0)
        clear_marker(marker1)

    return result


def test_close_vertical_split(client: cmux) -> TestResult:
    """Test that closing one side of a vertical split preserves the other terminal."""
    result = TestResult("Close Vertical Split")
    marker0 = Path(tempfile.gettempdir()) / f"cmux_close_v0_{os.getpid()}"
    marker1 = Path(tempfile.gettempdir()) / f"cmux_close_v1_{os.getpid()}"

    try:
        # Create a new tab for clean state
        client.new_workspace()
        time.sleep(0.5)
        wait_for_terminal_in_window(client, 0, timeout=5.0)
        client.focus_surface(0)
        time.sleep(0.2)

        # Verify initial terminal works
        if not verify_terminal_responsive(client, marker0, surface_idx=0):
            result.failure("Initial terminal not responsive")
            clear_marker(marker0)
            clear_marker(marker1)
            return result

        # Create a vertical split
        client.new_split("down")
        time.sleep(2.0)

        # Get surface count
        surfaces = client.list_surfaces()
        if len(surfaces) < 2:
            result.failure(f"Expected 2 surfaces after split, got {len(surfaces)}")
            clear_marker(marker0)
            clear_marker(marker1)
            return result

        # Verify both terminals work before close
        client.focus_surface(0)
        time.sleep(0.3)
        if not verify_terminal_responsive(client, marker0, surface_idx=0):
            result.failure("First terminal not responsive before close")
            clear_marker(marker0)
            clear_marker(marker1)
            return result

        client.focus_surface(1)
        time.sleep(0.3)
        if not verify_terminal_responsive(client, marker1, surface_idx=1):
            result.failure("Second terminal not responsive before close")
            clear_marker(marker0)
            clear_marker(marker1)
            return result

        # Close the second (bottom) surface
        client.close_surface(1)
        time.sleep(1.5)

        # Verify we now have 1 surface (with retry for timing)
        for _ in range(5):
            surfaces = client.list_surfaces()
            if len(surfaces) == 1:
                break
            time.sleep(0.3)

        if len(surfaces) != 1:
            result.failure(f"Expected 1 surface after close, got {len(surfaces)}")
            clear_marker(marker0)
            clear_marker(marker1)
            return result

        # Verify remaining terminal is responsive
        clear_marker(marker0)
        client.focus_surface(0)
        time.sleep(0.2)
        if not verify_terminal_responsive(client, marker0, surface_idx=0):
            result.failure("Remaining terminal not responsive after close")
            clear_marker(marker0)
            clear_marker(marker1)
            return result

        result.success("Vertical split closed, remaining terminal responsive")
        clear_marker(marker0)
        clear_marker(marker1)

    except Exception as e:
        result.failure(f"Exception: {e}")
        clear_marker(marker0)
        clear_marker(marker1)

    return result


def test_close_first_pane_vertical_split(client: cmux) -> TestResult:
    """Test that closing the FIRST (upper) pane of a vertical split preserves the second terminal.

    This is the specific bug the user reported: closing the first vertical split
    causes the terminal to disappear in the remaining pane.
    """
    result = TestResult("Close First Pane Vertical Split")
    marker0 = Path(tempfile.gettempdir()) / f"cmux_close_fv0_{os.getpid()}"
    marker1 = Path(tempfile.gettempdir()) / f"cmux_close_fv1_{os.getpid()}"

    try:
        # Create a new tab for clean state
        client.new_workspace()
        time.sleep(0.5)
        wait_for_terminal_in_window(client, 0, timeout=5.0)
        client.focus_surface(0)
        time.sleep(0.2)

        # Verify initial terminal works
        if not verify_terminal_responsive(client, marker0, surface_idx=0):
            result.failure("Initial terminal not responsive")
            clear_marker(marker0)
            clear_marker(marker1)
            return result

        # Create a vertical split (first terminal on top, second on bottom)
        client.new_split("down")
        time.sleep(2.0)

        # Get surface count
        surfaces = client.list_surfaces()
        if len(surfaces) < 2:
            result.failure(f"Expected 2 surfaces after split, got {len(surfaces)}")
            clear_marker(marker0)
            clear_marker(marker1)
            return result

        # Verify both terminals work before close
        client.focus_surface(0)
        time.sleep(0.3)
        if not verify_terminal_responsive(client, marker0, surface_idx=0):
            result.failure("First (top) terminal not responsive before close")
            clear_marker(marker0)
            clear_marker(marker1)
            return result

        client.focus_surface(1)
        time.sleep(0.3)
        if not verify_terminal_responsive(client, marker1, surface_idx=1):
            result.failure("Second (bottom) terminal not responsive before close")
            clear_marker(marker0)
            clear_marker(marker1)
            return result

        # Close the FIRST (top) surface - this is the bug case
        client.close_surface(0)
        time.sleep(1.5)

        # Verify we now have 1 surface (with retry for timing)
        for _ in range(5):
            surfaces = client.list_surfaces()
            if len(surfaces) == 1:
                break
            time.sleep(0.3)

        if len(surfaces) != 1:
            result.failure(f"Expected 1 surface after close, got {len(surfaces)}")
            clear_marker(marker0)
            clear_marker(marker1)
            return result

        # Verify remaining terminal is responsive (this is the critical check)
        clear_marker(marker0)
        clear_marker(marker1)
        client.focus_surface(0)
        time.sleep(0.2)
        if not verify_terminal_responsive(client, marker0, surface_idx=0):
            result.failure("Remaining terminal not responsive after closing first pane!")
            clear_marker(marker0)
            return result

        result.success("First pane closed, remaining terminal responsive")
        clear_marker(marker0)
        clear_marker(marker1)

    except Exception as e:
        result.failure(f"Exception: {e}")
        clear_marker(marker0)
        clear_marker(marker1)

    return result


def test_close_nested_splits(client: cmux) -> TestResult:
    """Test closing splits in a nested configuration."""
    result = TestResult("Close Nested Splits")
    markers = [
        Path(tempfile.gettempdir()) / f"cmux_nested_{i}_{os.getpid()}"
        for i in range(4)
    ]

    try:
        # Create a new tab for clean state
        client.new_workspace()
        time.sleep(0.5)

        # Create 2x2 grid
        client.new_split("right")
        time.sleep(0.8)
        client.focus_surface(0)
        time.sleep(0.3)
        client.new_split("down")
        time.sleep(0.8)
        client.focus_surface(2)
        time.sleep(0.3)
        client.new_split("down")
        time.sleep(0.8)

        # Verify all 4 surfaces exist
        surfaces = client.list_surfaces()
        if len(surfaces) < 4:
            result.failure(f"Expected 4 surfaces, got {len(surfaces)}")
            for m in markers:
                clear_marker(m)
            return result

        # Close one at a time and verify remaining terminals
        # Close surface 3 (bottom-right)
        client.close_surface(3)
        time.sleep(1.0)

        surfaces = client.list_surfaces()
        if len(surfaces) != 3:
            result.failure(f"After first close: expected 3 surfaces, got {len(surfaces)}")
            for m in markers:
                clear_marker(m)
            return result

        # Verify remaining 3 terminals work
        for i in range(3):
            client.focus_surface(i)
            time.sleep(0.3)
            if not verify_terminal_responsive(client, markers[i], surface_idx=i):
                result.failure(f"Terminal {i} not responsive after first close")
                for m in markers:
                    clear_marker(m)
                return result

        # Close another
        client.close_surface(0)
        time.sleep(1.0)

        surfaces = client.list_surfaces()
        if len(surfaces) != 2:
            result.failure(f"After second close: expected 2 surfaces, got {len(surfaces)}")
            for m in markers:
                clear_marker(m)
            return result

        # Verify remaining 2 terminals work
        for i in range(2):
            client.focus_surface(i)
            time.sleep(0.3)
            clear_marker(markers[i])
            if not verify_terminal_responsive(client, markers[i], surface_idx=i):
                result.failure(f"Terminal {i} not responsive after second close")
                for m in markers:
                    clear_marker(m)
                return result

        result.success("Nested splits closed correctly")
        for m in markers:
            clear_marker(m)

    except Exception as e:
        result.failure(f"Exception: {e}")
        for m in markers:
            clear_marker(m)

    return result


def test_rapid_split_close_vertical(client: cmux) -> TestResult:
    """Test rapid vertical split and close to reproduce blank terminal bug.

    This test creates and closes vertical splits rapidly with minimal delays
    to try to trigger race conditions that cause blank terminals.
    """
    result = TestResult("Rapid Split/Close Vertical")
    marker = Path(tempfile.gettempdir()) / f"cmux_rapid_{os.getpid()}"

    try:
        # Create a new tab for clean state
        client.new_workspace()
        time.sleep(0.5)
        wait_for_terminal_in_window(client, 0, timeout=5.0)
        client.focus_surface(0)
        time.sleep(0.2)

        # Verify initial terminal works
        if not verify_terminal_responsive(client, marker, surface_idx=0):
            result.failure("Initial terminal not responsive")
            clear_marker(marker)
            return result

        # Do rapid split/close cycles
        for cycle in range(5):
            clear_marker(marker)

            # Create vertical split with minimal delay
            client.new_split("down")
            time.sleep(0.4)  # Brief delay for split

            # Immediately close the bottom (new) pane
            client.close_surface(1)
            time.sleep(0.4)  # Brief delay for close

            # Check if remaining terminal is responsive
            client.focus_surface(0)
            time.sleep(0.2)
            if not verify_terminal_responsive(client, marker, surface_idx=0, retries=2):
                result.failure(f"Terminal blank after cycle {cycle + 1}")
                clear_marker(marker)
                return result

        result.success(f"Completed 5 rapid split/close cycles without blank")
        clear_marker(marker)

    except Exception as e:
        result.failure(f"Exception: {e}")
        clear_marker(marker)

    return result


def test_rapid_split_close_first_pane(client: cmux) -> TestResult:
    """Test rapid vertical split then close FIRST (top) pane.

    This specifically tests the user's reported issue: create vertical split,
    delete the bottom one, remaining top pane goes blank.
    """
    result = TestResult("Rapid Split/Close First Pane")
    marker = Path(tempfile.gettempdir()) / f"cmux_rapid_first_{os.getpid()}"

    try:
        # Create a new tab for clean state
        client.new_workspace()
        time.sleep(0.5)
        wait_for_terminal_in_window(client, 0, timeout=5.0)
        client.focus_surface(0)
        time.sleep(0.2)

        # Verify initial terminal works
        if not verify_terminal_responsive(client, marker, surface_idx=0):
            result.failure("Initial terminal not responsive")
            clear_marker(marker)
            return result

        # Do rapid split/close cycles - close the FIRST pane each time
        for cycle in range(5):
            clear_marker(marker)

            # Create vertical split with minimal delay
            client.new_split("down")
            time.sleep(0.4)  # Brief delay for split

            # Close the FIRST (top/original) pane - this is the bug case
            client.close_surface(0)
            time.sleep(0.4)  # Brief delay for close

            # Check if remaining terminal is responsive
            client.focus_surface(0)
            time.sleep(0.2)
            if not verify_terminal_responsive(client, marker, surface_idx=0, retries=2):
                result.failure(f"Terminal blank after closing first pane, cycle {cycle + 1}")
                clear_marker(marker)
                return result

        result.success(f"Completed 5 rapid first-pane close cycles without blank")
        clear_marker(marker)

    except Exception as e:
        result.failure(f"Exception: {e}")
        clear_marker(marker)

    return result


def run_tests():
    """Run all tests."""
    print("=" * 60)
    print("cmux Tab Dragging E2E Tests")
    print("=" * 60)
    print()
    print("These tests verify that terminals remain responsive after")
    print("various split and tab operations that simulate the scenarios")
    print("where tab dragging bugs occur.")
    print()

    socket_path = cmux.DEFAULT_SOCKET_PATH
    if not os.path.exists(socket_path):
        print(f"Error: Socket not found at {socket_path}")
        print("Please make sure cmux is running.")
        return 1

    results = []

    try:
        with cmux() as client:
            # Test connection
            print("Testing connection...")
            results.append(test_connection(client))
            status = "✅" if results[-1].passed else "❌"
            print(f"  {status} {results[-1].message}")
            print()

            if not results[-1].passed:
                return 1

            ensure_focused_terminal(client)

            # Test initial terminal
            print("Testing initial terminal responsiveness...")
            results.append(test_initial_terminal_responsive(client))
            status = "✅" if results[-1].passed else "❌"
            print(f"  {status} {results[-1].message}")
            print()
            time.sleep(0.5)

            # Test horizontal split
            print("Testing horizontal split (right)...")
            ensure_focused_terminal(client)
            results.append(test_split_right_responsive(client))
            status = "✅" if results[-1].passed else "❌"
            print(f"  {status} {results[-1].message}")
            print()
            time.sleep(0.5)

            # Test vertical split
            print("Testing vertical split (down)...")
            ensure_focused_terminal(client)
            results.append(test_split_down_responsive(client))
            status = "✅" if results[-1].passed else "❌"
            print(f"  {status} {results[-1].message}")
            print()
            time.sleep(0.5)

            # Test multiple splits
            print("Testing multiple splits (2x2 grid)...")
            ensure_focused_terminal(client)
            results.append(test_multiple_splits_responsive(client))
            status = "✅" if results[-1].passed else "❌"
            print(f"  {status} {results[-1].message}")
            print()
            time.sleep(0.5)

            # Test focus switching
            print("Testing rapid focus switching...")
            ensure_focused_terminal(client)
            results.append(test_focus_switching(client))
            status = "✅" if results[-1].passed else "❌"
            print(f"  {status} {results[-1].message}")
            print()
            time.sleep(0.5)

            # Test pane commands
            print("Testing pane commands...")
            ensure_focused_terminal(client)
            results.append(test_pane_commands(client))
            status = "✅" if results[-1].passed else "❌"
            print(f"  {status} {results[-1].message}")
            print()
            time.sleep(0.5)

            # Test new surfaces
            print("Testing new surfaces...")
            ensure_focused_terminal(client)
            results.append(test_new_surfaces(client))
            status = "✅" if results[-1].passed else "❌"
            print(f"  {status} {results[-1].message}")
            print()
            time.sleep(0.5)

            # Test split ratio 50/50
            print("Testing split ratio 50/50...")
            ensure_focused_terminal(client)
            results.append(test_split_ratio_50_50(client))
            status = "✅" if results[-1].passed else "❌"
            print(f"  {status} {results[-1].message}")
            print()
            time.sleep(0.5)

            # Test closing horizontal split
            print("Testing close horizontal split...")
            ensure_focused_terminal(client)
            results.append(test_close_horizontal_split(client))
            status = "✅" if results[-1].passed else "❌"
            print(f"  {status} {results[-1].message}")
            print()
            time.sleep(0.5)

            # Test closing vertical split
            print("Testing close vertical split...")
            ensure_focused_terminal(client)
            results.append(test_close_vertical_split(client))
            status = "✅" if results[-1].passed else "❌"
            print(f"  {status} {results[-1].message}")
            print()
            time.sleep(0.5)

            # Test closing first pane of vertical split (the bug case)
            print("Testing close first pane vertical split (bug case)...")
            ensure_focused_terminal(client)
            results.append(test_close_first_pane_vertical_split(client))
            status = "✅" if results[-1].passed else "❌"
            print(f"  {status} {results[-1].message}")
            print()
            time.sleep(0.5)

            # Test closing nested splits
            print("Testing close nested splits...")
            ensure_focused_terminal(client)
            results.append(test_close_nested_splits(client))
            status = "✅" if results[-1].passed else "❌"
            print(f"  {status} {results[-1].message}")
            print()
            time.sleep(0.5)

            # Test rapid split/close vertical
            print("Testing rapid split/close vertical...")
            ensure_focused_terminal(client)
            results.append(test_rapid_split_close_vertical(client))
            status = "✅" if results[-1].passed else "❌"
            print(f"  {status} {results[-1].message}")
            print()
            time.sleep(0.5)

            # Test rapid split/close first pane
            print("Testing rapid split/close first pane...")
            ensure_focused_terminal(client)
            results.append(test_rapid_split_close_first_pane(client))
            status = "✅" if results[-1].passed else "❌"
            print(f"  {status} {results[-1].message}")
            print()

    except cmuxError as e:
        print(f"Error: {e}")
        return 1

    # Summary
    print("=" * 60)
    print("Test Results Summary")
    print("=" * 60)

    passed = sum(1 for r in results if r.passed)
    total = len(results)

    for r in results:
        status = "✅ PASS" if r.passed else "❌ FAIL"
        print(f"  {r.name}: {status}")
        if not r.passed and r.message:
            print(f"      {r.message}")

    print()
    print(f"Passed: {passed}/{total}")

    if passed == total:
        print("\n🎉 All tests passed!")
        return 0
    else:
        print(f"\n⚠️  {total - passed} test(s) failed")
        return 1


if __name__ == "__main__":
    sys.exit(run_tests())
