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
    "nightly-next-tick.yml: Coalesce tick requests without cancelling work":
        "only a hand dispatch with --ref feat-cmux-next runs this copy (schedule, workflow_run and the "
        "tick's own dispatches run main's, which has no coalescer): at most 48 passes, 15 s apart",
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
