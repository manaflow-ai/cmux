#!/usr/bin/env python3
"""build-smoke-candidate.sh finds the dogfood bench mapping where the commit keeps it (--dry-run: nothing pushed).

Tip watcher, 2026-11-03 17:11Z: on feat 78a2a32b840e the script stopped with exit 3 ("the bench mapping
c6d35671018 does not apply"). feat now has its own mapping, scripts/cmux-next/cmux-next.dogfood.conf (#32872,
#33413), so the old cherry-pick of the Resources/build mapping conflicts with reload.sh; and feat's conf names
chrome-parity-* and cap<sha10>, not the watcher's feat-tip-fixes-<sha10> tag.

    python3 scripts/journeys/test_build_smoke_candidate.py
"""
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "build-smoke-candidate.sh"
NATIVE = "scripts/cmux-next/cmux-next.dogfood.conf"
OLD = "Resources/build/cmux-next.dogfood.conf"
RELOAD = "# RELEASE_FLAG: 1 when --release\nRELEASE_FLAG=0\n"


def git(repo, *args):
    return subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True, check=True).stdout.strip()


class Candidate(unittest.TestCase):
    def repo(self, files):
        tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp, True)
        repo = tmp / "clone"
        repo.mkdir()
        git(repo, "init", "-q", "-b", "main")
        git(repo, "config", "user.email", "t@example.com")
        git(repo, "config", "user.name", "t")
        git(repo, "config", "core.hooksPath", "/dev/null")  # the test repo has no hooks of its own
        (repo / "scripts" / "journeys").mkdir(parents=True)
        shutil.copy(SCRIPT, repo / "scripts" / "journeys" / SCRIPT.name)
        for path, text in files.items():
            (repo / path).parent.mkdir(parents=True, exist_ok=True)
            (repo / path).write_text(text)
        git(repo, "add", "-A")
        git(repo, "commit", "-q", "-m", "base")
        return repo, git(repo, "rev-parse", "HEAD")

    def dry(self, repo, sha, tag):
        done = subprocess.run(["bash", str(repo / "scripts" / "journeys" / SCRIPT.name), sha, "--tag", tag, "--dry-run",
                               "--worktree", str(repo.parent / "wt")], capture_output=True, text=True, timeout=60)
        head = next((l.split()[4] for l in done.stdout.splitlines() if l.startswith("dry run: would push")), None)
        return done, head

    def test_feat_native_mapping_takes_the_watchers_tag_with_one_conf_commit(self):
        conf = "# comment\nrelease_bench_tags=chrome-parity-* cap[0-9a-f]\n"
        repo, base = self.repo({NATIVE: conf, "scripts/reload.sh": RELOAD})
        done, head = self.dry(repo, base, "feat-tip-fixes-0123456789")
        self.assertEqual(done.returncode, 0, done.stderr + done.stdout)
        self.assertNotEqual(head, base)
        self.assertEqual(git(repo, "rev-parse", f"{head}^"), base)
        self.assertEqual(git(repo, "diff", "--name-only", base, head), NATIVE)  # no app source change
        lines = [l for l in git(repo, "show", f"{head}:{NATIVE}").splitlines() if l.startswith("release_bench_tags=")]
        self.assertEqual(lines[-1], "release_bench_tags=chrome-parity-* cap[0-9a-f] feat-tip-fixes-*")  # the last line counts

    def test_feat_native_mapping_with_a_matching_tag_adds_nothing(self):
        repo, base = self.repo({NATIVE: "release_bench_tags=chrome-parity-*\n", "scripts/reload.sh": RELOAD})
        done, head = self.dry(repo, base, "chrome-parity-x")
        self.assertEqual(done.returncode, 0, done.stderr + done.stdout)
        self.assertEqual(head, base)

    def test_a_dogfood_line_with_the_old_mapping_adds_nothing(self):
        repo, base = self.repo({OLD: "release_bench_tags=chrome-parity-* feat-tip-fixes-*\n", "scripts/reload.sh": RELOAD})
        done, head = self.dry(repo, base, "feat-tip-fixes-0123456789")
        self.assertEqual(done.returncode, 0, done.stderr + done.stdout)
        self.assertEqual(head, base)

    def test_a_native_conf_with_no_tags_is_refused(self):
        repo, base = self.repo({NATIVE: "release_bench_tags=\n", "scripts/reload.sh": RELOAD})
        done, _ = self.dry(repo, base, "feat-tip-fixes-0123456789")
        self.assertEqual(done.returncode, 2)
        self.assertIn("names no release_bench_tags", done.stderr)


if __name__ == "__main__":
    unittest.main()
