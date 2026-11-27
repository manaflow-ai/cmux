#!/usr/bin/env python3
"""Regression: Cmd-click on a folder path opens it in Finder, not the editor (cx-do47).

A path printed in terminal output that names a folder opens in Finder. Before,
it went to the configured editor like a file (a VS Code window for a folder).

The app must be a DEBUG build launched with the in-app Cmd-click harness
printing the folder's absolute path:
  CMUX_UI_TEST_TERMINAL_CMD_CLICK_SETUP=1
  CMUX_UI_TEST_TERMINAL_CMD_CLICK_PATH=FIX/setup.json
  CMUX_UI_TEST_TERMINAL_CMD_CLICK_FIXTURE_DIR=FIX
  CMUX_UI_TEST_TERMINAL_CMD_CLICK_COMMAND_PATH=FIX/command.json
  CMUX_UI_TEST_TERMINAL_CMD_CLICK_LINE_FORMAT=log
  CMUX_UI_TEST_TERMINAL_CMD_CLICK_LINE_PREFIX="wrote "
  CMUX_UI_TEST_TERMINAL_CMD_CLICK_DISPLAY_SUFFIX=.
  CMUX_UI_TEST_TERMINAL_CMD_CLICK_DISPLAY_AS_ABSOLUTE_PATH=1
  CMUX_UI_TEST_TERMINAL_CMD_CLICK_FILE_NAME=reports
  CMUX_UI_TEST_TERMINAL_CMD_CLICK_SKIP_FIXTURE_FILE=1
  CMUX_UI_TEST_TERMINAL_CMD_CLICK_CD_FIXTURE=1
  CMUX_UI_TEST_CAPTURE_OPEN_PATH=FIX/open-editor.log
  CMUX_UI_TEST_CAPTURE_OPEN_FOLDER_PATH=FIX/open-folder.log
With FIX/reports present as a folder the click must open it in Finder; with no
such folder or file the click must open nothing (no editor on a missing path).
Run it where the app can be key (a whole capture mini or a local tagged build):
  CMUX_FOLDER_LINK_FIXTURE=FIX python3 tests_v2/test_terminal_folder_link_opens_finder.py
"""

import json
import os
import sys
import time

FIX = os.environ.get("CMUX_FOLDER_LINK_FIXTURE", os.path.expanduser("~/cmdclick-folder"))
SETUP = os.path.join(FIX, "setup.json")
COMMAND = os.path.join(FIX, "command.json")
FOLDER = os.path.join(FIX, "reports")


def load() -> dict:
    try:
        with open(SETUP) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def lines(name: str) -> list:
    try:
        with open(os.path.join(FIX, name)) as f:
            return [line.strip() for line in f if line.strip()]
    except OSError:
        return []


def run(command_id: str, action: str, timeout: float = 30.0) -> dict:
    with open(COMMAND, "w") as f:
        json.dump({"id": command_id, "action": action}, f)
    deadline = time.time() + timeout
    data = {}
    while time.time() < deadline:
        data = load()
        if data.get("lastCommandId") == command_id:
            return data
        time.sleep(0.3)
    return data


def main() -> int:
    results = []

    def check(name: str, ok: bool, detail: str = "") -> None:
        results.append(ok)
        print(f"{'PASS' if ok else 'FAIL'} {name} {detail}".rstrip())

    deadline = time.time() + 90
    data = load()
    while time.time() < deadline and data.get("ready") != "1":
        time.sleep(0.5)
        data = load()
    check("harness printed the folder path", data.get("ready") == "1",
          str(data.get("displayToken") or data.get("setupError")))
    expect_folder = os.path.isdir(FOLDER)
    print("folder present:", expect_folder)

    click = run("click-1", "cmd_click_token")
    print("click", json.dumps({k: v for k, v in click.items() if k.startswith("lastCommand")})[:600])
    time.sleep(1.5)
    editor = lines("open-editor.log")
    folders = lines("open-folder.log")
    want = os.path.realpath(FOLDER)
    check("nothing goes to the editor", not editor, f"editor={editor}")
    if expect_folder:
        check("the folder opens in Finder", any(os.path.realpath(p) == want for p in folders), f"finder={folders}")
    else:
        check("a missing path opens nothing", not folders, f"finder={folders}")

    print(f"RESULT {sum(results)}/{len(results)}")
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
