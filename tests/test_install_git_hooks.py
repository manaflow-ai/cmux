#!/usr/bin/env python3
"""scripts/install-git-hooks.sh must not fail setup over hooks a contributor already has.

setup.sh runs the installer last under `set -e`, so a non-zero exit reports the
whole setup as failed. Existing hooks (a global core.hooksPath, or Git LFS's
hooks in .git/hooks) are left alone with a warning; real errors still fail.
"""
import errno
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import shutil
import shlex
import subprocess
import sys
import tempfile
import threading
import time
import unicodedata
import unittest
from unittest import mock


def _load_git_fixture_env():
    """tests/git_fixture_env.py by path, so `python3 -I` (no script folder on sys.path) runs this file too."""
    spec = importlib.util.spec_from_file_location("git_fixture_env", Path(__file__).resolve().parent / "git_fixture_env.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)  # importing it disables git auto maintenance
    return module


git_fixture_env = _load_git_fixture_env()


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
        # Fixture commits stand for a person: an agent or CI environment makes a
        # missing formatter fatal, and these fixtures have none.
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith("GIT_") and key not in self.AGENT_VARS}
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
            "scripts/merge-baseline.py",
            "scripts/merge-daemon-capabilities.py",
            "scripts/merge-insertions.py",
            "scripts/merge-cargo-lock.py",
            "scripts/ci/merge_main_resolver.py",
            "scripts/ci/validate_test_execution_registry.py",
            "scripts/ci/test_execution_registry.py",
            "scripts/ci/workload_entrypoints.py",
            "scripts/normalize-pbxproj.py",
            "scripts/lint_swift_namespaces.py",
            "scripts/swift_source_mask.py",
            "scripts/web_lint_prepush.py",
            "scripts/cmux-next/prepush-gate.py",
            "scripts/cmux-next/git_batch.py",
            "scripts/ci/base_merge_warning.py",
            "scripts/ci/github_release_download.py",
            "scripts/ci/deadline_http.py",
            "scripts/ci/generated_files_guard.py",
            "scripts/ci/ci_process_tree.py",
            "scripts/webviews_bun_version.py",
            "scripts/check-webviews-bun-version.sh",
            *self.installed_sources(),
            *self.copy_input_files(),
        ):
            source, target = SOURCE / relative, root / relative
            if not source.exists():
                continue  # a tree from before the file; the installer then fails on it if it needs it
            target.parent.mkdir(parents=True, exist_ok=True)
            if source.is_dir():
                shutil.copytree(source, target)
            else:
                shutil.copyfile(source, target)

    @staticmethod
    def installed_sources():
        """Every scripts/ file the installer copies with `install`, so a new copy line never leaves the fixture behind.

        #48396 added scripts/ci/workflow_job_bounds.py to the installer and every fixture install failed with
        "cannot stat" until this list named it; reading the installer keeps the two in step.
        """
        text = (SOURCE / INSTALLER).read_text(encoding="utf-8")
        installed = set(re.findall(r"^\s*install\s+-m\s+\d+\s+(scripts/\S+)", text, re.MULTILINE))
        # The checks copy's file inputs too: a37b619481 added scripts/ci/generated_files_guard.py and ci_process_tree.py to
        # checks-copy-inputs and every fixture install lacked them, so the stamp test read a file the fixture never had.
        manifest = SOURCE / "scripts/git-hooks/checks-copy-inputs"
        if manifest.exists():
            for line in manifest.read_text(encoding="utf-8").splitlines():
                source = line.strip().split(" -> ")[0].strip()
                if source and not source.startswith("#") and not source.endswith("/"):
                    installed.add(source)
        return sorted(installed)

    @staticmethod
    def copy_input_files():
        """Every single-file entry of scripts/git-hooks/checks-copy-inputs, so a new entry never leaves the fixture behind.

        The base added scripts/ci/generated_files_guard.py and scripts/ci/ci_process_tree.py to that list (prepush gate:
        refuse a push that commits a generated file) and the stamp test failed reading them from the fixture until it
        named them; reading the list keeps the two in step, like installed_sources() does for the installer.
        """
        lines = (SOURCE / "scripts/git-hooks/checks-copy-inputs").read_text(encoding="utf-8").splitlines()
        sources = (line.strip().split(" -> ")[0].strip() for line in lines
                   if line.strip() and not line.strip().startswith("#"))
        return sorted({source for source in sources if not source.endswith("/")})

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
            # The interpreter is picked on this host each merge (scripts/git-hooks/merge_python.sh), never one
            # recorded path; the wrapper is the reviewed copy in the clone's hook folder.
            self.assertEqual(words[0], "/bin/bash")
            self.assertEqual(Path(words[1]).resolve(),
                             (self.common_dir() / "cmux-git-hooks" / "merge_python.sh").resolve())
            self.assertEqual(Path(words[2]).resolve(), (installed / name).resolve())
            self.assertEqual(words[3:], expected_args)
            self.assertNotIn(f"scripts/{name}", command)

    def test_clean_clone_uses_trusted_hook_copies(self):
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_trusted_hooks_installed()
        self.assert_merge_driver_installed()

    def test_cmux_next_checks_include_the_arch_rule_modules(self):
        # arch-ratchet.py loads arch_rules/*.py from its own directory: without them the installed ratchet ran no
        # layer gate. Other folders (tests) stay out of the copy.
        for relative in ("scripts/cmux-next/arch-ratchet.py", "scripts/cmux-next/arch_rules/layer_gate.py",
                         "scripts/cmux-next/tests/test_layer_gate.py"):
            path = self.repo / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("# fixture\n", encoding="utf-8")
        self.git("add", "scripts/cmux-next")
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        checks = Path(self.local_hooks_path()) / "cmux-next-checks"
        self.assertTrue((checks / "arch-ratchet.py").is_file())
        self.assertTrue((checks / "arch_rules" / "layer_gate.py").is_file())
        self.assertFalse((checks / "tests").exists())

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
        # pre-push is installed for the web lint; the namespace fixer stays opt-in.
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((Path(self.local_hooks_path()) / "lint_swift_namespaces.py").exists())

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

    # Formatters at the commit boundary: the hook formats staged Rust in every
    # Cargo package (not only cmux-tui), and a formatter that cannot run warns
    # and lets the commit through (CI checks formatting).
    AGENT_VARS = ("CMUX_AGENT", "CMUX_REQUIRE_FORMATTERS", "CI", "CLAUDECODE", "CODEX_CI", "CODEX_THREAD_ID", "CODEX_SANDBOX", "CMUX_SKIP_FORMAT_HOOKS")

    def formatter_env(self, with_rustfmt, **extra):
        """Only the tools the hook needs on PATH, plus a recording rustfmt."""
        bin_dir = self.root / ("bin-rustfmt" if with_rustfmt else "bin-plain")
        bin_dir.mkdir(exist_ok=True)
        for tool in ("git", "bash", "sh", "sed", "awk", "grep", "cut", "sort", "head", "cat", "env", "dirname", "basename", "mktemp", "rm", "mv", "mkdir", "rmdir", "find", "tail", "sleep"):
            found = shutil.which(tool)
            if found and not (bin_dir / tool).exists():
                (bin_dir / tool).symlink_to(found)
        self.rustfmt_log = self.root / "rustfmt.log"
        if with_rustfmt:
            fake = bin_dir / "rustfmt"
            # Formats stdin to stdout as rustfmt does there: runs of spaces become one.
            fake.write_text(f'#!/bin/sh\nprintf "%s\\n" "$*" >> {shlex.quote(str(self.rustfmt_log))}\n'
                            f"exec {shlex.quote(shutil.which('sed'))} 's/  */ /g'\n")
            fake.chmod(0o755)
        env = dict(self.env, PATH=str(bin_dir), **extra)
        return env

    def stage_rust_package(self, root, edition, source="fn main() {}\n", config=None):
        package = self.repo / root
        (package / "src").mkdir(parents=True)
        (package / "Cargo.toml").write_text(f'[package]\nname = "probe"\nedition = "{edition}"\n')
        if config is not None:
            (package / "rustfmt.toml").write_text(config)
        (package / "src/main.rs").write_text(source)
        self.git("add", root)
        return package / "src/main.rs"

    def run_pre_commit(self, env):
        hook = Path(self.local_hooks_path()) / "pre-commit"
        return subprocess.run([str(hook)], cwd=self.repo, env=env, text=True, capture_output=True,
                              stdin=subprocess.DEVNULL)

    def test_pre_commit_registers_only_the_commits_own_tests(self):
        """The base carried an unregistered test; the hook wrote it into whichever pull request
        committed a test next, so unrelated pull requests conflicted on the registry (#21946)."""
        self.assertEqual(self.install().returncode, 0)
        workflow = self.repo / ".github/workflows/ci-guards.yml"
        workflow.parent.mkdir(parents=True, exist_ok=True)
        workflow.write_text(
            "name: CI guards\njobs:\n  workflow-guard-tests:\n    steps:\n"
            "      - run: python3 tests/test_kept.py\n"
            "      - run: python3 tests/test_base.py\n      - run: python3 tests/test_mine.py\n",
            encoding="utf-8",
        )
        registry = self.repo / "tests/test-execution.toml"
        registry.parent.mkdir(parents=True, exist_ok=True)
        registry.write_text('version = 1\n\n[[test]]\npath = "tests/test_kept.py"\nlane = "linux-guard"\n',
                            encoding="utf-8")
        for name in ("test_kept.py", "test_base.py"):
            (self.repo / "tests" / name).write_text("#!/usr/bin/env python3\n", encoding="utf-8")
        self.git("add", "-A")
        self.git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "--quiet", "--no-verify", "-m", "base")

        (self.repo / "tests/test_mine.py").write_text("#!/usr/bin/env python3\n", encoding="utf-8")
        self.git("add", "tests/test_mine.py")
        result = subprocess.run([str(Path(self.local_hooks_path()) / "pre-commit")], cwd=self.repo,
                                env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        text = registry.read_text(encoding="utf-8")
        self.assertIn('path = "tests/test_mine.py"', text)
        self.assertNotIn("tests/test_base.py", text)

    def test_pre_commit_registers_a_new_test_in_its_area_fragment(self):
        """The registry is tests/test-execution.d/<area>.toml: a new test goes into its area's file,
        and the hook stages that file, including a fragment the registration creates."""
        self.assertEqual(self.install().returncode, 0)
        workflow = self.repo / ".github/workflows/ci-guards.yml"
        workflow.parent.mkdir(parents=True, exist_ok=True)
        workflow.write_text(
            "name: CI guards\njobs:\n  workflow-guard-tests:\n    steps:\n"
            "      - run: python3 tests/test_ci_kept.py\n      - run: python3 tests/test_ci_mine.py\n",
            encoding="utf-8",
        )
        fragments = self.repo / "tests/test-execution.d"
        fragments.mkdir(parents=True)
        (fragments / "ci.toml").write_text('# ci\n\n[[test]]\npath = "tests/test_ci_kept.py"\nlane = "linux-guard"\n',
                                           encoding="utf-8")
        (self.repo / "tests/test_ci_kept.py").write_text("#!/usr/bin/env python3\n", encoding="utf-8")
        self.git("add", "-A")
        self.git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "--quiet", "--no-verify", "-m", "base")

        (self.repo / "tests/test_ci_mine.py").write_text("#!/usr/bin/env python3\n", encoding="utf-8")
        self.git("add", "tests/test_ci_mine.py")
        result = self.run_pre_commit(self.env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('path = "tests/test_ci_mine.py"', (fragments / "ci.toml").read_text(encoding="utf-8"))
        self.assertFalse((self.repo / "tests/test-execution.toml").exists())
        self.assertIn("tests/test-execution.d/ci.toml", self.git("diff", "--cached", "--name-only").stdout)

    def test_pre_commit_registers_a_test_its_workflow_change_names(self):
        """A commit that only adds a workflow line for an existing test registers that test, and
        still not the base's other unregistered one (#21946)."""
        self.assertEqual(self.install().returncode, 0)
        workflow = self.repo / ".github/workflows/ci-guards.yml"
        workflow.parent.mkdir(parents=True, exist_ok=True)
        base_workflow = ("name: CI guards\njobs:\n  workflow-guard-tests:\n    steps:\n"
                         "      - run: python3 tests/test_kept.py\n      - run: python3 tests/test_base.py\n")
        workflow.write_text(base_workflow, encoding="utf-8")
        registry = self.repo / "tests/test-execution.toml"
        registry.parent.mkdir(parents=True, exist_ok=True)
        registry.write_text('version = 1\n\n[[test]]\npath = "tests/test_kept.py"\nlane = "linux-guard"\n',
                            encoding="utf-8")
        for name in ("test_kept.py", "test_base.py", "test_mine.py"):
            (self.repo / "tests" / name).write_text("#!/usr/bin/env python3\n", encoding="utf-8")
        self.git("add", "-A")
        self.git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "--quiet", "--no-verify", "-m", "base")

        workflow.write_text(base_workflow + "      - run: python3 tests/test_mine.py\n", encoding="utf-8")
        self.git("add", ".github/workflows/ci-guards.yml")
        result = subprocess.run([str(Path(self.local_hooks_path()) / "pre-commit")], cwd=self.repo,
                                env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        text = registry.read_text(encoding="utf-8")
        self.assertIn('path = "tests/test_mine.py"', text)
        self.assertNotIn("tests/test_base.py", text)

    def test_pre_commit_registers_no_test_in_a_merge_commit(self):
        """Merging the base into a pull request staged every test the base added since the branch
        point, so the hook wrote the base's unregistered test into the pull request's merge commit
        (tests/test_nightly_dedicated_mini.py in #30071 and #30351). A merge adds no test of its own."""
        self.assertEqual(self.install().returncode, 0)
        commit = ("-c", "user.name=t", "-c", "user.email=t@t", "commit", "--quiet")
        workflow = self.repo / ".github/workflows/ci-guards.yml"
        workflow.parent.mkdir(parents=True, exist_ok=True)
        base_workflow = ("name: CI guards\njobs:\n  workflow-guard-tests:\n    steps:\n"
                         "      - run: python3 tests/test_kept.py\n")
        workflow.write_text(base_workflow, encoding="utf-8")
        registry = self.repo / "tests/test-execution.toml"
        registry.parent.mkdir(parents=True, exist_ok=True)
        registry_text = 'version = 1\n\n[[test]]\npath = "tests/test_kept.py"\nlane = "linux-guard"\n'
        registry.write_text(registry_text, encoding="utf-8")
        (self.repo / "tests/test_kept.py").write_text("#!/usr/bin/env python3\n", encoding="utf-8")
        self.git("add", "-A")
        self.git(*commit, "--no-verify", "-m", "base")

        self.git("checkout", "--quiet", "-b", "pr")
        (self.repo / "notes.txt").write_text("pull request work\n", encoding="utf-8")
        self.git("add", "notes.txt")
        self.git(*commit, "--no-verify", "-m", "pull request work")

        # The base adds a test and the workflow line that runs it, and leaves it unregistered.
        self.git("checkout", "--quiet", "main")
        (self.repo / "tests/test_theirs.py").write_text("#!/usr/bin/env python3\n", encoding="utf-8")
        workflow.write_text(base_workflow + "      - run: python3 tests/test_theirs.py\n", encoding="utf-8")
        self.git("add", "-A")
        self.git(*commit, "--no-verify", "-m", "base adds a test")

        self.git("checkout", "--quiet", "pr")
        merged = self.git("-c", "user.name=t", "-c", "user.email=t@t", "merge", "--quiet", "--no-ff",
                          "--no-commit", "main", check=False)
        self.assertEqual(merged.returncode, 0, merged.stdout + merged.stderr)
        result = self.git(*commit, "--no-edit", check=False)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(self.git("rev-list", "--parents", "-n", "1", "HEAD").stdout.split()), 3)
        self.assertEqual(self.git("show", "HEAD:tests/test-execution.toml").stdout, registry_text)
        self.assertEqual(registry.read_text(encoding="utf-8"), registry_text)

    def test_pre_commit_formats_rust_outside_cmux_tui_with_its_edition(self):
        self.assertEqual(self.install().returncode, 0)
        source = self.stage_rust_package("Native/OptChat/probe", "2024")
        result = self.run_pre_commit(self.formatter_env(with_rustfmt=True))
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.rustfmt_log.read_text().splitlines() if self.rustfmt_log.exists() else []
        self.assertEqual(len(calls), 1, calls)
        # No rustfmt.toml in the checkout: rustfmt's defaults, never a config
        # found above the checkout.
        # The staged file goes in on stdin, so no file path is an argument.
        edition_flag, edition, config_flag, config = calls[0].split(" ")
        self.assertEqual((edition_flag, edition, config_flag), ("--edition", "2024", "--config-path"), calls)
        self.assertFalse(Path(config).resolve().is_relative_to(self.repo.resolve()), config)
        self.assertEqual(self.git("show", ":Native/OptChat/probe/src/main.rs").stdout, source.read_text())

    def test_an_edit_saved_while_rustfmt_runs_is_kept(self):
        """Review F1 on #50609: the hook wrote rustfmt's earlier snapshot over the file, so an edit saved in an
        editor while rustfmt ran was lost from both the worktree and the index."""
        self.assertEqual(self.install().returncode, 0)
        source = self.stage_rust_package("workers/probe", "2021", source="fn   main() {}\n")
        env = self.formatter_env(with_rustfmt=True)
        saved = "fn main() { saved_during_rustfmt(); }\n"
        # This rustfmt reads its input, then the person saves the file, then it prints its output.
        (self.root / "bin-rustfmt" / "rustfmt").write_text(
            f"#!/bin/sh\nin=$({shlex.quote(shutil.which('cat'))})\n"
            f"printf '%s' {shlex.quote(saved)} > {shlex.quote(str(source))}\n"
            f"printf '%s\\n' \"$in\" | {shlex.quote(shutil.which('sed'))} 's/  */ /g'\n")
        result = self.run_pre_commit(env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(source.read_text(), saved, "the edit saved during rustfmt survives")
        self.assertIn("changed while rustfmt ran", result.stderr)
        self.assertEqual(self.git("show", ":workers/probe/src/main.rs").stdout, "fn   main() {}\n",
                         "the index keeps what was staged")

    def test_an_unchanged_format_never_rewrites_the_file(self):
        self.assertEqual(self.install().returncode, 0)
        source = self.stage_rust_package("workers/probe", "2021", source="fn main() {}\n")
        before = source.stat().st_mtime_ns
        os.utime(source, ns=(before - 10**9, before - 10**9))
        before = source.stat().st_mtime_ns
        result = self.run_pre_commit(self.formatter_env(with_rustfmt=True))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(source.stat().st_mtime_ns, before, "formatting changed nothing, so nothing is written")

    def test_pre_commit_uses_the_package_rustfmt_config(self):
        self.assertEqual(self.install().returncode, 0)
        self.stage_rust_package("workers/probe", "2021", source="fn   main() {}\n", config="max_width = 100\n")
        result = self.run_pre_commit(self.formatter_env(with_rustfmt=True))
        self.assertEqual(result.returncode, 0, result.stderr)
        config = (self.repo / "workers/probe/rustfmt.toml").resolve()
        self.assertEqual(self.rustfmt_log.read_text().splitlines(),
                         [f"--edition 2021 --config-path {config}"])
        self.assertEqual(self.git("show", ":workers/probe/src/main.rs").stdout, "fn main() {}\n",
                         "the formatted file is restaged")

    def test_missing_rustfmt_warns_and_commits_for_agents_and_people(self):
        self.assertEqual(self.install().returncode, 0)
        self.stage_rust_package("Native/OptChat/probe", "2021")
        # A Codex shell sets CODEX_THREAD_ID, not CMUX_AGENT.
        for extra in ({"CMUX_AGENT": "1"}, {"CODEX_THREAD_ID": "thread"}, {}):
            with self.subTest(env=extra):
                result = self.run_pre_commit(self.formatter_env(with_rustfmt=False, **extra))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("rustfmt is unavailable", result.stderr)
                self.assertIn("committing without formatting (CI checks formatting)", result.stderr)

    # A recording vp: logs "cwd<TAB>args" and replaces each file argument's text.
    FAKE_VP = """#!/bin/sh
printf '%s\\t%s\\n' "$(pwd)" "$*" >> "$FAKE_VP_LOG"
for arg in "$@"; do
    case "$arg" in fmt|-*) ;; *) printf 'formatted\\n' > "$arg" ;; esac
done
"""

    def stage_web_file(self, package, relative="src/app.ts", text="const   x=1\n"):
        directory = self.repo / package
        vp = directory / "node_modules/.bin/vp"
        vp.parent.mkdir(parents=True, exist_ok=True)
        vp.write_text(self.FAKE_VP)
        vp.chmod(0o755)
        path = directory / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        self.git("add", f"{package}/{relative}")
        return path

    def test_pre_commit_formats_staged_files_of_each_vite_plus_package_with_its_vp(self):
        self.assertEqual(self.install().returncode, 0)
        vp_log = self.root / "vp.log"
        for package in ("webviews", "cmux-tui/frontends/web"):
            with self.subTest(package=package):
                vp_log.unlink(missing_ok=True)
                self.git("rm", "-r", "-q", "--cached", "--ignore-unmatch", "webviews", "cmux-tui")
                self.stage_web_file(package)
                result = self.run_pre_commit(self.formatter_env(with_rustfmt=False, FAKE_VP_LOG=str(vp_log)))
                self.assertEqual(result.returncode, 0, result.stderr)
                runs = vp_log.read_text().splitlines() if vp_log.exists() else []
                self.assertEqual(len(runs), 1, result.stderr)
                cwd, args = runs[0].split("\t")
                self.assertEqual(Path(cwd).resolve(), (self.repo / package).resolve())
                self.assertEqual(args.split()[-1], "src/app.ts")
                staged = self.git("show", f":{package}/src/app.ts").stdout
                self.assertEqual(staged, "formatted\n", "the formatted file is restaged")

    def link_web_install(self, target):
        """webviews/node_modules as a link to TARGET (holding the recording vp), the way wt projects it."""
        self.stage_web_file("webviews")
        installed = self.repo / "webviews/node_modules"
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.rmtree(target, ignore_errors=True)
        shutil.move(str(installed), str(target))
        installed.symlink_to(target)

    def test_pre_commit_runs_vp_from_a_node_modules_linked_outside_the_checkout(self):
        """wt checkouts link webviews/node_modules to a shared install outside the checkout; the
        hook refused that link ("passes through ... inside this checkout"), so no webviews commit
        from a wt checkout could pass."""
        self.assertEqual(self.install().returncode, 0)
        vp_log = self.root / "vp.log"
        self.link_web_install(self.root / "projection/webviews/node_modules")
        result = self.run_pre_commit(self.formatter_env(with_rustfmt=False, FAKE_VP_LOG=str(vp_log), CMUX_AGENT="1"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("inside this checkout", result.stderr)
        self.assertEqual(self.git("show", ":webviews/src/app.ts").stdout, "formatted\n", result.stderr)

    def test_pre_commit_never_runs_a_node_modules_linked_back_into_the_checkout(self):
        """The vp is never run; like any formatter that cannot run, the commit goes on with a warning."""
        self.assertEqual(self.install().returncode, 0)
        vp_log = self.root / "vp.log"
        self.link_web_install(self.repo / "elsewhere/node_modules")
        result = self.run_pre_commit(self.formatter_env(with_rustfmt=False, FAKE_VP_LOG=str(vp_log), CMUX_AGENT="1"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("inside this checkout", result.stderr)
        self.assertIn("committing without formatting", result.stderr)
        self.assertFalse(vp_log.exists(), "a vp the checkout points at never runs")

    def test_pre_commit_takes_over_an_install_lock_whose_holder_died(self):
        # A hook killed mid-install leaves its lock; this worktree has no vp yet.
        self.assertEqual(self.install().returncode, 0)
        vp_log = self.root / "vp.log"
        web = self.repo / "webviews"
        self.stage_web_file("webviews")
        (web / "node_modules/.bin/vp").unlink()
        (web / "bun.lock").write_text("{}\n")
        (web / "package.json").write_text('{"devEngines": {"packageManager": {"name": "bun", "version": "1.4.4"}}}\n')
        env = self.formatter_env(with_rustfmt=False, FAKE_VP_LOG=str(vp_log))
        bun = Path(env["PATH"]) / "bun"
        bun.write_text(f"""#!/bin/sh
[ "$1" = --version ] && {{ echo 1.4.4; exit 0; }}
cat > node_modules/.bin/vp <<'VP'
{self.FAKE_VP}VP
{shutil.which("chmod")} +x node_modules/.bin/vp
""")
        bun.chmod(0o755)
        dead = subprocess.Popen(["true"])
        dead.wait()
        lock = Path(self.git("rev-parse", "--absolute-git-dir").stdout.strip()) / "cmux-format-install-webviews.lock"
        lock.mkdir()
        (lock / "pid").write_text(f"{dead.pid}\n")
        try:
            result = self.run_pre_commit(env)
        finally:
            bun.unlink()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("another agent is installing", result.stderr)
        self.assertEqual(self.git("show", ":webviews/src/app.ts").stdout, "formatted\n", result.stderr)
        self.assertFalse(lock.exists(), "the hook releases the lock it took over")

    # A bun that breaks the way bun 1.4 does when BUN_OPTIONS holds `--preload PATH`:
    # bun prepends the options, and every subcommand but `bun run` then reads as a
    # script name. `--version` still answers. `install` records its argv[0] and
    # writes the recording vp.
    def fake_bun(self, path, version, install_body=None):
        path.parent.mkdir(parents=True, exist_ok=True)
        install_body = install_body or f"""printf '%s\\n' "$0" >> {shlex.quote(str(self.root / "bun.log"))}
cat > node_modules/.bin/vp <<'VP'
{self.FAKE_VP}VP
{shutil.which("chmod")} +x node_modules/.bin/vp"""
        path.write_text(f"""#!/bin/sh
[ "$1" = --version ] && {{ echo {version}; exit 0; }}
if [ -n "$BUN_OPTIONS" ]; then echo "error: Script not found \\"$1\\"" >&2; exit 1; fi
[ "$1" = install ] || exit 0
mkdir -p node_modules/.bin
{install_body}
""")
        path.chmod(0o755)
        return path

    def bootstrap_env(self, pin="1.4.4", **extra):
        """An agent commit whose webviews has a bun.lock and no vp."""
        self.stage_web_file("webviews")
        web = self.repo / "webviews"
        (web / "node_modules/.bin/vp").unlink()
        (web / "bun.lock").write_text("{}\n")
        (web / "package.json").write_text(
            '{\n  "devEngines": {\n    "packageManager": {\n      "name": "bun",\n'
            f'      "version": "{pin}",\n      "onFail": "error"\n    }}\n  }}\n}}\n')
        env = self.formatter_env(with_rustfmt=False, FAKE_VP_LOG=str(self.root / "vp.log"), CMUX_AGENT="1",
                                 MISE_DATA_DIR=str(self.root / "mise"), ASDF_DATA_DIR=str(self.root / "asdf"),
                                 BUN_INSTALL=str(self.root / "bun-home"), **extra)
        env.pop("XDG_DATA_HOME", None)
        return env

    def test_pre_commit_installs_vp_when_bun_options_carry_a_preload(self):
        """BUN_OPTIONS=--preload PATH (a shell profile's preload) made `bun install` fail with
        'Script not found "install"', so every agent commit to webviews stopped at "vp is unavailable"."""
        self.assertEqual(self.install().returncode, 0)
        env = self.bootstrap_env(BUN_OPTIONS="--preload /nowhere/preload.js")
        bun = self.fake_bun(Path(env["PATH"]) / "bun", "1.4.4")
        try:
            result = self.run_pre_commit(env)
        finally:
            bun.unlink()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.git("show", ":webviews/src/app.ts").stdout, "formatted\n", result.stderr)
        self.assertEqual((self.root / "bun.log").read_text().splitlines(), [str(bun)],
                         "the install runs the bun it resolved, by absolute path")

    def test_pre_commit_installs_with_the_bun_webviews_pins(self):
        self.assertEqual(self.install().returncode, 0)
        env = self.bootstrap_env()
        path_bun = self.fake_bun(Path(env["PATH"]) / "bun", "1.3.0")
        pinned = self.fake_bun(self.root / "mise/installs/bun/1.4.4/bin/bun", "1.4.4")
        try:
            result = self.run_pre_commit(env)
        finally:
            path_bun.unlink()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / "bun.log").read_text().splitlines(), [str(pinned)], result.stderr)

    def test_a_failed_bootstrap_prints_its_command_tool_version_and_output(self):
        self.assertEqual(self.install().returncode, 0)
        env = self.bootstrap_env(BUN_OPTIONS="--preload /nowhere/preload.js", NODE_OPTIONS="--max-old-space-size=512")
        bun = self.fake_bun(Path(env["PATH"]) / "bun", "1.4.4", install_body=(
            "echo 'bun install v1.4.4'\n"
            "echo 'error: lockfile had changes, but lockfile is frozen' >&2\n"
            "exit 1"))
        try:
            result = self.run_pre_commit(env)
        finally:
            bun.unlink()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("vp is unavailable for webviews", result.stderr)
        for line in (
            f"command: env -u BUN_OPTIONS {bun} install --frozen-lockfile --ignore-scripts",
            f"argv[0]: {bun}",
            f"{bun} --version: 1.4.4",
            "BUN_OPTIONS: set",
            "NODE_OPTIONS: set",
            "bun install v1.4.4",
            "error: lockfile had changes, but lockfile is frozen",
        ):
            self.assertIn(line, result.stderr)
        self.assertNotIn("/nowhere/preload.js", result.stderr, "only whether BUN_OPTIONS is set, not its value")

    # A bun the checkout carries: any run of it, --version included, leaves the canary.
    def checkout_payload(self, directory):
        canary = self.root / "payload-ran"
        bun = directory / "bin/bun"
        bun.parent.mkdir(parents=True, exist_ok=True)
        bun.write_text(f"#!/bin/sh\n: > {shlex.quote(str(canary))}\necho 1.4.4\n")
        bun.chmod(0o755)
        return canary

    def test_a_pin_that_walks_out_of_the_install_root_runs_nothing(self):
        """Codex review of #41001: the pin went unchecked into the mise path, so
        ../../../repository/payload ran the checkout's payload/bin/bun with no bun on PATH."""
        self.assertEqual(self.install().returncode, 0)
        canary = self.checkout_payload(self.repo / "payload")
        (self.root / "mise/installs/bun").mkdir(parents=True)
        (self.root / "asdf/installs/bun").mkdir(parents=True)
        env = self.bootstrap_env(pin="../../../repository/payload")
        result = self.run_pre_commit(env)
        self.assertFalse(canary.exists(), result.stderr)
        self.assertIn("not an exact major.minor.patch version", result.stderr)
        self.assertEqual(result.returncode, 0, "a refused pin installs nothing; the commit goes on")
        self.assertIn("not installing webviews packages", result.stderr)

    def test_a_pinned_install_resolving_into_the_checkout_is_not_run(self):
        self.assertEqual(self.install().returncode, 0)
        canary = self.checkout_payload(self.repo / "payload")
        (self.root / "mise/installs/bun").mkdir(parents=True)
        (self.root / "mise/installs/bun/1.4.4").symlink_to(self.repo / "payload")
        env = self.bootstrap_env()
        result = self.run_pre_commit(env)
        self.assertFalse(canary.exists(), result.stderr)
        self.assertIn("outside its install root", result.stderr)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_a_path_bun_inside_the_checkout_is_not_run(self):
        self.assertEqual(self.install().returncode, 0)
        canary = self.checkout_payload(self.repo / "tools")
        env = self.bootstrap_env()
        env["PATH"] = f"{env['PATH']}{os.pathsep}{self.repo / 'tools/bin'}"
        result = self.run_pre_commit(env)
        self.assertFalse(canary.exists(), result.stderr)
        self.assertIn("inside this checkout", result.stderr)
        self.assertEqual(result.returncode, 0, result.stderr)

    # devEngines shapes where the first "version" is not bun's (#41001 review, F1): the hook took
    # the first version inside devEngines, so an npm entry listed first, or a runtime engine before
    # packageManager, picked the bun it installed with, while check-webviews-bun-version.sh read
    # another. Both now read scripts/webviews_bun_version.py; on each shape they give one answer.
    BUN_PIN_SHAPES = {
        "plain": ({"packageManager": {"name": "bun", "version": "1.4.4", "onFail": "error"}}, "1.4.4"),
        "npm listed first": ({"packageManager": [
            {"name": "npm", "version": "10.9.2", "onFail": "ignore"},
            {"name": "bun", "version": "1.4.4", "onFail": "error"},
        ]}, "1.4.4"),
        "runtime engine listed first": ({
            "runtime": {"name": "node", "version": "24.22.1"},
            "packageManager": {"name": "bun", "version": "1.4.4", "onFail": "error"},
        }, "1.4.4"),
        "no bun entry": ({"packageManager": {"name": "npm", "version": "10.9.2", "onFail": "error"}}, None),
    }

    def test_a_bun_the_hook_cannot_vouch_for_never_runs(self):
        """#41001 review: no trusted reader copy, a refused pin or no bun at the pin used to fall
        back to PATH's bun by name. Each now installs nothing and says the fix (the commit goes on
        unformatted; CI checks formatting), and the planted PATH bun (outside
        the checkout, so the resolver alone would let it run) never runs, --version included."""
        self.assertEqual(self.install().returncode, 0)
        reader = Path(self.local_hooks_path()) / "webviews_bun_version.py"
        saved = reader.read_bytes()
        marker = self.root / "planted-bun-ran"
        planted = self.root / "planted-bin/bun"
        planted.parent.mkdir(parents=True, exist_ok=True)
        planted.write_text(f"#!/bin/sh\n: > {shlex.quote(str(marker))}\necho 1.3.0\n")
        planted.chmod(0o755)
        no_bun = '{"devEngines": {"packageManager": {"name": "npm", "version": "10.9.2"}}}\n'
        for case, package_json, remove_reader, says in (
            ("no trusted reader copy", None, True, "run scripts/install-git-hooks.sh"),
            ("no bun entry", no_bun, False, "no bun in devEngines.packageManager"),
            ("no bun at the pin", None, False, "install it: curl -fsSL https://bun.sh/install | bash -s bun-v1.4.4"),
        ):
            with self.subTest(case=case):
                marker.unlink(missing_ok=True)
                env = self.bootstrap_env()
                env["PATH"] = f"{planted.parent}{os.pathsep}{env['PATH']}"
                if package_json is not None:
                    (self.repo / "webviews/package.json").write_text(package_json)
                if remove_reader:
                    reader.unlink()
                try:
                    result = self.run_pre_commit(env)
                finally:
                    reader.write_bytes(saved)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(says, result.stderr)
                self.assertIn("not installing webviews packages", result.stderr)
                self.assertNotIn("PATH's bun", result.stderr)
                if case == "no bun at the pin":
                    # Only the pinned candidates are asked their version; none is 1.4.4, so nothing installs.
                    self.assertFalse((self.root / "bun.log").exists(), result.stderr)
                else:
                    self.assertFalse(marker.exists(), f"{case}: the planted PATH bun ran\n{result.stderr}")

    def test_hook_and_version_checker_read_one_bun_pin(self):
        self.assertEqual(self.install().returncode, 0)
        old_bun = self.root / "old-bun"
        old_bun.write_text("#!/bin/sh\necho 0.0.1\n")
        old_bun.chmod(0o755)
        for shape, (dev_engines, expected) in self.BUN_PIN_SHAPES.items():
            with self.subTest(shape=shape):
                env = self.bootstrap_env()
                (self.repo / "webviews/package.json").write_text(
                    json.dumps({"name": "webviews", "devEngines": dev_engines}, indent=2) + "\n")
                # A bun at every version these shapes name, and an older one on PATH.
                installed = {version: self.fake_bun(self.root / f"mise/installs/bun/{version}/bin/bun", version)
                             for version in ("1.4.4", "10.9.2", "24.22.1")}
                path_bun = self.fake_bun(Path(env["PATH"]) / "bun", "0.0.1")
                (self.root / "bun.log").unlink(missing_ok=True)
                try:
                    result = self.run_pre_commit(env)
                finally:
                    path_bun.unlink()
                ran = (self.root / "bun.log").read_text().splitlines() if (self.root / "bun.log").exists() else []
                if ran:
                    self.assertEqual(len(ran), 1, result.stderr)
                    hook = next(version for version, bun in installed.items() if ran[0] == str(bun))
                else:
                    # No pin it accepts: the hook installs nothing and commits unformatted.
                    hook = None
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn("not installing webviews packages", result.stderr)
                # The checker, on the same package.json, against a bun older than any pin: its
                # install command names the version it wants, or it refuses the declaration.
                checked = subprocess.run(["sh", str(self.repo / "scripts/check-webviews-bun-version.sh"), str(old_bun)],
                                         cwd=self.repo, env=self.env, text=True, capture_output=True)
                self.assertNotEqual(checked.returncode, 0, checked.stderr)
                wanted = re.search(r"bun-v([0-9.]+)", checked.stderr)
                checker = wanted.group(1) if wanted else None
                self.assertEqual((hook, checker), (expected, expected),
                                 f"hook stderr: {result.stderr}\nchecker stderr: {checked.stderr}")
                if expected is None:
                    self.assertIn("no bun in devEngines.packageManager", result.stderr)
                    self.assertIn("no bun in devEngines.packageManager", checked.stderr)

    def test_skip_variable_commits_without_formatting(self):
        self.assertEqual(self.install().returncode, 0)
        vp_log = self.root / "vp.log"
        web = self.stage_web_file("webviews")
        self.stage_rust_package("Native/OptChat/probe", "2021")
        # A partly staged file (git add -p) commits under the switch too.
        web.write_text(web.read_text() + "const   y=2\n")
        result = self.run_pre_commit(self.formatter_env(
            with_rustfmt=True, FAKE_VP_LOG=str(vp_log), CMUX_AGENT="1", CMUX_SKIP_FORMAT_HOOKS="1"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("CMUX_SKIP_FORMAT_HOOKS", result.stderr)
        self.assertFalse(vp_log.exists())
        self.assertFalse(self.rustfmt_log.exists())

    def test_a_formatter_that_cannot_run_lets_an_agent_commit_through_with_a_warning(self):
        """The machine's toolchain says nothing about the commit, and CI checks formatting. No vp, no
        node_modules, a vp that cannot start, an install lock another hook holds, or no rustfmt used to
        refuse every agent commit (CMUX_AGENT, CLAUDECODE, CODEX_*, CI); each now commits with one line naming why."""
        self.assertEqual(self.install().returncode, 0)
        web = self.repo / "webviews"
        lock = Path(self.git("rev-parse", "--absolute-git-dir").stdout.strip()) / "cmux-format-install-webviews.lock"

        def no_node_modules():
            self.stage_web_file("webviews")
            shutil.rmtree(web / "node_modules")

        def vp_cannot_start():
            self.stage_web_file("webviews")
            (web / "node_modules/.bin/vp").write_text("#!/bin/sh\necho 'env: node: No such file or directory' >&2\nexit 127\n")

        def lock_held_by_another_hook():
            no_node_modules()
            (web / "bun.lock").write_text("{}\n")
            lock.mkdir()
            (lock / "pid").write_text(f"{os.getpid()}\n")
            # The holder finishes (without a vp) while this hook waits for it.
            threading.Timer(1.0, shutil.rmtree, (lock,)).start()

        def no_rustfmt():
            self.stage_rust_package("Native/OptChat/probe", "2021")

        for case, arrange, says in (
            ("no node_modules (no vp)", no_node_modules, "vp is unavailable for webviews"),
            ("vp cannot start", vp_cannot_start, "vp fmt exited 127 in webviews"),
            ("install lock held", lock_held_by_another_hook, "vp is unavailable for webviews"),
            ("no rustfmt", no_rustfmt, "rustfmt is unavailable"),
        ):
            for agent in ({"CMUX_AGENT": "1"}, {"CLAUDECODE": "1"}, {"CI": "true"}):
                with self.subTest(case=case, agent=agent):
                    self.git("rm", "-r", "-q", "--cached", "--ignore-unmatch", "webviews", "Native")
                    shutil.rmtree(web, ignore_errors=True)
                    shutil.rmtree(self.repo / "Native", ignore_errors=True)
                    arrange()
                    staged = self.git("diff", "--cached", "--name-only").stdout
                    result = self.run_pre_commit(self.formatter_env(with_rustfmt=False, **agent))
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn(says, result.stderr)
                    self.assertIn("committing without formatting (CI checks formatting)", result.stderr)
                    self.assertNotIn("refusing", result.stderr)
                    self.assertEqual(self.git("diff", "--cached", "--name-only").stdout, staged,
                                     "the commit keeps exactly what was staged")

    def test_a_bad_staged_file_still_gets_formatted_or_refused(self):
        """What stays: a staged file vp can format is formatted and restaged for an agent too, and a
        staged file with unstaged edits still refuses (formatting would stage those edits)."""
        self.assertEqual(self.install().returncode, 0)
        vp_log = self.root / "vp.log"
        web = self.stage_web_file("webviews")
        env = self.formatter_env(with_rustfmt=False, FAKE_VP_LOG=str(vp_log), CMUX_AGENT="1")
        result = self.run_pre_commit(env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.git("show", ":webviews/src/app.ts").stdout, "formatted\n")
        web.write_text("const   x=1\nconst   y=2\n")
        self.git("add", "webviews/src/app.ts")
        web.write_text(web.read_text() + "const   z=3\n")
        result = self.run_pre_commit(env)
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertIn("webviews/src/app.ts has unstaged changes", result.stderr)

    def test_unstaged_rust_files_the_commit_does_not_touch_never_refuse_it(self):
        """rustfmt ran on file paths and follows `mod` declarations, so any unstaged or untracked .rs
        file in the package refused the commit. Each staged file is now formatted through stdin."""
        self.assertEqual(self.install().returncode, 0)
        source = self.stage_rust_package("Native/OptChat/probe", "2021")
        tracked = source.parent / "lib.rs"
        tracked.write_text("pub fn a() {}\n")
        self.git("add", str(tracked))
        self.git("-c", "user.name=t", "-c", "user.email=t@t", "-c", "core.hooksPath=/dev/null",
                 "commit", "-q", "-m", "base")
        source.write_text("mod other;\nfn   main() {}\n")
        self.git("add", str(source))
        tracked.write_text("pub fn   a() {}\n")  # an unstaged edit
        untracked = source.parent / "other.rs"
        untracked.write_text("fn   b() {}\n")  # an untracked module the staged file declares
        result = self.run_pre_commit(self.formatter_env(with_rustfmt=True, CMUX_AGENT="1"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("unstaged Rust edits", result.stderr)
        self.assertEqual(self.git("show", ":Native/OptChat/probe/src/main.rs").stdout, "mod other;\nfn main() {}\n")
        self.assertEqual(tracked.read_text(), "pub fn   a() {}\n", "an unstaged file is never rewritten")
        self.assertEqual(untracked.read_text(), "fn   b() {}\n", "an untracked file is never rewritten")

    def fake_rustup(self, bin_dir, installed, pinned):
        rustup = bin_dir / "rustup"
        rustup.write_text(
            "#!/bin/sh\n"
            f'if [ "$1 $2 $3 $4" = "which --toolchain {installed} rustfmt" ]; then echo {shlex.quote(str(pinned))}; exit 0; fi\n'
            "exit 1\n")
        rustup.chmod(0o755)

    def test_pre_commit_uses_the_rustfmt_of_the_pinned_toolchain(self):
        self.assertEqual(self.install().returncode, 0)
        source = self.stage_rust_package("cmux-tui", "2021")
        (self.repo / "cmux-tui/rust-toolchain.toml").write_text('[toolchain]\nchannel = "1.95.0"\n')
        env = self.formatter_env(with_rustfmt=True)
        pinned = self.root / "pinned-rustfmt"
        pinned.write_text(f'#!/bin/sh\nprintf "pinned %s\\n" "$*" >> {shlex.quote(str(self.rustfmt_log))}\n'
                          f"exec {shlex.quote(shutil.which('sed'))} 's/  */ /g'\n")
        pinned.chmod(0o755)
        self.fake_rustup(self.root / "bin-rustfmt", "1.95.0", pinned)
        result = self.run_pre_commit(env)
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.rustfmt_log.read_text().splitlines()
        self.assertEqual(len(calls), 1, calls)
        self.assertTrue(calls[0].startswith("pinned --edition 2021 "), calls)
        self.assertEqual(self.git("show", ":cmux-tui/src/main.rs").stdout, source.read_text())

    def test_a_missing_pinned_toolchain_falls_back_to_path_rustfmt_with_a_warning(self):
        # rustfmt keeps a stable style across versions, so formatting with the
        # PATH rustfmt beats committing unformatted code.
        self.assertEqual(self.install().returncode, 0)
        self.stage_rust_package("cmux-tui", "2021")
        (self.repo / "cmux-tui/rust-toolchain.toml").write_text('[toolchain]\nchannel = "1.95.0"\n')
        env = self.formatter_env(with_rustfmt=True, CMUX_AGENT="1")
        self.fake_rustup(self.root / "bin-rustfmt", "1.99.0", "/nonexistent")
        result = self.run_pre_commit(env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("rustup toolchain install 1.95.0", result.stderr)
        self.assertEqual(len(self.rustfmt_log.read_text().splitlines()), 1)

    # A program the checkout carries: any run of it leaves ran-<name>, then it
    # does the real tool's job (if there is one) so the hook would go on.
    def plant(self, directory, name):
        real = shutil.which(name, path=str(self.root / "bin-rustfmt"))
        marker = self.root / f"ran-{name}"
        directory.mkdir(parents=True, exist_ok=True)
        tool = directory / name
        tool.write_text(f"#!/bin/sh\n: > {shlex.quote(str(marker))}\n"
                        + (f'exec {shlex.quote(real)} "$@"\n' if real else "exit 1\n"))
        tool.chmod(0o755)
        return marker

    def test_a_checkout_rustup_on_path_never_runs(self):
        """Codex review of #41001 (F1): rustup was called by name, so a checkout staging Rust
        files and a rust-toolchain file ran its own rustup put ahead on PATH."""
        self.assertEqual(self.install().returncode, 0)
        self.stage_rust_package("cmux-tui", "2021")
        (self.repo / "cmux-tui/rust-toolchain.toml").write_text('[toolchain]\nchannel = "1.95.0"\n')
        base = self.formatter_env(with_rustfmt=True)["PATH"]
        for label, entry, directory in (
            ("absolute entry", str(self.repo / "tools/bin"), self.repo / "tools/bin"),
            ("relative entry", "tools/bin", self.repo / "tools/bin"),
            ("empty entry (the current directory)", "", self.repo),
        ):
            with self.subTest(label):
                marker = self.plant(directory, "rustup")
                self.rustfmt_log.unlink(missing_ok=True)
                env = self.formatter_env(with_rustfmt=True)
                env["PATH"] = f"{entry}{os.pathsep}{base}"
                result = self.run_pre_commit(env)
                (directory / "rustup").unlink()
                self.assertFalse(marker.exists(), result.stderr)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("rustup toolchain install 1.95.0", result.stderr, "PATH's rustfmt formats instead")
                self.assertEqual(len(self.rustfmt_log.read_text().splitlines()), 1, result.stderr)

    def test_no_tool_the_checkout_puts_on_path_runs(self):
        """The whole class: every program the hook runs (git, sed, env, rustfmt, bun...) is
        resolved outside the checkout, so a checkout's own copy first on PATH never runs."""
        self.assertEqual(self.install().returncode, 0)
        self.stage_rust_package("cmux-tui", "2021")
        (self.repo / "cmux-tui/rust-toolchain.toml").write_text('[toolchain]\nchannel = "1.95.0"\n')
        env = self.formatter_env(with_rustfmt=True)
        self.fake_rustup(self.root / "bin-rustfmt", "1.99.0", "/nonexistent")
        plants = self.repo / "plants/bin"
        names = ("git", "sed", "grep", "head", "cut", "sort", "awk", "cat", "mkdir", "mv", "rm", "find",
                 "env", "mktemp", "tail", "sleep", "rustup", "rustfmt", "bun", "npm", "node", "swift-format")
        markers = [self.plant(plants, name) for name in names]
        env["PATH"] = f"{plants}{os.pathsep}{env['PATH']}"
        result = self.run_pre_commit(env)
        self.assertEqual([marker.name for marker in markers if marker.exists()], [], result.stderr)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.rustfmt_log.read_text().splitlines()), 1, result.stderr)

    # A script `sh` runs when the hook's first `git rev-parse` reaches a shell named git.
    def plant_rev_parse(self):
        marker = self.root / "checkout-rev-parse-ran"
        (self.repo / "rev-parse").write_text(f": > {shlex.quote(str(marker))}\n")
        return marker

    def test_a_checkout_link_named_git_to_an_outside_shell_never_runs(self):
        """Codex review of #41001 (F1): only the final target was checked, so a tracked
        tools/bin/git -> /bin/sh passed, and the hook's `git rev-parse` ran the checkout's rev-parse."""
        self.assertEqual(self.install().returncode, 0)
        marker = self.plant_rev_parse()
        tools = self.repo / "tools/bin"
        tools.mkdir(parents=True)
        (tools / "git").symlink_to("/bin/sh")
        self.git("add", "tools/bin/git")
        env = self.formatter_env(with_rustfmt=False)
        env["PATH"] = f"{tools}{os.pathsep}{env['PATH']}"
        result = self.run_pre_commit(env)
        self.assertFalse(marker.exists(), result.stderr)
        self.assertIn("inside this checkout", result.stderr)
        self.assertEqual(result.returncode, 0, "PATH's real git runs instead\n" + result.stderr)

    # A webviews package with a package-lock.json and no vp: the hook installs it with the
    # PATH npm, an outside script whose `#!/usr/bin/env <interpreter>` looks its interpreter up.
    def npm_bootstrap_env(self, interpreter="node"):
        env = self.bootstrap_env()
        web = self.repo / "webviews"
        (web / "bun.lock").unlink()
        (web / "package-lock.json").write_text('{"packages": {}}\n')
        npm = self.root / "npm-bin/npm"
        npm.parent.mkdir(exist_ok=True)
        npm.write_text(f"#!/usr/bin/env {interpreter}\nexit 1\n")
        npm.chmod(0o755)
        env["PATH"] = f"{npm.parent}{os.pathsep}{env['PATH']}"
        return env

    def checkout_interpreter(self, name):
        """A program in the checkout that leaves its marker when it runs."""
        marker = self.root / f"checkout-{name}-ran"
        payload = self.repo / "payload-bin" / name
        payload.parent.mkdir(exist_ok=True)
        real = shutil.which(name, path=str(self.root / "bin-plain"))
        payload.write_text(f"#!/bin/sh\n: > {shlex.quote(str(marker))}\n"
                           + (f'exec {shlex.quote(real)} "$@"\n' if real else "exit 1\n"))
        payload.chmod(0o755)
        return payload, marker

    def test_an_outside_node_linking_into_the_checkout_never_runs_for_npm(self):
        """Codex review of #41001 (F2): the children's PATH dropped checkout directories but kept an
        outside directory holding node -> <checkout>/payload, so npm's `#!/usr/bin/env node` ran it."""
        self.assertEqual(self.install().returncode, 0)
        payload, marker = self.checkout_interpreter("node")
        outside = self.root / "outside-bin"
        outside.mkdir()
        (outside / "node").symlink_to(payload)
        env = self.npm_bootstrap_env()
        env["PATH"] = f"{env['PATH']}{os.pathsep}{outside}"
        result = self.run_pre_commit(env)
        self.assertFalse(marker.exists(), result.stderr)
        self.assertIn("inside this checkout", result.stderr)
        # npm's `env node` finds no checked node, and says so instead of a bare not-found.
        self.assertIn("node is in CHILD_TOOLS (scripts/git-hooks/pre-commit), but PATH has no copy of it"
                      " outside this checkout", result.stderr)

    def symlink_layouts(self, name, payload):
        """(label, PATH entry) for each layout that steers a lookup of name at payload in the checkout."""
        layouts = []

        def place(label, directory):
            layouts.append((label, str(directory)))
            return directory

        d = place("a file in a checkout directory", self.repo / f"lay-file-{name}")
        d.mkdir()
        shutil.copy2(payload, d / name)
        d = place("an outside link to a checkout file", self.root / f"lay-link-{name}")
        d.mkdir()
        (d / name).symlink_to(payload)
        d = place("a relative outside link into the checkout", self.root / f"lay-relative-{name}")
        d.mkdir()
        (d / name).symlink_to(os.path.relpath(payload, d))
        place("an outside directory linking to a checkout directory",
              self.root / f"lay-dirlink-{name}").symlink_to(payload.parent, target_is_directory=True)
        hop = self.root / f"lay-dirhop-{name}"
        hop.symlink_to(payload.parent, target_is_directory=True)
        place("chained outside directory links into the checkout",
              self.root / f"lay-dirchain-{name}").symlink_to(hop, target_is_directory=True)
        d = place("chained file links through the checkout", self.root / f"lay-chain-{name}")
        d.mkdir()
        outside_hop = self.root / f"lay-chain-hop2-{name}"
        outside_hop.symlink_to(payload)
        checkout_hop = self.repo / f"lay-chain-hop1-{name}"
        checkout_hop.symlink_to(outside_hop)
        (d / name).symlink_to(checkout_hop)
        d = place("an outside directory linking to checkout links",
                  self.root / f"lay-mixed-{name}")
        d.symlink_to(self.repo / f"lay-mixed-target-{name}", target_is_directory=True)
        (self.repo / f"lay-mixed-target-{name}").mkdir()
        (self.repo / f"lay-mixed-target-{name}" / name).symlink_to(payload)
        if name == "git":
            # The F1 class: a link the checkout controls, whose final target is an outside program.
            d = place("a checkout link to an outside shell", self.repo / "lay-shell")
            d.mkdir()
            (d / "git").symlink_to("/bin/sh")
            d = place("an outside link through a checkout link to an outside shell", self.root / "lay-shell-chain")
            d.mkdir()
            (self.repo / "lay-shell-hop").symlink_to("/bin/sh")
            (d / "git").symlink_to(self.repo / "lay-shell-hop")
        return layouts

    def test_no_symlink_layout_runs_anything_under_the_checkout(self):
        """The class behind F1 and F2: every name the hook or its children run goes through one
        checked resolver that rejects any hop inside the checkout. For git (run by the hook), node
        and sh (run by an npm's shebang), every layout of links and directories that would steer the
        name into the checkout runs nothing there."""
        self.assertEqual(self.install().returncode, 0)
        self.formatter_env(with_rustfmt=False)  # makes bin-plain for the payloads' real tools
        rev_parse = self.plant_rev_parse()
        for name in ("git", "node", "sh"):
            payload, marker = self.checkout_interpreter(name)
            for label, entry in self.symlink_layouts(name, payload):
                with self.subTest(name=name, layout=label):
                    marker.unlink(missing_ok=True)
                    rev_parse.unlink(missing_ok=True)
                    env = self.npm_bootstrap_env(name) if name != "git" else self.formatter_env(with_rustfmt=False)
                    env["PATH"] = f"{entry}{os.pathsep}{env['PATH']}"
                    result = self.run_pre_commit(env)
                    self.assertEqual([m.name for m in (marker, rev_parse) if m.exists()], [], result.stderr)
                    self.assertIn("inside this checkout", result.stderr)
                    if name == "git":
                        self.assertEqual(result.returncode, 0, result.stderr)

    def test_a_child_running_a_tool_not_in_child_tools_names_it(self):
        """A child of the hook that needs a tool missing from CHILD_TOOLS got a bare
        command-not-found; by name, by exec and by shebang it now names the tool and the list.
        A hidden executable (.hidden-tool) is a tool like any other: the review of #41254
        found every name starting with "." skipped. Executability decides, not the name."""
        self.assertEqual(self.install().returncode, 0)
        marker = self.root / "unlisted-ran"
        extra = self.root / "extra-bin"
        extra.mkdir()
        for tool in ("frobnicate", ".hidden-tool"):
            unlisted = extra / tool
            unlisted.write_text(f"#!/bin/sh\n: > {shlex.quote(str(marker))}\n")
            unlisted.chmod(0o755)
            script = self.root / f"child-script{tool}"
            script.write_text(f"#!/usr/bin/env {tool}\n")
            script.chmod(0o755)
            for how, call in (("by name", f"{tool} --version"),
                              ("by exec", f"exec {tool} --version"),
                              ("by shebang", shlex.quote(str(script)))):
                with self.subTest(tool=tool, how=how):
                    marker.unlink(missing_ok=True)
                    result = self.run_child_with_extra_path(extra, call)
                    self.assertFalse(marker.exists(), "an unlisted tool never runs\n" + result.stderr)
                    self.assertIn(f"{tool} isn't in CHILD_TOOLS (scripts/git-hooks/pre-commit)", result.stderr)
                    self.assertIn("exit 127", result.stderr)
        # A file on PATH that is not executable is no tool: no stub claims it is one.
        inert = extra / "inert-file"
        inert.write_text("#!/bin/sh\n")
        inert.chmod(0o644)
        result = self.run_child_with_extra_path(extra, "inert-file --version")
        self.assertNotIn("inert-file isn't in CHILD_TOOLS", result.stderr)
        self.assertIn("exit 127", result.stderr)

    def run_child_with_extra_path(self, extra, call):
        env = self.bootstrap_env()
        env["PATH"] = f"{env['PATH']}{os.pathsep}{extra}"
        bun = self.fake_bun(Path(env["PATH"].split(os.pathsep)[0]) / "bun", "1.4.4", install_body=call)
        try:
            return self.run_pre_commit(env)
        finally:
            bun.unlink()

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

    def test_generated_web_bundles_keep_ours_and_sources_still_conflict(self):
        shutil.copyfile(SOURCE / ".gitattributes", self.repo / ".gitattributes")
        self.git("config", "user.name", "t")
        self.git("config", "user.email", "t@example.com")
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        driver = shlex.split(self.git("config", "--get", "merge.cmux-generated-v1.driver").stdout.strip())
        self.assertEqual([Path(driver[2]).name, *driver[3:]], ["merge-insertions.py", "--generated", "%O", "%A", "%B",
                                                               "%P", "%L"])
        self.assertNotEqual(Path(driver[2]).resolve(), (self.repo / "scripts/merge-insertions.py").resolve())

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

    def test_every_generated_web_output_keeps_ours(self):
        """The bundles the agent pane build writes beside index.html, and the strings
        tables the builds generate, collided on every feat-cmux-next move until each
        PR rebuilt them by hand."""
        shutil.copyfile(SOURCE / ".gitattributes", self.repo / ".gitattributes")
        self.git("config", "user.name", "t")
        self.git("config", "user.email", "t@example.com")
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        outputs = [self.repo / path for path in (
            "Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/Resources/agent-pane/pane.js",
            "Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/Resources/agent-pane/locales/en.js",
            "Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/Resources/agent-pane/highlight-worker.js",
            "webviews/src/agent-session/acpmux/generated/strings.json",
            "webviews/src/pages/settings/generated/strings.json",
            # The docs reference that follows the schema: 13 conflicts in a week.
            "web/data/next-docs/settings-reference.generated.json",
            "cmux-tui/bindings/go/raw/generated_types.go",
            "cmux-tui/bindings/rust/src/generated/types.rs",
        )]
        for path in outputs:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("base\n", encoding="utf-8")
        self.commit_all("base")
        self.git("checkout", "--quiet", "-b", "lane")
        for path in outputs:
            path.write_text("lane build\n", encoding="utf-8")
        self.commit_all("lane")
        self.git("checkout", "--quiet", "main")
        for path in outputs:
            path.write_text("main build\n", encoding="utf-8")
        self.commit_all("main")
        self.git("checkout", "--quiet", "lane")

        merged = self.git("merge", "--no-edit", "main", check=False)
        self.assertEqual(merged.returncode, 0, merged.stdout + merged.stderr)
        for path in outputs:
            self.assertEqual(path.read_text(encoding="utf-8"), "lane build\n", path)

    def test_mac_only_exports_never_keep_one_side(self):
        """The exports only a Mac rebuilds (settings schema, docs/mdm, the action exports, the CI target graph)
        kept this branch's copy until 2026-11-22, which dropped base's settings rows on cmux#45928 and cmux#47525
        with no conflict. Now both sides' rows merge, and two rebuilds of one line stop the merge on that file."""
        shutil.copyfile(SOURCE / ".gitattributes", self.repo / ".gitattributes")
        self.git("config", "user.name", "t")
        self.git("config", "user.email", "t@example.com")
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        exports = [self.repo / path for path in (
            "plans/cmux-next/actions.md",
            "schemas/settings/settings-schema.json",
            "docs/mdm/com.manaflow.cmux.json",
            "docs/mdm/com.manaflow.cmux.plist",
            "docs/mdm/managed-preferences.md",
            "Packages/macOS/CmuxNext/ci-target-graph.json",
        )]
        for path in exports:
            self.assertEqual(self.git("check-attr", "merge", "--", str(path.relative_to(self.repo))).stdout.split()[-1],
                             "cmux-export-v1", path)

        def rows(*keys):
            for path in exports:
                path.parent.mkdir(parents=True, exist_ok=True)
                if path.suffix == ".json":
                    body = ",\n".join(f'  "{key}" : 1' for key in keys)
                    path.write_text("{\n" + body + "\n}\n", encoding="utf-8")
                elif path.suffix == ".plist":
                    path.write_text("<dict>\n" + "".join(f"<key>{key}</key><true/>\n" for key in keys) + "</dict>\n",
                                    encoding="utf-8")
                else:
                    path.write_text("# rows\n\n" + "".join(f"- {key}\n" for key in keys) + "\nend\n",
                                    encoding="utf-8")

        rows("a", "z")
        self.commit_all("base")
        self.git("checkout", "--quiet", "-b", "lane")
        rows("a", "lane", "z")
        self.commit_all("lane")
        self.git("checkout", "--quiet", "main")
        rows("a", "base", "z")
        self.commit_all("main")
        self.git("checkout", "--quiet", "lane")
        merged = self.git("merge", "--no-edit", "main", check=False)
        self.assertEqual(merged.returncode, 0, merged.stdout + merged.stderr)
        for path in exports:
            text = path.read_text(encoding="utf-8")
            self.assertIn("lane", text, path)
            self.assertIn("base", text, path)  # base's row, which the old driver dropped

        # A real disagreement (both sides rewrote one line) is a conflict on that file, never one side.
        target = exports[0]
        target.write_text("lane rewrite\n", encoding="utf-8")
        self.commit_all("lane rewrite")
        self.git("checkout", "--quiet", "main")
        target.write_text("main rewrite\n", encoding="utf-8")
        self.commit_all("main rewrite")
        self.git("checkout", "--quiet", "lane")
        conflicted = self.git("merge", "--no-edit", "main", check=False)
        self.assertNotEqual(conflicted.returncode, 0)
        self.assertEqual(self.git("diff", "--name-only", "--diff-filter=U").stdout.split(), ["plans/cmux-next/actions.md"])

    def test_generated_files_keep_both_sides_rows_when_they_merge(self):
        """A file regenerate rebuilds still merges three-way when that is clean: a merge that stops on a
        hand-written file never runs the post-merge rebuild, and cmux#47525 committed the kept copies of the
        settings Swift without base's rows that way (AgentPolicy, PageLayoutCategories)."""
        shutil.copyfile(SOURCE / ".gitattributes", self.repo / ".gitattributes")
        self.git("config", "user.name", "t")
        self.git("config", "user.email", "t@example.com")
        self.assertEqual(self.install().returncode, 0)
        swift = self.repo / "Packages/macOS/CmuxNext/Sources/CmuxNextSettings/Schema/SettingsSchema+AgentPolicy.generated.swift"
        swift.parent.mkdir(parents=True, exist_ok=True)

        def rows(*keys):
            swift.write_text("let keys = [\n" + "".join(f'    "{key}",\n' for key in keys) + "]\n", encoding="utf-8")

        rows("a", "z")
        self.commit_all("base")
        self.git("checkout", "--quiet", "-b", "lane")
        rows("a", "lane", "z")
        self.commit_all("lane")
        self.git("checkout", "--quiet", "main")
        rows("a", "base", "z")
        self.commit_all("main")
        self.git("checkout", "--quiet", "lane")
        merged = self.git("merge", "--no-edit", "main", check=False)
        self.assertEqual(merged.returncode, 0, merged.stdout + merged.stderr)
        self.assertEqual(swift.read_text(encoding="utf-8"), 'let keys = [\n    "a",\n    "lane",\n    "base",\n    "z",\n]\n')

    def test_kept_generated_files_are_ones_the_ci_merger_rebuilds(self):
        """A kept copy is only safe where a rebuild replaces it: next_batch.py's
        merger rebuilds the web, Swift and SDK classes and blocks any other path
        both sides changed. A generated file with no check (the app permission
        scopes) would keep a stale copy silently."""
        import sys
        sys.path.insert(0, str(SOURCE / "scripts/ci"))
        import next_batch
        files = [path for path in subprocess.run(["git", "ls-files", "-z"], cwd=SOURCE, check=True,
                                                 capture_output=True, text=True).stdout.split("\0") if path]
        # The paths go through a file, never `input=`: a pipe write can block for good (scripts/cmux-next/git_batch.py).
        with tempfile.TemporaryFile() as paths:
            paths.write("\0".join(files).encode())
            paths.seek(0)
            attributes = subprocess.run(["git", "check-attr", "merge", "--stdin", "-z"], cwd=SOURCE, check=True,
                                        stdin=paths, capture_output=True, text=True).stdout.split("\0")
        kept = [path for path, _, value in zip(attributes[0::3], attributes[1::3], attributes[2::3])
                if value == "cmux-generated-v1"]
        self.assertTrue(kept)
        self.assertEqual([path for path in kept
                          if next_batch.classify(path) not in {"web", "swift", "sdk", "generated"}], [])

    def test_hand_written_sdk_files_still_merge_normally(self):
        shutil.copyfile(SOURCE / ".gitattributes", self.repo / ".gitattributes")
        self.assertEqual(self.install().returncode, 0)
        for path in ("cmux-tui/bindings/go/raw/client.go", "cmux-tui/bindings/java/src/com/cmux/raw/CmuxClient.java"):
            attribute = self.git("check-attr", "merge", "--", path).stdout.strip()
            self.assertTrue(attribute.endswith(": unspecified"), attribute)

    def test_the_merge_driver_section_runs_alone(self):
        """leo-workspace's wt installs merge drivers into every worktree mirror by running only this
        section, from its MERGE_DRIVER_DIR= line through its last `git config merge.` or "merge driver
        installed" line, with GIT_COMMON_DIR and PYTHON3_BIN set and nothing else of the installer. It
        stopped at an unset TRUSTED_HOOK_DIR (2026-11-16), so those clones merged generated files by line."""
        lines = (SOURCE / INSTALLER).read_text(encoding="utf-8").splitlines()
        start = next(i for i, line in enumerate(lines) if line.startswith("MERGE_DRIVER_DIR="))
        end = max(i for i, line in enumerate(lines) if i >= start and re.match(
            r'^\s*(git config merge\.|echo "==> .*merge driver installed)', line))
        section = "\n".join(lines[start:end + 1])
        mirror = self.root / "mirror.git"
        git_fixture_env.init_repo(mirror, "--bare", env=self.env)
        python3 = os.path.realpath(sys.executable)
        script = f"set -euo pipefail\nGIT_COMMON_DIR={shlex.quote(str(mirror))}\nPYTHON3_BIN={shlex.quote(python3)}\n{section}"
        env = {key: value for key, value in self.env.items() if key not in ("TRUSTED_HOOK_DIR",)}
        ran = subprocess.run(["bash", "-c", script], cwd=SOURCE, env={**env, "GIT_DIR": str(mirror)},
                             text=True, capture_output=True)
        self.assertEqual(ran.returncode, 0, ran.stderr)
        configured = subprocess.run(["git", "--git-dir", str(mirror), "config", "--get-regexp", r"^merge\..*\.driver$"],
                                    env=self.env, text=True, capture_output=True, check=True).stdout
        drivers = dict(line.split(" ", 1) for line in configured.splitlines())
        attributes = (SOURCE / ".gitattributes").read_text(encoding="utf-8")
        names = set(re.findall(r"(?:^|\s)merge=([A-Za-z0-9._-]+)", "\n".join(
            line for line in attributes.splitlines() if not line.lstrip().startswith("#"))))
        for name in names:
            self.assertIn(f"merge.{name}.driver", drivers, name)
            for word in shlex.split(drivers[f"merge.{name}.driver"]):
                if word.startswith(str(mirror)):
                    self.assertTrue(Path(word).is_file(), f"merge.{name}.driver runs {word}, which the section did not install")

    def test_ratchet_baselines_merge_entry_by_entry(self):
        """Two lanes that each change different baseline entries merge cleanly,
        keeping both changes; the same entry changed two ways conflicts."""
        shutil.copyfile(SOURCE / ".gitattributes", self.repo / ".gitattributes")
        self.git("config", "user.name", "t")
        self.git("config", "user.email", "t@example.com")
        self.assertEqual(self.install().returncode, 0)
        tsv = self.repo / "scripts/cmux-next/godfile-baseline.tsv"
        ratchet = self.repo / "scripts/lint-namespace-types-ratchet.txt"
        counts = self.repo / "scripts/cmux-next/main-actor-work-baseline.json"
        for path in (tsv, ratchet, counts):
            path.parent.mkdir(parents=True, exist_ok=True)
        tsv.write_text("rust-file\ta.rs\t900\t40\nrust-file\tb.rs\t800\t30\nrust-file\tc.rs\t700\t20\n")
        ratchet.write_text("# header\nA.swift:A\nB.swift:B\nC.swift:C\n")
        counts.write_text(json.dumps({"A.swift": {"decode": 2}, "B.swift": {"decode": 1}}, indent=1, sort_keys=True) + "\n")
        self.commit_all("base")
        base = self.git("rev-parse", "HEAD").stdout.strip()
        self.git("checkout", "--quiet", "-b", "lane")
        tsv.write_text("rust-file\tb.rs\t800\t30\nrust-file\tc.rs\t700\t20\n")  # fixed a.rs
        ratchet.write_text("# header\nB.swift:B\nC.swift:C\n")
        counts.write_text(json.dumps({"B.swift": {"decode": 1}}, indent=1, sort_keys=True) + "\n")
        self.commit_all("lane")
        self.git("checkout", "--quiet", "main")
        tsv.write_text("rust-file\ta.rs\t900\t40\nrust-file\tb.rs\t750\t30\nrust-file\tc.rs\t700\t20\n")  # b.rs shrank
        ratchet.write_text("# header\nA.swift:A\nB.swift:B\n")
        counts.write_text(json.dumps({"A.swift": {"decode": 2}, "B.swift": {"decode": 1}, "D.swift": {"decode": 1}},
                                     indent=1, sort_keys=True) + "\n")
        self.commit_all("main")
        self.git("checkout", "--quiet", "lane")

        merged = self.git("merge", "--no-edit", "main", check=False)
        self.assertEqual(merged.returncode, 0, merged.stdout + merged.stderr)
        self.assertEqual(tsv.read_text(), "rust-file\tb.rs\t750\t30\nrust-file\tc.rs\t700\t20\n")
        self.assertEqual(ratchet.read_text(), "# header\nB.swift:B\n")
        self.assertEqual(json.loads(counts.read_text()), {"B.swift": {"decode": 1}, "D.swift": {"decode": 1}})

        self.git("checkout", "--quiet", "-b", "other", base)
        tsv.write_text("rust-file\ta.rs\t900\t40\nrust-file\tb.rs\t780\t30\nrust-file\tc.rs\t700\t20\n")
        self.commit_all("other")
        self.git("checkout", "--quiet", "lane")
        clash = self.git("merge", "--no-edit", "other", check=False)
        self.assertNotEqual(clash.returncode, 0)
        self.assertIn("<<<<<<< ours\nrust-file\tb.rs\t750\t30\n=======\nrust-file\tb.rs\t780\t30\n>>>>>>> theirs",
                      tsv.read_text())
        self.git("merge", "--abort")

        # A JSON entry changed two ways also leaves markers, never a clean-looking ours.
        self.git("checkout", "--quiet", "-b", "json-other", base)
        counts.write_text(json.dumps({"A.swift": {"decode": 5}, "B.swift": {"decode": 1}}, indent=1, sort_keys=True) + "\n")
        self.commit_all("json other")
        self.git("checkout", "--quiet", "lane")
        clash = self.git("merge", "--no-edit", "json-other", check=False)
        self.assertNotEqual(clash.returncode, 0)
        self.assertIn("<<<<<<<", counts.read_text())
        self.assertIn('"decode": 5', counts.read_text())

    def test_design_token_baseline_merges_count_by_count(self):
        shutil.copyfile(SOURCE / ".gitattributes", self.repo / ".gitattributes")
        self.git("config", "user.name", "t")
        self.git("config", "user.email", "t@example.com")
        self.assertEqual(self.install().returncode, 0)
        jsonl = self.repo / "webviews/scripts/design-tokens-baseline.jsonl"
        jsonl.parent.mkdir(parents=True, exist_ok=True)
        row = '{{"file":"{}","kind":"height","property":"height","values":{}}}\n'.format
        jsonl.write_text(row("a.css", '{"8px":2,"9px":1}') + row("b.css", '{"4px":1}'))
        self.commit_all("base")
        self.git("checkout", "--quiet", "-b", "lane")
        jsonl.write_text(row("a.css", '{"8px":1,"9px":1}') + row("b.css", '{"4px":1}'))
        self.commit_all("lane")
        self.git("checkout", "--quiet", "main")
        jsonl.write_text(row("a.css", '{"8px":2}') + row("b.css", '{"4px":1}') + row("c.css", '{"6px":1}'))
        self.commit_all("main")
        self.git("checkout", "--quiet", "lane")
        merged = self.git("merge", "--no-edit", "main", check=False)
        self.assertEqual(merged.returncode, 0, merged.stdout + merged.stderr)
        self.assertEqual(jsonl.read_text(), row("a.css", '{"8px":1}') + row("b.css", '{"4px":1}')
                         + row("c.css", '{"6px":1}'))

        # Two rows with one key: a merge would keep one row's counts and drop the other's.
        self.git("checkout", "--quiet", "-b", "doubled")
        jsonl.write_text(row("a.css", '{"8px":1}') + row("a.css", '{"7px":3}'))
        self.commit_all("doubled")
        doubled = self.git("rev-parse", "HEAD").stdout.strip()
        jsonl.write_text(row("a.css", '{"8px":1}') + row("a.css", '{"7px":3}') + row("d.css", '{"1px":1}'))
        self.commit_all("doubled ours")
        self.git("checkout", "--quiet", "-b", "doubled-theirs", doubled)
        jsonl.write_text(row("a.css", '{"8px":2}') + row("a.css", '{"7px":3}'))
        self.commit_all("doubled theirs")
        clash = self.git("merge", "--no-edit", "doubled", check=False)
        self.assertNotEqual(clash.returncode, 0, clash.stdout + clash.stderr)
        self.git("merge", "--abort")

        # The same key with its fields in another order is still the same key.
        reordered = '{"property":"height","kind":"height","file":"a.css","values":{"7px":3}}\n'
        self.git("checkout", "--quiet", "-b", "reordered", doubled)
        jsonl.write_text(row("a.css", '{"8px":1}'))
        self.commit_all("single")
        single = self.git("rev-parse", "HEAD").stdout.strip()
        jsonl.write_text(row("a.css", '{"8px":1}') + reordered)
        self.commit_all("reordered ours")
        reordered_ours = self.git("rev-parse", "HEAD").stdout.strip()
        self.git("checkout", "--quiet", "-b", "reordered-theirs", single)
        jsonl.write_text(row("a.css", '{"8px":2}'))
        self.commit_all("reordered theirs")
        clash = self.git("merge", "--no-edit", reordered_ours, check=False)
        self.assertNotEqual(clash.returncode, 0, clash.stdout + clash.stderr)
        self.git("merge", "--abort")

    def test_insertions_both_sides_made_merge_and_changes_still_conflict(self):
        """Two lanes that each append to the same list merge with both entries; a line both
        changed, or a JSON result that no longer parses, stays a conflict."""
        shutil.copyfile(SOURCE / ".gitattributes", self.repo / ".gitattributes")
        self.git("config", "user.name", "t")
        self.git("config", "user.email", "t@example.com")
        self.assertEqual(self.install().returncode, 0)
        command = shlex.split(self.git("config", "--get", "merge.cmux-insertions-v1.driver").stdout.strip())
        self.assertEqual(Path(command[2]).resolve(),
                         (self.common_dir() / "cmux-merge-drivers/merge-insertions.py").resolve())
        self.assertEqual(command[3:], ["%O", "%A", "%B", "%P", "%L"])
        log = self.repo / "plans/cmux-next/sidebar-owner.md"
        lib = self.repo / "cmux-tui/crates/demo/src/lib.rs"
        surfaces = self.repo / ".github/design-surfaces.json"
        for path in (log, lib, surfaces):
            path.parent.mkdir(parents=True, exist_ok=True)
        log.write_text("# Log\n\n- first\n")
        lib.write_text("pub mod a;\n\nfn shared() {}\n")
        surfaces.write_text('{\n "a": 1\n}\n')
        self.commit_all("base")
        base = self.git("rev-parse", "HEAD").stdout.strip()
        self.git("checkout", "--quiet", "-b", "lane")
        log.write_text("# Log\n\n- first\n- lane entry\n")
        lib.write_text("pub mod a;\npub mod lane;\n\nfn shared() {}\n")
        self.commit_all("lane")
        self.git("checkout", "--quiet", "main")
        log.write_text("# Log\n\n- first\n- main entry\n")
        lib.write_text("pub mod a;\npub mod main;\n\nfn shared() {}\n")
        self.commit_all("main")
        self.git("checkout", "--quiet", "lane")
        merged = self.git("merge", "--no-edit", "main", check=False)
        self.assertEqual(merged.returncode, 0, merged.stdout + merged.stderr)
        self.assertEqual(log.read_text(), "# Log\n\n- first\n- lane entry\n- main entry\n")
        self.assertEqual(lib.read_text(), "pub mod a;\npub mod lane;\npub mod main;\n\nfn shared() {}\n")

        # Two appended functions both end in `}`: each keeps its own.
        self.git("checkout", "--quiet", "-b", "fn-a", base)
        lib.write_text("pub mod a;\n\nfn shared() {}\nfn a() {\n    1\n}\n")
        self.commit_all("fn a")
        self.git("checkout", "--quiet", "-b", "fn-b", base)
        lib.write_text("pub mod a;\n\nfn shared() {}\nfn b() {\n    2\n}\n")
        self.commit_all("fn b")
        merged = self.git("merge", "--no-edit", "fn-a", check=False)
        self.assertEqual(merged.returncode, 0, merged.stdout + merged.stderr)
        self.assertEqual(lib.read_text(), "pub mod a;\n\nfn shared() {}\nfn b() {\n    2\n}\nfn a() {\n    1\n}\n")

        # A line of the file that looks like a conflict marker is content, never a hunk.
        self.git("checkout", "--quiet", "-b", "marker-base", base)
        log.write_text("# Log\n\nTitle\n=======\n<<<<<<< see docs\n- first\n")
        self.commit_all("marker base")
        marker_base = self.git("rev-parse", "HEAD").stdout.strip()
        log.write_text("# Log\n\nTitle\n=======\n<<<<<<< see docs\n- first\n- x\n")
        self.commit_all("marker x")
        self.git("checkout", "--quiet", "-b", "marker-y", marker_base)
        log.write_text("# Log\n\nTitle\n=======\n<<<<<<< see docs\n- first\n- y\n")
        self.commit_all("marker y")
        merged = self.git("merge", "--no-edit", "marker-base", check=False)
        self.assertEqual(merged.returncode, 0, merged.stdout + merged.stderr)
        self.assertEqual(log.read_text(), "# Log\n\nTitle\n=======\n<<<<<<< see docs\n- first\n- y\n- x\n")

        # An inserted line as long as the driver's own markers is content too.
        long_line = ">" * 51 + " documentation\n"
        self.git("checkout", "--quiet", "-b", "long-x", base)
        log.write_text("# Log\n\n- first\n" + long_line)
        self.commit_all("long x")
        self.git("checkout", "--quiet", "-b", "long-y", base)
        log.write_text("# Log\n\n- first\n- y\n")
        self.commit_all("long y")
        merged = self.git("merge", "--no-edit", "long-x", check=False)
        self.assertEqual(merged.returncode, 0, merged.stdout + merged.stderr)
        self.assertEqual(log.read_text(), "# Log\n\n- first\n- y\n" + long_line)

        # One function both sides added with different bodies is one change made twice: kept
        # both, the file would define it twice, so it stays a conflict.
        self.git("checkout", "--quiet", "-b", "twice-a", base)
        lib.write_text("pub mod a;\n\nfn shared() {}\nfn helper(value: u32) -> u32 {\n    let doubled = value * 2;\n    doubled + 1\n}\n")
        self.commit_all("twice a")
        self.git("checkout", "--quiet", "-b", "twice-b", base)
        lib.write_text("pub mod a;\n\nfn shared() {}\nfn helper(value: u32) -> u32 {\n    let doubled = value * 2;\n    doubled + 2\n}\n")
        self.commit_all("twice b")
        clash = self.git("merge", "--no-edit", "twice-a", check=False)
        self.assertNotEqual(clash.returncode, 0)
        self.assertEqual(lib.read_text().count("let doubled"), 2, lib.read_text())
        self.assertIn("<<<<<<<", lib.read_text())
        self.git("merge", "--abort")

        # A file both branches created is two versions of one file, never two insertions.
        self.git("checkout", "--quiet", "-b", "new-a", base)
        (lib.parent / "fresh.rs").write_text("fn fresh() {\n    one();\n}\n")
        self.commit_all("new a")
        self.git("checkout", "--quiet", "-b", "new-b", base)
        (lib.parent / "fresh.rs").write_text("fn fresh() {\n    two();\n}\n")
        self.commit_all("new b")
        clash = self.git("merge", "--no-edit", "new-a", check=False)
        self.assertNotEqual(clash.returncode, 0)
        self.assertIn("<<<<<<<", (lib.parent / "fresh.rs").read_text())
        self.git("merge", "--abort")

        # TOML: a key one side appends to the last table stays in that table when the other
        # side appends a new table; keys and tables on both sides stay a conflict.
        toml = self.repo / "tests/test-execution.d/demo.toml"
        toml.parent.mkdir(parents=True, exist_ok=True)
        self.git("checkout", "--quiet", "-b", "toml-base", base)
        toml.write_text('[[test]]\npath = "a"\n')
        self.commit_all("toml base")
        toml_base = self.git("rev-parse", "HEAD").stdout.strip()
        toml.write_text('[[test]]\npath = "a"\n\n[[test]]\npath = "b"\n')
        self.commit_all("toml table")
        self.git("checkout", "--quiet", "-b", "toml-key", toml_base)
        toml.write_text('[[test]]\npath = "a"\nserial = true\n')
        self.commit_all("toml key")
        merged = self.git("merge", "--no-edit", "toml-base", check=False)
        self.assertEqual(merged.returncode, 0, merged.stdout + merged.stderr)
        self.assertEqual(toml.read_text(), '[[test]]\npath = "a"\nserial = true\n\n[[test]]\npath = "b"\n')
        self.git("checkout", "--quiet", "-b", "toml-both", toml_base)
        toml.write_text('[[test]]\npath = "a"\nx = 1\n[[test]]\npath = "c"\n')
        self.commit_all("toml both")
        clash = self.git("merge", "--no-edit", "toml-key", check=False)
        self.assertNotEqual(clash.returncode, 0)
        self.git("merge", "--abort")

        # The same line changed two ways is still the author's conflict.
        self.git("checkout", "--quiet", "-b", "other", base)
        lib.write_text("pub mod a;\n\nfn shared() { other() }\n")
        self.commit_all("other")
        self.git("checkout", "--quiet", "-b", "another", base)
        lib.write_text("pub mod a;\n\nfn shared() { another() }\n")
        self.commit_all("another")
        clash = self.git("merge", "--no-edit", "other", check=False)
        self.assertNotEqual(clash.returncode, 0)
        self.assertIn("<<<<<<<", lib.read_text())
        self.git("merge", "--abort")

        # Both sides inserting after the last key leaves JSON without a comma: a conflict, never a broken file.
        self.git("checkout", "--quiet", "-b", "json-a", base)
        surfaces.write_text('{\n "a": 1\n}\n "b": 2\n')
        self.commit_all("json a")
        self.git("checkout", "--quiet", "-b", "json-b", base)
        surfaces.write_text('{\n "a": 1\n}\n "c": 3\n')
        self.commit_all("json b")
        clash = self.git("merge", "--no-edit", "json-a", check=False)
        self.assertNotEqual(clash.returncode, 0)
        self.assertIn("<<<<<<<", surfaces.read_text())
        self.git("merge", "--abort")

        # Both sides adding the same key parses, but one value would silently win: a conflict.
        self.git("checkout", "--quiet", "-b", "key-a", base)
        surfaces.write_text('{\n "new": 1,\n "a": 1\n}\n')
        self.commit_all("key a")
        self.git("checkout", "--quiet", "-b", "key-b", base)
        surfaces.write_text('{\n "new": 2,\n "a": 1\n}\n')
        self.commit_all("key b")
        clash = self.git("merge", "--no-edit", "key-a", check=False)
        self.assertNotEqual(clash.returncode, 0)
        self.assertIn("<<<<<<<", surfaces.read_text())
        self.git("merge", "--abort")

        # The same key added in two places merges clean line by line, yet one value would win.
        self.git("checkout", "--quiet", "-b", "spread-base", base)
        surfaces.write_text('{\n "a": 1,\n "m": 0,\n "z": 2\n}\n')
        self.commit_all("spread base")
        spread_base = self.git("rev-parse", "HEAD").stdout.strip()
        surfaces.write_text('{\n "new": 1,\n "a": 1,\n "m": 0,\n "z": 2\n}\n')
        self.commit_all("spread top")
        self.git("checkout", "--quiet", "-b", "spread-bottom", spread_base)
        surfaces.write_text('{\n "a": 1,\n "m": 0,\n "z": 2,\n "new": 2\n}\n')
        self.commit_all("spread bottom")
        clash = self.git("merge", "--no-edit", "spread-base", check=False)
        self.assertNotEqual(clash.returncode, 0, clash.stdout + clash.stderr)
        self.git("merge", "--abort")

        # A clean merge of a file one side already broke is still not a valid result.
        self.git("checkout", "--quiet", "-b", "broken-base", base)
        surfaces.write_text('{\n "a": 1,\n "b": 2,\n "c": 3,\n "d": 4,\n "e": 5\n}\n')
        self.commit_all("broken base")
        broken_base = self.git("rev-parse", "HEAD").stdout.strip()
        surfaces.write_text('{\n "a": 9,\n "b": 2,\n "c": 3,\n "d": 4,\n "e": 5\n}\n')
        self.commit_all("fine")
        self.git("checkout", "--quiet", "-b", "broken-ours", broken_base)
        surfaces.write_text('{\n "a": 1,\n "b": 2,\n "c": 3,\n "d": 4\n "e": 5\n}\n')
        self.commit_all("broken ours")
        clash = self.git("merge", "--no-edit", "broken-base", check=False)
        self.assertNotEqual(clash.returncode, 0, clash.stdout + clash.stderr)
        self.git("merge", "--abort")

    def test_typescript_imports_merge_per_name(self):
        """Two branches that each import a new name from one module change that module's one
        import line; the merge keeps both names. A name either side dropped stays dropped, and
        a line both sides changed below the imports is still the author's conflict."""
        shutil.copyfile(SOURCE / ".gitattributes", self.repo / ".gitattributes")
        self.git("config", "user.name", "t")
        self.git("config", "user.email", "t@example.com")
        self.assertEqual(self.install().returncode, 0)
        app = self.repo / "webviews/src/demo/App.tsx"
        app.parent.mkdir(parents=True, exist_ok=True)
        head = 'import React, { useMemo, useState } from "react";\nimport { a, b } from "./ab";\n'
        body = "\nexport function App() {\n  return null;\n}\n"
        app.write_text(head + 'import { old } from "./old";\n' + body)
        self.commit_all("base")
        base = self.git("rev-parse", "HEAD").stdout.strip()

        def branch(name, text):
            self.git("checkout", "--quiet", "-b", name, base)
            app.write_text(text)
            self.commit_all(name)

        # Same line, a name each; a new statement on one side; a name one side dropped.
        branch("lane", 'import React, { useMemo, useRef, useState } from "react";\nimport { a, b, c } from "./ab";\n'
                       'import { old } from "./old";\nimport { lane } from "./lane";\n' + body)
        branch("trunk", 'import React, { useEffect, useMemo, useState } from "react";\nimport { a } from "./ab";\n'
                       'import { old, other } from "./old";\n' + body)
        merged = self.git("merge", "--no-edit", "lane", check=False)
        self.assertEqual(merged.returncode, 0, merged.stdout + merged.stderr)
        self.assertEqual(app.read_text(), 'import React, { useEffect, useMemo, useState, useRef } from "react";\n'
                                          'import { a, c } from "./ab";\nimport { old, other } from "./old";\n'
                                          'import { lane } from "./lane";\n' + body)

        # A statement one side removed whole, while the other left it as it was, goes.
        branch("drop", head + body)
        branch("keep", head + 'import { old } from "./old";\nimport { keep } from "./keep";\n' + body)
        merged = self.git("merge", "--no-edit", "drop", check=False)
        self.assertEqual(merged.returncode, 0, merged.stdout + merged.stderr)
        self.assertEqual(app.read_text(), head + 'import { keep } from "./keep";\n' + body)

        # A line past the print width breaks one name per line, as the formatter writes it.
        long_names = [f"someLongExportedName{index}" for index in range(6)]
        branch("long-a", head.replace("a, b }", "a, b, " + ", ".join(long_names[:3]) + " }") + 'import { old } from "./old";\n' + body)
        branch("long-b", head.replace("a, b }", "a, b, " + ", ".join(long_names[3:]) + " }") + 'import { old } from "./old";\n' + body)
        merged = self.git("merge", "--no-edit", "long-a", check=False)
        self.assertEqual(merged.returncode, 0, merged.stdout + merged.stderr)
        names = ["a", "b", *long_names[3:], *long_names[:3]]
        self.assertIn("import {\n" + "".join(f"  {name},\n" for name in names) + '} from "./ab";\n', app.read_text())

        # Both sides changing the default import, or one statement's lines with a comment in
        # them, leave the file to the line merge: still a conflict.
        branch("default-a", head.replace("import React,", "import ReactA,") + 'import { old } from "./old";\n' + body)
        branch("default-b", head.replace("import React,", "import ReactB,") + 'import { old } from "./old";\n' + body)
        clash = self.git("merge", "--no-edit", "default-a", check=False)
        self.assertNotEqual(clash.returncode, 0)
        self.assertIn("<<<<<<<", app.read_text())
        self.git("merge", "--abort")
        branch("comment-a", head.replace("{ a, b }", "{ a, b /* why */, x }") + 'import { old } from "./old";\n' + body)
        branch("comment-b", head.replace("{ a, b }", "{ a, b, y }") + 'import { old } from "./old";\n' + body)
        clash = self.git("merge", "--no-edit", "comment-a", check=False)
        self.assertNotEqual(clash.returncode, 0)
        self.git("merge", "--abort")

        # The order is merged too: side-effect imports run in it, so theirs moving one wins
        # over ours leaving it, and a namespace one side renamed is the new name.
        effects = 'import "./reset.css";\nimport "./polyfill";\nimport * as A from "./a";\n'
        branch("effects-base", effects + body)
        effects_base = self.git("rev-parse", "HEAD").stdout.strip()
        app.write_text('import "./polyfill";\nimport "./reset.css";\nimport * as B from "./a";\n' + body)
        self.commit_all("reorder and rename")
        self.git("checkout", "--quiet", "-b", "effects-ours", effects_base)
        app.write_text(effects + 'import { q } from "./q";\n' + body)
        self.commit_all("add q")
        merged = self.git("merge", "--no-edit", "effects-base", check=False)
        self.assertEqual(merged.returncode, 0, merged.stdout + merged.stderr)
        self.assertEqual(app.read_text(), 'import "./polyfill";\nimport "./reset.css";\nimport * as B from "./a";\n'
                                          'import { q } from "./q";\n' + body)

        # Left to the line merge, and so still conflicts: a name added as a value on one side and
        # a type on the other (declared twice), a statement one side changed and the other
        # deleted, a line that is not an import put among them (a directive), and CRLF files.
        for name, ours_text, theirs_text in (
            ("value-type", head.replace("a, b", "a, b, C"), head.replace("a, b", "a, b, type C")),
            ("change-delete", head.replace("a, b", "a, b, c"), head.replace('import { a, b } from "./ab";\n', "")),
            ("directive", head.replace("a, b", "a, b, c"), '"use client";\n' + head.replace("a, b", "a, b, d")),
        ):
            branch(name + "-a", ours_text + 'import { old } from "./old";\n' + body)
            branch(name + "-b", theirs_text + 'import { old } from "./old";\n' + body)
            clash = self.git("merge", "--no-edit", name + "-a", check=False)
            self.assertNotEqual(clash.returncode, 0, name)
            self.git("merge", "--abort")
        crlf = lambda text: text.replace("\n", "\r\n").encode()
        self.git("checkout", "--quiet", "-b", "crlf-base", base)
        app.write_bytes(crlf(head + body))
        self.commit_all("crlf base")
        crlf_base = self.git("rev-parse", "HEAD").stdout.strip()
        app.write_bytes(crlf(head.replace("a, b", "a, b, c") + body))
        self.commit_all("crlf c")
        self.git("checkout", "--quiet", "-b", "crlf-d", crlf_base)
        app.write_bytes(crlf(head.replace("a, b", "a, b, d") + body))
        self.commit_all("crlf d")
        clash = self.git("merge", "--no-edit", "crlf-base", check=False)
        self.assertNotEqual(clash.returncode, 0)
        self.git("merge", "--abort")

        # The imports merge and a line both sides changed in the body stays a conflict.
        branch("body-a", head.replace("a, b", "a, b, x") + 'import { old } from "./old";\n' + body.replace("null", "1"))
        branch("body-b", head.replace("a, b", "a, b, y") + 'import { old } from "./old";\n' + body.replace("null", "2"))
        clash = self.git("merge", "--no-edit", "body-a", check=False)
        self.assertNotEqual(clash.returncode, 0)
        self.assertTrue(app.read_text().startswith('import React, { useMemo, useState } from "react";\nimport { a, b, y, x } from "./ab";\n'),
                        app.read_text())
        self.assertIn("<<<<<<<", app.read_text())
        self.git("merge", "--abort")

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
        self.assert_trusted_post_merge_reinstalls("main")

    def test_trusted_feat_cmux_next_post_merge_reinstalls_its_hooks(self):
        # Direct pushes land on feat-cmux-next, whose pre-commit formats more
        # than main's; pulling it must install that copy, not keep an old one.
        self.assert_trusted_post_merge_reinstalls("feat-cmux-next")

    def test_post_merge_keeps_legacy_masker_trust_without_copy_manifest(self):
        """An older trusted branch may have no checks-copy-inputs, but its installer still copies the masker.
        A dirty masker must stop the auto-install before the legacy trust path is dropped."""
        hook = self.repo / "scripts/git-hooks/post-merge"
        manifest = self.repo / "scripts/git-hooks/checks-copy-inputs"
        manifest.unlink()
        marker = self.root / "installer-ran"
        installer = self.repo / INSTALLER
        installer.write_text(f"#!/bin/sh\ntouch {shlex.quote(str(marker))}\n", encoding="utf-8")
        installer.chmod(0o755)
        self.git("add", "-A")
        self.git("-c", "user.name=Merge Test", "-c", "user.email=merge@example.invalid", "commit", "-qm",
                 "legacy trusted branch")
        trusted = self.git("rev-parse", "HEAD").stdout.strip()
        self.git("remote", "add", "upstream", self.CANONICAL)
        self.git("update-ref", "refs/remotes/upstream/main", trusted)
        masker = self.repo / "scripts/swift_source_mask.py"
        masker.write_bytes(masker.read_bytes() + b"\n# dirty candidate\n")

        result = subprocess.run(["/bin/bash", str(hook)], cwd=self.repo, env=self.env, text=True, capture_output=True)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(marker.exists(), "post-merge ran the installer over a dirty legacy masker")
        self.assertIn("differ from trusted main", result.stderr)

    def assert_trusted_post_merge_reinstalls(self, branch):
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
        self.git("update-ref", f"refs/remotes/upstream/{branch}", trusted_main)
        self.git("switch", "-q", "main")
        self.git("config", "core.hooksPath", "scripts/git-hooks")
        self.git("config", "merge.xcstrings.driver", "python3 scripts/merge-xcstrings.py %O %A %B %P")
        self.git("config", "merge.pbxproj.driver", "python3 scripts/merge-pbxproj.py %O %A %B %P")

        result = self.git("merge", "--ff-only", f"upstream/{branch}", check=False)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.git("rev-parse", "HEAD").stdout.strip(), trusted_main)
        self.assertTrue(os.access(hook, os.X_OK), "Git ignores non-executable hooks")
        self.assert_trusted_hooks_installed()
        self.assert_merge_driver_installed()

    # An agent's push gate runs the clone's installed checks copy. post-merge refreshes it only when a checkout is
    # fast-forwarded to exactly feat-cmux-next; agents fetch and rebase in worktrees, so their copy stayed at the
    # last pull (2026-10-28: the per-symbol compile trailer rule landed and no agent ran it). pre-push refreshes the
    # copy from the fetched feat-cmux-next before a push to it.
    CANONICAL = "https://github.com/manaflow-ai/cmux.git"

    def commit_all(self, message):
        self.git("add", "-A")
        self.git("-c", "user.name=T", "-c", "user.email=t@example.invalid", "commit", "-qm", message)
        return self.git("rev-parse", "HEAD").stdout.strip()

    def installed_checks(self):
        return self.common_dir() / "cmux-git-hooks" / "cmux-next-checks"

    def refresh(self, remote_ref="refs/heads/feat-cmux-next", url=None):
        hook_dir = self.common_dir() / "cmux-git-hooks"
        head = self.git("rev-parse", "HEAD").stdout.strip()
        python3 = (hook_dir / "python3-path").read_text(encoding="utf-8").strip()
        return subprocess.run([python3, "-I", str(hook_dir / "refresh_checks.py"), "--hook-dir", str(hook_dir),
                               "--repo", str(self.repo), "--remote-url", url or self.CANONICAL],
                              input=f"refs/heads/topic {head} {remote_ref} {'0' * 40}\n", cwd=self.repo, env=self.env,
                              text=True, capture_output=True)

    def stale_install(self):
        """Install at an old feat-cmux-next, then move the fetched feat-cmux-next to a newer gate rule."""
        rule = self.repo / "scripts/cmux-next/compile_trailer.py"
        rule.write_text("RULE = 'old'\n")
        self.git("remote", "add", "origin", self.CANONICAL)
        old = self.commit_all("old rule")
        self.git("update-ref", "refs/remotes/origin/feat-cmux-next", old)
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.installed_checks() / "compile_trailer.py").read_text(), "RULE = 'old'\n")
        rule.write_text("RULE = 'new'\n")
        new = self.commit_all("new rule")
        self.git("update-ref", "refs/remotes/origin/feat-cmux-next", new)
        rule.write_text("RULE = 'from the working tree'\n")
        return old, new

    # 2026-11-10: about nine agents' pre-push hooks ran at once on one Mac (load average 300-770); every gate ran
    # past its limit and no push finished. The hook now takes a turn: CMUX_PREPUSH_SLOTS at once on the Mac.
    def queued_hooks(self, count, **settings):
        """Run COUNT installed pre-push hooks at once, each with a web lint that takes 0.5 s and writes when it
        started and ended; returns the (start, end) pairs in start order and the hooks' output."""
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        hook_dir = self.common_dir() / "cmux-git-hooks"
        log = self.root / "lint-times"
        (hook_dir / "web_lint_prepush.py").write_text(
            "import os, time\n"
            f"log = {str(log)!r}\n"
            "started = time.time()\n"
            "time.sleep(0.5)\n"
            "with open(log, 'a') as out:\n"
            "    out.write(f'{started} {time.time()}\\n')\n")
        (hook_dir / "cmux_next_prepush_gate.py").write_text("")
        (self.repo / "file").write_text("x\n")
        head = self.commit_all("a commit to push")
        queue = self.root / "queue"
        queue.mkdir()
        # Every hook pushes the same head: the pass cache would answer all but the first, and this is about the queue.
        env = dict(self.env, CMUX_PREPUSH_QUEUE_DIR=str(queue), CMUX_PREPUSH_PASS_CACHE="0", **settings)
        logs = [open(self.root / f"hook-{index}.log", "w+") for index in range(count)]
        for handle in logs:
            self.addCleanup(handle.close)
        # Output goes to files: the hooks are read one after another, and a full pipe would block one.
        hooks = [subprocess.Popen([str(hook_dir / "pre-push"), "origin", "https://example.invalid/x.git"],
                                  stdin=subprocess.PIPE, stdout=logs[index], stderr=subprocess.STDOUT, text=True,
                                  cwd=self.repo, env=env) for index in range(count)]
        for hook in hooks:
            hook.stdin.write(f"refs/heads/topic {head} refs/heads/topic {'0' * 40}\n")
            hook.stdin.close()
        output = []
        for hook, handle in zip(hooks, logs):
            code = hook.wait(timeout=120)
            handle.seek(0)
            output.append(handle.read())
            self.assertEqual(code, 0, output[-1])
        times = sorted(tuple(float(part) for part in line.split()) for line in log.read_text().splitlines())
        self.assertEqual(len(times), count)
        return times, output

    def test_pre_push_hooks_on_one_mac_check_one_after_another(self):
        times, output = self.queued_hooks(3, CMUX_PREPUSH_SLOTS="1")
        for (_, ended), (started, _) in zip(times, times[1:]):
            self.assertLessEqual(ended, started, f"two hooks checked at once: {times}")
        self.assertTrue(any("waiting for a turn" in text for text in output), output)
        self.assertTrue(all("hook times: queue " in text for text in output), output)

    def test_pre_push_queue_never_refuses_a_push_it_cannot_seat(self):
        # Past the wait budget the hook checks anyway: a stuck holder must not stop every push on the Mac.
        times, output = self.queued_hooks(2, CMUX_PREPUSH_SLOTS="1", CMUX_PREPUSH_QUEUE_WAIT_SECONDS="0")
        self.assertEqual(len(times), 2)
        self.assertTrue(all("pre-push: passed" in text for text in output), output)

    # 2026-11-22: 181 of 511 pushes on cosmic-gray in six hours repeated a sha already tried, each judged from scratch.
    def stub_checks(self, gate_exit=0):
        """Install, then replace the web lint and the gate with stubs that log their argv; returns (hook, log, head)."""
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        hook_dir = self.common_dir() / "cmux-git-hooks"
        log = self.root / "checks-run"
        for name, code in (("web_lint_prepush.py", 0), ("cmux_next_prepush_gate.py", gate_exit)):
            (hook_dir / name).write_text(
                "import sys\n"
                f"open({str(log)!r}, 'a').write({name!r} + ' ' + ' '.join(sys.argv[1:]) + '\\n')\n"
                f"sys.exit({code})\n")
        (self.repo / "file").write_text("x\n")
        return hook_dir / "pre-push", log, self.commit_all("a commit to push")

    def push_hook(self, hook, head, **settings):
        env = dict(self.env, CMUX_PREPUSH_QUEUE_DIR=str(self.root), **settings)
        return subprocess.run([str(hook), "origin", "https://example.invalid/x.git"], cwd=self.repo, env=env, text=True,
                              input=f"refs/heads/topic {head} refs/heads/topic {'0' * 40}\n", capture_output=True,
                              timeout=120)

    def runs(self, log):
        return log.read_text().splitlines() if log.exists() else []

    def test_pre_push_judges_the_same_push_once(self):
        hook, log, head = self.stub_checks()
        first = self.push_hook(hook, head)
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(len(self.runs(log)), 2, first.stderr)
        again = self.push_hook(hook, head)
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertEqual(len(self.runs(log)), 2, "a retry of a judged push ran the checks again")
        self.assertIn("not judged again", again.stderr)
        self.assertIn("pass-cache", again.stderr)
        self.assertNotIn("waiting for a turn", again.stderr)
        # Another head, a changed skip setting, or the cache off: judged.
        (self.repo / "file").write_text("y\n")
        other = self.commit_all("another commit")
        self.assertEqual(self.push_hook(hook, other).returncode, 0)
        self.assertEqual(len(self.runs(log)), 4)
        self.assertEqual(self.push_hook(hook, head, CMUX_NEXT_CHECKS_SKIP_REASON="x fails on base").returncode, 0)
        self.assertEqual(len(self.runs(log)), 6)
        self.assertEqual(self.push_hook(hook, head, CMUX_PREPUSH_PASS_CACHE="0").returncode, 0)
        self.assertEqual(len(self.runs(log)), 8)

    def test_pre_push_records_no_refused_push(self):
        hook, log, head = self.stub_checks(gate_exit=1)
        self.assertEqual(self.push_hook(hook, head).returncode, 1)
        self.assertEqual(self.push_hook(hook, head).returncode, 1)
        self.assertEqual(len(self.runs(log)), 4, "a refused push must be judged again")
        self.assertFalse(list((self.common_dir() / "cmux-prepush-pass").glob("*")) if
                         (self.common_dir() / "cmux-prepush-pass").exists() else [])

    def test_pre_push_judges_again_after_the_checks_copy_changes(self):
        hook, log, head = self.stub_checks()
        self.assertEqual(self.push_hook(hook, head).returncode, 0)
        (hook.parent / "cmux_next_prepush_gate.py").write_text(
            (hook.parent / "cmux_next_prepush_gate.py").read_text() + "# a new gate\n")
        self.assertEqual(self.push_hook(hook, head).returncode, 0)
        self.assertEqual(len(self.runs(log)), 4, "a new gate must judge the push again")

    def test_a_loaded_host_leaves_the_ci_layers_to_ci_and_its_pass_answers_only_a_loaded_run(self):
        hook, log, head = self.stub_checks()
        loaded = self.push_hook(hook, head, CMUX_PREPUSH_LOAD_FOR_TEST="100000")
        self.assertEqual(loaded.returncode, 0, loaded.stderr)
        gate_runs = [line for line in self.runs(log) if line.startswith("cmux_next_prepush_gate.py")]
        self.assertEqual(len(gate_runs), 1)
        self.assertIn("--defer-ci-layers", gate_runs[0])
        self.assertEqual(self.push_hook(hook, head, CMUX_PREPUSH_LOAD_FOR_TEST="100000").returncode, 0)
        self.assertEqual(len(self.runs(log)), 2, "a loaded retry of a loaded pass ran the checks again")
        idle = self.push_hook(hook, head, CMUX_PREPUSH_LOAD_FOR_TEST="0")
        self.assertEqual(idle.returncode, 0, idle.stderr)
        gate_runs = [line for line in self.runs(log) if line.startswith("cmux_next_prepush_gate.py")]
        self.assertEqual(len(gate_runs), 2, "an idle run must run the layers the loaded pass left to CI")
        self.assertNotIn("--defer-ci-layers", gate_runs[1])
        # The idle run's full pass answers a loaded run too.
        self.assertEqual(self.push_hook(hook, head, CMUX_PREPUSH_LOAD_FOR_TEST="100000").returncode, 0)
        self.assertEqual(len(self.runs(log)), 4)

    def test_pre_push_refreshes_a_stale_checks_copy_from_the_fetched_feat_cmux_next(self):
        _old, new = self.stale_install()
        result = self.refresh()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.installed_checks() / "compile_trailer.py").read_text(), "RULE = 'new'\n")
        self.assertIn(new[:12], result.stdout + result.stderr)
        gate = self.common_dir() / "cmux-git-hooks" / "cmux_next_prepush_gate.py"
        self.assertEqual(gate.read_bytes(), (SOURCE / "scripts/cmux-next/prepush-gate.py").read_bytes())
        again = self.refresh()  # current: nothing to do
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertEqual(again.stdout + again.stderr, "")
        hook = (SOURCE / "scripts/git-hooks/pre-push").read_text()
        self.assertLess(hook.index("refresh_checks.py"), hook.index("cmux_next_prepush_gate.py"),
                        "pre-push refreshes the checks before it runs them")

    def test_installed_and_refreshed_checks_carry_the_swift_source_masker(self):
        # Review of #28365: check-package-dependency-lists.py imports scripts/swift_source_mask.py, and the hook runs
        # its copy from the checks folder, so both the install and a refresh put the masker beside it.
        masker = self.repo / "scripts/swift_source_mask.py"
        if not masker.is_file():
            masker.parent.mkdir(parents=True, exist_ok=True)
            masker.write_bytes((SOURCE / "scripts/swift_source_mask.py").read_bytes())
        self.stale_install()
        self.assertTrue((self.installed_checks() / "swift_source_mask.py").is_file(), "the install has no masker")
        result = self.refresh()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.installed_checks() / "swift_source_mask.py").read_bytes(),
                         (SOURCE / "scripts/swift_source_mask.py").read_bytes(), "the refreshed copy has no masker")

    def test_installed_and_refreshed_checks_carry_the_shared_workflow_resolver(self):
        # check-single-host-fallbacks.py reads runs-on through tests/workflow_jobs.py, and the hook runs its copy from
        # the checks folder (it never reads the pushed one), so both the install and a refresh put it beside it.
        resolver = self.repo / "tests/workflow_jobs.py"
        if not resolver.is_file():
            resolver.parent.mkdir(parents=True, exist_ok=True)
            resolver.write_bytes((SOURCE / "tests/workflow_jobs.py").read_bytes())
        self.stale_install()
        self.assertTrue((self.installed_checks() / "workflow_jobs.py").is_file(), "the install has no resolver")
        result = self.refresh()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.installed_checks() / "workflow_jobs.py").read_bytes(),
                         (SOURCE / "tests/workflow_jobs.py").read_bytes(), "the refreshed copy has no resolver")

    COPY_INPUTS = "scripts/git-hooks/checks-copy-inputs"

    def copy_sources(self):
        """The source of every entry of the copy's input list (`source -> destination` names its source first)."""
        lines = (self.repo / self.COPY_INPUTS).read_text(encoding="utf-8").splitlines()
        return [line.strip().split(" -> ")[0].strip() for line in lines
                if line.strip() and not line.strip().startswith("#")]

    def installed_pairs(self):
        """The (source, destination) pairs the install or refresh says it copied (the copy's .pairs)."""
        rows = (self.installed_checks() / ".pairs").read_text(encoding="utf-8").splitlines()
        return [tuple(row.split("\t")) for row in rows if row]

    def test_a_change_to_the_resolver_alone_marks_the_install_stale(self):
        # Codex on #40894: the install copies tests/workflow_jobs.py beside the checks, but the stamp covered only
        # scripts/cmux-next, so a feat-cmux-next that changed the resolver alone never reached the installed hooks.
        resolver = self.repo / "tests/workflow_jobs.py"
        resolver.parent.mkdir(parents=True, exist_ok=True)
        resolver.write_bytes((SOURCE / "tests/workflow_jobs.py").read_bytes())
        self.stale_install()
        self.git("checkout", "-q", "--", ".")
        self.assertEqual(self.refresh().returncode, 0)  # current at the newer rule
        resolver.write_bytes(resolver.read_bytes() + b"\n# a resolver-only change\n")
        newer = self.commit_all("resolver only")
        self.git("update-ref", "refs/remotes/origin/feat-cmux-next", newer)
        result = self.refresh()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.installed_checks() / "workflow_jobs.py").read_bytes(), resolver.read_bytes(),
                         "a resolver-only change on feat-cmux-next did not reach the installed checks")
        self.assertIn(newer[:12], result.stdout + result.stderr)

    def test_every_file_the_install_copies_is_in_the_stamp_input(self):
        # The install copies exactly the (source, destination) pairs refresh_checks.py makes of
        # scripts/git-hooks/checks-copy-inputs, records them (.pairs) and stamps the copy from them, and a refresh does
        # the same at its commit; post-merge trusts a checkout only when no source differs. A source installed under
        # another name (`source -> destination`) is one pair like any other.
        resolver = self.repo / "tests/workflow_jobs.py"
        resolver.parent.mkdir(parents=True, exist_ok=True)
        resolver.write_bytes((SOURCE / "tests/workflow_jobs.py").read_bytes())
        inputs = self.repo / self.COPY_INPUTS
        inputs.write_text(inputs.read_text(encoding="utf-8")
                          + "scripts/ci/base_merge_warning.py -> renamed_merge_warning.py\n", encoding="utf-8")
        self.git("remote", "add", "origin", self.CANONICAL)
        head = self.commit_all("trusted")
        self.git("update-ref", "refs/remotes/origin/feat-cmux-next", head)
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        copy = self.installed_checks()
        pairs = self.installed_pairs()
        self.assertIn(("scripts/ci/base_merge_warning.py", "renamed_merge_warning.py"), pairs)
        self.assertIn(("tests/workflow_jobs.py", "workflow_jobs.py"), pairs)
        installed = sorted(path.relative_to(copy).as_posix() for path in copy.rglob("*")
                           if path.is_file() and path.name not in (".in-use", ".source", ".pairs"))
        self.assertEqual(installed, sorted(destination for _, destination in pairs),
                         "the install copied a file its pairs (the stamp's input) do not name, or the reverse")
        for source, destination in pairs:
            self.assertEqual((copy / destination).read_bytes(), (self.repo / source).read_bytes(), destination)
        # The stamp is the one refresh_checks.py derives from the same pairs at the same commit.
        python3 = (self.common_dir() / "cmux-git-hooks" / "python3-path").read_text(encoding="utf-8").strip()
        derived = subprocess.run([python3, "-I", "scripts/git-hooks/refresh_checks.py", "--repo", str(self.repo),
                                  "--stamp", head], cwd=self.repo, env=self.env, text=True, capture_output=True)
        self.assertEqual(derived.returncode, 0, derived.stderr)
        self.assertEqual((copy / ".source").read_text().split(), derived.stdout.split())
        self.assertEqual(derived.stdout.split()[0], head)
        self.assertEqual(self.refresh().stdout + self.refresh().stderr, "", "a current install was refreshed")
        # A change to the renamed source alone marks the install stale and reaches its destination.
        warning = self.repo / "scripts/ci/base_merge_warning.py"
        warning.write_bytes(warning.read_bytes() + b"\n# renamed source only\n")
        newer = self.commit_all("renamed source only")
        self.git("update-ref", "refs/remotes/origin/feat-cmux-next", newer)
        refreshed = self.refresh()
        self.assertEqual(refreshed.returncode, 0, refreshed.stderr)
        self.assertIn(newer[:12], refreshed.stdout + refreshed.stderr)
        self.assertEqual((copy / "renamed_merge_warning.py").read_bytes(), warning.read_bytes())
        self.assertEqual(self.installed_pairs(), pairs, "a refresh copied other pairs than the install")
        # Each source a stamp reads is an input post-merge refuses to trust when it differs from the trusted branch.
        self.git("update-ref", "refs/remotes/origin/main", newer)
        for entry in [self.COPY_INPUTS, *self.copy_sources()]:
            path = self.repo / (entry + "prepush-gate.py" if entry.endswith("/") else entry)
            reviewed = path.read_bytes()
            try:
                path.write_bytes(reviewed + b"\n# dirty candidate\n")
                hook = subprocess.run(["/bin/bash", "scripts/git-hooks/post-merge"], cwd=self.repo, env=self.env,
                                      text=True, capture_output=True)
                self.assertEqual(hook.returncode, 0, hook.stderr)
                self.assertIn("differ from trusted main", hook.stderr, entry)
            finally:
                path.write_bytes(reviewed)

    def test_a_refresh_puts_the_release_download_fallback_beside_the_gate(self):
        # #38454 review: the gate loads scripts/ci/github_release_download.py from beside itself, so a refresh that
        # rewrites the gate rewrites the helper from the same feat-cmux-next.
        hook_dir = self.common_dir() / "cmux-git-hooks"
        self.stale_install()
        (hook_dir / "github_release_download.py").unlink()  # an install from before the helper
        helper = self.repo / "scripts/ci/github_release_download.py"
        helper.write_text(helper.read_text() + "# newer\n")
        self.commit_all("newer helper")
        self.git("update-ref", "refs/remotes/origin/feat-cmux-next", self.git("rev-parse", "HEAD").stdout.strip())
        result = self.refresh()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((hook_dir / "github_release_download.py").read_bytes(), helper.read_bytes())

    def test_refresh_leaves_other_pushes_and_lookalike_remotes_alone(self):
        self.stale_install()
        for result in (self.refresh(remote_ref="refs/heads/topic"),
                       self.refresh(url="https://attacker.invalid/github.com/manaflow-ai/cmux")):
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((self.installed_checks() / "compile_trailer.py").read_text(), "RULE = 'old'\n")
        self.git("remote", "set-url", "origin", "https://attacker.invalid/github.com/manaflow-ai/cmux")
        result = self.refresh()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.installed_checks() / "compile_trailer.py").read_text(), "RULE = 'old'\n")

    def test_refresh_never_goes_back_to_an_older_feat_cmux_next(self):
        old, new = self.stale_install()
        self.git("checkout", "-q", "--", ".")
        self.git("update-ref", "refs/remotes/origin/feat-cmux-next", new)
        self.assertEqual(self.refresh().returncode, 0)
        self.git("update-ref", "refs/remotes/origin/feat-cmux-next", old)
        result = self.refresh()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.installed_checks() / "compile_trailer.py").read_text(), "RULE = 'new'\n")

    def test_refresh_replaces_a_copy_installed_from_a_commit_feat_cmux_next_never_got(self):
        # setup.sh in an agent's worktree stamps its unpushed (later rebased away) commit: that commit never becomes
        # an ancestor of feat-cmux-next, so an ancestor-only rule kept its unreviewed checks on every later push.
        old, new = self.stale_install()
        rule = self.repo / "scripts/cmux-next/compile_trailer.py"
        self.git("checkout", "-q", "--", ".")
        self.git("checkout", "-q", "-b", "side", old)
        rule.write_text("RULE = 'local, never landed'\n")
        self.commit_all("local rule")
        self.assertEqual(self.install().returncode, 0)
        self.assertEqual((self.installed_checks() / "compile_trailer.py").read_text(),
                         "RULE = 'local, never landed'\n")
        self.git("checkout", "-q", new)
        rule.write_text("RULE = 'newest'\n")
        newest = self.commit_all("newest rule")
        self.git("update-ref", "refs/remotes/origin/feat-cmux-next", newest)
        result = self.refresh()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.installed_checks() / "compile_trailer.py").read_text(), "RULE = 'newest'\n")

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
            "scripts/git-hooks/pre-push",
            "scripts/web_lint_prepush.py",
            "scripts/lint_swift_namespaces.py",
            "scripts/swift_source_mask.py",
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

    def test_an_install_behind_a_held_lock_gives_up_and_names_the_holder(self):
        """2026-10-28 (a803, a817, about 25 agents): a refresh stuck holding install.lock made every install and
        push behind it wait for good, naming pid 85305, the last installer's pid left in the file and long gone.
        An install now waits a bounded time, then fails naming the process that holds the lock."""
        self.assertEqual(self.install().returncode, 0)
        lock_path = self.common_dir() / "cmux-git-hooks" / "install.lock"
        lock_path.write_text("85305\n")  # the stale pid text of a finished install
        holder = subprocess.Popen(
            [sys.executable, "-I", "-c",
             "import fcntl, os, sys, time\n"
             "fd = os.open(sys.argv[1], os.O_RDWR)\nfcntl.flock(fd, fcntl.LOCK_EX)\n"
             "print('held', flush=True)\ntime.sleep(120)\n", str(lock_path)],
            stdout=subprocess.PIPE, text=True, start_new_session=True)
        self.addCleanup(holder.wait)
        self.addCleanup(holder.kill)
        self.assertEqual(holder.stdout.readline().strip(), "held")
        self.env["CMUX_HOOKS_INSTALL_LOCK_WAIT_SECONDS"] = "2"
        try:
            result = subprocess.run(["bash", INSTALLER], cwd=self.repo, env=self.env, text=True, capture_output=True,
                                    timeout=30)
        except subprocess.TimeoutExpired:
            self.fail("the install waited past 30 s for a lock another process holds")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(f"pid {holder.pid}", result.stderr)
        self.assertNotIn("85305", result.stderr)



def _load_refresh_checks():
    spec = importlib.util.spec_from_file_location("refresh_checks", SOURCE / "scripts/git-hooks/refresh_checks.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class CopyInputsConfinementTests(unittest.TestCase):
    """Codex on #40894 (F1, security): checks-copy-inputs names a source in the repository and a destination in the
    checks copy, and the install (install_copy) and a pre-push refresh (refresh) copy through it. An entry whose
    source leaves the repository (absolute, `..`, a symlink out) would read any local file into the hook folder, and
    one whose destination leaves the copy would overwrite any local file. Each form is refused, by name, before any
    file is written; legitimate entries still copy."""

    INPUTS = "scripts/git-hooks/checks-copy-inputs"

    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="cmux-copy-inputs-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        # ../../outside from the repository and from the stage both land in OUTSIDE.
        self.repo = self.root / "r" / "repo"
        self.hook_dir = self.root / "h"
        self.stage = self.hook_dir / "stage"
        self.outside = self.root / "outside"
        for folder in (self.repo / "scripts/cmux-next", self.repo / "scripts/git-hooks", self.stage, self.outside):
            folder.mkdir(parents=True)
        (self.outside / "secret").write_text("SECRET\n")
        (self.outside / "victim").write_text("VICTIM\n")
        (self.repo / "scripts/ok.py").write_text("OK = 1\n")
        (self.repo / "scripts/cmux-next/check.py").write_text("CHECK = 1\n")
        self.env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        self.env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull, HOME=str(self.root))
        git_fixture_env.without_auto_maintenance(self.env)
        self.git("init", "--quiet", "--initial-branch=main")
        self.rc = _load_refresh_checks()

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.repo), *args], env=self.env, text=True, capture_output=True,
                              check=True).stdout

    def commit(self, inputs):
        (self.repo / self.INPUTS).write_text(inputs)
        self.git("add", "-A")
        self.git("-c", "user.name=T", "-c", "user.email=t@example.invalid", "commit", "--allow-empty", "-qm", "inputs")
        return self.git("rev-parse", "HEAD").strip()

    def snapshot(self, folder):
        out = {}
        for dirpath, dirnames, filenames in os.walk(folder):
            for name in dirnames + filenames:
                path = Path(dirpath) / name
                out[str(path.relative_to(folder))] = (os.readlink(path) if path.is_symlink()
                                                      else None if path.is_dir() else path.read_bytes())
        return out

    def assert_install_refused(self, entry, rule, names):
        before_stage, before_outside = self.snapshot(self.stage), self.snapshot(self.outside)
        self.commit(f"scripts/cmux-next/\n{entry}\n")
        with self.assertRaises(ValueError) as caught:
            self.rc.install_copy(self.repo, self.stage)
        message = str(caught.exception)
        self.assertIn(names, message)
        self.assertIn(rule, message)
        self.assertEqual(self.snapshot(self.stage), before_stage, "a refused install wrote into the stage")
        self.assertEqual(self.snapshot(self.outside), before_outside, "a refused install wrote outside")

    def assert_refresh_refused(self, entry, rule, names):
        commit = self.commit(f"scripts/cmux-next/\n{entry}\n")
        before_hooks, before_outside = self.snapshot(self.hook_dir), self.snapshot(self.outside)
        with self.assertRaises(ValueError) as caught:
            self.rc.refresh(self.repo, self.hook_dir, commit)
        self.assertIn(names, str(caught.exception))
        self.assertIn(rule, str(caught.exception))
        self.assertEqual(self.snapshot(self.hook_dir), before_hooks, "a refused refresh wrote into the hook folder")
        self.assertEqual(self.snapshot(self.outside), before_outside, "a refused refresh wrote outside")

    def assert_refused(self, entry, rule, refresh=True, names=None):
        """ENTRY is refused under RULE, by a message naming NAMES (the entry itself by default)."""
        with self.subTest("install"):
            self.assert_install_refused(entry, rule, names or entry)
        if refresh:
            with self.subTest("refresh"):
                self.assert_refresh_refused(entry, rule, names or entry)

    # Sources.
    def test_an_absolute_source_is_refused(self):
        self.assert_refused(str(self.outside / "secret"), "is an absolute path")

    def test_a_dot_dot_source_is_refused(self):
        self.assert_refused("../../outside/secret", "has a .. component")

    def test_a_source_through_a_dot_dot_detour_is_refused(self):
        self.assert_refused("scripts/../../../outside/secret", "has a .. component")

    def test_a_source_under_a_symlinked_folder_that_escapes_is_refused(self):
        (self.repo / "linked").symlink_to(self.outside, target_is_directory=True)
        self.assert_refused("linked/secret", "resolves outside")

    def test_a_source_that_is_a_symlink_out_of_the_repository_is_refused(self):
        (self.repo / "scripts/leak.py").symlink_to(self.outside / "secret")
        self.assert_refused("scripts/leak.py", "resolves outside")

    def test_a_folder_member_that_is_a_symlink_out_of_the_repository_is_refused(self):
        (self.repo / "scripts/cmux-next/leak.py").symlink_to(self.outside / "secret")
        self.assert_refused("scripts/ok.py", "resolves outside", refresh=False, names="scripts/cmux-next/leak.py")

    def test_an_empty_source_is_refused(self):
        self.assert_refused("-> renamed.py", "is empty")

    # Destinations.
    def test_an_absolute_destination_is_refused(self):
        self.assert_refused(f"scripts/ok.py -> {self.outside / 'victim'}", "is an absolute path")

    def test_a_dot_dot_destination_is_refused(self):
        self.assert_refused("scripts/ok.py -> ../../outside/victim", "has a .. component")

    def test_a_destination_through_a_dot_dot_detour_is_refused(self):
        self.assert_refused("scripts/ok.py -> a/../../../outside/victim", "has a .. component")

    def test_a_destination_under_a_symlinked_folder_that_escapes_is_refused(self):
        (self.stage / "linked").symlink_to(self.outside, target_is_directory=True)
        self.assert_refused("scripts/ok.py -> linked/victim", "resolves outside", refresh=False)

    def test_a_destination_that_is_a_symlink_out_of_the_copy_is_refused(self):
        (self.stage / "victim.py").symlink_to(self.outside / "victim")
        self.assert_refused("scripts/ok.py -> victim.py", "resolves outside", refresh=False)

    def test_an_empty_destination_is_refused(self):
        self.assert_refused("scripts/ok.py ->", "is empty")

    def test_the_cli_names_the_refused_entry_and_exits_non_zero(self):
        self.commit("scripts/ok.py -> ../../outside/victim\n")
        result = subprocess.run([sys.executable, "-I", str(SOURCE / "scripts/git-hooks/refresh_checks.py"),
                                 "--repo", str(self.repo), "--install-copy", str(self.stage)],
                                env=self.env, text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("scripts/ok.py -> ../../outside/victim", result.stderr)
        self.assertNotIn("Traceback", result.stderr)
        self.assertEqual((self.outside / "victim").read_text(), "VICTIM\n")

    def test_post_merge_refuses_an_entry_that_leaves_the_repository(self):
        # post-merge reads the same list (to diff each source against the trusted branch); an entry that leaves the
        # repository stops it with the helper's refusal before the installer runs.
        for relative in ("scripts/git-hooks/post-merge", "scripts/git-hooks/refresh_checks.py"):
            shutil.copyfile(SOURCE / relative, self.repo / relative)
        installer = self.repo / "scripts/install-git-hooks.sh"
        marker = self.root / "installer-ran"
        installer.write_text(f"#!/bin/sh\ntouch {shlex.quote(str(marker))}\n")
        head = self.commit("scripts/cmux-next/\n../../outside/secret\n")
        self.git("remote", "add", "upstream", "https://github.com/manaflow-ai/cmux.git")
        self.git("update-ref", "refs/remotes/upstream/main", head)
        hook = subprocess.run(["/bin/bash", "scripts/git-hooks/post-merge"], cwd=self.repo, env=self.env, text=True,
                              capture_output=True)
        self.assertEqual(hook.returncode, 0, hook.stderr)
        self.assertIn("../../outside/secret", hook.stderr)
        self.assertIn("has a .. component", hook.stderr)
        self.assertFalse(marker.exists(), "post-merge ran the installer over a list that leaves the repository")

    # Legitimate entries.
    def test_legitimate_entries_still_copy(self):
        commit = self.commit("scripts/cmux-next/\nscripts/ok.py\nscripts/ok.py -> renamed/ok2.py\n")
        pairs = self.rc.install_copy(self.repo, self.stage)
        self.assertEqual(sorted(pairs), sorted([("scripts/cmux-next/check.py", "check.py"), ("scripts/ok.py", "ok.py"),
                                                ("scripts/ok.py", "renamed/ok2.py")]))
        self.assertEqual((self.stage / "check.py").read_text(), "CHECK = 1\n")
        self.assertEqual((self.stage / "ok.py").read_text(), "OK = 1\n")
        self.assertEqual((self.stage / "renamed/ok2.py").read_text(), "OK = 1\n")
        self.assertEqual(self.rc.refresh(self.repo, self.hook_dir, commit)[:30], "pre-push: refreshed the cmux-n")
        copy = self.hook_dir / "cmux-next-checks"
        self.assertEqual((copy / "renamed/ok2.py").read_text(), "OK = 1\n")
        self.assertEqual((copy / "check.py").read_text(), "CHECK = 1\n")


def load_tool_resolver():
    """The pre-commit hook's TOOL_RESOLVER (a single-quoted bash string) as a namespace of its
    functions; its dispatch runs only as __main__."""
    text = (SOURCE / "scripts/git-hooks/pre-commit").read_text(encoding="utf-8")
    match = re.search(r"^TOOL_RESOLVER='\n(.*?)\n'\n", text, re.S | re.M)
    namespace = {"__name__": "pre_commit_tool_resolver"}
    exec(compile(match.group(1), "scripts/git-hooks/pre-commit (TOOL_RESOLVER)", "exec"), namespace)
    return namespace


class CaseInsensitiveDestination:
    """os.symlink and os.readlink as on a case- and normalization-insensitive volume (the
    macOS default for the temporary directory): a name matches an entry of its directory
    whose NFD casefold is equal, so making a second one fails with FileExistsError."""

    def __init__(self, under):
        self.under = str(under)
        self.real_symlink = os.symlink
        self.real_readlink = os.readlink

    @staticmethod
    def key(name):
        return unicodedata.normalize("NFD", name).casefold()

    def existing(self, path):
        path = os.fspath(path)
        directory, name = os.path.split(path)
        if path.startswith(self.under + os.sep) and os.path.isdir(directory):
            for entry in os.listdir(directory):
                if self.key(entry) == self.key(name):
                    return os.path.join(directory, entry)
        return path

    def symlink(self, target, path, *args, **kwargs):
        if os.path.lexists(self.existing(path)):
            raise FileExistsError(errno.EEXIST, os.strerror(errno.EEXIST), os.fspath(path))
        return self.real_symlink(target, path, *args, **kwargs)

    def readlink(self, path, *args, **kwargs):
        return self.real_readlink(self.existing(path), *args, **kwargs)

    def __enter__(self):
        self.patches = [mock.patch.object(os, "symlink", self.symlink),
                        mock.patch.object(os, "readlink", self.readlink)]
        for patch in self.patches:
            patch.start()
        return self

    def __exit__(self, *exc):
        for patch in reversed(self.patches):
            patch.stop()
        return False


class CaseInsensitiveLookup:
    """os.path.isfile, os.path.exists, os.path.islink and os.access as on a case- and normalization-insensitive
    volume (macOS's default): a lookup of a name under UNDER finds the entry whose NFD casefold is equal, so a PATH
    directory holding NODE answers for node too (cmux#41666 review: the hook found NODE as node there)."""

    def __init__(self, under):
        self.folding = CaseInsensitiveDestination(under)
        self.real = {"isfile": os.path.isfile, "exists": os.path.exists, "islink": os.path.islink,
                     "access": os.access}

    def __enter__(self):
        fold = self.folding.existing
        real = self.real
        self.patches = [
            mock.patch.object(os.path, "isfile", lambda path: real["isfile"](fold(path))),
            mock.patch.object(os.path, "exists", lambda path: real["exists"](fold(path))),
            mock.patch.object(os.path, "islink", lambda path: real["islink"](fold(path))),
            mock.patch.object(os, "access", lambda path, mode, *a, **k: real["access"](fold(path), mode, *a, **k)),
        ]
        for patch in self.patches:
            patch.start()
        return self

    def __exit__(self, *exc):
        for patch in reversed(self.patches):
            patch.stop()
        return False


class ChildPathStubNamesTests(unittest.TestCase):
    """The stubs for names on PATH that CHILD_TOOLS does not list: names that differ only in
    case (or Unicode normalization) are one file on a case-insensitive temporary volume, and
    the hook raised an uncaught FileExistsError there, refusing every commit."""

    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="cmux-child-path-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(os.path.realpath(temporary.name))
        self.temp = self.root / "tmp"
        self.temp.mkdir()
        self.resolver = load_tool_resolver()
        patch = mock.patch.object(tempfile, "tempdir", str(self.temp))
        patch.start()
        self.addCleanup(patch.stop)

    def path_dir(self, label, *names, mode=0o755):
        directory = self.root / label
        directory.mkdir()
        for name in names:
            (directory / name).write_text("#!/bin/sh\nexit 0\n")
            (directory / name).chmod(mode)
        return str(directory)

    def child_path(self, *entries):
        return Path(self.resolver["child_path"](os.pathsep.join(entries), [], {}))

    def stub_kind(self, shims, name):
        stub = CaseInsensitiveDestination(self.temp).existing(shims / self.resolver["NOT_LISTED"] / name)
        return os.path.basename(os.readlink(stub))

    def folded(self, shims):
        names = os.listdir(shims / self.resolver["NOT_LISTED"])
        return sorted(CaseInsensitiveDestination.key(name) for name in names)

    def test_names_differing_only_in_case_get_one_stub(self):
        entry = self.path_dir("bin", "Probe", "probe")
        with CaseInsensitiveDestination(self.temp):
            shims = self.child_path(entry)
        self.assertEqual(self.folded(shims).count("probe"), 1)
        self.assertEqual(self.stub_kind(shims, "probe"), "not-listed")

    def test_the_same_name_in_two_path_dirs_gets_one_stub(self):
        first, second = self.path_dir("one", "Probe", "same"), self.path_dir("two", "probe", "same")
        with CaseInsensitiveDestination(self.temp):
            shims = self.child_path(first, second)
        self.assertEqual(self.folded(shims).count("probe"), 1)
        self.assertEqual(self.folded(shims).count("same"), 1)

    def test_a_listed_name_keeps_its_own_stub_beside_a_case_variant(self):
        """node is in CHILD_TOOLS with no copy here; NODE on PATH must not take its stub."""
        # Not executable: on macOS's case-insensitive volumes an executable NODE is node itself (the same file), and
        # the hook rightly links it (cmux#41666 review). This test is about the stub name, so the lookups fold too.
        entry = self.path_dir("bin", "NODE", mode=0o644)
        with CaseInsensitiveDestination(self.temp), CaseInsensitiveLookup(self.root):
            shims = self.child_path(entry)
        self.assertEqual(self.folded(shims).count("node"), 1)
        self.assertEqual(self.stub_kind(shims, "node"), "unresolved")

    def test_on_a_case_insensitive_volume_an_executable_case_variant_is_the_listed_tool(self):
        """There NODE and node are one file, so the hook links node to it (a NODE stub after it is never reached:
        the links come first on the children's PATH)."""
        entry = self.path_dir("bin", "NODE")
        with CaseInsensitiveDestination(self.temp), CaseInsensitiveLookup(self.root):
            shims = self.child_path(entry)
        self.assertEqual(os.readlink(shims / "node"), os.path.join(entry, "node"))

    def test_names_differing_only_in_normalization_get_one_stub(self):
        composed, decomposed = "caf\u00e9", "cafe\u0301"
        entry = self.path_dir("bin", composed, decomposed)
        with CaseInsensitiveDestination(self.temp):
            shims = self.child_path(entry)
        self.assertEqual(self.folded(shims).count(CaseInsensitiveDestination.key(composed)), 1)

    def test_any_other_filesystem_error_names_the_stub_and_stops(self):
        entry = self.path_dir("bin", "probe")
        real_symlink = os.symlink

        def refuse_probe(target, path, *args, **kwargs):
            if os.path.basename(path) == "probe":
                raise PermissionError(errno.EACCES, os.strerror(errno.EACCES), path)
            return real_symlink(target, path, *args, **kwargs)

        stderr = io.StringIO()
        with mock.patch.object(os, "symlink", refuse_probe), mock.patch.object(sys, "stderr", stderr):
            with self.assertRaises(SystemExit) as stopped:
                self.child_path(entry)
        self.assertEqual(stopped.exception.code, 1)
        self.assertIn("pre-commit: ", stderr.getvalue())
        self.assertIn(os.path.join(self.resolver["NOT_LISTED"], "probe"), stderr.getvalue())
        self.assertIn(os.strerror(errno.EACCES), stderr.getvalue())

# Detector: every command the pre-commit hook runs is a shell builtin, a function
# the hook defines, or a tool the hook's one resolver (resolve_tool) returned.
# A bash tokenizer over simple commands, pipelines, lists, compound commands,
# $(...), backticks and <(...), not a regex over lines.
SHELL_BUILTINS = frozenset("""
: [ alias bg bind break builtin caller cd command compgen complete compopt continue declare dirs disown
echo enable exit export false fc fg getopts hash help history jobs kill let local logout mapfile popd
printf pushd pwd read readarray readonly return set shift shopt suspend test times trap true type
typeset ulimit umask unalias unset wait
""".split())  # eval, exec, source and . run other code: never accepted as plain builtins.
OPENING_KEYWORDS = frozenset(("if", "then", "else", "elif", "do", "while", "until", "!", "{", "time"))
CLOSING_KEYWORDS = frozenset(("fi", "done", "}"))
SEPARATORS = frozenset((";", "&", "&&", "||", "|", "|&", "(", "\n"))
REDIRECTIONS = ("<<<", ">>", "&>>", "&>", ">&", "<&", "<>", ">|", "<", ">")
OPERATORS = (";;", "&&", "||", "|&") + REDIRECTIONS + (";", "&", "|", "(", ")")
ASSIGNMENT = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)(\[[^]]*\])?\+?=(.*)", re.S)
# The only right-hand side that makes a variable a resolved tool: one resolve_tool call.
RESOLVED = re.compile(r'"\$\(resolve_tool [^()`|;&]+?(?: \|\| true)?\)"')
COPY = re.compile(r'"\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?"')
VARIABLE_WORD = re.compile(r'"?\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?"?')
# The resolver's own interpreter: the one hook_python_pick (scripts/git-hooks/hook_python.sh, the reviewed copy
# beside the hook) picked on this host, then checked by the resolver's boot step. The picker never runs a candidate
# that resolves into the checkout or the git dir (tests/test_hook_python.py).
RESOLVER_INTERPRETER = "PYTHON3_BIN"
PICKED_INTERPRETER = '"$HOOK_PYTHON"'
# The one file the hook may source: the installed picker beside it. Its own commands are held to PICKER_COMMANDS.
PICKER_SOURCE = '"$HOOK_DIR/hook_python.sh"'
PICKER = SOURCE / "scripts/git-hooks/hook_python.sh"
# What the picker runs besides builtins: two system tools by absolute path, and the candidate it probes.
PICKER_COMMANDS = frozenset(("/bin/realpath", "/usr/bin/xcode-select", '"$real"'))
# Commands that run their argument as a program; env's comes after its options.
EXEC_WRAPPERS = {"TOOL_ENV"}
# Unresolved commands the detector lets through. Keep it empty.
UNRESOLVED_ALLOWLIST: frozenset = frozenset()


class BashCommands:
    """The simple commands a bash script runs, with its functions and assignments."""

    def __init__(self, source):
        self.source = source
        self.commands = []  # (line, [raw words])
        self.functions = set()
        self.assignments = {}  # name -> [raw right-hand sides]
        self.dynamic_assignments = []  # raw words of `printf -v "$x"` commands
        self.parse(self.tokenize(source, 0, closer=False)[0])

    def line(self, position):
        return self.source.count("\n", 0, position) + 1

    def tokenize(self, s, i, closer):
        tokens, depth = [], 0
        while i < len(s):
            c = s[i]
            if c in " \t":
                i += 1
            elif s.startswith("\\\n", i):
                i += 2
            elif c == "\n":
                tokens.append(("op", "\n", i))
                i += 1
            elif c == "#":
                i = s.find("\n", i) if "\n" in s[i:] else len(s)
            elif c == ")" and closer and depth == 0:
                return tokens, i + 1
            elif s.startswith("((", i):
                end = self.matching_paren(s, i)
                tokens.append(("arith", s[i:end], i))
                i = end
            elif s[i:i + 2] in ("<(", ">("):
                inner, end = self.tokenize(s, i + 2, closer=True)
                self.parse(inner)
                tokens.append(("word", s[i:end], i))
                i = end
            elif s.startswith("<<", i) and not s.startswith("<<<", i):
                raise ValueError(f"line {self.line(i)}: here-documents are not parsed; use a here-string")
            else:
                op = next((op for op in OPERATORS if s.startswith(op, i)), None)
                if op:
                    depth += {"(": 1, ")": -1}.get(op, 0)
                    tokens.append(("op", op, i))
                    i += len(op)
                else:
                    end = self.word_end(s, i)
                    tokens.append(("word", s[i:end], i))
                    i = end
        if closer:
            raise ValueError("unterminated substitution")
        return tokens, i

    @staticmethod
    def matching_paren(s, i):
        depth = 0
        for j in range(i, len(s)):
            depth += {"(": 1, ")": -1}.get(s[j], 0)
            if depth == 0:
                return j + 1
        raise ValueError("unterminated arithmetic")

    def dollar(self, s, i):
        """s[i] is $: the index after the expansion, parsing any command substitution in it."""
        if s.startswith("$((", i):
            return self.matching_paren(s, i + 1)
        if s.startswith("$(", i):
            inner, end = self.tokenize(s, i + 2, closer=True)
            self.parse(inner)
            return end
        if s.startswith("${", i):
            depth, j = 0, i + 1
            while j < len(s):
                if s[j] == "\\":
                    j += 2
                    continue
                if s[j] == "$" and j + 1 < len(s) and s[j + 1] in "({":
                    j = self.dollar(s, j)
                    continue
                if s[j] == '"':
                    j = self.double_quoted(s, j + 1)
                    continue
                depth += {"{": 1, "}": -1}.get(s[j], 0)
                j += 1
                if depth == 0:
                    return j
            raise ValueError("unterminated ${")
        if s.startswith("$'", i):
            j = i + 2
            while s[j] != "'":
                j += 2 if s[j] == "\\" else 1
            return j + 1
        return i + 1

    def backticks(self, s, i):
        j = i
        while s[j] != "`":
            j += 2 if s[j] == "\\" else 1
        nested = BashCommands(s[i:j].replace("\\`", "`"))
        self.commands += nested.commands
        self.functions |= nested.functions
        for name, values in nested.assignments.items():
            self.assignments.setdefault(name, []).extend(values)
        self.dynamic_assignments += nested.dynamic_assignments
        return j + 1

    def double_quoted(self, s, i):
        while s[i] != '"':
            if s[i] == "\\":
                i += 2
            elif s[i] == "$":
                i = self.dollar(s, i)
            elif s[i] == "`":
                i = self.backticks(s, i + 1)
            else:
                i += 1
        return i + 1

    def word_end(self, s, i):
        start = i
        while i < len(s) and s[i] not in " \t\n;&|()<>":
            if s[i] == "\\":
                i += 2
            elif s[i] == "'":
                i = s.index("'", i + 1) + 1
            elif s[i] == '"':
                i = self.double_quoted(s, i + 1)
            elif s[i] == "`":
                i = self.backticks(s, i + 1)
            elif s[i] == "$":
                i = self.dollar(s, i)
            else:
                i += 1
        if s.startswith("(", i) and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*\+?=", s[start:i]):
            i += 1  # an array assignment: NAME=(words...)
            while s[i] != ")":
                if s[i] in " \t\n":
                    i += 1
                elif (end := self.word_end(s, i)) > i:
                    i = end
                else:
                    raise ValueError(f"line {self.line(i)}: unparsed array assignment")
            i += 1
        return i

    def assign(self, name, value):
        self.assignments.setdefault(name, []).append(value)

    def parse(self, tokens):
        i, expect_command, cases = 0, True, []
        while i < len(tokens):
            kind, text, position = tokens[i]
            if kind == "op" and text in SEPARATORS:
                expect_command, i = True, i + 1
            elif kind == "op" and text == ";;":
                cases[-1] = "pattern"
                expect_command, i = True, i + 1
            elif kind == "op" and text == ")":
                expect_command, i = False, i + 1
            elif kind == "op":  # a redirection and its target
                i += 2
            elif cases and cases[-1] == "pattern":
                if text == "esac":
                    cases.pop()
                    expect_command, i = False, i + 1
                    continue
                while not (tokens[i][0] == "op" and tokens[i][1] == ")"):
                    i += 1
                cases[-1] = "body"
                expect_command, i = True, i + 1
            elif not expect_command or kind == "arith":
                expect_command, i = False, i + 1
            elif ASSIGNMENT.fullmatch(text):
                match = ASSIGNMENT.fullmatch(text)
                self.assign(match.group(1), match.group(3))
                i += 1
            elif text in OPENING_KEYWORDS:
                i += 1
            elif text in CLOSING_KEYWORDS:
                expect_command, i = False, i + 1
            elif text == "esac":
                cases.pop()
                expect_command, i = False, i + 1
            elif text == "case":
                if tokens[i + 2][1] != "in":
                    raise ValueError(f"line {self.line(position)}: unparsed case")
                cases.append("pattern")
                i += 3
            elif text in ("for", "select"):
                if tokens[i + 1][0] == "word":
                    self.assign(tokens[i + 1][1], "<loop>")
                while tokens[i][1] not in (";", "\n"):
                    i += 1
            elif text == "[[":
                while tokens[i][1] != "]]":
                    i += 1
                expect_command, i = False, i + 1
            elif text == "function":
                raise ValueError(f"line {self.line(position)}: write functions as name() {{")
            elif i + 2 < len(tokens) and tokens[i + 1][1] == "(" and tokens[i + 2][1] == ")":
                self.functions.add(text)
                i += 3
            else:
                words = []
                while i < len(tokens) and not (tokens[i][0] == "op" and tokens[i][1] in SEPARATORS | {";;", ")"}):
                    if tokens[i][0] == "op":
                        i += 2
                    else:
                        words.append(tokens[i][1])
                        i += 1
                self.command(position, words)
                expect_command = False

    def command(self, position, words):
        self.commands.append((self.line(position), words))
        name, arguments = words[0], words[1:]
        if name in ("local", "declare", "typeset", "export", "readonly"):
            for word in arguments:
                if ASSIGNMENT.fullmatch(word):
                    self.assign(ASSIGNMENT.fullmatch(word).group(1), ASSIGNMENT.fullmatch(word).group(3))
        elif name == "read":
            skip = False
            for word in arguments:
                if skip:
                    skip = False
                elif word in ("-a", "-d", "-n", "-N", "-p", "-t", "-u", "-i"):
                    skip = True
                elif not word.startswith("-"):
                    self.assign(word, "<read>")
        elif name == "printf" and arguments[:1] == ["-v"]:
            if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", arguments[1]):
                self.assign(arguments[1], "<printf>")
            else:
                self.dynamic_assignments.append(words)

    def resolved_variables(self):
        resolved, changed = set(), True
        while changed:
            changed = False
            for name, values in self.assignments.items():
                if name not in resolved and all(
                        RESOLVED.fullmatch(value) or (COPY.fullmatch(value) and COPY.fullmatch(value).group(1) in resolved)
                        for value in values):
                    resolved.add(name)
                    changed = True
        return resolved

    def violations(self):
        """Every command that is neither a builtin, a function here, nor a resolved tool."""
        resolved = self.resolved_variables()
        functions = set(self.functions)
        if self.sources_picker():
            functions |= BashCommands(PICKER.read_text(encoding="utf-8")).functions
            if self.assignments.get(RESOLVER_INTERPRETER) == [PICKED_INTERPRETER] and "hook_python_pick" in functions:
                resolved.add(RESOLVER_INTERPRETER)

        def is_resolved(variable):
            # TOOL_* variables are written only by the resolver's boot loader:
            # none may be assigned anywhere else.
            return variable in resolved or (variable.startswith("TOOL_") and variable not in self.assignments)

        found = []

        def check(line, words):
            word = words[0]
            if not any(c in word for c in "$\"'`\\"):
                if word in ("command", "builtin") and len(words) > 1 and words[1] not in ("-v", "-V"):
                    check(line, words[1:])
                elif word in SHELL_BUILTINS or word in functions:
                    pass
                elif words == ["source", PICKER_SOURCE]:
                    pass  # the reviewed picker beside the hook; its commands: test_the_picker_runs_only_...
                elif word not in UNRESOLVED_ALLOWLIST:
                    found.append((line, word))
                return
            match = VARIABLE_WORD.fullmatch(word)
            if not match or not is_resolved(match.group(1)):
                found.append((line, word))
                return
            if match.group(1) in EXEC_WRAPPERS:
                rest = list(words[1:])
                while rest and (rest[0].startswith("-") or ASSIGNMENT.fullmatch(rest[0])):
                    rest = rest[2:] if rest[0] in ("-u", "-C", "-S") else rest[1:]
                if rest:
                    check(line, rest)

        for line, words in self.commands:
            check(line, words)
        return found

    def sources_picker(self):
        return any(words == ["source", PICKER_SOURCE] for _, words in self.commands)


class PreCommitToolResolutionDetectorTests(unittest.TestCase):
    HOOK = SOURCE / "scripts/git-hooks/pre-commit"

    def test_every_command_the_pre_commit_hook_runs_is_a_builtin_or_a_resolved_tool(self):
        """Codex review of #41001 (F1): `rustup which` ran by name, ahead of every check."""
        hook = BashCommands(self.HOOK.read_text(encoding="utf-8"))
        self.assertEqual(hook.violations(), [], "run it through resolve_tool, never by name")
        self.assertEqual(UNRESOLVED_ALLOWLIST, frozenset())

    def test_only_the_boot_loader_writes_tool_variables(self):
        source = self.HOOK.read_text(encoding="utf-8")
        hook = BashCommands(source)
        self.assertEqual(hook.dynamic_assignments, [["printf", "-v", '"$name"', "'%s'", '"$value"']])
        self.assertIn("tool) [[ \"$name\" =~ ^TOOL_[A-Z0-9_]+$ ]] && printf -v", source)
        # The interpreter is the picker's choice, assigned once, never read from the recorded path directly.
        self.assertEqual(hook.assignments.get(RESOLVER_INTERPRETER), [PICKED_INTERPRETER])
        self.assertTrue(hook.sources_picker())
        self.assertIn('hook_python_pick 0 "$RECORDED_PYTHON" "$(pwd -P)" "${HOOK_DIR%/*}"', source)
        self.assertNotIn("read -r PYTHON3_BIN", source)

    def test_the_picker_runs_only_builtins_two_system_tools_and_the_candidate_it_probes(self):
        # The hook sources it before any tool is resolved, so it may look nothing up on PATH.
        picker = BashCommands(PICKER.read_text(encoding="utf-8"))
        unlisted = [(line, words[0]) for line, words in picker.commands
                    if words[0] not in SHELL_BUILTINS and words[0] not in picker.functions
                    and words[0] not in PICKER_COMMANDS]
        self.assertEqual(unlisted, [])
        self.assertEqual(picker.functions, {"hook_python_pick"})

    def test_the_detector_refuses_an_interpreter_that_is_not_the_picks(self):
        # Without the picker sourced, or with PYTHON3_BIN from anywhere else, the interpreter is unresolved.
        cases = (
            'PYTHON3_BIN="$HOOK_PYTHON"\n"$PYTHON3_BIN" -I x.py\n',
            f'source {PICKER_SOURCE}\nhook_python_pick 0 ""\nPYTHON3_BIN=/tmp/python3\n"$PYTHON3_BIN" -I x.py\n',
            'source ./hook_python.sh\nPYTHON3_BIN="$HOOK_PYTHON"\n"$PYTHON3_BIN" -I x.py\n',
        )
        for script in cases:
            with self.subTest(script=script):
                self.assertIn('"$PYTHON3_BIN"', self.violations(script))
        self.assertEqual(self.violations(f'source {PICKER_SOURCE}\nhook_python_pick 0 ""\n'
                                         'PYTHON3_BIN="$HOOK_PYTHON"\n"$PYTHON3_BIN" -I x.py\n'), [])

    # The hook defines resolve_tool; a fixture script gets a stand-in.
    def violations(self, script):
        return [word for _, word in BashCommands("resolve_tool() { :; }\n" + script).violations()]

    def test_detector_catches_an_unresolved_rustup(self):
        self.assertEqual(self.violations(
            'pinned="$(rustup which --toolchain "$toolchain" rustfmt 2>/dev/null || true)"\n'), ["rustup"])

    def test_detector_catches_names_in_every_command_position(self):
        cases = {
            "x=`sed -n p file`\n": ["sed"],
            '"$TOOL_GIT" diff | grep -q x\n': ["grep"],
            'while read -r line; do :; done < <(git diff --cached)\n': ["git"],
            'true && rustfmt a.rs\n': ["rustfmt"],
            'if ! cat f >/dev/null; then echo; fi\n': ["cat"],
            'f() { local d; d="$(cd / && rustup show)"; }\n': ["rustup"],
            'case "$1" in a|b) bun install ;; *) : ;; esac\n': ["bun"],
            '[[ -n "$(head -n 1 f)" ]] && echo\n': ["head"],
            'echo "$(printf "%s" "$(node -v)")"\n': ["node"],
            'x="${y:-$(swift-format --version)}"\n': ["swift-format"],
            '"$TOOL_ENV" -u BUN_OPTIONS rustup which\n': ["rustup"],
            'X=/tmp/rustup\n"$X" which\n': ['"$X"'],
            'f() { "$@"; }\n': ['"$@"'],
            'eval "$cmd"\n': ["eval"],
            'source ./x.sh\n': ["source"],
            'command rustup which\n': ["rustup"],
            'R="$(resolve_tool rustup || echo ./rustup)"\n"$R" which\n': ['"$R"'],
            'TOOL_RUSTUP=./rustup\n"$TOOL_RUSTUP" which\n': ['"$TOOL_RUSTUP"'],
        }
        for script, expected in cases.items():
            with self.subTest(script=script):
                self.assertEqual(self.violations(script), expected)

    def test_detector_accepts_builtins_functions_and_resolved_tools(self):
        script = (
            'f() { printf "%s\\n" "$1"; }\n'
            'R="$(resolve_tool rustup || true)"\n'
            'P="$R"\n'
            'tool="$(resolve_tool "$1")" || exit 1\n'
            'if [[ -n "$R" ]] && (( 1 > 0 )); then "$P" which; f x | "$TOOL_GREP" -q x; fi\n'
            'for ((i = 0; i < 2; i++)); do "$TOOL_SLEEP" 1; done\n'
            'for p in a b; do case "$p" in a) : ;; esac; done\n'
            '"$TOOL_ENV" -u BUN_OPTIONS "$tool" install\n'
            'command -v rustup >/dev/null\n'
        )
        self.assertEqual(self.violations(script), [])

    def test_detector_refuses_what_it_cannot_parse(self):
        with self.assertRaises(ValueError):
            BashCommands("cat <<EOF\nx\nEOF\n")


if __name__ == "__main__":
    unittest.main()
