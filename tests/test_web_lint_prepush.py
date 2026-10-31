#!/usr/bin/env python3
"""The pre-push hook runs the web lints on what a push changes, and stops a bad push.

Each test builds a throwaway repository with stand-in web packages (a
package.json `check` script and an `eslint` executable that fail on the word
BAD), installs the hooks with scripts/install-git-hooks.sh, and pushes to a
bare `origin` through the real `git push`, so the installed trusted hook copy is
what runs.
"""
import io
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import sys
import unittest
from unittest import mock
import git_fixture_env  # disables git auto maintenance


SOURCE = Path(__file__).resolve().parents[1]
INSTALLER = "scripts/install-git-hooks.sh"
AGENT_VARS = ("CMUX_AGENT", "CMUX_REQUIRE_FORMATTERS", "CI", "CLAUDECODE", "CODEX_CI", "CODEX_THREAD_ID",
              "CODEX_SANDBOX", "CMUX_WEB_LINT_SKIP_REASON", "CMUX_LOCAL_HEAVY_CHECKS")
# A host that runs no heavy checks, outside CI: CI (CI or GITHUB_ACTIONS=true) always runs every piece, so a test
# run on a CI runner must clear both or it would test CI's behaviour instead.
LIGHT_HOST = {"CMUX_LOCAL_HEAVY_CHECKS": "0", "CI": "", "GITHUB_ACTIONS": ""}

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
            "scripts/ci/fast_gate_webviews_checks.py",
            "scripts/cmux-next/prepush-gate.py",
            "scripts/cmux-next/push_range.py",
            "scripts/cmux-next/git_batch.py",
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
        self.assertIn("webviews: sh check-lanes.sh\nwebviews: sh check-format.sh\n", result.stdout)
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

    def test_a_rebased_branch_force_push_lints_only_its_own_files(self):
        # The branch is pushed once, then rebased onto a base that gained a web lint error (someone pushed it
        # with --no-verify). The remote head sits on the old base: a range from its merge base with the new head
        # would lint upstream's file and refuse the branch for it.
        self.git("checkout", "--quiet", "-b", "topic")
        self.write("web/app/page.tsx", "export const page = 2;\n")
        self.commit("topic web change")
        self.assertEqual(self.git("push", "--quiet", "--no-verify", "origin", "topic").returncode, 0)
        self.git("checkout", "--quiet", "feat-cmux-next")
        self.write("web/app/upstream.tsx", "export const upstream = BAD_ESLINT;\n")
        self.commit("someone else's lint error on the base")
        self.git("push", "--quiet", "--no-verify", "origin", "feat-cmux-next")
        self.git("fetch", "--quiet", "origin")
        self.git("checkout", "--quiet", "topic")
        self.git("rebase", "--quiet", "origin/feat-cmux-next")

        result = subprocess.run(["git", "-C", str(self.repo), "push", "--force", "origin", "topic"],
                                env=self.env, text=True, capture_output=True)

        self.assertEqual(result.returncode, 0, result.stderr)
        linted = self.eslint_log.read_text() if self.eslint_log.exists() else ""
        self.assertIn("app/page.tsx", linted, "the branch's own file is linted")
        self.assertNotIn("upstream.tsx", linted, "a file only the rebased-over commits change is not")

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

    def lint_range(self, *extra):
        """web_lint_prepush.py on HEAD~1..HEAD, as the fast gates run it on a pull request merged with its base."""
        head = self.git("rev-parse", "HEAD").stdout.strip()
        return subprocess.run([sys.executable, "scripts/web_lint_prepush.py", "--base", "HEAD~1", "--head", head,
                               *extra], cwd=self.repo, env=self.env, text=True, capture_output=True)

    def test_new_only_fails_on_a_new_error_over_a_base_that_is_red_with_another(self):
        # The base is red with one finding; the change adds a second. Per job both runs are just "red"; per error
        # the second is the change's (Leo, 2026-10-21: why should web lint and type check hide errors?).
        self.write("webviews/src/old.ts", "export const old = BAD_LANE;\n")
        self.commit("a red base")
        self.write("webviews/test/new.test.ts", "export const t = BAD_LANE;\n")
        self.commit("adds a second red")

        result = self.lint_range("--new-only")

        self.assertEqual(result.returncode, 1, result.stderr)
        added = result.stderr.split("adds over the base", 1)[1]
        self.assertIn("test/new.test.ts", added)
        self.assertNotIn("src/old.ts", added)

    def test_new_only_charges_a_red_with_nothing_to_compare(self):
        # A check that fails on the base and here but prints no finding (nothing, or only a run's totals) explains
        # nothing; matching two empty lists must not pass it off as the base's red.
        for name, prints in (("empty", ""), ("only noise", "echo 'Found 0 errors and 0 warnings in 1 files'")):
            with self.subTest(output=name):
                self.write("webviews/check-lanes.sh",
                           f"#!/bin/sh\nif grep -rl 'SILENT_RED' src >/dev/null 2>&1; then {prints}\nexit 1; fi\n")
                self.write("webviews/src/old.ts", "export const old = SILENT_RED;\n")
                self.commit(f"a silent red base ({name})")
                self.write("webviews/src/app.ts", f"export const app = '{name}';\n")
                self.commit(f"a change on the silent red base ({name})")

                result = self.lint_range("--new-only")

                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn("printed no finding to compare with the base", result.stderr)

    def test_new_only_keeps_a_red_the_base_has_as_a_warning(self):
        self.write("webviews/src/old.ts", "export const old = BAD_LANE;\n")
        self.commit("a red base")
        self.write("webviews/src/app.ts", "export const app = 3;\n")
        self.commit("a clean change on the red base")

        self.assertEqual(self.lint_range().returncode, 1, "without --new-only every red is the push's")
        result = self.lint_range("--new-only")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("::warning title=web lint (base)::webviews: sh check-lanes.sh", result.stderr)

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

    # webviews' check, cut down: a light python3 check, a nested script that mixes an allowlisted bun source check
    # with a type-aware lint (as check:effect-cleanup is), the formatter check, and the type check.
    HEAVY_CHECK = ('"python3 scripts/check_lanes.py && bun run check:nested && vp fmt --check && vp check --no-fmt --no-lint"')
    NESTED = '"bun scripts/check-design.ts && vp lint --config scripts/lint/x.json src"'
    CHECK_LANES_PY = "import pathlib, sys\nsys.exit(1 if 'BAD_LANE' in pathlib.Path('src/app.ts').read_text() else 0)\n"

    # webviews' real shape since #24438: `check` is the run-check-pieces.py runner and the chain is `check:pieces`.
    RUNNER_CHECK = ('"python3 ../scripts/cmux-next/run-check-pieces.py", "check:pieces": ' + HEAVY_CHECK)

    def heavy_fixture(self, check=None):
        """webviews' check gains the heavy pieces; stand-ins for vp and bun log each call with its niceness and Go
        thread cap. Seeded on origin, so the push under test changes only source; returns that push's env (outside
        CI) and the log."""
        self.write("webviews/package.json", WEBVIEWS_PACKAGE.replace(
            '"sh check-lanes.sh && sh check-format.sh"', check or self.HEAVY_CHECK).replace(
            '"check:fix": "sh fix-format.sh"', f'"check:fix": "vp check --fix", "check:nested": {self.NESTED}'))
        self.write("webviews/scripts/check_lanes.py", self.CHECK_LANES_PY)
        self.commit("heavy pieces")
        seeded = self.push(CMUX_WEB_LINT_SKIP_REASON="fixture: seed the heavy pieces on origin first")
        self.assertEqual(seeded.returncode, 0, seeded.stderr)
        bin_dir = self.repo / "webviews/node_modules/.bin"
        bin_dir.mkdir(parents=True)
        for name in ("vp", "bun"):
            (bin_dir / name).write_text(f'#!/bin/sh\necho "{name} $* nice=$(ps -o nice= -p $$ | tr -d " ") GOMAXPROCS=$GOMAXPROCS" >> "$VP_LOG"\n')
            (bin_dir / name).chmod(0o755)
        self.write("webviews/src/app.ts", "export const app = 7;\n")
        self.commit("source change")
        log = self.root / "vp.log"
        env = {key: value for key, value in self.env.items() if key not in ("GITHUB_ACTIONS", "CI")}
        env["VP_LOG"] = str(log)
        return env, log

    def push_with(self, env):
        return subprocess.run(["git", "-C", str(self.repo), "push", "origin", "feat-cmux-next"],
                              env=env, text=True, capture_output=True)

    def logged(self, log):
        return [line.split(" nice=")[0] for line in log.read_text().splitlines()] if log.exists() else []

    def test_a_host_that_runs_no_heavy_checks_runs_only_the_allowlist(self):
        env, log = self.heavy_fixture()

        result = self.push_with({**env, "CMUX_LOCAL_HEAVY_CHECKS": "0"})

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sorted(self.logged(log)), ["bun scripts/check-design.ts", "vp fmt --check"])
        self.assertIn("not run on this host (CMUX_LOCAL_HEAVY_CHECKS=0): vp lint --config scripts/lint/x.json src, "
                      "vp check --no-fmt --no-lint", result.stderr)
        self.assertIn("cmux-ci test", result.stderr, "must say where to run it instead")
        self.assertRegex(result.stderr, r"web lint passed in \d+\.\ds \(webviews\)")

    def test_a_host_that_runs_no_heavy_checks_runs_only_the_allowlisted_pieces_of_the_check_runner(self):
        # webviews' `check` is `python3 ../scripts/cmux-next/run-check-pieces.py` (#24438). The light host resolves
        # it through `check:pieces` and runs only the allowlisted pieces, never the runner as one opaque command
        # (which would run vp lint and vp check too).
        env, log = self.heavy_fixture(self.RUNNER_CHECK)

        result = self.push_with({**env, "CMUX_LOCAL_HEAVY_CHECKS": "0"})

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sorted(self.logged(log)), ["bun scripts/check-design.ts", "vp fmt --check"])
        self.assertIn("not run on this host (CMUX_LOCAL_HEAVY_CHECKS=0): vp lint --config scripts/lint/x.json src, "
                      "vp check --no-fmt --no-lint", result.stderr)
        self.assertNotIn("run-check-pieces.py", result.stderr)

    def test_light_pieces_still_refuse_a_bad_push_on_a_host_that_runs_no_heavy_checks(self):
        env, log = self.heavy_fixture()
        self.write("webviews/src/app.ts", "export const app = BAD_LANE;\n")
        self.commit("bad lane")

        result = self.push_with({**env, "CMUX_LOCAL_HEAVY_CHECKS": "0"})

        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertIn("python3 scripts/check_lanes.py", result.stderr)
        self.assertNotIn("vp check --no-fmt --no-lint", self.logged(log))

    def test_a_build_host_runs_every_piece_niced_and_capped(self):
        env, log = self.heavy_fixture()

        result = self.push_with(env)

        self.assertEqual(result.returncode, 0, result.stderr)
        calls = log.read_text().splitlines()
        self.assertIn("bun run check:nested", [c.split(" nice=")[0] for c in calls])
        self.assertIn("vp check --no-fmt --no-lint", [c.split(" nice=")[0] for c in calls])
        for call in calls:
            self.assertRegex(call, r" nice=\d+ GOMAXPROCS=\d+$")
            self.assertGreaterEqual(int(call.split("nice=")[1].split()[0]), 10, call)

    def spawned(self, argv, heavy):
        """Run the lint in process with every subprocess.run recorded and none but git executed (a stand-in answers
        the rest, failing the python3 check when the tree it runs in has BAD_LANE); returns (exit code, the commands
        spawned, nice stripped)."""
        lint = load_lint(self.repo)
        real = subprocess.run
        seen = []

        def spy(command, *args, **kwargs):
            words = command.split() if isinstance(command, str) else [str(w) for w in command]
            if words and Path(words[0]).name == "nice":
                words = words[3:]
            if words and Path(words[0]).name == "git":
                return real(command, *args, **kwargs)
            seen.append(" ".join(Path(words[0]).name if i == 0 else w for i, w in enumerate(words)))
            cwd = Path(kwargs.get("cwd") or ".")
            failed = words[:1] == ["python3"] and "BAD_LANE" in (cwd / "src/app.ts").read_text()
            return subprocess.CompletedProcess(command, 1 if failed else 0,
                                               "src/app.ts:1:1: error lane\n" if failed else "", "")

        env = {"CMUX_LOCAL_HEAVY_CHECKS": "1" if heavy else "0", "GITHUB_ACTIONS": "", "CI": ""}
        with mock.patch.dict(os.environ, env), mock.patch.object(lint.subprocess, "run", spy), \
                mock.patch("sys.stderr", new_callable=lambda: open(os.devnull, "w")):
            code = lint.main(["--repo", str(self.repo), *argv])
        return code, seen

    def test_no_mode_spawns_more_than_the_allowlist_on_a_host_that_runs_no_heavy_checks(self):
        self.heavy_fixture()
        (self.repo / "web/node_modules").mkdir(exist_ok=True)
        self.write("web/app/page.tsx", "export const page = 3;\n")
        self.commit("web change")
        head = self.git("rev-parse", "HEAD").stdout.strip()
        self.write("webviews/src/app.ts", "export const app = BAD_LANE;\n")
        self.write("webviews/package.json", (self.repo / "webviews/package.json").read_text().replace(
            '"name": "webviews-fixture"', '"name": "webviews-changed"'))  # a base tree cannot share node_modules
        self.commit("red change")
        red = self.git("rev-parse", "HEAD").stdout.strip()
        allowed = {"python3 scripts/check_lanes.py", "bun scripts/check-design.ts", "vp fmt --check",
                   "eslint --quiet --no-warn-ignored --cache --cache-location node_modules/.cache/eslint-web-lint/ "
                   "app/page.tsx", "eslint --quiet --no-warn-ignored app/page.tsx",
                   "eslint --quiet --no-warn-ignored --cache --cache-location node_modules/.cache/eslint-web-lint/ "
                   "--fix app/page.tsx"}  # web/'s ESLint is syntax-only (no type information)
        modes = {
            "checked-out --head": ["--base", "HEAD~1", "--head", red],
            "another commit (lint tree)": ["--base", "HEAD~2", "--head", head],
            "--new-only on a red change": ["--base", "HEAD~1", "--head", red, "--new-only"],
            "--all": ["--all", "--base", red, "--head", red],
            "--fix": ["--fix", "--base", "HEAD~2"],
        }
        for name, argv in modes.items():
            with self.subTest(mode=name):
                code, seen = self.spawned(argv, heavy=False)
                self.assertTrue(seen, "the allowlisted checks must still run")
                self.assertLessEqual(set(seen), allowed, seen)
        code, seen = self.spawned(modes["--new-only on a red change"], heavy=False)
        self.assertEqual(code, 1, "with no base comparison the red stays the change's")

    def test_a_dry_run_lists_exactly_what_a_run_spawns(self):
        # Reviews of 91644bb and 7d129c5: the dry run skipped light_plan() and the --fix passes. Both now come from
        # plan_steps(). For every cell of {light, full} x {fix, no fix} x {checked-out head, lint tree}, the dry run's
        # lines equal the commands the run spawns: setup and fix passes in order, then the checks (which run in
        # parallel) as a set. A package without node_modules is in neither in light mode.
        self.heavy_fixture()
        self.write("web/app/page.tsx", "export const page = 4;\n")
        self.write("webviews/src/app.ts", "export const app = 9;\n")
        self.write("cmux-tui/frontends/web/package.json", '{"name": "tui", "scripts": {"check": "vp fmt --check"}}\n')
        self.write("cmux-tui/frontends/web/src/main.ts", "export const main = 1;\n")  # no node_modules
        self.commit("web, webviews and tui changes")
        head = self.git("rev-parse", "HEAD").stdout.strip()
        lint = load_lint(self.repo)

        def normal(area, words):
            return f"{Path(area).name}: {' '.join([Path(words[0]).name, *words[1:]])}"

        def phase(line):
            area, command = line.split(": ", 1)
            if area == "typescript":
                return 0  # the bindings build
            if command.startswith(("bun install", "npm ci")):
                return 1
            if "--fix" in command.split():
                return 2
            return 3

        def spy_run(argv, env):
            real = subprocess.run
            spawned = []

            def spy(command, *args, **kwargs):
                words = command.split() if isinstance(command, str) else [str(w) for w in command]
                if words and Path(words[0]).name == "nice":
                    words = words[3:]
                if words[:2] == ["/bin/sh", "-c"]:
                    words = words[2].split()
                if Path(words[0]).name == "git":
                    return real(command, *args, **kwargs)
                spawned.append(normal(kwargs["cwd"], words))
                return subprocess.CompletedProcess(command, 0, "", "")

            with mock.patch.dict(os.environ, env), mock.patch.object(lint.subprocess, "run", spy), \
                    mock.patch.object(lint, "build_current", lambda repo, build: False), \
                    mock.patch("sys.stderr", new_callable=lambda: open(os.devnull, "w")):
                lint.main(["--repo", str(self.repo), *argv])
            return spawned

        cells = 0
        for heavy in ("0", "1"):
            for fix in (False, True):
                for where in ("checked-out head", "lint tree"):
                    if fix and where == "lint tree":
                        continue  # --fix edits the working tree itself, never a lint tree
                    argv = (["--fix", "--base", "HEAD~1"] if fix else
                            ["--base", "HEAD~1" if where == "checked-out head" else "HEAD~2", "--head", head])
                    with self.subTest(heavy=heavy, fix=fix, where=where):
                        if where == "lint tree":
                            self.git("checkout", "--quiet", "HEAD~1")
                        env = {"CMUX_LOCAL_HEAVY_CHECKS": heavy, "GITHUB_ACTIONS": "", "CI": ""}
                        # The dry run first: the run writes build and install stamps, which change what comes next.
                        with mock.patch.dict(os.environ, env), \
                                mock.patch.object(lint, "build_current", lambda repo, build: False), \
                                mock.patch("sys.stdout", new_callable=io.StringIO) as out, \
                                mock.patch("sys.stderr", new_callable=lambda: open(os.devnull, "w")):
                            lint.main(["--repo", str(self.repo), "--dry-run", *argv])
                        spawned = spy_run(argv, env)
                        listed = [normal(line.split(": ", 1)[0], shlex.split(line.split(": ", 1)[1]))
                                  for line in out.getvalue().splitlines()]
                        self.assertTrue(listed)
                        self.assertEqual(sorted(listed), sorted(spawned))
                        # Phases, as run_plan runs them: builds (in order), installs (in parallel), fix passes (in
                        # order), checks (in parallel). Each list keeps the phases in that order, and the in-order
                        # phases match line for line.
                        for commands in (listed, spawned):
                            phases = [phase(line) for line in commands]
                            self.assertEqual(phases, sorted(phases), commands)
                        for ordered in (0, 2):
                            self.assertEqual([c for c in listed if phase(c) == ordered],
                                             [c for c in spawned if phase(c) == ordered])
                        if heavy == "0":
                            self.assertFalse([line for line in listed if line.startswith("web: vp")], listed)
                            self.assertFalse([line for line in listed if " install" in line], listed)
                        if fix:
                            self.assertTrue(ordered, "a --fix run lists its fix passes")
                        self.git("checkout", "--quiet", "feat-cmux-next")
                        cells += 1
        self.assertEqual(cells, 6)

    def test_every_spawn_on_a_build_host_is_niced_and_capped(self):
        self.heavy_fixture()
        lint = load_lint(self.repo)
        real = subprocess.run
        spawned = []

        def spy(command, *args, **kwargs):
            words = command.split() if isinstance(command, str) else [str(w) for w in command]
            if Path(words[0]).name != "git":
                spawned.append((words, kwargs.get("env") or {}))
                return subprocess.CompletedProcess(command, 0, "", "")
            return real(command, *args, **kwargs)

        head = self.git("rev-parse", "HEAD").stdout.strip()
        with mock.patch.dict(os.environ, {"CMUX_LOCAL_HEAVY_CHECKS": "1", "GITHUB_ACTIONS": "", "CI": ""}), \
                mock.patch.object(lint.subprocess, "run", spy), \
                mock.patch("sys.stderr", new_callable=lambda: open(os.devnull, "w")):
            lint.main(["--repo", str(self.repo), "--base", "HEAD~1", "--head", head])
        self.assertTrue(spawned)
        for words, env in spawned:
            self.assertEqual(Path(words[0]).name, "nice", words)
            self.assertIn("GOMAXPROCS", env)
            self.assertIn("GOMEMLIMIT", env)
            self.assertIn("--max-old-space-size", env.get("NODE_OPTIONS", ""))

    def test_new_only_reruns_a_piece_on_the_base_niced_and_capped(self):
        # Both the head and the base fail `vp lint` with the same finding: the base rerun is a second type check,
        # so it gets the same nice and caps as the first.
        self.write("webviews/package.json", WEBVIEWS_PACKAGE.replace(
            '"sh check-lanes.sh && sh check-format.sh"', '"vp lint"'))
        self.commit("a heavy check")
        vp = self.repo / "webviews/node_modules/.bin/vp"
        vp.parent.mkdir(parents=True)
        vp.write_text('#!/bin/sh\necho "vp nice=$(ps -o nice= -p $$ | tr -d " ") GOMAXPROCS=$GOMAXPROCS" >> "$VP_LOG"\n'
                      'echo "src/app.ts:1:1: error same-finding"; exit 1\n')
        vp.chmod(0o755)
        self.write("webviews/src/app.ts", "export const app = 8;\n")
        self.commit("a change on a red base")
        log = self.root / "vp.log"
        env = {key: value for key, value in self.env.items() if key not in ("GITHUB_ACTIONS", "CI")}
        head = self.git("rev-parse", "HEAD").stdout.strip()

        result = subprocess.run([sys.executable, "scripts/web_lint_prepush.py", "--base", "HEAD~1", "--head", head,
                                 "--new-only"], cwd=self.repo, env={**env, "VP_LOG": str(log)}, text=True,
                                capture_output=True)

        calls = log.read_text().splitlines()
        self.assertEqual(len(calls), 2, (calls, result.stderr))
        for call in calls:
            self.assertRegex(call, r"^vp nice=\d+ GOMAXPROCS=\d+$")
            self.assertGreaterEqual(int(call.split("nice=")[1].split()[0]), 10, call)

    def test_the_allowlist_is_exact(self):
        lint = load_lint(self.repo)
        webviews = lint.SCRIPT_PACKAGES[0]
        scripts = {"check:effect-cleanup": "vp lint --config scripts/lint/effect-cleanup.json src dev-server",
                   "check:nested": "bun run check:effect-cleanup", "check:fixed-waits": "bun scripts/check-fixed-waits.ts",
                   "check:layers": "python3 ../scripts/cmux-next/check-layers.py", "loop": "bun run loop"}
        light, rest = lint.light_leaves(webviews, [
            "bun run check:fixed-waits", "bun run check:layers", "vp fmt --check", "bun run check:nested",
            "python3 -I ../scripts/cmux-next/check-dialog-key-hints.py ..",
            "vp lint", "vp check --no-fmt --no-lint", "tsc -p .", "sh check.sh", "bun run no-such-script",
            "bun ../escape.ts", "bun scripts/../x.ts", "bun run loop", "node x.js", "bun install",
            "vp fmt --check --write", "vp fmt"], scripts)
        self.assertEqual(light, ["bun scripts/check-fixed-waits.ts", "python3 ../scripts/cmux-next/check-layers.py",
                                 "vp fmt --check", "python3 -I ../scripts/cmux-next/check-dialog-key-hints.py .."])
        self.assertEqual(rest, ["vp lint --config scripts/lint/effect-cleanup.json src dev-server", "vp lint",
                                "vp check --no-fmt --no-lint", "tsc -p .", "sh check.sh", "bun run no-such-script",
                                "bun ../escape.ts", "bun scripts/../x.ts", "bun run loop", "node x.js", "bun install",
                                "vp fmt --check --write", "vp fmt"])

    def test_ci_runs_every_piece_even_where_the_host_says_no_heavy_checks(self):
        lint = load_lint(self.repo)
        for ci in ({"CI": "true"}, {"GITHUB_ACTIONS": "true"}):
            with self.subTest(ci=ci), mock.patch.dict(os.environ, {"CMUX_LOCAL_HEAVY_CHECKS": "0", "CI": "",
                                                                    "GITHUB_ACTIONS": "", **ci}):
                self.assertTrue(lint.local_heavy_checks())
        with mock.patch.dict(os.environ, {"CMUX_LOCAL_HEAVY_CHECKS": "0", "CI": "", "GITHUB_ACTIONS": ""}):
            self.assertFalse(lint.local_heavy_checks())

    def test_a_bun_found_through_a_relative_path_entry_installs(self):
        lint = load_lint(self.repo)
        ran = []
        found = lambda name: "node_modules/.bin/bun" if name in ("bun", "node_modules/.bin/bun") else None
        with mock.patch.object(lint.shutil, "which", found), mock.patch.object(
                lint, "run_leaving_no_lockfile",
                lambda command, cwd: ran.append(command) or subprocess.CompletedProcess(command, 0, "", "")):
            self.assertIsNone(lint.ensure_deps(self.repo, "webviews", force=True))
        self.assertEqual(ran[0][0], "node_modules/.bin/bun")
        with mock.patch.object(lint.shutil, "which", lambda name: None):
            missing = lint.ensure_deps(self.repo, "webviews", force=True)
        self.assertIn("bun is not on PATH", missing.output)

    def test_a_nested_check_runner_resolves_to_its_pieces(self):
        lint = load_lint(self.repo)
        webviews = lint.SCRIPT_PACKAGES[0]
        scripts = {"check:sub": "python3 ../scripts/cmux-next/run-check-pieces.py",
                   "check:sub:pieces": "vp fmt --check && vp lint"}
        self.assertEqual(lint.light_leaves(webviews, ["bun run check:sub"], scripts), (["vp fmt --check"], ["vp lint"]))

    def test_python3_and_bun_are_light_only_for_a_guarded_source_check_script(self):
        # Review of 3811e05: any shell-free `python3 ...` was light, so `python3 -m pip install ..` ran there.
        lint = load_lint(self.repo)
        webviews = lint.SCRIPT_PACKAGES[0]
        for piece in ("python3", "python3 -I", "python3 -m pip install requests", "python3 -m compileall .",
                      "python3 -c print(1)", "python3 -u scripts/x.py", "python3 -I -m pip install x",
                      "python3 check.py", "python3 src/check.py", "python3 /tmp/scripts/x.py",
                      "python3 ../../x/scripts/x.py", "python3 ../web/scripts/x.py", "python3 scripts/x.sh",
                      "python3 scripts/", "bun", "bun scripts/x.js", "bun -e scripts/x.ts",
                      "bun ../escape/scripts/x.ts", "bun x.ts", "bun scripts/../x.ts",
                      # Review of bead8b5: under src/, test/ or tests/ a push may change the script and still be
                      # linted, so the hook would run the changed code.
                      "bun src/scripts/evil.ts", "python3 test/scripts/x.py", "bun tests/scripts/x.ts",
                      "python3 -I src/lint/scripts/x.py"):
            with self.subTest(piece=piece):
                self.assertFalse(lint.is_light(piece, webviews))
        for piece in ("python3 scripts/check.py", "python3 -I scripts/check.py --root ..",
                      "python3 ../scripts/cmux-next/check-layers.py", "bun scripts/check-fixed-waits.ts",
                      "bun scripts/lint/x.ts"):
            with self.subTest(piece=piece):
                self.assertTrue(lint.is_light(piece, webviews))

    def test_every_light_script_is_one_the_hook_refuses_to_lint_when_a_push_changes_it(self):
        lint = load_lint(self.repo)
        for package in lint.SCRIPT_PACKAGES:
            for piece in ("bun scripts/a.ts", "bun src/scripts/a.ts", "python3 test/scripts/a.py",
                          "python3 ../scripts/cmux-next/a.py", "bun dev-server/scripts/a.ts"):
                argv = lint.light_argv(piece)
                if not lint.light_script(package, argv):
                    continue
                path = lint.posixpath.normpath(lint.posixpath.join(package.directory, argv[-1]))
                with self.subTest(package=package.directory, piece=piece):
                    plan = lint.make_plan(self.repo, [path], guard_executed=True, exists=lambda rel: True)
                    self.assertIn(package.directory, [directory for directory, _ in plan.untrusted], path)

    def test_a_light_prefix_cannot_carry_another_command(self):
        lint = load_lint(self.repo)
        for piece in ("python3 noop.py ; vp lint", "python3 a.py | vp lint", "python3 $(vp lint)", "python3 `vp lint`",
                      "python3 a.py || vp lint", "python3 a.py & vp lint", "python3 a.py\nvp lint",
                      "vp fmt --check > /dev/null; vp check", "python3 'a.py' ; tsc", "bun scripts/a.ts;tsc"):
            with self.subTest(piece=piece):
                self.assertFalse(lint.is_light(piece, lint.SCRIPT_PACKAGES[0]))
                self.assertEqual(lint.light_leaves(lint.SCRIPT_PACKAGES[0], [piece], {}), ([], [piece]))

    def test_a_shell_bypass_runs_nothing_heavy_on_a_host_that_runs_no_heavy_checks(self):
        # The reviewer's repro: an allowlisted prefix followed by `; vp lint`. Light pieces run as argument lists,
        # never through a shell, so the second command cannot start.
        env, log = self.heavy_fixture()
        package = (self.repo / "webviews/package.json").read_text().replace(
            '"python3 scripts/check_lanes.py && ',
            '"python3 scripts/check_lanes.py ; vp lint && python3 scripts/check_lanes.py && ')
        self.write("webviews/package.json", package)
        self.commit("a shell bypass in the check script")
        head = self.git("rev-parse", "HEAD").stdout.strip()
        code, seen = self.spawned(["--base", "HEAD~1", "--head", head], heavy=False)
        self.assertNotIn("vp lint", " ".join(seen))
        self.assertIn("python3 scripts/check_lanes.py", seen)

    def test_light_pieces_spawn_with_no_shell(self):
        self.heavy_fixture()
        lint = load_lint(self.repo)
        real = subprocess.run
        shells = []

        def spy(command, *args, **kwargs):
            words = command.split() if isinstance(command, str) else [str(w) for w in command]
            if Path(words[0]).name == "git":
                return real(command, *args, **kwargs)
            shells.append((isinstance(command, str) or kwargs.get("shell", False), " ".join(words)))
            return subprocess.CompletedProcess(command, 0, "", "")

        head = self.git("rev-parse", "HEAD").stdout.strip()
        with mock.patch.dict(os.environ, {"CMUX_LOCAL_HEAVY_CHECKS": "0", "GITHUB_ACTIONS": "", "CI": ""}), \
                mock.patch.object(lint.subprocess, "run", spy), \
                mock.patch("sys.stderr", new_callable=lambda: open(os.devnull, "w")):
            lint.main(["--repo", str(self.repo), "--base", "HEAD~1", "--head", head])
        self.assertTrue(shells)
        self.assertEqual([c for shell, c in shells if shell], [], "a light piece must never run through a shell")

    def test_a_niced_shell_string_keeps_its_meaning_and_every_command_is_niced(self):
        # `nice` in front of a shell string read `VAR=1` as the program (exit 127), and niced only the first
        # command of `a; b`. The whole shell runs niced instead.
        lint = load_lint(self.repo)
        probe = self.root / "probe.py"
        probe.write_text("import os, sys\nprint(os.environ.get('CHECK_MODE', '-'), os.nice(0))\n")
        env = {"PATH": os.environ["PATH"]}
        with mock.patch.dict(os.environ, {"GITHUB_ACTIONS": "", "CI": ""}):
            assigned = lint.spawn(f"CHECK_MODE=1 {sys.executable} {probe}", self.root, env)
            compound = lint.spawn(f"true; {sys.executable} {probe}", self.root, env)
        self.assertEqual(assigned.returncode, 0, assigned.stderr)
        mode, nice = assigned.stdout.split()
        floor = min(19, os.nice(0) + 10)  # relative to this process, which may itself run niced
        self.assertEqual(mode, "1")
        self.assertGreaterEqual(int(nice), floor)
        self.assertGreaterEqual(int(compound.stdout.split()[1]), floor, compound.stdout)

    def test_ci_spawns_as_is_and_a_caller_cap_is_kept(self):
        lint = load_lint(self.repo)
        with mock.patch.object(lint.subprocess, "run") as run, \
                mock.patch.dict(os.environ, {"GITHUB_ACTIONS": "true"}):
            lint.spawn("vp lint", self.repo, {"PATH": os.environ["PATH"]})
        self.assertEqual(run.call_args.args[0], "vp lint")
        self.assertNotIn("GOMAXPROCS", run.call_args.kwargs["env"])
        with mock.patch.object(lint.subprocess, "run") as run, \
                mock.patch.dict(os.environ, {"GITHUB_ACTIONS": "", "CI": ""}):
            lint.spawn(["vp", "lint"], self.repo, {"GOMAXPROCS": "3", "NODE_OPTIONS": "--max-old-space-size=1024"})
        argv, env = run.call_args.args[0], run.call_args.kwargs["env"]
        self.assertEqual(argv[-2:], ["vp", "lint"])
        self.assertEqual((env["GOMAXPROCS"], env["NODE_OPTIONS"]), ("3", "--max-old-space-size=1024"))
        self.assertEqual(env["GOMEMLIMIT"], lint.HEAVY_GOMEMLIMIT)


# cmux-tui/frontends/web imports `cmux` from file:../../bindings/typescript, whose exports point at a
# tsc-built dist/. Without that build its check printed 85 TS2307 "cannot find module 'cmux/raw'" errors.
TUI_FRONTEND_PACKAGE = """{
  "name": "tui-frontend-fixture",
  "dependencies": {"cmux": "file:../../bindings/typescript"},
  "scripts": {"check": "sh check.sh", "check:fix": "true"}
}
"""
TUI_FRONTEND_CHECK = """#!/bin/sh
echo "check $(basename "$PWD")" >> "$TOOL_LOG"
if [ ! -e node_modules/cmux/dist/src/index.d.ts ]; then echo "error TS2307: Cannot find module 'cmux/raw'"; exit 2; fi
if ! cmp -s node_modules/cmux/dist/src/index.d.ts ../../bindings/typescript/dist/src/index.d.ts; then
  echo 'checked against stale bindings'; exit 3
fi
echo 'types ok'
"""
BINDINGS_PACKAGE = '{"name": "cmux-sdk", "scripts": {"build": "tsc"}}\n'
# Stand-ins that log each call; a build writes dist/ (fails when FAKE_BUILD_FAIL is set), and a bun install
# copies a file: dependency into node_modules as it is at install time, as bun does.
FAKE_BUILD = """build() {
  if [ -n "$FAKE_BUILD_FAIL" ]; then echo "src/raw/index.ts(3,1): error TS1005: ';' expected."; exit 2; fi
  mkdir -p dist/src && cat src/raw/index.ts > dist/src/index.d.ts
}
"""
FAKE_NPM = "#!/bin/sh\n" + FAKE_BUILD + """echo "npm $* @ $(basename "$PWD")" >> "$TOOL_LOG"
case "$1" in
  ci) rm -rf node_modules && mkdir node_modules ;;
  run) [ "$2" = build ] && build ;;
esac
exit 0
"""
FAKE_BUN = "#!/bin/sh\n" + FAKE_BUILD + """echo "bun $* @ $(basename "$PWD")" >> "$TOOL_LOG"
case "$1" in
  install)
    if [ -n "$FAKE_INSTALL_FAIL" ] && [ "$(basename "$PWD")" = web ]; then echo 'error: install failed'; exit 1; fi
    mkdir -p node_modules
    [ -f package-lock.json ] && echo 'lockfileVersion = 1' > bun.lock  # bun writes one on migration
    if grep -q 'file:../../bindings/typescript' package.json; then
      rm -rf node_modules/cmux && mkdir -p node_modules/cmux
      [ -d ../../bindings/typescript/dist ] && cp -R ../../bindings/typescript/dist node_modules/cmux/
    fi ;;
  run) [ "$3" = build ] && build ;;
esac
exit 0
"""


# An allowlisted light piece (python3) that logs its call.
FMT_PY = "import os, pathlib\nwith open(os.environ['TOOL_LOG'], 'a') as log:\n    log.write(f'fmt {pathlib.Path.cwd().name}\\n')\n"


class TuiBindingsTests(unittest.TestCase):
    """The tui frontend's check runs only after its TypeScript bindings are installed and built."""

    setUp = WebLintPrePushTests.setUp
    copy_sources = WebLintPrePushTests.copy_sources
    git = WebLintPrePushTests.git
    write = WebLintPrePushTests.write
    commit = WebLintPrePushTests.commit

    def add_tui_packages(self, npm=True):
        self.write("cmux-tui/frontends/web/package.json", TUI_FRONTEND_PACKAGE)
        self.write("cmux-tui/frontends/web/check.sh", TUI_FRONTEND_CHECK)
        self.write("cmux-tui/frontends/web/src/main.ts", "export const main = 1;\n")
        self.write("cmux-tui/bindings/typescript/package.json", BINDINGS_PACKAGE)
        self.write("cmux-tui/bindings/typescript/package-lock.json", "{}\n")
        self.write("cmux-tui/bindings/typescript/tsconfig.json", "{}\n")
        self.write("cmux-tui/bindings/typescript/src/raw/index.ts", "export const raw = 1;\n")
        self.write("cmux-tui/bindings/typescript/.gitignore", "dist/\n")
        self.commit("tui packages")
        self.tool_log = self.root / "tools.log"
        tools = self.root / ("bin-npm" if npm else "bin-bun")
        tools.mkdir()
        for name, text in (("npm", FAKE_NPM), ("bun", FAKE_BUN)) if npm else (("bun", FAKE_BUN),):
            (tools / name).write_text(text)
            (tools / name).chmod(0o755)
        for name, target in (("python3", sys.executable), ("git", shutil.which("git"))):
            (tools / name).symlink_to(target)
        # No real npm, node or bun: only the stand-ins, so the order of the calls is the test.
        self.env.update(PATH=f"{tools}{os.pathsep}/usr/bin{os.pathsep}/bin", TOOL_LOG=str(self.tool_log))

    def lint_all(self, **env):
        self.tool_log.write_text("")
        result = subprocess.run(["scripts/web-lint.sh", "--all"], cwd=self.repo, env={**self.env, **env},
                                text=True, capture_output=True)
        return result, self.tool_log.read_text().splitlines()

    def test_a_stale_build_with_no_build_tool_stops_the_run_even_when_nothing_else_needs_setup(self):
        # Review of 9fee5123: with neither npm nor bun, a stale bindings build spawns nothing, and a frontend that has
        # node_modules and no bun.lock installs nothing, so setup_steps() was empty and run_plan() skipped
        # prepare_builds(): the check ran against the old bindings. ensure_build()'s failure must stop the run, and
        # the dry run must say so instead of listing checks the run never reaches.
        self.add_tui_packages(npm=False)
        (self.repo / "cmux-tui/frontends/web/node_modules/cmux").mkdir(parents=True)
        lint = load_lint(self.repo)
        # The frontend's copy came from these very inputs, so it needs no install; the build output is gone.
        stamp = lint.installed_stamp(self.repo, "cmux-tui/frontends/web", lint.TUI_BINDINGS)
        stamp.parent.mkdir(parents=True)
        stamp.write_text(lint.build_digest(self.repo, lint.TUI_BINDINGS))
        plan = lint.make_plan(self.repo, ["cmux-tui/frontends/web/src/main.ts"], guard_executed=False)
        real = shutil.which
        no_tools = lambda name, *a, **k: None if name in ("npm", "bun") else real(name, *a, **k)
        with mock.patch.object(lint.shutil, "which", no_tools), \
                mock.patch.dict(os.environ, {"TOOL_LOG": str(self.tool_log), "CI": "", "GITHUB_ACTIONS": ""}):
            self.tool_log.write_text("")
            _, setup, fixes, jobs = lint.plan_steps(self.repo, plan, False, True, True, "web-lint")
            results = lint.run_plan(self.repo, plan, fix=False)

        self.assertEqual([(r.label, r.returncode) for r in results], [("cmux-tui/bindings/typescript", 127)])
        self.assertIn("neither npm nor bun is on PATH", results[0].output)
        self.assertNotIn("check web", self.tool_log.read_text(), "the check must not run against stale bindings")
        self.assertEqual((fixes, jobs), ([], []))
        self.assertEqual(len(setup), 1)
        self.assertIn("neither npm nor bun is on PATH", lint.shown(setup[0]))

    def test_an_all_run_builds_the_bindings_before_the_frontend_check_and_is_clean(self):
        self.add_tui_packages()

        result, calls = self.lint_all()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("TS2307", result.stderr)
        self.assertIn("web lint passed", result.stderr)
        tui = [c for c in calls if not c.endswith("@ webviews")]
        self.assertEqual(tui, ["npm ci --no-audit --no-fund @ typescript", "npm run build @ typescript",
                               "bun install --silent --no-save @ web", "check web"])

    def test_a_host_that_runs_no_heavy_checks_installs_and_builds_nothing(self):
        # The bindings build is `npm ci` plus tsc: on such a host no npm, no bun install, no build and no tsc runs.
        # A package that already has node_modules still runs its light pieces; one with none is left to CI, named.
        self.add_tui_packages()
        self.write("cmux-tui/frontends/web/package.json", TUI_FRONTEND_PACKAGE.replace(
            '"check": "sh check.sh"', '"check": "python3 scripts/fmt.py && vp check --no-fmt --no-lint && tsc -p ."'))
        self.write("cmux-tui/frontends/web/scripts/fmt.py", FMT_PY)
        self.commit("a heavy frontend check")
        tools = Path(self.env["PATH"].split(os.pathsep)[0])
        for name in ("tsc", "vp"):
            (tools / name).write_text(f'#!/bin/sh\necho "{name} $*" >> "$TOOL_LOG"\n')
            (tools / name).chmod(0o755)

        result, calls = self.lint_all(**LIGHT_HOST)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, [], "nothing may install, build or check a package that has no node_modules")
        self.assertIn("cmux-tui/frontends/web: not linted here, it has no node_modules", result.stderr)

        (self.repo / "cmux-tui/frontends/web/node_modules").mkdir()
        result, calls = self.lint_all(**LIGHT_HOST)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([c for c in calls if not c.endswith("@ webviews")], ["fmt web"])
        self.assertIn("cmux-tui/bindings/typescript: not built here", result.stderr)

    def test_the_bindings_build_runs_niced_and_capped_outside_ci(self):
        self.add_tui_packages()
        tools = Path(self.env["PATH"].split(os.pathsep)[0])
        npm = tools / "npm"
        npm.write_text(FAKE_NPM.replace('echo "npm $* @ $(basename "$PWD")" >> "$TOOL_LOG"',
                                        'echo "npm $* @ $(basename "$PWD") nice=$(ps -o nice= -p $$ | tr -d " ") GOMAXPROCS=$GOMAXPROCS" '
                                        '>> "$TOOL_LOG"'))

        result, calls = self.lint_all(GITHUB_ACTIONS="", CI="")  # outside CI, even on a CI runner

        self.assertEqual(result.returncode, 0, result.stderr)
        built = [c for c in calls if c.startswith("npm")]
        self.assertEqual(len(built), 2, calls)
        for call in built:
            self.assertRegex(call, r"nice=\d+ GOMAXPROCS=\d+$")
            self.assertGreaterEqual(int(call.split("nice=")[1].split()[0]), 10, call)

    def test_a_lint_tree_on_a_host_that_runs_no_heavy_checks_shares_the_frontend_node_modules(self):
        # --head of a commit other than the checkout's runs in a lint tree; with nothing built there, the frontend
        # shares the checkout's node_modules and its light piece still runs.
        self.add_tui_packages()
        self.write("cmux-tui/frontends/web/package.json", TUI_FRONTEND_PACKAGE.replace(
            '"check": "sh check.sh"', '"check": "python3 scripts/fmt.py && vp check --no-fmt --no-lint"'))
        self.write("cmux-tui/frontends/web/scripts/fmt.py", FMT_PY)
        self.commit("a heavy frontend check")
        (self.repo / "cmux-tui/frontends/web/node_modules").mkdir()
        self.write("cmux-tui/frontends/web/src/main.ts", "export const main = 2;\n")
        self.commit("frontend change")
        head = self.git("rev-parse", "HEAD").stdout.strip()
        self.git("checkout", "--quiet", "HEAD~1")
        self.tool_log.write_text("")

        result = subprocess.run([sys.executable, "scripts/web_lint_prepush.py", "--base", "HEAD", "--head", head],
                                cwd=self.repo, env={**self.env, **LIGHT_HOST}, text=True,
                                capture_output=True)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("fmt web", self.tool_log.read_text().splitlines())
        self.assertNotIn("not linted here", result.stderr)

    def test_a_dry_run_for_a_lint_tree_lists_the_builds_and_installs_that_tree_needs(self):
        # Review of c146f28: with the bindings built and installed in the checkout, a dry run of a commit that runs in
        # a fresh lint tree listed only the check, while the run built and installed first (the tree has no dist/
        # and no node_modules of its own). The dry run now plans that tree.
        self.add_tui_packages()
        self.assertEqual(self.lint_all()[0].returncode, 0)  # the checkout's bindings built and installed
        self.write("cmux-tui/frontends/web/src/main.ts", "export const main = 2;\n")
        self.commit("frontend change")
        head = self.git("rev-parse", "HEAD").stdout.strip()
        self.write("notes.txt", "dirty\n")  # not exactly HEAD: the run happens in a lint tree

        dry = subprocess.run(["scripts/web-lint.sh", "--dry-run", "--base", "HEAD~1", "--head", head], cwd=self.repo,
                             env=self.env, text=True, capture_output=True)
        self.assertEqual(dry.returncode, 0, dry.stderr)
        listed = [(line.split(": ", 1)[0], " ".join([Path(shlex.split(line.split(": ", 1)[1])[0]).name,
                                                    *shlex.split(line.split(": ", 1)[1])[1:]]))
                  for line in dry.stdout.splitlines()]
        self.tool_log.write_text("")
        ran = subprocess.run(["scripts/web-lint.sh", "--base", "HEAD~1", "--head", head], cwd=self.repo,
                             env=self.env, text=True, capture_output=True)
        self.assertEqual(ran.returncode, 0, ran.stderr)
        calls = self.tool_log.read_text().splitlines()
        self.assertEqual([c for c in calls if c.startswith(("npm", "bun install"))],
                         ["npm ci --no-audit --no-fund @ typescript", "npm run build @ typescript",
                          "bun install --silent --no-save @ web"], "the run in a lint tree builds and installs")
        self.assertEqual([command for directory, command in listed],
                         ["npm ci --no-audit --no-fund", "npm run build", "bun install --silent --no-save", "sh check.sh"])
        self.assertEqual([directory for directory, _ in listed][:2], ["cmux-tui/bindings/typescript"] * 2)

    def test_a_current_bindings_build_is_not_rebuilt_and_a_source_change_rebuilds_it(self):
        self.add_tui_packages()
        self.assertEqual(self.lint_all()[0].returncode, 0)

        result, calls = self.lint_all()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse([c for c in calls if c.startswith("npm")], calls)
        self.assertIn("check web", calls)

        self.write("cmux-tui/bindings/typescript/src/raw/index.ts", "export const raw = 2;\n")
        result, calls = self.lint_all()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("npm run build @ typescript", calls)
        # The frontend's copy of the bindings is refreshed after a rebuild.
        self.assertLess(calls.index("npm run build @ typescript"), calls.index("bun install --silent --no-save @ web"))

    def test_a_failed_bindings_build_is_one_named_result_not_a_wall_of_ts2307(self):
        self.add_tui_packages()

        result, calls = self.lint_all(FAKE_BUILD_FAIL="1")

        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("TS2307", result.stderr)
        self.assertIn("cmux-tui/bindings/typescript", result.stderr)
        self.assertIn("error TS1005", result.stderr, "must show the build's own error")
        self.assertIn("cmux-tui/frontends/web", result.stderr, "must name the check it holds back")
        self.assertNotIn("check web", calls)

    def test_a_failed_frontend_install_after_a_rebuild_is_retried_not_checked_against_the_old_copy(self):
        self.add_tui_packages()
        self.assertEqual(self.lint_all()[0].returncode, 0)  # warm: built, installed, stamped
        self.write("cmux-tui/bindings/typescript/src/raw/index.ts", "export const raw = 2;\n")

        failed, _ = self.lint_all(FAKE_INSTALL_FAIL="1")  # rebuilt, but the frontend keeps its old copy
        self.assertNotEqual(failed.returncode, 0)

        result, calls = self.lint_all()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("stale bindings", result.stderr)
        self.assertNotIn("npm run build @ typescript", calls, "the build itself is current")
        self.assertIn("bun install --silent --no-save @ web", calls, "the frontend's old copy must be replaced")

    def test_a_bun_lockfile_in_the_bindings_invalidates_the_build(self):
        self.add_tui_packages(npm=False)
        self.assertEqual(self.lint_all()[0].returncode, 0)
        for name in ("bun.lock", "bun.lockb"):
            with self.subTest(name=name):
                self.write(f"cmux-tui/bindings/typescript/{name}", f"{name} selects other versions\n")

                result, calls = self.lint_all()

                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("bun run --bun build @ typescript", calls)

    def test_without_npm_bun_builds_the_bindings_and_leaves_no_lockfile(self):
        self.add_tui_packages(npm=False)

        result, calls = self.lint_all()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("bun run --bun build @ typescript", calls)
        self.assertLess(calls.index("bun run --bun build @ typescript"), calls.index("check web"))
        self.assertEqual(self.git("status", "--porcelain").stdout, "", "the run must not leave a bun.lock behind")

    def test_a_bindings_change_runs_the_frontend_check_and_the_hook_skips_a_changed_build_config(self):
        self.add_tui_packages()
        lint = load_lint(self.repo)

        plan = lint.make_plan(self.repo, ["cmux-tui/bindings/typescript/src/raw/index.ts"], guard_executed=True)
        self.assertEqual([p.directory for p in plan.script_packages], ["cmux-tui/frontends/web"])

        plan = lint.make_plan(self.repo, ["cmux-tui/bindings/typescript/package.json"], guard_executed=True)
        self.assertEqual(plan.script_packages, [])
        self.assertEqual(plan.untrusted, [("cmux-tui/frontends/web", ["cmux-tui/bindings/typescript/package.json"])])

    def test_the_hook_skips_a_push_that_changes_a_bindings_bun_lockfile(self):
        # The bun fallback installs from it and runs the compiler it selects: code the check runs.
        self.add_tui_packages()
        lint = load_lint(self.repo)
        for name in ("bun.lock", "bun.lockb"):
            with self.subTest(name=name):
                path = f"cmux-tui/bindings/typescript/{name}"

                plan = lint.make_plan(self.repo, [path], guard_executed=True)

                self.assertEqual(plan.script_packages, [])
                self.assertEqual(plan.untrusted, [("cmux-tui/frontends/web", [path])])


class CheckPiecesTests(unittest.TestCase):
    """`bun run check` runs every piece and fails at the end: a red text-focus guard (2026-10-22) stopped the
    `&&` chain before fmt, lint and the type check, so they never reported."""

    RUNNER = SOURCE / "scripts/cmux-next/run-check-pieces.py"

    def run_pieces(self, chain):
        with tempfile.TemporaryDirectory(prefix="cmux-check-pieces-") as temporary:
            package = Path(temporary)
            (package / "package.json").write_text(json.dumps({"scripts": {"check:pieces": chain}}))
            return subprocess.run([sys.executable, "-I", str(self.RUNNER)], cwd=package, text=True,
                                  capture_output=True)

    def test_a_red_piece_does_not_stop_the_ones_after_it(self):
        result = self.run_pieces("echo first && false && echo after-the-red && sh -c 'exit 3' && echo last")
        self.assertEqual(result.returncode, 1)
        for line in ("first", "after-the-red", "last"):
            self.assertIn(line, result.stdout)
        self.assertIn("2 red:", result.stderr)
        self.assertIn("  false", result.stderr)
        self.assertIn("  sh -c 'exit 3'", result.stderr)

    def test_all_green_passes(self):
        result = self.run_pieces("true && echo ok")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_webviews_check_runs_its_pieces_and_the_list_keeps_fmt_lint_and_types(self):
        scripts = json.loads((SOURCE / "webviews/package.json").read_text())["scripts"]
        self.assertEqual(scripts["check"], "python3 ../scripts/cmux-next/run-check-pieces.py")
        pieces = [piece.strip() for piece in scripts["check:pieces"].split("&&")]
        for piece in ("bun run check:text-focus", "vp fmt --check", "vp lint", "vp check --no-fmt --no-lint"):
            self.assertIn(piece, pieces)

    def test_the_prepush_lint_reads_the_pieces_list(self):
        lint = load_lint(SOURCE)
        package = lint.ScriptPackage(directory="webviews", triggers=("webviews/",), executed=())
        manifest = json.dumps({"scripts": {"check": "python3 run.py", "check:pieces": "a && b"}})
        self.assertEqual(lint.check_pieces(SOURCE, package, "check", lambda rel: manifest), ["a", "b"])
        manifest = json.dumps({"scripts": {"check": "a && b"}})
        self.assertEqual(lint.check_pieces(SOURCE, package, "check", lambda rel: manifest), ["a", "b"])


if __name__ == "__main__":
    unittest.main()
