#!/usr/bin/env python3
"""Regression: Cmd-click on `notes.md:12` opens the Markdown viewer, not an editor (cx-do47.1).

A Markdown path printed with a line (`build-fleet/ORG-BACKUP.md:12`, as agents
cite files) went to the configured editor because the `:line` branch ran
before the Markdown route. A Markdown file opens in cmux's Markdown viewer
whether or not a line follows it.

The app must be a DEBUG build launched with the in-app Cmd-click harness, the
terminal cwd at REPO/sub, and REPO/build-fleet/ORG-BACKUP.md present:
  CMUX_UI_TEST_TERMINAL_CMD_CLICK_SETUP=1
  CMUX_UI_TEST_TERMINAL_CMD_CLICK_PATH=REPO/sub/setup.json
  CMUX_UI_TEST_TERMINAL_CMD_CLICK_FIXTURE_DIR=REPO/sub
  CMUX_UI_TEST_TERMINAL_CMD_CLICK_COMMAND_PATH=REPO/sub/command.json
  CMUX_UI_TEST_TERMINAL_CMD_CLICK_LINE_FORMAT=log
  CMUX_UI_TEST_TERMINAL_CMD_CLICK_LINE_PREFIX="see "
  CMUX_UI_TEST_TERMINAL_CMD_CLICK_DISPLAY_SUFFIX=:12
  CMUX_UI_TEST_TERMINAL_CMD_CLICK_FILE_NAME=build-fleet/ORG-BACKUP.md
  CMUX_UI_TEST_TERMINAL_CMD_CLICK_SKIP_FIXTURE_FILE=1
  CMUX_UI_TEST_TERMINAL_CMD_CLICK_CD_FIXTURE=1
  CMUX_UI_TEST_CAPTURE_OPEN_PATH=REPO/open-editor.log
  CMUX_UI_TEST_CAPTURE_OPEN_URL_PATH=REPO/open-url.log
REPO is a git repository. Run it where the app can be key (a whole capture
mini or a local tagged build):
  CMUX_PATH_LINK_REPO=REPO python3 tests_v2/test_terminal_markdown_line_link_opens_viewer.py
"""

import json
import os
import sys
import time

REPO = os.environ.get("CMUX_PATH_LINK_REPO", os.path.expanduser("~/cmdclick-repo"))
FIX = os.path.join(REPO, "sub")
SETUP = os.path.join(FIX, "setup.json")
COMMAND = os.path.join(FIX, "command.json")
TARGET = os.path.join(REPO, "build-fleet", "ORG-BACKUP.md")


def load() -> dict:
    try:
        with open(SETUP) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def lines(path: str) -> list:
    try:
        with open(path) as f:
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
    check("harness printed the path", data.get("ready") == "1", str(data.get("displayToken") or data.get("setupError")))
    check("the Markdown file exists at the git root", os.path.exists(TARGET), TARGET)

    click = run("click-1", "cmd_click_token")
    print("click", json.dumps({k: v for k, v in click.items() if k.startswith("lastCommand")})[:600])
    time.sleep(1.5)
    state = run("state-1", "report_state")
    markdown = [os.path.realpath(p) for p in state.get("lastCommandMarkdownPaths") or []]
    editor = lines(os.path.join(REPO, "open-editor.log"))
    urls = state.get("lastCommandOpenedURLs") or []
    check("the .md:12 path opens in the Markdown viewer", os.path.realpath(TARGET) in markdown,
          f"markdown={markdown} urls={urls}")
    check("nothing goes to the editor", not editor, f"editor={editor}")

    print(f"RESULT {sum(results)}/{len(results)}")
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
