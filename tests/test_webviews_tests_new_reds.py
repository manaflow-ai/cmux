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
REDS = ROOT / "scripts/ci/test_reds.py"
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
    def run_pr(self, base_files, head_files, base_ref="HEAD^1", install_status=0, extra_env=None, file_timeout="10",
               uname=None):
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
        if uname is not None:
            # The host the wrapper believes it is on (`uname -s`), whatever runs this test.
            (bin_dir / "uname").write_text(f"#!/bin/sh\necho {uname}\n")
            (bin_dir / "uname").chmod(0o755)
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

    def test_the_base_replay_runs_one_file_at_a_time_whatever_widths_the_shard_set(self):
        """The shard step sets CMUX_WEB_TEST_DEV_JOBS (4) for its own run; inherited, the base replay
        would run its red dev-server files 4 at once, and a red that only contention causes there
        would pass a change's own red off as the base's."""
        replay = WRAPPER.read_text(encoding="utf-8")
        replay = replay[replay.index('CMUX_WEB_TEST_JOBS=1'):]
        replay = replay[:replay.index('bash "$here/run-webviews-tests.sh"')]
        for name in ("CMUX_WEB_TEST_DEV_JOBS", "CMUX_WEB_TEST_BROWSER_JOBS", "CMUX_WEB_TEST_SHARD"):
            self.assertIn(f"-u {name} ", replay)

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
        done, out = self.run_pr(base, dict(base), extra_env={"FAKE_PLAYWRIGHT_STATUS": "1"}, uname="Linux")
        self.assertEqual(done.returncode, 1, out)
        self.assertIn("the base did not set up", out)

    def test_a_mac_installs_no_engines_for_the_base(self):
        # No Playwright on Macs (Lawrence, 2026-11-02): outside GitHub Actions a Mac never runs
        # `playwright install` (the fake one fails if it does); the runner skips the browser files
        # there, so the base sets up without engines and its reds still match the head's.
        base = {"test/a.test.ts": body(["old red"])}
        done, out = self.run_pr(base, dict(base), extra_env={"FAKE_PLAYWRIGHT_STATUS": "1"}, uname="Darwin")
        self.assertEqual(done.returncode, 0, out)
        self.assertNotIn("the base did not set up", out)

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


class PullRequestShard(unittest.TestCase):
    """A pull request's shard step is continue-on-error (ci-web.yml): its exit reaches no one, and
    react-apps-base-check judges only the reds the published head results name. A fake runner stands in
    for run-webviews-tests.sh: it publishes FAKE_HEAD_RESULTS and exits FAKE_STATUS. The verdict is the
    shard's exit dropped, then the base job's compare (guards_new_reds.py) on what the shard published.
    #36403's shard 5 (job 127427541516) named its two reds, so the base job would have judged them; a
    run that ends red naming no red had nothing for the base job to judge, and went green."""

    FAKE_RUNNER = textwrap.dedent("""\
        #!/usr/bin/env bash
        echo "FAIL src/agent-session/acpmux/conversation/BackgroundMark.test.tsx"
        echo "RETRY src/agent-session/acpmux/conversation/BackgroundMark.test.tsx"
        printf '%s' "$FAKE_HEAD_RESULTS" > "$CMUX_WEB_TEST_RESULTS"
        exit "$FAKE_STATUS"
        """)

    def verdict(self, head, status, base):
        temp = Path(self.enterContext(tempfile.TemporaryDirectory()))
        scripts = temp / "scripts/ci"
        scripts.mkdir(parents=True)
        for script in (WRAPPER, COLLECT, COMPARE):
            shutil.copy(script, scripts / script.name)
        (scripts / "run-webviews-tests.sh").write_text(self.FAKE_RUNNER)
        published = temp / "head-results/webviews-head-results.json"
        env = {**os.environ, "TMPDIR": str(temp), "CMUX_WEB_TEST_SKIP_BASE": "1",
               "CMUX_WEB_TEST_RESULTS": str(published), "FAKE_HEAD_RESULTS": json.dumps(head),
               "FAKE_STATUS": str(status)}
        shard = subprocess.run(["bash", str(scripts / WRAPPER.name), "HEAD^1"], cwd=temp, env=env,
                               capture_output=True, text=True, timeout=60)
        (temp / "base.json").write_text(json.dumps(base))
        gate = subprocess.run([sys.executable, str(COMPARE), "--label", "Webview test", str(published),
                               str(temp / "base.json")], capture_output=True, text=True, timeout=60)
        return shard, gate, shard.stdout + shard.stderr + gate.stdout + gate.stderr

    def test_a_file_red_on_its_first_run_and_its_retry_fails_the_pull_request(self):
        name = "src/agent-session/acpmux/conversation/BackgroundMark.test.tsx > names its owner"
        shard, gate, out = self.verdict({name: False}, 1, {name: True})
        self.assertEqual(shard.returncode, 1, out)
        self.assertEqual(gate.returncode, 1, out)
        # The shard stays green on a pull request, so it says its reds are not passed.
        self.assertIn("::warning title=Webview test reds on this head::1 file red here, "
                      "judged by react-apps-base-check: src/agent-session/acpmux/conversation/BackgroundMark.test.tsx", out)

    def test_a_run_that_breaks_after_publishing_its_results_fails_the_pull_request(self):
        shard, gate, out = self.verdict({"test/a.test.ts": True}, 2, {})
        self.assertEqual(shard.returncode, 2, out)
        self.assertEqual(gate.returncode, 1, out)
        self.assertIn("::error title=Webview test run broke::", out)

    def test_a_red_exit_that_names_no_red_fails_the_pull_request(self):
        shard, gate, out = self.verdict({"test/a.test.ts": True}, 1, {})
        self.assertEqual(gate.returncode, 1, out)
        self.assertIn("::error title=Webview test run broke::", out)

    def test_a_green_run_stays_green(self):
        shard, gate, out = self.verdict({"test/a.test.ts": True}, 0, {})
        self.assertEqual((shard.returncode, gate.returncode), (0, 0), out)
        self.assertNotIn("::error", out)
        self.assertNotIn("::warning", out)


class Collect(unittest.TestCase):
    def test_a_budget_stopped_retry_retains_only_first_run_failures(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            log = tmp / "stopped"
            log.write_text("--- retry stopped at shared budget ---\n"
                           "(pass) transient [1.00ms]\n(fail) partial retry [2.00ms]\n"
                           "--- first failure retained ---\n"
                           "(pass) first pass [1.00ms]\n(fail) original [2.00ms]\n"
                           "Ran 2 tests across 1 files.\n")
            (tmp / "summary").write_text(f"FAIL f.test.ts {log}\n")
            subprocess.run([sys.executable, str(COLLECT), str(tmp / "summary"), str(tmp / "out.json")], check=True)
            self.assertEqual(json.loads((tmp / "out.json").read_text()), {
                "f.test.ts > original": False,
            })

    def test_a_summary_becomes_per_test_results(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            logs = {"pass": "(pass) fine [1.00ms]\n", "fail": "(pass) a > good [1.00ms]\n(fail) a > b [2.00ms]\nRan 2 tests across 1 files.\n",
                    "crash": "error: no module\n", "hang": "(fail) slow [9.00s]\n"}
            for name, text in logs.items():
                (tmp / name).write_text(text)
            (tmp / "summary").write_text(f"PASS p.test.ts {tmp}/pass\nFAIL f.test.ts {tmp}/fail\n"
                                         f"FAIL c.test.ts {tmp}/crash\nTIMEOUT h.test.ts {tmp}/hang\n")
            subprocess.run([sys.executable, str(COLLECT), str(tmp / "summary"), str(tmp / "out.json")], check=True)
            self.assertEqual(json.loads((tmp / "out.json").read_text()), {
                "p.test.ts": True, "f.test.ts > a > good": True, "f.test.ts > a > b": False,
                "c.test.ts": False, "h.test.ts": False,
                "h.test.ts > slow": False})

    def test_a_cut_short_failed_file_does_not_publish_named_passes(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            log = tmp / "cut-short"
            log.write_text("(pass) looks-good [1.00ms]\n(fail) still-red [2.00ms]\n")
            (tmp / "summary").write_text(f"FAIL f.test.ts {log}\n")
            subprocess.run([sys.executable, str(COLLECT), str(tmp / "summary"), str(tmp / "out.json")], check=True)
            self.assertEqual(json.loads((tmp / "out.json").read_text()), {
                "f.test.ts > still-red": False,
            })


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
                for source in (COLLECT, COMPARE, SHARDS, HISTORY, REDS):
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
                   "CMUX_WEB_TEST_JOBS": "1", "GITHUB_ACTIONS": "true", "TAP_TESTS_STATE": "off"}
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
            for runner in (ROOT / "scripts/ci/run-webviews-tests.sh", COLLECT, COMPARE, HISTORY, REDS):  # as the head shard publishes them
                shutil.copy(runner, runner_temp / "head-results/runner")
            head_results = runner_temp / "head-results/webviews-head-results.json"
            head_results.write_text(json.dumps({f"{red} > received preview opens": False}))
            env = {k: v for k, v in os.environ.items() if k not in ("CMUX_BROWSER_TESTS", "GITHUB_ACTIONS")}
            env.update(PATH=f"{bins}:{os.environ['PATH']}", RUNNER_TEMP=str(runner_temp), TMPDIR=str(tmp),
                       HEAD_RESULTS=str(head_results), BASE_RESULTS=str(runner_temp / "base-results.json"),
                       CMUX_NEXT_STYLE_GUARDS="warn", CMUX_WEB_TEST_JOBS="1", CMUX_WEB_TEST_RETRIES="0",
                       CMUX_WEB_TEST_FILE_TIMEOUT="10", TAP_TESTS_STATE="off")

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

    def run_verdict(self, change_breaks_it, files=1):
        """The base job's steps on a real merge commit: a head shard red the base replay passes is re-run
        alone on the head, and is the change's only if it fails there again. FILES head-red files: the
        first is the one the change may break, the rest pass everywhere but ran out of the head shard's budget."""
        tmp = Path(self.enterContext(tempfile.TemporaryDirectory()))
        repo, runner_temp, bins = tmp / "repo", tmp / "temp", tmp / "bin"
        git = lambda *args: subprocess.run(["git", "-C", str(repo), "-c", "user.name=t", "-c", "user.email=t@t",
                                            *args], check=True, capture_output=True, text=True).stdout.strip()
        red = "test/reasoning-own-control.test.ts"
        others = [f"test/budget-gone-{i:02d}.test.ts" for i in range(1, files)]
        (repo / "webviews/test").mkdir(parents=True)
        (repo / "scripts/ci").mkdir(parents=True)
        for source in (COLLECT, COMPARE):
            shutil.copy(source, repo / "scripts/ci" / source.name)
        (repo / "webviews" / red).write_text(body([]))
        for other in others:
            (repo / "webviews" / other).write_text(body([]))
        git("init", "-q", "-b", "base")
        git("add", "-A")
        git("commit", "-qm", "base: the file passes")
        git("checkout", "-qb", "change")
        (repo / "webviews" / red).write_text(body(["mounts the gallery frame"] if change_breaks_it else []) + "// changed\n")
        git("commit", "-qam", "the change")
        git("checkout", "-q", "base")
        (repo / "webviews/other.txt").write_text("base moved\n")
        git("add", "-A")
        git("commit", "-qm", "base moves")
        git("merge", "-q", "--no-ff", "change", "-m", "the pull request's merge commit")
        merge = git("rev-parse", "HEAD")
        runner_temp.mkdir()
        bins.mkdir()
        (bins / "bun").write_text(FAKE_BUN)
        (bins / "bun").chmod(0o755)
        (runner_temp / "head-results/runner").mkdir(parents=True)
        for runner in (ROOT / "scripts/ci/run-webviews-tests.sh", COLLECT, COMPARE, HISTORY, REDS):
            shutil.copy(runner, runner_temp / "head-results/runner")
        head_results = runner_temp / "head-results/webviews-head-results.json"
        # The head shard's first run timed out on the frame and its retry budget was gone: the file is red unnamed.
        # #35163 (run 41890002293, shard 8): a shard out of budget keeps 13 files red at once, some
        # file-level and some `> (unnamed)`.
        head_results.write_text(json.dumps({red: False, **{f"{o} > (unnamed)": False for o in others[::2]},
                                            **{o: False for o in others[1::2]}}))
        output = runner_temp / "github-output"
        output.touch()
        env = {k: v for k, v in os.environ.items() if k not in ("CMUX_BROWSER_TESTS", "GITHUB_ACTIONS")}
        env.update(PATH=f"{bins}:{os.environ['PATH']}", RUNNER_TEMP=str(runner_temp), TMPDIR=str(tmp),
                   GITHUB_SHA=merge, GITHUB_OUTPUT=str(output), HEAD_RESULTS=str(head_results),
                   BASE_RESULTS=str(runner_temp / "base-results.json"),
                   HEAD_RERUN=str(runner_temp / "head-rerun-results.json"), CMUX_NEXT_STYLE_GUARDS="warn",
                   CMUX_WEB_TEST_JOBS="1", CMUX_WEB_TEST_RETRIES="0", CMUX_WEB_TEST_FILE_TIMEOUT="10",
                   TAP_TESTS_STATE="off")
        run = lambda name, cwd: subprocess.run(["bash", "-eu", "-c", command(name)], cwd=cwd, env=env,
                                               capture_output=True, text=True, timeout=60)
        self.assertEqual(run("Use the merge parent as the base", repo).returncode, 0)
        base = run("Run base reds and compare", repo / "webviews")
        self.assertEqual(base.returncode, 1, base.stdout + base.stderr)
        self.assertIn("rerun=true", output.read_text())
        self.assertEqual((runner_temp / "head-rerun-files").read_text(), "".join(f"{f}\n" for f in sorted([red, *others])))
        self.assertEqual(run("Check out the head again", repo).returncode, 0)
        self.assertEqual(git("rev-parse", "HEAD"), merge)
        return run("Re-run the change's reds alone on the head", repo / "webviews")

    def test_a_head_red_that_passes_alone_on_the_head_ends_the_verdict_green(self):
        done = self.run_verdict(change_breaks_it=False)
        out = done.stdout + done.stderr
        self.assertEqual(done.returncode, 0, out)
        self.assertIn("passed again alone on the head::test/reasoning-own-control.test.ts", out)
        self.assertNotIn("red on this change::", out)

    def test_a_shard_out_of_budget_with_many_file_reds_is_still_rerun_on_the_head(self):
        # #35163: 13 files red at the end of an out-of-budget head shard all passed on the base; the head re-run
        # was skipped for having more than 10, so all 13 were charged to the change.
        done = self.run_verdict(change_breaks_it=False, files=13)
        out = done.stdout + done.stderr
        self.assertEqual(done.returncode, 0, out)
        self.assertIn("passed again alone on the head::test/budget-gone-01.test.ts > (unnamed)", out)
        self.assertIn("passed again alone on the head::test/budget-gone-02.test.ts", out)
        self.assertNotIn("red on this change::", out)

    def test_a_head_red_the_change_causes_stays_red_after_the_head_rerun(self):
        done = self.run_verdict(change_breaks_it=True)
        out = done.stdout + done.stderr
        self.assertEqual(done.returncode, 1, out)
        self.assertIn("::error title=Webview test red on this change::test/reasoning-own-control.test.ts", out)

    def test_the_job_fails_on_the_change_reds_the_head_rerun_did_not_clear(self):
        text = WORKFLOW.read_text(encoding="utf-8")
        base = text[text.index("  react-apps-base-check:"):text.index("  runners:")]
        replay = base[base.index("      - name: Run base reds and compare\n"):]
        self.assertIn("continue-on-error: true", replay[: replay.index("run: |")])
        last = base[base.index("      - name: Fail on the change's own reds\n"):]
        self.assertIn("steps.base.outcome == 'failure' && steps.rerun.outcome != 'success'", last)
        for step in ("Check out the head again", "Use the head's bun", "Install head webview dependencies",
                     "Build head web bundles", "Install head headless engines", "Re-run the change's reds alone on the head"):
            found = base[base.index(f"      - name: {step}\n"):]
            self.assertIn("if: ${{ steps.base.outputs.rerun == 'true' }}", found[: found.index("run:")])
        self.assertLess(base.index("Re-run the change's reds alone on the head"), base.index("Fail on the change's own reds"))


if __name__ == "__main__":
    unittest.main()
