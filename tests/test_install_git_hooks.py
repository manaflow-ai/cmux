#!/usr/bin/env python3
"""scripts/install-git-hooks.sh must not fail setup over hooks a contributor already has.

setup.sh runs the installer last under `set -e`, so a non-zero exit reports the
whole setup as failed. Existing hooks (a global core.hooksPath, or Git LFS's
hooks in .git/hooks) are left alone with a warning; real errors still fail.
"""
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import shlex
import subprocess
import sys
import tempfile
import time
import unittest


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
            "scripts/webviews_bun_version.py",
            "scripts/check-webviews-bun-version.sh",
        ):
            source, target = SOURCE / relative, root / relative
            if not source.exists():
                continue  # a tree from before the file; the installer then fails on it if it needs it
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
    # Cargo package (not only cmux-tui), and a missing formatter stops an agent's
    # commit instead of skipping silently.
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
            fake.write_text(f'#!/bin/sh\nprintf "%s\\n" "$*" >> {shlex.quote(str(self.rustfmt_log))}\n')
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
        return subprocess.run([str(hook)], cwd=self.repo, env=env, text=True, capture_output=True)

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
        edition_flag, edition, config_flag, config, path = calls[0].split(" ")
        self.assertEqual((edition_flag, edition, config_flag, path),
                         ("--edition", "2024", "--config-path", str(source.resolve())), calls)
        self.assertFalse(Path(config).resolve().is_relative_to(self.repo.resolve()), config)

    def test_pre_commit_uses_the_package_rustfmt_config(self):
        self.assertEqual(self.install().returncode, 0)
        source = self.stage_rust_package("workers/probe", "2021", config="max_width = 100\n")
        result = self.run_pre_commit(self.formatter_env(with_rustfmt=True))
        self.assertEqual(result.returncode, 0, result.stderr)
        config = (self.repo / "workers/probe/rustfmt.toml").resolve()
        self.assertEqual(self.rustfmt_log.read_text().splitlines(),
                         [f"--edition 2021 --config-path {config} {source.resolve()}"])

    def test_missing_rustfmt_stops_an_agent_commit_and_warns_a_person(self):
        self.assertEqual(self.install().returncode, 0)
        self.stage_rust_package("Native/OptChat/probe", "2021")
        agent = self.run_pre_commit(self.formatter_env(with_rustfmt=False, CMUX_AGENT="1"))
        self.assertNotEqual(agent.returncode, 0, agent.stderr)
        self.assertIn("rustfmt is unavailable", agent.stderr)
        self.assertIn("do not pass --no-verify", agent.stderr)
        # A Codex shell sets CODEX_THREAD_ID, not CMUX_AGENT.
        codex = self.run_pre_commit(self.formatter_env(with_rustfmt=False, CODEX_THREAD_ID="thread"))
        self.assertNotEqual(codex.returncode, 0, codex.stderr)
        person = self.run_pre_commit(self.formatter_env(with_rustfmt=False))
        self.assertEqual(person.returncode, 0, person.stderr)
        self.assertIn("rustfmt is unavailable", person.stderr)

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
        """An agent commit (a missing vp is fatal) whose webviews has a bun.lock and no vp."""
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
        self.assertNotEqual(result.returncode, 0, result.stderr)
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
        self.assertNotEqual(result.returncode, 0, "a refused pin refuses the commit")
        self.assertIn("refusing to install webviews packages", result.stderr)

    def test_a_pinned_install_resolving_into_the_checkout_is_not_run(self):
        self.assertEqual(self.install().returncode, 0)
        canary = self.checkout_payload(self.repo / "payload")
        (self.root / "mise/installs/bun").mkdir(parents=True)
        (self.root / "mise/installs/bun/1.4.4").symlink_to(self.repo / "payload")
        env = self.bootstrap_env()
        result = self.run_pre_commit(env)
        self.assertFalse(canary.exists(), result.stderr)
        self.assertIn("outside its install root", result.stderr)
        self.assertNotEqual(result.returncode, 0, result.stderr)

    def test_a_path_bun_inside_the_checkout_is_not_run(self):
        self.assertEqual(self.install().returncode, 0)
        canary = self.checkout_payload(self.repo / "tools")
        env = self.bootstrap_env()
        env["PATH"] = f"{env['PATH']}{os.pathsep}{self.repo / 'tools/bin'}"
        result = self.run_pre_commit(env)
        self.assertFalse(canary.exists(), result.stderr)
        self.assertIn("inside this checkout", result.stderr)
        self.assertNotEqual(result.returncode, 0, result.stderr)

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

    def test_a_bun_the_hook_cannot_vouch_for_refuses_the_commit(self):
        """#41001 review: no trusted reader copy, a refused pin or no bun at the pin used to fall
        back to PATH's bun by name. Each now refuses with the fix, and the planted PATH bun (outside
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
                self.assertNotEqual(result.returncode, 0, result.stderr)
                self.assertIn(says, result.stderr)
                self.assertIn("refusing to install webviews packages", result.stderr)
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
                    # No pin it accepts: the hook installs with nothing and refuses the commit.
                    hook = None
                    self.assertNotEqual(result.returncode, 0, result.stderr)
                    self.assertIn("refusing to install webviews packages", result.stderr)
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
        pinned.write_text(f'#!/bin/sh\nprintf "pinned %s\\n" "$*" >> {shlex.quote(str(self.rustfmt_log))}\n')
        pinned.chmod(0o755)
        self.fake_rustup(self.root / "bin-rustfmt", "1.95.0", pinned)
        result = self.run_pre_commit(env)
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.rustfmt_log.read_text().splitlines()
        self.assertEqual(len(calls), 1, calls)
        self.assertTrue(calls[0].startswith("pinned --edition 2021 "), calls)
        self.assertTrue(calls[0].endswith(str(source.resolve())), calls)

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
            # Other checked exports: lanes committed "regenerate after the tip
            # merge" for these every day.
            "plans/cmux-next/actions.md",
            "plans/cmux-next/action-surfaces.json",
            "schemas/settings/settings-schema.json",
            # The docs reference that follows the schema: 13 conflicts in a week.
            "web/data/next-docs/settings-reference.generated.json",
            "docs/mdm/com.manaflow.cmux.plist",
            "Packages/macOS/CmuxNext/ci-target-graph.json",
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
        self.assertEqual([path for path in kept if next_batch.classify(path) not in {"web", "swift", "sdk"}], [])

    def test_hand_written_sdk_files_still_merge_normally(self):
        shutil.copyfile(SOURCE / ".gitattributes", self.repo / ".gitattributes")
        self.assertEqual(self.install().returncode, 0)
        for path in ("cmux-tui/bindings/go/raw/client.go", "cmux-tui/bindings/java/src/com/cmux/raw/Client.java"):
            attribute = self.git("check-attr", "merge", "--", path).stdout.strip()
            self.assertTrue(attribute.endswith(": unspecified"), attribute)

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
        env = dict(self.env, CMUX_PREPUSH_QUEUE_DIR=str(queue), **settings)
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
# The resolver's own interpreter: the absolute path the installer wrote beside the
# hook, read once, then checked by the resolver's boot step.
RESOLVER_INTERPRETER = "PYTHON3_BIN"
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
        if self.assignments.get(RESOLVER_INTERPRETER) == ["<read>"]:
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
                elif word in SHELL_BUILTINS or word in self.functions:
                    pass
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
        self.assertEqual(hook.assignments.get(RESOLVER_INTERPRETER), ["<read>"])
        self.assertIn('IFS= read -r PYTHON3_BIN < "$PYTHON_PATH_FILE"', source)

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
