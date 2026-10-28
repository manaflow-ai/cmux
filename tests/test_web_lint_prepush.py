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

    def test_an_all_run_builds_the_bindings_before_the_frontend_check_and_is_clean(self):
        self.add_tui_packages()

        result, calls = self.lint_all()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("TS2307", result.stderr)
        self.assertIn("web lint passed", result.stderr)
        tui = [c for c in calls if not c.endswith("@ webviews")]
        self.assertEqual(tui, ["npm ci --no-audit --no-fund @ typescript", "npm run build @ typescript",
                               "bun install --silent --no-save @ web", "check web"])

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


if __name__ == "__main__":
    unittest.main()
