#!/usr/bin/env python3
"""No "cmux Remote" name for the helper app.

Leo, 2026-11-17: "But why call it cmux remote? Remote is a crowded namespace".
The one signed permission app is `cmux Computer Use` (com.cmuxterm.cua) and its
supervisor is the helper host (`cmux-helper-host`, `helper-host-*` daemon
requests, `cmux helper-host`, Packages/macOS/CmuxHelperHost). This fails when
an old name comes back in a tracked file:

  "cmux Remote", "CmuxRemote", "com.cmuxterm.remote", "remote-host"

A different "remote" is fine and stays: remote machines (cmux-tui/crates/cmux-remote*,
CmuxRemoteEndpoint and friends in web/services/vms), the legacy SSH stack
(CmuxRemoteWorkspace/Session/Daemon), tailnet remote hosting ("remote-hosts.md",
"remote-hosting"), and the files listed in ALLOWED_PATHS with their reason.
"""

from __future__ import annotations

import re
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

BANNED = re.compile(
    r"cmux Remote"
    r"|(?<![A-Za-z])CmuxRemote(?!Workspace|Session|Daemon|Capture|Enrollment|Endpoint|Route|AttachOptions)"
    r"|com\.cmuxterm\.remote\b"
    r"|(?<![\w-])remote-host(?!s\b|ing|-color)"
)

# Paths that may say an old name, each with why.
ALLOWED_PATHS = {
    # Run logs and history: records of what happened, not names in use.
    r"^cmux-next-ios/verify/": "dated run logs",
    r"^CHANGELOG\.md$": "release history",
    r"^release-notes/": "release history",
    r"^tests/fixtures/": "captured CI logs",
    r"^plans/cmux-next/arch-ratchet\.json$": "applied ratchet exceptions are verbatim records",
    r"^plans/cmux-next/arch-exceptions/": "applied ratchet exceptions are verbatim records",
    # Builds cmux#37003's head with that PR's own build script and bundle names.
    r"^scripts/measure/cu-driver-eval/": "builds another PR's head",
    # SSH remote hosts, not the helper app.
    r"^\.github/review-bot-rules/remote-relay-authorization\.md$": "the cmux ssh relay's remote host",
    r"^skills/cmux-socket-policy/": "the cmux ssh relay's remote host",
    r"^cmux-next-ios/UITests/FirstUserJourneyUITests\.swift$": "an SSH remote-host screen",
    # Remote machines (the cmux-remote crates) and their web side.
    r"^cmux-tui/crates/cmux-remote(-[a-z-]+)?/": "remote machines",
    r"^web/services/vms/": "remote machines",
    r"^web/tests/vm-": "remote machines",
    r"^web/scripts/": "remote machines",
    r"^vendor/": "vendored code",
    r"^ghostty": "vendored code",
    r"^THIRD_PARTY_LICENSES\.md$": "generated license list",
    # This lint names what it bans.
    r"^tests/test_no_cmux_remote_name\.py$": "the lint itself",
}
ALLOWED_RE = re.compile("|".join(ALLOWED_PATHS))


def offenders(paths: list[str], read) -> list[str]:
    found = []
    for rel in paths:
        if ALLOWED_RE.search(rel):
            continue
        text = read(rel)
        if text is None:
            continue
        for number, line in enumerate(text.splitlines(), 1):
            match = BANNED.search(line)
            if match:
                found.append(f"{rel}:{number}: {match.group(0)!r}: {line.strip()[:160]}")
    return found


def read_tracked(rel: str) -> str | None:
    path = ROOT / rel
    try:
        data = path.read_bytes()
    except OSError:
        return None
    if b"\0" in data[:8192]:
        return None
    return data.decode("utf-8", errors="replace")


class MatcherTests(unittest.TestCase):
    def test_bans_the_old_names(self) -> None:
        for line in [
            "Grant them once, to cmux Remote.",
            "import CmuxRemoteWire",
            "CmuxRemoteService.start()",
            'Logger(subsystem: "com.cmuxterm.remote")',
            "cmux remote-host status",
            '{"cmd": "remote-host-call"}',
            "state under remote-host/host.json",
        ]:
            self.assertTrue(BANNED.search(line), line)

    def test_keeps_other_remotes(self) -> None:
        for line in [
            "plans/cmux-next/remote-hosts.md",
            "remote-hosting logins",
            "data-cmux-remote-host",
            "remote-host-color-test-1",
            "CmuxRemoteWorkspace was deleted",
            "CmuxRemoteEndpoint",
            "openCmuxRemote(machine)",
            "cmux-remote-browser-host",
            "cmux helper-host status",
            "com.cmuxterm.cua",
            "remote.confirm",
        ]:
            self.assertFalse(BANNED.search(line), line)

    def test_allowed_paths_skip(self) -> None:
        texts = {"cmux-next-ios/verify/x.md": "cmux Remote", "docs/a.md": "cmux Remote"}
        found = offenders(list(texts), texts.get)
        self.assertEqual([entry.split(":")[0] for entry in found], ["docs/a.md"])


def main() -> int:
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(MatcherTests)
    if not unittest.TextTestRunner(verbosity=0).run(suite).wasSuccessful():
        return 1
    tracked = subprocess.run(
        ["git", "-C", str(ROOT), "ls-files", "-z"], check=True, capture_output=True, text=True
    ).stdout.split("\0")
    found = offenders([p for p in tracked if p], read_tracked)
    if found:
        print("The helper app is cmux Computer Use and its supervisor the helper host; "
              "these lines use a retired cmux Remote name (tests/test_no_cmux_remote_name.py):")
        for entry in found:
            print("  " + entry)
        return 1
    print("no cmux Remote name")
    return 0


if __name__ == "__main__":
    sys.exit(main())
