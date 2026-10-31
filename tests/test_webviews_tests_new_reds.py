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
import re
import shutil
import textwrap
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
WRAPPER = ROOT / "scripts/ci/webviews-tests-new-reds.sh"
COLLECT = ROOT / "scripts/ci/webviews_test_results.py"
COMPARE = ROOT / "scripts/ci/guards_new_reds.py"
SHARDS = ROOT / "scripts/ci/webviews_test_shards.py"
HISTORY = ROOT / "scripts/ci/webviews_test_history.py"
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
        ran = set(re.findall(r"^START (\S+) \(hard limit", out, re.MULTILINE))
        self.assertTrue(0 < len(ran) < len(files), out)  # the head ran its shard only
        self.assertEqual(out.count("::warning title=Webview test red on the base too::"), len(ran), out)

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

    def test_a_pull_request_can_publish_head_results_without_replaying_the_base(self):
        base, head = self.shard_1()
        with tempfile.TemporaryDirectory() as results_dir:
            result_path = Path(results_dir) / "head.json"
            done, out = self.run_pr(
                base,
                head,
                extra_env={
                    "CMUX_WEB_TEST_SKIP_BASE": "1",
                    "CMUX_WEB_TEST_RESULTS": str(result_path),
                },
            )
            self.assertEqual(done.returncode, 1, out)
            self.assertTrue(result_path.is_file())
            self.assertIn("test/agent-pane-peer-chat.test.ts", result_path.read_text())
            self.assertIn("base comparison runs in the separate react-apps base job", out)
            self.assertNotIn("the red files again on the base", out)


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


def command(name):
    """The run: script of ci-web.yml's step NAME."""
    text = WORKFLOW.read_text().split(f"      - name: {name}\n", 1)[1]
    text = text.split("\n      - name:", 1)[0]
    run = text.split("        run: ", 1)[1]
    if not run.startswith("|"):
        return run.splitlines()[0]
    lines = run.splitlines()[1:]
    indent = len(lines[0]) - len(lines[0].lstrip())
    script = []
    for line in lines:
        if line.strip() and not line.startswith(" " * indent):
            break
        script.append(line)
    return textwrap.dedent("\n".join(script))


class Workflow(unittest.TestCase):
    def test_base_replay_uses_the_same_runner_deadline_as_the_head(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            head, base, runner_temp, bins = (tmp / name for name in ("head", "base", "temp", "bin"))
            for repo in (head, base):
                (repo / "webviews/test").mkdir(parents=True)
                (repo / "scripts/ci").mkdir(parents=True)
                (repo / "webviews/test/hang.test.ts").write_text("// cmux-web-test-timeout: 3000\nHANG\n")
                subprocess.run(["git", "init", "-q", str(repo)], check=True)
                subprocess.run(["git", "-C", str(repo), "add", "-A"], check=True)
                subprocess.run(["git", "-C", str(repo), "-c", "user.name=t", "-c", "user.email=t@t",
                                "commit", "-qm", "fixture"], check=True)
                for source in (COLLECT, COMPARE, SHARDS, HISTORY):
                    shutil.copy(source, repo / "scripts/ci" / source.name)
            runner_temp.mkdir()
            bins.mkdir()
            (bins / "bun").write_text(FAKE_BUN)
            (bins / "bun").chmod(0o755)
            shutil.copy(ROOT / "scripts/ci/run-webviews-tests.sh", head / "scripts/ci/run-webviews-tests.sh")
            # The old base reaches a named assertion after its former long deadline. It must
            # not supply a different file-level verdict from the head's bounded runner.
            (base / "scripts/ci/run-webviews-tests.sh").write_text('#!/bin/sh\nprintf \'{"test/hang.test.ts > late assertion": false}\\n\' > "$CMUX_WEB_TEST_RESULTS"\nexit 1\n')
            wrapper = head / "scripts/ci/webviews-tests-new-reds.sh"
            wrapper.write_text('#!/bin/sh\nmkdir -p "$(dirname "$CMUX_WEB_TEST_RESULTS")"\nprintf \'{"test/hang.test.ts": false}\\n\' > "$CMUX_WEB_TEST_RESULTS"\n')
            wrapper.chmod(0o755)
            published = runner_temp / "webviews-head-results"
            env = {**os.environ, "PATH": f"{bins}:{os.environ['PATH']}", "RUNNER_TEMP": str(runner_temp),
                   "BASE_REF": "", "CMUX_WEB_TEST_RESULTS": str(published / "webviews-head-results.json"),
                   "CMUX_WEB_TEST_MAX_FILE_TIMEOUT": "1", "CMUX_WEB_TEST_RETRIES": "0",
                   "CMUX_WEB_TEST_JOBS": "1", "GITHUB_ACTIONS": "true"}
            done = subprocess.run(["bash", "-eu", "-c", command("Test webviews")],
                                  cwd=head / "webviews", env=env, capture_output=True, text=True, timeout=10)
            self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
            downloaded = runner_temp / "head-results"
            shutil.copytree(published, downloaded)
            env.update(HEAD_RESULTS=str(downloaded / "webviews-head-results.json"),
                       BASE_RESULTS=str(runner_temp / "base-results.json"))
            done = subprocess.run(["bash", "-eu", "-c", command("Run base reds and compare")],
                                  cwd=base / "webviews", env=env, capture_output=True, text=True, timeout=10)
            self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
            self.assertIn("red on the base too", done.stdout)
            self.assertEqual(json.loads((runner_temp / "base-results.json").read_text()), {"test/hang.test.ts": False})

    def test_pull_requests_compare_with_the_merge_parent_and_pushes_do_not(self):
        text = WORKFLOW.read_text(encoding="utf-8")
        step = text[text.index("      - name: Test webviews\n"):]
        step = step[: step.index("\n      - name:", 10)]
        self.assertIn("BASE_REF: ${{ github.event_name == 'pull_request' && 'HEAD^1' || '' }}", step)
        self.assertIn('../scripts/ci/webviews-tests-new-reds.sh "$BASE_REF"', step)
        self.assertIn("CMUX_WEB_TEST_RESULTS: ${{ runner.temp }}/webviews-head-results/webviews-head-results.json", step)
        self.assertIn("CMUX_WEB_TEST_SKIP_BASE: ${{ github.event_name == 'pull_request' && '1' || '0' }}", step)
        self.assertIn("Upload head webview results", text)
        self.assertIn("react-apps-head-results-shard${{ matrix.shard }}", text)
        self.assertNotIn("react-apps-head-results-shard${{ matrix.shard }}-attempt", text)
        self.assertIn("overwrite: true", text)
        self.assertIn("react-apps-base-check:", text)
        base = text[text.index("  react-apps-base-check:"):text.index("  runners:")]
        # The base builds with its own declared bun, before it installs anything.
        self.assertLess(base.index("run: scripts/cmux-next/private-bun.sh"), base.index("bun install --frozen-lockfile"))
        self.assertIn("actions/download-artifact@", text)
        # The head's comparison and flake history, which its shard publishes beside its runner.
        self.assertIn('python3 "$runner/guards_new_reds.py" --label "Webview test" --flaky "$flaky"', text)
        self.assertIn("../scripts/ci/guards_new_reds.py ../scripts/ci/webviews_test_history.py", text)
        self.assertIn("printf '{}\\n' > \"$BASE_RESULTS\"", text)
        self.assertNotIn('cp "$HEAD_RESULTS" "$BASE_RESULTS"', text)
        self.assertIn('CMUX_WEB_TEST_FILES="$(cat "$files")"', text)
        shard = text[text.index("  react-apps-check-shard:"):text.index("  react-doctor:")]
        self.assertIn("fetch-depth: ${{ github.event_name == 'pull_request' && '2' || '1' }}", shard)

    def test_the_base_job_replays_on_the_merge_parent(self):
        """pull_request.base.sha lags the merge commit's first parent once the base moves: #27045's
        base job replayed on a base 12 commits older than the one its head shards merged onto, where
        agent-pane-no-capsules still passed, and charged the change with the merge parent's own red."""
        text = WORKFLOW.read_text(encoding="utf-8")
        base = text[text.index("  react-apps-base-check:"):text.index("  runners:")]
        self.assertNotIn("github.event.pull_request.base.sha", base)
        checkout = base[base.index("      - name: Checkout the merge commit\n"):]
        checkout = checkout[: checkout.index("\n      - name:", 10)]
        self.assertIn("fetch-depth: 2", checkout)
        self.assertNotIn("ref:", checkout)
        detach = base.index("run: git checkout -q --detach HEAD^1")
        self.assertLess(detach, base.index("run: scripts/cmux-next/private-bun.sh"))
        self.assertLess(detach, base.index("bun install --frozen-lockfile"))

    def test_head_shards_leave_room_for_a_slow_files_retry(self):
        """#27045's shard 1: a 60 s retry used half the runner's 120 s default, so
        attach-huge-files' 130 s retry was cut short and its contended first run stood."""
        text = WORKFLOW.read_text(encoding="utf-8")
        step = text[text.index("      - name: Test webviews\n"):]
        step = step[: step.index("\n      - name:", 10)]
        # #27425: a fixed 300 s budget still cut accent-glass-invariants' retry and skipped two more
        # files. The step's retry deadline bounds every retry, inside the job's 40 min, and no smaller
        # budget cuts a retry before it.
        budget = int(re.search(r'CMUX_WEB_TEST_RETRY_BUDGET: "(\d+)"', step).group(1))
        deadline = int(re.search(r'CMUX_WEB_TEST_RETRY_DEADLINE: "(\d+)"', step).group(1))
        self.assertGreaterEqual(budget, deadline)
        self.assertLessEqual(deadline, 34 * 60)


    def test_a_head_red_the_merge_parent_has_is_a_base_red_even_when_the_old_base_passed(self):
        """#26980 broke message-preview-browser at 16:19; #27130, #27000, #26988 and #27008 merged onto
        parents that had it, but the base job replayed on github.event.pull_request.base.sha, an older
        commit without #26980, where the file passed: the merge parent's red was charged to each PR.
        The base job's own steps, run on a real merge commit, must replay at the merge parent."""
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            repo, runner_temp, bins = tmp / "repo", tmp / "temp", tmp / "bin"
            git = lambda *args: subprocess.run(["git", "-C", str(repo), "-c", "user.name=t", "-c", "user.email=t@t",
                                                *args], check=True, capture_output=True, text=True).stdout.strip()
            red = "test/message-preview-browser.test.ts"
            (repo / "webviews/test").mkdir(parents=True)
            (repo / "scripts/ci").mkdir(parents=True)
            for source in (COLLECT, COMPARE):
                shutil.copy(source, repo / "scripts/ci" / source.name)
            (repo / "webviews" / red).write_text(body([]))
            git("init", "-q", "-b", "base")
            git("add", "-A")
            git("commit", "-qm", "old base: the file passes")
            old_base = git("rev-parse", "HEAD")
            git("checkout", "-qb", "change")
            (repo / "webviews/src").mkdir()
            (repo / "webviews/src/other.ts").write_text("export {}\n")
            git("add", "-A")
            git("commit", "-qm", "the change: touches nothing the red file reads")
            git("checkout", "-q", "base")
            (repo / "webviews" / red).write_text(body(["received preview opens"]))
            git("commit", "-qam", "merge parent: the base breaks the file (#26980)")
            parent = git("rev-parse", "HEAD")
            git("merge", "-q", "--no-ff", "change", "-m", "the pull request's merge commit")
            self.assertEqual(git("rev-parse", "HEAD^1"), parent)
            merge = git("rev-parse", "HEAD")
            runner_temp.mkdir()
            bins.mkdir()
            (bins / "bun").write_text(FAKE_BUN)
            (bins / "bun").chmod(0o755)
            (runner_temp / "head-results/runner").mkdir(parents=True)
            for runner in (ROOT / "scripts/ci/run-webviews-tests.sh", COLLECT, COMPARE, HISTORY):  # as the head shard publishes them
                shutil.copy(runner, runner_temp / "head-results/runner")
            head_results = runner_temp / "head-results/webviews-head-results.json"
            head_results.write_text(json.dumps({f"{red} > received preview opens": False}))
            env = {k: v for k, v in os.environ.items() if k not in ("CMUX_BROWSER_TESTS", "GITHUB_ACTIONS")}
            env.update(PATH=f"{bins}:{os.environ['PATH']}", RUNNER_TEMP=str(runner_temp), TMPDIR=str(tmp),
                       HEAD_RESULTS=str(head_results), BASE_RESULTS=str(runner_temp / "base-results.json"),
                       CMUX_NEXT_STYLE_GUARDS="warn", CMUX_WEB_TEST_JOBS="1", CMUX_WEB_TEST_RETRIES="0",
                       CMUX_WEB_TEST_FILE_TIMEOUT="10")

            def replay(checkout_step):
                git("checkout", "-q", "--detach", merge)
                if checkout_step:
                    subprocess.run(["bash", "-eu", "-c", command(checkout_step)], cwd=repo, env=env, check=True)
                else:  # the former step: actions/checkout of pull_request.base.sha
                    git("checkout", "-q", "--detach", old_base)
                return subprocess.run(["bash", "-eu", "-c", command("Run base reds and compare")],
                                      cwd=repo / "webviews", env=env, capture_output=True, text=True, timeout=60)

            done = replay("Use the merge parent as the base")
            out = done.stdout + done.stderr
            self.assertEqual(done.returncode, 0, out)
            self.assertIn(f"::warning title=Webview test red on the base too::{red} > received preview opens", out)
            self.assertNotIn("red on this change::", out)
            # The old pinned base passes the file, so a replay there charges the red to the change.
            done = replay(None)
            out = done.stdout + done.stderr
            self.assertEqual(done.returncode, 1, out)
            self.assertIn(f"::error title=Webview test red on this change::{red} > received preview opens", out)

if __name__ == "__main__":
    unittest.main()
