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
        for tool in ("git", "bash", "sh", "sed", "awk", "grep", "cut", "sort", "head", "cat", "env", "dirname", "basename", "mktemp", "rm", "mv", "mkdir", "rmdir", "find"):
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
        env = self.formatter_env(with_rustfmt=False, FAKE_VP_LOG=str(vp_log))
        bun = Path(env["PATH"]) / "bun"
        bun.write_text(f"""#!/bin/sh
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
            "Packages/macOS/CmuxNext/Sources/CmuxNextPalette/Resources/palette-ranker.js",
            "webviews/src/agent-session/acpmux/generated/strings.json",
            "webviews/src/pages/settings/generated/strings.json",
            # Other checked exports: lanes committed "regenerate after the tip
            # merge" for these every day.
            "plans/cmux-next/actions.md",
            "plans/cmux-next/action-surfaces.json",
            "schemas/settings/settings-schema.json",
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


if __name__ == "__main__":
    unittest.main()
