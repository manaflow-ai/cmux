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
            "scripts/ci/merge_main_resolver.py",
            "scripts/ci/validate_test_execution_registry.py",
            "scripts/ci/test_execution_registry.py",
            "scripts/ci/workload_entrypoints.py",
            "scripts/normalize-pbxproj.py",
            "scripts/lint_swift_namespaces.py",
            "scripts/swift_source_mask.py",
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

    def install(self, root=None, *args):
        return subprocess.run(["bash", INSTALLER, *args], cwd=root or self.repo, env=self.env,
                              text=True, capture_output=True)

    def local_hooks_path(self):
        return self.git("config", "--local", "--get", "core.hooksPath", check=False).stdout.strip()

    def common_dir(self):
        common = Path(self.git("rev-parse", "--git-common-dir").stdout.strip())
        return common if common.is_absolute() else self.repo / common

    def assert_trusted_hooks_installed(self):
        installed = self.common_dir() / "cmux-git-hooks"
        self.assertEqual(Path(self.local_hooks_path()).resolve(), installed.resolve())
        self.assertNotEqual(installed.resolve(), (self.repo / "scripts/git-hooks").resolve())
        for name in ("pre-commit", "post-merge"):
            self.assertTrue((installed / name).is_file(), name)
            self.assertTrue(os.access(installed / name, os.X_OK), name)
        for name in (
            "validate_test_execution_registry.py",
            "test_execution_registry.py",
            "workload_entrypoints.py",
            "normalize-pbxproj.py",
            "python3-path",
        ):
            self.assertTrue((installed / name).is_file(), name)
        python3 = Path((installed / "python3-path").read_text(encoding="utf-8").strip())
        self.assertTrue(python3.is_absolute())
        self.assertFalse(python3.resolve().is_relative_to(self.repo.resolve()))
        helper = subprocess.run(
            [str(python3), "-I", str(installed / "validate_test_execution_registry.py"), "--help"],
            cwd=self.repo,
            env=self.env,
            text=True,
            capture_output=True,
        )
        self.assertEqual(helper.returncode, 0, helper.stderr)

    def assert_merge_driver_installed(self):
        installed = self.common_dir() / "cmux-merge-drivers"
        for name in ("merge-xcstrings.py", "merge-pbxproj.py", "normalize-pbxproj.py"):
            self.assertTrue((installed / name).is_file(), name)
        self.assertTrue((installed / "ci" / "merge_main_resolver.py").is_file())

        for key, name, expected_args in (
            ("merge.xcstrings-v2.driver", "merge-xcstrings.py", ["%O", "%A", "%B", "%P", "%L"]),
            ("merge.xcstrings.driver", "merge-xcstrings.py", ["%O", "%A", "%B", "%P", "%L"]),
            ("merge.pbxproj-v1.driver", "merge-pbxproj.py", ["%O", "%A", "%B", "%P"]),
            ("merge.pbxproj.driver", "merge-pbxproj.py", ["%O", "%A", "%B", "%P"]),
        ):
            command = self.git("config", "--get", key).stdout.strip()
            words = shlex.split(command)
            self.assertTrue(Path(words[0]).is_absolute())
            self.assertFalse(Path(words[0]).resolve().is_relative_to(self.repo.resolve()))
            self.assertEqual(words[1], "-I")
            self.assertEqual(Path(words[2]).resolve(), (installed / name).resolve())
            self.assertEqual(words[3:], expected_args)
            self.assertNotIn(f"scripts/{name}", command)

    def test_clean_clone_uses_trusted_hook_copies(self):
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_trusted_hooks_installed()
        self.assert_merge_driver_installed()

    def test_namespace_fix_option_installs_trusted_pre_push_hook(self):
        result = self.install(None, "--namespace-fix")
        self.assertEqual(result.returncode, 0, result.stderr)
        installed = Path(self.local_hooks_path())
        self.assertTrue((installed / "pre-push").is_file())
        self.assertTrue(os.access(installed / "pre-push", os.X_OK))
        self.assertTrue((installed / "lint_swift_namespaces.py").is_file())
        self.assertTrue((installed / "swift_source_mask.py").is_file())
        hook = (installed / "pre-push").read_text(encoding="utf-8")
        self.assertNotIn("scripts/lint_swift_namespaces.py", hook)

    def test_default_install_does_not_enable_namespace_fix_hook(self):
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((Path(self.local_hooks_path()) / "pre-push").exists())

    def test_installed_hooks_do_not_follow_checked_out_hook_changes(self):
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        installed_hook = Path(self.local_hooks_path()) / "post-merge"
        reviewed = installed_hook.read_bytes()

        (self.repo / "scripts/git-hooks/post-merge").write_text(
            "#!/bin/sh\nexit 99\n",
            encoding="utf-8",
        )

        self.assertEqual(installed_hook.read_bytes(), reviewed)
        self.assertNotEqual(
            installed_hook.resolve(),
            (self.repo / "scripts/git-hooks/post-merge").resolve(),
        )

    def test_pre_commit_helpers_do_not_follow_checked_out_changes(self):
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        installed = Path(self.local_hooks_path())
        for relative, installed_name in (
            ("scripts/ci/validate_test_execution_registry.py", "validate_test_execution_registry.py"),
            ("scripts/normalize-pbxproj.py", "normalize-pbxproj.py"),
        ):
            reviewed = (installed / installed_name).read_bytes()
            (self.repo / relative).write_text(
                "raise SystemExit('untrusted checkout executed')\n",
                encoding="utf-8",
            )
            self.assertEqual((installed / installed_name).read_bytes(), reviewed)

        hook = (installed / "pre-commit").read_text(encoding="utf-8")
        self.assertNotIn("scripts/ci/validate_test_execution_registry.py", hook)
        self.assertNotIn("scripts/normalize-pbxproj.py", hook)

    def test_pre_commit_executes_no_checked_out_python_helpers(self):
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        marker = self.root / "untrusted-hook-helper-ran"
        payload = (
            "from pathlib import Path\n"
            f"Path({str(marker)!r}).touch()\n"
        )
        (self.repo / "scripts/ci/validate_test_execution_registry.py").write_text(
            payload, encoding="utf-8"
        )
        (self.repo / "scripts/normalize-pbxproj.py").write_text(payload, encoding="utf-8")

        workflow = self.repo / ".github/workflows/probe.yml"
        workflow.parent.mkdir(parents=True)
        workflow.write_text("name: probe\n", encoding="utf-8")
        pbxproj = self.repo / "cmux.xcodeproj/project.pbxproj"
        pbxproj.parent.mkdir(parents=True)
        pbxproj.write_text("not a project\n", encoding="utf-8")
        self.git("add", str(workflow.relative_to(self.repo)), str(pbxproj.relative_to(self.repo)))

        hook = Path(self.local_hooks_path()) / "pre-commit"
        hook_result = subprocess.run(
            [str(hook)], cwd=self.repo, env=self.env, text=True, capture_output=True
        )

        self.assertNotEqual(hook_result.returncode, 0, "trusted normalizer must reject the fixture")
        self.assertFalse(marker.exists(), "a helper from the checked-out branch executed")

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

    def commit_all(self, message):
        self.git("add", "-A")
        self.git("commit", "--quiet", "-m", message)

    def test_generated_web_bundles_keep_ours_and_sources_still_conflict(self):
        shutil.copyfile(SOURCE / ".gitattributes", self.repo / ".gitattributes")
        self.git("config", "user.name", "t")
        self.git("config", "user.email", "t@example.com")
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.git("config", "--get", "merge.cmux-generated-v1.driver").stdout.strip(), "true")

        pane = self.repo / "Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/Resources/agent-pane/index.html"
        chunk = self.repo / "Resources/markdown-viewer/webviews-app/chunks/vendor.mjs"
        source = self.repo / "webviews/src/App.tsx"
        for path in (pane, chunk, source):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("base\n", encoding="utf-8")
        self.commit_all("base")
        self.git("checkout", "--quiet", "-b", "lane")
        pane.write_text("lane build\n", encoding="utf-8")
        chunk.write_text("lane chunk\n", encoding="utf-8")
        self.commit_all("lane")
        self.git("checkout", "--quiet", "main")
        pane.write_text("main build\n", encoding="utf-8")
        chunk.write_text("main chunk\n", encoding="utf-8")
        self.commit_all("main")
        self.git("checkout", "--quiet", "lane")

        # Both sides rebuilt the bundles: the merge finishes and keeps the lane's
        # copies for scripts/cmux-next/regenerate-web-bundles.sh to replace.
        merged = self.git("merge", "--no-edit", "main", check=False)
        self.assertEqual(merged.returncode, 0, merged.stdout + merged.stderr)
        self.assertEqual(pane.read_text(encoding="utf-8"), "lane build\n")
        self.assertEqual(chunk.read_text(encoding="utf-8"), "lane chunk\n")

        # The driver is scoped to the bundles: authored sources still conflict.
        source.write_text("lane source\n", encoding="utf-8")
        self.commit_all("lane source")
        self.git("checkout", "--quiet", "main")
        source.write_text("main source\n", encoding="utf-8")
        self.commit_all("main source")
        self.git("checkout", "--quiet", "lane")
        conflicted = self.git("merge", "--no-edit", "main", check=False)
        self.assertNotEqual(conflicted.returncode, 0)
        unmerged = self.git("diff", "--name-only", "--diff-filter=U").stdout.split()
        self.assertEqual(unmerged, ["webviews/src/App.tsx"])

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
        self.assert_trusted_hooks_installed()
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

    def test_post_merge_rejects_dirty_installer_at_trusted_main(self):
        self.git("add", ".")
        self.git(
            "-c", "user.name=Merge Test",
            "-c", "user.email=merge@example.invalid",
            "commit", "-qm", "trusted main",
        )
        self.git("remote", "add", "upstream", "https://github.com/manaflow-ai/cmux.git")
        self.git("update-ref", "refs/remotes/upstream/main", "HEAD")
        marker = self.root / "dirty-installer-ran"
        installer = self.repo / INSTALLER
        installer.write_text(f"#!/bin/sh\ntouch {shlex.quote(str(marker))}\n", encoding="utf-8")
        installer.chmod(0o755)

        result = subprocess.run(
            ["bash", "scripts/git-hooks/post-merge"],
            cwd=self.repo,
            env=self.env,
            text=True,
            capture_output=True,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("differ from trusted main", result.stderr)
        self.assertFalse(marker.exists())

    def test_post_merge_rejects_dirty_trusted_pre_commit_helpers(self):
        self.git("add", ".")
        self.git(
            "-c", "user.name=Merge Test",
            "-c", "user.email=merge@example.invalid",
            "commit", "-qm", "trusted main",
        )
        self.git("remote", "add", "upstream", "https://github.com/manaflow-ai/cmux.git")
        self.git("update-ref", "refs/remotes/upstream/main", "HEAD")

        for relative in (
            "scripts/ci/validate_test_execution_registry.py",
            "scripts/ci/test_execution_registry.py",
            "scripts/ci/workload_entrypoints.py",
        ):
            path = self.repo / relative
            reviewed = path.read_bytes()
            try:
                path.write_bytes(reviewed + b"\n# dirty candidate\n")
                result = subprocess.run(
                    ["/bin/bash", "scripts/git-hooks/post-merge"],
                    cwd=self.repo,
                    env=self.env,
                    text=True,
                    capture_output=True,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("differ from trusted main", result.stderr, relative)
            finally:
                path.write_bytes(reviewed)

    def test_global_hooks_path_warns_and_succeeds(self):
        global_hooks = self.root / "global-hooks"
        global_hooks.mkdir()
        self.git("config", "--global", "core.hooksPath", str(global_hooks))

        result = self.install()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.local_hooks_path(), "", "must not override the contributor's hooks")
        self.assertIn(str(global_hooks), result.stderr)
        self.assertIn("cmux-git-hooks/pre-commit", result.stderr, "must say how to wire the hook")
        self.assertIn("cmux-git-hooks/post-merge", result.stderr, "must say how to refresh merge drivers")
        self.assertNotIn("core.hooksPath scripts/git-hooks", result.stderr)
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
        self.assert_trusted_hooks_installed()

    def test_existing_lfs_hook_warns_and_succeeds(self):
        hook = self.default_hooks_dir() / "pre-push"
        hook.write_text(LFS_PRE_PUSH)
        hook.chmod(0o755)

        result = self.install()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.local_hooks_path(), "", "must not hide the existing hook")
        self.assertEqual(hook.read_text(), LFS_PRE_PUSH)
        self.assertIn("pre-push", result.stderr)
        self.assertIn("cmux-git-hooks/pre-commit", result.stderr, "must say how to chain the hook")
        self.assertIn("cmux-git-hooks/post-merge", result.stderr, "must say how to refresh merge drivers")
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
