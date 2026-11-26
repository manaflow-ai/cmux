#!/usr/bin/env python3
"""Regression: Cmd-click on a bare relative path never opens the browser (cx-do47).

Leo Cmd-clicked "build-fleet/ORG-BACKUP.md" in terminal output and cmux opened
https://build-fleet/ORG-BACKUP.md. Text without a scheme is a URL only when its
host has a public top-level domain (or is localhost, or an IP with a port);
"foo/bar.md" is a path. It resolves against the terminal's cwd, then the git
root; when no file exists, the click does nothing.

The app must be a DEBUG build launched with the in-app Cmd-click harness, the
terminal cwd at REPO/sub, and the printed path absent under the cwd:
  CMUX_UI_TEST_TERMINAL_CMD_CLICK_SETUP=1
  CMUX_UI_TEST_TERMINAL_CMD_CLICK_PATH=REPO/sub/setup.json
  CMUX_UI_TEST_TERMINAL_CMD_CLICK_FIXTURE_DIR=REPO/sub
  CMUX_UI_TEST_TERMINAL_CMD_CLICK_COMMAND_PATH=REPO/sub/command.json
  CMUX_UI_TEST_TERMINAL_CMD_CLICK_LINE_FORMAT=log
  CMUX_UI_TEST_TERMINAL_CMD_CLICK_LINE_PREFIX="see "
  CMUX_UI_TEST_TERMINAL_CMD_CLICK_DISPLAY_SUFFIX=.
  CMUX_UI_TEST_TERMINAL_CMD_CLICK_FILE_NAME=build-fleet/ORG-BACKUP.md
  CMUX_UI_TEST_TERMINAL_CMD_CLICK_SKIP_FIXTURE_FILE=1
  CMUX_UI_TEST_TERMINAL_CMD_CLICK_CD_FIXTURE=1
  CMUX_UI_TEST_OPEN_MARKDOWN_IN_CMUX_VIEWER=1
  CMUX_UI_TEST_CAPTURE_OPEN_URL_PATH=REPO/open-url.log
REPO is a git repository. With REPO/build-fleet/ORG-BACKUP.md present the click
must open it in the Markdown viewer; without it the click must open nothing.
Run it where the app can be key (a whole capture mini or a local tagged build):
  CMUX_PATH_LINK_REPO=REPO python3 tests_v2/test_terminal_path_link_not_browser.py
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
    expect_file = os.path.exists(TARGET)
    print("git-root file present:", expect_file)

    click = run("click-1", "cmd_click_token")
    print("click", json.dumps({k: v for k, v in click.items() if k.startswith("lastCommand")})[:600])
    time.sleep(1.5)
    state = run("state-1", "report_state")
    urls = state.get("lastCommandOpenedURLs") or []
    markdown = [os.path.realpath(p) for p in state.get("lastCommandMarkdownPaths") or []]
    web = [u for u in urls if "://" in u and not u.startswith("file:")]
    check("no browser URL is opened for a bare relative path", not web, f"opened={web}")
    if expect_file:
        check("the path resolves against the git root into the Markdown viewer",
              os.path.realpath(TARGET) in markdown, f"markdown={markdown} urls={urls}")
    else:
        check("a path that exists nowhere opens nothing", not urls and not markdown,
              f"markdown={markdown} urls={urls}")

    print(f"RESULT {sum(results)}/{len(results)}")
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
