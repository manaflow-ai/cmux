#!/usr/bin/env python3
"""Behavior test for scripts/ci/pr_red_checks_comment.py against a fake GitHub API (HTTP).

Runs the script as the workflow does (env vars, real HTTP) and checks what it writes: the `checks`
line of the PR's status comment naming each red web/size check, an in-place edit to green when they
pass, the old red-checks comment edited into the status comment, and no write for a clean PR or an unchanged red list.
"""
import json
import os
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "ci" / "pr_red_checks_comment.py"
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import pr_status  # noqa: E402
# tests/git_fixture_env.py, loaded by path: `python3 -I` puts no script folder on sys.path.
import importlib.util as _git_fixture_importlib  # noqa: E402
from os import path as _git_fixture_path  # noqa: E402
_git_fixture_spec = _git_fixture_importlib.spec_from_file_location(
    "git_fixture_env", _git_fixture_path.join(_git_fixture_path.dirname(_git_fixture_path.abspath(__file__)), "git_fixture_env.py"))
git_fixture_env = _git_fixture_importlib.module_from_spec(_git_fixture_spec)
_git_fixture_spec.loader.exec_module(git_fixture_env)

LEGACY = "<!-- cmux-red-checks -->"
BOT = {"login": "github-actions[bot]"}
RED_LINE = "red: web / react-apps-check; do not merge until green; see lane-rules"
# cmux-next-guards.yml own-change-checks: the size cap and the crash ratchet are steps of this one job.
OWN_CHANGE_JOB = "cmux-next size cap, crash ratchet, localization debt ratchet, no new generated files"


def status(**sections):
    return pr_status.render(sections)


class FakeGitHub:
    def __init__(self, check_runs, comments, base_runs=None, steps=None, annotations=None, env=None, pr_head="a" * 40,
                 graphql_checks=True, more_pages=False):
        self.check_runs, self.writes, self.gets, self.env = check_runs, [], [], env or {}
        # graphql_checks: answer the check-run and details queries (False: they error, so REST answers them).
        # more_pages: the check-runs query says a page was not enough, so REST answers it.
        self.graphql_checks, self.more_pages = graphql_checks, more_pages
        self.check_queries = []
        self.graphql = []  # GraphQL queries: the status comment reads (a separate pool from REST)
        self.pr_head = pr_head  # the pull request's head now (HEAD_SHA is "a" * 40)
        self.base_runs, self.steps, self.annotations = base_runs, steps or {}, annotations or {}
        self.comments = {c["id"]: dict(c, user=c.get("user", BOT)) for c in comments}
        fake = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def reply(self, data):
                body = json.dumps(data).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self):
                fake.gets.append(self.path)
                if "/annotations" in self.path:
                    rid = int(self.path.split("/check-runs/")[1].split("/")[0])
                    return self.reply(fake.annotations.get(rid, []))
                if "/actions/jobs/" in self.path:
                    jid = int(self.path.rsplit("/", 1)[1].split("?")[0])
                    return self.reply({"id": jid, "steps": fake.steps.get(jid, [])})
                if "/check-runs" in self.path:
                    runs = fake.base_runs if f"/commits/{'b' * 40}/" in self.path else fake.check_runs
                    return self.reply({"total_count": len(runs), "check_runs": runs})
                if self.path.startswith("/repos/o/r/issues/7/comments"):
                    return self.reply(sorted(fake.comments.values(), key=lambda c: c["id"]))
                if self.path == "/repos/o/r/pulls/7":
                    return self.reply({"number": 7, "head": {"sha": fake.pr_head}})
                self.send_error(404)

            def body(self):
                return json.loads(self.rfile.read(int(self.headers["Content-Length"])))

            def do_POST(self):
                payload = self.body()
                if self.path == "/graphql" and ("checkSuites" in payload["query"] or "nodes(ids" in payload["query"]):
                    fake.check_queries.append(payload["variables"])
                    if not fake.graphql_checks:
                        return self.reply({"errors": [{"message": "rate limited"}]})
                    return self.reply({"data": fake.checks_data(payload)})
                if self.path == "/graphql":
                    fake.graphql.append(payload["variables"])
                    nodes = [{"fullDatabaseId": str(c["id"]), "body": c["body"],
                              "author": {"__typename": "Bot", "login": c["user"]["login"].removesuffix("[bot]")}}
                             for c in sorted(fake.comments.values(), key=lambda c: c["id"])]
                    return self.reply({"data": {"repository": {"issueOrPullRequest": {"comments": {
                        "pageInfo": {"hasNextPage": False, "endCursor": None}, "nodes": nodes}}}}})
                fake.writes.append(("POST", self.path, payload["body"]))
                fake.comments[99] = {"id": 99, "body": payload["body"], "user": BOT}
                self.reply(fake.comments[99])

            def do_PATCH(self):
                payload = self.body()
                fake.writes.append(("PATCH", self.path, payload["body"]))
                cid = int(self.path.rsplit("/", 1)[1])
                fake.comments[cid]["body"] = payload["body"]
                self.reply(fake.comments[cid])

            def do_DELETE(self):
                fake.writes.append(("DELETE", self.path, None))
                del fake.comments[int(self.path.rsplit("/", 1)[1])]
                self.send_response(204)
                self.end_headers()

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    @staticmethod
    def node_id(rid):
        return f"CR_{rid}"

    def checks_data(self, payload):
        variables = payload["variables"]
        if "ids" in variables:
            ids = {int(i.removeprefix("CR_")) for i in variables["ids"]}
            return {"nodes": [{"databaseId": rid,
                               "steps": {"pageInfo": {"hasNextPage": len(self.steps.get(rid, [])) > 100},
                                         "nodes": [{"name": st.get("name"), "number": n + 1,
                                                    "conclusion": (st.get("conclusion") or "").upper() or None}
                                                   for n, st in enumerate(self.steps.get(rid, [])[:100])]},
                               "annotations": {"nodes": [{"title": a.get("title"), "message": a.get("message"),
                                                          "annotationLevel": (a.get("annotation_level") or "").upper()}
                                                         for a in self.annotations.get(rid, [])]}}
                              for rid in sorted(ids)]}

        def commit(runs):
            return {"checkSuites": {"pageInfo": {"hasNextPage": False}, "nodes": [{"checkRuns": {
                "pageInfo": {"hasNextPage": self.more_pages},
                "nodes": [{"id": self.node_id(r["id"]), "databaseId": r["id"], "name": r["name"],
                           "status": (r.get("status") or "").upper(),
                           "conclusion": (r.get("conclusion") or "").upper() or None,
                           "startedAt": r.get("started_at")} for r in runs]}}]}}

        repository = {"head": commit(self.check_runs)}
        if variables.get("withBase"):
            repository["base"] = commit(self.base_runs or [])
        return {"repository": repository}

    def run(self):
        url = f"http://127.0.0.1:{self.server.server_port}"
        # PR_HEAD_REMOTE: no such remote, so the head is read over REST unless a test gives a real one.
        env = dict(os.environ, GITHUB_API_URL=url, GITHUB_GRAPHQL_URL=url + "/graphql", GITHUB_REPOSITORY="o/r",
                   GITHUB_TOKEN="t", GH_TOKEN="t", PR_NUMBER="7", HEAD_SHA="a" * 40, PR_STATUS_SETTLE_SECONDS="0.01",
                   PR_HEAD_REMOTE="/nonexistent/pr-head-remote")
        env.pop("BASE_SHA", None)
        env.pop("OWN_CHECKS_GREEN", None)
        if self.base_runs is not None:
            env["BASE_SHA"] = "b" * 40
        env.update(self.env)
        out = subprocess.run([sys.executable, str(SCRIPT)], env=env, capture_output=True, text=True, timeout=60)
        self.server.shutdown()
        assert out.returncode == 0, out.stderr
        return self.writes


def read_check_runs(fake):
    """The head's check runs were read: over GraphQL, or REST's pages when GraphQL could not answer."""
    return any("checkSuites" in str(q) or "head" in q for q in fake.check_queries) or any(
        "/check-runs" in path for path in fake.gets)


def run(name, conclusion, status="completed", started="2026-10-13T00:00:00Z", id_=1):
    return {"id": id_, "name": name, "status": status, "conclusion": conclusion, "started_at": started}


def test_red_web_check_creates_one_comment_naming_it():
    writes = FakeGitHub([run("web / react-apps-check", "failure"), run("web / web-typecheck", "success", id_=2),
                         run("ci-status", "failure", id_=3)], []).run()
    assert writes == [("POST", "/repos/o/r/issues/7/comments", status(checks=RED_LINE))]


def test_size_check_and_web_check_both_listed():
    writes = FakeGitHub([run(OWN_CHANGE_JOB, "failure"), run("web / Web status", "timed_out", id_=2)], []).run()
    assert len(writes) == 1
    body = pr_status.parse(writes[0][2])["checks"]
    assert f"red: {OWN_CHANGE_JOB};" in body and "red: web / Web status;" in body


def test_unchanged_red_list_writes_nothing():
    existing = status(checks=RED_LINE)
    assert FakeGitHub([run("web / react-apps-check", "failure")], [{"id": 5, "body": existing}]).run() == []


def test_green_again_edits_the_line_in_place_and_keeps_the_others():
    existing = status(bead="Bead: `cx-abc1`", checks=RED_LINE)
    writes = FakeGitHub([run("web / react-apps-check", "failure", started="2026-10-13T00:00:00Z", id_=1),
                         run("web / react-apps-check", "success", started="2026-10-13T01:00:00Z", id_=2)],
                        [{"id": 4, "body": "unrelated"}, {"id": 5, "body": existing}]).run()
    assert writes == [("PATCH", "/repos/o/r/issues/comments/5",
                       status(bead="Bead: `cx-abc1`", checks="web and size checks: green"))]


def test_the_old_red_checks_comment_becomes_the_status_comment():
    old = LEGACY + "\n" + RED_LINE
    writes = FakeGitHub([run("web / react-apps-check", "failure")], [{"id": 3, "body": old}]).run()
    assert writes == [("PATCH", "/repos/o/r/issues/comments/3", status(checks=RED_LINE))]


def test_clean_or_pending_pr_gets_no_comment():
    assert FakeGitHub([run("web / react-apps-check", "success"), run("web / web-tests", None, status="in_progress", id_=2)], []).run() == []


# Base comparison (BASE_SHA set): #20633 merged with react-apps-check red because its budget red was a
# known base red; the job's lint step had also failed, on the PR's own new test, and only the base had
# it green. Each red check is compared step by step with the base commit's run of the same check.
def failed(name):
    return {"name": name, "conclusion": "failure"}


def ok(name):
    return {"name": name, "conclusion": "success"}


RAC = "web / react-apps-check (1)"


def checks_line(fake):
    writes = fake.run()
    assert len(writes) == 1, writes
    return pr_status.parse(writes[0][2])["checks"]


def test_a_red_step_the_base_passes_is_new_and_blocks():
    line = checks_line(FakeGitHub(
        [run(RAC, "failure", id_=11)], [],
        base_runs=[run(RAC, "failure", id_=21)],
        steps={11: [ok("Build"), failed("Check webviews (Oxlint, Oxfmt, type check)"), failed("Fail on the eager JS budget")],
               21: [ok("Build"), ok("Check webviews (Oxlint, Oxfmt, type check)"), failed("Fail on the eager JS budget")]}))
    assert line.startswith(f"red: {RAC}; NEW: step `Check webviews (Oxlint, Oxfmt, type check)` passes on the base bbbbbbbbbb;"), line
    assert "do not merge until green" in line, line


def test_the_same_failed_steps_as_the_base_are_a_base_red():
    line = checks_line(FakeGitHub(
        [run(RAC, "failure", id_=11)], [],
        base_runs=[run(RAC, "failure", id_=21)],
        steps={11: [failed("Fail on the eager JS budget")], 21: [failed("Fail on the eager JS budget")]}))
    assert line == f"red: {RAC}; base red: the same failure on the base bbbbbbbbbb; does not block", line


def test_a_new_failure_annotation_inside_a_shared_step_is_new():
    # The cmux-next checks job fails one summary step for any red sub-check; the sub-checks differ.
    name = "cmux-next checks (god files, concurrency, crash safety, l10n)"
    line = checks_line(FakeGitHub(
        [run(name, "failure", id_=11)], [],
        base_runs=[run(name, "failure", id_=21)],
        steps={11: [failed("Fail on any red check")], 21: [failed("Fail on any red check")]},
        annotations={11: [{"annotation_level": "failure", "message": "red check: Motion tokens"},
                          {"annotation_level": "failure", "message": "red check: String tables (21 languages)"},
                          {"annotation_level": "failure", "message": "Process completed with exit code 1."}],
                     21: [{"annotation_level": "failure", "message": "red check: String tables (21 languages)"},
                          {"annotation_level": "failure", "message": "Process completed with exit code 1."}]}))
    assert line.startswith(f"red: {name}; NEW: `red check: Motion tokens` is not red on the base bbbbbbbbbb;"), line


def test_the_line_quotes_the_failing_steps_red_never_a_passing_steps_negative_case_stderr():
    # cmux#40369 (feat-cmux-next runs 42820823641, 42820590433): the static checks job failed only in its page strings
    # step, and base_red_excuse.py quoted the license step's expected stderr ("pinned license manifest digest
    # changed"), printed by a passing negative-case test. This line is built from the failed steps' names and the
    # job's failure annotations (`##[error]` lines), never from plain log text, so a passing step's stderr is never
    # quoted or compared here (base_red_excuse.failed_steps_log keeps any step whose section has an `##[error]`).
    # The name as GitHub reports it: its 101-character `name:` cut to 97 characters and "...".
    name = "cmux-next static checks (vt-link-graph, nightly static capabilities, defaults snapshot, page stri..."
    licenses = "The nightly's Ghostty license checks pass on fixtures"
    strings = "Every page's strings generate with no missing translation"
    exit_line = {"annotation_level": "failure", "message": "Process completed with exit code 1."}
    line = checks_line(FakeGitHub(
        [run(name, "failure", id_=11)], [],
        base_runs=[run(name, "failure", id_=21)],
        steps={11: [ok(licenses), failed(strings)], 21: [ok(licenses), failed(strings)]},
        annotations={11: [{"annotation_level": "failure", "message": "settings: 42 strings missing"}, exit_line],
                     21: [{"annotation_level": "failure", "message": "home: 3 strings missing"}, exit_line]}))
    assert line.startswith(f"red: {name}; NEW: `settings: 42 strings missing` is not red on the base bbbbbbbbbb;"), line
    assert "digest" not in line and "license" not in line.lower(), line


def test_a_base_that_is_green_makes_every_red_new():
    line = checks_line(FakeGitHub([run(RAC, "failure", id_=11)], [], base_runs=[run(RAC, "success", id_=21)],
                                  steps={11: [failed("Test webviews")]}))
    assert line.startswith(f"red: {RAC}; NEW: green on the base bbbbbbbbbb;"), line


def test_no_base_run_to_compare_still_blocks():
    line = checks_line(FakeGitHub([run(RAC, "failure", id_=11)], [], base_runs=[], steps={11: [failed("Test webviews")]}))
    assert line == f"red: {RAC}; no finished base run on bbbbbbbbbb to compare; do not merge until green; see lane-rules", line


def test_a_cancelled_base_run_cannot_excuse_a_red():
    line = checks_line(FakeGitHub([run(RAC, "failure", id_=11)], [], base_runs=[run(RAC, "cancelled", id_=21)],
                                  steps={11: [failed("Test webviews")]}))
    assert line == f"red: {RAC}; no finished base run on bbbbbbbbbb to compare; {'do not merge until green; see lane-rules'}", line


def test_the_cmux_next_checks_job_is_tracked():
    name = "cmux-next checks (god files, concurrency, crash safety, l10n)"
    writes = FakeGitHub([run(name, "failure")], []).run()
    assert writes and f"red: {name};" in pr_status.parse(writes[0][2])["checks"], writes



# 2026-10-30: 22 pull requests merged webview test reds that then broke the base. The base replay named each
# new red test, yet this line said "no finished base run to compare" for it (a push never runs the replay)
# and "base red: does not block" for react-apps-check and Web status, whose one failed step matches any red
# base. The replay's red now names its tests and blocks; an aggregate follows the other lines.
BASE_CHECK = "web / react-apps-base-check (3)"


def new_red(name):
    return {"annotation_level": "failure", "title": "Webview test red on this change", "message": name}


def test_a_red_base_replay_names_its_new_tests_and_blocks():
    tests = [f"test/new-tab-{n}.test.tsx > case {n}" for n in range(5)]
    line = checks_line(FakeGitHub(
        [run(BASE_CHECK, "failure", id_=11)], [], base_runs=[],
        annotations={11: [new_red(t) for t in tests] + [
            {"annotation_level": "warning", "title": "Webview test red on the base too", "message": "test/old.test.ts > x"},
            {"annotation_level": "failure", "message": "Process completed with exit code 1."}]}))
    assert line == (f"red: {BASE_CHECK}; NEW webview test reds: {tests[0]}; {tests[1]}; {tests[2]} (+2 more); "
                    "do not merge until green; see lane-rules"), line


def test_a_red_base_replay_that_names_no_test_still_blocks():
    line = checks_line(FakeGitHub([run(BASE_CHECK, "failure", id_=11)], [], base_runs=[]))
    assert line.startswith(f"red: {BASE_CHECK}; it named no new red test") and "do not merge until green" in line, line


def test_an_aggregate_is_never_a_base_red_when_a_job_it_gathers_is_new():
    # #24644: react-apps-check's "Check webview test shards" failed the same way on the base, so it read as a base
    # red; its base replay had named agent-pane-no-capsules as red on the change alone.
    fake = FakeGitHub(
        [run("web / react-apps-check", "failure", id_=11), run("web / Web status", "failure", id_=12),
         run(BASE_CHECK, "failure", id_=13)], [],
        base_runs=[run("web / react-apps-check", "failure", id_=21), run("web / Web status", "failure", id_=22)],
        steps={11: [failed("Check webview test shards")], 21: [failed("Check webview test shards")],
               12: [failed("Check routed web jobs")], 22: [failed("Check routed web jobs")]},
        annotations={13: [new_red("test/agent-pane-no-capsules.test.ts > rounds its controls")]})
    lines = checks_line(fake).splitlines()
    assert len(lines) == 3, lines
    assert all("base red" not in line and "do not merge until green" in line for line in lines), lines
    assert lines[2].startswith("red: web / react-apps-check; a job it gathers is red on this change"), lines


def test_an_aggregate_whose_jobs_are_all_base_reds_does_not_block():
    fake = FakeGitHub(
        [run("web / react-apps-check", "failure", id_=11), run(RAC, "failure", id_=12)], [],
        base_runs=[run(RAC, "failure", id_=22)],
        steps={12: [failed("Fail on the eager JS budget")], 22: [failed("Fail on the eager JS budget")]})
    lines = checks_line(fake).splitlines()
    assert lines[0] == ("red: web / react-apps-check; follows the jobs it gathers, whose reds are all on the base "
                        "too; does not block"), lines


def test_an_aggregate_red_with_no_red_job_blocks():
    fake = FakeGitHub([run("web / react-apps-check", "failure", id_=11)], [],
                      base_runs=[run("web / react-apps-check", "failure", id_=21)],
                      steps={11: [failed("Check webview test shards")], 21: [failed("Check webview test shards")]})
    line = checks_line(fake)
    assert line.startswith("red: web / react-apps-check; none of the jobs it gathers is red"), line
    assert "do not merge until green" in line, line


def test_an_unrelated_base_red_never_excuses_an_aggregate_whose_job_was_cancelled():
    # Review (gpt-6-astra), 2026-10-30: React Doctor cancelled, both web aggregates red, and a size-cap red that the
    # base has too. The size cap is no job either aggregate gathers, and the cancelled job is the aggregates' own.
    size = OWN_CHANGE_JOB
    fake = FakeGitHub(
        [run("web / react-apps-check", "failure", id_=11), run("web / Web status", "failure", id_=12),
         run("web / react-doctor", "cancelled", id_=13), run(size, "failure", id_=14), run(RAC, "success", id_=15)], [],
        base_runs=[run(size, "failure", id_=24), run("web / react-apps-check", "success", id_=21)],
        steps={14: [failed("Check the app size")], 24: [failed("Check the app size")]})
    lines = checks_line(fake).splitlines()
    by = {line.split(";")[0]: line for line in lines}
    assert "does not block" in by[f"red: {size}"], lines
    assert by["red: web / react-apps-check"].endswith(
        "a job it gathers ended without a verdict (web / react-doctor: cancelled); do not merge until green; see lane-rules"), lines
    assert "a job it gathers is red on this change" in by["red: web / Web status"], lines


def test_a_cancelled_job_blocks_its_aggregate_beside_base_reds():
    fake = FakeGitHub(
        [run("web / react-apps-check", "failure", id_=11), run(RAC, "failure", id_=12),
         run("web / react-doctor", "cancelled", id_=13)], [],
        base_runs=[run(RAC, "failure", id_=22)],
        steps={12: [failed("Fail on the eager JS budget")], 22: [failed("Fail on the eager JS budget")]})
    lines = checks_line(fake).splitlines()
    assert "ended without a verdict (web / react-doctor: cancelled)" in lines[0], lines


# OWN_CHECKS_GREEN: the caller's tracked jobs passed. Three workflows call this on every push; with
# no red line there is nothing for a green caller to change, so it reads no check runs.
GREEN = {"OWN_CHECKS_GREEN": "true"}


def test_a_green_caller_with_no_red_line_reads_only_the_comments():
    # The common call: one GraphQL comment read and no REST call (the repository's REST budget is shared).
    fake = FakeGitHub([run("web / react-apps-check", "success")], [], env=GREEN)
    assert fake.run() == []
    assert fake.gets == [], fake.gets
    assert len(fake.graphql) == 1 and fake.graphql[0]["number"] == 7, fake.graphql


def test_the_status_comment_is_read_over_graphql_not_rest():
    fake = FakeGitHub([run("web / react-apps-check", "failure")], [{"id": 5, "body": status(checks="web and size checks: green")}])
    writes = fake.run()
    assert writes and writes[0][0] == "PATCH" and RED_LINE in writes[0][2], writes
    assert fake.graphql, "the comment reads go over GraphQL"
    assert not any("/issues/7/comments" in path for path in fake.gets), fake.gets


def test_a_green_caller_still_turns_a_red_line_green():
    fake = FakeGitHub([run("web / react-apps-check", "success")], [{"id": 5, "body": status(checks=RED_LINE)}], env=GREEN)
    assert fake.run() == [("PATCH", "/repos/o/r/issues/comments/5", status(checks="web and size checks: green"))]
    assert read_check_runs(fake)


def test_a_green_caller_keeps_another_workflows_red():
    fake = FakeGitHub([run(OWN_CHANGE_JOB, "failure")],
                      [{"id": 5, "body": status(checks=f"red: {OWN_CHANGE_JOB}; do not merge until green; see lane-rules")}],
                      env=GREEN)
    assert fake.run() == []
    assert read_check_runs(fake)


def test_the_callers_pass_whether_their_own_checks_passed():
    import yaml
    reusable = yaml.safe_load((ROOT / ".github/workflows/pr-red-checks-comment.yml").read_text())
    trigger = reusable.get("on", reusable.get(True))
    assert "own_checks_green" in trigger["workflow_call"]["inputs"]
    steps = reusable["jobs"]["comment"]["steps"]
    env = next(s for s in steps if s.get("name") == "Update the red checks line")["env"]
    assert env["OWN_CHECKS_GREEN"] == "${{ inputs.own_checks_green }}"
    for workflow in ("ci.yml", "cmux-next.yml", "cmux-next-guards.yml"):
        job = yaml.safe_load((ROOT / ".github/workflows" / workflow).read_text())["jobs"]["pr-red-checks"]
        assert job["with"]["own_checks_green"] == (
            "${{ !contains(needs.*.result, 'failure') && !contains(needs.*.result, 'cancelled') }}"), workflow

def test_a_call_for_a_superseded_head_writes_nothing():
    # A late call for an old head: its red is not the pull request's, and the current head's line stays.
    fake = FakeGitHub([run("web / react-apps-check", "failure")], [{"id": 5, "body": status(checks="web and size checks: green")}],
                      pr_head="c" * 40)
    assert fake.run() == []
    assert "/repos/o/r/pulls/7" in fake.gets


def test_a_call_for_the_current_head_still_writes_its_red():
    fake = FakeGitHub([run("web / react-apps-check", "failure")], [])
    writes = fake.run()
    assert len(writes) == 1 and RED_LINE in writes[0][2]


def head_remote(tmp, sha_holder):
    """A local git repository whose refs/pull/7/head is a real commit; its sha goes in sha_holder."""
    repo = Path(tmp) / "remote"
    git = ["git", "-c", "user.name=t", "-c", "user.email=t@t", "-C", str(repo)]
    subprocess.run(["git", "init", "-q", str(repo)], check=True)
    subprocess.run(git + ["commit", "-q", "--allow-empty", "-m", "head"], check=True)
    sha = subprocess.run(git + ["rev-parse", "HEAD"], check=True, capture_output=True, text=True).stdout.strip()
    subprocess.run(git + ["update-ref", "refs/pull/7/head", sha], check=True)
    sha_holder.append(sha)
    return str(repo)


def test_the_head_is_read_with_git_not_the_api():
    import tempfile
    with tempfile.TemporaryDirectory() as tmp:
        sha = []
        remote = head_remote(tmp, sha)
        fake = FakeGitHub([run("web / react-apps-check", "failure")], [], env={"PR_HEAD_REMOTE": remote, "HEAD_SHA": sha[0]})
        writes = fake.run()
    assert len(writes) == 1 and RED_LINE in writes[0][2], writes
    assert "/repos/o/r/pulls/7" not in fake.gets, fake.gets


def test_a_head_git_says_moved_on_writes_nothing():
    import tempfile
    with tempfile.TemporaryDirectory() as tmp:
        remote = head_remote(tmp, [])
        fake = FakeGitHub([run("web / react-apps-check", "failure")], [], env={"PR_HEAD_REMOTE": remote})
        assert fake.run() == []
    assert "/repos/o/r/pulls/7" not in fake.gets, fake.gets


def test_nothing_to_change_reads_no_head():
    fake = FakeGitHub([run("web / react-apps-check", "success")], [])
    assert fake.run() == []
    assert "/repos/o/r/pulls/7" not in fake.gets



def rest_check_reads(fake):
    return [p for p in fake.gets if "/check-runs" in p or "/actions/jobs/" in p]


def test_a_red_comparison_spends_no_rest_when_graphql_answers():
    # The head's and base's runs in one query, the compared runs' steps and annotations in a second: no REST read.
    fake = FakeGitHub([run(RAC, "failure", id_=11)], [], base_runs=[run(RAC, "failure", id_=21)],
                      steps={11: [failed("Test webviews")], 21: [failed("Test webviews")]})
    line = checks_line(fake)
    assert "base red: the same failure" in line, line
    assert rest_check_reads(fake) == [], fake.gets
    assert len(fake.check_queries) == 2, fake.check_queries
    assert fake.check_queries[0]["withBase"] is True
    assert sorted(fake.check_queries[1]["ids"]) == ["CR_11", "CR_21"]


def test_graphql_errors_fall_back_to_the_same_rest_answer():
    def fake(**kw):
        return FakeGitHub([run(RAC, "failure", id_=11)], [], base_runs=[run(RAC, "failure", id_=21)],
                          steps={11: [failed("Test webviews"), failed("Lint")], 21: [failed("Test webviews")]}, **kw)
    over_graphql, over_rest = fake(), fake(graphql_checks=False)
    assert checks_line(over_graphql) == checks_line(over_rest)
    assert "NEW: step `Lint` passes on the base" in checks_line(fake())
    assert rest_check_reads(over_graphql) == []
    assert any("/check-runs" in p for p in over_rest.gets) and any("/actions/jobs/11" in p for p in over_rest.gets)


def test_a_commit_with_more_runs_than_a_page_reads_them_over_rest():
    fake = FakeGitHub([run(RAC, "failure", id_=11)], [], base_runs=[run(RAC, "success", id_=21)],
                      steps={11: [failed("Test webviews")]}, more_pages=True)
    assert "NEW: green on the base" in checks_line(fake)
    assert any("/commits/" + "a" * 40 + "/check-runs" in p for p in fake.gets)
    assert any("/commits/" + "b" * 40 + "/check-runs" in p for p in fake.gets)


def test_a_green_pr_reads_its_runs_with_one_graphql_query():
    fake = FakeGitHub([run(RAC, "success", id_=11)], [], base_runs=[run(RAC, "failure", id_=21)])
    assert fake.run() == []
    assert rest_check_reads(fake) == [] and len(fake.check_queries) == 1


def test_a_job_with_more_steps_than_a_page_reads_them_over_rest():
    # Review of #35330: a failed step past the 100th must still count, so that run's steps come from REST.
    many = [ok(f"step {n}") for n in range(120)] + [failed("Lint")]
    fake = FakeGitHub([run(RAC, "failure", id_=11)], [], base_runs=[run(RAC, "failure", id_=21)],
                      steps={11: many, 21: [failed("Test webviews")]})
    assert "NEW: step `Lint` passes on the base" in checks_line(fake)
    assert any("/actions/jobs/11" in p for p in fake.gets)
    assert not any("/actions/jobs/21" in p for p in fake.gets)


def test_a_null_graphql_check_run_reads_that_commit_over_rest():
    # GraphQL lists a deleted or hidden run as null; the commit's runs are then incomplete, so REST answers.
    import pr_red_checks_comment as red
    good = {"id": "n1", "databaseId": 1, "name": "web", "status": "COMPLETED", "conclusion": "FAILURE",
            "startedAt": "2026-10-13T00:00:00Z"}
    commit = {"checkSuites": {"pageInfo": {"hasNextPage": False},
                              "nodes": [{"checkRuns": {"pageInfo": {"hasNextPage": False}, "nodes": [good, None]}}]}}
    assert red._commit_runs(commit) is None
    commit["checkSuites"]["nodes"][0]["checkRuns"]["nodes"] = [good]
    assert [r["id"] for r in red._commit_runs(commit)] == [1]
    commit["checkSuites"]["nodes"].append(None)
    assert red._commit_runs(commit) is None


def test_a_null_step_or_annotation_leaves_that_run_to_rest():
    import pr_red_checks_comment as red

    class GH:
        details = {}

    def node(steps, notes, id_):
        return {"databaseId": id_, "steps": {"pageInfo": {"hasNextPage": False}, "nodes": steps},
                "annotations": {"nodes": notes}}

    step = {"name": "Build", "conclusion": "FAILURE", "number": 1}
    data = {"nodes": [node([step, None], [], 1), node([step], [None], 2), node([step], [], 3)]}
    gh = GH()
    red.prefetch_details(gh, [{"id": i, "node_id": f"n{i}"} for i in (1, 2, 3)], query=lambda q, v: data)
    assert sorted(gh.details) == [3]


if __name__ == "__main__":
    import traceback
    bad = 0
    for _name, _fn in sorted(globals().items()):
        if _name.startswith("test_") and callable(_fn):
            try:
                _fn()
                print("PASS", _name)
            except Exception:  # noqa: BLE001 - report every failure
                bad += 1
                print("FAIL", _name)
                traceback.print_exc(limit=1)
    sys.exit(1 if bad else 0)

