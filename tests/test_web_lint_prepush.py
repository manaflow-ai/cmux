#!/usr/bin/env python3
"""The pre-push hook runs the web lints on what a push changes, and stops a bad push.

Each test builds a throwaway repository with stand-in web packages (a
package.json `check` script and an `eslint` executable that fail on the word
BAD), installs the hooks with scripts/install-git-hooks.sh, and pushes to a
bare `origin` through the real `git push`, so the installed trusted hook copy is
what runs.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import sys
import unittest
import git_fixture_env  # disables git auto maintenance


SOURCE = Path(__file__).resolve().parents[1]
INSTALLER = "scripts/install-git-hooks.sh"
AGENT_VARS = ("CMUX_AGENT", "CMUX_REQUIRE_FORMATTERS", "CI", "CLAUDECODE", "CODEX_CI", "CODEX_THREAD_ID",
              "CODEX_SANDBOX", "CMUX_WEB_LINT_SKIP_REASON")

# Two `&&` pieces, as webviews' real check script has many; each fails on BAD.
WEBVIEWS_PACKAGE = """{
  "name": "webviews-fixture",
  "scripts": {
    "check": "sh check-lanes.sh && sh check-format.sh",
    "check:fix": "sh fix-format.sh"
  }
}
"""
CHECK_LANES = """#!/bin/sh
if grep -rl 'BAD_LANE' src test 2>/dev/null; then echo 'browser lane import outside a lane file'; exit 1; fi
echo 'lanes ok'
"""
CHECK_FORMAT = """#!/bin/sh
if grep -rl 'BAD_FORMAT' src test 2>/dev/null; then echo 'Format issues found'; exit 1; fi
echo 'format ok'
"""
FIX_FORMAT = """#!/bin/sh
for f in $(grep -rl 'BAD_FORMAT' src test 2>/dev/null); do sed 's/BAD_FORMAT/good_format/' "$f" > "$f.tmp" && mv "$f.tmp" "$f"; done
"""
FAKE_ESLINT = """#!/bin/sh
status=0
fix=0
for arg in "$@"; do
  case "$arg" in
    --fix) fix=1 ;;
    -*|node_modules/*) ;;
    *)
      echo "$arg" >> "$ESLINT_LOG"
      if [ "$fix" = 1 ]; then sed 's/BAD_ESLINT/good_eslint/' "$arg" > "$arg.tmp" && mv "$arg.tmp" "$arg"; fi
      if grep -q BAD_ESLINT "$arg"; then echo "$arg: error no-bad"; status=1; fi ;;
  esac
done
exit $status
"""


def load_lint(repo):
    import importlib.util
    spec = importlib.util.spec_from_file_location("web_lint_prepush", repo / "scripts/web_lint_prepush.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module  # dataclasses look their module up
    spec.loader.exec_module(module)
    return module


class WebLintPrePushTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="cmux-web-lint-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.repo = self.root / "repository"
        self.origin = self.root / "origin.git"
        self.global_config = self.root / "gitconfig"
        self.global_config.write_text("[user]\n\tname = Fixture\n\temail = fixture@example.com\n")
        self.eslint_log = self.root / "eslint.log"
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith("GIT_") and key not in AGENT_VARS}
        self.env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=str(self.global_config),
                        HOME=str(self.root), ESLINT_LOG=str(self.eslint_log))
        git_fixture_env.without_auto_maintenance(self.env)

        subprocess.run(["git", "init", "--quiet", "--bare", "--initial-branch=feat-cmux-next", str(self.origin)],
                       env=self.env, check=True, capture_output=True)
        self.repo.mkdir()
        self.git("init", "--quiet", "--initial-branch=feat-cmux-next")
        self.git("remote", "add", "origin", str(self.origin))
        self.copy_sources()
        self.write("webviews/package.json", WEBVIEWS_PACKAGE)
        self.write("webviews/check-lanes.sh", CHECK_LANES)
        self.write("webviews/check-format.sh", CHECK_FORMAT)
        self.write("webviews/fix-format.sh", FIX_FORMAT)
        self.write("webviews/src/app.ts", "export const app = 1;\n")
        self.write("webviews/test/app.test.ts", "export const t = 1;\n")
        self.write("web/package.json", '{"name": "web-fixture"}\n')
        self.write("web/app/page.tsx", "export const page = 1;\n")
        self.write("web/app/other.tsx", "export const other = BAD_ESLINT;\n")  # web/ is red on base
        self.write(".gitignore", "node_modules/\n")
        self.commit("base")
        eslint = self.repo / "web/node_modules/.bin/eslint"
        eslint.parent.mkdir(parents=True)
        eslint.write_text(FAKE_ESLINT)
        eslint.chmod(0o755)
        self.git("push", "--quiet", "--no-verify", "origin", "feat-cmux-next")
        self.git("fetch", "--quiet", "origin")
        installed = subprocess.run(["bash", INSTALLER], cwd=self.repo, env=self.env, text=True, capture_output=True)
        self.assertEqual(installed.returncode, 0, installed.stderr)

    def copy_sources(self):
        for relative in (
            "scripts/git-hooks",
            INSTALLER,
            "scripts/web_lint_prepush.py",
            "scripts/cmux-next/prepush-gate.py",
            "scripts/ci/base_merge_warning.py",
            "scripts/web-lint.sh",
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
        ):
            source, target = SOURCE / relative, self.repo / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            if source.is_dir():
                shutil.copytree(source, target)
            else:
                shutil.copyfile(source, target)
                shutil.copymode(source, target)

    def git(self, *args, check=True):
        return subprocess.run(["git", "-C", str(self.repo), *args], env=self.env,
                              text=True, capture_output=True, check=check)

    def write(self, relative, text):
        path = self.repo / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def commit(self, message):
        self.git("add", "-A")
        self.git("commit", "--quiet", "--no-verify", "-m", message)

    def push(self, **env):
        return subprocess.run(["git", "-C", str(self.repo), "push", "origin", "feat-cmux-next"],
                              env={**self.env, **env}, text=True, capture_output=True)

    def logged_trees(self):
        """GIT_TRACE for the run, which every git under the hook inherits (a PATH shim would not: git puts
        its exec-path first for hooks); returns (env, a reader of the `git worktree add` calls). A lint tree
        is a full checkout, 913 MB on cmux."""
        log = self.root / "git-trace.log"

        def trees():
            lines = log.read_text().splitlines() if log.exists() else []
            return [line for line in lines if "built-in: git" in line and " worktree add " in line]
        return {"GIT_TRACE": str(log)}, trees

    def test_a_push_with_nothing_to_lint_builds_no_lint_tree(self):
        # A dirty checkout and a Swift-only push: the plan is empty, so no full checkout is written.
        self.write("Sources/App.swift", "let a = 1\n")
        self.commit("swift only")
        self.write("notes.txt", "untracked\n")
        env, trees = self.logged_trees()

        result = self.push(**env)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(trees(), [])

    def test_the_trace_sees_a_lint_tree_when_one_is_needed(self):
        self.write("webviews/src/app.ts", "export const app = 5;\n")
        self.commit("web change")
        self.write("notes.txt", "untracked\n")
        env, trees = self.logged_trees()

        result = self.push(**env)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(trees()), 1)

    def test_a_dry_run_builds_no_lint_tree(self):
        self.write("webviews/src/app.ts", "export const app = 4;\n")
        self.commit("web change")
        self.write("notes.txt", "untracked\n")
        env, trees = self.logged_trees()
        head = self.git("rev-parse", "HEAD").stdout.strip()

        result = subprocess.run([sys.executable, "scripts/web_lint_prepush.py", "--dry-run", "--base", "HEAD~1",
                                 "--head", head], cwd=self.repo, env={**self.env, **env}, text=True,
                                capture_output=True)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("webviews: sh check-lanes.sh && sh check-format.sh", result.stdout)
        self.assertEqual(trees(), [])

    def remote_head(self):
        return subprocess.run(["git", "-C", str(self.origin), "rev-parse", "feat-cmux-next"],
                              env=self.env, text=True, capture_output=True).stdout.strip()

    def test_default_install_adds_the_pre_push_hook(self):
        hooks = Path(self.git("config", "--get", "core.hooksPath").stdout.strip())
        self.assertTrue(os.access(hooks / "pre-push", os.X_OK))
        self.assertTrue((hooks / "web_lint_prepush.py").is_file())

    def test_push_with_a_webviews_lint_error_is_refused_with_the_fix_command(self):
        before = self.remote_head()
        self.write("webviews/test/app.test.ts", "export const t = BAD_LANE;\n")
        self.commit("bad lane")

        result = self.push()

        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.remote_head(), before, "the bad commit must not reach origin")
        self.assertIn("web lint failed", result.stderr)
        self.assertIn("browser lane import", result.stderr, "must show the failing check's output")
        self.assertIn("scripts/web-lint.sh --fix", result.stderr, "must name the exact fix command")

    def test_clean_webviews_push_passes_and_reports_its_time(self):
        self.write("webviews/src/app.ts", "export const app = 2;\n")
        self.commit("clean change")

        result = self.push()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertRegex(result.stderr, r"web lint passed in \d+\.\ds \(webviews\)")
        self.assertEqual(self.remote_head(), self.git("rev-parse", "HEAD").stdout.strip())

    def test_push_without_web_changes_runs_no_lint(self):
        self.write("webviews/src/app.ts", "export const app = BAD_LANE;\n")
        self.commit("red webviews already on origin")
        self.assertEqual(self.push(CMUX_WEB_LINT_SKIP_REASON="fixture: seed a red base on origin first").returncode, 0)
        self.write("README.md", "docs only\n")
        self.commit("docs")

        result = self.push()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("web lint", result.stderr)

    def test_a_lint_error_in_the_pushed_commit_is_refused_when_the_working_tree_has_the_fix(self):
        # The fix is made but not committed: linting the working tree passed this push (0b115ab).
        before = self.remote_head()
        self.write("webviews/src/app.ts", "export const app = BAD_LANE;\n")
        self.commit("bad lane")
        self.write("webviews/src/app.ts", "export const app = 3;\n")

        result = self.push()

        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.remote_head(), before, "the bad commit must not reach origin")
        self.assertIn("browser lane import", result.stderr)

    def test_a_clean_pushed_commit_passes_whatever_the_working_tree_holds(self):
        self.write("webviews/src/app.ts", "export const app = 3;\n")
        self.write("web/app/page.tsx", "export const page = 3;\n")
        self.commit("clean")
        self.write("webviews/src/app.ts", "export const app = BAD_LANE;\n")  # uncommitted, not pushed
        self.write("webviews/src/draft.ts", "export const draft = BAD_FORMAT;\n")  # untracked, not pushed
        self.write("web/app/page.tsx", "export const page = BAD_ESLINT;\n")

        result = self.push()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.remote_head(), self.git("rev-parse", "HEAD").stdout.strip())
        self.assertIn("BAD_LANE", (self.repo / "webviews/src/app.ts").read_text(), "the working tree is left alone")

    def test_pushing_a_branch_that_is_not_checked_out_lints_that_branch(self):
        self.git("checkout", "--quiet", "-b", "side")
        self.write("web/app/page.tsx", "export const page = BAD_ESLINT;\n")
        self.commit("bad web on side")
        self.git("checkout", "--quiet", "feat-cmux-next")
        before = self.remote_head()

        result = subprocess.run(["git", "-C", str(self.repo), "push", "origin", "side:feat-cmux-next"],
                                env=self.env, text=True, capture_output=True)

        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.remote_head(), before)
        self.assertIn("app/page.tsx: error no-bad", result.stderr)

    def test_a_lint_tree_shares_node_modules_only_when_it_installs_the_same_thing(self):
        lint = load_lint(self.repo)
        self.write("pkg/package.json", '{"dependencies": {"b": "file:../bindings"}}\n')
        self.write("pkg/bun.lock", "lock 1\n")
        self.write("bindings/index.ts", "export const b = 1;\n")
        self.commit("pkg")
        (self.repo / "pkg/node_modules").mkdir()
        head = self.git("rev-parse", "HEAD").stdout.strip()
        self.assertTrue(lint.shares_deps(self.repo, head, "pkg"))
        for path, text in (("pkg/bun.lock", "lock 2\n"), ("pkg/package.json", '{"dependencies": {}}\n'),
                           ("bindings/index.ts", "export const b = 2;\n")):
            with self.subTest(path=path):
                before = (self.repo / path).read_text()
                self.write(path, text)
                self.commit(f"change {path}")
                pushed = self.git("rev-parse", "HEAD").stdout.strip()
                self.git("checkout", "--quiet", "HEAD~1")
                self.assertFalse(lint.shares_deps(self.repo, pushed, "pkg"), path)
                self.git("checkout", "--quiet", "feat-cmux-next")
                self.write(path, before)
                self.commit(f"restore {path}")
        (self.repo / "pkg/node_modules").rmdir()
        self.assertFalse(lint.shares_deps(self.repo, self.git("rev-parse", "HEAD").stdout.strip(), "pkg"))

    def test_eslint_in_a_lint_tree_keeps_no_cache(self):
        # The cache is keyed by absolute path: a random tree path misses every time and prunes the checkout's.
        lint = load_lint(self.repo)
        self.assertIn("--cache", lint.eslint_command(self.repo, "web", ["web/a.ts"], False))
        self.assertNotIn("--cache", lint.eslint_command(self.repo, "web", ["web/a.ts"], False, cache=False))

    def test_web_eslint_checks_only_the_changed_files(self):
        self.write("web/app/page.tsx", "export const page = 2;\n")
        self.commit("touch one web file")

        result = self.push()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.eslint_log.read_text().split(), ["app/page.tsx"],
                         "the red file nobody touched must not be linted")

    def test_web_eslint_error_in_a_changed_file_is_refused(self):
        self.write("web/app/page.tsx", "export const page = BAD_ESLINT;\n")
        self.commit("bad web")

        result = self.push()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("app/page.tsx: error no-bad", result.stderr)

    def test_fix_option_repairs_what_the_tools_can_fix(self):
        self.write("webviews/src/app.ts", "export const app = BAD_FORMAT;\n")
        self.write("web/app/page.tsx", "export const page = BAD_ESLINT;\n")

        fixed = subprocess.run(["scripts/web-lint.sh", "--fix"], cwd=self.repo, env=self.env,
                               text=True, capture_output=True)

        self.assertEqual(fixed.returncode, 0, fixed.stderr)
        self.assertIn("good_format", (self.repo / "webviews/src/app.ts").read_text())
        self.assertIn("good_eslint", (self.repo / "web/app/page.tsx").read_text())

    def test_skip_needs_a_reason_that_names_the_evidence(self):
        self.write("webviews/src/app.ts", "export const app = BAD_LANE;\n")
        self.commit("bad")

        short = self.push(CMUX_WEB_LINT_SKIP_REASON="base red")
        self.assertNotEqual(short.returncode, 0)

        skipped = self.push(CMUX_WEB_LINT_SKIP_REASON="check-lanes is red on base abc1234 too")
        self.assertEqual(skipped.returncode, 0, skipped.stderr)
        self.assertIn("web lint skipped: check-lanes is red on base abc1234 too", skipped.stderr)

    def test_hook_does_not_run_check_code_the_push_changes(self):
        # A pushed branch could carry any check script; the hook must not run it.
        marker = self.root / "ran"
        self.write("webviews/check-lanes.sh", f"#!/bin/sh\ntouch {marker}\n")
        self.commit("change a check script")

        result = self.push()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(marker.exists(), "the hook ran a check script from the pushed branch")
        self.assertIn("not linted here", result.stderr)
        self.assertIn("webviews/check-lanes.sh", result.stderr)


if __name__ == "__main__":
    unittest.main()
