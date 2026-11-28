"""Stale-ref routing (scripts/ci/stale_route_runs.py; queue janitor category g).

2026-11-28: macos-26 had 9 queued, the oldest 68 minutes. The hogger was run 46126603464, attempt 3 of "iOS simulator
screenshot loop" on PR #63559, whose ref predated cmux#64299 (which routed that workflow off hosted macos-26). A run
follows the workflow file at its own ref and a re-run reuses it, so nothing moved it off the old label. These tests pin
the remedy: an open pull request is base-merged, a merged one's run is shed, and a run whose main copy still asks for
the label is left alone.
"""
from __future__ import annotations

import datetime as dt
import importlib.util
import json
import sys
import tempfile
import unittest
import urllib.parse
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))
sys.path.insert(0, str(ROOT / "scripts/ci"))

import test_ci_queue_janitor as base  # noqa: E402

janitor = base.janitor
stale = sys.modules.get("stale_route_runs")
if stale is None:  # pragma: no cover - the janitor imports it
    spec = importlib.util.spec_from_file_location("stale_route_runs", ROOT / "scripts/ci/stale_route_runs.py")
    stale = importlib.util.module_from_spec(spec)
    sys.modules["stale_route_runs"] = stale
    spec.loader.exec_module(stale)

NOW = base.NOW
iso = base.iso
LABEL = "macos-26"
PATH = ".github/workflows/ios-sim-screenshot-loop.yml"
# Main's copy after cmux#64299 (abridged): `macos-26` stays in comments and in the fork-only arm of runs-on.
RUNS_ON = ("${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || github.event_name == 'pull_request' && "
           "github.event.pull_request.head.repo.full_name != github.repository && 'blacksmith-6vcpu-macos-26' || "
           "github.run_attempt == 1 && vars.CI_PR_POOL_OWNED == '1' && (vars.CI_LIGHT_LANE_RUNNER || "
           "(vars.CI_SIDE_LANE_LABELS != '' && fromJSON(vars.CI_SIDE_LANE_LABELS) || vars.CI_SIDE_LANE_RUNNER)) || "
           "vars.MACOS_RUNNER_26 || 'blacksmith-6vcpu-macos-26' }}")
ROUTED = f"""# Attempt 1 takes the owned side label (CI_PR_POOL_OWNED), a re-run vars.MACOS_RUNNER_26 or Blacksmith macOS;
# only a fork's run uses GitHub's macos-26 (tests/test_ci_no_github_hosted_macos.py).
name: iOS simulator screenshot loop
jobs:
  loop:
    name: composer + terminal keyboard screenshots
    runs-on: {RUNS_ON}
    steps:
      # A fork's run is on GitHub's hosted macos-26 image, which has Xcode 26.6.
      - name: Select Xcode
        env:
          CMUX_CI_XCODE_APP: ${{{{ github.repository_owner != 'manaflow-ai' && '/Applications/Xcode_26.6.app' || '' }}}}
        run: ./scripts/select-ci-xcode.sh
"""
# A workflow main still runs on macos-26.
STILL = "name: CI\njobs:\n  build:\n    runs-on: macos-26  # hosted\n"
CHANGE_SHA = "64299deadbeefcafe0000000000000000000000"
CHANGE_AT = NOW - dt.timedelta(minutes=60)
# cmux#64299's patch to the workflow (abridged).
PATCH = f"""@@ -1,15 +1,16 @@
-# On a GitHub-hosted macOS runner: build the app, boot an iPhone simulator
+# Attempt 1 takes the owned side label (CI_PR_POOL_OWNED), a re-run vars.MACOS_RUNNER_26 or Blacksmith macOS;
+# only a fork's run uses GitHub's macos-26 (tests/test_ci_no_github_hosted_macos.py).
 name: iOS simulator screenshot loop
@@ -31,7 +32,7 @@ concurrency:
   loop:
     name: composer + terminal keyboard screenshots
-    runs-on: macos-26
+    runs-on: {RUNS_ON}
     continue-on-error: true
-      # GitHub's hosted macos-26 image has Xcode 26.6, not the pool pin (27.2); the floor is 26.
+      # A fork's run is on GitHub's hosted macos-26 image, which has Xcode 26.6, not the pool pin (27.2).
-          CMUX_CI_XCODE_APP: /Applications/Xcode_26.6.app
+          CMUX_CI_XCODE_APP: ${{{{ github.repository_owner != 'manaflow-ai' && '/Applications/Xcode_26.6.app' || '' }}}}
"""


def pr_run(*, branch, sha, age, path=PATH, attempt=1, status="queued", base_ref="main"):
    run = base.make_run(branch=branch, sha=sha, age=age, path=path, status=status, attempt=attempt)
    run["pull_requests"] = [{"number": 1, "base": {"ref": base_ref}}]
    return run


def agent_pr(*args, author="cmux-agents-lander[bot]", **kwargs):
    """base.make_pr() plus the author the janitor's PR query reads; None: the read had no author."""
    pr = base.make_pr(*args, **kwargs)
    pr["author"] = None if author is None else {"login": author}
    return pr


def queued_job(label=LABEL):
    return {"status": "queued", "name": "loop", "labels": [label], "created_at": iso(5), "runner_id": None,
            "runner_name": None}


def change():
    return stale.Change(CHANGE_SHA, CHANGE_AT, "main")


def resolve(run, prs):
    return prs[0] if prs else None


class WorkflowCopies:
    def __init__(self, files):
        self.temp = tempfile.TemporaryDirectory()
        self.dir = Path(self.temp.name)
        for name, text in files.items():
            (self.dir / name).write_text(text)

    def __enter__(self):
        return {"main": self.dir}

    def __exit__(self, *exc):
        self.temp.cleanup()


def pool_of(job):
    return [str(label) for label in job.get("labels") or ()]


class PatchTests(unittest.TestCase):
    def test_a_removed_runs_on_line_is_a_routing_change(self):
        self.assertTrue(stale.patch_removes_label(PATCH, LABEL))

    def test_a_patch_that_keeps_the_label_is_not(self):
        self.assertFalse(stale.patch_removes_label("-    runs-on: macos-26\n+    runs-on: [macos-26, large]\n", LABEL))
        self.assertFalse(stale.patch_removes_label("+    runs-on: macos-26\n", LABEL))

    def test_a_longer_label_is_not_the_label(self):
        self.assertFalse(stale.patch_removes_label("-    runs-on: macos-26-xlarge\n", LABEL))
        self.assertFalse(stale.names_label("runs-on: macos-26-xlarge", LABEL))
        self.assertTrue(stale.names_label("runs-on: [MACOS-26]", LABEL))

    def test_comments_and_expressions_do_not_name_the_label(self):
        # The real cmux#64299 copy keeps macos-26 only in comments and the fork-only expression arm.
        self.assertFalse(stale.names_label(ROUTED, LABEL))
        self.assertTrue(stale.names_label(STILL, LABEL))
        self.assertTrue(stale.names_label("runs-on: macos-26 # was macos-15", LABEL))

    def test_file_headers_are_not_lines(self):
        self.assertFalse(stale.patch_removes_label("--- a/macos-26\n+++ b/x\n", LABEL))


class RoutingChangeTests(unittest.TestCase):
    def fake_get(self, details):
        calls = []

        def get(url):
            calls.append(url)
            if "/commits?" in url:
                query = urllib.parse.parse_qs(url.split("?", 1)[1])
                assert query["sha"] == ["main"] and query["path"] == [PATH], url
                return [{"sha": sha} for sha in details]
            return details[url.rsplit("/", 1)[1]]
        return get, calls

    def test_the_commit_that_dropped_the_label_is_named(self):
        details = {
            "newer": {"files": [{"filename": PATH, "status": "modified", "patch": "+# comment\n"}],
                      "commit": {"committer": {"date": "2026-09-22T16:30:00Z"}}},
            CHANGE_SHA: {"files": [{"filename": PATH, "status": "modified", "patch": PATCH}],
                         "commit": {"committer": {"date": "2026-09-22T16:00:00Z"}}},
        }
        get, calls = self.fake_get(details)
        found = stale.routing_change(get, "manaflow-ai/cmux", "main", PATH, LABEL)
        self.assertEqual(found, stale.Change(CHANGE_SHA, CHANGE_AT, "main"))
        self.assertEqual(len(calls), 3)

    def test_no_commit_dropping_it_means_no_change(self):
        details = {"a": {"files": [{"filename": PATH, "status": "modified", "patch": "+    runs-on: macos-26\n"}],
                         "commit": {"committer": {"date": "2026-09-22T16:00:00Z"}}}}
        get, _ = self.fake_get(details)
        self.assertIsNone(stale.routing_change(get, "manaflow-ai/cmux", "main", PATH, LABEL))

    def test_a_deleted_workflow_is_a_routing_change(self):
        details = {"gone": {"files": [{"filename": PATH, "status": "removed", "patch": ""}],
                            "commit": {"committer": {"date": "2026-09-22T16:00:00Z"}}}}
        get, _ = self.fake_get(details)
        self.assertEqual(stale.routing_change(get, "manaflow-ai/cmux", "main", PATH, LABEL).sha, "gone")


class FindSuspectTests(unittest.TestCase):
    def test_a_label_main_no_longer_names_is_a_suspect(self):
        run = pr_run(branch="lane/ios-rust-macname-tags", sha="head", age=68, attempt=3)
        with WorkflowCopies({"ios-sim-screenshot-loop.yml": ROUTED}) as copies:
            found = stale.find_suspects([run], {run["id"]: [queued_job()]}, [LABEL], copies, pool_of=pool_of)
        self.assertEqual([(s.run["id"], s.label, s.branch, s.path) for s in found],
                         [(run["id"], LABEL, "main", PATH)])

    def test_a_run_whose_main_copy_still_targets_the_label_is_left_alone(self):
        run = pr_run(branch="feature", sha="head", age=68, path=".github/workflows/ci.yml")
        with WorkflowCopies({"ci.yml": STILL}) as copies:
            self.assertEqual(stale.find_suspects([run], {run["id"]: [queued_job()]}, [LABEL], copies,
                                                 pool_of=pool_of), [])

    def test_only_saturated_pools_and_unassigned_jobs_count(self):
        run = pr_run(branch="lane/x", sha="head", age=68)
        assigned = dict(queued_job(), runner_name="mac-1")
        with WorkflowCopies({"ios-sim-screenshot-loop.yml": ROUTED}) as copies:
            self.assertEqual(stale.find_suspects([run], {run["id"]: [queued_job()]}, ["other"], copies,
                                                 pool_of=pool_of), [])
            self.assertEqual(stale.find_suspects([run], {run["id"]: [assigned]}, [LABEL], copies,
                                                 pool_of=pool_of), [])
            self.assertEqual(stale.find_suspects([run], {run["id"]: [queued_job()]}, [LABEL], copies,
                                                 pool_of=pool_of, protected=lambda r: "release"), [])

    def test_a_branch_without_a_copy_on_disk_is_not_judged(self):
        run = base.make_run(event="push", branch="lane/x", sha="head", age=68, path=PATH, status="queued")
        with WorkflowCopies({"ios-sim-screenshot-loop.yml": ROUTED}) as copies:
            self.assertEqual(stale.find_suspects([run], {run["id"]: [queued_job()]}, [LABEL], copies,
                                                 pool_of=pool_of), [])


class DecideTests(unittest.TestCase):
    def suspect(self, *, age=68, sha="head"):
        run = pr_run(branch="lane/ios-rust-macname-tags", sha=sha, age=age, attempt=3)
        return stale.Suspect(run, LABEL, "main", PATH)

    def test_open_pull_request_at_the_run_head_is_base_merged(self):
        d = stale.decide(self.suspect(), change(), [agent_pr(63559, head="head")], resolve=resolve)
        self.assertEqual((d.action, d.pr["number"]), ("base-merge", 63559))

    def test_merged_pull_request_run_is_shed(self):
        d = stale.decide(self.suspect(), change(), [agent_pr(63559, state="MERGED", head="head")],
                         resolve=resolve)
        self.assertEqual(d.action, "shed")
        d = stale.decide(self.suspect(), change(), [agent_pr(63559, state="CLOSED", head="head")],
                         resolve=resolve)
        self.assertEqual(d.action, "shed")

    def test_teammate_open_pull_request_is_shed_never_merged_into(self):
        d = stale.decide(self.suspect(), change(), [agent_pr(62888, head="head", author="austinywang")],
                         resolve=resolve)
        self.assertEqual(d.action, "shed")
        self.assertIn("austinywang's", d.note)

    def test_unread_author_is_shed_never_merged_into(self):
        d = stale.decide(self.suspect(), change(), [agent_pr(63678, head="head", author=None)], resolve=resolve)
        self.assertEqual(d.action, "shed")

    def test_teammates_match_red_autofix(self):
        import red_autofix
        self.assertEqual(stale.TEAMMATES, red_autofix.TEAMMATES)

    def test_open_pull_request_that_moved_on_sheds_the_old_head(self):
        d = stale.decide(self.suspect(), change(), [agent_pr(63559, head="newer")], resolve=resolve)
        self.assertEqual(d.action, "shed")

    def test_a_run_created_after_the_change_is_not_stale(self):
        self.assertIsNone(stale.decide(self.suspect(age=30), change(), [agent_pr(63559, head="head")],
                                       resolve=resolve))

    def test_no_routing_change_means_no_decision(self):
        self.assertIsNone(stale.decide(self.suspect(), None, [agent_pr(63559, head="head")], resolve=resolve))

    def test_an_unknown_pull_request_is_kept(self):
        self.assertEqual(stale.decide(self.suspect(), change(), [], resolve=resolve).action, "keep")


class PlanTests(unittest.TestCase):
    def test_one_base_merge_per_pull_request_and_caps(self):
        runs = [pr_run(branch="lane/a", sha="head", age=90 - i) for i in range(3)]
        suspects = [stale.Suspect(run, LABEL, "main", PATH) for run in runs]
        lookups = []

        def lookup(*key):
            lookups.append(key)
            return change()
        decisions = stale.plan(suspects, {"lane/a": [agent_pr(7, head="head")]}, lookup=lookup, resolve=resolve)
        self.assertEqual([d.action for d in decisions], ["base-merge", "keep", "keep"])
        self.assertEqual(lookups, [("main", PATH, LABEL)])

    def test_shed_cap_and_runs_another_category_cancels(self):
        runs = [pr_run(branch=f"lane/{i}", sha="head", age=90 - i) for i in range(3)]
        suspects = [stale.Suspect(run, LABEL, "main", PATH) for run in runs]
        prs = {f"lane/{i}": [agent_pr(i + 1, state="MERGED", head="head")] for i in range(3)}
        decisions = stale.plan(suspects, prs, lookup=lambda *k: change(), resolve=resolve, max_sheds=1,
                               already_cancelled=[runs[0]["id"]])
        self.assertEqual([d.action for d in decisions], ["keep", "shed", "keep"])

    def test_headline_names_the_count_label_and_change(self):
        runs = [pr_run(branch=f"lane/{i}", sha="head", age=90 - i) for i in range(2)]
        decisions = [stale.StaleRoute(run, LABEL, change(), "shed", "merged") for run in runs]
        text, warnings = stale.render(decisions, {}, dry_run=True)
        self.assertIn("2 queued runs ask for macos-26 from refs that predate the routing change in 64299deadb on main",
                      text)
        self.assertTrue(warnings[0].startswith("::warning title=stale-ref routing on macos-26::"))


class StaleRouteGitHub(base.FakeGitHub):
    """FakeGitHub plus the commit reads and update-branch the stale-ref pass makes."""

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.commit_details = {}
        self.updated = []

    def request(self, method, path, body=None, *, app_only=False):
        short = path.replace("/repos/manaflow-ai/cmux", "", 1)
        if method == "GET" and short.startswith("/commits"):
            self.calls += 1
            self.log.append((method, path))
            if short.startswith("/commits?"):
                query = urllib.parse.parse_qs(short.split("?", 1)[1])
                return [{"sha": sha} for sha, detail in self.commit_details.items()
                        if any(f["filename"] == query["path"][0] for f in detail["files"])]
            return self.commit_details[short.rsplit("/", 1)[1]]
        if method == "PUT" and short.startswith("/pulls/") and short.endswith("/update-branch"):
            self.calls += 1
            self.log.append((method, path))
            self.updated.append((int(short.split("/")[2]), (body or {}).get("expected_head_sha")))
            return {"message": "Updating pull request branch."}
        return super().request(method, path, body, app_only=app_only)


class SweepTests(unittest.TestCase):
    """The janitor sweep end to end: macos-26 saturated, one stale-ref run among runs main still sends there."""

    def sweep(self, stale_pr_state, *, dry_run=False, can_merge=True, author="cmux-agents-lander[bot]",
              base_ref="main"):
        hogger = pr_run(branch="lane/ios-rust-macname-tags", sha="head63559", age=68, attempt=3, base_ref=base_ref)
        busy = [pr_run(branch=f"lane/busy-{i}", sha=f"busy{i}", age=20 + i, path=".github/workflows/ci.yml")
                for i in range(8)]
        runs = [hogger, *busy]
        jobs = {run["id"]: [queued_job()] for run in runs}
        fake = StaleRouteGitHub({run["id"]: dict(run) for run in runs}, jobs)
        fake.app_token = can_merge  # cmux-bot's App token (GitHub.app_token); False: the workflow token fallback
        fake.prs = {"lane/ios-rust-macname-tags": [agent_pr(63559, state=stale_pr_state, head="head63559",
                                                                author=author)]}
        fake.prs.update({f"lane/busy-{i}": [agent_pr(100 + i, head=f"busy{i}")] for i in range(8)})
        fake.commit_details = {CHANGE_SHA: {"files": [{"filename": PATH, "status": "modified", "patch": PATCH}],
                                            "commit": {"committer": {"date": iso(60)}}}}
        printed = []
        with tempfile.TemporaryDirectory() as temp:
            workflows = Path(temp) / "workflows"
            workflows.mkdir()
            (workflows / "ci.yml").write_text(STILL)
            argv = []
            if base_ref == "main":
                (workflows / "ios-sim-screenshot-loop.yml").write_text(ROUTED)
            else:
                # cmux#64299's shape: the change landed on base_ref; main's copy still asks for macos-26.
                (workflows / "ios-sim-screenshot-loop.yml").write_text(ROUTED.replace(RUNS_ON, LABEL))
                branch = Path(temp) / base_ref
                branch.mkdir()
                (branch / "ios-sim-screenshot-loop.yml").write_text(ROUTED)
                (branch / "ci.yml").write_text(STILL)
                argv = ["--branch-workflows", f"{base_ref}={branch}"]
            out, summary = Path(temp) / "pool.json", Path(temp) / "summary.md"
            argv += ["--repo", "manaflow-ai/cmux", "--summary", str(summary), "--workflows-dir", str(workflows),
                     "--pool-load", str(out)] + (["--dry-run"] if dry_run else [])
            with mock.patch.object(janitor, "GitHub", lambda token, repo, fallback_token="": fake), \
                    mock.patch.dict("os.environ", {"GH_TOKEN": "t", "CMUX_BOT_TOKEN": "t"}), \
                    mock.patch.object(janitor.time, "sleep", lambda _: None), \
                    mock.patch.object(janitor, "utc_now", lambda: NOW), \
                    mock.patch("builtins.print", lambda *a, **k: printed.append(" ".join(map(str, a)))):
                code = janitor.main(argv)
            snapshot = json.loads(out.read_text())
            text = summary.read_text()
        return code, fake, hogger, busy, snapshot, text, printed

    def cancelled(self, fake):
        return {int(path.split("/")[-2]) for method, path in fake.log if method == "POST" and path.endswith("/cancel")}

    def test_open_pull_request_is_base_merged_not_cancelled(self):
        code, fake, hogger, busy, snapshot, text, printed = self.sweep("OPEN")
        self.assertEqual(code, 0)
        self.assertEqual(fake.updated, [(63559, "head63559")])
        self.assertNotIn(hogger["id"], self.cancelled(fake))
        self.assertIn("1 queued run asks for macos-26 from refs that predate the routing change in 64299deadb", text)
        self.assertEqual(snapshot["stale_routes"][0]["base_merged"], [63559])
        self.assertTrue(any(line.startswith("::warning title=stale-ref routing on macos-26::") for line in printed))

    def test_merged_pull_request_run_is_shed(self):
        code, fake, hogger, busy, snapshot, text, printed = self.sweep("MERGED")
        self.assertEqual(code, 0)
        self.assertEqual(fake.updated, [])
        self.assertIn(hogger["id"], self.cancelled(fake))

    def test_runs_main_still_sends_to_the_label_are_left_alone(self):
        code, fake, hogger, busy, snapshot, text, printed = self.sweep("OPEN")
        self.assertFalse({run["id"] for run in busy} & self.cancelled(fake))
        self.assertEqual(snapshot["stale_routes"][0]["runs"], [hogger["id"]])
        self.assertEqual([n for n, _ in fake.updated], [63559])

    def test_without_cmux_bot_the_open_pull_request_is_named_not_merged(self):
        code, fake, hogger, busy, snapshot, text, printed = self.sweep("OPEN", can_merge=False)
        self.assertEqual(fake.updated, [])
        self.assertIn("keep (base merge needs cmux-bot's token)", text)
        warning = next(line for line in printed if line.startswith("::warning title=stale-ref routing"))
        self.assertNotIn("base-merged", warning)

    def test_teammate_open_pull_request_run_is_shed_not_merged_into(self):
        code, fake, hogger, busy, snapshot, text, printed = self.sweep("OPEN", author="austinywang")
        self.assertEqual(code, 0)
        self.assertEqual(fake.updated, [])
        self.assertIn(hogger["id"], self.cancelled(fake))
        self.assertIn("austinywang's", text)

    def test_feat_cmux_next_change_base_merges_its_pull_request(self):
        """The 2026-11-28 incident: #64299 landed on feat-cmux-next, whose copy the PR run follows."""
        code, fake, hogger, busy, snapshot, text, printed = self.sweep("OPEN", base_ref="feat-cmux-next")
        self.assertEqual(code, 0)
        self.assertEqual(fake.updated, [(63559, "head63559")])
        self.assertIn("routing change in 64299deadb on feat-cmux-next", text)

    def test_dry_run_writes_nothing(self):
        code, fake, hogger, busy, snapshot, text, printed = self.sweep("OPEN", dry_run=True)
        self.assertEqual(fake.updated, [])
        self.assertIn("would base-merge PR #63559", "\n".join(printed))


if __name__ == "__main__":
    unittest.main()
