#!/usr/bin/env python3
"""FEED-SESSION-KEY guard (review of manaflow-ai/cmux#41240, finding F1).

The feed bridge posts one phone item per acpmux prompt and withdraws it when the
prompt is answered elsewhere. It must key every add and every withdraw on ONE id
per session: the row's `qualifiedSessionId` (`peer/id`, which acpmux sends on a
peer's rows and on every notice of a peer's session), or this daemon's own raw
`sessionId` for its own sessions. That key is made in one place,
`AcpmuxPendingReads.sessionKey(_:)`. A raw `sessionId` read anywhere else on the
feed path names no peer: two peers can share it, and a prompt that recovery
posted under the qualified id is never withdrawn by a notice read by the raw id,
so a stale item stays on the phone.

This guard fails when a file on the feed path
  - reads `"sessionId"` from a row, notice or reply (`x["sessionId"]`);
    writing it into a request (`["sessionId": key]`) is fine;
  - builds a `peer/id` key by hand (a line that reads `["peer"]` and
    interpolates `/\\(`).
A line that must do either (sessionKey's own body) carries
`feed-key-allow: <reason>`. Comments are not read.

The feed path: every Swift file under CmuxNextApp/Feed/, the dialog desk's
prompt list (Approvals/AgentDialogLine.swift), and the recovery reads it shares
(AcpmuxPendingReads.swift, AcpmuxSessionListGate.swift).

Tested by scripts/cmux-next/tests/check-feed-session-key.test.sh.

Usage: scripts/cmux-next/check-feed-session-key.py [repo-root]
Exit 0 clean, 1 with findings, 2 on a usage error.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

SOURCES = "Packages/macOS/CmuxNext/Sources"
FEED_DIRS = [f"{SOURCES}/CmuxNextApp/Feed"]
FEED_FILES = [
    f"{SOURCES}/CmuxNextAgentPane/Approvals/AgentDialogLine.swift",
    f"{SOURCES}/CmuxNextAgentPane/AcpmuxPendingReads.swift",
    f"{SOURCES}/CmuxNextAgentPane/AcpmuxSessionListGate.swift",
]
ALLOW = "feed-key-allow:"

# A read of the raw id: the key in a subscript, not a dictionary literal's `"sessionId":`.
RAW_READ = re.compile(r'\[\s*"sessionId"\s*\]')
# A hand-made qualified key: the peer read and a `/\(` interpolation on one line.
PEER_READ = re.compile(r'\[\s*"peer"\s*\]')
HAND_KEY = re.compile(r'/\\\(')


def feed_files(root: Path) -> list[Path]:
    files: list[Path] = []
    for directory in FEED_DIRS:
        path = root / directory
        if path.is_dir():
            files.extend(sorted(path.rglob("*.swift")))
    for name in FEED_FILES:
        path = root / name
        if path.is_file():
            files.append(path)
    return files


def code_of(line: str) -> str:
    """The line without a `//` comment (outside a string literal)."""
    quoted = False
    i = 0
    while i < len(line):
        c = line[i]
        if c == "\\" and quoted:
            i += 2
            continue
        if c == '"':
            quoted = not quoted
        elif not quoted and line.startswith("//", i):
            return line[:i]
        i += 1
    return line


def findings(root: Path) -> list[str]:
    out: list[str] = []
    for path in feed_files(root):
        rel = path.relative_to(root)
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if ALLOW in line:
                continue
            code = code_of(line)
            if RAW_READ.search(code):
                out.append(f"{rel}:{number}: reads the raw sessionId; key the feed on "
                           "AcpmuxPendingReads.sessionKey(_:) (qualifiedSessionId for a peer)")
            elif PEER_READ.search(code) and HAND_KEY.search(code):
                out.append(f"{rel}:{number}: builds a peer/id key by hand; use "
                           "AcpmuxPendingReads.sessionKey(_:)")
    return out


def main(argv: list[str]) -> int:
    if len(argv) > 2 or (len(argv) == 2 and argv[1].startswith("-")):
        print(__doc__.strip().splitlines()[-2], file=sys.stderr)
        return 2
    root = Path(argv[1]) if len(argv) == 2 else Path(__file__).resolve().parents[2]
    found = findings(root)
    for finding in found:
        print(finding, file=sys.stderr)
    if found:
        print(f"check-feed-session-key: {len(found)} finding(s). A line that must read it carries "
              f"`{ALLOW} <reason>`.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
