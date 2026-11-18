#!/usr/bin/env python3
"""Every network fetch in a NEXT nightly step retries (or is named here with why it need not).

On 2026-11-18 NEXT nightly run 44232805509 died in "Assemble the Computer Use helper": one
`git clone` of manaflow-ai/cmux-cua in scripts/build-cmux-cua.sh stalled for 9 minutes on the
signer's link (`curl 56 Recv failure: Operation timed out`, exit 128), with no retry and no
second source, and the NEXT feed then lagged the newest landing by 684 minutes. The cargo step
right after it already retried three times; the fetch in front of it did not.

This test reads .github/workflows/nightly.yml, every scripts/ci/nightly-steps/*.sh and
scripts/build-cmux-cua.sh, and fails on a fetch (git clone/fetch/pull/ls-remote/submodule
update, npm install, curl, wget, gh release download) that has none of:
- scripts/ci/nightly-steps/net-retry.sh, scripts/ci/git_fetch_retry.py, scripts/ci/init-submodule.sh,
  or the workflow's own `retry` wrapper;
- curl's `--retry`;
- an inline bounded loop: `... && break` on the line, or a `for attempt|t|try in ...` within the
  four lines before it.
A fetch that needs no retry (a local path, a read that tolerates absence) is listed in
NO_RETRY_NEEDED with its reason. Handbook: cmuxterm-hq docs/handbook/nightly-fetch-without-retry.md.
"""
from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCES = [
    ROOT / ".github/workflows/nightly.yml",
    ROOT / "scripts/build-cmux-cua.sh",
    *sorted((ROOT / "scripts/ci/nightly-steps").glob("*.sh")),
]
HELPER = ROOT / "scripts/ci/nightly-steps/net-retry.sh"

FETCH = re.compile(
    r"\bgit\b(?:\s+-[cC]\s+\S+)*\s+(?:clone|fetch|pull|ls-remote)\b"
    r"|\bgit\b.*\bsubmodule\s+update\b"
    r"|\bnpm\s+(?:i|install|ci)\b"
    r"|\bcurl\s"
    r"|\bwget\s"
    r"|\bgh\s+release\s+download\b"
)
RETRIED = re.compile(
    r"net-retry\.sh|git_fetch_retry\.py|init-submodule\.sh|--retry\b|&&\s*break\b|^\s*retry\s"
)
LOOP = re.compile(r"\b(?:for|until|while)\s+(?:attempt|t|try|tries|i)\b|\bfor\s+\w+\s+in\s+1\s+2\s+3\b")

# (file relative to the repo, a substring of the line) -> why it needs no retry.
NO_RETRY_NEEDED = {
    ("scripts/ci/nightly-steps/app-host-build-root.sh", 'fetch -q --no-tags "$root/src"'):
        "a local path, not the network; `|| true` already tolerates a miss",
    ("scripts/ci/nightly-steps/ensure-gh.sh", "command -v curl"):
        "a PATH probe, not a fetch",
    ("scripts/ci/nightly-steps/ensure-gh.sh", "githubcli-archive-keyring.gpg"):
        "the second source: the release-asset download above it already retries",
    ("scripts/ci/nightly-steps/publish-next-feed-keep-nightly.sh", 'code="curl exit'):
        "a message naming curl's status, not a fetch",
    ("scripts/ci/nightly-steps/publish-next-feed-before.sh", "(curl exit"):
        "a message naming curl's status, not a fetch",
    ("scripts/ci/nightly-steps/release-notes-sign.sh", "notes/index.json"):
        "the previous notes index: a miss starts a fresh index, never fails the step",
    ("scripts/ci/nightly-steps/release-notes-start-span.sh", "notes/index.json"):
        "the previous notes index: a miss starts a fresh span, never fails the step",
    ("scripts/ci/nightly-steps/verify-final-dmg-bundle-size-budget.sh", "curl -sfIL --max-time 20"):
        "the previous DMG's size for a budget note: a miss skips the comparison",
    ("scripts/build-cmux-cua.sh", 'git clone --quiet --no-checkout "$CMUX_CUA_SOURCE_BUNDLE"'):
        "a clone from a local git bundle (the controller store or R2 put it there)",
}


def logical_lines(text: str) -> list[tuple[int, str]]:
    """(first line number, text) per command line, backslash continuations joined, comments dropped."""
    out: list[tuple[int, str]] = []
    pending, start = "", 0
    for number, line in enumerate(text.splitlines(), 1):
        if not pending and line.lstrip().startswith("#"):
            continue
        if not pending:
            start = number
        if line.endswith("\\"):
            pending += line[:-1] + " "
            continue
        out.append((start, pending + line))
        pending = ""
    if pending:
        out.append((start, pending))
    return out


def unretried(path: Path, text: str) -> list[str]:
    rel = path.relative_to(ROOT).as_posix() if path.is_relative_to(ROOT) else path.name
    lines = logical_lines(text)
    found: list[str] = []
    for index, (number, line) in enumerate(lines):
        if not FETCH.search(line) or RETRIED.search(line):
            continue
        if any(LOOP.search(before) for _, before in lines[max(0, index - 4):index]):
            continue
        if any(rel == file and needle in line for (file, needle) in NO_RETRY_NEEDED):
            continue
        found.append(f"{rel}:{number}: {line.strip()}")
    return found


class NightlyNetworkFetchRetry(unittest.TestCase):
    def test_every_nightly_fetch_retries(self) -> None:
        found = [hit for path in SOURCES for hit in unretried(path, path.read_text(encoding="utf-8"))]
        self.assertEqual(found, [], "a nightly step fetches over the network with no retry; wrap it in "
                         "scripts/ci/nightly-steps/net-retry.sh (git goes through git_fetch_retry.py), "
                         "or name it in NO_RETRY_NEEDED with why:\n" + "\n".join(found))

    def test_every_no_retry_entry_still_matches(self) -> None:
        stale = []
        for (file, needle) in NO_RETRY_NEEDED:
            path = ROOT / file
            if not path.exists() or needle not in path.read_text(encoding="utf-8"):
                stale.append(f"{file}: {needle}")
        self.assertEqual(stale, [], "NO_RETRY_NEEDED entries that match nothing; remove them")

    def test_detector_catches_the_cua_clone(self) -> None:
        # The exact shape that failed run 44232805509.
        bare = 'TMPDIR_CLONE="$(mktemp -d)"\ngit clone "$CMUX_CUA_REPO_URL" "$TMPDIR_CLONE"\n'
        self.assertEqual(len(unretried(ROOT / "scripts/x.sh", bare)), 1)
        for retried in (
            '"$(dirname "${BASH_SOURCE[0]}")/net-retry.sh" -- git fetch --no-tags origin "$SHA"\n',
            'curl -fsSL --retry 3 -o f "$URL"\n',
            'for t in 1 2 3; do npm install --global x && break; sleep 5; done\n',
            'for attempt in 1 2 3; do\n  if git -C d fetch --depth 1 origin "$SHA"; then break; fi\ndone\n',
        ):
            self.assertEqual(unretried(ROOT / "scripts/x.sh", retried), [], retried)

    def test_helper_retries_and_routes_git_through_git_fetch_retry(self) -> None:
        text = HELPER.read_text(encoding="utf-8")
        self.assertIn("git_fetch_retry.py", text)
        self.assertRegex(text, r"backoff=\(\d+ \d+ \d+\)")
        self.assertTrue(HELPER.stat().st_mode & 0o111, "net-retry.sh must be executable")


if __name__ == "__main__":
    unittest.main()
