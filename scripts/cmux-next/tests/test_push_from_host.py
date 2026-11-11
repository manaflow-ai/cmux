#!/usr/bin/env python3
"""scripts/cmux-next/push-from-host.sh pushes through another Mac, with that Mac's pre-push hook as the gate.

The "other Mac" here is a second clone under a temporary home, reached through an `ssh` on PATH that runs the
command in this machine's bash with that home. `gh` is a stand-in that prints a token; the remote is a local
bare repository. So the test runs the script's real steps: the bundle, the hook, the push, the rebase.

  python3 scripts/cmux-next/tests/test_push_from_host.py
"""
import importlib.util
import os
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

# tests/git_fixture_env.py turns off git's background maintenance in temp repos.
_git_fixture_env = importlib.util.spec_from_file_location(
    "git_fixture_env",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "tests", "git_fixture_env.py"),
)
git_fixture_env = importlib.util.module_from_spec(_git_fixture_env)
_git_fixture_env.loader.exec_module(git_fixture_env)

SCRIPT = Path(__file__).resolve().parents[1] / "push-from-host.sh"
TOKEN = "test-token-never-printed"
FAKE_SSH = """#!/bin/bash
while [[ "$1" == -o ]]; do shift 2; done
shift  # the host
export HOME="$FAKE_HOST_HOME"
exec bash -c "$*"
"""
FAKE_DF = """#!/bin/bash
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "/dev/fake 999999999 1 $(cat "$FAKE_FREE_KB_FILE") 1% /"
"""
HOOK = """#!/bin/bash
cat > /dev/null
echo ran >> "$FAKE_HOST_HOME/hook.log"
if [[ -f "$FAKE_HOST_HOME/refuse" ]]; then echo "pre-push: refused in fixture" >&2; exit 1; fi
"""


class PushFromHostTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="cmux-push-from-host-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.host_home = self.root / "host-home"
        self.origin = self.root / "origin.git"
        self.work = self.root / "work"
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        for name, text in (("ssh", FAKE_SSH), ("gh", f"#!/bin/bash\necho {TOKEN}\n")):
            (bin_dir / name).write_text(text)
            (bin_dir / name).chmod(0o755)
        self.bin_dir = bin_dir
        config = self.root / "gitconfig"
        # The fixture's own global config, with the helper's maintenance opt-out (it replaces the helper's file).
        config.write_text("[user]\n\tname = Fixture\n\temail = fixture@example.invalid\n[init]\n\tdefaultBranch = feat-cmux-next\n"
                          + git_fixture_env.CONFIG_FILE_OPT_OUT)
        # No GIT_* from the caller (a pre-push hook's GIT_DIR would aim every git here at the caller's repository),
        # then the helper's GIT_CONFIG_COUNT opt-out back on top.
        self.env = git_fixture_env.fixture_env(
            {key: value for key, value in os.environ.items() if not key.startswith("GIT_")})
        self.env.update(PATH=f"{bin_dir}:{self.env.get('PATH', '')}", GIT_CONFIG_GLOBAL=str(config),
                        GIT_CONFIG_NOSYSTEM="1", FAKE_HOST_HOME=str(self.host_home))
        git_fixture_env.init_repo(self.origin, "--bare", env=self.env)
        self.run_ok("git", "clone", "--quiet", str(self.origin), str(self.work))
        self.commit(self.work, "base.txt", "base\n", "base")
        self.git(self.work, "push", "--quiet", "origin", "HEAD:refs/heads/feat-cmux-next")
        host_repo = self.host_home / "fun/cmux"
        host_repo.parent.mkdir(parents=True)
        self.run_ok("git", "clone", "--quiet", str(self.origin), str(host_repo))
        hooks = self.host_home / "hooks"
        hooks.mkdir()
        (hooks / "pre-push").write_text(HOOK)
        (hooks / "pre-push").chmod(0o755)
        self.git(host_repo, "config", "core.hooksPath", str(hooks))

    def run_ok(self, *command, cwd=None):
        return subprocess.run(command, cwd=cwd, env=self.env, text=True, capture_output=True, check=True).stdout

    def git(self, repo, *args):
        return self.run_ok("git", "-C", str(repo), *args).strip()

    def commit(self, repo, name, text, message):
        (Path(repo) / name).write_text(text)
        self.git(repo, "add", "-A")
        self.git(repo, "commit", "--quiet", "-m", message)
        return self.git(repo, "rev-parse", "HEAD")

    def remote_head(self, branch):
        done = subprocess.run(["git", "-C", str(self.origin), "rev-parse", "--verify", "--quiet", f"refs/heads/{branch}"],
                              env=self.env, text=True, capture_output=True)
        return done.stdout.strip()

    def push(self, *args):
        done = subprocess.run(["bash", str(SCRIPT), "--host", "fake-host", *args], cwd=self.work, env=self.env,
                              text=True, capture_output=True)
        self.assertNotIn(TOKEN, done.stdout + done.stderr, "the token must never be printed")
        return done

    def leftovers(self, sha):
        return sorted(Path("/tmp").glob(f"push-from-host-{sha[:12]}-*"))

    def test_a_push_goes_through_the_hosts_hook_and_leaves_nothing_behind(self):
        sha = self.commit(self.work, "a.txt", "a\n", "a change")

        done = self.push("topic")

        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(self.remote_head("topic"), sha)
        self.assertEqual((self.host_home / "hook.log").read_text(), "ran\n", "the host's pre-push hook is the gate")
        self.assertEqual(done.stdout.strip().splitlines()[-1], sha)
        self.assertEqual(self.leftovers(sha), [])
        self.assertEqual(len(self.git(self.host_home / "fun/cmux", "worktree", "list").splitlines()), 1)

    def test_a_push_the_hosts_hook_refuses_reaches_no_branch(self):
        sha = self.commit(self.work, "a.txt", "a\n", "a change")
        (self.host_home / "refuse").write_text("")

        done = self.push("topic")

        self.assertEqual(done.returncode, 1, done.stderr)
        self.assertIn("refused in fixture", done.stderr)
        self.assertEqual(self.remote_head("topic"), "")
        self.assertEqual(self.leftovers(sha), [])

    def moved_branch(self):
        """A local commit on the old head of feat-cmux-next, which then moves on the remote."""
        sha = self.commit(self.work, "mine.txt", "mine\n", "my change")
        other = self.root / "other"
        self.run_ok("git", "clone", "--quiet", str(self.origin), str(other))
        moved = self.commit(other, "theirs.txt", "theirs\n", "their change")
        self.git(other, "push", "--quiet", "origin", "HEAD:refs/heads/feat-cmux-next")
        return sha, moved

    def test_a_branch_that_moved_refuses_a_plain_push_and_is_never_forced(self):
        _sha, moved = self.moved_branch()

        done = self.push("feat-cmux-next")

        self.assertEqual(done.returncode, 1, done.stderr)
        self.assertEqual(self.remote_head("feat-cmux-next"), moved)

    def test_rebase_puts_the_commit_on_the_branchs_new_head_and_prints_it(self):
        sha, moved = self.moved_branch()

        done = self.push("--rebase", "feat-cmux-next")

        self.assertEqual(done.returncode, 0, done.stderr)
        head = self.remote_head("feat-cmux-next")
        self.assertNotEqual(head, sha)
        self.assertEqual(self.git(self.origin, "rev-parse", f"{head}^"), moved)
        self.assertEqual(self.git(self.origin, "log", "-1", "--format=%s", head), "my change")
        self.assertEqual(done.stdout.strip().splitlines()[-1], head)
        self.assertIn("fetch and rebase", done.stderr)

    # 2026-11-10: the push host went offline at 99% full. A killed run leaves its 2 GB checkout in /tmp.
    def test_a_push_removes_the_leftovers_of_old_runs_and_keeps_new_ones(self):
        # The script sweeps /tmp/push-from-host-* on the host, so the leftovers live there; mkdtemp/mkstemp make
        # each one fresh and exclusive, so no name is one another user could create first.
        old_tree = Path(tempfile.mkdtemp(prefix="push-from-host-", suffix="-1.tree", dir="/tmp"))
        handle, name = tempfile.mkstemp(prefix="push-from-host-", suffix="-1.bundle", dir="/tmp")
        os.close(handle)
        old_bundle = Path(name)
        handle, name = tempfile.mkstemp(prefix="push-from-host-", suffix="-2.bundle", dir="/tmp")
        os.close(handle)
        fresh = Path(name)
        (old_tree / "file").write_text("x")
        old_bundle.write_text("x")
        fresh.write_text("x")
        self.addCleanup(lambda: [subprocess.run(["rm", "-rf", str(path)]) for path in (old_tree, old_bundle, fresh)])
        three_hours_ago = time.time() - 3 * 3600
        for path in (old_tree, old_bundle):
            os.utime(path, (three_hours_ago, three_hours_ago))
        self.commit(self.work, "a.txt", "a\n", "a change")

        done = self.push("topic")

        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertFalse(old_tree.exists(), "a leftover checkout of a killed run stayed")
        self.assertFalse(old_bundle.exists())
        self.assertTrue(fresh.exists(), "a file of a push that runs now was removed")
        self.assertIn("leftover", done.stderr)

    def with_free_kb(self, kilobytes):
        (self.bin_dir / "df").write_text(FAKE_DF)
        (self.bin_dir / "df").chmod(0o755)
        free = self.root / "free-kb"
        free.write_text(str(kilobytes))
        self.env["FAKE_FREE_KB_FILE"] = str(free)

    def test_a_host_under_20_gb_free_pushes_and_warns(self):
        self.with_free_kb(10 * 1048576)
        sha = self.commit(self.work, "a.txt", "a\n", "a change")

        done = self.push("topic")

        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(self.remote_head("topic"), sha)
        self.assertRegex(done.stderr, r"WARNING: \S+ has only 10 GB of disk free")

    def test_a_host_with_no_room_for_the_checkout_pushes_nothing_and_says_why(self):
        self.with_free_kb(1 * 1048576)
        sha = self.commit(self.work, "a.txt", "a\n", "a change")

        done = self.push("topic")

        self.assertEqual(done.returncode, 2, done.stderr)
        self.assertEqual(self.remote_head("topic"), "")
        self.assertIn("1 GB of disk free", done.stderr)
        self.assertFalse((self.host_home / "hook.log").exists())
        # The refusal exits before the push; it still removes the bundle and script it was sent (they leaked, and the
        # next test's commit, the same sha within a second, found them).
        self.assertEqual(self.leftovers(sha), [])

    def test_a_host_with_room_says_nothing_about_disk(self):
        self.with_free_kb(200 * 1048576)
        self.commit(self.work, "a.txt", "a\n", "a change")

        done = self.push("topic")

        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertNotIn("disk free", done.stderr)


if __name__ == "__main__":
    unittest.main()
