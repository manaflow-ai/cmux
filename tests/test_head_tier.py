"""scripts/ci/head_tier.py and its use in the pr router: a draft head runs the cheap tier only."""

from __future__ import annotations

import os
import re
import subprocess
import sys
import tempfile
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


class IdleTests(unittest.TestCase):
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

    def test_two_base_merges_on_a_branch_idle_three_days_run_nothing(self) -> None:
        facts = head_tier.head_facts(self.event(self.head))
        self.assertEqual(facts, {"base_merge_only": True, "own_last": self.now - 3 * DAY})
        self.assertEqual(head_tier.tier("pull_request", self.event(self.head), facts=facts, now=self.now)[0], "none")

    def test_a_recent_own_commit_is_not_idle(self) -> None:
        facts = head_tier.head_facts(self.event(self.head))
        self.assertEqual(head_tier.tier("pull_request", self.event(self.head), facts=facts,
                                        now=self.now - 2 * DAY - 60)[0], "full")

    def test_an_own_commit_head_is_full(self) -> None:
        facts = head_tier.head_facts(self.event(self.own))
        self.assertEqual(facts, {"base_merge_only": False, "own_last": None})
        self.assertEqual(head_tier.tier("pull_request", self.event(self.own), facts=facts, now=self.now)[0], "full")

    def test_full_ci_the_switch_and_other_actions_override(self) -> None:
        facts = head_tier.head_facts(self.event(self.head))
        tier = head_tier.tier
        self.assertEqual(tier("pull_request", self.event(self.head, labels=("full-ci",)), facts=facts,
                              now=self.now)[0], "full")
        self.assertEqual(tier("pull_request", self.event(self.head), facts=facts, now=self.now, idle_switch="0")[0],
                         "full")
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
    "chief-evals.yml", "cloud-chief-machine.yml", "cloud-journey-pr.yml", "cloud-vm-guest-install.yml",
    "cloudflare-relay.yml", "cmux-cloud-cli.yml", "cmux-mobile-ffi.yml", "cmux-next-car-guards.yml",
    "cmux-next-fast-gates.yml", "cmux-next-guards.yml", "cmux-next-hot-verify.yml", "cmux-next-ios-kit.yml",
    "cmux-next-pr-autofix.yml", "cmux-next-shell-integration.yml", "cmux-next-terminal.yml", "cmux-rd-windows.yml",
    "cmux-vm.yml", "cmux-vm-clients.yml", "cmux-vm-cloud.yml", "cmux-vnc.yml", "ios-e2e.yml",
    "ios-reliability-matrix.yml", "iroh-v2.yml", "measure-swift-typecheck.yml", "relay-tls.yml", "release-rails.yml",
    "signing-keychain-macos.yml", "terminal-hang-diagnostics.yml", "test-ios.yml")}
GATED["backend-migrations.yml"] = "pull_request_target"
# Only the draft tier: its one job runs only when the motion-golden label is the one added (a person asks for it).
DRAFT_ONLY = {"cmux-next-motion-golden.yml": "pull_request"}
# backend-migrations applies a migration when a person adds the `backend:apply-migrations` label, draft or not.
KEEP_ON_LABELED = {"backend-migrations.yml"}
# Re-run-only on a pull request (#53046: act_fixer asks for the re-run after a mechanical red), so a cheap head's
# first run never starts them either.
RERUN_ONLY_ON_PULL_REQUEST = {("cmux-next-pr-autofix.yml", "repair")}
# Push-only jobs: their if: excludes a pull request, so no cheap head ever runs them.
NEVER_ON_PULL_REQUEST = {("cmux-next-pr-autofix.yml", "push"), ("chief-evals.yml", "fleet-ab")}
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

if __name__ == "__main__":
    unittest.main()
