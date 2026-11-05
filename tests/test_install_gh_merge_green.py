#!/usr/bin/env python3
"""scripts/install-gh-merge-green.sh pins gh-merge-green to a tested origin/main snapshot.

On 2026-10-19 ~/.local/bin/gh-merge-green was a symlink into a live working
checkout; an agent switched its branch and edited the script in place, and the
half-edited file broke every session's merges. These tests build a fixture
origin, install from it, and check that edits in the source checkout or the
snapshot never change what the installed command runs, and that a newer
origin/main is installed only after its tests pass.
"""
from __future__ import annotations

import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import unittest

import git_fixture_env  # disables git auto maintenance

SOURCE = Path(__file__).resolve().parents[1]
INSTALLER = "scripts/install-gh-merge-green.sh"
LAUNCHER = "scripts/gh-merge-green-pinned"

STUB_TEST = """import unittest

class Stub(unittest.TestCase):
    def test_ok(self):
        self.assertTrue({ok})
"""

# `glaeda-gh checks REPO SHA... --json`: the main push's "CI fast guards" result
# for every SHA, from the verdict file next to it (success, failure or pending).
FAKE_GLAEDA = """#!/usr/bin/env python3
import json, pathlib, sys
here = pathlib.Path(sys.argv[0]).parent
with open(here / "calls", "a") as log:
    log.write(" ".join(sys.argv[1:]) + "\\n")
verdict = (here / "verdict").read_text().strip()
shas = [a for a in sys.argv[1:] if len(a) == 40]
if verdict == "pending":
    print(json.dumps({"heads": {}, "unread": {s: "not read yet" for s in shas}}))
else:
    found = {"CI fast guards / CI fast guards": ["completed", verdict]}
    print(json.dumps({"heads": {s: {"found": found} for s in shas}, "unread": {}}))
"""


class DefaultTestsCoverTheHelpersTests(unittest.TestCase):
    """An install runs DEFAULT_TESTS before it trusts a new main. Every scripts/ci helper gh-merge-green runs whose
    tests/test_<helper>.py exists must be among them: cmux#23516 added merge_check_paths.py and its tests, but not
    the module here, so an install never ran them."""

    def test_every_helper_with_tests_is_in_default_tests(self):
        import re
        helper = (SOURCE / "scripts" / "gh-merge-green").read_text()
        installer = (SOURCE / INSTALLER).read_text()
        listed = set(re.search(r'^DEFAULT_TESTS="([^"]*)"', installer, re.M).group(1).split())
        missing = sorted(f"tests.test_{name}" for name in set(re.findall(r"\bci/([a-z_]+)\.py", helper))
                         if (SOURCE / "tests" / f"test_{name}.py").is_file() and f"tests.test_{name}" not in listed)
        self.assertEqual(missing, [], "add these to DEFAULT_TESTS in " + INSTALLER)


class InstallGhMergeGreenTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="gh-merge-green-install-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.home = self.root / "state"
        self.bin = self.root / "bin"
        self.origin = self.root / "origin.git"
        self.clone = self.root / "clone"
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith(("GIT_", "GH_MERGE_GREEN_"))}
        global_config = self.root / "gitconfig"
        global_config.write_text("[user]\n\tname = Test\n\temail = test@example.com\n")
        self.env.update(
            HOME=str(self.root),
            GIT_CONFIG_NOSYSTEM="1",
            GIT_CONFIG_GLOBAL=str(global_config),
            GH_MERGE_GREEN_HOME=str(self.home),
            GH_MERGE_GREEN_INSTALL_ANY_ORIGIN="1",
            GH_MERGE_GREEN_INSTALL_TESTS="tests.test_stub",
            GH_MERGE_GREEN_UPDATE_INTERVAL="999999999",
        )
        git_fixture_env.without_auto_maintenance(self.env)
        self.run_ok("git", "init", "--quiet", "--bare", "--initial-branch=main", str(self.origin))
        self.run_ok("git", "clone", "--quiet", str(self.origin), str(self.clone))
        self.commit_version("v1", tests_pass=True)

    def tearDown(self):
        # Snapshot files are read-only; let TemporaryDirectory remove them.
        for path in self.root.rglob("*"):
            if path.is_file() and not path.is_symlink():
                path.chmod(path.stat().st_mode | stat.S_IWUSR)

    def run_ok(self, *argv, cwd=None):
        return self.assert_ok(self.run_cmd(*argv, cwd=cwd))

    def assert_ok(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def run_cmd(self, *argv, cwd=None):
        return subprocess.run(argv, cwd=cwd, env=self.env, capture_output=True, text=True, timeout=120)

    def write(self, relative, text, mode=0o644):
        path = self.clone / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        path.chmod(mode)

    def commit_version(self, version, tests_pass):
        for relative in (INSTALLER, LAUNCHER, "tests/git_fixture_env.py"):
            target = self.clone / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(SOURCE / relative, target)
            target.chmod(0o755)
        self.write("scripts/gh-merge-green", f'#!/usr/bin/env bash\necho "{version} $*"\n', 0o755)
        self.write("scripts/ci/helper.py", f"VERSION = {version!r}\n")
        self.write("tests/test_stub.py", STUB_TEST.format(ok=tests_pass))
        self.run_ok("git", "add", "-A", cwd=self.clone)
        self.run_ok("git", "commit", "--quiet", "-m", version, cwd=self.clone)
        self.run_ok("git", "push", "--quiet", "origin", "HEAD:main", cwd=self.clone)
        return self.run_ok("git", "rev-parse", "HEAD", cwd=self.clone).stdout.strip()

    def install(self, *extra):
        return self.run_cmd(str(SOURCE / INSTALLER), "install", "--repo", str(self.clone),
                            "--bin", str(self.bin), *extra)

    def installer(self, *argv):
        return self.run_cmd(str(self.home / "current" / INSTALLER), *argv)

    def gh_merge_green(self, *argv):
        return self.run_cmd(str(self.bin / "gh-merge-green"), *argv)

    def test_installed_command_ignores_edits_and_branch_switches_in_the_source_checkout(self):
        self.assert_ok(self.install())
        self.assertEqual(self.gh_merge_green("owner/repo#1").stdout, "v1 owner/repo#1\n")

        # What broke merges on 2026-10-19: a branch switch plus a half-edited file.
        self.run_ok("git", "switch", "--quiet", "-c", "agent-wip", cwd=self.clone)
        self.write("scripts/gh-merge-green", "#!/usr/bin/env bash\nif then\n", 0o755)
        result = self.gh_merge_green("owner/repo#1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "v1 owner/repo#1\n")

    def test_install_keeps_spotlights_marker_out_of_git_status(self):
        """Spotlight's .metadata_never_index marker is not a change: the managed clone's
        info/exclude lists it, so git status stays clean for every worktree of the clone."""
        self.assert_ok(self.install())
        (self.clone / ".metadata_never_index").touch()
        status = self.run_ok("git", "status", "--porcelain", "--untracked-files=all", cwd=self.clone).stdout
        self.assertEqual(status, "")
        self.assert_ok(self.install())  # a second install does not list it twice
        exclude = Path(self.run_ok("git", "rev-parse", "--path-format=absolute", "--git-common-dir",
                                   cwd=self.clone).stdout.strip()) / "info" / "exclude"
        self.assertEqual(exclude.read_text().splitlines().count(".metadata_never_index"), 1)

    def test_an_in_place_edit_of_the_snapshot_is_restored_before_running(self):
        self.assert_ok(self.install())
        script = (self.home / "current" / "scripts" / "gh-merge-green").resolve()
        self.assertEqual(script.stat().st_mode & 0o222, 0, "snapshot files are installed read-only")
        script.chmod(0o755)
        script.write_text("#!/usr/bin/env bash\nif then\n")

        result = self.gh_merge_green("owner/repo#2")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "v1 owner/repo#2\n")
        self.assertIn("edited in place", result.stderr)
        self.assertEqual(script.stat().st_mode & 0o222, 0)

    def test_update_installs_a_newer_origin_main_only_after_its_tests_pass(self):
        self.assert_ok(self.install())
        self.commit_version("v2", tests_pass=True)
        self.assert_ok(self.installer("update"))
        self.assertEqual(self.gh_merge_green("x#3").stdout, "v2 x#3\n")

        bad = self.commit_version("v3", tests_pass=False)
        result = self.installer("update")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("tests failed", result.stderr)
        self.assertEqual((self.home / "failed").read_text().strip(), bad)
        self.assertFalse((self.home / "snapshots" / bad).exists())

        result = self.gh_merge_green("x#4")
        self.assertEqual(result.stdout, "v2 x#4\n")
        self.assertIn("failed the gh-merge-green tests", result.stderr)

        # The same failed commit is not retried on every run.
        result = self.installer("update")
        self.assertIn("already failed", result.stderr)

    def test_a_commit_that_does_not_change_gh_merge_green_reuses_the_snapshot(self):
        self.assert_ok(self.install())
        first = (self.home / "current").resolve()
        self.write("README.md", "unrelated\n")
        self.run_ok("git", "add", "-A", cwd=self.clone)
        self.run_ok("git", "commit", "--quiet", "-m", "docs", cwd=self.clone)
        self.run_ok("git", "push", "--quiet", "origin", "HEAD:main", cwd=self.clone)
        result = self.assert_ok(self.installer("update"))
        self.assertIn("already current", result.stderr)
        self.assertEqual((self.home / "current").resolve(), first)

    def test_refuses_a_ref_that_is_not_on_origin_main(self):
        self.run_ok("git", "switch", "--quiet", "-c", "side", cwd=self.clone)
        self.write("scripts/gh-merge-green", "#!/usr/bin/env bash\necho side\n", 0o755)
        self.run_ok("git", "commit", "--quiet", "-am", "side", cwd=self.clone)
        result = self.install("--ref", "side")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not on origin/main", result.stderr)
        self.assertFalse((self.bin / "gh-merge-green").exists())

    def test_refuses_a_lookalike_origin_host(self):
        del self.env["GH_MERGE_GREEN_INSTALL_ANY_ORIGIN"]
        self.run_ok("git", "remote", "set-url", "origin", "https://evilgithub.com/manaflow-ai/cmux.git", cwd=self.clone)
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("origin is not github.com/manaflow-ai/cmux", result.stderr)
        self.assertFalse((self.bin / "gh-merge-green").exists())

    def test_refuses_a_main_commit_without_the_launcher(self):
        self.run_ok("git", "rm", "--quiet", LAUNCHER, cwd=self.clone)
        self.run_ok("git", "commit", "--quiet", "-m", "no launcher", cwd=self.clone)
        self.run_ok("git", "push", "--quiet", "origin", "HEAD:main", cwd=self.clone)
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("has no scripts/gh-merge-green-pinned", result.stderr)
        self.assertFalse((self.bin / "gh-merge-green").exists())

    def test_a_failed_forced_reinstall_keeps_the_working_command(self):
        self.assert_ok(self.install())
        live = (self.home / "current").resolve()
        self.env["GH_MERGE_GREEN_INSTALL_TESTS"] = "tests.test_missing_module_fails"
        (self.clone / "tests" / "test_missing_module_fails.py").write_text("raise SystemExit(1)\n")
        self.run_ok("git", "add", "-A", cwd=self.clone)
        self.run_ok("git", "commit", "--quiet", "-m", "red test", cwd=self.clone)
        self.run_ok("git", "push", "--quiet", "origin", "HEAD:main", cwd=self.clone)
        result = self.install("--force")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.home / "current").resolve(), live)
        self.assertEqual(self.gh_merge_green("x#5").stdout, "v1 x#5\n")

    def test_launcher_stops_when_the_snapshot_cannot_be_verified(self):
        self.assert_ok(self.install())
        snapshot = (self.home / "current").resolve()
        (snapshot / ".git").rename(snapshot / ".git-moved")
        result = self.gh_merge_green("x#6")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("cannot verify the pinned install", result.stderr)
        self.assertEqual(result.stdout, "")

    def submitter_only_mac(self, verdict):
        """This HOME is one of Leo's Macs (no local test suites); CI reads come from a fake glaeda-gh."""
        role = self.root / ".local" / "lib" / "cmux-local-build-guards" / "build-role"
        role.parent.mkdir(parents=True, exist_ok=True)
        role.write_text("submitter-only\n")
        fake = self.root / "fakebin" / "glaeda-gh"
        fake.parent.mkdir(exist_ok=True)
        fake.write_text(FAKE_GLAEDA)
        fake.chmod(0o755)
        self.env["GH_MERGE_GREEN_GLAEDA"] = str(fake)
        self.set_ci(verdict)

    def set_ci(self, verdict):
        (self.root / "fakebin" / "verdict").write_text(verdict)

    def ci_reads(self):
        log = self.root / "fakebin" / "calls"
        return log.read_text().splitlines() if log.exists() else []

    def test_a_submitter_only_mac_installs_a_ci_green_commit_without_running_its_tests(self):
        self.assert_ok(self.install())
        self.submitter_only_mac("success")
        # Its local tests would fail, so a v2 install proves they did not run here.
        green = self.commit_version("v2", tests_pass=False)
        result = self.assert_ok(self.installer("update"))
        self.assertIn("CI fast guards", result.stderr)
        self.assertNotIn("running", result.stderr)
        self.assertEqual(self.gh_merge_green("x#7").stdout, "v2 x#7\n")
        self.assertEqual((self.home / "checked").read_text().strip(), green)
        self.assertTrue(any(green in call for call in self.ci_reads()), self.ci_reads())

    def test_a_submitter_only_mac_waits_for_ci_that_has_not_finished(self):
        self.assert_ok(self.install())
        self.submitter_only_mac("pending")
        pending = self.commit_version("v2", tests_pass=False)
        result = self.assert_ok(self.installer("update"))
        self.assertIn("not passed", result.stderr)
        self.assertEqual(self.gh_merge_green("x#8").stdout, "v1 x#8\n")
        self.assertFalse((self.home / "failed").exists())
        self.assertNotEqual((self.home / "checked").read_text().strip(), pending)

        self.set_ci("success")  # the next update installs it
        self.assert_ok(self.installer("update"))
        self.assertEqual(self.gh_merge_green("x#9").stdout, "v2 x#9\n")

    def test_a_submitter_only_mac_keeps_its_install_when_ci_failed(self):
        self.assert_ok(self.install())
        self.submitter_only_mac("failure")
        red = self.commit_version("v2", tests_pass=True)
        result = self.installer("update")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("CI fast guards", result.stderr)
        self.assertEqual((self.home / "failed").read_text().strip(), red)
        self.assertEqual(self.gh_merge_green("x#10").stdout, "v1 x#10\n")

    def test_a_submitter_only_mac_waits_when_glaeda_gh_is_missing(self):
        self.assert_ok(self.install())
        self.submitter_only_mac("success")
        self.env["GH_MERGE_GREEN_GLAEDA"] = str(self.root / "fakebin" / "no-such-glaeda-gh")
        self.commit_version("v2", tests_pass=False)
        result = self.assert_ok(self.installer("update"))
        self.assertIn("not passed", result.stderr)
        self.assertEqual(self.gh_merge_green("x#11").stdout, "v1 x#11\n")

    def test_replaces_the_old_checkout_symlink(self):
        self.bin.mkdir()
        (self.bin / "gh-merge-green").symlink_to(self.clone / "scripts" / "gh-merge-green")
        self.assert_ok(self.install())
        target = os.readlink(self.bin / "gh-merge-green")
        self.assertEqual(target, str(self.home / "current" / LAUNCHER))


if __name__ == "__main__":
    unittest.main()
