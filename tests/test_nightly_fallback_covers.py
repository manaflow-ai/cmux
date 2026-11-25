#!/usr/bin/env python3
"""Detector for a nightly fallback client older than a daemon capability the app needs.

Replays run 44975559258 (2026-11-22): the build commit's tree was still publishing, so the resolver
picked the newest published tree (client 602f51e1, 24 commits behind), and "Bundle the cmux-tui
client" failed 20 min in at check-daemon-capabilities.sh: "the bundled static capability manifest is
missing language-packs-v1", which #45928 added to the daemon and the app's list together.
scripts/ci/nightly_fallback_covers.py answers it at resolve time from git; resolve-tree-pending.sh
drops such a fallback, so the bundle step waits for the build commit's own tree instead
(scripts/cmux-next/tests/nightly-tree-at-install.test.sh runs the resolver on that case).
"""
from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/nightly_fallback_covers.py"

WORKSPACE = '[workspace]\nmembers = ["crates/cmux-tui-core"]\n'
CORE_MANIFEST = '[package]\nname = "cmux-tui-core"\n\n[dependencies]\nserde = "1"\n'
LIST = 'pub const LIST: &[&str] = &["identify-v1", "history-v1"];\n'


def git(repo: Path, *args: str) -> str:
    env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t",
           "GIT_COMMITTER_EMAIL": "t@t", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"}
    return subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True, check=True,
                          env=env).stdout.strip()


def write(repo: Path, rel: str, text: str) -> None:
    path = repo / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def capabilities_json(names: list[str]) -> str:
    quoted = ", ".join(f'"{n}"' for n in names)
    return f'{{"comment": "", "required": ["identify-v1"], "optional": [{quoted}], "unservedByBundledDaemon": []}}\n'


class FallbackCovers(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self.tmp.name)
        git(self.repo, "init", "-q", "-b", "main")
        write(self.repo, "cmux-tui/Cargo.toml", WORKSPACE)
        write(self.repo, "cmux-tui/crates/cmux-tui-core/Cargo.toml", CORE_MANIFEST)
        write(self.repo, "cmux-tui/crates/cmux-tui-core/src/server/capabilities.rs", LIST)
        # A capability the app lists that the parser cannot see on either side ("history-v1" is in
        # the list above; "ws-listen-v1" is defined nowhere the parser reads): never a refusal.
        write(self.repo, "plans/cmux-next/daemon-capabilities.json", capabilities_json(["history-v1", "ws-listen-v1"]))
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-qm", "old client")
        self.old = git(self.repo, "rev-parse", "HEAD")

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def run_covers(self, app: str, client: str) -> subprocess.CompletedProcess:
        return subprocess.run(["python3", "-I", str(SCRIPT), "--repo", str(self.repo), "--app-commit", app,
                               "--client-commit", client], capture_output=True, text=True, timeout=120)

    def add_language_packs(self) -> str:
        # #45928's shape: the daemon constant and the app's list in one commit.
        write(self.repo, "cmux-tui/crates/cmux-tui-core/src/language_packs.rs",
              'pub(crate) const CAPABILITY: &str = "language-packs-v1";\n')
        write(self.repo, "plans/cmux-next/daemon-capabilities.json",
              capabilities_json(["history-v1", "ws-listen-v1", "language-packs-v1"]))
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-qm", "language packs")
        return git(self.repo, "rev-parse", "HEAD")

    def test_old_client_without_a_capability_the_app_lists_is_refused(self) -> None:
        tip = self.add_language_packs()
        result = self.run_covers(tip, self.old)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("missing=language-packs-v1", result.stdout)

    def test_client_at_the_build_commit_covers(self) -> None:
        tip = self.add_language_packs()
        result = self.run_covers(tip, tip)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("missing=\n", result.stdout + "\n")

    def test_old_client_covers_when_no_capability_was_added(self) -> None:
        write(self.repo, "README.md", "unrelated\n")
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-qm", "unrelated")
        result = self.run_covers(git(self.repo, "rev-parse", "HEAD"), self.old)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_a_daemon_capability_the_app_does_not_list_is_not_needed(self) -> None:
        write(self.repo, "cmux-tui/crates/cmux-tui-core/src/extra.rs",
              'pub const EXTRA_CAPABILITY: &str = "extra-v1";\n')
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-qm", "daemon only")
        result = self.run_covers(git(self.repo, "rev-parse", "HEAD"), self.old)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_an_unreadable_client_commit_is_could_not_tell(self) -> None:
        tip = self.add_language_packs()
        result = self.run_covers(tip, "0" * 40)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("missing=", result.stdout)


if __name__ == "__main__":
    unittest.main()
