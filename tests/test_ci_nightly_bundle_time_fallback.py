#!/usr/bin/env python3
"""A pending tip tree whose artifacts run failed ships the newest published tree, not a failed NIGHTLY.

Leo, 2026-11-26: "cant we just accept the nightly using an older tui version".

Nightlies 46114171177, 46116717235 and 46119598955 (2026-11-28) read "TREE_FALLBACK: ": at resolve
time the newest trees within 24 h were still publishing. The tip's own cmux-tui artifacts run then
failed build-linux, and "Bundle the cmux-tui client" failed, though a tree 32 commits (0 h) behind was
published by then. The step now searches again itself (pin-cmux-tui.sh resolve-newest-published)
when resolve handed it no fallback.

Run: python3 tests/test_ci_nightly_bundle_time_fallback.py (a second; fakes only, no network).
"""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
STEP = ROOT / "scripts/ci/nightly-steps/app-bundle-cmux-tui-client.sh"
TIP_KEY = "a" * 40
TIP_COMMIT = "b" * 40
OLD_KEY = "c" * 40
OLD_COMMIT = "d" * 40


class BundleTimeFallback(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="nightly-bundle-fallback."))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        repo = self.tmp / "repo"
        (repo / "scripts/ci/nightly-steps").mkdir(parents=True)
        (repo / "scripts/cmux-next").mkdir(parents=True)
        shutil.copy(STEP, repo / "scripts/ci/nightly-steps" / STEP.name)
        shutil.copy(ROOT / "scripts/ci/timeout.sh", repo / "scripts/ci/timeout.sh")
        self.record = self.tmp / "record"
        stubs = {
            "scripts/install-cmux-tui-client.sh": '#!/usr/bin/env bash\necho "install $*" >> "$RECORD"\n',
            "scripts/strip-release-bundle.sh": "#!/bin/sh\n",
            "scripts/cmux-next/write-cmux-tui-version.sh": '#!/usr/bin/env bash\necho "version $*" >> "$RECORD"\n',
            "scripts/cmux-next/check-daemon-capabilities.sh": "#!/bin/sh\n",
            # The tip's tree never publishes: its artifacts run failed.
            "scripts/cmux-next/await-tree-client.sh":
                '#!/usr/bin/env bash\necho "await $*" >> "$RECORD"\n'
                'if [ -n "${AWAIT_PUBLISHES:-}" ]; then echo "$AWAIT_PUBLISHES"; exit 0; fi\n'
                'echo "error: the run of tip is failed build-linux; nothing will publish it in time" >&2; exit 1\n',
            # SEARCH_OUT: what resolve-newest-published finds now (empty: nothing within 24 h).
            "scripts/cmux-next/pin-cmux-tui.sh":
                '#!/usr/bin/env bash\n[ "$1" = resolve-newest-published ] || exit 0\n'
                'echo "search max=$CMUX_TUI_TREE_SEARCH_COMMITS tipwait=$CMUX_TUI_TREE_TIP_WAIT_SECONDS'
                ' dispatch=[$CMUX_TUI_TREE_DISPATCH] age=${CMUX_TUI_TREE_MAX_AGE_HOURS:-default}" >> "$RECORD"\n'
                '[ -n "${SEARCH_OUT:-}" ] || { echo "error: no published cmux-tui tree within 24 h" >&2; exit 1; }\n'
                'printf "%b" "$SEARCH_OUT"\n',
        }
        for rel, body in stubs.items():
            path = repo / rel
            path.write_text(body)
            path.chmod(0o755)
        self.repo = repo
        (self.tmp / "runner").mkdir()
        self.env = {
            "PATH": os.environ["PATH"], "HOME": str(self.tmp), "RECORD": str(self.record),
            "RUNNER_TEMP": str(self.tmp / "runner"), "GITHUB_OUTPUT": str(self.tmp / "out"),
            "GITHUB_STEP_SUMMARY": str(self.tmp / "summary"), "NIGHTLY_COMPILE_ARCHS": "arm64",
            "CMUX_TUI_CLIENT_COMMIT": TIP_COMMIT, "CMUX_TUI_CLIENT_KEY": TIP_KEY,
            "CMUX_TUI_CLIENT_CACHE": str(self.tmp / "cache"), "TREE_PENDING": "true",
            "TREE_CANDIDATES": TIP_COMMIT, "TREE_FALLBACK": "",
        }
        self.found = f"commit={OLD_COMMIT}\\nkey={OLD_KEY}\\nsource_commit={'e' * 40}\\nbehind=32\\n"

    def run_step(self, **env: str) -> tuple[subprocess.CompletedProcess[str], list[str], str]:
        self.record.unlink(missing_ok=True)
        (self.tmp / "out").unlink(missing_ok=True)
        result = subprocess.run(["bash", f"scripts/ci/nightly-steps/{STEP.name}"], cwd=self.repo,
                                env=dict(self.env, **env), capture_output=True, text=True, timeout=60)
        record = self.record.read_text().splitlines() if self.record.exists() else []
        out = (self.tmp / "out").read_text() if (self.tmp / "out").exists() else ""
        return result, record, out

    def test_no_resolve_fallback_and_a_failed_tip_run_bundles_the_tree_found_now(self) -> None:
        result, record, out = self.run_step(SEARCH_OUT=self.found)
        log = result.stdout + result.stderr
        self.assertEqual(result.returncode, 0, log)
        self.assertIn(f"tree=fallback", out)
        self.assertIn(f"key={OLD_KEY}", out)
        self.assertIn(f"commit={OLD_COMMIT}", out)
        self.assertTrue(any(line.startswith("install ") and OLD_COMMIT in line for line in record), record)
        # The search is the resolver's (no tip wait, no dispatch, its 24 h default bound).
        search = [line for line in record if line.startswith("search ")]
        self.assertEqual(search, ["search max=300 tipwait=0 dispatch=[] age=default"], record)
        # The build log says an older tree shipped and why.
        self.assertIn("resolve had no fallback tree; found tree " + OLD_KEY, log)
        self.assertIn("::warning title=cmux-tui client::the build commit's tree " + TIP_KEY, log)

    def test_the_tips_tree_still_wins_when_it_publishes_within_the_bounded_wait(self) -> None:
        result, record, out = self.run_step(SEARCH_OUT=self.found, AWAIT_PUBLISHES=TIP_COMMIT)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("tree=exact", out)
        self.assertIn(f"commit={TIP_COMMIT}", out)

    def test_a_tree_published_during_the_wait_is_found_by_the_second_search(self) -> None:
        # First search empty; the stub flips to a hit for the second (after the wait fails).
        flag = self.tmp / "searched"
        pin = self.repo / "scripts/cmux-next/pin-cmux-tui.sh"
        pin.write_text(pin.read_text().replace(
            '[ -n "${SEARCH_OUT:-}" ]',
            f'[ -e {flag} ] || {{ touch {flag}; echo "error: none yet" >&2; exit 1; }}; [ -n "${{SEARCH_OUT:-}}" ]'))
        result, record, out = self.run_step(SEARCH_OUT=self.found)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(sum(line.startswith("search ") for line in record), 2, record)
        self.assertIn("tree=fallback", out)
        self.assertIn(f"key={OLD_KEY}", out)

    def test_nothing_within_24_h_still_fails(self) -> None:
        result, record, out = self.run_step()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(sum(line.startswith("search ") for line in record), 2, record)
        self.assertNotIn("tree=", out)

    def test_fallback_off_never_searches(self) -> None:
        result, record, _ = self.run_step(SEARCH_OUT=self.found, CMUX_TUI_TREE_CLIENT_FALLBACK="off")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(line.startswith("search ") for line in record), record)

    def test_a_resolve_fallback_is_used_without_searching_again(self) -> None:
        result, record, out = self.run_step(SEARCH_OUT=self.found, TREE_FALLBACK=f"{'f' * 40} {'9' * 40}")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(any(line.startswith("search ") for line in record), record)
        self.assertIn(f"key={'9' * 40}", out)


if __name__ == "__main__":
    unittest.main()
