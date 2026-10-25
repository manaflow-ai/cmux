#!/usr/bin/env python3
"""The perf cron's architecture report (scripts/cmux-next/perf-cron-arch-report.py) with GitHub faked and git real
(temporary repositories whose commits carry a fake arch_counts.py that follows the pinned contract: `--repo --rev
--json`, reads the commit from git objects, prints one record of the arch-ratchet.json shape).

Covered: a rise opens the issue with the row, the packages that rose, the first sha seen higher and the commits in
the range; the same rise updates it; a fall closes it; a new rise reopens it; the history is capped; a run that
cannot judge every row (a renamed row, another method version, a missing ratchet file, a failed count) notes it in
the issue, opens or reopens it when needed, and never closes it; a commit with neither ratchet file is only logged;
an exceptions entry --update applied (applied_sha) allows no new rise, a pending one (no applied_sha) raises the
limit like the pre-push rule and an invalid one is ignored, also when the measured_sha was rebased away; an older
commit or a bisect step after a newer point changes nothing; a kept point whose sha is not a sha is dropped before it
reaches git or GitHub; a rewritten branch (the last point diverged, or its commit is gone) restarts the trend and says
so; a shallow, sparse, blobless clone whose HEAD is not the measured commit (made by git clone, and the way
actions/checkout makes it) is counted with a few fetches, not one per blob; a count past the deadline is still
noted in the issue in time; an unreadable state is never overwritten; with no repository or GH_TOKEN the point is
kept and no GitHub request is made, also in a dry run; the in-process run_report() and report_finished() change only their own keys.
Run: python3 -I scripts/cmux-next/tests/test_perf_cron_arch_report.py (not a CI job)."""
import contextlib, copy, importlib.util, io, json, os, subprocess, tempfile, time, unittest, urllib.error
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("perf_cron_arch_report", os.path.join(HERE, "..", "perf-cron-arch-report.py"))
report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(report)

REPO = "manaflow-ai/cmux"
BOT = {"login": "github-actions[bot]"}
SOURCES = "Packages/macOS/CmuxNext/Sources"
# Like the real arch_counts.py: reads every Swift source of the commit and the commit's counts from git objects (one
# cat-file --batch), so a blobless clone without a prefetch pays one fetch per blob here too.
FAKE_COUNTS = r'''import argparse, json, subprocess
ap = argparse.ArgumentParser()
ap.add_argument("--repo", required=True)
ap.add_argument("--rev", required=True)
ap.add_argument("--json", action="store_true")
a = ap.parse_args()
def git(*args, data=None):
    return subprocess.run(["git", "-C", a.repo, *args], input=data, capture_output=True, check=True).stdout
sha = git("rev-parse", "--verify", a.rev + "^{commit}").decode().strip()
paths = [p for p in git("ls-tree", "-r", "-z", "--name-only", sha, "--", "%s").decode().split("\0")
         if p.endswith(".swift")] + ["plans/cmux-next/fake-counts.json"]
out = git("cat-file", "--batch", data="".join(f"{sha}:{p}\n" for p in paths).encode())
at, body = 0, b""
for _ in paths:
    nl = out.index(b"\n", at)
    size = int(out[at:nl].split()[2])
    body = out[nl + 1:nl + 1 + size]
    at = nl + 1 + size + 1
value = json.loads(body)
print(json.dumps({"method": "arch_counts", "measured_sha": sha, **value}, sort_keys=True))
''' % SOURCES
ROWS = {"layer_hard": {"title": "hard layer edges", "ratchet": True},
        "stateful_singletons": {"title": "stateful singletons", "ratchet": True},
        "app_lines": {"title": "CmuxNextApp Swift lines", "ratchet": False}}


def counts(singletons, browser, rename=None, version=1):
    rows = {(rename or {}).get(k, k): v for k, v in ROWS.items()}
    name = (rename or {}).get("stateful_singletons", "stateful_singletons")
    totals = {k: 0 for k in rows}
    totals.update({name: singletons, "app_lines": 100})
    packages = {"CmuxNextBrowser": {name: browser}, "CmuxNextApp": {name: singletons - browser, "app_lines": 100}}
    return {"method_version": version, "rows": rows, "totals": totals, "packages": packages}


def ratchet(singletons=5, browser=2, version=1, measured_sha="0" * 40, exceptions=()):
    return {"_doc": "a count only goes down", "method": "arch_counts", "measured_sha": measured_sha,
            "measured_date": "2026-10-23", **counts(singletons, browser, version=version),
            "exceptions": list(exceptions)}


def entry(allow, why="a reviewed browser cache", row="stateful_singletons", date="2026-10-23"):
    return {"date": date, "row": row, "allow": allow, "why": why}


RATCHET = ratchet()


class FakeGitHub:
    def __init__(self):
        self.issues, self.calls, self.comments = {}, [], []

    def add(self, number, title, body, user=BOT, state="open"):
        self.issues[number] = {"number": number, "title": title, "body": body, "user": user, "state": state}

    def __call__(self, path, method="GET", body=None, timeout=30):
        self.calls.append((method, path))
        prefix = f"/repos/{REPO}/issues"
        if path.startswith(f"/repos/{REPO}/compare/"):
            # Only asked when git cannot answer: in these tests, when the old point's commit no longer exists.
            raise urllib.error.HTTPError(path, 404, "Not Found", None, None)
        if path.startswith(f"/repos/{REPO}/commits/"):
            return {"sha": path.rsplit("/", 1)[1]}
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


def git(repo, *args):
    return subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True, check=True).stdout.strip()


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
        self.write("scripts/cmux-next/perf-cron.py", "# the report checkout's sparse file\n")
        self.write("Packages/macOS/CmuxNext/Package.swift", "// swift-tools-version:6.0\n")
        self.write(f"{SOURCES}/CmuxNextApp/App.swift", "struct App {}\n")
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
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-q", "--allow-empty", "-m", subject)
        return git(self.repo, "rev-parse", "HEAD")

    def run_report(self, sha, *extra, kind="tip", root=None):
        out = io.StringIO()
        with mock.patch.object(report, "gh_request", self.gh), contextlib.redirect_stdout(out):
            code = report.main(["--sha", sha, "--kind", kind, "--state", self.state, "--root", root or self.repo,
                                "--issue", "--run-url", "https://example.com/run/1", *extra])
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

    def test_a_rise_opens_the_issue_with_row_packages_first_sha_and_range(self):
        a, b, c = self.rise()
        self.assertEqual(self.gh.writes(), [], "at the ratchet: no issue")
        out = self.run_report(c)
        issues = self.own_issues()
        self.assertEqual(len(issues), 1, out)
        body = issues[0]["body"]
        self.assertIn(report.ISSUE_MARK, body)
        self.assertIn("| stateful_singletons | CmuxNextBrowser 2→3 | 5 | 6 |", body)
        self.assertNotIn("| app_lines |", body, "a row the ratchet file does not ratchet is never judged")
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
        out = self.run_report(self.commit("feat: again", counts(6, 3)))
        issues = self.own_issues()
        self.assertEqual(len(issues), 1)
        self.assertEqual(issues[0]["state"], "open", out)
        self.assertIn("reopened issue", out)

    def assert_open_issue_stays_open(self, value, ratchet_value, expect):
        _, _, c = self.rise()
        self.run_report(c)
        number = self.own_issues()[0]["number"]
        self.gh.comments.clear()
        out = self.run_report(self.commit("refactor: the rows change", value, ratchet=ratchet_value))
        issue = self.gh.issues[number]
        self.assertEqual(issue["state"], "open", out)
        self.assertEqual(self.gh.comments, [], "no 'Recovered' comment on a run that cannot judge every row")
        self.assertIn(expect, issue["body"])
        self.assertIn(expect, out)
        self.assertNotIn("closed issue", out)
        return out

    def test_a_renamed_row_never_closes_the_issue_and_is_named(self):
        # The count fell under the ratchet only because the row has a new name: the rename dodges the count.
        out = self.assert_open_issue_stays_open(counts(1, 0, rename={"stateful_singletons": "static_holders"}),
                                                RATCHET, "missing from the counts")
        self.assertIn("stateful_singletons", self.own_issues()[0]["body"])
        self.assertIn("left issue", out)

    def test_counts_with_no_row_in_common_never_close_the_issue(self):
        self.assert_open_issue_stays_open(
            counts(0, 0, rename={"stateful_singletons": "x1", "layer_hard": "x2"}), RATCHET,
            "no ratcheted row of the ratchet file is in the counts")

    def test_another_method_version_judges_nothing_and_never_closes(self):
        self.assert_open_issue_stays_open(counts(1, 0, version=2), RATCHET, "method v2")

    def test_an_older_commit_or_a_bisect_step_after_a_newer_point_changes_nothing(self):
        a, _, c = self.rise()
        self.run_report(c)
        before, issues = self.state_text(), copy.deepcopy(self.gh.issues)
        self.gh.calls.clear()
        out = self.run_report(a)
        self.assertIn("is older than the last point", out)
        self.assertEqual(self.state_text(), before, "an older tip adds no point after a newer one")
        self.assertEqual(self.gh.issues, issues)
        self.assertEqual(self.gh.writes(), [])
        out = self.run_report(a, kind="bisect")
        self.assertIn("not a tip", out)
        self.assertEqual(self.state_text(), before)
        self.assertEqual(self.gh.calls, [], "a bisect step is not looked at at all")

    def partial_clone(self, way):
        """A depth-1, blobless, sparse checkout of the branch tip like the report job's, made by `git clone`
        ("clone") or the way actions/checkout makes it ("checkout": init, remote add, fetch --filter, checkout),
        which marks the promisor remote with remote.origin.promisor, not extensions.partialClone."""
        git(self.repo, "config", "uploadpack.allowFilter", "true")
        git(self.repo, "config", "uploadpack.allowAnySHA1InWant", "true")
        clone = os.path.join(self.tmp.name, f"clone-{way}")
        url = f"file://{self.repo}"
        if way == "clone":
            subprocess.run(["git", "clone", "-q", "--depth", "1", "--filter=blob:none", "--sparse", "--branch",
                            "feat-cmux-next", url, clone], check=True, capture_output=True)
            git(clone, "sparse-checkout", "set", "--no-cone", "scripts/cmux-next/perf-cron.py")
        else:
            subprocess.run(["git", "init", "-q", clone], check=True)
            git(clone, "remote", "add", "origin", url)
            git(clone, "config", "--local", "gc.auto", "0")
            git(clone, "-c", "protocol.version=2", "fetch", "-q", "--no-tags", "--prune", "--no-recurse-submodules",
                "--filter=blob:none", "--depth=1", "origin",
                "+refs/heads/feat-cmux-next:refs/remotes/origin/feat-cmux-next")
            git(clone, "sparse-checkout", "set", "--no-cone", "scripts/cmux-next/perf-cron.py")
            git(clone, "checkout", "-q", "--force", "-B", "feat-cmux-next", "refs/remotes/origin/feat-cmux-next")
        self.assertEqual(git(clone, "rev-parse", "--is-shallow-repository"), "true")
        return clone

    def assert_partial_clone_counted_with_a_few_fetches(self, way):
        for i in range(200):
            self.write(f"{SOURCES}/CmuxNextBrowser/File{i}.swift", f"struct File{i} {{}}\n")
        measured = self.commit("baseline", counts(5, 2))
        self.commit("later 1")
        self.commit("later 2", counts(5, 1))
        clone = self.partial_clone(way)
        self.assertNotEqual(git(clone, "rev-parse", "HEAD"), measured, "the measured sha is HEAD~2, not in the clone")
        trace = os.path.join(self.tmp.name, f"trace-{way}")
        with mock.patch.dict(os.environ, {"GIT_TRACE": trace}):
            out = self.run_report(measured, root=clone)
        self.assertNotIn("error", out)
        point = self.load_state()[report.STATE_KEY][-1]
        self.assertEqual((point["sha"], point["totals"]["stateful_singletons"]), (measured, 5), out)
        with open(trace) as f:
            fetches = [line for line in f if "built-in: git fetch" in line]
        self.assertLessEqual(len(fetches), 3, f"{len(fetches)} fetch processes: the blobs were fetched one by one")

    def test_a_shallow_sparse_blobless_clone_is_counted_with_a_few_fetches(self):
        self.assert_partial_clone_counted_with_a_few_fetches("clone")

    def test_an_actions_checkout_style_partial_clone_is_counted_with_a_few_fetches(self):
        self.assert_partial_clone_counted_with_a_few_fetches("checkout")

    def test_a_rewritten_branch_restarts_the_trend_and_says_so(self):
        a, b, c = self.rise()
        self.run_report(c)
        self.assertEqual([p["sha"] for p in self.load_state()[report.STATE_KEY]], [a, c])
        git(self.repo, "reset", "-q", "--hard", b)  # feat-cmux-next rewritten: c is no longer on it
        d = self.commit("feat: the rewritten singleton", counts(6, 3))
        out = self.run_report(d)
        self.assertIn("the trend restarts at", out)
        self.assertEqual([p["sha"] for p in self.load_state()[report.STATE_KEY]], [a, d],
                         "the point that is not an ancestor is dropped, the next tip adds its point")
        body = self.own_issues()[0]["body"]
        self.assertIn(f"Trend: the trend restarts at {d[:12]}", body)
        self.assertIn(f"{a[:12]}..{d[:12]}", body)
        self.assertIn("feat: the rewritten singleton", body)
        self.assertNotIn("feat: add a browser singleton", body, "the rewritten-away commit is not in the range")
        e = self.commit("docs: later")
        out = self.run_report(e)
        self.assertNotIn("restarts", out)
        self.assertEqual([p["sha"] for p in self.load_state()[report.STATE_KEY]], [a, d, e])

    def test_a_last_point_whose_commit_is_gone_restarts_the_trend(self):
        a = self.commit("baseline", counts(5, 2))
        gone = "f" * 40
        state = self.load_state()
        state[report.STATE_KEY] = [{"sha": gone, "at": "2026-10-22T00:00:00Z", "method_version": 1,
                                    "totals": {"stateful_singletons": 4}, "packages": {}}]
        with open(self.state, "w") as f:
            json.dump(state, f)
        out = self.run_report(a)
        self.assertIn(f"the last point {gone[:12]} is gone", out)
        self.assertEqual([p["sha"] for p in self.load_state()[report.STATE_KEY]], [a])

    def test_a_count_past_the_deadline_is_noted_in_the_issue_in_time(self):
        self.write("scripts/cmux-next/arch_counts.py", "import time\ntime.sleep(60)\n")
        sha = self.commit("a slow counter", counts(5, 2))
        state = self.load_state()
        frozen = copy.deepcopy(state)
        started = time.monotonic()
        out = io.StringIO()
        with mock.patch.object(report, "gh_request", self.gh), mock.patch.object(report, "ISSUE_RESERVE_SECONDS", 3), \
                contextlib.redirect_stdout(out):
            changed = report.run_report(state, sha, "tip", root=self.repo, repo=REPO, issue=True,
                                        deadline=report.Deadline(6))
        self.assertLess(time.monotonic() - started, 30, "the count is stopped at the deadline, not after its sleep")
        self.assertTrue(changed, out.getvalue())
        issue = self.own_issues()[0]
        self.assertIn("ran past the report's deadline", issue["body"])
        self.assertEqual(state[report.ISSUE_KEY], issue["number"])
        self.assertNotIn(report.STATE_KEY, state, "no point from a count that did not finish")
        state.pop(report.ISSUE_KEY)
        self.assertEqual(state, frozen)
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertFalse(report.run_report(state, sha, "tip", root=self.repo, deadline=report.Deadline(0)))
        self.assertEqual(state, frozen, "a deadline that has passed stops the report before it changes anything")

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
        self.assertEqual(hist[-1]["totals"]["stateful_singletons"], 5)
        self.assertEqual((state["schema"], state["regressions"], state["issue"]), (1, [], 7))

    def test_the_trend_table_shows_ratchet_last_values_now_and_arrow(self):
        for v in (5, 4, 4):
            self.run_report(self.commit(f"v{v}", counts(v, 2)))
        out = self.run_report(self.commit("down", counts(3, 2)))
        self.assertIn("| stateful_singletons | 5 | 5 4 4 | 3 | ↓ |", out)
        self.assertIn("| app_lines | - | 100 100 100 | 100 | = |", out, "a report-only row has no ratchet value")
        self.assertNotIn("layer_hard", out, "a row that is 0 everywhere is left out")

    def test_a_missing_ratchet_file_beside_arch_counts_is_noted_in_the_issue(self):
        _, _, c = self.rise()
        self.run_report(c)
        number = self.own_issues()[0]["number"]
        s = self.commit("chore: drop the ratchet", counts(9, 9), ratchet=None)
        out = self.run_report(s)
        self.assertIn(f"left issue #{number} open", out)
        self.assertIn(f"Not judged: no {report.RATCHET_PATH} at {s[:12]}", self.gh.issues[number]["body"])
        self.assertEqual(self.gh.issues[number]["state"], "open")
        self.assertEqual(self.load_state()[report.STATE_KEY][-1]["sha"], s, "the trend point is still kept")

    def test_a_run_that_cannot_judge_opens_the_issue_and_reopens_a_closed_one(self):
        # The counts moved to method v2 without `arch-ratchet.py --update`: every run is "cannot judge".
        a = self.commit("baseline", counts(5, 2))
        self.run_report(a)
        out = self.run_report(self.commit("count v2", counts(9, 9, version=2)))
        issues = self.own_issues()
        self.assertEqual(len(issues), 1, out)
        self.assertIn("opened issue", out)
        self.assertIn("Not judged: the counts are method v2", issues[0]["body"])
        self.run_report(self.commit("update the ratchet file", counts(5, 2)))
        self.assertEqual(self.gh.issues[issues[0]["number"]]["state"], "closed", "a judged good run closes it")
        self.gh.comments.clear()
        out = self.run_report(self.commit("count v2 again", counts(9, 9, version=2)))
        self.assertEqual(self.gh.issues[issues[0]["number"]]["state"], "open", out)
        self.assertIn("reopened issue", out)
        self.assertTrue(self.gh.comments[0][1].startswith("Cannot judge every row"))
        self.assertEqual(len(self.own_issues()), 1)

    def test_a_failed_count_at_a_commit_with_the_ratchet_files_is_noted_in_the_issue(self):
        a = self.commit("baseline", counts(5, 2))
        self.run_report(a)
        points = self.load_state()[report.STATE_KEY]
        bad = {"the counter exits": ("import sys\nsys.exit(3)\n", "gave no counts (exit 3)"),
               "another shape": ("print('{\"totals\": {\"stateful_singletons\": 0}}')\n",
                                 "does not follow the arch_counts contract"),
               "another commit": ("import json\nprint(json.dumps({'method': 'arch_counts', 'method_version': 1, "
                                  "'measured_sha': '0' * 40, 'rows': {'x': {'ratchet': True}}, 'totals': {}, "
                                  "'packages': {}}))\n", "counted '0000"),
               "drop the counter": (None, "arch_counts.py is not in the commit")}
        for subject, (script, expect) in bad.items():
            path = os.path.join(self.repo, "scripts/cmux-next/arch_counts.py")
            if script is None:
                os.remove(path)
            else:
                self.write("scripts/cmux-next/arch_counts.py", script)
            sha = self.commit(subject)
            out = self.run_report(sha)
            issues = self.own_issues()
            self.assertEqual(len(issues), 1, out)
            self.assertEqual(issues[0]["state"], "open")
            self.assertIn(f"Not judged: the count at {sha[:12]} failed:", issues[0]["body"])
            self.assertIn(expect, issues[0]["body"])
            self.assertNotIn("closed issue", out)
            self.assertEqual(self.load_state()[report.STATE_KEY], points, "a failed count adds no point")

    def test_a_commit_without_the_ratchet_files_is_only_logged(self):
        os.remove(os.path.join(self.repo, "scripts/cmux-next/arch_counts.py"))
        before = self.state_text()
        out = self.run_report(self.commit("before the ratchet-file slice", counts(9, 9), ratchet=None))
        self.assertIn("neither scripts/cmux-next/arch_counts.py nor", out)
        self.assertEqual(self.gh.calls, [])
        self.assertEqual(self.state_text(), before)

    def test_an_unreadable_state_is_never_overwritten(self):
        with open(self.state, "w") as f:
            f.write("{not json")
        out = self.run_report(self.commit("x", counts(9, 9)))
        self.assertIn("cannot read the state", out)
        self.assertEqual(self.state_text(), "{not json")
        self.assertIn("bad arguments", self.capture(lambda: report.main(["--state", self.state])))

    def test_an_entry_update_applied_allows_no_new_rise(self):
        # The pending entry E (allow 2) covers a +2; --update records 7 and marks E applied_sha. A later +2 with no new
        # entry (a skip reason, --no-verify, a GitHub merge) is a regression, not "within E" again.
        a = self.commit("baseline", counts(5, 2))
        self.run_report(a)
        e = entry(2)
        b = self.commit("feat: two reviewed singletons, their entry", counts(7, 4), ratchet=ratchet(exceptions=[e]))
        out = self.run_report(b)
        self.assertEqual(self.own_issues(), [], out)
        applied = ratchet(singletons=7, browser=4, measured_sha=b, exceptions=[{**e, "applied_sha": b}])
        out = self.run_report(self.commit("arch-ratchet.py --update", ratchet=applied))
        self.assertEqual(self.own_issues(), [], out)
        out = self.run_report(self.commit("feat: two more, no entry", counts(9, 6), ratchet=applied))
        issues = self.own_issues()
        self.assertEqual(len(issues), 1, out)
        body = issues[0]["body"]
        self.assertIn("| stateful_singletons | CmuxNextBrowser 4→6 | 7 | 9 |", body, out)
        self.assertIn(f"this entry was folded into the total at {b[:12]} (applied_sha)", body)
        self.assertIn(report.exception_key(e), body, "the entry prints without its applied_sha")
        self.assertNotIn("--update", body, "the issue never tells anyone to record an unapproved rise")

    def test_a_pending_entry_raises_the_limit_like_the_pre_push_rule(self):
        self.run_report(self.commit("baseline", counts(5, 2)))
        file = ratchet(exceptions=[entry(1), entry(4, why=" "), entry(4, date="soon"), entry(4, row="no_such_row")])
        out = self.run_report(self.commit("feat: one reviewed singleton, its entry", counts(6, 3), ratchet=file))
        self.assertEqual(self.own_issues(), [], out)
        self.assertIn("run scripts/cmux-next/arch-ratchet.py --update to fold them into the total", out)
        self.assertEqual(out.count("ignored exceptions entry"), 3, out)
        out = self.run_report(self.commit("feat: two more, no entry", counts(8, 5), ratchet=file))
        body = self.own_issues()[0]["body"]
        self.assertIn("| stateful_singletons | CmuxNextBrowser 2→5 | 5 + 1 | 8 |", body, out)
        self.assertIn("+1 of the rise (+3 over the total recorded at 000000000000) is allowed by pending entries", body)
        self.assertIn("The rest (+2) needs the fix.", body)

    def test_a_measured_sha_rebased_away_still_applies_the_pending_entries(self):
        # The file at measured_sha is never read: a measured_sha that was rebased away and never pushed (the brief
        # rebases before every push) neither fails a fetch nor drops the pending allowance.
        file = ratchet(measured_sha="f" * 40, exceptions=[entry(1)])
        self.run_report(self.commit("baseline", counts(5, 2), ratchet=file))
        out = self.run_report(self.commit("feat: one reviewed singleton", counts(6, 3), ratchet=file))
        self.assertEqual(self.own_issues(), [], out)
        self.assertNotIn("fetching", out)
        self.assertNotIn("OVER", out)

    def test_a_kept_point_whose_sha_is_not_a_sha_is_dropped(self):
        a = self.commit("baseline", counts(5, 2))
        state = self.load_state()
        bad = "--output=" + os.path.join(self.tmp.name, "written-by-git")
        state[report.STATE_KEY] = [{"sha": bad, "at": "2026-10-22T00:00:00Z", "method_version": 1,
                                    "totals": {"stateful_singletons": 4}, "packages": {}}]
        with open(self.state, "w") as f:
            json.dump(state, f)
        out = self.run_report(a)
        self.assertNotIn("restarts", out, "the bad point is not a point: there is no trend to restart")
        self.assertEqual([p["sha"] for p in self.load_state()[report.STATE_KEY]], [a])
        self.assertFalse([c for c in self.gh.calls if "--output" in c[1]], "the bad sha never reaches a GitHub path")
        self.assertFalse(os.path.exists(bad.split("=", 1)[1]))

    def test_the_count_does_not_get_the_jobs_token_by_accident(self):
        # Not a security boundary (the child can read its parent's environment): it stops an accidental use only.
        self.write("scripts/cmux-next/arch_counts.py", "import os, sys\nprint(os.environ.get('GH_TOKEN'), file=sys.stderr)\n"
                                                        "sys.exit(1)\n")
        out = self.run_report(self.commit("print the token", counts(5, 2)))
        self.assertIn("gave no counts (exit 1): None", out)

    def test_run_report_in_process_changes_only_its_own_keys(self):
        _, _, c = self.rise()
        state = {"schema": 1, "history": [{"sha": "x"}], report.STATE_KEY: self.load_state()[report.STATE_KEY]}
        with mock.patch.object(report, "gh_request", self.gh), contextlib.redirect_stdout(io.StringIO()):
            changed = report.run_report(state, c, "tip", root=self.repo, repo=REPO, issue=True)
            self.assertTrue(changed)
            self.assertEqual(state[report.STATE_KEY][-1]["sha"], c)
            self.assertEqual(state[report.ISSUE_KEY], self.own_issues()[0]["number"])
            self.assertEqual((state["schema"], state["history"]), (1, [{"sha": "x"}]))
            frozen = copy.deepcopy(state)
            with mock.patch.object(report, "counts_at", side_effect=SystemExit(2)):
                self.assertFalse(report.run_report(state, self.commit("next"), "tip", root=self.repo, repo=REPO))
            self.assertEqual(state, frozen, "an error, also a SystemExit, leaves the state as it was")

    def test_report_finished_counts_the_measurement_perf_cron_just_finished(self):
        _, _, c = self.rise()
        state = {"schema": 1, "history": [{"sha": "x", "kind": "tip"}, {"sha": c, "kind": "tip", "at": "now"}],
                 report.STATE_KEY: self.load_state()[report.STATE_KEY]}
        with mock.patch.object(report, "gh_request", self.gh), contextlib.redirect_stdout(io.StringIO()):
            self.assertTrue(report.report_finished(state, root=self.repo, repo=REPO, issue=True))
            self.assertEqual(state[report.STATE_KEY][-1]["sha"], c)
            frozen = copy.deepcopy(state)
            state["history"].append({"sha": c, "kind": "bisect"})
            self.assertFalse(report.report_finished(state, root=self.repo, repo=REPO, issue=True))
            state["history"] = []
            self.assertFalse(report.report_finished(state, root=self.repo, repo=REPO, issue=True))
        state["history"] = frozen["history"]
        self.assertEqual(state, frozen)

    def test_dry_run_writes_nothing(self):
        _, _, c = self.rise()
        before = self.state_text()
        out = self.run_report(c, "--dry-run")
        self.assertEqual(self.state_text(), before)
        self.assertEqual(self.gh.writes(), [])
        self.assertIn("would open an issue", out)

    def test_no_repository_or_token_keeps_the_point_and_never_calls_github(self):
        _, _, c = self.rise()
        self.gh.calls.clear()
        with mock.patch.dict(os.environ):
            os.environ.pop("GH_TOKEN")
            out = self.run_report(c)
        self.assertIn("no repository or GH_TOKEN: the issue is not kept this run", out)
        self.assertIn("1 row(s) over the limit", out)
        self.assertEqual(self.gh.calls, [], "with no token, no GitHub request is made")
        state = self.load_state()
        self.assertEqual(state[report.STATE_KEY][-1]["sha"], c, "the trend point is still kept")
        self.assertNotIn(report.ISSUE_KEY, state)
        d = self.commit("feat: one more singleton", counts(7, 4))
        before = self.state_text()
        with mock.patch.dict(os.environ):
            os.environ.pop("GITHUB_REPOSITORY")
            out = self.run_report(d, "--dry-run")
        self.assertIn("no repository or GH_TOKEN: the issue is not kept this run", out)
        self.assertEqual(self.gh.calls, [], "with no repository, also a dry run makes no GitHub request")
        self.assertEqual(self.state_text(), before)
        with mock.patch.dict(os.environ):
            os.environ.pop("GH_TOKEN")
            out = self.run_report(d, "--dry-run")
        self.assertIn("no repository or GH_TOKEN: the issue is not kept this run", out)
        self.assertNotIn("cannot keep the issue", out)
        self.assertEqual(self.gh.calls, [], "with a repository but no token, also a dry run makes no GitHub request")
        self.assertEqual(self.state_text(), before)

    def test_the_prefetch_covers_the_local_package_closure_the_count_reads(self):
        # The measured commit's own arch_counts.py names what its count reads (`--read-paths`): CmuxNext and the
        # transitive closure of its local `.package(path:)` dependencies, so the one fetch covers a Shared package.
        with open(os.path.join(HERE, "..", "arch_counts.py")) as f:
            self.write(report.COUNTS_SCRIPT, f.read())
        manifest = 'import PackageDescription\nlet package = Package(name: "{}", dependencies: [{}], targets: [])\n'
        self.write("Packages/macOS/CmuxNext/Package.swift",
                   manifest.format("CmuxNext", '.package(path: "../../Shared/Kit")'))
        self.write("Packages/Shared/Kit/Package.swift", manifest.format("Kit", '.package(path: "../Deep")'))
        self.write("Packages/Shared/Kit/Sources/Kit/Kit.swift", "struct Kit {}\n")
        self.write("Packages/Shared/Deep/Package.swift", manifest.format("Deep", ""))
        self.write("Packages/Shared/Deep/Sources/Deep/Deep.swift", "struct Deep {}\n")
        self.write("Packages/Shared/Other/Package.swift", manifest.format("Other", ""))
        self.write("Packages/Shared/Other/Sources/Other/Other.swift", "struct Other {}\n")
        sha = self.commit("a closure of local packages", counts(5, 2))
        with contextlib.redirect_stdout(io.StringIO()):
            names = {name for _, name in report.count_files(report.Deadline(60), self.repo, sha)}
        for path in ("Packages/Shared/Kit/Package.swift", "Packages/Shared/Kit/Sources/Kit/Kit.swift",
                     "Packages/Shared/Deep/Package.swift", "Packages/Shared/Deep/Sources/Deep/Deep.swift",
                     f"{SOURCES}/CmuxNextApp/App.swift", report.COUNTS_SCRIPT, report.RATCHET_PATH):
            self.assertIn(path, names)
        self.assertNotIn("Packages/Shared/Other/Sources/Other/Other.swift", names, "not linked: not read")

    def capture(self, fn):
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(fn(), 0)
        return out.getvalue()


if __name__ == "__main__":
    unittest.main()
