#!/usr/bin/env python3
"""
Visual Screenshot Tests for cmuxterm

Takes screenshots before and after each state change during split/browser operations
and generates an HTML report for visual verification.

Usage:
    python3 tests/test_visual_screenshots.py
    # Then open tests/visual_report.html in a browser
"""

import os
import sys
import time
import subprocess
import tempfile
import base64
from pathlib import Path
from datetime import datetime
from dataclasses import dataclass, field
from typing import Optional

# Add parent directory for imports
sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux

SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmuxterm-debug.sock")
OUTPUT_DIR = Path(__file__).parent / "visual_output"
HTML_REPORT = Path(__file__).parent / "visual_report.html"


@dataclass
class Screenshot:
    """A single screenshot with metadata."""
    path: Path
    label: str
    timestamp: str

    def to_base64(self) -> str:
        """Convert image to base64 for embedding in HTML."""
        with open(self.path, "rb") as f:
            return base64.b64encode(f.read()).decode("utf-8")


@dataclass
class StateChange:
    """A before/after state change with screenshots."""
    name: str
    description: str
    before: Optional[Screenshot] = None
    after: Optional[Screenshot] = None
    command: str = ""
    result: str = ""
    passed: bool = True
    error: str = ""
    before_state: str = ""  # Text representation of state before
    after_state: str = ""   # Text representation of state after


def get_app_window_id() -> Optional[str]:
    """Get the window ID of the cmuxterm app."""
    result = subprocess.run(
        ["osascript", "-e",
         'tell application "System Events" to get id of first window of process "cmuxterm DEV"'],
        capture_output=True, text=True
    )
    if result.returncode == 0:
        return result.stdout.strip()
    return None


def take_screenshot(label: str, index: int) -> Optional[Screenshot]:
    """Take a screenshot using the in-app screenshot API."""
    try:
        import socket
        import select
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.connect(SOCKET_PATH)
        sock.setblocking(False)

        # Send screenshot command with label
        safe_label = label.replace(" ", "_").replace("/", "-")
        cmd = f"screenshot {index:03d}_{safe_label}\n"
        sock.sendall(cmd.encode())

        # Read response with proper timeout handling
        data = b""
        start = time.time()
        while time.time() - start < 5.0:
            ready, _, _ = select.select([sock], [], [], 0.5)
            if ready:
                try:
                    chunk = sock.recv(4096)
                    if not chunk:
                        break
                    data += chunk
                    if b"\n" in data:
                        break
                except BlockingIOError:
                    continue
            elif data:  # Got some data, no more coming
                break
        sock.close()

        response = data.decode().strip()
        if not response:
            print(f"  ⚠️  Screenshot: no response")
            return None

        if not response.startswith("OK"):
            print(f"  ⚠️  Screenshot failed: {response}")
            return None

        # Parse response: "OK <id> <path>"
        parts = response.split(" ", 2)
        if len(parts) < 3:
            print(f"  ⚠️  Invalid screenshot response: {response}")
            return None

        screenshot_id = parts[1]
        screenshot_path = Path(parts[2])

        if not screenshot_path.exists():
            print(f"  ⚠️  Screenshot file not found: {screenshot_path}")
            return None

        return Screenshot(
            path=screenshot_path,
            label=label,
            timestamp=datetime.now().strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]
        )

    except Exception as e:
        print(f"  ⚠️  Screenshot error: {e}")
        return None


def capture_state_direct() -> str:
    """Capture current state of surfaces and panes using direct socket connection."""
    try:
        import socket
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.connect(SOCKET_PATH)
        sock.settimeout(2.0)

        def send_cmd(cmd: str) -> str:
            sock.sendall((cmd + "\n").encode())
            data = b""
            while True:
                chunk = sock.recv(4096)
                if not chunk:
                    break
                data += chunk
                if b"\n" in data:
                    break
            return data.decode().strip()

        surfaces = send_cmd("list_surfaces")
        tabs = send_cmd("list_tabs")
        panes = send_cmd("list_panes")
        sock.close()

        return f"Surfaces:\n{surfaces}\n\nTabs:\n{tabs}\n\nPanes:\n{panes}"
    except Exception as e:
        return f"Error capturing state: {e}"


def generate_html_report(changes: list[StateChange]) -> None:
    """Generate an HTML report with all screenshots."""
    html = '''<!DOCTYPE html>
<html>
<head>
    <title>cmuxterm Visual Test Report</title>
    <style>
        body {
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
            background: #1a1a2e;
            color: #eee;
            padding: 20px;
            max-width: 1800px;
            margin: 0 auto;
        }
        h1 {
            color: #4cc9f0;
            border-bottom: 2px solid #4361ee;
            padding-bottom: 10px;
        }
        h2 {
            color: #7209b7;
            margin-top: 40px;
        }
        .state-change {
            background: #16213e;
            border-radius: 12px;
            padding: 20px;
            margin: 20px 0;
            box-shadow: 0 4px 6px rgba(0,0,0,0.3);
        }
        .state-change.passed {
            border-left: 4px solid #4cc9f0;
        }
        .state-change.failed {
            border-left: 4px solid #f72585;
        }
        .screenshots {
            display: flex;
            gap: 20px;
            margin-top: 15px;
            flex-wrap: wrap;
        }
        .screenshot-container {
            flex: 1;
            min-width: 400px;
            background: #0f0f23;
            border-radius: 8px;
            padding: 10px;
        }
        .screenshot-container h4 {
            color: #4361ee;
            margin: 0 0 10px 0;
        }
        .screenshot-container img {
            max-width: 100%;
            border-radius: 4px;
            border: 1px solid #333;
        }
        .meta {
            font-size: 0.9em;
            color: #888;
            margin-top: 5px;
        }
        .command {
            background: #0f0f23;
            padding: 10px;
            border-radius: 4px;
            font-family: monospace;
            margin: 10px 0;
            color: #4cc9f0;
        }
        .result {
            color: #4cc9f0;
        }
        .error {
            color: #f72585;
            background: rgba(247, 37, 133, 0.1);
            padding: 10px;
            border-radius: 4px;
        }
        .summary {
            background: #0f0f23;
            padding: 20px;
            border-radius: 8px;
            margin-bottom: 30px;
        }
        .summary .passed { color: #4cc9f0; }
        .summary .failed { color: #f72585; }
        .timestamp {
            font-size: 0.8em;
            color: #666;
        }
        .annotation {
            margin-top: 15px;
            padding: 10px;
            background: #0f0f23;
            border-radius: 8px;
        }
        .annotation label {
            display: block;
            color: #f72585;
            font-weight: bold;
            margin-bottom: 5px;
        }
        .annotation textarea {
            width: 100%;
            min-height: 60px;
            background: #1a1a2e;
            border: 1px solid #333;
            border-radius: 4px;
            color: #eee;
            padding: 8px;
            font-family: inherit;
            resize: vertical;
        }
        .annotation textarea:focus {
            outline: none;
            border-color: #4361ee;
        }
        .copy-section {
            position: fixed;
            bottom: 20px;
            right: 20px;
            background: #16213e;
            padding: 15px;
            border-radius: 12px;
            box-shadow: 0 4px 20px rgba(0,0,0,0.5);
            z-index: 1000;
        }
        .copy-btn {
            background: #4361ee;
            color: white;
            border: none;
            padding: 12px 24px;
            border-radius: 6px;
            cursor: pointer;
            font-size: 14px;
            font-weight: bold;
        }
        .copy-btn:hover {
            background: #3651d4;
        }
        .copy-btn.copied {
            background: #4cc9f0;
        }
        .issue-marker {
            display: inline-block;
            margin-left: 10px;
            padding: 2px 8px;
            background: #f72585;
            color: white;
            border-radius: 4px;
            font-size: 0.8em;
            cursor: pointer;
        }
        .issue-marker.no-issue {
            background: #333;
            color: #888;
        }
    </style>
</head>
<body>
    <h1>cmuxterm Visual Test Report</h1>
    <p class="timestamp">Generated: ''' + datetime.now().strftime("%Y-%m-%d %H:%M:%S") + '''</p>

    <div class="summary">
        <h3>Summary</h3>
        <p>Total tests: ''' + str(len(changes)) + '''</p>
        <p class="passed">Passed: ''' + str(sum(1 for c in changes if c.passed)) + '''</p>
        <p class="failed">Failed: ''' + str(sum(1 for c in changes if not c.passed)) + '''</p>
    </div>
'''

    for i, change in enumerate(changes, 1):
        status_class = "passed" if change.passed else "failed"
        html += f'''
    <div class="state-change {status_class}">
        <h2>{i}. {change.name}</h2>
        <p>{change.description}</p>
        '''

        if change.command:
            html += f'<div class="command">{change.command}</div>'

        if change.result:
            html += f'<div class="result">Result: {change.result}</div>'

        if change.error:
            html += f'<div class="error">Error: {change.error}</div>'

        html += '<div class="screenshots">'

        if change.before:
            html += f'''
            <div class="screenshot-container">
                <h4>Before</h4>
                <img src="data:image/png;base64,{change.before.to_base64()}" alt="{change.before.label}">
                <div class="meta">{change.before.timestamp}</div>
            </div>
            '''
        elif change.before_state:
            html += f'''
            <div class="screenshot-container">
                <h4>Before (State)</h4>
                <pre style="color: #888; font-size: 0.85em; white-space: pre-wrap;">{change.before_state}</pre>
            </div>
            '''

        if change.after:
            html += f'''
            <div class="screenshot-container">
                <h4>After</h4>
                <img src="data:image/png;base64,{change.after.to_base64()}" alt="{change.after.label}">
                <div class="meta">{change.after.timestamp}</div>
            </div>
            '''
        elif change.after_state:
            html += f'''
            <div class="screenshot-container">
                <h4>After (State)</h4>
                <pre style="color: #888; font-size: 0.85em; white-space: pre-wrap;">{change.after_state}</pre>
            </div>
            '''

        # Add annotation section
        test_id = f"test_{i}"
        html += f'''
        </div>
        <div class="annotation">
            <label>🐛 Issue? Describe what's wrong:</label>
            <textarea id="{test_id}_notes" placeholder="e.g., 'bottom right pane is blank after close'" oninput="updateIssueMarker({i})"></textarea>
        </div>
    </div>'''

    # Add copy section and JavaScript
    html += '''
    <div class="copy-section">
        <button class="copy-btn" onclick="copyFeedback()">📋 Copy Feedback</button>
        <div id="copy-status" style="margin-top: 8px; font-size: 0.85em; color: #888;"></div>
    </div>

    <script>
    function updateIssueMarker(testNum) {
        // Could add visual markers if needed
    }

    function copyFeedback() {
        const tests = document.querySelectorAll('.state-change');
        let feedback = [];

        tests.forEach((test, idx) => {
            const testNum = idx + 1;
            const title = test.querySelector('h2').textContent;
            const textarea = document.getElementById(`test_${testNum}_notes`);
            const notes = textarea ? textarea.value.trim() : '';

            if (notes) {
                const command = test.querySelector('.command');
                const cmdText = command ? command.textContent : '';
                feedback.push(`## ${title}`);
                if (cmdText) feedback.push(`Command: ${cmdText}`);
                feedback.push(`Issue: ${notes}`);
                feedback.push('');
            }
        });

        if (feedback.length === 0) {
            document.getElementById('copy-status').textContent = 'No issues noted!';
            return;
        }

        const text = '# Visual Test Feedback\\n\\n' + feedback.join('\\n');
        navigator.clipboard.writeText(text).then(() => {
            const btn = document.querySelector('.copy-btn');
            btn.classList.add('copied');
            btn.textContent = '✓ Copied!';
            document.getElementById('copy-status').textContent = `${feedback.filter(l => l.startsWith('## ')).length} issue(s) copied`;
            setTimeout(() => {
                btn.classList.remove('copied');
                btn.textContent = '📋 Copy Feedback';
            }, 2000);
        });
    }
    </script>
</body>
</html>
'''

    HTML_REPORT.write_text(html)
    print(f"\n📊 Report generated: {HTML_REPORT}")


def run_visual_tests():
    """Run visual tests with state capture."""
    changes: list[StateChange] = []
    screenshot_idx = 0

    print("=" * 60)
    print("cmuxterm Visual Screenshot Tests")
    print("=" * 60)
    print()
    print("Using in-app screenshot API to capture window state.\n")

    # Helper to get a fresh connection
    def get_client() -> cmux:
        c = cmux(SOCKET_PATH)
        c.connect()
        return c

    # Connect to cmux
    client = get_client()

    # Reset app state: create a fresh tab and switch to it
    print("Resetting app state...")
    try:
        # Create a new tab to start fresh
        result = client._send_command("new_tab")
        if result.startswith("OK"):
            time.sleep(0.5)
            # The new tab should be selected automatically

        # Reconnect after creating new tab
        client.close()
        time.sleep(0.3)
        client = get_client()

        # Close all other surfaces in this tab except the first terminal
        for _ in range(5):  # Try up to 5 times to clean up
            surfaces = client.list_surfaces()
            if len(surfaces) <= 1:
                break
            # Close from end to start to avoid index shifting issues
            for i in range(len(surfaces) - 1, 0, -1):
                try:
                    client._send_command(f"close_surface {i}")
                    time.sleep(0.2)
                except:
                    pass
            time.sleep(0.2)

        # Ensure we have a terminal focused
        surfaces = client.list_surfaces()
        for i, s in enumerate(surfaces):
            if "[terminal]" in s[1]:
                client.focus_surface(i)
                break
    except Exception as e:
        print(f"  Warning: Reset failed: {e}")

    # Wait for app to be ready
    time.sleep(0.8)

    # Helper to capture screenshot and state
    def capture(label: str) -> tuple[Optional[Screenshot], str]:
        nonlocal screenshot_idx
        screenshot = take_screenshot(label, screenshot_idx)
        screenshot_idx += 1
        state = capture_state_direct()
        return screenshot, state

    # Test 1: Initial state
    print("1. Capturing initial state...")
    change = StateChange(
        name="Initial State",
        description="App window with single terminal pane"
    )
    change.after, change.after_state = capture("initial_state")
    changes.append(change)
    time.sleep(0.5)

    # Test 2: Create horizontal split (right)
    print("2. Creating horizontal split (right)...")
    change = StateChange(
        name="Horizontal Split (Right)",
        description="Split the terminal pane horizontally",
        command="new_split right"
    )
    change.before, change.before_state = capture("before_split_right")
    time.sleep(0.5)

    try:
        # Reconnect to ensure fresh connection
        client.close()
        time.sleep(0.2)
        client = get_client()
        client.new_split("right")
        change.result = "OK"
        change.passed = True
    except Exception as e:
        change.error = str(e)
        change.passed = False
    time.sleep(0.8)

    change.after, change.after_state = capture("after_split_right")
    changes.append(change)
    time.sleep(0.5)

    # Test 3: Create vertical split (down)
    print("3. Creating vertical split (down)...")
    change = StateChange(
        name="Vertical Split (Down)",
        description="Split the focused pane vertically",
        command="new_split down"
    )
    change.before, change.before_state = capture("before_split_down")
    time.sleep(0.5)

    try:
        # Reconnect to ensure fresh connection
        client.close()
        time.sleep(0.2)
        client = get_client()
        client.new_split("down")
        change.result = "OK"
        change.passed = True
    except Exception as e:
        change.error = str(e)
        change.passed = False
    time.sleep(0.8)

    change.after, change.after_state = capture("after_split_down")
    changes.append(change)
    time.sleep(0.5)

    # Reconnect after split operations
    client.close()
    time.sleep(0.2)
    client = get_client()

    # Test 4: Open browser panel
    print("4. Opening browser panel...")
    change = StateChange(
        name="Open Browser Panel",
        description="Open a browser panel in the current pane",
        command="open_browser https://example.com"
    )
    change.before, change.before_state = capture("before_browser")
    time.sleep(0.3)

    try:
        result = client._send_command("open_browser https://example.com")
        change.result = result
        change.passed = result.startswith("OK")
    except Exception as e:
        change.error = str(e)
        change.passed = False
    time.sleep(1.0)  # Browser needs time to load

    change.after, change.after_state = capture("after_browser")
    changes.append(change)
    time.sleep(0.5)

    # Test 5: Focus switching
    print("5. Focus switching between panes...")
    surfaces = client.list_surfaces()
    if len(surfaces) >= 2:
        change = StateChange(
            name="Focus Switch to Pane 0",
            description="Switch focus to the first pane",
            command="focus_surface 0"
        )
        change.before, change.before_state = capture("before_focus_0")
        time.sleep(0.3)

        client.focus_surface(0)
        change.result = "Focused pane 0"
        time.sleep(0.3)

        change.after, change.after_state = capture("after_focus_0")
        changes.append(change)
    time.sleep(0.5)

    # Test 6: Close a split
    print("6. Closing a split...")
    surfaces = client.list_surfaces()
    if len(surfaces) >= 2:
        change = StateChange(
            name="Close Split",
            description="Close the last surface to collapse the split",
            command=f"close_surface {len(surfaces) - 1}"
        )
        change.before, change.before_state = capture("before_close_split")
        time.sleep(0.3)

        try:
            result = client.close_surface(len(surfaces) - 1)
            change.result = result
            change.passed = True
        except Exception as e:
            change.error = str(e)
            change.passed = False
        time.sleep(0.5)

        change.after, change.after_state = capture("after_close_split")
        changes.append(change)
    time.sleep(0.5)

    # Test 7: Rapid split/close cycle
    print("7. Rapid split/close cycle...")

    # Ensure we have a terminal focused for the rapid cycles
    # Create a new tab to get a clean terminal state
    client.close()
    time.sleep(0.3)
    client = get_client()
    try:
        client._send_command("new_tab")
        time.sleep(0.5)
        client.close()
        time.sleep(0.2)
        client = get_client()
    except:
        pass

    for i in range(3):
        # Reconnect before each cycle to ensure clean state
        client.close()
        time.sleep(0.3)
        client = get_client()

        # Ensure terminal is focused
        surfaces = client.list_surfaces()
        for j, s in enumerate(surfaces):
            if "[terminal]" in s[1]:
                client.focus_surface(j)
                break
        time.sleep(0.2)

        change = StateChange(
            name=f"Rapid Split/Close Cycle {i+1}",
            description=f"Quick split and close operation #{i+1}",
            command="new_split down; close_surface 1"
        )
        change.before, change.before_state = capture(f"before_rapid_{i}")
        time.sleep(0.5)

        # Split
        try:
            client.new_split("down")
            time.sleep(0.5)

            # Capture mid state
            mid_state = capture_state_direct()

            # Close
            client.close_surface(1)
            change.passed = True
        except Exception as e:
            change.error = str(e)
            change.passed = False
        time.sleep(0.5)

        change.after, change.after_state = capture(f"after_rapid_{i}")
        changes.append(change)
    time.sleep(0.5)

    # Test 8: New sidebar tab
    print("8. Creating new sidebar tab...")
    change = StateChange(
        name="New Sidebar Tab",
        description="Create a new sidebar tab",
        command="new_tab"
    )
    change.before, change.before_state = capture("before_new_tab")
    time.sleep(0.3)

    result = client.new_tab()
    change.result = result if result else "No ID returned"
    change.passed = bool(result)
    time.sleep(0.5)

    change.after, change.after_state = capture("after_new_tab")
    changes.append(change)
    time.sleep(0.5)

    # Test 9: Open browser in new tab
    print("9. Opening browser in new tab...")
    change = StateChange(
        name="Browser in New Tab",
        description="Open a browser panel in the new sidebar tab",
        command="open_browser https://github.com"
    )
    change.before, change.before_state = capture("before_browser_tab")
    time.sleep(0.3)

    try:
        result = client._send_command("open_browser https://github.com")
        change.result = result
        change.passed = result.startswith("OK")
    except Exception as e:
        change.error = str(e)
        change.passed = False
    time.sleep(1.5)  # Browser needs time to load

    change.after, change.after_state = capture("after_browser_tab")
    changes.append(change)

    # Generate the HTML report
    generate_html_report(changes)

    # Cleanup: close extra tabs to prevent accumulation across test runs
    try:
        client.close()
        time.sleep(0.2)
        client = get_client()
        tabs = client.list_tabs()
        # Keep only the last tab (selected one), close others
        if len(tabs) > 1:
            for i in range(len(tabs) - 1):
                try:
                    tab_id = tabs[i][1]
                    client._send_command(f"close_tab {tab_id}")
                    time.sleep(0.1)
                except:
                    pass
        client.close()
    except:
        pass

    # Summary
    print()
    print("=" * 60)
    print("Visual Test Summary")
    print("=" * 60)
    passed = sum(1 for c in changes if c.passed)
    failed = sum(1 for c in changes if not c.passed)
    print(f"  Passed: {passed}")
    print(f"  Failed: {failed}")
    print(f"  Total:  {len(changes)}")
    # Print failed test names
    failed_tests = [c for c in changes if not c.passed]
    if failed_tests:
        print()
        print("Failed tests:")
        for c in failed_tests:
            print(f"  - {c.name}: {c.error or c.result or 'no error/result'}")
    print()
    print(f"📁 Screenshots saved to: {OUTPUT_DIR}")
    print(f"📊 Open report: {HTML_REPORT}")


if __name__ == "__main__":
    run_visual_tests()
