#!/usr/bin/env python3
"""The perf cron's architecture report (scripts/cmux-next/perf-cron-arch-report.py) with GitHub faked and git real
(a temporary repository whose commits carry a fake arch_counts.py, the counts it reports and the ratchet file): a rise
opens the issue with the row, the package, the first sha seen higher and the commits in the range; the same rise
updates it; a fall closes it; the history is capped; a missing ratchet file prints a note; errors never fail the job.
Run: python3 -I scripts/cmux-next/tests/test_perf_cron_arch_report.py (not a CI job)."""
import contextlib, importlib.util, io, json, os, subprocess, tempfile, unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("perf_cron_arch_report", os.path.join(HERE, "..", "perf-cron-arch-report.py"))
report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(report)

REPO = "manaflow-ai/cmux"
BOT = {"login": "github-actions[bot]"}
FAKE_COUNTS = '''import json, sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
def full_counts(root=ROOT):
    return json.loads((Path(root) / "plans/cmux-next/fake-counts.json").read_text())
if __name__ == "__main__":
    print(json.dumps(full_counts()))
'''
LAYERS = {"targets": {"CmuxNextBrowser": {"layer": "domain"}, "CmuxNextApp": {"layer": "app"}}}


def counts(singletons, browser):
    return {"targets": {"stateful_singletons": singletons, "layer_hard": 0},
            "packages": {"CmuxNextBrowser": {"stateful_singletons": browser}, "CmuxNextApp": {"stateful_singletons": 0}}}


RATCHET = {"_doc": "a count only goes down", "measured_at": "x", "counts": counts(5, 2)}


class FakeGitHub:
    def __init__(self):
        self.issues, self.calls, self.comments = {}, [], []

    def add(self, number, title, body, user=BOT, state="open"):
        self.issues[number] = {"number": number, "title": title, "body": body, "user": user, "state": state}

    def __call__(self, path, method="GET", body=None, timeout=30):
        self.calls.append((method, path))
        prefix = f"/repos/{REPO}/issues"
        if path.startswith("/search/issues"):
            items = sorted(self.issues.values(), key=lambda i: -i["number"])
            return {"items": [dict(i) for i in items if i["title"] == report.ISSUE_TITLE]}
        if method == "POST" and path == prefix:
            number = max(self.issues, default=0) + 1
            self.add(number, body["title"], body["body"])
            return dict(self.issues[number])
        if path.endswith("/comments"):
            self.comments.append((int(path.split("/")[-2]), body["body"]))
            return {}
        number = int(path.rsplit("/", 1)[1])
        if method == "PATCH":
            self.issues[number].update(body)
            self.issues[number].pop("state_reason", None)
        return dict(self.issues[number])

    def writes(self):
        return [c for c in self.calls if c[0] != "GET"]


class ArchReportTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        d = self.tmp.name
        self.repo = os.path.join(d, "repo")
        gitconfig = os.path.join(d, "gitconfig")
        open(gitconfig, "w").close()
        env = mock.patch.dict(os.environ, {"GIT_CONFIG_GLOBAL": gitconfig, "GIT_CONFIG_NOSYSTEM": "1",
                                           "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com",
                                           "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.com",
                                           "GH_TOKEN": "fake", "GITHUB_REPOSITORY": REPO})
        env.start()
        self.addCleanup(env.stop)
        subprocess.run(["git", "init", "-q", "-b", "feat-cmux-next", self.repo], check=True)
        self.write("scripts/cmux-next/arch_counts.py", FAKE_COUNTS)
        self.write("plans/cmux-next/architecture-layers.json", json.dumps(LAYERS))
        self.write("Packages/macOS/CmuxNext/Package.swift", "// swift-tools-version:6.0\n")
        self.state = os.path.join(d, "state.json")
        with open(self.state, "w") as f:
            json.dump({"schema": 1, "regressions": [], "issue": 7}, f)
        self.gh = FakeGitHub()

    def write(self, rel, text):
        path = os.path.join(self.repo, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(text)

    def commit(self, subject, value=None, ratchet=RATCHET):
        if value is not None:
            self.write("plans/cmux-next/fake-counts.json", json.dumps(value))
        path = os.path.join(self.repo, report.RATCHET_PATH)
        if ratchet is None:
            if os.path.exists(path):
                os.remove(path)
        else:
            self.write(report.RATCHET_PATH, json.dumps(ratchet))
        subprocess.run(["git", "-C", self.repo, "add", "-A"], check=True)
        subprocess.run(["git", "-C", self.repo, "commit", "-q", "--allow-empty", "-m", subject], check=True)
        return subprocess.run(["git", "-C", self.repo, "rev-parse", "HEAD"], capture_output=True, text=True,
                              check=True).stdout.strip()

    def run_report(self, sha, *extra):
        out = io.StringIO()
        with mock.patch.object(report, "gh_request", self.gh), contextlib.redirect_stdout(out):
            code = report.main(["--sha", sha, "--state", self.state, "--root", self.repo, "--issue",
                                "--run-url", "https://example.com/run/1", *extra])
        self.assertEqual(code, 0)
        return out.getvalue()

    def state_text(self):
        with open(self.state) as f:
            return f.read()

    def load_state(self):
        with open(self.state) as f:
            return json.load(f)

    def own_issues(self):
        return [i for i in self.gh.issues.values() if report.own_issue(i)]

    def rise(self):
        a = self.commit("baseline", counts(5, 2))
        self.run_report(a)
        b = self.commit("refactor: an unrelated change")
        c = self.commit("feat: add a browser singleton", counts(6, 3))
        return a, b, c

    def test_a_rise_opens_the_issue_with_row_package_first_sha_and_range(self):
        a, b, c = self.rise()
        self.assertEqual(self.gh.writes(), [], "at the ratchet: no issue")
        out = self.run_report(c)
        issues = self.own_issues()
        self.assertEqual(len(issues), 1, out)
        body = issues[0]["body"]
        self.assertIn(report.ISSUE_MARK, body)
        self.assertIn("| packages/CmuxNextBrowser/stateful_singletons | CmuxNextBrowser | 2 | 3 |", body)
        self.assertIn("| targets/stateful_singletons | - | 5 | 6 |", body)
        self.assertIn(c[:12], body)
        self.assertIn(f"{a[:12]}..{c[:12]}", body)
        self.assertIn("refactor: an unrelated change", body)
        self.assertIn("feat: add a browser singleton", body)
        self.assertNotIn("baseline", body, "the last good commit is not in the range")
        self.assertEqual(self.load_state()[report.ISSUE_KEY], issues[0]["number"])
        self.assertIn("OVER", out)
        self.assertIn("perf-cron-arch: opened issue", out)

    def test_the_same_rise_updates_the_issue(self):
        _, _, c = self.rise()
        self.run_report(c)
        d = self.commit("docs: still over")
        out = self.run_report(d)
        issues = self.own_issues()
        self.assertEqual(len(issues), 1, "the same rise updates, never a second issue")
        self.assertIn("updated issue", out)
        self.assertEqual(issues[0]["state"], "open")
        self.assertIn(f"{c[:12]}", issues[0]["body"], "the first sha seen higher stays the first one")
        self.assertIn(("PATCH", f"/repos/{REPO}/issues/{issues[0]['number']}"), self.gh.calls)

    def test_a_fall_closes_the_issue(self):
        _, _, c = self.rise()
        self.run_report(c)
        e = self.commit("fix: inject the browser cache", counts(5, 2))
        out = self.run_report(e)
        issue = self.own_issues()[0]
        self.assertEqual(issue["state"], "closed", out)
        self.assertTrue(any(n == issue["number"] and body.startswith("Recovered") for n, body in self.gh.comments))
        self.assertIn("closed issue", out)
        self.gh.calls.clear()
        self.run_report(self.commit("chore: nothing", counts(4, 2)))
        self.assertEqual(self.gh.writes(), [], "a closed issue stays closed while every row is under the ratchet")

    def test_a_rise_again_reopens_the_closed_issue(self):
        _, _, c = self.rise()
        self.run_report(c)
        self.run_report(self.commit("fix", counts(5, 2)))
        out = self.run_report(self.commit("feat: again", counts(5, 3)))
        issues = self.own_issues()
        self.assertEqual(len(issues), 1)
        self.assertEqual(issues[0]["state"], "open", out)
        self.assertIn("reopened issue", out)

    def test_a_persons_issue_with_the_same_title_is_never_touched(self):
        self.gh.add(7, report.ISSUE_TITLE, f"{report.ISSUE_MARK} copied", user={"login": "someone"})
        _, _, c = self.rise()
        self.run_report(c)
        self.assertEqual(self.gh.issues[7]["body"], f"{report.ISSUE_MARK} copied")
        self.assertEqual(self.gh.issues[7]["state"], "open")
        self.assertEqual(len(self.own_issues()), 1)

    def test_the_history_is_capped_at_20_and_keeps_the_perf_state(self):
        shas = [self.commit(f"c{i}", counts(5, 2)) for i in range(25)]
        for s in shas:
            self.run_report(s)
        self.run_report(shas[-1])  # the same sha again replaces its point
        state = self.load_state()
        hist = state[report.STATE_KEY]
        self.assertEqual(len(hist), report.HISTORY_POINTS)
        self.assertEqual([p["sha"] for p in hist], shas[-20:])
        self.assertEqual(hist[-1]["rows"]["targets/stateful_singletons"], 5)
        self.assertEqual((state["schema"], state["regressions"], state["issue"]), (1, [], 7))

    def test_the_trend_table_shows_ratchet_last_values_now_and_arrow(self):
        for v in (5, 4, 4):
            self.run_report(self.commit(f"v{v}", counts(v, 2)))
        out = self.run_report(self.commit("down", counts(3, 2)))
        self.assertIn("| targets/stateful_singletons | 5 | 5 4 4 | 3 | ↓ |", out)
        self.assertNotIn("layer_hard", out, "a row that is 0 everywhere is left out")

    def test_a_missing_ratchet_file_prints_a_note_and_keeps_the_issue_as_it_is(self):
        _, _, c = self.rise()
        self.run_report(c)
        self.gh.calls.clear()
        s = self.commit("chore: drop the ratchet", counts(9, 9), ratchet=None)
        out = self.run_report(s)
        self.assertIn(f"no {report.RATCHET_PATH} at {s[:12]}: trend only", out)
        self.assertEqual(self.gh.calls, [], "no ratchet: no judgement, no GitHub call")
        self.assertEqual(self.load_state()[report.STATE_KEY][-1]["sha"], s, "the trend point is still kept")

    def test_errors_never_fail_and_never_overwrite_the_perf_state(self):
        with open(self.state, "w") as f:
            f.write("{not json")
        out = self.run_report(self.commit("x", counts(9, 9)))
        self.assertIn("cannot read the state", out)
        self.assertEqual(self.state_text(), "{not json")
        os.remove(os.path.join(self.repo, "scripts/cmux-next/arch_counts.py"))
        out = self.run_report(self.commit("drop the counter", counts(9, 9)))
        self.assertIn("error, the report is skipped", out)
        self.assertIn("arch_counts.py is not in the commit", out)
        self.assertIn("bad arguments", self.capture(lambda: report.main(["--state", self.state])))

    def test_dry_run_writes_nothing(self):
        _, _, c = self.rise()
        before = self.state_text()
        out = self.run_report(c, "--dry-run")
        self.assertEqual(self.state_text(), before)
        self.assertEqual(self.gh.writes(), [])
        self.assertIn("would open an issue", out)

    def capture(self, fn):
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(fn(), 0)
        return out.getvalue()


if __name__ == "__main__":
    unittest.main()
