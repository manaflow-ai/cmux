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
