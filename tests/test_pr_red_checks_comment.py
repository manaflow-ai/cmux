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

LEGACY = "<!-- cmux-red-checks -->"
BOT = {"login": "github-actions[bot]"}
RED_LINE = "red: web / react-apps-check; do not merge until green; see lane-rules"


def status(**sections):
    return pr_status.render(sections)


class FakeGitHub:
    def __init__(self, check_runs, comments, base_runs=None, steps=None, annotations=None, env=None, pr_head="a" * 40):
        self.check_runs, self.writes, self.gets, self.env = check_runs, [], [], env or {}
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

    def run(self):
        env = dict(os.environ, GITHUB_API_URL=f"http://127.0.0.1:{self.server.server_port}", GITHUB_REPOSITORY="o/r",
                   GITHUB_TOKEN="t", PR_NUMBER="7", HEAD_SHA="a" * 40, PR_STATUS_SETTLE_SECONDS="0.01")
        env.pop("BASE_SHA", None)
        env.pop("OWN_CHECKS_GREEN", None)
        if self.base_runs is not None:
            env["BASE_SHA"] = "b" * 40
        env.update(self.env)
        out = subprocess.run([sys.executable, str(SCRIPT)], env=env, capture_output=True, text=True, timeout=60)
        self.server.shutdown()
        assert out.returncode == 0, out.stderr
        return self.writes


def run(name, conclusion, status="completed", started="2026-10-13T00:00:00Z", id_=1):
    return {"id": id_, "name": name, "status": status, "conclusion": conclusion, "started_at": started}


def test_red_web_check_creates_one_comment_naming_it():
    writes = FakeGitHub([run("web / react-apps-check", "failure"), run("web / web-typecheck", "success", id_=2),
                         run("ci-status", "failure", id_=3)], []).run()
    assert writes == [("POST", "/repos/o/r/issues/7/comments", status(checks=RED_LINE))]


def test_size_check_and_web_check_both_listed():
    writes = FakeGitHub([run("cmux-next CmuxNextApp size cap", "failure"), run("web / Web status", "timed_out", id_=2)], []).run()
    assert len(writes) == 1
    body = pr_status.parse(writes[0][2])["checks"]
    assert "red: cmux-next CmuxNextApp size cap;" in body and "red: web / Web status;" in body


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



# OWN_CHECKS_GREEN: the caller's tracked jobs passed. Three workflows call this on every push; with
# no red line there is nothing for a green caller to change, so it reads no check runs.
GREEN = {"OWN_CHECKS_GREEN": "true"}


def test_a_green_caller_with_no_red_line_reads_only_the_comments():
    fake = FakeGitHub([run("web / react-apps-check", "success")], [], env=GREEN)
    assert fake.run() == []
    assert fake.gets and all("/issues/7/comments" in path for path in fake.gets), fake.gets


def test_a_green_caller_still_turns_a_red_line_green():
    fake = FakeGitHub([run("web / react-apps-check", "success")], [{"id": 5, "body": status(checks=RED_LINE)}], env=GREEN)
    assert fake.run() == [("PATCH", "/repos/o/r/issues/comments/5", status(checks="web and size checks: green"))]
    assert any("/check-runs" in path for path in fake.gets)


def test_a_green_caller_keeps_another_workflows_red():
    fake = FakeGitHub([run("cmux-next crash ratchet", "failure")],
                      [{"id": 5, "body": status(checks="red: cmux-next crash ratchet; do not merge until green; see lane-rules")}],
                      env=GREEN)
    assert fake.run() == []
    assert any("/check-runs" in path for path in fake.gets)


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


def test_nothing_to_change_reads_no_head():
    fake = FakeGitHub([run("web / react-apps-check", "success")], [])
    assert fake.run() == []
    assert "/repos/o/r/pulls/7" not in fake.gets


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

