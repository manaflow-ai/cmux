"""scripts/ci/head_tier.py and its use in the pr router: a draft head runs the cheap tier only."""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import tempfile
import time
import unittest
import unittest.mock
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import head_tier  # noqa: E402
import pr_router  # noqa: E402

# tests/git_fixture_env.py, loaded by path: `python3 -I` puts no script folder on sys.path.
import importlib.util as _git_fixture_importlib  # noqa: E402

_git_fixture_spec = _git_fixture_importlib.spec_from_file_location(
    "git_fixture_env", str(Path(__file__).resolve().parent / "git_fixture_env.py"))
git_fixture_env = _git_fixture_importlib.module_from_spec(_git_fixture_spec)
_git_fixture_spec.loader.exec_module(git_fixture_env)


def event(draft: bool, labels: tuple[str, ...] = (), action: str = "synchronize") -> dict:
    return {"action": action, "pull_request": {"draft": draft, "labels": [{"name": n} for n in labels]}}


class TierTests(unittest.TestCase):
    def test_draft_is_cheap(self) -> None:
        self.assertEqual(head_tier.tier("pull_request", event(True))[0], "cheap")

    def test_ready_is_full(self) -> None:
        self.assertEqual(head_tier.tier("pull_request", event(False))[0], "full")

    def test_full_ci_label_makes_a_draft_full(self) -> None:
        self.assertEqual(head_tier.tier("pull_request", event(True, ("full-ci",)))[0], "full")

    def test_switch_off_makes_a_draft_full(self) -> None:
        self.assertEqual(head_tier.tier("pull_request", event(True), "0")[0], "full")

    def test_other_events_and_unreadable_payloads_are_full(self) -> None:
        self.assertEqual(head_tier.tier("push", event(True))[0], "full")
        self.assertEqual(head_tier.tier("pull_request", {})[0], "full")


class RouterTests(unittest.TestCase):
    CALLEES = {
        "heavy.yml": {"types": ["opened", "synchronize", "ready_for_review"]},
        "cheap.yml": {"types": ["opened", "synchronize", "ready_for_review"], "draft": True},
    }

    def test_a_draft_starts_only_draft_callees(self) -> None:
        start, why = pr_router.route(event(True), self.CALLEES, ["a.py"])
        self.assertEqual(start, ["cheap.yml"])
        self.assertIn("ready for review", why["heavy.yml"])

    def test_marking_ready_starts_everything(self) -> None:
        start, _ = pr_router.route(event(False, action="ready_for_review"), self.CALLEES, ["a.py"])
        self.assertEqual(start, ["cheap.yml", "heavy.yml"])

    def test_full_ci_and_the_switch_start_everything_on_a_draft(self) -> None:
        self.assertEqual(pr_router.route(event(True, ("full-ci",)), self.CALLEES, ["a.py"])[0],
                         ["cheap.yml", "heavy.yml"])
        self.assertEqual(pr_router.route(event(True), self.CALLEES, ["a.py"], "0")[0], ["cheap.yml", "heavy.yml"])

    SWIFT = {"swift.yml": {"types": ["opened", "synchronize", "ready_for_review", "labeled"],
                           "paths": ["Packages/**"]}}

    def test_full_ci_still_routes_by_paths(self) -> None:
        # cmux#58044: a lane VM's land handoff adds full-ci to every PR; it started every callee whatever the paths.
        for action, added in (("synchronize", ""), ("labeled", "full-ci")):
            ev = event(False, ("full-ci",), action)
            if added:
                ev["label"] = {"name": added}
            start, why = pr_router.route(ev, self.SWIFT, ["scripts/ci/a.py"])
            self.assertEqual(start, [], action)
            self.assertIn("path filter", why["swift.yml"])
            self.assertEqual(pr_router.route(ev, self.SWIFT, ["Packages/A/b.swift"])[0], ["swift.yml"], action)

    def test_full_ci_with_unknown_files_starts_everything(self) -> None:
        self.assertEqual(pr_router.route(event(False, ("full-ci",)), self.SWIFT, None)[0], ["swift.yml"])

    def test_a_callees_own_label_still_starts_it_whatever_the_paths(self) -> None:
        callees = {"swift.yml": dict(self.SWIFT["swift.yml"], labels=["swift-ci"])}
        ev = event(False, ("swift-ci",), "labeled")
        ev["label"] = {"name": "swift-ci"}
        self.assertEqual(pr_router.route(ev, callees, ["scripts/ci/a.py"])[0], ["swift.yml"])

    def test_full_ci_beats_fast_track(self) -> None:
        old = os.environ.get("CMUX_FAST_TRACK")
        try:
            os.environ["CMUX_FAST_TRACK"] = "1"
            files = ["docs/a.md"]
            if not pr_router.fast_track.classify(files)[0]:
                self.skipTest("fast-track does not classify docs/a.md here")
            heavy = {"heavy.yml": self.CALLEES["heavy.yml"]}
            self.assertEqual(pr_router.route(event(False), heavy, files)[0], [])
            self.assertEqual(pr_router.route(event(False, ("full-ci",)), heavy, files)[0], ["heavy.yml"])
        finally:
            if old is None:
                os.environ.pop("CMUX_FAST_TRACK", None)
            else:
                os.environ["CMUX_FAST_TRACK"] = old

    def test_every_real_callee_that_skips_drafts_listens_to_ready_for_review(self) -> None:
        for name, config in pr_router.load_manifest().items():
            if not config.get("draft"):
                self.assertIn("ready_for_review", config["types"], name)


def land_event(draft: bool = False, labels: tuple[str, ...] = (), action: str = "synchronize",
               base: str = "feat-cmux-next", head_repo: str = "manaflow-ai/cmux", added: str = "") -> dict:
    ev = event(draft, labels, action)
    ev["pull_request"]["base"] = {"ref": base, "repo": {"full_name": "manaflow-ai/cmux"}}
    ev["pull_request"]["head"] = {"repo": {"full_name": head_repo}}
    if added:
        ev["label"] = {"name": added}
    return ev


class LandTierTests(unittest.TestCase):
    """The land rule: only the head handed off to land (`ready-to-land`) runs the full tier."""

    def tier(self, ev: dict, land: str = "1") -> str:
        return head_tier.tier("pull_request", ev, land_switch=land)[0]

    def test_a_ready_head_not_handed_off_is_cheap(self) -> None:
        self.assertEqual(self.tier(land_event()), "cheap")
        self.assertIn("ready-to-land", head_tier.tier("pull_request", land_event(), land_switch="1")[1])

    def test_the_land_label_and_full_ci_make_it_full(self) -> None:
        self.assertEqual(self.tier(land_event(labels=("ready-to-land",))), "full")
        self.assertEqual(self.tier(land_event(labels=("full-ci",))), "full")

    def test_a_draft_stays_cheap_even_with_the_land_label(self) -> None:
        self.assertEqual(self.tier(land_event(draft=True, labels=("ready-to-land",))), "cheap")

    def test_the_switch_forks_and_other_bases_keep_the_full_tier(self) -> None:
        self.assertEqual(self.tier(land_event(), land="0"), "full")
        self.assertEqual(self.tier(land_event(head_repo="someone/cmux")), "full")
        self.assertEqual(self.tier(land_event(base="main")), "full")
        self.assertEqual(head_tier.tier("pull_request", land_event())[0], "full")  # land_switch defaults off

    def test_a_ready_pr_naming_a_leo_ask_is_handed_off_from_its_first_head(self) -> None:
        # The ask rule: an ask PR runs the landing tier at open, not only once ready-to-land is added.
        ev = land_event(action="opened")
        ev["pull_request"]["body"] = "Leo asked for this (ask-dccba52b6f)."
        decided = head_tier.tier("pull_request", ev, land_switch="1")
        self.assertEqual(decided[0], "full")
        self.assertIn("Leo ask", decided[1])
        # With the hourly full tier rule (production: CI_LAND_FULL_PER_PR=0) it lands on the affected tier, as a
        # ready-to-land head does, and cmux/land-tier is success at once.
        decided = head_tier.tier("pull_request", ev, land_switch="1", land_full_switch="0")
        labelled = head_tier.tier("pull_request", land_event(labels=("ready-to-land",)), land_switch="1",
                                  land_full_switch="0")
        self.assertEqual(decided[0], labelled[0])
        self.assertTrue(head_tier.land_affected(decided))
        old = os.environ.get("CI_LAND_TIER")
        try:
            os.environ["CI_LAND_TIER"] = "1"
            self.assertEqual(pr_router.land_status(ev, decided), "success")
        finally:
            if old is None:
                os.environ.pop("CI_LAND_TIER", None)
            else:
                os.environ["CI_LAND_TIER"] = old

    def test_the_ask_rule_needs_an_ask_id_a_ready_pr_and_its_switch(self) -> None:
        def ev(body: object, draft: bool = False) -> dict:
            e = land_event(draft=draft, action="opened")
            e["pull_request"]["body"] = body
            return e
        self.assertEqual(self.tier(ev("no ask here; task-0123456789; ask-xyz")), "cheap")
        self.assertEqual(self.tier(ev(None)), "cheap")
        self.assertEqual(self.tier(ev("mask-0123456789")), "cheap")  # a word that only ends in ask- is not an id
        self.assertEqual(self.tier(ev("ask-0123456789", draft=True)), "cheap")
        self.assertFalse(head_tier.for_ask(ev("ask-0123456789"), switch="0"))
        self.assertTrue(head_tier.for_ask(ev("ask-0123456789"), switch="1"))
        old = os.environ.get("CI_ASK_LANDING")
        try:
            os.environ["CI_ASK_LANDING"] = "0"
            self.assertEqual(self.tier(ev("ask-0123456789")), "cheap")
        finally:
            if old is None:
                os.environ.pop("CI_ASK_LANDING", None)
            else:
                os.environ["CI_ASK_LANDING"] = old

    def test_the_ask_rule_hands_off_only_the_head_at_open_or_ready_never_a_later_push(self) -> None:
        # lane-9's CI-minutes goal: a push after open must not pay the landing tier again; it waits for ready-to-land.
        for action in ("opened", "reopened", "ready_for_review"):
            e = land_event(action=action)
            e["pull_request"]["body"] = "ask-dccba52b6f"
            self.assertTrue(head_tier.for_ask(e, switch="1"), action)
            self.assertEqual(self.tier(e), "full", action)
        for action in ("synchronize", "edited", "labeled"):
            e = land_event(action=action)
            e["pull_request"]["body"] = "ask-dccba52b6f"
            self.assertFalse(head_tier.for_ask(e, switch="1"), action)
        e = land_event(action="synchronize")
        e["pull_request"]["body"] = "ask-dccba52b6f"
        self.assertEqual(self.tier(e), "cheap")
        e = land_event(action="synchronize", labels=("ready-to-land",))
        e["pull_request"]["body"] = "ask-dccba52b6f"
        self.assertEqual(self.tier(e), "full")  # the label still hands a later push off, as for any PR

    def test_decide_reads_the_switch_from_the_environment(self) -> None:
        old = os.environ.get("CI_LAND_TIER")
        try:
            os.environ["CI_LAND_TIER"] = "0"
            self.assertEqual(head_tier.decide("pull_request", land_event())[0], "full")
            os.environ["CI_LAND_TIER"] = "1"
            self.assertEqual(head_tier.decide("pull_request", land_event())[0], "cheap")
        finally:
            if old is None:
                os.environ.pop("CI_LAND_TIER", None)
            else:
                os.environ["CI_LAND_TIER"] = old

    def test_the_router_starts_only_cheap_callees_then_everything_on_the_land_label(self) -> None:
        ev = land_event()
        start, why = pr_router.route(ev, RouterTests.CALLEES, ["a.py"], decided=head_tier.tier(
            "pull_request", ev, land_switch="1"))
        self.assertEqual(start, ["cheap.yml"])
        self.assertIn("ready-to-land", why["heavy.yml"])
        ev = land_event(labels=("ready-to-land",), action="labeled", added="ready-to-land")
        start, _ = pr_router.route(ev, RouterTests.CALLEES, ["a.py"], decided=head_tier.tier(
            "pull_request", ev, land_switch="1"))
        self.assertEqual(start, ["cheap.yml", "heavy.yml"])

    def test_full_ci_added_is_the_land_handoff_from_a_lane_vm(self) -> None:
        # A lane VM's broker never sets ready-to-land (autoland's queue) but lets a lane add full-ci, so land-judge's
        # land_tier asks with full-ci there: the same head must run the full tier and flip cmux/land-tier to success.
        ev = land_event(labels=("full-ci",), action="labeled", added="full-ci")
        decided = head_tier.tier("pull_request", ev, land_switch="1")
        start, _ = pr_router.route(ev, RouterTests.CALLEES, ["a.py"], decided=decided)
        self.assertEqual(start, ["cheap.yml", "heavy.yml"])
        old = os.environ.get("CI_LAND_TIER")
        try:
            os.environ["CI_LAND_TIER"] = "1"
            self.assertEqual(pr_router.land_status(ev, decided), "success")
        finally:
            if old is None:
                os.environ.pop("CI_LAND_TIER", None)
            else:
                os.environ["CI_LAND_TIER"] = old

    def test_full_ci_added_then_taken_off_still_runs_the_full_tier(self) -> None:
        # land-judge's full-ci pulse (add, then remove a second later): GitHub built the labeled event's payload
        # after the removal, so its labels held ready-to-land but not full-ci, and the router ran the affected tier
        # and skipped pr-pipeline.yml (cmux#52441, router run 45831524947). The event's own label counts.
        ev = land_event(labels=("ready-to-land",), action="labeled", added="full-ci")
        decided = head_tier.tier("pull_request", ev, land_switch="1", land_full_switch="0")
        self.assertEqual(decided, ("full", "full-ci label"))
        start, _ = pr_router.route(ev, RouterTests.CALLEES, ["a.py"], decided=decided)
        self.assertEqual(start, ["cheap.yml", "heavy.yml"])
        self.assertEqual(head_tier.labels_of(ev), {"ready-to-land", "full-ci"})
        # only a labeled event adds its label: an unlabeled full-ci is gone
        gone = land_event(labels=("ready-to-land",), action="unlabeled", added="full-ci")
        self.assertEqual(head_tier.labels_of(gone), {"ready-to-land"})

    def test_the_route_job_runs_on_full_ci_added_and_skips_other_labels(self) -> None:
        text = (ROOT / ".github" / "workflows" / "pr-router.yml").read_text()
        cond = re.search(r"^    if: \$\{\{ (.*) \}\}$", text.split("  route:", 1)[1], re.M).group(1)
        group = re.search(r"^  group: (.*)$", text, re.M).group(1)

        def ev(expr: str, action: str, label: str) -> object:
            values = {"github.event_name": "'pull_request'", "github.event.pull_request.base.ref": "'feat-cmux-next'",
                      "github.event.action": repr(action), "github.event.label.name": repr(label),
                      "github.event.pull_request.number": "'7'", "github.run_id": "'99'"}
            expr = re.sub(r"(github\.event\.changes\.[\w.]+|github\.event\.pull_request\.body)", "None", expr)
            expr = re.sub(r"contains\(None, '[^']*'\)", "False", expr)
            expr = re.sub(r"!contains\(fromJSON\('(\[[^\]]*\])'\), github\.event\.label\.name\)",
                          lambda m: f"(github.event.label.name not in {m.group(1)})", expr)
            expr = re.sub(r"format\('([^']*)', ([^)]*)\)", lambda m: repr(m.group(1).replace("{0}", "99")), expr)
            for name, value in values.items():
                expr = expr.replace(name, value)
            expr = expr.replace("&&", " and ").replace("||", " or ").replace("!=", " __NE__ ")
            expr = expr.replace("!", " not ").replace(" __NE__ ", " != ")
            return eval(expr, {"__builtins__": {}}, {})  # noqa: S307 - our own workflow's expression

        # Removing a label routes nothing (pr-router takes no `unlabeled` event either; the shared label guard,
        # tests/test_ci_label_events_skip_full_ci.py, skips removing a coverage label in every workflow).
        for action, label, routes in (("labeled", "ready-to-land", True), ("labeled", "full-ci", True),
                                      ("unlabeled", "ready-to-land", False), ("unlabeled", "full-ci", False),
                                      ("labeled", "risk:low", False), ("synchronize", "", True)):
            with self.subTest(action=action, label=label):
                self.assertEqual(bool(ev(cond, action, label)), routes)
                # A routed label shares the head's group (it supersedes the cheap run); another gets its own.
                parts = re.findall(r"\$\{\{ (.*?) \}\}", group)
                own = any(isinstance(ev(p, action, label), str) and "-label-" in ev(p, action, label) for p in parts)
                self.assertEqual(own, action in ("labeled", "unlabeled") and not routes)

    def test_the_land_status(self) -> None:
        old = os.environ.get("CI_LAND_TIER")
        try:
            os.environ["CI_LAND_TIER"] = "1"
            self.assertEqual(pr_router.land_status(land_event(), ("cheap", "")), "pending")
            self.assertEqual(pr_router.land_status(land_event(), ("none", "")), "pending")
            self.assertEqual(pr_router.land_status(land_event(labels=("ready-to-land",)), ("full", "")), "success")
            self.assertEqual(pr_router.land_status(land_event(draft=True), ("cheap", "")), "")
            self.assertEqual(pr_router.land_status(land_event(head_repo="someone/cmux"), ("full", "")), "")
            os.environ["CI_LAND_TIER"] = "0"
            self.assertEqual(pr_router.land_status(land_event(), ("full", "")), "")
        finally:
            if old is None:
                os.environ.pop("CI_LAND_TIER", None)
            else:
                os.environ["CI_LAND_TIER"] = old

    def test_a_landing_head_runs_the_affected_tier_unless_the_switch_restores_the_full_tier(self) -> None:
        landing = land_event(labels=("ready-to-land",))
        decided = head_tier.tier("pull_request", landing, land_switch="1", land_full_switch="0")
        self.assertEqual(decided[0], "cheap")
        self.assertTrue(head_tier.land_affected(decided))
        self.assertIn("CI_LAND_FULL_PER_PR=1", decided[1])
        self.assertEqual(head_tier.tier("pull_request", landing, land_switch="1", land_full_switch="1")[0], "full")
        # full-ci still gives the full tier; the land rule off, a fork or another base keeps it too.
        self.assertEqual(head_tier.tier("pull_request", land_event(labels=("ready-to-land", "full-ci")),
                                        land_switch="1", land_full_switch="0")[0], "full")
        for ev, land in ((landing, "0"), (land_event(labels=("ready-to-land",), head_repo="x/cmux"), "1"),
                         (land_event(labels=("ready-to-land",), base="main"), "1")):
            self.assertEqual(head_tier.tier("pull_request", ev, land_switch=land, land_full_switch="0")[0], "full")
        # A head not handed off keeps the land rule's own cheap tier, never land_affected.
        self.assertFalse(head_tier.land_affected(head_tier.tier("pull_request", land_event(), land_switch="1",
                                                                land_full_switch="0")))

    def test_decide_reads_ci_land_full_per_pr_unset_as_the_affected_tier(self) -> None:
        keys = ("CI_LAND_TIER", "CI_LAND_FULL_PER_PR")
        old = {key: os.environ.get(key) for key in keys}
        landing = land_event(labels=("ready-to-land",))
        try:
            os.environ["CI_LAND_TIER"] = "1"
            os.environ.pop("CI_LAND_FULL_PER_PR", None)
            self.assertEqual(head_tier.decide("pull_request", landing)[0], "cheap")
            os.environ["CI_LAND_FULL_PER_PR"] = "0"
            self.assertEqual(head_tier.decide("pull_request", landing)[0], "cheap")
            os.environ["CI_LAND_FULL_PER_PR"] = "1"
            self.assertEqual(head_tier.decide("pull_request", landing)[0], "full")
        finally:
            for key, value in old.items():
                if value is None:
                    os.environ.pop(key, None)
                else:
                    os.environ[key] = value

    def test_the_affected_landing_head_starts_cheap_callees_and_posts_land_tier_success(self) -> None:
        ev = land_event(labels=("ready-to-land",), action="labeled", added="ready-to-land")
        decided = head_tier.tier("pull_request", ev, land_switch="1", land_full_switch="0")
        start, why = pr_router.route(ev, RouterTests.CALLEES, ["a.py"], decided=decided)
        self.assertEqual(start, ["cheap.yml"])
        self.assertIn("heavy.yml", why)
        old = os.environ.get("CI_LAND_TIER")
        try:
            os.environ["CI_LAND_TIER"] = "1"
            self.assertEqual(pr_router.land_status(ev, decided), "success")
            self.assertEqual(pr_router.land_status(land_event(), head_tier.tier(
                "pull_request", land_event(), land_switch="1", land_full_switch="0")), "pending")
        finally:
            if old is None:
                os.environ.pop("CI_LAND_TIER", None)
            else:
                os.environ["CI_LAND_TIER"] = old

    def test_a_pulsed_full_ci_is_the_full_tier_though_the_payload_lost_it(self) -> None:
        # cmux#53671 at c52da39d (14:13Z 2026-11-26): land-judge's lane VM pulse added full-ci and took it off 2 s
        # later; the `labeled` payload listed only ready-to-land, the router read the affected cheap tier and pr
        # pipeline (the iOS matrix land-judge waits for) never started. The event's own added label counts.
        ev = land_event(labels=("ready-to-land",), action="labeled", added="full-ci")
        decided = head_tier.tier("pull_request", ev, land_switch="1", land_full_switch="0")
        self.assertEqual(decided, ("full", "full-ci label"))
        self.assertEqual(head_tier.labels_of(ev), {"ready-to-land", "full-ci"})
        start, _ = pr_router.route(ev, RouterTests.CALLEES, ["a.py"], decided=decided)
        self.assertIn("heavy.yml", start)
        # Only a `labeled` event adds its label: an unlabeled full-ci is gone.
        gone = land_event(labels=("ready-to-land",), action="unlabeled", added="full-ci")
        self.assertEqual(head_tier.labels_of(gone), {"ready-to-land"})
        self.assertEqual(head_tier.tier("pull_request", gone, land_switch="1", land_full_switch="0")[0], "cheap")

    def test_the_land_label_overrides_the_idle_skip(self) -> None:
        facts = {"base_merge_only": True, "own_last": 0}
        self.assertEqual(head_tier.tier("pull_request", land_event(), facts=facts, now=10 * 86400,
                                        land_switch="1")[0], "none")
        self.assertEqual(head_tier.tier("pull_request", land_event(labels=("ready-to-land",)), facts=facts,
                                        now=10 * 86400, land_switch="1")[0], "full")


DAY = 24 * 3600


class BranchRepo(unittest.TestCase):
    """A real repository: a branch with its own commit, then two base merges on top."""

    def git(self, *args: str, when: int | None = None) -> str:
        env = git_fixture_env.fixture_env()
        if when is not None:
            env.update(GIT_AUTHOR_DATE=f"{when} +0000", GIT_COMMITTER_DATE=f"{when} +0000")
        return subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false",
                               *args], cwd=self.dir, env=env, check=True, capture_output=True,
                              text=True).stdout.strip()

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = self.tmp.name
        self.now = 1_800_000_000
        git_fixture_env.init_repo(self.dir, "-b", "feat-cmux-next")
        self.git("commit", "-q", "--allow-empty", "-m", "base", when=self.now - 10 * DAY)
        self.git("checkout", "-q", "-b", "lane/x")
        self.git("commit", "-q", "--allow-empty", "-m", "own work", when=self.now - 3 * DAY)
        self.own = self.git("rev-parse", "HEAD")
        self.git("checkout", "-q", "feat-cmux-next")
        self.git("commit", "-q", "--allow-empty", "-m", "base moves", when=self.now - 2 * DAY)
        self.git("checkout", "-q", "lane/x")
        self.git("merge", "-q", "--no-ff", "-m", "Merge branch 'feat-cmux-next' into lane/x", "feat-cmux-next",
                 when=self.now - 2 * DAY)
        self.git("checkout", "-q", "feat-cmux-next")
        self.git("commit", "-q", "--allow-empty", "-m", "base moves again", when=self.now - 60)
        self.git("checkout", "-q", "lane/x")
        self.git("merge", "-q", "--no-ff", "-m", "Merge remote-tracking branch 'origin/feat-cmux-next' into lane/x",
                 "feat-cmux-next", when=self.now - 30)
        self.head = self.git("rev-parse", "HEAD")
        self.cwd = os.getcwd()
        os.chdir(self.dir)

    def tearDown(self) -> None:
        os.chdir(self.cwd)
        self.tmp.cleanup()

    @staticmethod
    def event(sha: str, action: str = "synchronize", labels: tuple[str, ...] = ()) -> dict:
        return {"action": action, "pull_request": {"draft": False, "head": {"sha": sha},
                                                   "base": {"ref": "feat-cmux-next"},
                                                   "labels": [{"name": n} for n in labels]}}



class IdleTests(BranchRepo):
    def test_two_base_merges_on_a_branch_idle_three_days_run_nothing(self) -> None:
        facts = head_tier.head_facts(self.event(self.head))
        self.assertEqual(facts, {"base_merge_only": True, "own_last": self.now - 3 * DAY, "by_github": False,
                                 "previous": self.git("rev-parse", "HEAD^1"),
                                 "base_parent": self.git("rev-parse", "HEAD^2")})
        self.assertEqual(head_tier.tier("pull_request", self.event(self.head), facts=facts, now=self.now)[0], "none")

    def test_a_recent_own_commit_is_not_idle(self) -> None:
        facts = head_tier.head_facts(self.event(self.head))
        self.assertEqual(head_tier.tier("pull_request", self.event(self.head), facts=facts,
                                        now=self.now - 2 * DAY - 60, sync_switch="0")[0], "full")

    def test_a_local_base_merge_on_an_active_branch_runs_the_cheap_tier(self) -> None:
        facts = head_tier.head_facts(self.event(self.head))
        fresh = self.now - 3 * DAY + 3600  # the branch's own last commit is an hour old: not idle
        got = head_tier.tier("pull_request", self.event(self.head), facts=facts, now=fresh)
        self.assertEqual(got[0], "cheap", got)
        self.assertEqual(head_tier.tier("pull_request", self.event(self.head), facts=facts, now=fresh,
                                        sync_switch="0")[0], "full")
        self.assertEqual(head_tier.tier("pull_request", self.event(self.head, labels=("full-ci",)), facts=facts,
                                        now=fresh)[0], "full")
        self.assertEqual(head_tier.tier("pull_request", self.event(self.head, "ready_for_review"), facts=facts,
                                        now=fresh)[0], "full")

    def test_a_merge_github_made_keeps_the_full_tier(self) -> None:
        self.git("checkout", "-q", "feat-cmux-next")
        self.git("commit", "-q", "--allow-empty", "-m", "base moves a third time", when=self.now - 20)
        self.git("checkout", "-q", "lane/x")
        env = git_fixture_env.fixture_env()
        env.update(GIT_COMMITTER_NAME="GitHub", GIT_COMMITTER_EMAIL="noreply@github.com",
                   GIT_COMMITTER_DATE=f"{self.now - 10} +0000", GIT_AUTHOR_DATE=f"{self.now - 10} +0000")
        subprocess.run(["git", "-c", "commit.gpgsign=false", "merge", "-q", "--no-ff", "-m",
                        "Merge branch 'feat-cmux-next' into lane/x", "feat-cmux-next"],
                       cwd=self.dir, env=env, check=True, capture_output=True)
        head = self.git("rev-parse", "HEAD")
        facts = head_tier.head_facts(self.event(head))
        self.assertEqual(facts, {"base_merge_only": True, "own_last": self.now - 3 * DAY, "by_github": True,
                                 "previous": self.git("rev-parse", "HEAD^1"),
                                 "base_parent": self.git("rev-parse", "HEAD^2")})
        self.assertEqual(head_tier.tier("pull_request", self.event(head), facts=facts,
                                        now=self.now - 3 * DAY + 3600)[0], "full")

    def test_an_own_commit_head_is_full(self) -> None:
        facts = head_tier.head_facts(self.event(self.own))
        self.assertEqual(facts, {"base_merge_only": False, "own_last": None, "by_github": False})
        self.assertEqual(head_tier.tier("pull_request", self.event(self.own), facts=facts, now=self.now)[0], "full")

    def test_full_ci_the_switch_and_other_actions_override(self) -> None:
        facts = head_tier.head_facts(self.event(self.head))
        tier = head_tier.tier
        self.assertEqual(tier("pull_request", self.event(self.head, labels=("full-ci",)), facts=facts,
                              now=self.now)[0], "full")
        self.assertEqual(tier("pull_request", self.event(self.head), facts=facts, now=self.now, idle_switch="0",
                              sync_switch="0")[0], "full")
        self.assertEqual(tier("pull_request", self.event(self.head, "ready_for_review"), facts=facts,
                              now=self.now)[0], "full")
        self.assertIsNone(head_tier.head_facts(self.event(self.head, "opened")))

    def test_an_unreadable_head_is_full(self) -> None:
        facts = head_tier.head_facts(self.event("0" * 40))
        self.assertIsNone(facts)
        self.assertEqual(head_tier.tier("pull_request", self.event("0" * 40), facts=facts, now=self.now)[0], "full")

    def test_the_router_starts_nothing_for_an_idle_base_merge(self) -> None:
        decided = head_tier.tier("pull_request", self.event(self.head),
                                 facts=head_tier.head_facts(self.event(self.head)), now=self.now)
        start, why = pr_router.route(self.event(self.head), RouterTests.CALLEES, ["a.py"], decided=decided)
        self.assertEqual(start, [])
        self.assertIn("only merges the base", why["cheap.yml"])


class GreenBaseMergeTests(BranchRepo):
    """The same repository, read before the idle rule's 24 h: the green-head base merge rule alone decides, on a
    head the land rule holds (a ready head into feat-cmux-next from this repository, CI_LAND_TIER on)."""

    @staticmethod
    def event(sha: str, action: str = "synchronize", labels: tuple[str, ...] = ()) -> dict:
        ev = BranchRepo.event(sha, action, labels)
        ev["pull_request"]["base"]["repo"] = {"full_name": "manaflow-ai/cmux"}
        ev["pull_request"]["head"]["repo"] = {"full_name": "manaflow-ai/cmux"}
        return ev

    @staticmethod
    def tier(*args, **kwargs) -> tuple[str, str]:
        kwargs.setdefault("land_switch", "1")
        return head_tier.tier(*args, **kwargs)

    def facts(self, green: bool | None) -> dict:
        facts = head_tier.head_facts(self.event(self.head))
        self.assertEqual(facts["previous"], self.git("rev-parse", "HEAD^1"))
        return {**facts, "previous_green": green}

    def test_a_base_merge_onto_a_green_head_runs_nothing(self) -> None:
        recent = self.now - 2 * DAY - 60  # the idle rule says no
        decided = self.tier("pull_request", self.event(self.head), facts=self.facts(True), now=recent)
        self.assertEqual(decided[0], "none")
        self.assertIn("whose every run passed", decided[1])

    def test_a_red_or_unread_previous_head_keeps_the_cheap_tier(self) -> None:
        recent = self.now - 2 * DAY - 60
        for green in (False, None):
            self.assertEqual(self.tier("pull_request", self.event(self.head), facts=self.facts(green),
                                            now=recent)[0], "cheap", green)

    def test_labels_switches_and_other_bases_keep_the_usual_tier(self) -> None:
        recent = self.now - 2 * DAY - 60
        tier = self.tier
        facts = self.facts(True)
        self.assertEqual(tier("pull_request", self.event(self.head, labels=("full-ci",)), facts=facts,
                              now=recent)[0], "full")
        # The labelled base merge rule: a ready-to-land head runs nothing too (the land pulses the label), unless
        # its switch is off.
        self.assertEqual(tier("pull_request", self.event(self.head, labels=("ready-to-land",)), facts=facts,
                              now=recent)[0], "none")
        self.assertEqual(tier("pull_request", self.event(self.head, labels=("ready-to-land",)), facts=facts,
                              now=recent, labelled_switch="0")[0], "full")
        self.assertEqual(tier("pull_request", self.event(self.head), facts=facts, now=recent, green_switch="0")[0],
                         "cheap")
        # Where the green-head rule does not apply, the sync rule's cheap tier (or, with it off, the full tier) stays.
        for sync, usual in (("1", "cheap"), ("0", "full")):
            self.assertEqual(tier("pull_request", self.event(self.head), facts=facts, now=recent, land_switch="0",
                                  sync_switch=sync)[0], usual)
            main = self.event(self.head)
            main["pull_request"]["base"]["ref"] = "main"
            self.assertEqual(tier("pull_request", main, facts=facts, now=recent, sync_switch=sync)[0], usual)
            fork = self.event(self.head)
            fork["pull_request"]["head"]["repo"] = {"full_name": "someone/cmux"}
            self.assertEqual(tier("pull_request", fork, facts=facts, now=recent, sync_switch=sync)[0], usual)
        self.assertEqual(tier("pull_request", self.event(self.head, "ready_for_review"), facts=facts,
                              now=recent)[0], "cheap")

    def test_an_own_commit_head_is_never_green_skipped(self) -> None:
        facts = {**head_tier.head_facts(self.event(self.own)), "previous_green": True}
        self.assertEqual(self.tier("pull_request", self.event(self.own), facts=facts, now=self.now)[0], "cheap")

    def test_short_merge_messages_count_as_base_merges(self) -> None:
        pattern = head_tier.base_merge_message("feat-cmux-next")
        for message in ("Merge branch 'feat-cmux-next' into lane/x",
                        "Merge remote-tracking branch 'origin/feat-cmux-next' into lane/x",
                        "Merge feat-cmux-next into lane/ci14-x", "Merge feat-cmux-next", "Merge origin/feat-cmux-next"):
            self.assertTrue(pattern.match(message), message)
        for message in ("Merge feat-cmux-next-old into lane/x", "Merge branch 'lane/other'",
                        "Merge feat-cmux-next and fix the build", "Merge pull request #1 from x/feat-cmux-next"):
            self.assertFalse(pattern.match(message), message)


class SamePatchTests(unittest.TestCase):
    """The same-patch rule: a head whose own change equals the previous head's (a rebase onto a newer base), with
    every run at the previous head green, runs nothing (goal ci-min-per-pr-30)."""

    REPO = {"full_name": "manaflow-ai/cmux"}

    def event(self, labels: tuple[str, ...] = (), before: str = "b" * 40, action: str = "synchronize") -> dict:
        return {"action": action, "before": before, "pull_request": {
            "draft": False, "labels": [{"name": n} for n in labels],
            "base": {"ref": "feat-cmux-next", "repo": self.REPO}, "head": {"sha": "a" * 40, "repo": self.REPO}}}

    @staticmethod
    def compare(*files: tuple[str, str]) -> dict:
        return {"files": [{"filename": name, "status": "modified", "patch": patch} for name, patch in files]}

    def test_the_key_ignores_hunk_lines_context_and_file_order(self) -> None:
        one = self.compare(("a.py", "@@ -10,3 +10,4 @@ def f():\n x\n-old\n+new"), ("b.py", "@@ -1 +1 @@\n-a\n+b"))
        moved = self.compare(("b.py", "@@ -7 +7 @@\n-a\n+b"), ("a.py", "@@ -40,3 +40,4 @@ def g():\n y\n-old\n+new"))
        self.assertEqual(head_tier.patch_key(one), head_tier.patch_key(moved))
        other = self.compare(("a.py", "@@ -10,3 +10,4 @@\n x\n-old\n+newer"), ("b.py", "@@ -1 +1 @@\n-a\n+b"))
        self.assertNotEqual(head_tier.patch_key(one), head_tier.patch_key(other))
        renamed = self.compare(("c.py", "@@ -10,3 +10,4 @@\n x\n-old\n+new"), ("b.py", "@@ -1 +1 @@\n-a\n+b"))
        self.assertNotEqual(head_tier.patch_key(one), head_tier.patch_key(renamed))

    def test_a_compare_not_whole_has_no_key(self) -> None:
        self.assertIsNone(head_tier.patch_key(None))
        self.assertIsNone(head_tier.patch_key({"files": []}))
        self.assertIsNone(head_tier.patch_key({"files": [{"filename": "x.png", "status": "added"}]}))
        self.assertIsNone(head_tier.patch_key(self.compare(*[(f"f{i}", "+x") for i in range(300)])))
        self.assertIsNone(head_tier.own_patch_key("manaflow-ai/cmux", "feat-cmux-next", "a" * 40, ""))

    def tier(self, ev: dict, facts: dict, **kwargs) -> tuple[str, str]:
        kwargs.setdefault("land_switch", "1")
        return head_tier.tier("pull_request", ev, facts=facts, now=time.time(), **kwargs)

    def test_a_rebased_head_onto_a_green_previous_head_runs_nothing(self) -> None:
        facts = {"base_merge_only": False, "own_last": None, "before": "b" * 40, "same_patch_green": True}
        decided = self.tier(self.event(), facts)
        self.assertEqual(decided, ("none", decided[1]))
        self.assertIn("same change as bbbbbbbbbb", decided[1])
        for label, usual in (("full-ci", "full"), ("ready-to-land", "none")):
            self.assertEqual(self.tier(self.event((label,)), facts)[0], usual, label)
        self.assertEqual(self.tier(self.event(("ready-to-land",)), facts, labelled_switch="0")[0], "full")
        self.assertEqual(self.tier(self.event(), facts, green_switch="0")[0], "cheap")
        self.assertEqual(self.tier(self.event(), {**facts, "same_patch_green": False})[0], "cheap")

    def test_decide_compares_both_heads_and_reads_the_previous_runs(self) -> None:
        calls = []
        real = head_tier.head_facts, head_tier.runs_at, head_tier.own_patch_key
        green = [{"id": 1, "path": "ci.yml", "status": "completed", "conclusion": "success"}]
        try:
            head_tier.head_facts = lambda e: {"base_merge_only": False, "own_last": None}
            head_tier.runs_at = lambda *a: calls.append(("runs", a[1])) or green
            head_tier.own_patch_key = lambda repo, base, sha, token: calls.append(("key", sha)) or "k"
            with unittest.mock.patch.dict(os.environ, {"GH_TOKEN": "t", "GITHUB_REPOSITORY": "manaflow-ai/cmux"}):
                self.assertEqual(head_tier.decide("pull_request", self.event())[0], "none")
                self.assertEqual(calls, [("key", "a" * 40), ("key", "b" * 40), ("runs", "b" * 40)])
                head_tier.own_patch_key = lambda repo, base, sha, token: sha[:1]  # the two changes differ
                calls.clear()
                self.assertEqual(head_tier.decide("pull_request", self.event())[0], "cheap")
                self.assertEqual(calls, [])
                head_tier.own_patch_key = lambda *a: None  # unread
                self.assertEqual(head_tier.decide("pull_request", self.event())[0], "cheap")
                head_tier.own_patch_key = lambda *a: "k"
                head_tier.runs_at = lambda *a: [{**green[0], "conclusion": "failure"}]
                self.assertEqual(head_tier.decide("pull_request", self.event())[0], "cheap")
                calls.clear()
                head_tier.own_patch_key = lambda repo, base, sha, token: calls.append(sha) or "k"
                for ev in (self.event(before="0" * 39), self.event(("full-ci",))):
                    head_tier.decide("pull_request", ev)
                self.assertEqual(calls, [])
                head_tier.decide("pull_request", self.event(("ready-to-land",)))  # the labelled base merge rule
                self.assertEqual(calls, ["a" * 40, "b" * 40])
                calls.clear()
                with unittest.mock.patch.dict(os.environ, {"CI_LABELLED_BASE_MERGE_SKIP": "0"}):
                    head_tier.decide("pull_request", self.event(("ready-to-land",)))
                self.assertEqual(calls, [])
        finally:
            head_tier.head_facts, head_tier.runs_at, head_tier.own_patch_key = real


class LandCarryTests(BranchRepo):
    """A `ready-to-land` head that only merges the base onto a head whose full tier passed: the land carry rule."""

    event = staticmethod(GreenBaseMergeTests.event)
    tier = staticmethod(GreenBaseMergeTests.tier)

    def landed(self, landed: bool | None, own: bool = False) -> dict:
        sha = self.own if own else self.head
        facts = head_tier.head_facts(self.event(sha))
        return {**facts, "previous_landed": landed}

    def landing(self, sha: str | None = None, labels: tuple[str, ...] = ("ready-to-land",)) -> dict:
        return self.event(sha or self.head, labels=labels)

    def test_a_landing_base_merge_onto_a_passed_full_tier_runs_cheap_and_carries_success(self) -> None:
        decided = self.tier("pull_request", self.landing(), facts=self.landed(True), now=self.now)
        self.assertEqual(decided[0], "cheap")
        self.assertTrue(head_tier.carried(decided))
        with unittest.mock.patch.dict(os.environ, {"CI_LAND_TIER": "1"}):
            self.assertEqual(pr_router.land_status(self.landing(), decided), "success")

    def test_a_merge_github_made_carries_too(self) -> None:
        self.git("checkout", "-q", "feat-cmux-next")
        self.git("commit", "-q", "--allow-empty", "-m", "base moves a third time", when=self.now - 20)
        self.git("checkout", "-q", "lane/x")
        env = git_fixture_env.fixture_env()
        env.update(GIT_COMMITTER_NAME="GitHub", GIT_COMMITTER_EMAIL="noreply@github.com",
                   GIT_COMMITTER_DATE=f"{self.now - 10} +0000", GIT_AUTHOR_DATE=f"{self.now - 10} +0000")
        subprocess.run(["git", "-c", "commit.gpgsign=false", "merge", "-q", "--no-ff", "-m",
                        "Merge branch 'feat-cmux-next' into lane/x", "feat-cmux-next"],
                       cwd=self.dir, env=env, check=True, capture_output=True)
        facts = head_tier.head_facts(self.event(self.git("rev-parse", "HEAD")))
        self.assertTrue(facts["by_github"])
        decided = self.tier("pull_request", self.landing(self.git("rev-parse", "HEAD")),
                            facts={**facts, "previous_landed": True}, now=self.now)
        self.assertTrue(head_tier.carried(decided), decided)

    def test_an_unproved_previous_head_an_own_commit_full_ci_or_the_switch_keep_the_full_tier(self) -> None:
        for landed in (False, None):
            self.assertEqual(self.tier("pull_request", self.landing(), facts=self.landed(landed),
                                       now=self.now)[0], "full", landed)
        self.assertEqual(self.tier("pull_request", self.landing(self.own), facts=self.landed(True, own=True),
                                   now=self.now)[0], "full")
        self.assertEqual(self.tier("pull_request", self.landing(labels=("ready-to-land", "full-ci")),
                                   facts=self.landed(True), now=self.now)[0], "full")
        for switches in ({"carry_switch": "0"}, {"land_switch": "0"}):
            self.assertEqual(self.tier("pull_request", self.landing(), facts=self.landed(True), now=self.now,
                                       **switches)[0], "full", switches)
        decided = self.tier("pull_request", self.landing(), facts=self.landed(False), now=self.now)
        self.assertFalse(head_tier.carried(decided))

    def test_a_head_not_landing_is_unchanged(self) -> None:
        recent = self.now - 2 * DAY - 60
        decided = self.tier("pull_request", self.event(self.head), facts=self.landed(True), now=recent)
        self.assertNotEqual(decided[0], "full")
        self.assertFalse(head_tier.carried(decided))

    def test_decide_reads_the_status_and_runs_only_for_a_landing_base_merge(self) -> None:
        calls = []
        real = head_tier.head_facts, head_tier.runs_at, head_tier.land_status_at
        repo = {"full_name": "manaflow-ai/cmux"}
        ev = {"action": "synchronize", "pull_request": {
            "draft": False, "base": {"ref": "feat-cmux-next", "repo": repo},
            "head": {"sha": "a" * 40, "repo": repo}, "labels": [{"name": "ready-to-land"}]}}
        state = {"value": "success"}
        # The hourly full tier rule (on by default) gives every landing head the cheap tier; pin it off so the carry
        # rule's own full-or-carried verdict shows.
        saved = os.environ.get("CI_LAND_FULL_PER_PR")
        os.environ["CI_LAND_FULL_PER_PR"] = "1"
        # The labelled base merge rule (on by default) gives a green previous head the tier none before the carry
        # rule; pin it off here (LabelledBaseMergeTests covers it). The red-head rerun rule reads the runs first; pin
        # it off too so this test shows the carry rule's own reads (RedBaseMergeTests covers it).
        labelled = unittest.mock.patch.dict(os.environ, {"CI_LABELLED_BASE_MERGE_SKIP": "0",
                                                         "CI_RED_BASE_MERGE_RERUN": "0"})
        labelled.start()
        self.addCleanup(labelled.stop)
        try:
            head_tier.land_status_at = lambda *a: calls.append(("status", a[1])) or state["value"]
            head_tier.runs_at = lambda *a: calls.append(("runs", a[1])) or [
                {"id": 1, "path": "ci.yml", "status": "completed", "conclusion": "success"}]
            head_tier.head_facts = lambda e: {"base_merge_only": False, "own_last": None}
            self.assertEqual(head_tier.decide("pull_request", ev)[0], "full")
            self.assertEqual(calls, [])
            head_tier.head_facts = lambda e: {"base_merge_only": True, "own_last": time.time(), "previous": "b" * 40}
            decided = head_tier.decide("pull_request", ev)
            self.assertTrue(head_tier.carried(decided), decided)
            self.assertEqual(calls, [("status", "b" * 40), ("runs", "b" * 40)])
            calls.clear()
            state["value"] = "pending"  # the previous head ran the cheap tier: nothing to carry, runs not read
            self.assertEqual(head_tier.decide("pull_request", ev)[0], "full")
            self.assertEqual(calls, [("status", "b" * 40)])
        finally:
            head_tier.head_facts, head_tier.runs_at, head_tier.land_status_at = real
            if saved is None:
                os.environ.pop("CI_LAND_FULL_PER_PR", None)
            else:
                os.environ["CI_LAND_FULL_PER_PR"] = saved


class GreenPreviousTests(unittest.TestCase):
    """green_previous over the Actions runs API's workflow_runs."""

    @staticmethod
    def run_(id_: int, path: str, conclusion: str | None, status: str = "completed") -> dict:
        return {"id": id_, "path": path, "status": status, "conclusion": conclusion}

    def test_every_newest_run_green(self) -> None:
        runs = [self.run_(1, "ci.yml", "success"), self.run_(2, "router.yml", "skipped")]
        self.assertTrue(head_tier.green_previous(runs))

    def test_a_newer_rerun_replaces_an_older_cancelled_run(self) -> None:
        runs = [self.run_(1, "ci.yml", "cancelled"), self.run_(5, "ci.yml", "success")]
        self.assertTrue(head_tier.green_previous(runs))
        self.assertFalse(head_tier.green_previous(list(reversed([self.run_(1, "ci.yml", "success"),
                                                                 self.run_(5, "ci.yml", "failure")]))))

    def test_red_running_cancelled_or_empty_is_not_green(self) -> None:
        self.assertFalse(head_tier.green_previous([]))
        self.assertFalse(head_tier.green_previous(None))
        self.assertFalse(head_tier.green_previous([self.run_(1, "ci.yml", None, "in_progress")]))
        self.assertFalse(head_tier.green_previous([self.run_(1, "ci.yml", "success"),
                                                   self.run_(2, "x.yml", "cancelled")]))
        self.assertFalse(head_tier.green_previous([self.run_(1, "ci.yml", "failure")]))

    def test_unreadable_inputs_read_nothing(self) -> None:
        self.assertIsNone(head_tier.runs_at("manaflow-ai/cmux", "0" * 40, ""))
        self.assertIsNone(head_tier.runs_at("not a repo", "0" * 40, "t"))

    def test_decide_reads_the_verdict_only_for_a_base_merge(self) -> None:
        calls = []
        real_facts, real_runs = head_tier.head_facts, head_tier.runs_at
        repo = {"full_name": "manaflow-ai/cmux"}
        ev = {"action": "synchronize", "pull_request": {"draft": False, "base": {"ref": "feat-cmux-next", "repo": repo},
                                                        "head": {"sha": "a" * 40, "repo": repo}, "labels": []}}
        try:
            head_tier.runs_at = lambda *a: calls.append(a) or [self.run_(1, "ci.yml", "success")]
            head_tier.head_facts = lambda e: {"base_merge_only": False, "own_last": None}
            self.assertEqual(head_tier.decide("pull_request", ev)[0], "cheap")
            self.assertEqual(calls, [])
            head_tier.head_facts = lambda e: {"base_merge_only": True, "own_last": time.time(), "previous": "b" * 40}
            self.assertEqual(head_tier.decide("pull_request", ev)[0], "none")
            self.assertEqual(calls[0][1], "b" * 40)
        finally:
            head_tier.head_facts, head_tier.runs_at = real_facts, real_runs

# Workflows whose pull request runs skip a draft head (the tail of the draft tier, after ci.yml and cmux-next.yml).
# Every job of each carries DRAFT_TIER_CONDITION, because a job with `!cancelled()` or `always()` runs even when the
# job it needs was skipped, so gating only the root jobs would not gate those. A job that is skipped reports
# "skipped", which a required check accepts; marking the draft ready (`ready_for_review`) runs them on the same head.
# Value: the pull request event the workflow listens to. Anything else with a pull_request trigger is kept on drafts
# (cheap guards, deploys, closed-event cleanups): the list is in the pull request body.
GATED = {
    "auth-refresh-tests.yml": "pull_request",
    "backend-migrations.yml": "pull_request_target",
    "cmux-next-motion-golden.yml": "pull_request",
    "cmux-next-pr-autofix.yml": "pull_request",
    "cmux-next-shell-integration.yml": "pull_request",
    "cmux-vnc.yml": "pull_request",
    "ios-e2e.yml": "pull_request",
    "iroh-v2.yml": "pull_request",
    "measure-swift-typecheck.yml": "pull_request",
    "relay-tls.yml": "pull_request",
    "signing-keychain-macos.yml": "pull_request",
    "test-ios.yml": "pull_request",
}
# Workflows whose pull request runs skip every head that is not handed to land (the tail of the land tier, after
# ci.yml and cmux-next.yml). Leo, 2026-11-23: "de facto, im asking for 99% fewer minutes of ci time, period."
# Every job of each carries LAND_TIER_CONDITION, because a job with `!cancelled()` or `always()` runs even when the
# job it needs was skipped, so gating only the root jobs would not gate those. A skipped job reports "skipped", which
# land-judge counts as passing, so cmux/land-tier stays pending on that head (land_judge rule land_tier) until the
# `ready-to-land` label re-runs each of these (`labeled` in its trigger, the label guard of
# tests/test_ci_label_events_skip_full_ci.py) at the same head. Marking a draft ready runs them only with that label.
# Value: the pull request event the workflow listens to. Anything else with a pull_request trigger is the cheap
# signal kept on every head (pr-body-checks, risk tier, language boundaries, merge freeze, pr-checks, web complexity,
# classic frozen guard) or already skips feat-cmux-next pull requests (scripts/ci/affected_jobs.py PR_SKIP_IF).
GATED = {name: "pull_request" for name in (
    "auth-refresh-tests.yml", "backend.yml", "billing.yml", "chat-open-perf-report.yml",
    "cloud-chief-machine.yml", "cloud-journey-pr.yml", "cloud-vm-guest-install.yml", "cloudflare-relay.yml",
    "cmux-cloud-cli.yml", "cmux-next-car-guards.yml", "cmux-next-fast-gates.yml", "cmux-next-guards.yml",
    "cmux-next-hot-verify.yml", "cmux-next-pr-autofix.yml",
    "cmux-next-shell-integration.yml", "cmux-vm.yml", "cmux-vm-clients.yml", "cmux-vm-cloud.yml", "cmux-vnc.yml",
    "ios-e2e.yml", "iroh-v2.yml", "measure-swift-typecheck.yml", "relay-tls.yml",
    "release-rails.yml", "signing-keychain-macos.yml", "terminal-hang-diagnostics.yml", "test-ios.yml",
    # 17.4k runner-min per 10.8 h on pull request heads (11-25 05:30Z-16:18Z), every push of every head before:
    # rust-workspaces' plan, reads and workspace matrix; cmux-tui-spec's changes router and acpmux/clippy jobs.
    "rust-workspaces.yml", "cmux-tui-spec.yml")}
GATED["backend-migrations.yml"] = "pull_request_target"
# Only the draft tier: its one job runs only when the motion-golden label is the one added (a person asks for it).
DRAFT_ONLY = {"cmux-next-motion-golden.yml": "pull_request"}

# backend-migrations applies a migration when a person adds the `backend:apply-migrations` label, draft or not.
KEEP_ON_LABELED = {"backend-migrations.yml"}
# Re-run-only on a pull request (#53046: act_fixer asks for the re-run after a mechanical red), so a cheap head's
# first run never starts them either.
RERUN_ONLY_ON_PULL_REQUEST = {("cmux-next-pr-autofix.yml", "repair")}
# Push-only jobs: their if: excludes a pull request, so no cheap head ever runs them.
# chief-evals, cmux-mobile-ffi, cmux-next-terminal and cmux-rd-windows have no pull_request trigger since #54661
# (advisory-only PR runs off), so no head of theirs is gated.
NEVER_ON_PULL_REQUEST = {("cmux-next-pr-autofix.yml", "push")}
# Runs on every head: deletes the pull request's preview when it closes.
KEEP_ON_EVERY_HEAD = {("backend.yml", "preview-cleanup")}
# The full-ci base merge carry job (head_tier.full_carry): runs only on the full-ci or ready-to-land label event the
# land tier itself runs on, before that tier's jobs, so it carries the label condition instead of the land condition.
FULL_CARRY_JOBS = {(name, "full-carry") for name in ("cmux-next-guards.yml", "ios-e2e.yml", "test-ios.yml",
                                                     "rust-workspaces.yml")}
# Runs for a closed pull request (cancels its hot-verify) or a head handed to land.
CLOSED_OR_LAND = {("cmux-next-hot-verify.yml", "plan")}


def draft_tier_condition(event_name: str, keep_labeled: bool = False) -> str:
    """The job-level expression equal to head_tier.tier(..., land_switch="0") == "full" (the draft tier only)."""
    parts = [
        f"github.event_name != '{event_name}'",
        "github.event.pull_request.draft != true",
        "contains(github.event.pull_request.labels.*.name, 'full-ci')",
        "(vars.CI_DRAFT_CHEAP_TIER || '1') == '0'",
    ]
    if keep_labeled:
        parts.insert(1, "github.event.action == 'labeled'")
    return "(" + " || ".join(parts) + ")"


def land_tier_condition(event_name: str, keep_labeled: bool = False) -> str:
    """The job-level expression equal to head_tier.tier(..., land_switch=CI_LAND_TIER,
    land_full_switch=CI_LAND_FULL_PER_PR) == "full", the idle rule aside
    (an idle base merge into a gated workflow runs it as a ready head does)."""
    parts = [
        f"github.event_name != '{event_name}'",
        "contains(github.event.pull_request.labels.*.name, 'full-ci')",
        "(github.event.pull_request.draft == true && (vars.CI_DRAFT_CHEAP_TIER || '1') == '0')",
        "(github.event.pull_request.draft != true && ((contains(github.event.pull_request.labels.*.name, 'ready-to-land')"
        " && vars.CI_LAND_FULL_PER_PR == '1')"
        " || github.event.pull_request.base.ref != 'feat-cmux-next'"
        " || github.event.pull_request.head.repo.full_name != github.repository"
        " || (vars.CI_LAND_TIER || '1') == '0'))",
    ]
    if keep_labeled:
        parts.insert(1, "github.event.action == 'labeled'")
    return "(" + " || ".join(parts) + ")"


def _job_ifs(text: str) -> dict:
    """job id -> the text of its job-level `if:` (None when it has none), by indentation, so comments survive."""
    out: dict = {}
    job = None
    in_jobs = False
    for line in text.splitlines():
        if line.startswith("jobs:"):
            in_jobs = True
            continue
        if not in_jobs:
            continue
        if line and not line.startswith((" ", "#")):
            break
        match = re.match(r"^  ([A-Za-z0-9_-]+):\s*(#.*)?$", line)
        if match:
            job = match.group(1)
            out[job] = None
        elif job and line.startswith("    if:"):
            out[job] = line[len("    if:"):].strip()
        elif job and out.get(job) in (">", ">-", "|", "|-") and line.startswith("      "):
            out[job] += " " + line.strip()  # the rest of a block-scalar if:
    return out


def _trigger_types(text: str, event_name: str, name: str = "") -> str:
    """The workflow's own pull request trigger types, or, for a pr-router callee (scripts/ci/pr_router.json: no
    pull_request trigger of its own into feat-cmux-next), the types the router starts it on."""
    callees = json.loads((ROOT / "scripts" / "ci" / "pr_router.json").read_text())["callees"]
    if event_name == "pull_request" and name in callees:
        return json.dumps(callees[name]["types"])
    block = re.search(rf"^  {event_name}:\n((?:    .*\n|\s*\n)*)", text, re.M)
    assert block, f"no {event_name} trigger"
    types = re.search(r"^    types:\s*(\[[^\]]*\]|(?:\n      - .*)+)", block.group(1), re.M)
    assert types, "the trigger lists no types"
    return types.group(1)


class GatedWorkflowTests(unittest.TestCase):
    """Regression test (run by hand, not a CI job): every gated workflow runs only at the head handed to land."""

    WORKFLOWS = ROOT / ".github" / "workflows"

    def test_every_job_carries_the_condition_and_the_trigger_lists_ready_for_review_and_labeled(self) -> None:
        for name, event_name in GATED.items():
            text = (self.WORKFLOWS / name).read_text()
            expected = land_tier_condition(event_name, name in KEEP_ON_LABELED)
            jobs = _job_ifs(text)
            self.assertTrue(jobs, name)
            for job, condition in jobs.items():
                if (name, job) in NEVER_ON_PULL_REQUEST:
                    self.assertTrue(any(c in (condition or "") for c in
                                        ("github.event_name != 'pull_request'", "github.event_name == 'push'")),
                                    f"{name}: job {job}")
                    continue
                if (name, job) in RERUN_ONLY_ON_PULL_REQUEST:
                    self.assertIn("(github.event_name != 'pull_request' || github.run_attempt > 1)", condition or "",
                                  f"{name}: job {job}")
                    continue
                if (name, job) in FULL_CARRY_JOBS:
                    self.assertIn("github.event.action == 'labeled' && contains(fromJSON('[\"full-ci\",\"ready-to-land\"]'), "
                                  "github.event.label.name)", condition or "", f"{name}: job {job}")
                    continue
                if (name, job) in KEEP_ON_EVERY_HEAD:
                    self.assertNotIn("CI_LAND_TIER", condition or "", f"{name}: job {job}")
                    continue
                self.assertIsNotNone(condition, f"{name}: job {job} has no if:")
                if (name, job) in CLOSED_OR_LAND:
                    self.assertIn(f"(github.event.action == 'closed' || {expected})", condition, f"{name}: job {job}")
                    continue
                self.assertIn(expected, condition, f"{name}: job {job}")
                self.assertNotIn("github.event.pull_request.draft != true ||", condition, f"{name}: job {job}")
            types = _trigger_types(text, event_name, name)
            self.assertIn("ready_for_review", types, name)
            self.assertIn("labeled", types, name)

    def test_draft_only_workflows_keep_the_draft_condition(self) -> None:
        for name, event_name in DRAFT_ONLY.items():
            text = (self.WORKFLOWS / name).read_text()
            for job, condition in _job_ifs(text).items():
                self.assertIn(draft_tier_condition(event_name), condition or "", f"{name}: job {job}")
            self.assertIn("ready_for_review", _trigger_types(text, event_name, name), name)

    def test_the_cmux_next_router_drops_the_cargo_fast_tier_on_a_cheap_head(self) -> None:
        """A later line of an output wins: the cheap tier's fast_tier_cargo=false follows the cargo route's line."""
        text = (ROOT / "scripts" / "ci" / "cmux-next-steps" / "classify-pull-request-paths.sh").read_text()
        route = text.index("fast_tier_cargo_route.py --changed-files")
        cheap = text.index('echo "fast_tier_cargo=false" >> "$GITHUB_OUTPUT"')
        self.assertLess(route, cheap)
        self.assertIn('if [[ "$head_tier" == cheap || "$head_tier" == none ]]; then',
                      text[text.rindex("\n", 0, text.rindex("\n", 0, cheap)):cheap])
        workflow = (self.WORKFLOWS / "cmux-next.yml").read_text()
        self.assertIn(land_tier_condition("pull_request"), _job_ifs(workflow)["pr-red-checks"])

    def test_the_condition_matches_head_tier_for_every_input(self) -> None:
        """Evaluate the expression's terms against head_tier.tier over all combinations (the idle rule off)."""
        for event_name in ("pull_request", "pull_request_target"):
            for draft in (True, False):
                for labels in ((), ("full-ci",), ("ready-to-land",), ("other",)):
                    for base in ("feat-cmux-next", "main"):
                        for head_repo in ("manaflow-ai/cmux", "someone/cmux"):
                            for switch in ("1", "0"):
                                for land in ("1", "0"):
                                  for land_full in ("1", "0", ""):
                                    ev = land_event(draft, labels, base=base, head_repo=head_repo)
                                    full = head_tier.tier(event_name, ev, switch, idle_switch="0",
                                                          land_switch=land, land_full_switch=land_full)[0] == "full"
                                    runs = (
                                        "full-ci" in labels
                                        or (draft and switch == "0")
                                        or (not draft and (("ready-to-land" in labels and land_full == "1")
                                                           or base != "feat-cmux-next"
                                                           or head_repo != "manaflow-ai/cmux" or land == "0"))
                                    )
                                    self.assertEqual(full, runs, (event_name, draft, labels, base, head_repo,
                                                                  switch, land, land_full))


# ci-web.yml is a workflow_call callee of ci.yml (job `web`), so it sees the caller's pull request event. Its heavy
# jobs carry the land condition; its verdict jobs (react-apps-check, Web status) still run on every head and accept
# those skips only on a cheap head, read from WEB_LAND_TIER (the same expression). Measured 2026-11-25: the React
# shards, base replay and webviews-typecheck were about 90k runner min/day on feat-cmux-next heads not handed to land.
CI_WEB_LAND_TIER_JOBS = ("react-apps-check-shard", "webviews-typecheck")
CI_WEB_VERDICT_JOBS = ("react-apps-check", "web-status")


class CiWebLandTierTests(unittest.TestCase):
    TEXT = (ROOT / ".github" / "workflows" / "ci-web.yml").read_text()

    def test_the_heavy_jobs_carry_the_land_condition(self) -> None:
        jobs = _job_ifs(self.TEXT)
        for job in CI_WEB_LAND_TIER_JOBS:
            self.assertIn(land_tier_condition("pull_request"), jobs[job] or "", job)

    def test_the_jobs_that_need_the_shards_skip_with_them(self) -> None:
        jobs = _job_ifs(self.TEXT)
        self.assertNotIn("always()", jobs["react-apps-base-check"])
        self.assertNotIn("!cancelled()", jobs["react-apps-base-check"])
        self.assertIn("needs.react-apps-check-shard.result != 'skipped'", jobs["webviews-test-durations"])

    def test_the_verdict_jobs_still_run_and_read_the_same_condition(self) -> None:
        jobs = _job_ifs(self.TEXT)
        env = f"WEB_LAND_TIER: ${{{{ {land_tier_condition('pull_request')} }}}}"
        for job in CI_WEB_VERDICT_JOBS:
            self.assertNotIn("CI_LAND_TIER", jobs[job] or "", job)
            start = self.TEXT.index(f"\n  {job}:\n")
            end = self.TEXT.find("\n  # ", start + 1)
            block = self.TEXT[start:] if end < 0 else self.TEXT[start:end]
            self.assertIn(env, block, job)
            self.assertIn('os.environ.get("WEB_LAND_TIER")', block, job)
            self.assertNotIn('os.environ.get("WEB_LAND_TIER") == "true"', block, job)  # an unset flag fails closed
        self.assertIn('may_skip.add("webviews-typecheck")', self.TEXT)

    def test_ci_yml_reruns_web_on_the_land_label(self) -> None:
        ci = (ROOT / ".github" / "workflows" / "ci.yml").read_text()
        self.assertIn("labeled", _trigger_types(ci, "pull_request"))
        self.assertIn('"ready-to-land"', _job_ifs(ci)["web"] or "")


class LandHandoffOnlyTests(unittest.TestCase):
    """land_handoff_only (the machine channel PR head build): only a land's own heads start it, never every
    full-tier push of a PR that keeps ready-to-land or full-ci on (2026-11-26: 168 builds an hour, 17 merges)."""

    CALLEES = {"mc.yml": {"types": ["opened", "synchronize", "reopened", "ready_for_review"],
                          "land_handoff_only": True}}

    def route(self, ev: dict, land_update: bool = False) -> list[str]:
        decided = head_tier.tier("pull_request", ev, land_switch="1")
        return pr_router.route(ev, self.CALLEES, ["cmux-tui/src/a.rs"], decided=decided, land_update=land_update)[0]

    def test_the_land_handoff_starts_it(self) -> None:
        for label in ("ready-to-land", "full-ci"):
            with self.subTest(label=label):
                self.assertEqual(self.route(land_event(labels=(label,), action="labeled", added=label)), ["mc.yml"])

    def test_a_push_to_a_labeled_pr_does_not(self) -> None:
        for labels in (("ready-to-land",), ("full-ci",), ()):
            for action in ("synchronize", "opened", "reopened", "ready_for_review"):
                with self.subTest(labels=labels, action=action):
                    self.assertEqual(self.route(land_event(labels=labels, action=action)), [])

    def test_another_label_does_not(self) -> None:
        self.assertEqual(self.route(land_event(labels=("ready-to-land", "risk:low"), action="labeled",
                                               added="risk:low")), [])

    def test_lands_update_branch_head_starts_it(self) -> None:
        self.assertEqual(self.route(land_event(labels=("ready-to-land",)), land_update=True), ["mc.yml"])

    def test_land_update_head_needs_the_label_a_synchronize_and_githubs_merge(self) -> None:
        old = head_tier.head_facts
        try:
            head_tier.head_facts = lambda ev: {"base_merge_only": True, "by_github": True}
            self.assertTrue(pr_router.land_update_head(land_event(labels=("ready-to-land",)), self.CALLEES))
            self.assertFalse(pr_router.land_update_head(land_event(labels=("full-ci",)), self.CALLEES))
            self.assertFalse(pr_router.land_update_head(land_event(labels=("ready-to-land",), action="opened"),
                                                        self.CALLEES))
            self.assertFalse(pr_router.land_update_head(land_event(labels=("ready-to-land",)), RouterTests.CALLEES))
            head_tier.head_facts = lambda ev: {"base_merge_only": True, "by_github": False}
            self.assertFalse(pr_router.land_update_head(land_event(labels=("ready-to-land",)), self.CALLEES))
            head_tier.head_facts = lambda ev: {"base_merge_only": False, "by_github": True}
            self.assertFalse(pr_router.land_update_head(land_event(labels=("ready-to-land",)), self.CALLEES))
            head_tier.head_facts = lambda ev: None
            self.assertFalse(pr_router.land_update_head(land_event(labels=("ready-to-land",)), self.CALLEES))
        finally:
            head_tier.head_facts = old

    def test_the_merge_trains_tip_starts_it(self) -> None:
        """lane/merge-train carries `hold`, never ready-to-land: its pushes are the one head a merge's tree can match
        while every member's own head is behind the base (0 of 18 merges matched their head, 2026-11-26 11-13Z)."""
        for action in ("opened", "reopened", "synchronize"):
            with self.subTest(action=action):
                ev = land_event(labels=("hold",), action=action)
                ev["pull_request"]["head"]["ref"] = "lane/merge-train"
                self.assertEqual(self.route(ev), ["mc.yml"])
        ev = land_event(labels=("hold",))
        ev["pull_request"]["head"]["ref"] = "lane/merge-train"
        self.assertEqual(pr_router.route(ev, {"mc.yml": dict(self.CALLEES["mc.yml"], skip_docs_only=True)},
                                         ["docs/a.md"])[0], [])
        fork = land_event(labels=("hold",), head_repo="someone/cmux")
        fork["pull_request"]["head"]["ref"] = "lane/merge-train"
        self.assertEqual(self.route(fork), [])
        other = land_event(labels=("hold",))
        other["pull_request"]["head"]["ref"] = "lane/merge-train-2"
        self.assertEqual(self.route(other), [])

    def test_the_machine_channel_callee_is_land_handoff_only(self) -> None:
        self.assertTrue(pr_router.load_manifest()["cmux-machine-channel.yml"].get("land_handoff_only"))



def _pr_event(labels: tuple[str, ...] = (), action: str = "synchronize") -> dict:
    repo = {"full_name": "manaflow-ai/cmux"}
    return {"action": action, "pull_request": {
        "draft": False, "base": {"ref": "feat-cmux-next", "repo": repo},
        "head": {"sha": "a" * 40, "repo": repo}, "labels": [{"name": n} for n in labels]}}


def _run(id_: int, path: str, conclusion: str | None, status: str = "completed") -> dict:
    return {"id": id_, "path": f".github/workflows/{path}", "status": status, "conclusion": conclusion}


class LabelledBaseMergeTests(unittest.TestCase):
    """Cut (a): a ready-to-land head's base merge onto a green head runs nothing; the land pulses the label."""

    FACTS = {"base_merge_only": True, "own_last": time.time(), "by_github": True, "previous": "b" * 40,
             "previous_green": True}

    def tier(self, ev: dict, **kwargs) -> tuple[str, str]:
        kwargs.setdefault("land_switch", "1")
        return head_tier.tier("pull_request", ev, facts=self.FACTS, now=time.time(), **kwargs)

    def test_a_labelled_base_merge_onto_a_green_head_runs_nothing_and_keeps_the_land_tier_pending(self) -> None:
        ev = _pr_event(("ready-to-land",))
        decided = self.tier(ev)
        self.assertEqual(decided[0], "none")
        with unittest.mock.patch.dict(os.environ, {"CI_LAND_TIER": "1"}):
            # pending with the cheap tier's description: land-judge pulses ready-to-land at this head.
            self.assertEqual(pr_router.land_status(ev, decided), "pending")
        callees = pr_router.load_manifest()
        start, _ = pr_router.route(ev, callees, ["README.md"], decided=decided, land_update=True)
        self.assertEqual(start, [])

    def test_the_land_handoff_full_ci_and_the_switch_run_the_usual_tier(self) -> None:
        # The land's own labeled event (the pulse) is not a synchronize: the land tier runs there.
        self.assertNotEqual(self.tier(_pr_event(("ready-to-land",), "labeled"))[0], "none")
        self.assertEqual(self.tier(_pr_event(("ready-to-land", "full-ci")))[0], "full")
        self.assertNotEqual(self.tier(_pr_event(("ready-to-land",)), labelled_switch="0")[0], "none")
        self.assertFalse(head_tier.green_rule_applies(_pr_event(("ready-to-land",)), "1", "1", "0"))
        self.assertTrue(head_tier.green_rule_applies(_pr_event(("ready-to-land",)), "1", "1", "1"))

    def test_a_red_or_unread_previous_head_keeps_the_usual_tier(self) -> None:
        for green in (False, None):
            facts = {**self.FACTS, "previous_green": green}
            decided = head_tier.tier("pull_request", _pr_event(("ready-to-land",)), facts=facts, now=time.time(),
                                     land_switch="1")
            self.assertNotEqual(decided[0], "none", green)


class RedBaseMergeTests(unittest.TestCase):
    """Cut (b): a base merge onto a red head reruns only what was not green there; anything unread runs all."""

    RED = [_run(1, "ci.yml", "success"), _run(2, "cmux-next.yml", "failure"), _run(3, "pr-router.yml", "failure")]

    def decide(self, ev: dict, runs: list | None, workflow: str, env: dict | None = None) -> tuple:
        real = head_tier.head_facts, head_tier.runs_at
        try:
            head_tier.head_facts = lambda e: {"base_merge_only": True, "own_last": time.time(), "by_github": True,
                                              "previous": "b" * 40}
            head_tier.runs_at = lambda *a: runs
            ref = f"manaflow-ai/cmux/.github/workflows/{workflow}@refs/pull/1/merge" if workflow else ""
            with unittest.mock.patch.dict(os.environ, {"GH_TOKEN": "t", "GITHUB_REPOSITORY": "manaflow-ai/cmux",
                                                       "GITHUB_WORKFLOW_REF": ref, **(env or {})}):
                return head_tier.decide_with_facts("pull_request", ev)
        finally:
            head_tier.head_facts, head_tier.runs_at = real

    def test_a_workflow_green_at_the_red_previous_head_runs_nothing(self) -> None:
        decided, facts = self.decide(_pr_event(), self.RED, "ci.yml")
        self.assertEqual(decided[0], "none")
        self.assertTrue(head_tier.rerun(decided), decided)
        self.assertEqual(facts["previous_runs"], self.RED)

    def test_a_workflow_red_cancelled_skipped_running_or_missing_there_runs_its_usual_tier(self) -> None:
        self.assertFalse(head_tier.rerun(self.decide(_pr_event(), self.RED, "cmux-next.yml")[0]))
        for runs in ([_run(1, "ci.yml", "cancelled"), _run(2, "x.yml", "failure")],
                     [_run(1, "ci.yml", "skipped"), _run(2, "x.yml", "failure")],
                     [_run(1, "ci.yml", None, "in_progress"), _run(2, "x.yml", "failure")],
                     [_run(2, "x.yml", "failure")],
                     [_run(5, "ci.yml", "failure"), _run(1, "ci.yml", "success")]):  # the newest run counts
            self.assertNotEqual(self.decide(_pr_event(), runs, "ci.yml")[0][0], "none", runs)

    def test_it_fails_open(self) -> None:
        self.assertNotEqual(self.decide(_pr_event(), None, "ci.yml")[0][0], "none")  # runs unread
        self.assertNotEqual(self.decide(_pr_event(), self.RED, "")[0][0], "none")  # own workflow unknown

    def test_full_ci_the_switch_the_land_handoff_and_forks_run_everything(self) -> None:
        self.assertEqual(self.decide(_pr_event(("full-ci",)), self.RED, "ci.yml")[0][0], "full")
        self.assertNotEqual(self.decide(_pr_event(), self.RED, "ci.yml", {"CI_RED_BASE_MERGE_RERUN": "0"})[0][0],
                            "none")
        self.assertNotEqual(self.decide(_pr_event(("ready-to-land",), "labeled"), self.RED, "ci.yml")[0][0], "none")
        fork = _pr_event()
        fork["pull_request"]["head"]["repo"] = {"full_name": "someone/cmux"}
        self.assertEqual(self.decide(fork, self.RED, "ci.yml")[0][0], "full")

    def test_a_landing_head_keeps_the_land_tier_pending(self) -> None:
        ev = _pr_event(("ready-to-land",))
        decided = self.decide(ev, self.RED, "ci.yml")[0]
        self.assertEqual(decided[0], "none")
        with unittest.mock.patch.dict(os.environ, {"CI_LAND_TIER": "1"}):
            self.assertEqual(pr_router.land_status(ev, decided), "pending")

    def test_helpers(self) -> None:
        self.assertEqual(head_tier.workflow_file("o/r/.github/workflows/ci.yml@refs/heads/x"), "ci.yml")
        self.assertEqual(head_tier.workflow_file(None), "")
        self.assertTrue(head_tier.passed_there(self.RED, "ci.yml"))
        self.assertFalse(head_tier.passed_there(self.RED, "pr-router.yml"))
        self.assertFalse(head_tier.passed_there(self.RED, ""))
        self.assertFalse(head_tier.passed_there(["junk"], "ci.yml"))


class RouterRerunPlanTests(unittest.TestCase):
    """Cut (b) inside the router: callees and table jobs that passed at the red previous head stay off."""

    @staticmethod
    def job(name: str, conclusion: str | None = "success", seconds: int = 600, status: str = "completed") -> dict:
        return {"name": name, "status": status, "conclusion": conclusion, "started_at": "2026-11-26T10:00:00Z",
                "completed_at": f"2026-11-26T10:{seconds // 60:02d}:{seconds % 60:02d}Z"}

    def names(self) -> dict:
        return pr_router.caller_names(pr_router.ENTRY.read_text())

    def test_caller_names_cover_every_callee(self) -> None:
        names = self.names()
        self.assertEqual(names["pr-pipeline.yml"], "pr pipeline")
        self.assertEqual(set(names), set(pr_router.caller_jobs(pr_router.ENTRY.read_text())))

    def test_only_red_cancelled_short_or_absent_reruns(self) -> None:
        jobs = [self.job("pr router"),
                self.job("Swift packages on Linux / test (shared)"),
                self.job("Swift packages on Linux / test (ios)", "skipped", 0),
                self.job("cmux-next fast gates / gate", "failure"),
                self.job("cmux-next size budget / check", "success", 20),  # under a minute: reruns
                self.job("classic API guard / guard", "cancelled"),
                self.job("pr pipeline / linux"),
                self.job("pr pipeline / web-browser", "failure"),
                self.job("iOS link FFI on Linux", "skipped", 0)]  # skipped there: never proved
        carried, rows = pr_router.rerun_plan(jobs, self.names(), ["linux", "web-browser"])
        self.assertEqual(carried, {"swift-linux-packages.yml"})
        self.assertEqual(rows, {"linux"})
        self.assertEqual(pr_router.rerun_plan(None, self.names(), ["linux"]), (set(), set()))

    def test_route_keeps_carried_callees_off(self) -> None:
        callees = pr_router.load_manifest()
        ev = _pr_event()
        start, why = pr_router.route(ev, callees, None, decided=("full", "ready for review"))
        self.assertIn("swift-linux-packages.yml", start)
        start, why = pr_router.route(ev, callees, None, decided=("full", "ready for review"),
                                     carried={"swift-linux-packages.yml"})
        self.assertNotIn("swift-linux-packages.yml", start)
        self.assertTrue(why["swift-linux-packages.yml"].startswith(head_tier.RERUN_REASON))

    def test_plan_for_fails_open_and_reads_only_a_red_previous_head(self) -> None:
        callees = pr_router.load_manifest()
        runs = [_run(1, "pr-router.yml", "failure")]
        real = pr_router.router_jobs_at
        try:
            pr_router.router_jobs_at = lambda *a: [self.job("Swift packages on Linux / test")]
            facts = {"previous_green": False, "previous_runs": runs}
            self.assertEqual(pr_router.plan_for(("full", ""), facts, callees), ({"swift-linux-packages.yml"}, set()))
            for f in (None, {**facts, "previous_green": None}, {**facts, "previous_green": True},
                      {"previous_green": False}):
                self.assertEqual(pr_router.plan_for(("full", ""), f, callees), (set(), set()), f)
            self.assertEqual(pr_router.plan_for(("none", ""), facts, callees), (set(), set()))
            pr_router.router_jobs_at = lambda *a: None  # unread jobs
            self.assertEqual(pr_router.plan_for(("full", ""), facts, callees), (set(), set()))
        finally:
            pr_router.router_jobs_at = real
        self.assertIsNone(pr_router.router_jobs_at([_run(1, "ci.yml", "failure")], "manaflow-ai/cmux", "t"))
        self.assertIsNone(pr_router.router_jobs_at(runs, "manaflow-ai/cmux", ""))


if __name__ == "__main__":
    unittest.main()


def _labeled(label: str, labels: tuple[str, ...] = ()) -> dict:
    ev = _pr_event(labels, "labeled")
    ev["label"] = {"name": label}
    return ev


class FullCiBaseMergeCarryTests(unittest.TestCase):
    """A full-ci pulse (or ready-to-land) on a head that only merges the base carries the previous head's land tier
    run: all green runs nothing, reds rerun only what was not green, and the full set runs on an overlap, a merge with
    edits of its own, no land tier run there, or anything unread."""

    GREEN = [_run(1, "ci.yml", "success"), _run(2, "pr-router.yml", "success"), _run(3, "cmux-next-guards.yml", "success")]
    RED = [_run(1, "ci.yml", "success"), _run(2, "pr-router.yml", "failure"), _run(3, "cmux-next-guards.yml", "failure")]

    def decide(self, ev: dict, runs: list | None = None, workflow: str = "ci.yml", status: str | None = "success",
               keys: tuple = ("k", "k"), facts: dict | None = None, env: dict | None = None) -> tuple:
        """decide_with_facts with git and the API stubbed: KEYS are own_patch_key's answers at the head and at the
        previous head (the PR's own change, with blobs)."""
        base = {"base_merge_only": True, "own_last": time.time(), "by_github": True, "previous": "b" * 40,
                "base_parent": "c" * 40}
        real = head_tier.head_facts, head_tier.runs_at, head_tier.land_status_at, head_tier.own_patch_key
        answers = {"a" * 40: keys[0], "b" * 40: keys[1]}
        try:
            head_tier.head_facts = lambda e, *a, **k: base if facts is None else facts
            head_tier.runs_at = lambda *a: self.GREEN if runs is None else runs
            head_tier.land_status_at = lambda *a: status
            head_tier.own_patch_key = lambda repo, b, sha, token, blobs=False: answers.get(sha) if blobs else None
            ref = f"manaflow-ai/cmux/.github/workflows/{workflow}@refs/pull/1/merge" if workflow else ""
            with unittest.mock.patch.dict(os.environ, {"GH_TOKEN": "t", "GITHUB_REPOSITORY": "manaflow-ai/cmux",
                                                       "GITHUB_WORKFLOW_REF": ref, "CI_LAND_TIER": "1",
                                                       **(env or {})}):
                return head_tier.decide_with_facts("pull_request", ev)
        finally:
            (head_tier.head_facts, head_tier.runs_at, head_tier.land_status_at, head_tier.own_patch_key) = real

    def test_a_full_ci_pulse_onto_an_all_green_land_tier_run_carries_it(self) -> None:
        for label in ("full-ci", "ready-to-land"):
            ev = _labeled(label, ("ready-to-land",))
            decided, _ = self.decide(ev)
            self.assertEqual(decided[0], "none", (label, decided))
            self.assertTrue(head_tier.full_carried(decided))
            with unittest.mock.patch.dict(os.environ, {"CI_LAND_TIER": "1"}):
                self.assertEqual(pr_router.land_status(ev, decided), "success")
            start, _ = pr_router.route(ev, pr_router.load_manifest(), ["README.md"], decided=decided)
            self.assertEqual(start, [])

    def test_reds_rerun_only_what_was_not_green(self) -> None:
        ev = _labeled("full-ci")
        decided, _ = self.decide(ev, self.RED, "ci.yml")  # green there: runs nothing
        self.assertTrue(head_tier.full_carried(decided), decided)
        decided, facts = self.decide(ev, self.RED, "cmux-next-guards.yml")  # red there: runs again
        self.assertEqual(decided[0], "full")
        decided, facts = self.decide(ev, self.RED, "pr-router.yml")
        self.assertTrue(head_tier.full_rerun(decided), decided)
        self.assertEqual(facts["previous_runs"], self.RED)
        self.assertIs(facts["previous_green"], False)
        real = pr_router.router_jobs_at
        try:  # the router reruns only its jobs that were not green there
            pr_router.router_jobs_at = lambda *a: [RouterRerunPlanTests.job("Swift packages on Linux / test")]
            carried, _ = pr_router.plan_for(decided, facts, pr_router.load_manifest())
        finally:
            pr_router.router_jobs_at = real
        self.assertEqual(carried, {"swift-linux-packages.yml"})
        with unittest.mock.patch.dict(os.environ, {"CI_LAND_TIER": "1"}):
            self.assertEqual(pr_router.land_status(ev, decided), "success")

    def test_case_1_and_2_an_overlap_or_an_edit_of_the_merge_runs_the_full_set(self) -> None:
        # The PR's own change differs before and after the merge (a base change merged into one of its files, a
        # conflict resolved, or a file edited in the merge): the keys differ.
        decided, _ = self.decide(_labeled("full-ci"), keys=("k1", "k2"))
        self.assertEqual(decided, ("full", "full-ci label"))
        for keys in ((None, "k"), ("k", None)):  # a compare of 300 files or more, or a binary file: unread
            self.assertEqual(self.decide(_labeled("full-ci"), keys=keys)[0][0], "full", keys)

    def test_case_2_a_merge_that_is_not_only_a_base_merge_runs_the_full_set(self) -> None:
        own = {"base_merge_only": False, "own_last": None, "by_github": False}
        self.assertEqual(self.decide(_labeled("full-ci"), facts=own)[0][0], "full")

    def test_case_3_no_land_tier_run_at_the_previous_head_runs_the_full_set(self) -> None:
        for status in ("pending", "", "failure"):
            self.assertEqual(self.decide(_labeled("full-ci"), status=status)[0][0], "full", status)

    def test_any_lookup_error_runs_the_full_set(self) -> None:
        self.assertEqual(self.decide(_labeled("full-ci"), status=None)[0][0], "full")  # status unread
        self.assertEqual(self.decide(_labeled("full-ci"), facts={})[0][0], "full")  # git unread
        real = head_tier.runs_at
        try:
            decided, _ = self.decide(_labeled("full-ci"), runs=[])
            self.assertEqual(decided[0], "full")  # no runs at all is not green
        finally:
            head_tier.runs_at = real
        self.assertIsNone(head_tier.full_carry({"base_merge_only": True, "full_landed": True,
                                                "own_change_kept": True}))  # runs unread

    def test_the_switch_turns_it_off(self) -> None:
        decided, _ = self.decide(_labeled("full-ci"), env={"CI_FULL_CI_BASE_MERGE_CARRY": "0"})
        self.assertEqual(decided, ("full", "full-ci label"))

    def test_other_events_labels_and_forks_are_untouched(self) -> None:
        self.assertFalse(head_tier.full_carry_rule_applies(_pr_event(("full-ci",))))  # a synchronize
        self.assertFalse(head_tier.full_carry_rule_applies(_labeled("some-label", ("full-ci",))))
        fork = _labeled("full-ci")
        fork["pull_request"]["head"]["repo"] = {"full_name": "someone/cmux"}
        self.assertFalse(head_tier.full_carry_rule_applies(fork))
        draft = _labeled("full-ci")
        draft["pull_request"]["draft"] = True
        self.assertFalse(head_tier.full_carry_rule_applies(draft))
        self.assertTrue(head_tier.full_carry_rule_applies(_labeled("full-ci")))
        # a synchronize with full-ci on keeps the full tier
        self.assertEqual(self.decide(_pr_event(("full-ci",)))[0], ("full", "full-ci label"))

    def test_the_patch_key_with_blobs_sees_a_merged_base_change(self) -> None:
        before = {"files": [{"filename": "a.rs", "status": "modified", "sha": "1", "patch": "@@ -1 +1 @@\n-x\n+y"}]}
        after = {"files": [{"filename": "a.rs", "status": "modified", "sha": "2", "patch": "@@ -5 +5 @@\n-x\n+y"}]}
        self.assertEqual(head_tier.patch_key(before), head_tier.patch_key(after))
        self.assertNotEqual(head_tier.patch_key(before, blobs=True), head_tier.patch_key(after, blobs=True))
