"""scripts/ci/head_tier.py and its use in the pr router: a draft head runs the cheap tier only."""

from __future__ import annotations

import os
import re
import subprocess
import sys
import tempfile
import time
import unittest
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
                                 "previous": self.git("rev-parse", "HEAD^1")})
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
                                 "previous": self.git("rev-parse", "HEAD^1")})
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
        for label in ("full-ci", "ready-to-land"):
            self.assertEqual(tier("pull_request", self.event(self.head, labels=(label,)), facts=facts,
                                  now=recent)[0], "full", label)
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
    "app-store-shelf.yml", "auth-refresh-tests.yml", "backend.yml", "billing.yml", "chat-open-perf-report.yml",
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
    """The job-level expression equal to head_tier.tier(..., land_switch=CI_LAND_TIER) == "full", the idle rule aside
    (an idle base merge into a gated workflow runs it as a ready head does)."""
    parts = [
        f"github.event_name != '{event_name}'",
        "contains(github.event.pull_request.labels.*.name, 'full-ci')",
        "(github.event.pull_request.draft == true && (vars.CI_DRAFT_CHEAP_TIER || '1') == '0')",
        "(github.event.pull_request.draft != true && (contains(github.event.pull_request.labels.*.name, 'ready-to-land')"
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


def _trigger_types(text: str, event_name: str) -> str:
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
                if (name, job) in KEEP_ON_EVERY_HEAD:
                    self.assertNotIn("CI_LAND_TIER", condition or "", f"{name}: job {job}")
                    continue
                self.assertIsNotNone(condition, f"{name}: job {job} has no if:")
                if (name, job) in CLOSED_OR_LAND:
                    self.assertIn(f"(github.event.action == 'closed' || {expected})", condition, f"{name}: job {job}")
                    continue
                self.assertIn(expected, condition, f"{name}: job {job}")
                self.assertNotIn("github.event.pull_request.draft != true ||", condition, f"{name}: job {job}")
            types = _trigger_types(text, event_name)
            self.assertIn("ready_for_review", types, name)
            self.assertIn("labeled", types, name)

    def test_draft_only_workflows_keep_the_draft_condition(self) -> None:
        for name, event_name in DRAFT_ONLY.items():
            text = (self.WORKFLOWS / name).read_text()
            for job, condition in _job_ifs(text).items():
                self.assertIn(draft_tier_condition(event_name), condition or "", f"{name}: job {job}")
            self.assertIn("ready_for_review", _trigger_types(text, event_name), name)

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
                                    ev = land_event(draft, labels, base=base, head_repo=head_repo)
                                    full = head_tier.tier(event_name, ev, switch, idle_switch="0",
                                                          land_switch=land)[0] == "full"
                                    runs = (
                                        "full-ci" in labels
                                        or (draft and switch == "0")
                                        or (not draft and ("ready-to-land" in labels or base != "feat-cmux-next"
                                                           or head_repo != "manaflow-ai/cmux" or land == "0"))
                                    )
                                    self.assertEqual(full, runs, (event_name, draft, labels, base, head_repo,
                                                                  switch, land))


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

if __name__ == "__main__":
    unittest.main()
