#!/usr/bin/env python3
"""The cmux NEXT nightly release train (scripts/ci/nightly_next_train.py,
scripts/ci/nightly_next_train_drive.py, nightly-next-train.yml,
nightly-next-verdict.yml; docs/ci/nightly-next-train.md).

Candidates, reverts and the G1' tree check run real git in a scratch
repository; GitHub is a fake."""
from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
CI = ROOT / "scripts" / "ci"
sys.path.insert(0, str(CI))


def load(name: str, file: str):
    spec = importlib.util.spec_from_file_location(name, CI / file)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


train = load("nightly_next_train", "nightly_next_train.py")
drive = load("nightly_next_train_drive", "nightly_next_train_drive.py")
fix_forward = load("nightly_next_fix_forward", "nightly_next_fix_forward.py")

REPO = "manaflow-ai/cmux"
ENV = {"GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com", "GIT_COMMITTER_NAME": "t",
       "GIT_COMMITTER_EMAIL": "t@example.com", "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_SYSTEM": os.devnull}


class Repo:
    """A scratch repository; the train module's git() runs in the cwd."""

    def __init__(self) -> None:
        self.dir = tempfile.TemporaryDirectory()
        self.old = os.getcwd()
        os.chdir(self.dir.name)
        self.saved = {k: os.environ.get(k) for k in ENV}
        os.environ.update(ENV)
        self.git("init", "-q", "-b", "feat-cmux-next")

    def close(self) -> None:
        os.chdir(self.old)
        for key, value in self.saved.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value
        self.dir.cleanup()

    def git(self, *args: str) -> str:
        return subprocess.run(["git", *args], check=True, capture_output=True, text=True).stdout.strip()

    def commit(self, subject: str, files: dict[str, str]) -> str:
        for path, text in files.items():
            Path(path).parent.mkdir(parents=True, exist_ok=True)
            Path(path).write_text(text, encoding="utf-8")
        self.git("add", "-A")
        self.git("commit", "-q", "-m", subject)
        return self.git("rev-parse", "HEAD")


def lines(*values: str) -> str:
    return "".join(f"{v}\n" for v in values)


class FakeApi:
    def __init__(self, pulls: dict[int, dict], activity: list[dict]) -> None:
        self.pulls, self.activity = pulls, activity

    def __call__(self, path: str, paginate: bool = False):
        self.calls = getattr(self, "calls", 0) + 1
        if path.startswith(f"repos/{REPO}/pulls?state=closed&base=feat-cmux-next"):
            page = int(re.search(r"[?&]page=(\d+)", path).group(1))
            return list(self.pulls.values()) if page == 1 and getattr(self, "listed", True) else []
        match = re.fullmatch(rf"repos/{REPO}/pulls/(\d+)", path)
        if match:
            if int(match.group(1)) not in self.pulls:
                raise train.TrainError("404")
            return self.pulls[int(match.group(1))]
        if path.startswith(f"repos/{REPO}/activity"):
            page = int(re.search(r"[?&]page=(\d+)", path).group(1))
            return self.activity if page == 1 else []
        raise AssertionError(f"unexpected api {path}")


class History(unittest.TestCase):
    """base -> pr-1 (a.txt) -> push (b.txt, 2 commits) -> pr-3 (a.txt, on
    pr-1's line) -> pr-4 (c.txt)."""

    def setUp(self) -> None:
        self.repo = Repo()
        r = self.repo
        self.base = r.commit("base", {"a.txt": lines("one", "two"), "b.txt": lines("b"), "c.txt": lines("c")})
        self.c1 = r.commit("Change a (#1)", {"a.txt": lines("ONE", "two")})
        self.p1 = r.commit("push one", {"b.txt": lines("b", "b2")})
        self.p2 = r.commit("push two", {"b.txt": lines("b", "b2", "b3")})
        self.c3 = r.commit("Change a again (#3)", {"a.txt": lines("ONE!", "two")})
        self.c4 = r.commit("Change c (#4)", {"c.txt": lines("c", "c4")})
        pull = lambda n, sha, user, labels=(): {  # noqa: E731
            "number": n, "merge_commit_sha": sha, "merged_at": "2026-10-20T00:00:00Z", "title": f"PR {n}",
            "user": {"login": user}, "merged_by": {"login": "lander"}, "labels": [{"name": x} for x in labels]}
        self.api = FakeApi(
            {1: pull(1, self.c1, "alice"), 3: pull(3, self.c3, "carol"), 4: pull(4, self.c4, "dave", ["nightly-hold"])},
            [{"before": self.c1, "after": self.p2, "actor": {"login": "bob"}}],
        )
        self.cars = train.plan_cars(self.base, self.c4, REPO, api=self.api)

    def tearDown(self) -> None:
        self.repo.close()

    def ids(self) -> list[str]:
        return [car.id for car in self.cars]

    def tree_file(self, commit: str, path: str) -> str:
        return self.repo.git("show", f"{commit}:{path}")

    def test_cars_by_pr_and_by_push_with_owners(self) -> None:
        self.assertEqual(self.ids(), ["pr-1", f"push-{self.p2[:12]}", "pr-3", "pr-4"])
        by_id = {car.id: car for car in self.cars}
        self.assertEqual(by_id["pr-1"].owner, "alice")
        self.assertEqual(by_id["pr-1"].merger, "lander")
        push = by_id[f"push-{self.p2[:12]}"]
        self.assertEqual((push.kind, push.owner, push.commits), ("push", "bob", [self.p1, self.p2]))
        self.assertEqual(push.files, ["b.txt"])
        self.assertTrue(by_id["pr-4"].held)
        self.assertFalse(by_id["pr-3"].held)

    def test_prs_come_from_one_listing_not_one_call_each(self) -> None:
        self.api.calls = 0
        train.plan_cars(self.base, self.c4, REPO, api=self.api)
        self.assertEqual(self.api.calls, 2)  # one activity page, one PR page
        self.api.listed, self.api.calls = False, 0
        cars = train.plan_cars(self.base, self.c4, REPO, api=self.api)
        self.assertIn("pr-3", [car.id for car in cars])  # the per-PR fallback
        self.assertEqual(self.api.calls, 2 + 3)

    def test_a_pr_subject_whose_merge_sha_differs_is_not_that_pr(self) -> None:
        self.api.pulls[3]["merge_commit_sha"] = "f" * 40
        ids = [car.id for car in train.plan_cars(self.base, self.c4, REPO, api=self.api)]
        self.assertNotIn("pr-3", ids)
        self.assertIn(f"commit-{self.c3[:12]}", ids)

    def test_a_clean_quarantine_reverts_only_that_car(self) -> None:
        made = train.make_train_commit(self.base, self.c4, self.cars, ["pr-4"])
        self.assertEqual(made["quarantined"], ["pr-4"])
        self.assertEqual(self.tree_file(made["commit"], "c.txt"), "c")
        self.assertEqual(self.tree_file(made["commit"], "a.txt"), "ONE!\ntwo")
        self.assertEqual(self.repo.git("rev-list", "--parents", "-n1", made["commit"]).split()[1:], [self.base, self.c4])
        self.assertEqual(train.verify_train_commit(made["commit"])["ok"], True)

    def test_a_conflicting_revert_pulls_in_the_later_car(self) -> None:
        made = train.make_train_commit(self.base, self.c4, self.cars, ["pr-1"])
        self.assertEqual(made["quarantined"], ["pr-1", "pr-3"])
        self.assertEqual(made["with"], {"pr-3": "pr-1"})
        self.assertEqual(self.tree_file(made["commit"], "a.txt"), "one\ntwo")
        message = self.repo.git("log", "-1", "--format=%B", made["commit"])
        self.assertIn("pr-3 (quarantined with pr-1)", message)
        self.assertIn(train.TRAILER, message)
        self.assertEqual(train.verify_train_commit(made["commit"])["ok"], True)

    def test_no_quarantine_is_the_tip_tree(self) -> None:
        made = train.make_train_commit(self.base, self.c4, self.cars, [])
        self.assertEqual(self.repo.git("rev-parse", f"{made['commit']}^{{tree}}"), self.repo.git("rev-parse", f"{self.c4}^{{tree}}"))
        self.assertTrue(train.verify_train_commit(made["commit"])["ok"])

    def test_g1_prime_refuses_a_tree_that_is_not_its_reverts(self) -> None:
        made = train.make_train_commit(self.base, self.c4, self.cars, ["pr-4"])
        message = self.repo.git("log", "-1", "--format=%B", made["commit"]) + "\n"
        # Same trailers, but the tip's tree (pr-4 still in): a forged list.
        forged = subprocess.run(["git", "commit-tree", f"{self.c4}^{{tree}}", "-p", self.base, "-p", self.c4, "-F", "-"],
                                input=message, check=True, capture_output=True, text=True).stdout.strip()
        verdict = train.verify_train_commit(forged)
        self.assertFalse(verdict["ok"])
        self.assertIn("listed revert", verdict["reason"])
        plain = train.verify_train_commit(self.c4)
        self.assertFalse(plain["ok"])
        bad = train.main(["verify", "--commit", forged])
        self.assertEqual(bad, 1)

    def test_g1_prime_refuses_a_revert_outside_the_tip(self) -> None:
        # "Reverting" an off-branch commit that deletes evil.sh adds evil.sh.
        r = self.repo
        r.git("checkout", "-q", "-b", "side", self.base)
        r.commit("add evil", {"evil.sh": "boom\n"})
        Path("evil.sh").unlink()
        evil = r.commit("drop evil", {})
        r.git("checkout", "-q", "feat-cmux-next")
        tree, failed, _ = train.apply_reverts(self.c4, [evil])
        self.assertIsNone(failed)
        message = f"nightly-next train: x\n\n{train.TRAILER}\n{train.REVERT_TRAILER} {evil}\n"
        forged = subprocess.run(["git", "commit-tree", tree, "-p", self.base, "-p", self.c4, "-F", "-"],
                                input=message, check=True, capture_output=True, text=True).stdout.strip()
        self.assertEqual(r.git("show", f"{forged}:evil.sh"), "boom")
        verdict = train.verify_train_commit(forged)
        self.assertFalse(verdict["ok"])
        self.assertIn("not in the history", verdict["reason"])

    def test_a_carried_car_keeps_its_hold_label(self) -> None:
        made = train.make_train_commit(self.base, self.c4, self.cars, ["pr-1"])
        _, carried = train.source_base(made["commit"])
        self.api.pulls[1]["labels"] = [{"name": "nightly-hold"}]
        cars = train.plan_cars(self.c4, self.c4, REPO, api=self.api, carried=carried)
        self.assertTrue({car.id: car for car in cars}["pr-1"].held)
        self.api.pulls[1]["labels"] = []
        _, carried = train.source_base(made["commit"])
        cars = train.plan_cars(self.c4, self.c4, REPO, api=self.api, carried=carried)
        self.assertFalse({car.id: car for car in cars}["pr-1"].held)

    def test_a_shipped_train_carries_its_quarantine_into_the_next(self) -> None:
        made = train.make_train_commit(self.base, self.c4, self.cars, ["pr-1"])
        src, carried = train.source_base(made["commit"])
        self.assertEqual(src, self.c4)
        self.assertEqual([car.id for car in carried], ["pr-1", "pr-3"])
        self.assertEqual(carried[0].commits, [self.c1])
        self.assertTrue(all(car.carried for car in carried))
        c5 = self.repo.commit("Change d (#5)", {"d.txt": lines("d")})
        self.api.pulls[5] = {**self.api.pulls[1], "number": 5, "merge_commit_sha": c5, "labels": []}
        cars = train.plan_cars(src, c5, REPO, api=self.api, carried=carried)
        self.assertEqual([car.id for car in cars], ["pr-1", "pr-3", "pr-5"])
        # The carried cars still revert cleanly on the new tip: the next train
        # keeps them out until a fix lands.
        again = train.make_train_commit(made["commit"], c5, cars, ["pr-1", "pr-3"])
        self.assertEqual(self.tree_file(again["commit"], "a.txt"), "one\ntwo")
        self.assertEqual(self.tree_file(again["commit"], "d.txt"), "d")
        self.assertTrue(train.verify_train_commit(again["commit"])["ok"])

    def test_the_drive_refuses_a_base_that_names_cars_off_the_tip(self) -> None:
        # A crafted base (a dispatch's good_build) can name any commit in its
        # trailers; the car guards would check it out with the release App
        # token held, so the drive refuses anything off the tip's history.
        made = train.make_train_commit(self.base, self.c4, self.cars, ["pr-1"])
        src, carried = train.source_base(made["commit"])
        cars = train.plan_cars(src, self.c4, REPO, api=self.api, carried=carried)
        train.require_on_tip(src, cars, self.c4)
        r = self.repo
        r.git("checkout", "-q", "-b", "side", self.base)
        evil = r.commit("unreviewed (#9)", {"evil.sh": "boom\n"})
        r.git("checkout", "-q", "feat-cmux-next")
        forged = train.Car(id="pr-9", kind="pr", commits=[evil], pr=9, carried=True)
        with self.assertRaisesRegex(train.TrainError, "car pr-9 names"):
            train.require_on_tip(src, cars + [forged], self.c4)
        with self.assertRaisesRegex(train.TrainError, "source"):
            train.require_on_tip(evil, cars, self.c4)
        short = train.Car(id="pr-8", kind="pr", commits=[self.c1[:12]], pr=8, carried=True)
        with self.assertRaisesRegex(train.TrainError, "car pr-8 names"):
            train.require_on_tip(src, cars + [short], self.c4)

    def test_a_prefix_candidate_is_a_real_commit_minus_later_carried_cars(self) -> None:
        head, reverts = train.prefix_candidate(self.cars, 2, ["pr-1"], self.base)
        self.assertEqual(head, self.p2)
        self.assertEqual(reverts, ["pr-1"])
        made = train.make_train_commit(self.base, head, self.cars, reverts)
        self.assertEqual(self.tree_file(made["commit"], "a.txt"), "one\ntwo")
        # Later cars are not in the prefix's history: nothing to revert.
        later = train.build_candidate(self.p2, self.cars, ["pr-4"])
        self.assertEqual(later["quarantined"], [])

    def test_the_cli_plans_and_writes_the_summary(self) -> None:
        out = Path("train.json")
        summary = Path("summary.md")
        orig = train.gh_api
        train.gh_api = self.api
        try:
            plan_args = ["plan", "--tip", self.c4, "--base-commit", self.base, "--repo", REPO,
                         "--out", str(out), "--summary", str(summary)]
            # plan_cars' default api is bound at definition; pass through main.
            orig_plan = train.plan_cars
            train.plan_cars = lambda b, t, r, carried=(): orig_plan(b, t, r, api=self.api, carried=carried)
            try:
                self.assertEqual(train.main(plan_args), 0)
            finally:
                train.plan_cars = orig_plan
        finally:
            train.gh_api = orig
        doc = json.loads(out.read_text())
        self.assertEqual(doc["tip"], self.c4)
        self.assertEqual(doc["held"], ["pr-4"])
        self.assertIn("| pr-4 | dave |", summary.read_text())
        self.assertEqual(train.main(["candidate", "--tip", self.c4, "--parent", self.base, "--quarantine", "pr-4",
                                     "--train", str(out), "--out", "cand.json"]), 0)
        self.assertEqual(train.main(["verify", "--commit", json.loads(Path("cand.json").read_text())["commit"]]), 0)


class Bisection(unittest.TestCase):
    def test_points_split_the_range_k_ways(self) -> None:
        self.assertEqual(train.bisect_points(0, 40, 4), [8, 16, 24, 32])
        self.assertEqual(train.bisect_points(0, 2, 4), [1])
        self.assertEqual(train.bisect_points(3, 4, 4), [])

    def test_narrow_keeps_the_first_red_prefix(self) -> None:
        self.assertEqual(train.narrow(0, 40, {8: True, 16: False, 24: False, 32: True}), (8, 16))
        self.assertEqual(train.narrow(0, 40, {8: True, 16: True, 24: True, 32: True}), (32, 40))


class FakeBuilder:
    """Green unless the candidate holds the culprit car and does not revert it."""

    def __init__(self, cars: list, culprits: set[str], silent: bool = False) -> None:
        self.index = {car.commits[-1]: i for i, car in enumerate(cars)}
        self.cars, self.culprits, self.silent = cars, culprits, silent
        self.rounds: list[int] = []

    def build(self, commits, deadline):
        self.rounds.append(len(commits))
        out = {}
        for commit, _ in commits:
            head, _, out_ids = commit.partition("|")
            reverted = set(filter(None, out_ids.split(",")))
            upto = self.index.get(head, -1)
            held = {car.id for car in self.cars[:upto + 1]} - reverted
            out[commit] = None if self.silent else not (held & self.culprits)
        return out


def fake_commit(parent, head, cars, quarantine, title=None):
    q = list(dict.fromkeys(quarantine))
    return {"commit": f"{head}|{','.join(sorted(q))}", "quarantined": q, "with": {}}


def cars_of(n: int) -> list:
    return [train.Car(id=f"pr-{i}", kind="pr", commits=[f"{i:040x}"], pr=i) for i in range(n)]


class TrainLoop(unittest.TestCase):
    def run_train(self, n, culprits, clock=None, silent=False, config=None):
        cars = cars_of(n)
        builder = FakeBuilder(cars, {f"pr-{c}" for c in culprits}, silent)
        runner = drive.Train(cars, cars[-1].commits[-1], "p" * 40, "s" * 40, builder, config or drive.Config(),
                             clock=clock or (lambda: 0.0), make_commit=fake_commit, log=lambda _: None)
        return runner.run([]), builder

    def test_green_candidate_ships_with_one_build(self) -> None:
        outcome, builder = self.run_train(40, [])
        self.assertTrue(outcome.shipped)
        self.assertEqual(builder.rounds, [1])
        self.assertEqual(outcome.quarantined, [])

    def test_one_culprit_in_40_cars_takes_3_rounds_of_4(self) -> None:
        outcome, builder = self.run_train(40, [13])
        self.assertTrue(outcome.shipped, outcome.reason)
        self.assertEqual(outcome.culprits, ["pr-13"])
        self.assertEqual(outcome.quarantined, ["pr-13"])
        self.assertLessEqual(outcome.rounds, 3)
        self.assertTrue(all(size <= 4 for size in builder.rounds[1:-1]))

    def test_two_culprits_are_both_quarantined(self) -> None:
        outcome, _ = self.run_train(20, [3, 17], config=drive.Config(rounds=6))
        self.assertTrue(outcome.shipped, outcome.reason)
        self.assertEqual(sorted(outcome.culprits), ["pr-17", "pr-3"])

    def test_the_round_cap_ships_nothing(self) -> None:
        outcome, _ = self.run_train(200, [150], config=drive.Config(k=1, rounds=3))
        self.assertFalse(outcome.shipped)
        self.assertIn("3 bisection rounds", outcome.reason)
        self.assertIn("the current nightly stays", outcome.reason)

    def test_the_time_cap_ships_nothing(self) -> None:
        ticks = iter([0.0, 0.0] + [7201.0] * 50)
        outcome, _ = self.run_train(40, [13], clock=lambda: next(ticks))
        self.assertFalse(outcome.shipped)
        self.assertIn("120-minute cap", outcome.reason)

    def test_no_build_result_ships_nothing(self) -> None:
        outcome, _ = self.run_train(5, [], silent=True)
        self.assertFalse(outcome.shipped)
        self.assertIn("no result", outcome.reason)

    def test_config_defaults_and_bounds(self) -> None:
        self.assertEqual(drive.Config.from_env({}), drive.Config(k=4, rounds=3, cap_minutes=120))
        self.assertEqual(drive.Config.from_env({"NIGHTLY_NEXT_TRAIN_K": "6"}).k, 6)
        for bad in ({"NIGHTLY_NEXT_TRAIN_K": "0"}, {"NIGHTLY_NEXT_TRAIN_CAP_MINUTES": "9999"}, {"NIGHTLY_NEXT_TRAIN_ROUNDS": "x"}):
            with self.assertRaises(train.TrainError):
                drive.Config.from_env(bad)

    def test_the_fix_forward_suspect_starts_out(self) -> None:
        cars = cars_of(3)
        self.assertEqual(drive.suspect_car(cars, cars[1].commits[0]), "pr-1")
        self.assertIsNone(drive.suspect_car(cars, "f" * 40))
        self.assertIsNone(drive.suspect_car(cars, ""))
        with self.assertRaises(train.TrainError):
            drive.suspect_car(cars, "nope")


class Verdicts(unittest.TestCase):
    BUILD = "3947349329001"
    COMMIT = "a" * 40

    def api(self, run=None, jobs=None, head_branch="nightly-next"):
        def call(path, paginate=False):
            if path == f"repos/{REPO}/actions/runs/39473493290":
                return {"head_branch": head_branch, "head_sha": self.COMMIT, "event": "push",
                        "head_repository": {"full_name": REPO}}
            if path == f"repos/{REPO}/actions/runs/555":
                return run if run is not None else {"path": train.CANARY_WORKFLOW, "event": "schedule", "repository": {"full_name": REPO}}
            if path.startswith(f"repos/{REPO}/actions/runs/555/jobs"):
                return {"jobs": jobs if jobs is not None else [{"name": f"canary {self.BUILD}", "status": "completed", "conclusion": "success"},
                                                               {"name": f"verdict pass {self.BUILD}", "status": "in_progress"}]}
            raise AssertionError(path)
        return call

    def test_a_pass_from_a_scheduled_green_canary(self) -> None:
        doc = train.checked_verdict(self.api(), REPO, self.BUILD, "pass", "555", now=lambda: "T")
        self.assertEqual(doc, {"schema": 1, "build": self.BUILD, "verdict": "pass", "commit": self.COMMIT,
                               "canaryRun": f"https://github.com/{REPO}/actions/runs/555", "checkedAt": "T"})

    def test_a_pass_needs_the_canary_job_green(self) -> None:
        with self.assertRaises(train.TrainError):
            train.checked_verdict(self.api(jobs=[{"name": f"canary {self.BUILD}", "status": "completed", "conclusion": "failure"}]),
                                  REPO, self.BUILD, "pass", "555")
        with self.assertRaises(train.TrainError):
            train.checked_verdict(self.api(run={"path": train.CANARY_WORKFLOW, "event": "workflow_dispatch", "repository": {"full_name": REPO}}),
                                  REPO, self.BUILD, "pass", "555")

    def test_a_skipped_canary_is_no_pass(self) -> None:
        # The canary job succeeds on a skip too; the run's verdict job says skipped.
        jobs = [{"name": f"canary {self.BUILD}", "status": "completed", "conclusion": "success"},
                {"name": f"verdict skipped {self.BUILD}", "status": "in_progress"}]
        with self.assertRaises(train.TrainError):
            train.checked_verdict(self.api(jobs=jobs), REPO, self.BUILD, "pass", "555")

    def test_a_verdict_needs_a_canary_run_and_a_nightly_next_build(self) -> None:
        with self.assertRaises(train.TrainError):
            train.checked_verdict(self.api(run={"path": ".github/workflows/other.yml", "event": "schedule", "repository": {"full_name": REPO}}),
                                  REPO, self.BUILD, "fail", "555")
        with self.assertRaises(train.TrainError):
            train.checked_verdict(self.api(head_branch="main"), REPO, self.BUILD, "fail", "555")
        with self.assertRaises(train.TrainError):
            train.checked_verdict(self.api(), REPO, self.BUILD, "maybe", "555")
        doc = train.checked_verdict(self.api(jobs=[]), REPO, self.BUILD, "fail", "555")
        self.assertEqual(doc["verdict"], "fail")

    def test_the_base_is_the_newest_passing_feed_build(self) -> None:
        feed = "".join(f"<item><sparkle:version>{b}</sparkle:version></item>" for b in ("100", "300", "200"))
        self.assertEqual(train.feed_builds(feed), ["300", "200", "100"])
        docs = {"300": {"build": "300", "verdict": "fail", "commit": "c" * 40},
                "200": {"build": "200", "verdict": "pass", "commit": "b" * 40},
                "100": {"build": "100", "verdict": "pass", "commit": "a" * 40}}
        fetch = lambda url: json.dumps(docs[url.rsplit("/", 1)[1][:-5]]).encode() if url.rsplit("/", 1)[1][:-5] in docs else None  # noqa: E731
        self.assertEqual(train.last_good(feed, fetch, "https://x/verdicts"), {"build": "200", "commit": "b" * 40, "source": "verdict"})
        docs["200"]["build"] = "999"  # a document for another build does not count
        self.assertEqual(train.last_good(feed, fetch, "https://x/verdicts")["build"], "100")
        self.assertIsNone(train.last_good(feed, lambda url: None, "https://x/verdicts"))

    def test_the_verdicts_sit_next_to_the_next_feed(self) -> None:
        self.assertEqual(train.FEED, "https://files-next.cmux.com/nightly-next/next/appcast-arm64.xml")
        self.assertEqual(train.VERDICTS, train.FEED.rsplit("/", 1)[0] + "/verdicts")


class OwnedRefusal(unittest.TestCase):
    """A compile an owned Mac refused, or never ran, is re-run once and then judged on Blacksmith."""

    SETUP = {"name": "Set up job", "conclusion": "failure"}

    def job(self, labels, conclusion, steps):
        return {"name": drive.GATE_JOB, "labels": labels, "conclusion": conclusion, "steps": steps}

    def test_only_an_owned_job_that_never_ran_its_steps_is_refused(self) -> None:
        owned = ["glaeda-side-std-xcode-26.6"]
        self.assertTrue(drive.refused_on_owned(self.job(owned, "failure", [])))
        self.assertTrue(drive.refused_on_owned(self.job(owned, "failure", [self.SETUP, {"name": "Complete job", "conclusion": "success"}])))
        self.assertTrue(drive.refused_on_owned(self.job(owned, "cancelled", [{"name": "Set up job", "conclusion": "success"}])))
        lost_after_setup = [{"name": "Set up job", "conclusion": "success"}, {"name": "Complete job", "conclusion": "success"}]
        self.assertTrue(drive.refused_on_owned(self.job(owned, "failure", lost_after_setup)))
        compile_red = [{"name": "Set up job", "conclusion": "success"}, {"name": "Release compile", "conclusion": "failure"}]
        self.assertFalse(drive.refused_on_owned(self.job(owned, "failure", compile_red)))
        self.assertFalse(drive.refused_on_owned(self.job(["blacksmith-6vcpu-macos-26"], "failure", [])))
        self.assertFalse(drive.refused_on_owned(self.job(owned, "success", [])))
        self.assertFalse(drive.refused_on_owned(None))

    def test_a_refused_compile_is_re_run_once_then_read(self) -> None:
        commit = "c" * 40
        refused = self.job(["glaeda-side-std-xcode-26.6"], "failure", [self.SETUP])
        green = self.job(["blacksmith-6vcpu-macos-26"], "success", [{"name": "Release compile", "conclusion": "success"}])
        # The second poll still shows attempt 1 completed (GitHub has not started the re-run): no second re-run.
        polls = iter([({"id": 7, "status": "completed", "run_attempt": 1}, refused),
                      ({"id": 7, "status": "completed", "run_attempt": 1}, refused),
                      ({"id": 7, "status": "in_progress", "run_attempt": 2}, None),
                      ({"id": 7, "status": "completed", "run_attempt": 2}, green)])
        calls, state = [], {}

        def fake_gh(*args, **_):
            calls.append(args)
            if args[:2] in (("workflow", "run"), ("run", "rerun")):
                return ""
            if "/jobs?" in args[1]:
                return json.dumps({"jobs": [state["job"]] if state["job"] else []})
            run, state["job"] = next(polls)
            return json.dumps({"workflow_runs": [dict(run, head_sha=commit)]})

        builder = drive.GitHubBuilder("o/r", "1", poll_seconds=0, sleep=lambda _: None)
        original_gh, original_git = drive.gh, drive.train.git
        drive.gh, drive.train.git = fake_gh, lambda *a, **k: ""
        try:
            results = builder.build([(commit, "candidate")], deadline=float("inf"))
        finally:
            drive.gh, drive.train.git = original_gh, original_git
        self.assertEqual(results, {commit: True})
        self.assertEqual([c for c in calls if c[:2] == ("run", "rerun")],
                         [("run", "rerun", "7", "--failed", "--repo", "o/r")])

    def test_a_compile_red_on_an_owned_mac_is_red(self) -> None:
        commit = "d" * 40
        red = self.job(["glaeda-side-std-xcode-26.6"], "failure",
                       [{"name": "Set up job", "conclusion": "success"}, {"name": "Release compile", "conclusion": "failure"}])
        calls = []

        def fake_gh(*args, **_):
            calls.append(args)
            if args[:2] == ("workflow", "run"):
                return ""
            if "/jobs?" in args[1]:
                return json.dumps({"jobs": [red]})
            return json.dumps({"workflow_runs": [{"id": 8, "status": "completed", "run_attempt": 1, "head_sha": commit}]})

        builder = drive.GitHubBuilder("o/r", "1", poll_seconds=0, sleep=lambda _: None)
        original_gh, original_git = drive.gh, drive.train.git
        drive.gh, drive.train.git = fake_gh, lambda *a, **k: ""
        try:
            results = builder.build([(commit, "candidate")], deadline=float("inf"))
        finally:
            drive.gh, drive.train.git = original_gh, original_git
        self.assertEqual(results, {commit: False})
        self.assertFalse([c for c in calls if c[:2] == ("run", "rerun")])

    def test_the_compile_picks_an_idle_owned_mac_then_blacksmith(self) -> None:
        import yaml
        jobs = yaml.safe_load((ROOT / ".github/workflows/nightly-next-train.yml").read_text(encoding="utf-8"))["jobs"]
        pick = jobs["pick-train-runner"]
        self.assertEqual(pick["environment"], "ci-routing-agent")
        self.assertIn("nightly_build_runner.py", pick["steps"][-1]["run"])
        self.assertNotIn("DEDICATED_LABEL", pick["steps"][-1]["env"])
        # vars.NIGHTLY_NEXT_TRAIN_RUNNER reaches only OWNED_LABELS, and the picker offers no hosted Mac from it.
        picker = load("nightly_build_runner", "nightly_build_runner.py")
        for label in ("macos-26", "macos-latest", "blacksmith-6vcpu-macos-26"):
            self.assertFalse(picker.owned_label(label))
        self.assertTrue(picker.owned_label("glaeda-side-std-xcode-26.6"))
        text = (ROOT / ".github/workflows/nightly-next-train.yml").read_text(encoding="utf-8")
        self.assertEqual([line.split(":")[0].strip() for line in text.splitlines()
                          if "vars.NIGHTLY_NEXT_TRAIN_RUNNER" in line and not line.lstrip().startswith("#")],
                         ["OWNED_LABELS"])
        self.assertIn("ubuntu", pick["runs-on"])
        runs_on = jobs["build"]["runs-on"]
        self.assertEqual(jobs["build"]["needs"], "pick-train-runner")
        self.assertIn("needs.pick-train-runner.outputs.attempt == format('{0}', github.run_attempt) && "
                      "needs.pick-train-runner.outputs.owned || needs.pick-train-runner.outputs.blacksmith || "
                      "vars.MACOS_RUNNER_26 || 'blacksmith-6vcpu-macos-26' }}", runs_on)


class Wiring(unittest.TestCase):
    def read(self, name: str) -> str:
        return (ROOT / ".github" / "workflows" / name).read_text(encoding="utf-8")

    def test_the_train_declares_the_fix_forward_contract(self) -> None:
        text = self.read("nightly-next-train.yml")
        for name in fix_forward.TRAIN_INPUTS:
            self.assertRegex(text, rf"(?m)^      {name}:$")

    def test_the_gate_job_name_is_one_name(self) -> None:
        text = self.read("nightly-next-train.yml")
        guard = (CI / "promote-nightly-next.mjs").read_text(encoding="utf-8")
        self.assertIn(f"name: {drive.GATE_JOB}\n", text)
        self.assertIn(f"export const TRAIN_GATE_JOB = '{drive.GATE_JOB}';", guard)
        self.assertIn("export const TRAIN_TRAILER = 'Nightly-Train: v1';", guard)
        self.assertEqual(train.TRAILER, "Nightly-Train: v1")
        self.assertIn("startsWith(github.ref, 'refs/heads/nightly-train/')", text)

    def test_the_train_holds_a_secret_only_when_on(self) -> None:
        text = self.read("nightly-next-train.yml")
        self.assertIn("environment: ${{ inputs.mode != 'plan' && vars.NIGHTLY_NEXT_TRAIN == 'on' && 'nightly-next-train' || '' }}", text)
        self.assertIn("MODE: ${{ inputs.mode == 'plan' && 'dry-run' || vars.NIGHTLY_NEXT_TRAIN == 'on' && 'on' || 'dry-run' }}", text)
        self.assertIn("persist-credentials: false", text)

    def test_the_canary_writes_each_verdict_through_release_next(self) -> None:
        canary = self.read("nightly-next-canary.yml")
        self.assertIn("request=(workflow run nightly-next-verdict.yml -R \"$GITHUB_REPOSITORY\" --ref nightly-next", canary)
        self.assertIn('gh "${request[@]}"', canary)
        self.assertIn("name: verdict ${{ needs.canary.outputs.verdict }} ${{ needs.pick.outputs.build }}", canary)
        verdict = self.read("nightly-next-verdict.yml")
        self.assertIn("environment: release-next", verdict)
        self.assertIn("github.ref == 'refs/heads/nightly-next'", verdict)
        self.assertIn("nightly_next_train.py verdict-check", verdict)
        self.assertIn("nightly-next-guard.py r2-key", verdict)
        self.assertIn("NIGHTLY_NEXT_R2_PREFIX: nightly-next/next/", verdict)

    def test_the_tick_starts_the_train(self) -> None:
        tick = self.read("nightly-next-tick.yml")
        self.assertIn("gh workflow run nightly-next-train.yml", tick)
        self.assertIn("if: vars.NIGHTLY_NEXT_TRAIN != 'on'", tick)


if __name__ == "__main__":
    unittest.main()
