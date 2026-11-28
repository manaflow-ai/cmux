#!/usr/bin/env python3
"""Regression: Cmd-hover underlines a path only when it names a file (cx-do47.1).

Ghostty's link regex matched any `foo/bar.md` in terminal output, so Cmd-hover
underlined and previewed a path that exists nowhere, and the click then did
nothing. The app now asks, through Ghostty's link filter, whether the text
names a file or folder (against the terminal's cwd, then the git root) or a
web address it would open; anything else is no link.

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
REPO is a git repository. With REPO/build-fleet/ORG-BACKUP.md present, Cmd-hover
must report the link; without it, Cmd-hover must report no link.
Run it where the app can be key (a whole capture mini or a local tagged build):
  CMUX_PATH_LINK_REPO=REPO python3 tests_v2/test_terminal_path_link_hover_needs_file.py
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

    # Ghostty reports the hovered link on a later main-queue turn; the second
    # hover reads what the first one reported.
    run("hover-1", "hover_token")
    time.sleep(1.0)
    hover = run("hover-2", "hover_token")
    result = hover.get("lastCommandResult") or {}
    print("hover", json.dumps(result)[:600])
    url = result.get("linkHoverURL") or ""
    if expect_file:
        check("Cmd-hover on a path that names a file is a link", "ORG-BACKUP.md" in url, f"linkHoverURL={url!r}")
    else:
        check("Cmd-hover on a path that names nothing is no link", not url, f"linkHoverURL={url!r}")

    print(f"RESULT {sum(results)}/{len(results)}")
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
