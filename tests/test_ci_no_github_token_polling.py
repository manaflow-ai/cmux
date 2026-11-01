#!/usr/bin/env python3
"""No workflow step polls the GitHub API with the workflow's own GITHUB_TOKEN.

Every workflow shares one GITHUB_TOKEN budget an hour, and a step that sleeps in
a loop and calls the API each pass spends it for as long as it waits (2026-10-25
and 2026-10-26: nightly promotion, CLA and publish steps failed with "API rate
limit exceeded for installation"). scripts/ci/github_token_polling.py finds such
steps; its docstring says how. Wait with a job-level `concurrency` group, a
`workflow_run` trigger, or another token (an App token has its own budget).

ALLOWED lists the steps that poll today, as `workflow file: step name`, each with
why it may stay. Shrink it; do not grow it without a reason the review accepts.
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

from github_token_polling import (  # noqa: E402
    calls_with_own_token, js_polls, polling_steps, python_polls, shell_polls, step_polls,
)

WORKFLOWS = ROOT / ".github" / "workflows"

ALLOWED: dict[str, str] = {
    "ci-macos.yml: Wait for routed Linux preflight":
        "release-admission only (release_build and full_suite): one jobs read every 5 s, up to 210; "
        "should become a `needs:` on linux-preflight",
    "cmux-tui-release.yml: Dispatch registry publishers": "a release, by hand: finds the publisher runs it dispatched",
    "cmux-next.yml: Dispatch with GITHUB_TOKEN, waiting through a rate limit":
        "the DEV handoff's fallback dispatch (#25458), only when the App token cannot: at most three "
        "tries, each sleeping only after a rate-limit refusal (the /rate_limit read costs nothing)",
    "coderouter-release.yml: Publish immutable GitHub release":
        "a release: up to five reads of the assets' visibility, then one publish",
    "ios-testflight.yml: Decide whether a TestFlight upload is needed":
        "orders uploads: waits only while an earlier TestFlight run is active, listing runs and jobs "
        "each pass; a candidate for a concurrency group",
    "merge-group-fail-fast.yml: Locate and watch the merge-group CI run":
        "per merge group: finds and watches its CI run (lawrencecchen's #16224 cuts it)",
    'cmux-next-base-autofix.yml: Wait for the GhosttyKit release':
        'per feat-cmux-next push touching its paths, only while the ghostty gitlink has no published GhosttyKit release: one release read every 120 s, at most 45 passes, one run at a time; a candidate for workflow_run on build-ghosttykit.yml',
    "cmux-next.yml: Decide the fleet build's REF capture":
        "per DEV compile on a mini with CMUX_NEXT_HYBRID_REF_CAPTURE=1: two artifact reads "
        "(hybrid_ref_capture.py have), each sleeping only after a rate-limit refusal (Retry-After or "
        "the reset) or a 5xx, 600 s in all; a silent rate limit lost run 40428066457's capture",
    "cmux-next.yml: Capture the fleet build's REF":
        "calls hybrid_ref_capture.py capture, which never runs have's retry loop (the scan reads the "
        "whole script); its one jobs read is not in a loop",
    'cmux-next.yml: Probe the same-tree cmux-tui':
        'a same-repository PR whose merge has its own unpublished cmux-tui tree waits for an active trusted publisher (pin-cmux-tui.sh await_outside_publisher): two run reads every 10 s, at most 10 passes; forks look once; pushes and DEV dispatches look once, then re-check once after 20 s',
    'cmux-tui-artifacts.yml: Re-check the owner after leaving the marker':
        'only when this run deferred to a same-key owner whose hand-off job has started: one owner-run read every 15 s, at most 12 passes',
    'cmux-next-generated-catch-up.yml: Select PRs that conflict with feat-cmux-next':
        "per feat-cmux-next push, only while a PR's mergeable is UNKNOWN: re-lists open PRs every 20 s, at most 5 more times",
    'published-in.yml: Comment the release on its PRs':
        'per stable release: one comment per PR, 7.5 s apart for the secondary limit on content writes; stops at the first rate-limit refusal',
    'nightly.yml: Comment the build on its PRs':
        'per published nightly-next build: one comment per PR, 7.5 s apart; stops at the first rate-limit refusal',
    'auto-resume-nightly-notarization.yml: Prepare publication notes':
        'retry only: a gh api read is retried after a timeout or non-4xx failure, at most 3 tries, 5 and 10 s apart',
    'auto-resume-nightly-notarization.yml: Publish accepted assets and feeds':
        'retry only: prune retries a delete after 408/425/429/5xx or a rate-limit 403 (at most 4 tries); the publisher paces writes 1 s apart and waits out rate limits within its budget',
    'auto-triage.yml: Propose severity and area':
        'retry only: a request sleeps after a rate-limit 403/429 or a network error, at most 4 tries',
    'auto-triage.yml: Label untriaged open issues':
        'a backfill, by hand: the same rate-limit and network retry, at most 4 tries',
    'fleet-compile-check.yml: Compile-check the app on the build fleet and post fleet/compile-check':
        'retry only: two status POSTs, each retried after 429/5xx/no answer or a rate-limit 403, at most 6 tries',
    'ios-internal-nightly-trigger.yml: Decide':
        'retry only: one runs list, retried after a rate limit/429/5xx/timeout, at most 4 tries, 10/20/40 s apart',
    'nightly-tag-permission-probe.yml: Expect github.token to reject the workflow-changing ref':
        'by hand: each ref call retried after 408/425/429/5xx or a network error, at most 4 tries; the expected 403 is not retried',
    'risk-tier.yml: Grade the pull request':
        'retry only: a loop over the two sign-off labels; gh_run retries a failed gh call at most 3 times, 2 and 4 s apart',
    'auto-resume-nightly-notarization.yml: Poll saved Apple submissions without reserving a Mac':
        "polls Apple's notary service (poll-notary-submission.py), not GitHub; the scan counts urlopen as an API call",
    "cmux-next-perf-budgets.yml: Read the state and pick this tick's work":
        "the scan reads every loop of a script the step runs; perf-cron.py's sleeping loop is in run-part (fleet controller calls), which this step never runs",
    'cmux-next-perf-budgets.yml: Start the next part now':
        "the scan reads every loop of a script the step runs; perf-cron.py's sleeping loop is in run-part, which this step never runs",
    'cmux-next-perf-budgets.yml: Store the part, compare, keep the regression issue':
        "the scan reads every loop of a script the step runs; perf-cron.py's sleeping loop is in run-part, which this step never runs",
    'cmux-next.yml: Fetch the same-tree cmux-tui':
        'the scan reads every loop of a script the step runs; pin-cmux-tui.sh fetch waits on files.cmux.com; its GitHub run check is every 300 s inside a 120 s wait, so at most one',
    'cmux-next.yml: Probe the same-tree cmux-tui after the marker':
        'the scan reads every loop of a script the step runs; CMUX_TUI_TREE_PUBLISHER_WAIT_SECONDS=0 and CMUX_TUI_TREE_RECHECK_SECONDS=0: one look, no sleep',
    'cmux-tui-artifacts.yml: Check whether a newer push superseded this one':
        'the scan reads every loop of a script the step runs; the step runs only pin-cmux-tui.sh key, which has no loop and no API call',
    'nightly-tag-permission-probe.yml: Verify app token moves the workflow-changing ref':
        'uses the minted App token: its mint has no continue-on-error, so the github.token fallback never applies',
    'nightly.yml: Continue the newest accepted pending notarization':
        'walks at most 5 recovery candidates once each; the only sleep retries feed reads from files.cmux.com',
    'nightly.yml: Resolve cmux-tui client commit':
        "the scan reads every loop of a script the step runs; its walk visits at most 50 commits once each; only when none resolves it waits for the tip's active publisher (files.cmux.com every 30 s, one run read every 300 s, at most 3000 s)",
    'actions-artifact-prune.yml: Prune':
        'hourly: paces artifact deletes 0.4 s apart (at most 150 a minute) and stops at 50 calls left',
    'ci-cloud-overflow-probe.yml: Probe and switch':
        'every 10 min: watches its probe job, one jobs read every 15 s for at most CI_CLOUD_PROBE_MINUTES + 5 (7 to 25 min); a candidate for an App token',
    'ci-macos.yml: Try parallel GitHub artifact transport':
        'retry only: an artifact download is retried after a failure, at most 4 tries, 1-8 s apart',
    'ci-owned-pool-rescue.yml: Watch runs on persistent pools':
        'watches owned-pool runs (up to 5 h for a sweeper): reads on the glaeda-route App token (READ_TOKEN); GITHUB_TOKEN takes cancels, re-runs and a read the App may not make',
    'cmux-next-batch.yml: Run the batch':
        'a batch, only when CMUX_NEXT_BATCH_ENABLED=1: the flagged loop pages GraphQL with one 10 s retry on a timeout; the batch also waits for its dispatched runs, one read every 15 s to find a run (10 min) and every 90 s for it to finish',
    'cmux-next-batch.yml: Wait for quiet, then dispatch a batch':
        'only when CMUX_NEXT_BATCH_ENABLED=1: one debounce sleep between two run listings, then a dispatch; the flagged loop (GraphQL paging with one 10 s retry) is in the batch subcommand this step does not run',
    "gallery-advisory.yml: Update the PR's gallery section":
        'pr_status.py: a request is retried only after a rate limit or 5xx (at most 5 waits); the settle re-read after a write runs at most 4 rounds',
    "pr-checks.yml: Update the PR's review line":
        'pr_status.py: a request is retried only after a rate limit or 5xx (at most 5 waits); the settle re-read after a write runs at most 4 rounds',
    'pr-status.yml: Write the line':
        'pr_status.py: a request is retried only after a rate limit or 5xx (at most 5 waits); the settle re-read after a write runs at most 4 rounds',
    'nightly-next-train.yml: Run the train':
        "a train run: waits for its candidate builds, one run read per pending build every 60 s, within the train's cap (NIGHTLY_NEXT_TRAIN_CAP_MINUTES, default 120)",
    "tui-publish-npm.yml: Require successful verified artifact run": "a release, by hand: at most 24 reads",
    "tui-publish-pypi.yml: Require successful verified artifact run": "a release, by hand: at most 24 reads",
}


class GithubTokenPollingTests(unittest.TestCase):
    def test_no_new_github_token_polling_loop(self) -> None:
        new = {key: line for key, line in polling_steps(WORKFLOWS).items() if key not in ALLOWED}
        self.assertFalse(new, (
            "these steps sleep in a loop and call the GitHub API with github.token, which spends the "
            "budget every workflow shares (see this file's docstring for what to do instead):\n"
            + "\n".join(f"  {key}  ({line})" for key, line in sorted(new.items()))))

    def test_the_allowlist_has_no_stale_entries(self) -> None:
        stale = sorted(set(ALLOWED) - set(polling_steps(WORKFLOWS)))
        self.assertFalse(stale, f"no longer polling, remove from ALLOWED: {stale}")


class ShellTests(unittest.TestCase):
    def test_loops_that_sleep_and_call(self) -> None:
        self.assertTrue(shell_polls('until gh run view "$id" --json status | grep -q completed; do\n  sleep 30\ndone\n'))
        self.assertTrue(shell_polls("x=1; while true; do gh api rate_limit; sleep 5; done"))
        nested = ("for i in 1 2 3; do\n  for j in a b; do\n    echo $j\n  done\n"
                  "  gh api repos/o/r/actions/runs >/dev/null\n  sleep 10\ndone\n")
        self.assertTrue(shell_polls(nested))
        self.assertTrue(shell_polls('for _ in 1 2; do\n  s="$(gh run view 1 --json status)"\n  sleep 5\ndone\n'))
        self.assertTrue(shell_polls("for i in 1 2; do curl -s https://api.github.com/repos/o/r; sleep 3; done"))

    def test_a_call_outside_the_sleeping_loop_is_not_polling(self) -> None:
        self.assertIsNone(shell_polls('for f in *.txt; do\n  wc -l "$f"\ndone\ngh api rate_limit\n'))
        self.assertIsNone(shell_polls("for i in 1 2; do sleep 1; done\n"))
        self.assertIsNone(shell_polls("gh api rate_limit\nfor i in 1 2 3; do\n  sleep 5\ndone\n"))

    def test_quoted_and_commented_keywords_do_not_end_a_loop(self) -> None:
        self.assertTrue(shell_polls('while true; do\n  echo "not done yet"\n  gh api x\n  sleep 5\ndone\n'))
        self.assertTrue(shell_polls("while true; do\n  # done waiting?\n  gh api x\n  sleep 5\ndone\n"))
        self.assertIsNone(shell_polls('for i in 1 2; do\n  echo "gh api x; sleep 5"\ndone\n'))

    def test_helpers_count_only_when_called(self) -> None:
        helper = ('state() {\n  gh run view "$1" --json status\n}\n'
                  "for _ in 1 2 3; do\n  state 42 | grep -q completed && break\n  sleep 15\ndone\n")
        self.assertTrue(shell_polls(helper))
        nap = "nap() {\n  sleep 15\n}\nwhile true; do\n  gh api repos/o/r/actions/runs\n  nap\ndone\n"
        self.assertTrue(shell_polls(nap))
        unindented = "function state {\ngh api x\n}\nwhile true; do\nstate\nsleep 5\ndone\n"
        self.assertTrue(shell_polls(unindented))
        brace_below = "state()\n{\n  gh api x\n}\nwhile true; do state; sleep 5; done\n"
        self.assertTrue(shell_polls(brace_below))
        # A word that matches a helper's name is not a call to it.
        self.assertIsNone(shell_polls('status() { gh api x; }\nfor status in a b; do\n  echo "waiting for status"\n'
                                      "  sleep 5\ndone\n"))
        # A one-line helper ends at its closing brace.
        self.assertIsNone(shell_polls("nap() { sleep 5; }\n  gh api x\nfor i in 1 2; do nap; done\n"))

    def test_a_python_heredoc_is_read_as_python(self) -> None:
        script = ("python3 - <<'PY'\nimport time, subprocess\nfor _ in range(5):\n"
                  "    subprocess.run(['gh', 'api', 'x'])\n    time.sleep(5)\nPY\n")
        self.assertTrue(shell_polls(script))
        self.assertIsNone(shell_polls("python3 - <<'PY'\nimport time\nfor _ in range(5):\n    time.sleep(1)\nPY\ngh api x\n"))


class PythonTests(unittest.TestCase):
    def test_python_loops_and_helpers(self) -> None:
        py = ("import time\ndef runs():\n    return gh_json('api', 'x')\n\n"
              "for _ in range(10):\n    runs()\n    time.sleep(5)\n")
        self.assertTrue(python_polls(py))
        self.assertIsNone(python_polls("import time\nfor _ in range(3):\n    time.sleep(1)\nurllib.request.urlopen(u)\n"))
        self.assertIsNone(python_polls("import time\ndef runs():\n    print('runs')\nfor _ in range(3):\n"
                                       "    print('runs')\n    time.sleep(1)\n"))
        multiline = ("import time\ndef state(\n    a,\n    b,\n):\n    return urllib.request.urlopen(a)\n"
                     "while True:\n    state(1, 2)\n    time.sleep(5)\n")
        self.assertTrue(python_polls(multiline))

    def test_a_nested_helper_does_not_hide_the_global_one(self) -> None:
        py = ("import time\ndef state():\n    return gh_json('api', 'x')\ndef unused():\n    def state():\n"
              "        return 1\n    return state()\nwhile True:\n    state()\n    time.sleep(5)\n")
        self.assertTrue(python_polls(py))


class JavaScriptTests(unittest.TestCase):
    def test_javascript_loops_and_helpers(self) -> None:
        coalescer = """
const activeRuns = async () => (await github.rest.actions.listWorkflowRuns({ owner, repo, workflow_id })).data;
for (let attempt = 0; attempt < 48; attempt += 1) {
  const runs = await activeRuns();
  await sleep(15000);
}
"""
        self.assertTrue(js_polls(coalescer))
        later = "for (let i = 0; i < 3; i++) {\n  await sleep(1000);\n}\nawait github.rest.issues.get({});\n"
        self.assertIsNone(js_polls(later))
        words = ("function status() { return github.rest.repos.get({}); }\n"
                 "for (const x of xs) {\n  console.log('waiting for status');\n  await sleep(5);\n}\n")
        self.assertIsNone(js_polls(words))
        method = ("function status() { return github.rest.repos.get({}); }\n"
                  "while (true) {\n  core.status();\n  await sleep(5);\n}\n")
        self.assertIsNone(js_polls(method))


class TokenTests(unittest.TestCase):
    def test_an_api_url_variable_is_the_api(self) -> None:
        loop = 'for _ in 1 2; do curl -u "x:$GH_TOKEN" "$API_URL/repos/x/runs/1"; sleep 5; done\n'
        own = {"GH_TOKEN": "${{ github.token }}"}
        self.assertTrue(step_polls({"run": loop, "env": dict(own, API_URL="${{ github.api_url }}")}, {}, {}))
        self.assertTrue(step_polls({"run": loop, "env": own}, {"env": {"API_URL": "https://api.github.com"}}, {}))
        self.assertIsNone(step_polls({"run": loop, "env": dict(own, API_URL="https://files.cmux.com")}, {}, {}))
        assigned = 'API="${GITHUB_API_URL}/repos/x"\n' + loop.replace("$API_URL/repos/x", "$API")
        self.assertTrue(step_polls({"run": assigned, "env": own}, {}, {}))
        retry = 'post() { for ((a = 1; a <= 6; a++)); do curl -X POST "$API/statuses/s"; sleep 5; done; }\npost\n'
        self.assertTrue(step_polls({"run": retry, "env": dict(own, API="${{ github.api_url }}/repos/x")}, {}, {}))

    def test_a_loop_takes_on_the_repository_scripts_it_runs(self) -> None:
        import tempfile
        from github_token_polling import Scripts
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "scripts").mkdir()
            (root / "scripts" / "look.sh").write_text('gh api "repos/x/releases/tags/t"\n')
            (root / "scripts" / "outer.sh").write_text("bash scripts/look.sh\n")
            (root / "scripts" / "quiet.sh").write_text("echo hi\n")
            (root / "scripts" / "wait.py").write_text(
                "import time, subprocess\nfor _ in range(3):\n    subprocess.run(['gh', 'api', 'x'])\n    time.sleep(5)\n")
            own = {"GH_TOKEN": "${{ github.token }}"}
            scripts = Scripts(root)
            calls = 'check() { scripts/outer.sh; }\nfor _ in $(seq 1 45); do sleep 120; check; done\n'
            self.assertTrue(step_polls({"run": calls, "env": own}, {}, {}, scripts))
            quiet = "for _ in 1 2; do sleep 1; ./scripts/quiet.sh; done\n"
            self.assertIsNone(step_polls({"run": quiet, "env": own}, {}, {}, scripts))
            self.assertIn("scripts/wait.py", step_polls({"run": "python3 scripts/wait.py\n", "env": own}, {}, {}, scripts))
            app = {"GH_TOKEN": "${{ steps.app.outputs.token }}"}
            self.assertIsNone(step_polls({"run": calls, "env": app}, {}, {}, scripts))

    def test_a_followed_script_sees_the_callers_api_url(self) -> None:
        import tempfile
        from github_token_polling import Scripts
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "scripts").mkdir()
            (root / "scripts" / "api.sh").write_text('curl -H "Authorization: Bearer $GH_TOKEN" "$API_URL/repos/x"\n')
            step = {"run": "for _ in 1 2; do scripts/api.sh; sleep 5; done\n",
                    "env": {"GH_TOKEN": "${{ github.token }}", "API_URL": "${{ github.api_url }}"}}
            self.assertTrue(step_polls(step, {}, {}, Scripts(root)))
            step["env"]["API_URL"] = "https://files.cmux.com"
            self.assertIsNone(step_polls(step, {}, {}, Scripts(root)))

    def test_a_heredoc_inside_a_shell_loop_is_part_of_the_loop(self) -> None:
        own = {"GH_TOKEN": "${{ github.token }}"}
        py = ("for _ in 1 2 3; do\n  python3 - <<'PY'\nimport urllib.request\n"
              "urllib.request.urlopen('https://api.github.com/repos/x')\nPY\n  sleep 5\ndone\n")
        self.assertTrue(step_polls({"run": py, "env": own}, {}, {}))
        js = ("for _ in 1 2 3; do\n  node <<'JS'\nawait github.rest.repos.get({})\nJS\n  sleep 5\ndone\n")
        self.assertTrue(step_polls({"run": js, "env": own}, {}, {}))
        text = "for _ in 1 2 3; do\n  cat > f <<'EOF'\ncurl https://api.github.com\nEOF\n  sleep 5\ndone\n"
        self.assertIsNone(step_polls({"run": text, "env": own}, {}, {}))

    def test_python_methods_and_bound_callables_are_followed(self) -> None:
        method = ("import time, urllib.request\n"
                  "class Api:\n"
                  "    def jobs(self):\n"
                  "        return urllib.request.urlopen('https://api.github.com/x')\n"
                  "def main(api):\n"
                  "    while True:\n"
                  "        api.jobs()\n"
                  "        time.sleep(30)\n")
        self.assertTrue(python_polls(method))
        default = ("import time, urllib.request\n"
                   "def call(path, *, sleep=time.sleep, opener=urllib.request.urlopen):\n"
                   "    for attempt in range(3):\n"
                   "        opener(path)\n"
                   "        sleep(5)\n")
        self.assertTrue(python_polls(default))
        indirect = ("import time, urllib.request\n"
                    "def http_api(path):\n"
                    "    return urllib.request.urlopen(path)\n"
                    "def upsert(api=http_api):\n"
                    "    for _ in range(4):\n"
                    "        api('/x')\n"
                    "        time.sleep(2)\n")
        self.assertTrue(python_polls(indirect))
        wrapper = ("import subprocess, time\n"
                   "class GitHub:\n"
                   "    def gh(self, *args):\n"
                   "        return subprocess.run(['gh', *args])\n"
                   "    def runs(self):\n"
                   "        return self.gh('api', 'repos/x/actions/runs')\n"
                   "def wait(gh):\n"
                   "    while True:\n"
                   "        time.sleep(15)\n"
                   "        gh.runs()\n")
        self.assertTrue(python_polls(wrapper))
        local = ("import time\n"
                 "class Clock:\n"
                 "    def tick(self):\n"
                 "        return 1\n"
                 "def main(c):\n"
                 "    while True:\n"
                 "        c.tick()\n"
                 "        time.sleep(1)\n")
        self.assertIsNone(python_polls(local))

    def test_the_innermost_token_wins(self) -> None:
        job = {"env": {"GH_TOKEN": "${{ github.token }}"}}
        self.assertTrue(calls_with_own_token({}, job, {}))
        self.assertFalse(calls_with_own_token({"env": {"GH_TOKEN": "${{ steps.app.outputs.token }}"}}, job, {}))
        self.assertTrue(calls_with_own_token({"env": {"GITHUB_TOKEN": "${{ secrets.GITHUB_TOKEN }}"}}, {}, {}))

    def test_gh_prefers_a_non_empty_gh_token(self) -> None:
        workflow = {"env": {"GITHUB_TOKEN": "${{ secrets.GITHUB_TOKEN }}"}}
        self.assertFalse(calls_with_own_token({"env": {"GH_TOKEN": "${{ steps.app.outputs.token }}"}}, {}, workflow))
        self.assertTrue(calls_with_own_token({"env": {"GH_TOKEN": "${{ github.token }}",
                                                      "GITHUB_TOKEN": "${{ steps.app.outputs.token }}"}}, {}, {}))
        # An empty GH_TOKEN makes gh fall back to GITHUB_TOKEN.
        self.assertTrue(calls_with_own_token({"env": {"GH_TOKEN": "", "GITHUB_TOKEN": "${{ github.token }}"}}, {}, {}))

    def test_a_script_naming_github_token_is_judged_by_it(self) -> None:
        step = {"env": {"GH_TOKEN": "${{ steps.app.outputs.token }}", "GITHUB_TOKEN": "${{ github.token }}"}}
        self.assertFalse(calls_with_own_token(step, {}, {}, "gh api x"))
        self.assertTrue(calls_with_own_token(step, {}, {}, 'curl -H "Authorization: Bearer $GITHUB_TOKEN" u'))

    def test_a_github_script_step_with_another_token_is_skipped(self) -> None:
        loop = "while (true) { await github.rest.repos.get({}); await sleep(5); }"
        own = {"uses": "actions/github-script@v9", "with": {"script": loop}}
        app = {"uses": "actions/github-script@v9", "with": {"script": loop, "github-token": "${{ steps.app.outputs.token }}"}}
        self.assertTrue(step_polls(own, {}, {}))
        self.assertIsNone(step_polls(app, {}, {}))


if __name__ == "__main__":
    unittest.main()
