#!/usr/bin/env python3
"""react-apps-check fails a pull request only on webview tests it turns red; the base's reds are warnings.

About 25 browser tests were red on feat-cmux-next for every pull request, so #23090 (2026-10-21) landed
2 new reds unseen among them: agent-pane-peer-chat and agent-pane-working-counts, fixed by #23164.
scripts/ci/webviews-tests-new-reds.sh runs each file red on the head again in a checkout of the base
and compares per test name (scripts/ci/guards_new_reds.py). A fake `bun` stands in for the real one:
a test file's `FAIL <name>` lines are the tests it fails, `CRASH` makes it fail before naming any,
`HANG` makes it time out, `SCOPED` crashes it like prScope.ts does when CMUX_PR_CHANGED_FILES is
set and HEAD^1 is missing (the base checkout: the job fetched only the merge commit and its parents),
`FLAKY` fails `sometimes` on its first run only (a test red only under the shard's load),
`CROWDED` fails `crowded` when another test file runs at the same time,
and `RULE` fails `the rules hold` as a prScope rule test with findings does unless
CMUX_NEXT_STYLE_GUARDS=warn. `bun install` leaves a fake Playwright whose install exits
FAKE_PLAYWRIGHT_STATUS.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
WRAPPER = ROOT / "scripts/ci/webviews-tests-new-reds.sh"
COLLECT = ROOT / "scripts/ci/webviews_test_results.py"
COMPARE = ROOT / "scripts/ci/guards_new_reds.py"
WORKFLOW = ROOT / ".github/workflows/ci-web.yml"

FAKE_BUN = """#!/usr/bin/env bash
if [ "$1" = install ]; then
  mkdir -p node_modules/.bin
  printf '#!/bin/sh\nexit "${FAKE_PLAYWRIGHT_STATUS:-0}"\n' > node_modules/.bin/playwright
  chmod +x node_modules/.bin/playwright
  exit "${FAKE_BUN_INSTALL_STATUS:-0}"
fi
[ "$1" = test ] || exit 9
file="${!#}"  # bun test [--timeout MS] ./FILE
if grep -q '^CRASH' "$file"; then echo "error: Cannot find module './gone'"; exit 1; fi
if grep -q '^HANG' "$file"; then sleep 30; fi
if grep -q '^SCOPED' "$file" && [ -n "${CMUX_PR_CHANGED_FILES:-}" ] && ! git rev-parse -q --verify HEAD^1 > /dev/null; then
  echo "error: git diff HEAD^1 HEAD"; exit 1
fi
status=0
stamp="$(git rev-parse --git-common-dir)/ran-$(basename "$file")"
if grep -q '^FLAKY' "$file" && [ ! -e "$stamp" ]; then touch "$stamp"; echo "(fail) sometimes [5.00ms]"; status=1; fi
running="$(git rev-parse --git-common-dir)/running"
if grep -q '^CROWDED' "$file"; then
  mkdir -p "$running" && touch "$running/$$" && sleep 1
  if [ "$(ls "$running" | wc -l)" -gt 1 ]; then echo "(fail) crowded [5.00ms]"; status=1; fi
  rm "$running/$$"
fi
if grep -q '^RULE' "$file" && [ "${CMUX_NEXT_STYLE_GUARDS:-}" != warn ]; then echo "(fail) the rules hold [3.00ms]"; status=1; fi
while read -r word name; do
  if [ "$word" = FAIL ]; then echo "(fail) $name [12.50ms]"; status=1; fi
done < "$file"
echo "(pass) the rest [1.00ms]"
exit "$status"
"""

# The (fail) lines of #23090's react-apps-check (1), job 119088076516: ctrl-b and the location strip
# were red on the base too; peer-chat and working-counts were the change's.
SHARD_1 = {
    "test/agent-pane-ctrl-b-background.test.ts": [
        "with no running call, Ctrl-B stays the composer's and asks nothing",
        "a Codex chat shows no hint and keeps Ctrl-B",
    ],
    "test/agent-pane-peer-chat.test.ts": [
        "a chat on an SSH machine > counts its running turn from the prompt and offers no machine switch mid-chat",
    ],
    "test/agent-pane-working-counts.test.ts": ["(unnamed)"],
    "test/composer-location-strip.test.ts": [
        "the chat composer at 420 px: the strip's marks line up with the prompt's edges",
        "the chat composer at 760 px: the strip's marks line up with the prompt's edges",
    ],
}
BASE_REDS = ("test/agent-pane-ctrl-b-background.test.ts", "test/composer-location-strip.test.ts")


def body(fails):
    return "".join(f"FAIL {name}\n" for name in fails) + "it('passes', () => {})\n"


class Wrapper(unittest.TestCase):
    def run_pr(self, base_files, head_files, base_ref="HEAD^1", install_status=0, extra_env=None, file_timeout="10"):
        """A base commit and the change on top; the wrapper runs from the head's webviews/."""
        temp = Path(self.enterContext(tempfile.TemporaryDirectory()))
        repo = temp / "repo"
        git = lambda *args: subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True)
        (repo / "webviews").mkdir(parents=True)
        bundles = repo / "scripts/cmux-next/build-web-bundles.sh"
        bundles.parent.mkdir(parents=True)
        bundles.write_text("#!/bin/sh\necho built > \"$(dirname \"$0\")/../../webviews/.built\"\n")
        bundles.chmod(0o755)
        git("init", "-q")
        for files in (base_files, head_files):
            for name in {**base_files, **head_files}:
                path = repo / "webviews" / name
                if name in files:
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_text(files[name])
                elif path.exists():
                    path.unlink()
            git("add", "-A")
            git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "c")
        bin_dir = temp / "bin"
        bin_dir.mkdir()
        (bin_dir / "bun").write_text(FAKE_BUN)
        (bin_dir / "bun").chmod(0o755)
        env = {k: v for k, v in os.environ.items() if k not in ("CMUX_BROWSER_TESTS", "GITHUB_ACTIONS")}
        env.update(PATH=f"{bin_dir}:{os.environ['PATH']}", CMUX_WEB_TEST_FILE_TIMEOUT=file_timeout, CMUX_WEB_TEST_JOBS="4",
                   FAKE_BUN_INSTALL_STATUS=str(install_status), TMPDIR=str(temp), **(extra_env or {}))
        args = ["bash", str(WRAPPER)] + ([base_ref] if base_ref else [])
        done = subprocess.run(args, cwd=repo / "webviews", env=env, capture_output=True, text=True, timeout=60)
        self.assertEqual(sorted(p.name for p in temp.iterdir()), ["bin", "repo"], "left scratch behind")
        return done, done.stdout + done.stderr

    def shard_1(self):
        head = {name: body(fails) for name, fails in SHARD_1.items()}
        base = {name: body(SHARD_1[name] if name in BASE_REDS else []) for name in SHARD_1}
        return base, head

    def test_the_23090_case_fails_on_its_two_new_reds_only(self):
        base, head = self.shard_1()
        done, out = self.run_pr(base, head)
        self.assertEqual(done.returncode, 1, out)
        self.assertIn("::error title=Webview test red on this change::test/agent-pane-peer-chat.test.ts > a chat on an SSH "
                      "machine > counts its running turn from the prompt and offers no machine switch mid-chat", out)
        self.assertIn("::error title=Webview test red on this change::test/agent-pane-working-counts.test.ts > (unnamed)", out)
        self.assertEqual(out.count("::error title=Webview test red on this change::"), 2, out)
        self.assertIn("::warning title=Webview test red on the base too::test/agent-pane-ctrl-b-background.test.ts > "
                      "a Codex chat shows no hint and keeps Ctrl-B", out)
        self.assertEqual(out.count("::warning title=Webview test red on the base too::"), 4, out)

    def test_base_reds_never_fail_a_pull_request(self):
        base, _ = self.shard_1()
        done, out = self.run_pr(base, dict(base))
        self.assertEqual(done.returncode, 0, out)
        self.assertNotIn("::error", out)
        self.assertEqual(out.count("::warning title=Webview test red on the base too::"), 4, out)

    def test_a_new_red_test_in_a_base_red_file_is_the_changes(self):
        base = {"test/a.test.ts": body(["old red"])}
        done, out = self.run_pr(base, {"test/a.test.ts": body(["old red", "new red"])})
        self.assertEqual(done.returncode, 1, out)
        self.assertIn("::error title=Webview test red on this change::test/a.test.ts > new red", out)
        self.assertIn("::warning title=Webview test red on the base too::test/a.test.ts > old red", out)

    def test_a_file_that_never_got_to_its_tests_on_the_base_says_nothing_about_them(self):
        for broken in ("CRASH\n", "HANG\n"):
            with self.subTest(broken.strip()):
                done, out = self.run_pr({"test/a.test.ts": broken}, {"test/a.test.ts": body(["new red"])}, file_timeout="2")
                self.assertEqual(done.returncode, 1, out)
                self.assertIn("::error title=Webview test red on this change::test/a.test.ts > new red", out)

    def test_the_base_reruns_every_red_file_whatever_the_shard(self):
        files = {f"test/{n}.test.ts": body(["old red"]) for n in "abcd"}
        done, out = self.run_pr(files, dict(files),
                                extra_env={"CMUX_WEB_TEST_SHARD": "1", "CMUX_WEB_TEST_SHARD_COUNT": "2"})
        self.assertEqual(done.returncode, 0, out)
        self.assertNotIn("::error", out)
        self.assertEqual(out.count("::warning title=Webview test red on the base too::"), 2, out)

    def test_the_changes_files_do_not_reach_the_base_run(self):
        files = {"test/a.test.ts": "SCOPED\n" + body(["old red"])}
        done, out = self.run_pr(files, dict(files), extra_env={"CMUX_PR_CHANGED_FILES": "webviews/src/x.gallery.tsx"})
        self.assertEqual(done.returncode, 0, out)
        self.assertIn("::warning title=Webview test red on the base too::test/a.test.ts > old red", out)

    def test_a_file_red_only_beside_the_others_is_a_warning(self):
        done, out = self.run_pr({"test/a.test.ts": body([])}, {"test/a.test.ts": "FLAKY\n" + body([])})
        self.assertEqual(done.returncode, 0, out)
        self.assertNotIn("::error", out)
        self.assertIn("passed only when run alone (failed or timed out beside other files):\n  test/a.test.ts", out)
        self.assertNotIn("the red files again on the base", out)

    def test_a_flaky_file_keeps_its_steady_reds(self):
        # A file that fails again alone keeps the reds of that run alone, as the base runs it.
        done, out = self.run_pr({"test/a.test.ts": body([])}, {"test/a.test.ts": "FLAKY\n" + body(["new red"])})
        self.assertEqual(done.returncode, 1, out)
        self.assertIn("::error title=Webview test red on this change::test/a.test.ts > new red", out)
        self.assertNotIn("test/a.test.ts > sometimes", out)

    def test_files_red_only_beside_each_other_are_not_the_changes(self):
        # composer-draft-wrap timed out beside the other red files when they reran together and passed
        # on the base, which reran it with nothing else (#23209's react-apps-check (1), 7a2323c9).
        files = {f"test/{n}.test.ts": "CROWDED\n" + body([]) for n in "ab"}
        done, out = self.run_pr({name: body([]) for name in files}, files)
        self.assertEqual(done.returncode, 0, out)
        self.assertNotIn("::error", out)
        # However many of them started close enough to crowd each other.
        self.assertGreaterEqual(out.count("(first run: FAIL)"), 1, out)
        self.assertNotIn("the red files again on the base", out)

    def test_the_bases_rule_findings_do_not_hide_the_changes_own(self):
        # On a main PR (CMUX_NEXT_STYLE_GUARDS=fail) the head's ui-rules test fails on the change's own
        # finding only; the base, unscoped, would fail the same test on the findings it already has.
        done, out = self.run_pr({"test/ui-rules.test.ts": "RULE\n" + body([])},
                                {"test/ui-rules.test.ts": body(["the rules hold"])},
                                extra_env={"CMUX_NEXT_STYLE_GUARDS": "fail"})
        self.assertEqual(done.returncode, 1, out)
        self.assertIn("::error title=Webview test red on this change::test/ui-rules.test.ts > the rules hold", out)

    def test_a_base_without_its_own_playwright_engines_makes_every_red_the_changes(self):
        # A change that bumps Playwright: the base's version has no engines on this runner, so its
        # browser tests would all be red and match the head's.
        base = {"test/a.test.ts": body(["old red"])}
        done, out = self.run_pr(base, dict(base), extra_env={"FAKE_PLAYWRIGHT_STATUS": "1"})
        self.assertEqual(done.returncode, 1, out)
        self.assertIn("the base did not set up", out)

    def test_a_new_file_that_fails_is_the_changes(self):
        done, out = self.run_pr({"test/a.test.ts": body([])}, {"test/a.test.ts": body([]), "test/b.test.ts": body(["x"])})
        self.assertEqual(done.returncode, 1, out)
        self.assertIn("::error title=Webview test red on this change::test/b.test.ts > x", out)

    def test_a_base_that_does_not_set_up_makes_every_red_the_changes(self):
        base = {"test/a.test.ts": body(["old red"])}
        done, out = self.run_pr(base, dict(base), install_status=1)
        self.assertEqual(done.returncode, 1, out)
        self.assertIn("the base did not set up", out)

    def test_a_push_keeps_every_red(self):
        base = {"test/a.test.ts": body(["old red"])}
        done, out = self.run_pr(base, dict(base), base_ref=None)
        self.assertEqual(done.returncode, 1, out)
        self.assertNotIn("Webview test red", out)

    def test_a_green_head_skips_the_base(self):
        done, out = self.run_pr({"test/a.test.ts": body(["old red"])}, {"test/a.test.ts": body([])})
        self.assertEqual(done.returncode, 0, out)
        self.assertNotIn("on the base", out)


class Collect(unittest.TestCase):
    def test_a_summary_becomes_per_test_results(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            logs = {"pass": "(pass) fine [1.00ms]\n", "fail": "(fail) a > b [2.00ms]\n(fail) a > b [2.00ms]\n",
                    "crash": "error: no module\n", "hang": "(fail) slow [9.00s]\n"}
            for name, text in logs.items():
                (tmp / name).write_text(text)
            (tmp / "summary").write_text(f"PASS p.test.ts {tmp}/pass\nFAIL f.test.ts {tmp}/fail\n"
                                         f"FAIL c.test.ts {tmp}/crash\nTIMEOUT h.test.ts {tmp}/hang\n")
            subprocess.run([sys.executable, str(COLLECT), str(tmp / "summary"), str(tmp / "out.json")], check=True)
            self.assertEqual(json.loads((tmp / "out.json").read_text()), {
                "p.test.ts": True, "f.test.ts > a > b": False, "c.test.ts": False, "h.test.ts": False,
                "h.test.ts > slow": False})


class GuardsUnchanged(unittest.TestCase):
    def test_guard_steps_keep_their_titles(self):
        with tempfile.TemporaryDirectory() as tmp:
            head, base = Path(tmp) / "h.json", Path(tmp) / "b.json"
            head.write_text(json.dumps({"lint": False}))
            base.write_text(json.dumps({"lint": True}))
            done = subprocess.run([sys.executable, str(COMPARE), str(head), str(base)], capture_output=True, text=True)
            self.assertEqual(done.returncode, 1)
            self.assertIn("::error title=Guard red on this change::lint", done.stdout)


class Workflow(unittest.TestCase):
    def test_pull_requests_compare_with_the_merge_parent_and_pushes_do_not(self):
        text = WORKFLOW.read_text(encoding="utf-8")
        step = text[text.index("      - name: Test webviews\n"):]
        step = step[: step.index("\n      - name:", 10)]
        self.assertIn("BASE_REF: ${{ github.event_name == 'pull_request' && 'HEAD^1' || '' }}", step)
        self.assertIn('run: ../scripts/ci/webviews-tests-new-reds.sh "$BASE_REF"', step)
        shard = text[text.index("  react-apps-check-shard:"):text.index("  react-doctor:")]
        self.assertIn("fetch-depth: ${{ github.event_name == 'pull_request' && '2' || '1' }}", shard)


if __name__ == "__main__":
    unittest.main()
