#!/usr/bin/env python3
"""scripts/install-git-hooks.sh must not fail setup over hooks a contributor already has.

setup.sh runs the installer last under `set -e`, so a non-zero exit reports the
whole setup as failed. Existing hooks (a global core.hooksPath, or Git LFS's
hooks in .git/hooks) are left alone with a warning; real errors still fail.
"""
import os
from pathlib import Path
import shutil
import shlex
import subprocess
import tempfile
import unittest
import git_fixture_env  # disables git auto maintenance


SOURCE = Path(__file__).resolve().parents[1]
INSTALLER = "scripts/install-git-hooks.sh"
LFS_PRE_PUSH = """#!/bin/sh
command -v git-lfs >/dev/null 2>&1 || { echo >&2 "This repository is configured for Git LFS"; exit 2; }
git lfs pre-push "$@"
"""


class InstallGitHooksTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="cmux-install-hooks-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.repo = self.root / "repository"
        self.global_config = self.root / "gitconfig"
        self.global_config.write_text("")
        self.env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        self.env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=str(self.global_config),
                        HOME=str(self.root))
        git_fixture_env.without_auto_maintenance(self.env)
        self.repo.mkdir()
        self.git("init", "--quiet", "--initial-branch=main")
        self.copy_installer(self.repo)

    def copy_installer(self, root):
        for relative in (
            "scripts/git-hooks",
            INSTALLER,
            "scripts/merge-xcstrings.py",
            "scripts/merge-pbxproj.py",
            "scripts/ci/catch_up_pr.py",
            "scripts/normalize-pbxproj.py",
        ):
            source, target = SOURCE / relative, root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            if source.is_dir():
                shutil.copytree(source, target)
            else:
                shutil.copyfile(source, target)

    def git(self, *args, check=True):
        return subprocess.run(["git", "-C", str(self.repo), *args], env=self.env,
                              text=True, capture_output=True, check=check)

    def install(self, root=None):
        return subprocess.run(["bash", INSTALLER], cwd=root or self.repo, env=self.env,
                              text=True, capture_output=True)

    def local_hooks_path(self):
        return self.git("config", "--local", "--get", "core.hooksPath", check=False).stdout.strip()

    def assert_merge_driver_installed(self):
        common = Path(self.git("rev-parse", "--git-common-dir").stdout.strip())
        if not common.is_absolute():
            common = self.repo / common
        installed = common / "cmux-merge-drivers"
        for name in ("merge-xcstrings.py", "merge-pbxproj.py", "normalize-pbxproj.py"):
            self.assertTrue((installed / name).is_file(), name)
        self.assertTrue((installed / "ci" / "catch_up_pr.py").is_file())

        for key, name in (
            ("merge.xcstrings-v2.driver", "merge-xcstrings.py"),
            ("merge.xcstrings.driver", "merge-xcstrings.py"),
            ("merge.pbxproj-v1.driver", "merge-pbxproj.py"),
            ("merge.pbxproj.driver", "merge-pbxproj.py"),
        ):
            command = self.git("config", "--get", key).stdout.strip()
            words = shlex.split(command)
            self.assertTrue(Path(words[0]).is_absolute())
            self.assertFalse(Path(words[0]).resolve().is_relative_to(self.repo.resolve()))
            self.assertEqual(words[1], "-I")
            self.assertEqual(Path(words[2]).resolve(), (installed / name).resolve())
            self.assertEqual(words[3:], ["%O", "%A", "%B", "%P"])
            self.assertNotIn(f"scripts/{name}", command)

    def test_clean_clone_uses_tracked_hooks(self):
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.local_hooks_path(), "scripts/git-hooks")
        self.assert_merge_driver_installed()

    def test_merge_driver_does_not_follow_checked_out_script_changes(self):
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        command = self.git("config", "--get", "merge.pbxproj-v1.driver").stdout.strip()
        installed_driver = Path(shlex.split(command)[2])
        reviewed = installed_driver.read_bytes()

        (self.repo / "scripts" / "merge-pbxproj.py").write_text(
            "raise SystemExit('untrusted checkout executed')\n",
            encoding="utf-8",
        )

        self.assertEqual(installed_driver.read_bytes(), reviewed)
        self.assertNotEqual(installed_driver.resolve(), (self.repo / "scripts" / "merge-pbxproj.py").resolve())

    def test_repo_relative_python_is_rejected_without_execution(self):
        tools = self.repo / "tools"
        tools.mkdir()
        marker = self.root / "untrusted-python-ran"
        fake_python = tools / "python3"
        fake_python.write_text(
            f"#!/bin/sh\ntouch {shlex.quote(str(marker))}\n",
            encoding="utf-8",
        )
        fake_python.chmod(0o755)
        self.env["PATH"] = f"tools:{self.env['PATH']}"

        result = self.install()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("python3 must resolve to an absolute executable", result.stderr)
        self.assertFalse(marker.exists())

    def test_in_checkout_python_is_rejected_through_a_symlinked_checkout(self):
        tools = self.repo / "tools"
        tools.mkdir()
        marker = self.root / "untrusted-symlink-python-ran"
        fake_python = tools / "python3"
        fake_python.write_text(
            f"#!/bin/sh\ntouch {shlex.quote(str(marker))}\n",
            encoding="utf-8",
        )
        fake_python.chmod(0o755)
        linked_repo = self.root / "repository-link"
        linked_repo.symlink_to(self.repo, target_is_directory=True)
        self.env["PATH"] = f"{linked_repo / 'tools'}:{self.env['PATH']}"

        result = subprocess.run(
            ["bash", str(linked_repo / INSTALLER)],
            cwd=linked_repo,
            env=self.env,
            text=True,
            capture_output=True,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("python3 resolves inside the checkout", result.stderr)
        self.assertFalse(marker.exists())

    def test_trusted_main_post_merge_migrates_legacy_driver_commands(self):
        hook = self.repo / "scripts/git-hooks/post-merge"
        hook.unlink()
        self.git("add", ".")
        self.git(
            "-c", "user.name=Merge Test",
            "-c", "user.email=merge@example.invalid",
            "commit", "-qm", "old main",
        )
        self.git("remote", "add", "upstream", "git@github.com:manaflow-ai/cmux.git")
        self.git("switch", "-q", "-c", "trusted-main")
        shutil.copy2(SOURCE / "scripts/git-hooks/post-merge", hook)
        self.git("add", str(hook.relative_to(self.repo)))
        self.git(
            "-c", "user.name=Merge Test",
            "-c", "user.email=merge@example.invalid",
            "commit", "-qm", "add trusted migration hook",
        )
        trusted_main = self.git("rev-parse", "HEAD").stdout.strip()
        self.git("update-ref", "refs/remotes/upstream/main", trusted_main)
        self.git("switch", "-q", "main")
        self.git("config", "core.hooksPath", "scripts/git-hooks")
        self.git("config", "merge.xcstrings.driver", "python3 scripts/merge-xcstrings.py %O %A %B %P")
        self.git("config", "merge.pbxproj.driver", "python3 scripts/merge-pbxproj.py %O %A %B %P")

        result = self.git("merge", "--ff-only", "upstream/main", check=False)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.git("rev-parse", "HEAD").stdout.strip(), trusted_main)
        self.assertTrue(os.access(hook, os.X_OK), "Git ignores non-executable hooks")
        self.assert_merge_driver_installed()

    def test_post_merge_rejects_lookalike_github_url(self):
        marker = self.root / "untrusted-installer-ran"
        installer = self.repo / INSTALLER
        installer.write_text(f"#!/bin/sh\ntouch {shlex.quote(str(marker))}\n", encoding="utf-8")
        installer.chmod(0o755)
        self.git("add", ".")
        self.git(
            "-c", "user.name=Merge Test",
            "-c", "user.email=merge@example.invalid",
            "commit", "-qm", "lookalike remote checkout",
        )
        self.git("remote", "add", "upstream", "https://attacker.invalid/github.com/manaflow-ai/cmux")
        self.git("update-ref", "refs/remotes/upstream/main", "HEAD")

        result = subprocess.run(
            ["bash", "scripts/git-hooks/post-merge"],
            cwd=self.repo,
            env=self.env,
            text=True,
            capture_output=True,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(marker.exists())

    def test_global_hooks_path_warns_and_succeeds(self):
        global_hooks = self.root / "global-hooks"
        global_hooks.mkdir()
        self.git("config", "--global", "core.hooksPath", str(global_hooks))

        result = self.install()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.local_hooks_path(), "", "must not override the contributor's hooks")
        self.assertIn(str(global_hooks), result.stderr)
        self.assertIn("scripts/git-hooks/pre-commit", result.stderr, "must say how to wire the hook")
        self.assertIn("scripts/git-hooks/post-merge", result.stderr, "must say how to refresh merge drivers")
        self.assert_merge_driver_installed()

    def default_hooks_dir(self):
        hooks = Path(self.git("rev-parse", "--git-path", "hooks").stdout.strip())
        return hooks if hooks.is_absolute() else self.repo / hooks

    def test_executable_backup_is_not_an_existing_hook(self):
        backup = self.default_hooks_dir() / "pre-commit.bak"
        backup.write_text("#!/bin/sh\nexit 1\n")
        backup.chmod(0o755)

        result = self.install()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.local_hooks_path(), "scripts/git-hooks")

    def test_existing_lfs_hook_warns_and_succeeds(self):
        hook = self.default_hooks_dir() / "pre-push"
        hook.write_text(LFS_PRE_PUSH)
        hook.chmod(0o755)

        result = self.install()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.local_hooks_path(), "", "must not hide the existing hook")
        self.assertEqual(hook.read_text(), LFS_PRE_PUSH)
        self.assertIn("pre-push", result.stderr)
        self.assertIn("scripts/git-hooks/pre-commit", result.stderr, "must say how to chain the hook")
        self.assertIn("scripts/git-hooks/post-merge", result.stderr, "must say how to refresh merge drivers")
        self.assert_merge_driver_installed()

    def test_outside_a_git_repository_still_fails(self):
        plain = self.root / "not-a-repository"
        plain.mkdir()
        self.copy_installer(plain)
        self.env["GIT_CEILING_DIRECTORIES"] = str(self.root)

        result = self.install(plain)

        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
