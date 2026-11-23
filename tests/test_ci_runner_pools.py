#!/usr/bin/env python3
"""scripts/ci/runner_pools.py keeps RUNNER_POOLS on a live member of every declared pool."""

from __future__ import annotations

import contextlib
import copy
import datetime as dt
import io
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import runner_pools  # noqa: E402

# The queue janitor's macos-pool-load snapshot as main's janitor wrote it at 22:53Z on 2026-10-28
# (runner names and warm state dropped). Its starved and unserved are empty: they describe owned
# glaeda-* labels, never pool members.
# CI_CLOUD_OVERFLOW_SAVED as the switch wrote it at 04:23Z on 2026-11-01 (trimmed): only macOS variables.
MACOS_ONLY_RECORD = json.dumps({"changed": {"MACOS_RUNNER_PR": {"after": "glaeda-std-xcode-26.6",
                                                                "before": "blacksmith-6vcpu-macos-26"}},
                                "since": "2026-11-01T04:23:40Z"})
SWITCHED_LINUX = json.dumps({"changed": {"LINUX_RUNNER": {"after": "blacksmith-16vcpu-ubuntu-2404",
                                                          "before": "blacksmith-32vcpu-ubuntu-2404"}}})
RECORDED = json.loads((ROOT / "tests/fixtures/runner-pools/macos-pool-load-2026-10-28T2253Z.json").read_text())
SNAPSHOT_AT = dt.datetime(2026, 10, 28, 22, 53, 37, tzinfo=dt.timezone.utc)
NOW = SNAPSHOT_AT + dt.timedelta(minutes=2)
POOLS = {
    "linux": {"why": "x", "members": ["blacksmith-32vcpu-ubuntu-2404", "blacksmith-16vcpu-ubuntu-2404"]},
    "macos_26": {"why": "x", "members": ["blacksmith-6vcpu-macos-26", "blacksmith-12vcpu-macos-26"]},
    "macos_26_large": {"why": "x", "members": ["blacksmith-12vcpu-macos-26", "blacksmith-6vcpu-macos-26"]},
}


def blacksmith_failover_pools(path=runner_pools.RUNNERS, env=None):
    """The declared pools without their owned GCP lead and Freestyle rung (runner_pools.owned_prefix()): the
    Blacksmith-to-Blacksmith failover the tests below exercise, as it runs once the owned members are full."""
    pools = REAL_LOAD_POOLS(path, env)
    for spec in pools.values():
        if spec.get("members"):
            spec["members"] = spec["members"][len(runner_pools.owned_prefix(spec["members"])):]
    return pools


REAL_LOAD_POOLS = runner_pools.load_pools


class BlacksmithFailover:
    """Mixin: runner_pools.main() and load_pools() read blacksmith_failover_pools()."""

    def setUp(self) -> None:
        super().setUp()
        runner_pools.load_pools = blacksmith_failover_pools
        self.addCleanup(setattr, runner_pools, "load_pools", REAL_LOAD_POOLS)


def fresh_snapshot(now):
    """A complete janitor snapshot from a minute before NOW that saw no Linux start: beside it a probe's stall
    counts (label_evidence())."""
    return dict(copy.deepcopy(RECORDED), generated_at=runner_pools.iso(now - dt.timedelta(minutes=1)), label_started={})


def health(labels, checked=NOW):
    # Exactly what the overflow switch writes to CI_CLOUD_LABEL_HEALTH (cloud_overflow_switch.label_health()).
    import cloud_overflow_switch as switch
    stalled = [label for label, state in labels.items() if state == "stalled"]
    return switch.label_health(list(labels), stalled, checked=runner_pools.iso(checked),
                               run="https://github.com/x/y/actions/runs/1", minutes=5)


class Declared(unittest.TestCase):
    def test_the_declared_pools_are_valid(self) -> None:
        self.assertEqual(runner_pools.spec_problems(runner_pools.load_pools()), [])

    def test_the_linux_pool_is_the_runner_set(self) -> None:
        # Leo, 2026-10-28: "just pin the set of the shit that isn't hilariously slow".
        # Smallest first: Blacksmith caps vCPUs at once, so the live member is the small size (2026-11-01).
        # Leo, 2026-11-21: "i just am like fundamentally opposed to paying for ci when i exist": the owned GCP
        # pool leads. Leo, 2026-11-19: "We still keep Blacksmith sometimes, but stop fucking relying on it. [...] We
        # could use Freestyle": a full GCP pool overflows to Freestyle, and Blacksmith only after it.
        self.assertEqual(runner_pools.load_pools()["linux"]["members"],
                         ["cmux-fleet-linux-x64", "cmux-freestyle-linux-x64", "blacksmith-4vcpu-ubuntu-2404",
                          "blacksmith-16vcpu-ubuntu-2404"])

    def test_every_blacksmith_linux_size_has_its_own_pool(self) -> None:
        # Leo, 2026-10-28: "Where the f***ing are the generalized solution to all these problems that these
        # incessant pins?" A job measured at one size reads that size's pool, so a stalled size moves by declaration.
        pools = runner_pools.load_pools()
        for size, name in ((2, "linux_2"), (4, "linux_4"), (8, "linux_8"), (16, "linux_16"), (32, "linux_32")):
            with self.subTest(pool=name):
                listed = runner_pools.members(pools[name])
                if pools[name].get("ephemeral_only"):
                    self.assertFalse(runner_pools.owned_gcp(listed[0]))
                else:
                    self.assertEqual(listed[0], "cmux-fleet-linux-x64")
                    # Freestyle VMs have 8 vCPU: only the pools whose jobs fit there list the rung.
                    self.assertEqual(listed[1] == "cmux-freestyle-linux-x64", size <= 8, name)
                    listed = listed[len(runner_pools.owned_prefix(listed)):]
                self.assertEqual(listed[0], f"blacksmith-{size}vcpu-ubuntu-2404")
                self.assertGreater(len(listed), 1, f"{name} needs a member to fail over to")

    def test_every_bounded_selector_accepts_every_linux_member(self) -> None:
        # Review of #30340: a member a bounded selector refuses (contains([...], vars.LINUX_RUNNER) && ... || '<4 vCPU>')
        # sends its readers back to the stalled size when the pool steps onto it.
        selector = re.compile(r"contains\(fromJSON\('(\[[^']*\])'\), (?:vars\.LINUX_RUNNER|fromJSON\(vars\.RUNNER_POOLS[^)]*\)\.linux)\)"
                              r" && (?:vars\.LINUX_RUNNER|fromJSON\(vars\.RUNNER_POOLS[^)]*\)\.linux) \|\| '(blacksmith-4vcpu-ubuntu-2404)'")
        members = [m for m in runner_pools.load_pools()["linux"]["members"] if not runner_pools.owned_lead(m)]
        found = 0
        for workflow in sorted((ROOT / ".github/workflows").glob("*.y*ml")):
            for match in selector.finditer(workflow.read_text(encoding="utf-8")):
                found += 1
                with self.subTest(workflow=workflow.name):
                    self.assertLessEqual(set(members), set(json.loads(match.group(1))))
        self.assertGreater(found, 0)

    def test_no_pool_names_a_reused_machine(self) -> None:
        # A job reading a pool, a fork's pull request included, never lands on an owned Mac:
        # those come only through a picker. The one owned exception is ephemeral too: a named owned Linux VM
        # label (one job per fresh VM clone) as a pool's first member.
        for name, spec in runner_pools.load_pools().items():
            for index, label in enumerate(runner_pools.members(spec)):
                with self.subTest(pool=name, label=label):
                    if index == 0 and runner_pools.owned_ephemeral(label):
                        continue
                    # The persistent GCP pool (cmux-fleet-linux-x64) leads only pools no fork or write-token
                    # job needs fresh: those are ephemeral_only (spec_problems()).
                    if index == 0 and runner_pools.owned_gcp(label) and not spec.get("ephemeral_only"):
                        continue
                    # So does the Freestyle rung right after it (one VM per job; never a fork's run).
                    if index == 1 and runner_pools.owned_freestyle(label) and not spec.get("ephemeral_only"):
                        continue
                    self.assertRegex(label, runner_pools.HOSTED if spec.get("hosted") else runner_pools.EPHEMERAL)

    def test_the_owned_linux_vm_pool_leads_with_the_fleet_and_overflows_to_blacksmith(self) -> None:
        # Leo, 2026-11-19: "dont we have linux vms set up on everybody yet? we shuold" ... "on the fleet".
        pools = runner_pools.load_pools()
        self.assertEqual(runner_pools.members(pools["linux_owned_small"]),
                         ["glaeda-linux-arm64", "blacksmith-2vcpu-ubuntu-2404", "blacksmith-4vcpu-ubuntu-2404"])
        # Never in the pool LINUX_RUNNER mirrors: about 140 workflows read it, x64-only jobs among them.
        for name in runner_pools.MIRRORS.values():
            self.assertFalse(any(runner_pools.owned_ephemeral(label) for label in runner_pools.members(pools[name])))

    def test_linux_runner_may_name_the_persistent_pool_but_nothing_else_outside_its_pool(self) -> None:
        # The persistent pool serves every x64 Linux label (Leo, 2026-11-21 00:38Z: "just... accept all labels"),
        # so nothing waits on it; it stays out of pools.linux, so the writer never routes the pool's readers there.
        pools = runner_pools.load_pools()
        for label in sorted(runner_pools.PERSISTENT_LINUX_POOL_LABELS):
            with self.subTest(label=label):
                self.assertEqual(runner_pools.mirror_problems({"LINUX_RUNNER": label}, pools, record=None), [])
                # The owned GCP label (OWNED_GCP_LINUX) leads pools.linux by design and overflows when full
                # (#49556); every other persistent label stays out.
                if not runner_pools.owned_gcp(label):
                    self.assertNotIn(label, runner_pools.members(pools["linux"]))
        self.assertTrue(runner_pools.mirror_problems({"LINUX_RUNNER": "glaeda-linux-arm64"}, pools, record=None))

    def test_an_owned_linux_vm_label_may_only_lead_a_pool_with_blacksmith_after_it(self) -> None:
        good = {"a": {"why": "x", "members": ["glaeda-linux-arm64", "blacksmith-2vcpu-ubuntu-2404"]}}
        self.assertEqual(runner_pools.spec_problems(good), [])
        bad = {
            # Alone: nothing to overflow to when the few VMs are taken.
            "alone": {"why": "x", "members": ["glaeda-linux-arm64"]},
            # After a Blacksmith member: a failover onto a handful of VMs.
            "second": {"why": "x", "members": ["blacksmith-2vcpu-ubuntu-2404", "glaeda-linux-arm64"]},
            # Followed only by another owned label.
            "owned_only": {"why": "x", "members": ["glaeda-linux-arm64", "glaeda-std-xcode-26.6"]},
            # A label that only looks like one: owned labels are named, never matched by pattern.
            "lookalike": {"why": "x", "members": ["glaeda-linux-x64", "blacksmith-2vcpu-ubuntu-2404"]},
        }
        found = "\n".join(runner_pools.spec_problems(bad))
        for name in bad:
            self.assertIn(f"pools.{name}:", found)

    def test_the_release_valve_and_outage_override_never_take_an_owned_linux_vm_as_x64(self) -> None:
        pools = runner_pools.load_pools(env={runner_pools.HOSTED_OVERRIDE: "ubuntu-24.04"})
        spec = pools["linux_owned_small"]
        # The hosted outage override stands in for Blacksmith x64 pools only; this pool keeps its members.
        self.assertFalse(spec.get("hosted"))
        self.assertEqual(runner_pools.members(spec)[0], "glaeda-linux-arm64")
        # The valve is judged on the Blacksmith members: nothing is smaller than 2 vCPU.
        self.assertEqual(runner_pools.valve_labels(spec, pools), [])
        self.assertEqual(runner_pools.valve_labels(
            {"members": ["glaeda-linux-arm64", "blacksmith-4vcpu-ubuntu-2404"]}, runner_pools.load_pools()),
            ["blacksmith-2vcpu-ubuntu-2404"])

    def test_spec_problems_refuse_owned_hosted_and_unknown_labels(self) -> None:
        bad = {
            "a": {"why": "x", "members": ["glaeda-std-xcode-26.6"]},
            "b": {"why": "x", "members": ["ubuntu-24.04"]},
            "c": {"why": "x", "hosted": True, "members": ["ubuntu-24.04"]},
            "d": {"why": "x", "members": ["some-host"]},
            "E": {"why": "x", "members": ["blacksmith-32vcpu-ubuntu-2404"]},
            "f": {"members": ["blacksmith-32vcpu-ubuntu-2404"]},
        }
        found = "\n".join(runner_pools.spec_problems(bad))
        for name in ("pools.a", "pools.b", "pools.c", "pools.d", "pools.E", "pools.f"):
            self.assertIn(name, found)

    def test_the_reconciler_runs_in_the_overflow_watch_with_the_switch_token(self) -> None:
        # No new credential: the token the overflow switch already mints writes RUNNER_POOLS.
        workflow = yaml.safe_load((ROOT / ".github/workflows/ci-cloud-overflow-probe.yml").read_text())
        steps = workflow["jobs"]["watch"]["steps"]
        [step] = [s for s in steps if "runner_pools.py" in str(s.get("run", ""))]
        self.assertEqual(step["env"]["SWITCH_TOKEN"], "${{ steps.switch-token.outputs.token }}")
        self.assertEqual(step["env"]["RUNNER_POOLS"], "${{ vars.RUNNER_POOLS }}")
        self.assertIn("always()", str(step.get("if")))
        names = [s.get("name") for s in steps]
        self.assertLess(names.index(step["name"]), names.index("End this run's stuck probe"))

    def test_the_reconciler_reads_as_cmux_bot_not_the_shared_workflow_token(self) -> None:
        # Its GH_TOKEN only reads (queue sample, pool snapshot artifact): cmux-bot's read-only token, minted
        # earlier in the same job, keeps those reads off the repository GITHUB_TOKEN pool every workflow shares.
        workflow = yaml.safe_load((ROOT / ".github/workflows/ci-cloud-overflow-probe.yml").read_text())
        steps = workflow["jobs"]["watch"]["steps"]
        [step] = [s for s in steps if "runner_pools.py" in str(s.get("run", ""))]
        [mint] = [s for s in steps if s.get("id") == "cmux-bot-token"]
        self.assertEqual(mint["with"]["permission-actions"], "read")
        self.assertEqual(step["env"]["GH_TOKEN"], "${{ steps.cmux-bot-token.outputs.token || github.token }}")
        self.assertNotIn("GLAEDA_ROUTE", step["env"]["GH_TOKEN"])
        names = [s.get("name") for s in steps]
        self.assertLess(names.index(mint["name"]), names.index(step["name"]))

    def test_the_watch_runs_the_pinned_linux_pool_spill_with_main_as_fallback(self) -> None:
        # cmux#31884: the queue-aware spill runs from a reviewed feat-cmux-next commit beside main's policy.
        workflow = yaml.safe_load((ROOT / ".github/workflows/ci-cloud-overflow-probe.yml").read_text())
        steps = workflow["jobs"]["watch"]["steps"]
        [checkout] = [s for s in steps if s.get("id") == "spill-tooling"]
        self.assertRegex(checkout["with"]["ref"], r"^[0-9a-f]{40}$")
        # 2026-11-18: the pin sat at c736d2e (2026-11-01) for 17 days, so the hosted-first valve (cmux#45861) never
        # ran: RUNNER_POOLS.hosted_saturated stayed unset while GitHub-hosted held ~2,500 queued runs (median wait
        # 3 h), and nightly 44243166776's publish-nightly-next-github queued behind them. The pin's comment names the
        # spill changes it carries; it must carry the valve.
        self.assertNotEqual(checkout["with"]["ref"], "c736d2e6c1db29305963040992f89f9466630f79")
        pin_line = next(line for line in (ROOT / ".github/workflows/ci-cloud-overflow-probe.yml").read_text().splitlines()
                        if checkout["with"]["ref"] in line)
        self.assertIn("#45861", pin_line, "the spill pin must carry the hosted-first valve")
        self.assertEqual(checkout["with"]["persist-credentials"], False)
        # cmuxterm-hq#16113 step 3: the spill imports expected_wait.py (and its deadline_http.py client) for the
        # wait-based admission verdict; without them it publishes none.
        self.assertIn("#48949", pin_line, "the spill pin must carry wait-based admission")
        self.assertEqual(set(checkout["with"]["sparse-checkout"].split()),
                         {"scripts/ci/linux_pool_spill.py", "scripts/ci/runner_pool_reconcile.py",
                          "scripts/ci/expected_wait.py", "scripts/ci/deadline_http.py"})
        self.assertTrue(checkout.get("continue-on-error"))
        [step] = [s for s in steps if "runner_pools.py" in str(s.get("run", ""))]
        self.assertIn('--policy-root "$GITHUB_WORKSPACE"', step["run"])
        # Without the checkout, or when the spill fails, main's policy still runs alone.
        self.assertEqual(step["run"].count("python3 scripts/ci/runner_pools.py"), 2)
        # The admission verdict's inputs reach the spill, read-only: the controller that serves its feeds and the
        # owned families' slots.
        self.assertEqual(step["env"]["RUNNER_ADMISSION_CONTROLLER"], "${{ vars.RUNNER_ADMISSION_CONTROLLER }}")
        self.assertEqual(step["env"]["CI_OWNED_POOL_SLOTS"], "${{ vars.CI_OWNED_POOL_SLOTS }}")
        names = [s.get("name") for s in steps]
        self.assertLess(names.index(checkout["name"]), names.index(step["name"]))


    def test_hosted_light_rescue_runs_without_the_overflow_probe(self) -> None:
        # A queued probe must not hold the recovery that moves other queued light jobs.
        path = ROOT / ".github/workflows/ci-hosted-light-rescue.yml"
        self.assertTrue(path.is_file(), "hosted light rescue needs an independent scheduler")
        workflow = yaml.safe_load(path.read_text())
        events = workflow.get("on", workflow.get(True))
        self.assertEqual(events["schedule"], [{"cron": "*/5 * * * *"}])
        self.assertNotEqual(workflow["concurrency"]["group"], "ci-cloud-overflow-probe")
        self.assertFalse(workflow["concurrency"]["cancel-in-progress"])
        rescue = workflow["jobs"]["rescue"]
        self.assertNotIn("needs", rescue)
        self.assertEqual(rescue["permissions"], {"actions": "write", "contents": "read"})
        self.assertNotIn("secrets.", path.read_text())
        self.assertNotIn("CI_LIGHT_LANE_RUNNER", rescue["runs-on"])
        self.assertNotIn("CI_SIDE_LANE_RUNNER", rescue["runs-on"])
        self.assertIn("vars.CI_TRUSTED_RUNNER", rescue["runs-on"])
        self.assertIn("ephemeral-required", path.read_text())
        self.assertEqual(rescue["steps"][0]["with"]["ref"], "main")
        self.assertTrue((ROOT / "scripts/ci/hosted_light_rescue.py").is_file())
        old = yaml.safe_load((ROOT / ".github/workflows/ci-cloud-overflow-probe.yml").read_text())
        self.assertNotIn("hosted_light_rescue.py", str(old["jobs"]))

    def test_the_independent_schedule_only_wakes_the_single_sweeper(self) -> None:
        workflow = yaml.safe_load((ROOT / ".github/workflows/ci-hosted-light-rescue.yml").read_text())
        steps = workflow["jobs"]["rescue"]["steps"]
        [step] = [s for s in steps if "hosted_light_rescue.py" in str(s.get("run", ""))]
        self.assertIn("python3 scripts/ci/hosted_light_rescue.py", step["run"])
        self.assertEqual(step["env"]["GH_TOKEN"], "${{ github.token }}")
        self.assertIn("--wake-sweeper", step["run"])
        self.assertNotIn("--runners", step["run"])
        self.assertNotIn(".rescue-workflows", str(steps))

    def test_a_failed_optional_policy_checkout_does_not_stop_the_primary_sweep(self) -> None:
        doc = yaml.safe_load((ROOT / ".github/workflows/ci-owned-pool-rescue.yml").read_text())
        steps = doc["jobs"]["rescue"]["steps"]
        [policy] = [s for s in steps if s.get("with", {}).get("path") == ".rescue-workflows"]
        # Actions skips subsequent ordinary steps after a fatal action failure. This optional
        # checkout must clear that failure so the existing owned-pool sweeper can still start.
        self.assertTrue(policy.get("continue-on-error"))
        self.assertLessEqual(policy.get("timeout-minutes", 360), 2)
        [watch] = [s for s in steps if "owned_pool_rescue.py" in str(s.get("run", ""))]
        self.assertLess(steps.index(policy), steps.index(watch))

    def test_the_minute_sweeper_isolates_light_rescue_from_the_routing_app(self) -> None:
        doc = yaml.safe_load((ROOT / ".github/workflows/ci-owned-pool-rescue.yml").read_text())
        [step] = [s for s in doc["jobs"]["rescue"]["steps"] if "owned_pool_rescue.py" in str(s.get("run", ""))]
        # cmux-bot first (its own installation pool), the workflow token as fallback; never the routing App.
        self.assertEqual(step["env"]["HOSTED_LIGHT_TOKEN"], "${{ steps.cmux-bot-token.outputs.token || github.token }}")
        self.assertEqual(step["env"]["HOSTED_LIGHT_FALLBACK_TOKEN"], "${{ github.token }}")
        self.assertNotIn("GLAEDA_ROUTE", str(step["env"]["HOSTED_LIGHT_TOKEN"]))
        self.assertEqual(step["env"]["HOSTED_LIGHT_DISABLED"], "${{ vars.CI_HOSTED_LIGHT_RESCUE_DISABLED }}")
        self.assertEqual(step["env"]["HOSTED_LIGHT_POLICY"], ".rescue-workflows/.github")


class Evidence(unittest.TestCase):
    def test_it_reads_the_variable_the_switch_writes(self) -> None:
        import cloud_overflow_switch as switch
        self.assertEqual(runner_pools.HEALTH_VARIABLE, switch.HEALTH_VARIABLE)
        # The switch probes every member of the linux pool, so each one has health of its own.
        self.assertEqual(set(switch.PROBE_LABELS),
                         {m for m in runner_pools.load_pools()["linux"]["members"] if not runner_pools.owned_lead(m)})

    def test_every_x64_linux_label_a_pool_can_name_is_probed(self) -> None:
        # 2026-11-18: linux_16 and linux_32 sat on blacksmith-32vcpu-ubuntu-2404 while it started nothing
        # from about 23:12Z (488 jobs queued, none running, at 01:01Z). The probe asked only for 4 and 16
        # vCPU, and the janitor's snapshot was truncated (2,500 queued runs), so nothing ever said 32 vCPU
        # was dead. Every x64 Linux label a pool can point at, release valve included, has probe health.
        import cloud_overflow_switch as switch
        pools = runner_pools.load_pools()
        reachable = {label for spec in pools.values() for label in runner_pools.allowed(spec, pools)
                     if runner_pools.X64_UBUNTU.match(label)}
        self.assertEqual(set(switch.HEALTH_LABELS), reachable)
        self.assertEqual(switch.HEALTH_LABELS[:len(switch.PROBE_LABELS)], switch.PROBE_LABELS)

    def test_the_recorded_snapshot_marks_nothing(self) -> None:
        dead, started, _ = runner_pools.label_evidence(None, RECORDED, now=NOW)
        self.assertEqual((dead, started), (set(), set()))

    def owned_linux_snapshot(self, *, queued, running, oldest, started_ago):
        snapshot = copy.deepcopy(RECORDED)
        snapshot["pools"]["glaeda-linux-arm64"] = {"queued": queued, "running": running, "reserved_queued": 0,
                                                   "oldest_queued_minutes": oldest}
        snapshot["label_started"] = {"glaeda-linux-arm64": runner_pools.iso(SNAPSHOT_AT - started_ago)}
        return snapshot

    def test_a_full_owned_linux_vm_label_is_dead_even_while_it_starts_jobs(self) -> None:
        # One VM clone per mini: a job that waited the cutoff there means every VM is taken. The pool overflows to
        # Blacksmith although the VMs keep starting jobs (a Blacksmith label doing that is load, not death).
        snapshot = self.owned_linux_snapshot(queued=6, running=2, oldest=12, started_ago=dt.timedelta(minutes=1))
        dead, started, _ = runner_pools.label_evidence(None, snapshot, now=NOW)
        self.assertIn("glaeda-linux-arm64", dead)
        self.assertNotIn("glaeda-linux-arm64", started)
        pools = runner_pools.load_pools()
        value, lines = runner_pools.reconcile({}, pools, dead_now=dead, served_now=started, now=NOW,
                                              covered=runner_pools.evidence_covers(None, snapshot, pools, now=NOW))
        self.assertEqual(value["linux_owned_small"], "blacksmith-2vcpu-ubuntu-2404")
        self.assertIn("glaeda-linux-arm64", value[runner_pools.DEAD_KEY])
        # Once its queue no longer waits, its recent start clears the mark and the pool comes back to the fleet.
        later = NOW + dt.timedelta(minutes=10)
        drained = self.owned_linux_snapshot(queued=1, running=2, oldest=2, started_ago=dt.timedelta(minutes=1))
        drained["generated_at"] = runner_pools.iso(later - dt.timedelta(minutes=2))
        drained["label_started"] = {"glaeda-linux-arm64": runner_pools.iso(later - dt.timedelta(minutes=3))}
        dead, started, _ = runner_pools.label_evidence(None, drained, now=later)
        self.assertNotIn("glaeda-linux-arm64", dead)
        self.assertIn("glaeda-linux-arm64", started)
        again, _ = runner_pools.reconcile(value, pools, dead_now=dead, served_now=started, now=later,
                                          covered=runner_pools.evidence_covers(None, drained, pools, now=later))
        self.assertEqual(again["linux_owned_small"], "glaeda-linux-arm64")
        self.assertNotIn("glaeda-linux-arm64", again[runner_pools.DEAD_KEY])

    def test_a_full_owned_gcp_pool_overflows_to_blacksmith_and_comes_back(self) -> None:
        # Leo, 2026-11-21: "i just am like fundamentally opposed to paying for ci when i exist". The x64 pools lead
        # with the persistent GCP pool; Blacksmith takes their jobs only while its oldest queued job has waited
        # the cutoff.
        label = "cmux-fleet-linux-x64"
        snapshot = copy.deepcopy(RECORDED)
        snapshot["pools"][label] = {"queued": 40, "running": 600, "reserved_queued": 0, "oldest_queued_minutes": 12}
        snapshot["label_started"] = {label: runner_pools.iso(SNAPSHOT_AT - dt.timedelta(minutes=1))}
        pools = runner_pools.load_pools()
        fresh, _ = runner_pools.reconcile({}, pools, dead_now=(), served_now=(), now=NOW)
        for name in ("linux", "linux_2", "linux_8", "linux_16", "linux_32"):
            self.assertEqual(fresh[name], label, name)
        for name in ("linux_4", "promotion"):
            self.assertRegex(fresh[name], runner_pools.EPHEMERAL, name)
        dead, started, _ = runner_pools.label_evidence(None, snapshot, now=NOW)
        self.assertIn(label, dead)
        value, _ = runner_pools.reconcile(fresh, pools, dead_now=dead, served_now=started, now=NOW,
                                          covered=runner_pools.evidence_covers(None, snapshot, pools, now=NOW))
        # Leo, 2026-11-19: "stop fucking relying on [Blacksmith]. [...] We could use Freestyle": the 8 vCPU pools
        # take the Freestyle rung next; the 16 and 32 vCPU pools, whose jobs do not fit a Freestyle VM, Blacksmith.
        for name in ("linux", "linux_2", "linux_8"):
            self.assertEqual(value[name], "cmux-freestyle-linux-x64", name)
        self.assertEqual(value["linux_16"], "blacksmith-16vcpu-ubuntu-2404")
        # A full Freestyle rung too: Blacksmith takes the overflow.
        rung = "cmux-freestyle-linux-x64"
        snapshot["pools"][rung] = {"queued": 30, "running": 200, "reserved_queued": 0, "oldest_queued_minutes": 12}
        snapshot["label_started"][rung] = runner_pools.iso(SNAPSHOT_AT - dt.timedelta(minutes=1))
        dead, started, _ = runner_pools.label_evidence(None, snapshot, now=NOW)
        self.assertLessEqual({label, rung}, dead)
        value, _ = runner_pools.reconcile(value, pools, dead_now=dead, served_now=started, now=NOW,
                                          covered=runner_pools.evidence_covers(None, snapshot, pools, now=NOW))
        self.assertEqual(value["linux"], "blacksmith-4vcpu-ubuntu-2404")
        self.assertEqual(value["linux_8"], "blacksmith-8vcpu-ubuntu-2404")
        self.assertEqual(runner_pools.mirror_target({"linux": rung}, pools, "linux"), "blacksmith-4vcpu-ubuntu-2404")
        later = NOW + dt.timedelta(minutes=10)
        drained = copy.deepcopy(RECORDED)
        drained["generated_at"] = runner_pools.iso(later - dt.timedelta(minutes=2))
        drained["pools"][label] = {"queued": 0, "running": 500, "reserved_queued": 0, "oldest_queued_minutes": 0}
        drained["label_started"] = {label: runner_pools.iso(later - dt.timedelta(minutes=3))}
        dead, started, _ = runner_pools.label_evidence(None, drained, now=later)
        again, _ = runner_pools.reconcile(value, pools, dead_now=dead, served_now=started, now=later,
                                          covered=runner_pools.evidence_covers(None, drained, pools, now=later))
        self.assertEqual(again["linux"], label)
        self.assertNotIn(label, again[runner_pools.DEAD_KEY])

    def gcp_stall_snapshot(self, **idle):
        label = "cmux-fleet-linux-x64"
        snapshot = copy.deepcopy(RECORDED)
        # 2026-11-21 23:46Z: 19 queued on the GCP label beside 428 available and 309 busy runners.
        snapshot["pools"][label] = {"queued": 19, "running": 309, "reserved_queued": 0, "oldest_queued_minutes": 12,
                                    **idle}
        snapshot["label_started"] = {label: runner_pools.iso(SNAPSHOT_AT - dt.timedelta(minutes=1))}
        return label, snapshot

    def test_an_owned_label_with_idle_runners_is_not_full_while_jobs_wait(self) -> None:
        # Detector: a few jobs the pool never takes must not move every x64 pool to Blacksmith while hundreds of
        # its runners are idle. Leo, 2026-11-19, on Blacksmith: "stop ... relying on it".
        label, snapshot = self.gcp_stall_snapshot(online=709, busy=309, idle=400)
        dead, started, notes = runner_pools.label_evidence(None, snapshot, now=NOW)
        self.assertNotIn(label, dead)
        self.assertIn(label, started)
        self.assertTrue(any("400 runners idle" in note for note in notes))
        pools = runner_pools.load_pools()
        # A full mark an earlier pass wrote clears now.
        marked = {runner_pools.DEAD_KEY: {label: runner_pools.iso(NOW - dt.timedelta(minutes=5))}}
        value, _ = runner_pools.reconcile(marked, pools, dead_now=dead, served_now=started, now=NOW,
                                          covered=runner_pools.evidence_covers(None, snapshot, pools, now=NOW))
        for name in ("linux", "linux_2", "linux_8", "linux_16"):
            self.assertEqual(value[name], label, name)

    def test_an_owned_label_with_no_idle_runner_spills_once_a_job_waited(self) -> None:
        for idle in (0, runner_pools.OWNED_IDLE_HEADROOM):
            with self.subTest(idle=idle):
                label, snapshot = self.gcp_stall_snapshot(online=309 + idle, busy=309, idle=idle)
                dead, started, _ = runner_pools.label_evidence(None, snapshot, now=NOW)
                self.assertIn(label, dead)
                self.assertNotIn(label, started)
                pools = runner_pools.load_pools()
                value, _ = runner_pools.reconcile({}, pools, dead_now=dead, served_now=started, now=NOW,
                                                  covered=runner_pools.evidence_covers(None, snapshot, pools, now=NOW))
                # A full GCP pool overflows to the Freestyle rung first (OWNED_FREESTYLE_LINUX); a pool too big for
                # its 8 vCPU VMs goes straight to Blacksmith. Leo, 2026-11-19: "stop ... relying on it".
                self.assertEqual(value["linux"], "cmux-freestyle-linux-x64")
                self.assertEqual(value["linux_16"], "blacksmith-16vcpu-ubuntu-2404")

    def test_idle_runners_do_not_count_before_the_stall_cutoff_and_a_bad_reading_keeps_the_queue_rule(self) -> None:
        label, quiet = self.gcp_stall_snapshot(idle=0)
        quiet["pools"][label]["oldest_queued_minutes"] = 2
        self.assertNotIn(label, runner_pools.label_evidence(None, quiet, now=NOW)[0])
        for reading in ({}, {"idle": None}, {"idle": "400"}, {"idle": True}, {"idle": -1}):
            with self.subTest(reading=reading):
                label, snapshot = self.gcp_stall_snapshot(**reading)
                self.assertIn(label, runner_pools.label_evidence(None, snapshot, now=NOW)[0])

    def test_an_old_snapshot_does_not_make_the_gcp_pool_full(self) -> None:
        # 2026-11-22 09:37Z: the 09:02Z snapshot (35 min old) read cmux-fleet-linux-x64 1 queued, oldest 0 min, 884
        # running, a start at 09:03Z. 0 + 35 min of snapshot age crossed the cutoff, and every x64 pool went to
        # Blacksmith. Only the wait the snapshot measured makes our pool full.
        label = "cmux-fleet-linux-x64"
        snapshot = copy.deepcopy(RECORDED)
        snapshot["pools"][label] = {"queued": 1, "running": 884, "reserved_queued": 0, "oldest_queued_minutes": 0}
        snapshot["label_started"] = {label: runner_pools.iso(SNAPSHOT_AT + dt.timedelta(minutes=1))}
        later = SNAPSHOT_AT + dt.timedelta(minutes=35)
        dead, started, _ = runner_pools.label_evidence(None, snapshot, now=later)
        self.assertNotIn(label, dead)
        pools = runner_pools.load_pools()
        fresh, _ = runner_pools.reconcile({}, pools, dead_now=(), served_now=(), now=later)
        value, _ = runner_pools.reconcile(fresh, pools, dead_now=dead, served_now=started, now=later,
                                          covered=runner_pools.evidence_covers(None, snapshot, pools, now=later))
        for name in ("linux", "linux_2", "linux_8", "linux_16", "linux_32"):
            self.assertEqual(value[name], label, name)
        # A wait the snapshot did measure still overflows, however fresh the snapshot is.
        snapshot["pools"][label]["oldest_queued_minutes"] = 11
        dead, _, _ = runner_pools.label_evidence(None, snapshot, now=SNAPSHOT_AT)
        self.assertIn(label, dead)

    def test_linux_runner_stays_on_blacksmith_while_the_gcp_pool_is_live(self) -> None:
        # About 250 workflows read vars.LINUX_RUNNER with no fresh-machine check (release jobs among them), so
        # the mirror never names the persistent pool; feat-cmux-next readers fall through to the pool instead.
        pools = runner_pools.load_pools()
        value, _ = runner_pools.reconcile({}, pools, dead_now=(), served_now=(), now=NOW)
        self.assertEqual(value["linux"], "cmux-fleet-linux-x64")
        self.assertEqual(runner_pools.mirror_target(value, pools, "linux"), "blacksmith-4vcpu-ubuntu-2404")
        marked = dict(value, **{runner_pools.DEAD_KEY: {"blacksmith-4vcpu-ubuntu-2404": runner_pools.iso(NOW)}})
        self.assertEqual(runner_pools.mirror_target(marked, pools, "linux"), "blacksmith-16vcpu-ubuntu-2404")
        self.assertEqual(runner_pools.mirror_writes(value, {"LINUX_RUNNER": "blacksmith-4vcpu-ubuntu-2404"},
                                                    record=None, pools=pools), [])

    def test_the_gcp_label_leads_only_a_pool_that_needs_no_fresh_machine(self) -> None:
        good = {"a": {"why": "x", "members": ["cmux-fleet-linux-x64", "blacksmith-4vcpu-ubuntu-2404"]}}
        self.assertEqual(runner_pools.spec_problems(good), [])
        for bad in ({"why": "x", "members": ["cmux-fleet-linux-x64"]},
                    {"why": "x", "members": ["blacksmith-4vcpu-ubuntu-2404", "cmux-fleet-linux-x64"]},
                    {"why": "x", "members": ["cmux-fleet-linux-x64", "blacksmith-4vcpu-ubuntu-2404"],
                     "ephemeral_only": True},
                    {"why": "x", "members": ["blacksmith-4vcpu-ubuntu-2404"], "ephemeral_only": "yes"}):
            with self.subTest(spec=bad):
                self.assertTrue(runner_pools.spec_problems({"a": bad}))

    def test_the_freestyle_label_follows_the_gcp_lead_in_a_pool_that_needs_no_fresh_machine(self) -> None:
        for good in (["cmux-fleet-linux-x64", "cmux-freestyle-linux-x64", "blacksmith-4vcpu-ubuntu-2404"],
                     ["cmux-freestyle-linux-x64", "blacksmith-4vcpu-ubuntu-2404"]):
            with self.subTest(members=good):
                self.assertEqual(runner_pools.spec_problems({"a": {"why": "x", "members": good}}), [])
        for bad in ({"why": "x", "members": ["cmux-fleet-linux-x64", "cmux-freestyle-linux-x64"]},
                    {"why": "x", "members": ["blacksmith-4vcpu-ubuntu-2404", "cmux-freestyle-linux-x64",
                                             "blacksmith-16vcpu-ubuntu-2404"]},
                    {"why": "x", "members": ["cmux-freestyle-linux-x64", "cmux-fleet-linux-x64",
                                             "blacksmith-4vcpu-ubuntu-2404"]},
                    {"why": "x", "members": ["cmux-freestyle-linux-x64", "blacksmith-4vcpu-ubuntu-2404"],
                     "ephemeral_only": True}):
            with self.subTest(spec=bad):
                self.assertTrue(runner_pools.spec_problems({"a": bad}))

    def test_an_owned_linux_vm_label_with_no_vm_online_is_dead(self) -> None:
        snapshot = self.owned_linux_snapshot(queued=3, running=0, oldest=15, started_ago=dt.timedelta(hours=3))
        dead, _, _ = runner_pools.label_evidence(None, snapshot, now=NOW)
        self.assertIn("glaeda-linux-arm64", dead)

    def test_an_owned_linux_vm_label_keeping_up_is_serving(self) -> None:
        snapshot = self.owned_linux_snapshot(queued=2, running=2, oldest=4, started_ago=dt.timedelta(minutes=2))
        dead, started, _ = runner_pools.label_evidence(None, snapshot, now=NOW)
        self.assertNotIn("glaeda-linux-arm64", dead)
        self.assertIn("glaeda-linux-arm64", started)

    def test_a_stalled_blacksmith_mac_in_the_snapshot_is_dead(self) -> None:
        # simple_pool_picker.blacksmith_stalled(): a queued job waited 10 minutes, nothing runs there, and the
        # janitor's label_started shows no start since that job began to wait.
        snapshot = copy.deepcopy(RECORDED)
        snapshot["pools"]["blacksmith-6vcpu-macos-26"].update(queued=3, running=0, oldest_queued_minutes=9)
        snapshot["label_started"] = {"blacksmith-6vcpu-macos-26": runner_pools.iso(SNAPSHOT_AT - dt.timedelta(minutes=40))}
        dead, _, _ = runner_pools.label_evidence(None, snapshot, now=NOW)
        self.assertEqual(dead, {"blacksmith-6vcpu-macos-26"})
        # Owned labels in the snapshot are never pool members and are not read.
        snapshot["pools"]["glaeda-std-xcode-26.6"].update(queued=9, oldest_queued_minutes=60)
        snapshot["starved"] = [{"label": "glaeda-gui-std-xcode-26.6+glaeda-std-xcode-26.6", "queued": 1}]
        dead, _, _ = runner_pools.label_evidence(None, snapshot, now=NOW)
        self.assertEqual(dead, {"blacksmith-6vcpu-macos-26"})

    def test_a_busy_blacksmith_mac_that_starts_jobs_is_not_dead(self) -> None:
        # 2026-11-08: blacksmith-6vcpu-macos-15 started four jobs of run 42503576472 at 17:28-17:31Z, one
        # still running, yet RUNNER_POOLS marked it dead at 17:34:13Z: other jobs had queued there over 10
        # minutes. A long queue on a label that starts jobs is load, not death; only a label that runs
        # nothing and started nothing while its oldest job waited is dead.
        stalled = copy.deepcopy(RECORDED)
        stalled["pools"]["blacksmith-6vcpu-macos-26"].update(queued=6, running=0, oldest_queued_minutes=25)
        stalled["label_started"] = {}
        # A start it shows is evidence it serves: that clears a mark the old rule wrote, at once.
        # No label_started map is no evidence either way.
        label = {"blacksmith-6vcpu-macos-26"}
        for name, change, served in [
            ("a job runs there", {"running": 1}, label),
            ("a job started after the oldest began to wait",
             {"label_started": runner_pools.iso(SNAPSHOT_AT - dt.timedelta(minutes=3))}, label),
            ("no start evidence in the snapshot", {"no_label_started": True}, set()),
        ]:
            with self.subTest(name):
                snapshot = copy.deepcopy(stalled)
                if "running" in change:
                    snapshot["pools"]["blacksmith-6vcpu-macos-26"]["running"] = change["running"]
                if "label_started" in change:
                    snapshot["label_started"] = {"blacksmith-6vcpu-macos-26": change["label_started"]}
                if change.get("no_label_started"):
                    del snapshot["label_started"]
                dead, started, _ = runner_pools.label_evidence(None, snapshot, now=NOW)
                self.assertEqual(dead, set())
                self.assertEqual(started, served)
        # The control: nothing runs, and the last start is older than the oldest wait.
        dead, _, _ = runner_pools.label_evidence(None, stalled, now=NOW)
        self.assertEqual(dead, {"blacksmith-6vcpu-macos-26"})

    def test_dead_label_entries_split_on_comma_and_plus(self) -> None:
        # cmux#27114's DeadLabel.as_json(): label sets joined with ",", live members listed.
        snapshot = dict(RECORDED, dead_labels=[{
            "label": "blacksmith-16vcpu-ubuntu-2404", "family": "linux", "queued": 4,
            "oldest_queued_minutes": 6, "live": ["blacksmith-32vcpu-ubuntu-2404"]}])
        dead, started, _ = runner_pools.label_evidence(None, snapshot, now=NOW)
        self.assertEqual(dead, {"blacksmith-16vcpu-ubuntu-2404"})
        self.assertEqual(started, {"blacksmith-32vcpu-ubuntu-2404"})
        self.assertEqual(runner_pools._labels("a,b+c"), {"a", "b", "c"})

    def test_probe_health_per_label(self) -> None:
        fresh = dict(copy.deepcopy(RECORDED), label_started={})
        dead, started, _ = runner_pools.label_evidence(health({
            "blacksmith-32vcpu-ubuntu-2404": "stalled", "blacksmith-16vcpu-ubuntu-2404": "started"}), fresh, now=NOW)
        self.assertEqual(dead, {"blacksmith-32vcpu-ubuntu-2404"})
        self.assertEqual(started, {"blacksmith-16vcpu-ubuntu-2404"})

    def test_a_probe_stall_without_a_fresh_snapshot_marks_nothing_dead(self) -> None:
        # Run 44296348389, 11:37Z on 2026-11-18: the cmux-bot App's budget was spent, the snapshot read
        # returned 403 ("judging on the probe alone"), and the 4, 8, 16 and 32 vCPU probes, queued behind the
        # org's vCPU cap while 2,618 jobs waited, read "stalled"; all four were marked dead and every Linux pool
        # was squeezed onto 2 vCPU. A stall cannot tell a dead size from a full cap without the janitor's starts.
        probe = health({"blacksmith-4vcpu-ubuntu-2404": "stalled", "blacksmith-8vcpu-ubuntu-2404": "stalled",
                        "blacksmith-2vcpu-ubuntu-2404": "started"})
        stale = dict(copy.deepcopy(RECORDED), label_started={},
                     generated_at=runner_pools.iso(NOW - runner_pools.SNAPSHOT_MAX_AGE - dt.timedelta(minutes=1)))
        for snapshot in (None, stale, dict(copy.deepcopy(RECORDED), truncated=True)):
            with self.subTest(snapshot=bool(snapshot)):
                dead, started, notes = runner_pools.label_evidence(probe, snapshot, now=NOW)
                self.assertEqual(dead, set())
                self.assertEqual(started, {"blacksmith-2vcpu-ubuntu-2404"})
                self.assertTrue(any("no fresh janitor snapshot" in note for note in notes), notes)
        # The marks already there keep their state: no fresh evidence, so none expires or is renewed, and a
        # probe start still clears its label.
        pools = runner_pools.load_pools()
        since = runner_pools.iso(NOW - dt.timedelta(minutes=5))
        current = {"_dead": {"blacksmith-4vcpu-ubuntu-2404": since, "blacksmith-2vcpu-ubuntu-2404": since}}
        dead, started, _ = runner_pools.label_evidence(probe, None, now=NOW)
        value, _ = runner_pools.reconcile(current, pools, dead_now=dead, served_now=started, now=NOW,
                                          covered=runner_pools.evidence_covers(probe, None, pools, now=NOW))
        self.assertEqual(value["_dead"], {"blacksmith-4vcpu-ubuntu-2404": since})

    def test_no_evidence_retires_nothing(self) -> None:
        # Fail closed: with CI_CLOUD_LABEL_HEALTH absent (cmux#27121 not deployed) and no snapshot,
        # nothing is marked dead, and the pools stay on their first members.
        dead, started, _ = runner_pools.label_evidence(None, None, now=NOW)
        self.assertEqual((dead, started), (set(), set()))
        switch = Main.Switch()
        self.assertEqual(runner_pools.main([], {"RUNNER_POOLS": ""}, api=Main.Api(None), switch=switch, now=NOW), 0)
        value = json.loads(switch.writes[0][1])
        self.assertEqual(value["_dead"], {})
        for name, spec in runner_pools.load_pools().items():
            self.assertEqual(value[name], spec["members"][0])

    def test_an_undated_stale_or_future_snapshot_decides_nothing(self) -> None:
        stalled = copy.deepcopy(RECORDED)
        stalled["pools"]["blacksmith-6vcpu-macos-26"].update(queued=3, running=0, oldest_queued_minutes=30)
        stalled["label_started"] = {}
        stalled["dead_labels"] = [{"label": "blacksmith-16vcpu-ubuntu-2404", "live": []}]
        dead, _, _ = runner_pools.label_evidence(None, stalled, now=NOW)
        self.assertEqual(dead, {"blacksmith-6vcpu-macos-26", "blacksmith-16vcpu-ubuntu-2404"})
        for generated in (None, "yesterday", "2026-10-28T22:53:37",
                          runner_pools.iso(NOW - runner_pools.SNAPSHOT_MAX_AGE - dt.timedelta(minutes=1)),
                          runner_pools.iso(NOW + dt.timedelta(hours=1))):
            with self.subTest(generated=generated):
                snapshot = dict(stalled, generated_at=generated)
                dead, started, notes = runner_pools.label_evidence(None, snapshot, now=NOW)
                self.assertEqual((dead, started), (set(), set()))
                self.assertTrue(notes)

    def test_old_or_unreadable_health_decides_nothing(self) -> None:
        old = health({"blacksmith-32vcpu-ubuntu-2404": "stalled"}, checked=NOW - dt.timedelta(hours=1))
        future = health({"blacksmith-32vcpu-ubuntu-2404": "stalled"}, checked=NOW + dt.timedelta(hours=1))
        for value in (old, future, {"labels": []}, {"checked": "2026-10-28T22:00:00", "labels": {}}):
            dead, started, notes = runner_pools.label_evidence(value, None, now=NOW)
            self.assertEqual((dead, started), (set(), set()))
            self.assertTrue(notes)


class Reconcile(unittest.TestCase):
    def run_once(self, current, dead=(), served=(), now=NOW):
        return runner_pools.reconcile(current, POOLS, dead_now=dead, served_now=served, now=now)

    def test_first_pass_points_every_pool_at_its_first_member(self) -> None:
        value, _ = self.run_once({})
        self.assertEqual(value["linux"], "blacksmith-32vcpu-ubuntu-2404")
        self.assertEqual(value["macos_26"], "blacksmith-6vcpu-macos-26")
        self.assertEqual(value["macos_26_large"], "blacksmith-12vcpu-macos-26")
        self.assertEqual(value["_dead"], {})

    def test_a_dead_member_flips_its_pools_to_the_next(self) -> None:
        value, lines = self.run_once({}, dead={"blacksmith-6vcpu-macos-26"})
        self.assertEqual(value["macos_26"], "blacksmith-12vcpu-macos-26")
        self.assertEqual(value["macos_26_large"], "blacksmith-12vcpu-macos-26")
        self.assertIn("pools.macos_26: unset -> blacksmith-12vcpu-macos-26", lines)

    def test_a_mark_holds_until_it_expires_or_the_label_starts_a_job(self) -> None:
        first, _ = self.run_once({}, dead={"blacksmith-32vcpu-ubuntu-2404"})
        self.assertEqual(first["linux"], "blacksmith-16vcpu-ubuntu-2404")
        held, _ = self.run_once(first, now=NOW + dt.timedelta(minutes=20))
        self.assertEqual(held["linux"], "blacksmith-16vcpu-ubuntu-2404")
        expired, _ = self.run_once(first, now=NOW + runner_pools.DEAD_TTL)
        self.assertEqual(expired["linux"], "blacksmith-32vcpu-ubuntu-2404")
        probed, _ = self.run_once(first, served={"blacksmith-32vcpu-ubuntu-2404"}, now=NOW + dt.timedelta(minutes=5))
        self.assertEqual(probed["linux"], "blacksmith-32vcpu-ubuntu-2404")

    def test_every_member_dead_keeps_the_first(self) -> None:
        # No smaller x64 size is declared in POOLS, so the release valve has nowhere to go.
        value, _ = self.run_once({}, dead={"blacksmith-32vcpu-ubuntu-2404", "blacksmith-16vcpu-ubuntu-2404"})
        self.assertEqual(value["linux"], "blacksmith-32vcpu-ubuntu-2404")

    def test_every_member_dead_releases_to_the_next_smaller_live_size(self) -> None:
        # 2026-11-18 01:18Z: 16 vCPU marked dead, 32 vCPU starting nothing since about 23:12Z, and
        # linux_16 / linux_32 left on 32 vCPU. 8 vCPU kept starting jobs (01:10Z, run 44211950380).
        pools = {
            "linux_8": {"why": "x", "members": ["blacksmith-8vcpu-ubuntu-2404", "blacksmith-16vcpu-ubuntu-2404"]},
            "linux_16": {"why": "x", "members": ["blacksmith-16vcpu-ubuntu-2404", "blacksmith-32vcpu-ubuntu-2404"]},
            "linux_32": {"why": "x", "members": ["blacksmith-32vcpu-ubuntu-2404", "blacksmith-16vcpu-ubuntu-2404"]},
            "linux_4": {"why": "x", "members": ["blacksmith-4vcpu-ubuntu-2404", "blacksmith-16vcpu-ubuntu-2404"]},
            "macos_26": {"why": "x", "members": ["blacksmith-6vcpu-macos-26", "blacksmith-12vcpu-macos-26"]},
        }
        both = {"blacksmith-16vcpu-ubuntu-2404", "blacksmith-32vcpu-ubuntu-2404"}
        value, lines = runner_pools.reconcile({}, pools, dead_now=both, served_now=(), now=NOW)
        self.assertEqual(value["linux_16"], "blacksmith-8vcpu-ubuntu-2404")
        self.assertEqual(value["linux_32"], "blacksmith-8vcpu-ubuntu-2404")
        self.assertEqual(value["linux_8"], "blacksmith-8vcpu-ubuntu-2404")
        self.assertTrue(any("release valve" in line and "linux_16" in line for line in lines), lines)
        # The value round-trips and passes --check: the valve label is allowed, not reset.
        current, dropped = runner_pools.parse_value(runner_pools.render(value), pools)
        self.assertEqual(dropped, [])
        self.assertEqual(current["linux_16"], "blacksmith-8vcpu-ubuntu-2404")
        self.assertEqual(runner_pools.value_problems(value, pools), [])
        # 8 vCPU dead too: the next smaller declared size that is not.
        value, _ = runner_pools.reconcile({}, pools, dead_now={*both, "blacksmith-8vcpu-ubuntu-2404"},
                                          served_now=(), now=NOW)
        self.assertEqual(value["linux_16"], "blacksmith-4vcpu-ubuntu-2404")
        # Nothing smaller alive: the first member, as before.
        value, _ = runner_pools.reconcile({}, pools, dead_now={*both, "blacksmith-8vcpu-ubuntu-2404",
                                                               "blacksmith-4vcpu-ubuntu-2404"},
                                          served_now=(), now=NOW)
        self.assertEqual(value["linux_16"], "blacksmith-16vcpu-ubuntu-2404")
        # A member starting again takes the pool back from the valve.
        released, _ = runner_pools.reconcile({}, pools, dead_now=both, served_now=(), now=NOW)
        back, _ = runner_pools.reconcile(released, pools, dead_now=(), served_now={"blacksmith-32vcpu-ubuntu-2404"},
                                         now=NOW + dt.timedelta(minutes=10))
        self.assertEqual(back["linux_32"], "blacksmith-32vcpu-ubuntu-2404")
        self.assertEqual(back["linux_16"], "blacksmith-32vcpu-ubuntu-2404")
        # macOS pools and any other label stay out of the valve.
        self.assertEqual(runner_pools.allowed(pools["macos_26"], pools), runner_pools.members(pools["macos_26"]))
        self.assertTrue(runner_pools.value_problems({**value, "linux_16": "blacksmith-2vcpu-ubuntu-2404"}, pools))

    def test_the_release_valve_never_goes_below_min_vcpu(self) -> None:
        # 2026-11-18 11:47Z-13:18Z: with 16, 8 and 32 vCPU marked dead the valve put linux_16 on 4 and then 2 vCPU,
        # and every fat-LTO cmux-tui tree build there was SIGKILLed out of memory (run 44289517882, acpmux rustc on
        # blacksmith-4vcpu-ubuntu-2404, then 12 runs on 2 vCPU), so no tree published and the NEXT nightlies failed.
        pools = {
            "linux_2": {"why": "x", "members": ["blacksmith-2vcpu-ubuntu-2404", "blacksmith-4vcpu-ubuntu-2404"]},
            "linux_4": {"why": "x", "members": ["blacksmith-4vcpu-ubuntu-2404", "blacksmith-16vcpu-ubuntu-2404"]},
            "linux_8": {"why": "x", "members": ["blacksmith-8vcpu-ubuntu-2404", "blacksmith-4vcpu-ubuntu-2404"]},
            "linux_16": {"why": "x", "min_vcpu": 8,
                         "members": ["blacksmith-16vcpu-ubuntu-2404", "blacksmith-8vcpu-ubuntu-2404",
                                     "blacksmith-32vcpu-ubuntu-2404"]},
        }
        self.assertEqual(runner_pools.spec_problems(pools), [])
        self.assertEqual(runner_pools.valve_labels(pools["linux_16"], pools), [])
        dead = {"blacksmith-16vcpu-ubuntu-2404", "blacksmith-8vcpu-ubuntu-2404", "blacksmith-32vcpu-ubuntu-2404",
                "blacksmith-4vcpu-ubuntu-2404"}
        value, _ = runner_pools.reconcile({}, pools, dead_now=dead, served_now=(), now=NOW)
        # It waits on its own first member rather than taking a size its jobs are killed on.
        self.assertEqual(value["linux_16"], "blacksmith-16vcpu-ubuntu-2404")
        self.assertEqual(value["linux_8"], "blacksmith-2vcpu-ubuntu-2404")  # no floor: the valve as before
        # A value below the floor is not allowed, so a hand edit is reset too.
        self.assertTrue(runner_pools.value_problems({**value, "linux_16": "blacksmith-4vcpu-ubuntu-2404"}, pools))

    def test_a_large_pool_declares_its_memory_floor(self) -> None:
        pools = {"linux_16": {"why": "x", "members": ["blacksmith-16vcpu-ubuntu-2404", "blacksmith-8vcpu-ubuntu-2404"]}}
        self.assertTrue(any("min_vcpu" in problem for problem in runner_pools.spec_problems(pools)))
        below = {"linux_16": {"why": "x", "min_vcpu": 16,
                              "members": ["blacksmith-16vcpu-ubuntu-2404", "blacksmith-8vcpu-ubuntu-2404"]}}
        self.assertTrue(any("below its min_vcpu" in problem for problem in runner_pools.spec_problems(below)))
        bad = {"linux_16": {"why": "x", "min_vcpu": "8", "members": ["blacksmith-16vcpu-ubuntu-2404"]}}
        self.assertTrue(any("positive whole number" in problem for problem in runner_pools.spec_problems(bad)))
        # The declared fat-LTO pools keep 8 vCPU (32 GB) as their floor.
        declared = runner_pools.load_pools()
        for name in ("linux_16", "linux_32"):
            with self.subTest(pool=name):
                self.assertEqual(runner_pools.memory_floor(declared[name]), 8)

    def test_no_change_keeps_the_value_byte_for_byte(self) -> None:
        value, _ = self.run_once({})
        again, lines = self.run_once(value, now=NOW + dt.timedelta(minutes=10))
        self.assertEqual(runner_pools.render(again), runner_pools.render(value))
        self.assertEqual(lines, [])


class NeverHosted(unittest.TestCase):
    def test_a_non_hosted_pool_never_resolves_to_a_hosted_label(self) -> None:
        # Hosted runners are not in the declared set: whatever is dead, a pool not marked hosted
        # picks one of its own Blacksmith members, never ubuntu-* or macos-*.
        pools = runner_pools.load_pools()
        every = {label for spec in pools.values() for label in runner_pools.members(spec)}
        value, _ = runner_pools.reconcile({}, pools, dead_now=every, served_now=(), now=NOW)
        for name, spec in pools.items():
            if not spec.get("hosted"):
                self.assertTrue(runner_pools.EPHEMERAL.match(value[name]) or runner_pools.owned_lead(value[name]),
                                value[name])
                self.assertNotRegex(value[name], runner_pools.HOSTED)
        current, dropped = runner_pools.parse_value(json.dumps({"linux": "ubuntu-24.04"}), pools)
        self.assertNotIn("linux", current)
        self.assertTrue(dropped)

    def test_the_overflow_switch_never_writes_a_hosted_label(self) -> None:
        # The switch that moves the old variables (LINUX_RUNNER, CI_TRUSTED_RUNNER) never points one
        # at GitHub-hosted Ubuntu or macOS, with or without an override asking it to.
        import cloud_overflow_switch as switch
        for overrides in (None, json.dumps({"LINUX_RUNNER": "ubuntu-24.04"}),
                          json.dumps({"MACOS_RUNNER_15": "macos-15"})):
            values, _ = switch.failover_values("/Applications/Xcode_26.6.app", overrides)
            for name, value in values.items():
                with self.subTest(overrides=overrides, variable=name):
                    self.assertNotRegex(str(value), r"^(?:ubuntu|macos|windows)-")


class HostedOverride(unittest.TestCase):
    # Leo, 2026-11-17, asked "Allow GitHub-hosted ubuntu-24.04 for cmux Linux CI until Blacksmith recovers?":
    # "Allow until it recovers". A hand-set RUNNER_POOLS was reset by the next pass (parse_value() drops a label
    # outside a pool), so the override is a variable the writer itself reads.
    ON = {"CI_LINUX_HOSTED_RUNNER": "ubuntu-24.04"}
    X64 = ("linux", "linux_2", "linux_4", "linux_8", "linux_16", "linux_32", "promotion")

    def test_unset_or_not_a_hosted_ubuntu_label_changes_nothing(self) -> None:
        declared = runner_pools.load_pools(env={})
        for raw in ("", "  ", "blacksmith-4vcpu-ubuntu-2404", "macos-15", "glaeda-side-std-xcode-26.6", "ubuntu"):
            with self.subTest(raw=raw):
                self.assertEqual(runner_pools.load_pools(env={"CI_LINUX_HOSTED_RUNNER": raw}), declared)

    def test_the_x64_linux_pools_lead_with_it_and_nothing_else_moves(self) -> None:
        declared = runner_pools.load_pools(env={})
        pools = runner_pools.load_pools(env=self.ON)
        self.assertEqual(runner_pools.spec_problems(pools), [])
        for name in self.X64:
            listed = declared[name]["members"]
            # The owned GCP lead and Freestyle rung stay first: the override replaces only the Blacksmith overflow.
            lead = runner_pools.owned_prefix(listed)
            self.assertEqual(pools[name]["members"], [*lead, "ubuntu-24.04", *listed[len(lead):]])
        for name in set(declared) - set(self.X64):
            self.assertEqual(pools[name], declared[name], name)
        self.assertEqual(pools["linux_arm64"]["members"], ["blacksmith-4vcpu-ubuntu-2404-arm"])

    def test_a_pass_writes_it_and_the_next_pass_keeps_it(self) -> None:
        before = runner_pools.reconcile({}, runner_pools.load_pools(env={}), dead_now=(), served_now=(), now=NOW)[0]
        switch = Main.Switch({"LINUX_RUNNER": "ubuntu-24.04"})
        env = {"RUNNER_POOLS": runner_pools.render(before), **self.ON}
        self.assertEqual(runner_pools.main([], env, api=Main.Api(None), switch=switch, now=NOW), 0)
        [(name, raw)] = switch.writes
        written = json.loads(raw)
        declared = runner_pools.load_pools(env={})
        self.assertEqual({k: written[k] for k in self.X64},
                         {k: "cmux-fleet-linux-x64" if runner_pools.owned_gcp(declared[k]["members"][0])
                          else "ubuntu-24.04" for k in self.X64})
        self.assertEqual({k: v for k, v in written.items() if k not in self.X64 and not k.startswith("_")},
                         {k: v for k, v in before.items() if k not in self.X64 and not k.startswith("_")})
        again = Main.Switch({"LINUX_RUNNER": "ubuntu-24.04"})
        env = {"RUNNER_POOLS": raw, **self.ON}
        self.assertEqual(runner_pools.main([], env, api=Main.Api(None), switch=again, now=NOW), 0)
        self.assertEqual(again.writes, [])
        self.assertEqual(runner_pools.main(["--check"], dict(env, LINUX_RUNNER="ubuntu-24.04")), 0)
        # Deleting the variable is the revert: the next pass puts every pool back on Blacksmith.
        back = Main.Switch({"LINUX_RUNNER": "ubuntu-24.04"})
        self.assertEqual(runner_pools.main([], {"RUNNER_POOLS": raw}, api=Main.Api(None), switch=back, now=NOW), 0)
        [(name, raw), mirrored] = back.writes
        self.assertEqual({k: json.loads(raw)[k] for k in self.X64}, {k: before[k] for k in self.X64})
        # router-review F1: LINUX_RUNNER follows the pool back too, so --check passes after the revert.
        # While the owned GCP pool is the live member, LINUX_RUNNER (read with no fresh-machine check) stays on
        # the pool's first live Blacksmith member (mirror_target()).
        self.assertEqual(mirrored, ("LINUX_RUNNER", runner_pools.mirror_target(before, runner_pools.load_pools(env={}),
                                                                              "linux")))
        self.assertEqual(mirrored[1], "blacksmith-4vcpu-ubuntu-2404")
        self.assertEqual(runner_pools.main(["--check"], {"RUNNER_POOLS": raw, "LINUX_RUNNER": mirrored[1]}), 0)

    def test_the_mirror_leaves_the_hosted_label_alone_while_the_override_is_set(self) -> None:
        value = {"linux": "ubuntu-24.04"}
        self.assertEqual(runner_pools.mirror_writes(value, {"LINUX_RUNNER": "ubuntu-24.04"}, record=None), [])
        self.assertEqual(runner_pools.mirror_writes(value, {"LINUX_RUNNER": "blacksmith-4vcpu-ubuntu-2404"},
                                                    record=None), [("LINUX_RUNNER", "ubuntu-24.04")])

    def test_the_watch_and_the_check_pass_the_variable(self) -> None:
        for path, find in ((".github/workflows/ci-cloud-overflow-probe.yml", "runner_pools.py"),
                           (".github/workflows/ci-repo-variables.yml", "runner_pools.py --check")):
            workflow = yaml.safe_load((ROOT / path).read_text())
            steps = [s for job in workflow["jobs"].values() for s in job.get("steps", [])
                     if find in str(s.get("run", ""))]
            self.assertTrue(steps, path)
            for step in steps:
                self.assertEqual(step["env"]["CI_LINUX_HOSTED_RUNNER"], "${{ vars.CI_LINUX_HOSTED_RUNNER }}", path)


class Schema(unittest.TestCase):
    def test_malformed_values_are_repaired_not_crashed_on(self) -> None:
        good, _ = runner_pools.reconcile({}, POOLS, dead_now=(), served_now=(), now=NOW)
        for raw in ('{"_dead":[]}', '{"_dead":{"blacksmith-32vcpu-ubuntu-2404":"2026-10-28T22:00:00"}}',
                    '{"_dead":{"blacksmith-32vcpu-ubuntu-2404":7}}', '{"linux":"ubuntu-24.04"}', '{"linux":3}',
                    '[]', '"x"', 'not json'):
            with self.subTest(raw=raw):
                current, dropped = runner_pools.parse_value(raw, POOLS)
                self.assertTrue(dropped)
                value, _ = runner_pools.reconcile(current, POOLS, dead_now=(), served_now=(), now=NOW)
                self.assertEqual({k: value[k] for k in POOLS}, {k: good[k] for k in POOLS})
                self.assertEqual(value["_dead"], {})

    def test_a_valid_value_round_trips(self) -> None:
        value, _ = runner_pools.reconcile({}, POOLS, dead_now={"blacksmith-6vcpu-macos-26"}, served_now=(), now=NOW)
        current, dropped = runner_pools.parse_value(runner_pools.render(value), POOLS)
        self.assertEqual(dropped, [])
        self.assertEqual(runner_pools.render(current), runner_pools.render(value))

    def test_value_problems(self) -> None:
        value, _ = runner_pools.reconcile({}, POOLS, dead_now=(), served_now=(), now=NOW)
        self.assertEqual(runner_pools.value_problems(value, POOLS), [])
        self.assertTrue(runner_pools.value_problems({**value, "linux": "ubuntu-24.04"}, POOLS))
        missing = dict(value)
        del missing["macos_26"]
        self.assertTrue(runner_pools.value_problems(missing, POOLS))


class Main(BlacksmithFailover, unittest.TestCase):
    class Api:
        def __init__(self, snapshot):
            self._snapshot = snapshot

        def snapshot(self, *, now):
            return self._snapshot

    class Switch:
        def __init__(self, variables=None):
            self.writes = []
            self.variables = dict(variables or {})

        def get_variable(self, name):
            return self.variables.get(name)

        def set_variable(self, name, value):
            self.writes.append((name, value))
            self.variables[name] = value

    def test_the_2026_11_18_pass_moves_linux_16_and_linux_32_off_the_dead_sizes(self) -> None:
        # The live RUNNER_POOLS at 01:18:46Z and a probe pass over every x64 size, with the declared pools.
        live = json.dumps({"_dead": {"blacksmith-16vcpu-ubuntu-2404": "2026-11-18T01:18:46Z",
                                     "blacksmith-4vcpu-ubuntu-2404": "2026-11-18T01:18:46Z"},
                           "_updated": "2026-11-18T01:18:46Z",
                           "linux": "blacksmith-4vcpu-ubuntu-2404", "linux_16": "blacksmith-32vcpu-ubuntu-2404",
                           "linux_2": "blacksmith-2vcpu-ubuntu-2404", "linux_32": "blacksmith-32vcpu-ubuntu-2404",
                           "linux_4": "blacksmith-4vcpu-ubuntu-2404", "linux_8": "blacksmith-8vcpu-ubuntu-2404"})
        now = dt.datetime(2026, 11, 18, 1, 28, 46, tzinfo=dt.timezone.utc)
        switch = self.Switch({runner_pools.HEALTH_VARIABLE: json.dumps(health({
            "blacksmith-4vcpu-ubuntu-2404": "stalled", "blacksmith-16vcpu-ubuntu-2404": "stalled",
            "blacksmith-2vcpu-ubuntu-2404": "started", "blacksmith-8vcpu-ubuntu-2404": "started",
            "blacksmith-32vcpu-ubuntu-2404": "stalled"}, checked=now))})
        self.assertEqual(runner_pools.main([], {"RUNNER_POOLS": live}, api=self.Api(fresh_snapshot(now)), switch=switch,
                                           now=now), 0)
        value = json.loads(switch.writes[0][1])
        self.assertEqual(value["linux_16"], "blacksmith-8vcpu-ubuntu-2404")
        self.assertEqual(value["linux_32"], "blacksmith-8vcpu-ubuntu-2404")
        self.assertIn("blacksmith-32vcpu-ubuntu-2404", value["_dead"])
        # linux is [4, 16] vCPU, both stalled: its valve is 2 vCPU, and the LINUX_RUNNER mirror check accepts it.
        self.assertEqual(value["linux"], "blacksmith-2vcpu-ubuntu-2404")
        # The next pass keeps it (the writer used to reset any label outside the members). It rewrites the
        # variable only to refresh the dead marks' times.
        again = self.Switch(switch.variables)
        self.assertEqual(runner_pools.main([], {"RUNNER_POOLS": switch.writes[0][1]},
                                           api=self.Api(fresh_snapshot(now + dt.timedelta(minutes=1))),
                                           switch=again, now=now + dt.timedelta(minutes=1)), 0)
        kept = json.loads(dict(again.writes).get("RUNNER_POOLS", switch.writes[0][1]))
        self.assertEqual((kept["linux_16"], kept["linux_32"]),
                         ("blacksmith-8vcpu-ubuntu-2404", "blacksmith-8vcpu-ubuntu-2404"))
        self.assertEqual(runner_pools.main(["--check"], {"RUNNER_POOLS": switch.writes[0][1],
                                                         "LINUX_RUNNER": value["linux"]}), 0)

    def test_a_stalled_size_flips_linux_once(self) -> None:
        switch = self.Switch({runner_pools.HEALTH_VARIABLE: json.dumps(health({
            "blacksmith-4vcpu-ubuntu-2404": "stalled", "blacksmith-16vcpu-ubuntu-2404": "started"})),
            "LINUX_RUNNER": "blacksmith-4vcpu-ubuntu-2404"})
        with tempfile.TemporaryDirectory() as tmp:
            env = {"RUNNER_POOLS": "", "GITHUB_STEP_SUMMARY": f"{tmp}/summary"}
            self.assertEqual(runner_pools.main([], env, api=self.Api(RECORDED), switch=switch, now=NOW), 0)
        [(name, raw), mirrored] = switch.writes
        self.assertEqual(name, "RUNNER_POOLS")
        self.assertEqual(json.loads(raw)["linux"], "blacksmith-16vcpu-ubuntu-2404")
        # LINUX_RUNNER leaves the stalled size with the pool.
        self.assertEqual(mirrored, ("LINUX_RUNNER", "blacksmith-16vcpu-ubuntu-2404"))

    def test_linux_runner_on_a_size_outside_the_set_follows_the_pool(self) -> None:
        # 2026-10-31: RUNNER_POOLS.linux was live but LINUX_RUNNER still named a size outside the pool
        # (then the stalled 4 vCPU size; since the pool went smallest first, 32 vCPU).
        pools = {"linux": "blacksmith-4vcpu-ubuntu-2404"}
        current, _ = runner_pools.parse_value(json.dumps(pools), runner_pools.load_pools())
        value, _ = runner_pools.reconcile(current, runner_pools.load_pools(), dead_now=(), served_now=(), now=NOW)
        env = {"RUNNER_POOLS": runner_pools.render(value)}
        switch = self.Switch({"LINUX_RUNNER": "blacksmith-32vcpu-ubuntu-2404"})
        self.assertEqual(runner_pools.main([], env, api=self.Api(None), switch=switch, now=NOW), 0)
        self.assertEqual(switch.writes, [("LINUX_RUNNER", "blacksmith-4vcpu-ubuntu-2404")])

    def test_linux_runner_is_left_to_the_overflow_switch_and_to_a_deliberate_value(self) -> None:
        value = {"linux": "blacksmith-32vcpu-ubuntu-2404"}
        record = '{"changed": {"LINUX_RUNNER": {"was": "blacksmith-32vcpu-ubuntu-2404"}}}'
        self.assertEqual(runner_pools.mirror_writes(value, {"LINUX_RUNNER": "x"}, record=record), [])
        self.assertEqual(runner_pools.mirror_writes(value, {"LINUX_RUNNER": "glaeda-std-xcode-26.6"}, record=None), [])
        self.assertEqual(runner_pools.mirror_writes(value, {"LINUX_RUNNER": None}, record=None),
                         [("LINUX_RUNNER", "blacksmith-32vcpu-ubuntu-2404")])
        self.assertEqual(runner_pools.mirror_writes(value, {"LINUX_RUNNER": "blacksmith-32vcpu-ubuntu-2404"},
                                                    record=None), [])

    def test_unreadable_evidence_keeps_the_dead_marks(self) -> None:
        # Watch run 41279880300 (2026-11-01 06:12-06:23Z): every App-token read returned 403 (the job
        # listing, the janitor snapshot, CI_CLOUD_LABEL_HEALTH), the 32 vCPU mark passed DEAD_TTL with no
        # evidence about it, and RUNNER_POOLS.linux went from 16 back to the stalled 32 vCPU size.
        # Unknown stays unknown: the mark is kept and the pool stays where it was. The sizes come from the
        # declared pool (its first member dead, the pool on its second), whatever order it lists them in.
        marked = runner_pools.iso(NOW - runner_pools.DEAD_TTL - dt.timedelta(minutes=10))
        pools = runner_pools.load_pools()
        first, second = runner_pools.members(pools["linux"])[:2]
        # Every pool on its first member that is not the dead one (linux_4 lists the same 4 vCPU size first).
        held = {name: next(m for m in runner_pools.members(spec) if m != first) for name, spec in pools.items()}
        held["linux"] = second
        held["_dead"] = {first: marked}
        held["_updated"] = marked

        class Forbidden(self.Switch):
            def get_variable(self, name):
                raise RuntimeError(f"GET /actions/variables/{name} failed (403)")

        class NoSnapshot:
            def snapshot(self, *, now):
                raise RuntimeError("GET artifacts failed (403)")

        switch = Forbidden()
        env = {"RUNNER_POOLS": runner_pools.render(held)}
        self.assertEqual(runner_pools.main([], env, api=NoSnapshot(), switch=switch, now=NOW), 0)
        self.assertEqual(switch.writes, [])
        # The same with health that is only stale (the job's start value from 05:30Z) and no snapshot.
        stale = health({first: "stalled"}, checked=NOW - dt.timedelta(minutes=55))
        switch = self.Switch({runner_pools.HEALTH_VARIABLE: json.dumps(stale), "LINUX_RUNNER": second})
        self.assertEqual(runner_pools.main([], env, api=self.Api(None), switch=switch, now=NOW), 0)
        self.assertEqual(switch.writes, [])
        # A fresh snapshot is no evidence about a Linux size (it lists only macOS labels): still held.
        current, _ = runner_pools.parse_value(env["RUNNER_POOLS"], pools)
        covered = runner_pools.evidence_covers(None, RECORDED, pools, now=NOW)
        self.assertNotIn(first, covered)
        self.assertIn("blacksmith-6vcpu-macos-26", covered)
        value, lines = runner_pools.reconcile(current, pools, dead_now=(), served_now=(), now=NOW, covered=covered)
        self.assertEqual((value["linux"], value["_dead"]), (second, held["_dead"]))
        self.assertTrue(any("kept; no fresh evidence" in line for line in lines))
        # Fresh probe health that lists the dead size lets its expired mark go, as before.
        fresh = health({second: "started", first: "started"})
        covered = runner_pools.evidence_covers(fresh, None, pools, now=NOW)
        value, _ = runner_pools.reconcile(current, pools, dead_now=(), served_now=(), now=NOW, covered=covered)
        self.assertEqual((value["linux"], value["_dead"]), (first, {}))
        # Health that lists only the other size says nothing about the dead one: kept.
        covered = runner_pools.evidence_covers(health({second: "started"}), None, pools, now=NOW)
        value, _ = runner_pools.reconcile(current, pools, dead_now=(), served_now=(), now=NOW, covered=covered)
        self.assertEqual(value["linux"], second)

    def test_an_unreadable_linux_runner_is_not_overwritten(self) -> None:
        class Broken(self.Switch):
            def get_variable(self, name):
                if name == "LINUX_RUNNER":
                    raise RuntimeError("GET failed (502)")
                return super().get_variable(name)
        value, _ = runner_pools.reconcile({}, runner_pools.load_pools(), dead_now=(), served_now=(), now=NOW)
        switch = Broken()
        env = {"RUNNER_POOLS": runner_pools.render(value)}
        self.assertEqual(runner_pools.main([], env, api=self.Api(None), switch=switch, now=NOW), 0)
        self.assertEqual(switch.writes, [])

    def test_check_fails_while_linux_runner_is_outside_the_linux_pool(self) -> None:
        value, _ = runner_pools.reconcile({}, runner_pools.load_pools(), dead_now=(), served_now=(), now=NOW)
        env = {"RUNNER_POOLS": runner_pools.render(value)}
        self.assertEqual(runner_pools.main(["--check"], dict(env, LINUX_RUNNER="blacksmith-4vcpu-ubuntu-2404")), 0)
        self.assertEqual(runner_pools.main(["--check"], dict(env, LINUX_RUNNER="blacksmith-32vcpu-ubuntu-2404")), 1)
        self.assertEqual(runner_pools.main(["--check"], env), 1)
        self.assertEqual(runner_pools.main(["--check"], dict(env, LINUX_RUNNER="ubuntu-24.04",
                                                             CI_CLOUD_OVERFLOW_SAVED=SWITCHED_LINUX)), 0)
        # A record that left LINUX_RUNNER alone does not excuse it.
        self.assertEqual(runner_pools.main(["--check"], dict(env, LINUX_RUNNER="ubuntu-24.04",
                                                             CI_CLOUD_OVERFLOW_SAVED=MACOS_ONLY_RECORD)), 1)

    def test_a_macos_only_overflow_record_does_not_freeze_linux_runner_on_a_dead_member(self) -> None:
        # 2026-11-01: the record (04:23Z) changed only macOS variables; RUNNER_POOLS marked 32 vCPU dead at
        # 05:30Z and moved linux to 16 vCPU, but LINUX_RUNNER stayed on 32 and its jobs queued there.
        # The declared linux pool is now 4 then 16 vCPU (32 vCPU left it on 2026-11-01), so the dead member is 4.
        current, _ = runner_pools.parse_value(json.dumps({"linux": "blacksmith-4vcpu-ubuntu-2404"}),
                                              runner_pools.load_pools())
        value, _ = runner_pools.reconcile(current, runner_pools.load_pools(),
                                          dead_now={"blacksmith-4vcpu-ubuntu-2404"}, served_now=(), now=NOW)
        self.assertEqual(value["linux"], "blacksmith-16vcpu-ubuntu-2404")
        live = {"LINUX_RUNNER": "blacksmith-4vcpu-ubuntu-2404"}
        self.assertEqual(runner_pools.mirror_writes(value, live, record=MACOS_ONLY_RECORD),
                         [("LINUX_RUNNER", "blacksmith-16vcpu-ubuntu-2404")])
        # The switch's own change stays the switch's, and an unreadable record still defers everything.
        self.assertEqual(runner_pools.mirror_writes(value, live, record=SWITCHED_LINUX), [])
        self.assertEqual(runner_pools.mirror_writes(value, live, record="not json"), [])
        self.assertEqual(runner_pools.mirror_writes(value, live, record='{"since": "x"}'), [])
        env = {"RUNNER_POOLS": runner_pools.render(value)}
        switch = self.Switch({"LINUX_RUNNER": "blacksmith-4vcpu-ubuntu-2404",
                              "CI_CLOUD_OVERFLOW_SAVED": MACOS_ONLY_RECORD})
        self.assertEqual(runner_pools.main([], env, api=self.Api(None), switch=switch, now=NOW), 0)
        self.assertEqual(switch.writes, [("LINUX_RUNNER", "blacksmith-16vcpu-ubuntu-2404")])

    def test_the_repo_variable_check_hands_in_what_the_mirror_check_reads(self) -> None:
        workflow = yaml.safe_load((ROOT / ".github/workflows/ci-repo-variables.yml").read_text())
        steps = [step for job in workflow["jobs"].values() for step in job.get("steps", [])
                 if "runner_pools.py --check" in str(step.get("run", ""))]
        self.assertTrue(steps)
        for step in steps:
            for name in (*runner_pools.MIRRORS, runner_pools.OVERFLOW_RECORD):
                self.assertEqual(step["env"].get(name), "${{ vars.%s }}" % name)

    def test_runner_pool_check_defers_once_for_a_new_declaration(self) -> None:
        workflow = yaml.safe_load((ROOT / ".github/workflows/ci-repo-variables.yml").read_text())
        steps = [step for job in workflow["jobs"].values() for step in job.get("steps", [])]
        declaration = next(step for step in steps if step.get("id") == "declaration")
        check = next(step for step in steps if "runner_pools.py --check" in str(step.get("run", "")))
        self.assertIn("github.event_name == 'push'", declaration["if"])
        self.assertIn("steps.declaration.outputs.pending != 'true'", check["if"])
        # Review of #30627: a depth-1 clone lacks event.before, so the diff must have it or call it pending.
        checkout = next(step for step in steps if step.get("name") == "Checkout")
        self.assertEqual(checkout["with"].get("fetch-depth"), 2)
        self.assertIn("BEFORE", declaration["env"])
        self.assertIn("SHA", declaration["env"])
        self.assertIn("check_runner_pool_declaration.sh", declaration["run"])
        declaration_script = (ROOT / "scripts/ci/check_runner_pool_declaration.sh").read_text()
        self.assertIn(".github/runners.json", declaration_script)

    def test_runner_pool_declaration_diff_failure_fails_closed(self) -> None:
        script = ROOT / "scripts/ci/check_runner_pool_declaration.sh"
        with tempfile.TemporaryDirectory() as tmp:
            fake_git = Path(tmp) / "git"
            fake_git.write_text("""#!/bin/sh
if [ "$1" = diff ]; then
  exit 128
fi
exit 0
""", encoding="utf-8")
            fake_git.chmod(0o755)
            output = Path(tmp) / "github-output"
            env = dict(os.environ, PATH=f"{tmp}:{os.environ['PATH']}", BEFORE="before", SHA="after",
                       GITHUB_OUTPUT=str(output))
            result = subprocess.run(["bash", str(script)], env=env, text=True,
                                    capture_output=True, check=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(output.exists())
            self.assertIn("git diff exited 128", result.stderr)

    def test_no_switch_token_and_a_correct_linux_runner_is_not_a_failure(self) -> None:
        # Review of #28864: with no token and the variables not handed in, the mirror is unknown, not unset.
        value, _ = runner_pools.reconcile({}, runner_pools.load_pools(), dead_now=(), served_now=(), now=NOW)
        env = {"RUNNER_POOLS": runner_pools.render(value)}
        self.assertEqual(runner_pools.main([], env, api=self.Api(None), switch=None, now=NOW), 0)
        env.update(LINUX_RUNNER=value["linux"], CI_CLOUD_OVERFLOW_SAVED="")
        self.assertEqual(runner_pools.main([], env, api=self.Api(None), switch=None, now=NOW), 0)

    def test_the_overflow_watch_hands_in_what_the_mirror_reads(self) -> None:
        workflow = yaml.safe_load((ROOT / ".github/workflows/ci-cloud-overflow-probe.yml").read_text())
        steps = [step for job in workflow["jobs"].values() for step in job.get("steps", [])
                 if "python3 scripts/ci/runner_pools.py" in str(step.get("run", ""))]
        self.assertTrue(steps)
        for step in steps:
            for name in (*runner_pools.MIRRORS, runner_pools.OVERFLOW_RECORD):
                self.assertEqual(step["env"].get(name), "${{ vars.%s }}" % name)

    def test_nothing_changed_writes_nothing(self) -> None:
        switch = self.Switch({"LINUX_RUNNER": "blacksmith-4vcpu-ubuntu-2404"})
        env = {"RUNNER_POOLS": ""}
        runner_pools.main([], env, api=self.Api(RECORDED), switch=switch, now=NOW)
        env["RUNNER_POOLS"] = switch.writes[0][1]
        runner_pools.main([], env, api=self.Api(RECORDED), switch=switch, now=NOW + dt.timedelta(minutes=10))
        self.assertEqual(len(switch.writes), 1)

    def test_a_malformed_variable_is_rewritten(self) -> None:
        switch = self.Switch()
        self.assertEqual(runner_pools.main([], {"RUNNER_POOLS": '{"_dead":[]}'}, api=self.Api(None),
                                           switch=switch, now=NOW), 0)
        self.assertEqual(runner_pools.value_problems(json.loads(switch.writes[0][1]), runner_pools.load_pools()), [])

    def test_check_fails_on_an_unset_or_malformed_variable(self) -> None:
        self.assertEqual(runner_pools.main(["--check"], {"RUNNER_POOLS": ""}), 1)
        self.assertEqual(runner_pools.main(["--check"], {"RUNNER_POOLS": '{"_dead":[]}'}), 1)


class RawLabelVars(unittest.TestCase):
    """RAW_LABEL_VARS leave a dead label with the pools and go back when it recovers (2026-11-18: LINUX_BUILD_RUNNER
    and LINUX_RUNNER_DARWIN_CROSS stayed on a dead blacksmith-32vcpu-ubuntu-2404, about 1,706 jobs queued there)."""

    NOW = dt.datetime(2026, 11, 18, 4, 30, tzinfo=dt.timezone.utc)
    DEAD32 = "blacksmith-32vcpu-ubuntu-2404"
    LIVE16 = "blacksmith-16vcpu-ubuntu-2404"
    SIZES = ("blacksmith-2vcpu-ubuntu-2404", "blacksmith-4vcpu-ubuntu-2404", "blacksmith-8vcpu-ubuntu-2404",
             "blacksmith-16vcpu-ubuntu-2404", "blacksmith-32vcpu-ubuntu-2404")

    def switch(self, variables, stalled, now):
        states = {label: ("stalled" if label in stalled else "started") for label in self.SIZES}
        return Main.Switch({runner_pools.HEALTH_VARIABLE: json.dumps(health(states, checked=now)), **variables})

    def run_pass(self, switch, pools_value, now):
        from contextlib import redirect_stdout
        from io import StringIO
        out = StringIO()
        switch.variables[runner_pools.HEALTH_VARIABLE] = json.dumps(health(
            json.loads(switch.variables[runner_pools.HEALTH_VARIABLE])["labels"], checked=now))
        switch.writes.clear()
        with redirect_stdout(out):
            code = runner_pools.main([], {"RUNNER_POOLS": pools_value}, api=Main.Api(fresh_snapshot(now)), switch=switch,
                                     now=now)
        self.assertEqual(code, 0)
        written = dict(switch.writes)
        return written, json.loads(written.get("RUNNER_POOLS", pools_value)), out.getvalue()

    def outage(self):
        return self.switch({
            "LINUX_RUNNER": self.LIVE16,
            "LINUX_BUILD_RUNNER": self.DEAD32,
            "LINUX_RUNNER_DARWIN_CROSS": self.DEAD32,
            "CI_TRUSTED_RUNNER": "blacksmith-2vcpu-ubuntu-2404",
            "CI_COMPILE_CHECK_GATEWAY": "glaeda-gateway-xcode-26.6",
            "LINUX_ARM64_RUNNER": "ubuntu-24.04-arm",
        }, {self.DEAD32}, self.NOW)

    def test_a_dead_label_moves_the_variable_and_records_its_home(self) -> None:
        switch = self.outage()
        written, value, out = self.run_pass(switch, "", self.NOW)
        self.assertEqual(written["LINUX_BUILD_RUNNER"], self.LIVE16)
        self.assertEqual(written["LINUX_RUNNER_DARWIN_CROSS"], self.LIVE16)
        self.assertEqual(value[runner_pools.RAW_HOME_KEY], {
            "LINUX_BUILD_RUNNER": {"home": self.DEAD32, "to": self.LIVE16},
            "LINUX_RUNNER_DARWIN_CROSS": {"home": self.DEAD32, "to": self.LIVE16}})
        self.assertIn(f"::warning title=Runner pools::LINUX_BUILD_RUNNER: {self.DEAD32} -> {self.LIVE16}", out)
        self.assertIn(f"::warning title=Runner pools::LINUX_RUNNER_DARWIN_CROSS: {self.DEAD32} -> {self.LIVE16}", out)
        # The next pass, still dead, moves nothing and keeps the homes.
        again, kept, _ = self.run_pass(switch, runner_pools.render(value), self.NOW + dt.timedelta(minutes=10))
        self.assertEqual(set(again) - {"RUNNER_POOLS"}, set())
        self.assertEqual(kept[runner_pools.RAW_HOME_KEY], value[runner_pools.RAW_HOME_KEY])

    def test_recovery_moves_it_back_and_then_forgets_the_home(self) -> None:
        switch = self.outage()
        _, value, _ = self.run_pass(switch, "", self.NOW)
        later = self.NOW + dt.timedelta(minutes=10)
        switch.variables[runner_pools.HEALTH_VARIABLE] = json.dumps(health({label: "started" for label in self.SIZES}))
        written, value, out = self.run_pass(switch, runner_pools.render(value), later)
        self.assertNotIn(self.DEAD32, value["_dead"])
        self.assertEqual(written["LINUX_BUILD_RUNNER"], self.DEAD32)
        self.assertEqual(written["LINUX_RUNNER_DARWIN_CROSS"], self.DEAD32)
        self.assertIn(f"LINUX_BUILD_RUNNER: {self.LIVE16} -> {self.DEAD32} ({self.DEAD32} takes jobs again", out)
        written, value, _ = self.run_pass(switch, runner_pools.render(value), later + dt.timedelta(minutes=10))
        self.assertNotIn(runner_pools.RAW_HOME_KEY, value)
        self.assertEqual(set(written) - {"RUNNER_POOLS"}, set())

    def test_a_variable_on_a_live_label_is_never_touched(self) -> None:
        switch = self.outage()
        written, value, _ = self.run_pass(switch, "", self.NOW)
        for name in ("CI_TRUSTED_RUNNER", "CI_COMPILE_CHECK_GATEWAY", "LINUX_ARM64_RUNNER", "CI_CONTROL_RUNNER"):
            self.assertNotIn(name, written)
            self.assertNotIn(name, value[runner_pools.RAW_HOME_KEY])

    def test_a_variable_set_by_hand_to_a_non_pool_value_is_left_alone(self) -> None:
        switch = self.outage()
        _, value, _ = self.run_pass(switch, "", self.NOW)
        switch.variables["LINUX_BUILD_RUNNER"] = "ubuntu-24.04"
        written, value, out = self.run_pass(switch, runner_pools.render(value), self.NOW + dt.timedelta(minutes=10))
        self.assertNotIn("LINUX_BUILD_RUNNER", written)
        self.assertNotIn("LINUX_BUILD_RUNNER", value[runner_pools.RAW_HOME_KEY])
        self.assertIn("LINUX_BUILD_RUNNER=ubuntu-24.04 was set by hand", out)
        # Nor is one a person set to another live pool size, even once its old home recovers.
        switch.variables["LINUX_RUNNER_DARWIN_CROSS"] = "blacksmith-8vcpu-ubuntu-2404"
        switch.variables[runner_pools.HEALTH_VARIABLE] = json.dumps(health({label: "started" for label in self.SIZES}))
        written, value, _ = self.run_pass(switch, runner_pools.render(value), self.NOW + dt.timedelta(minutes=20))
        self.assertEqual(set(written) - {"RUNNER_POOLS"}, set())
        self.assertNotIn(runner_pools.RAW_HOME_KEY, value)

    def test_a_variable_the_overflow_switch_changed_is_left_to_it(self) -> None:
        switch = self.outage()
        switch.variables[runner_pools.OVERFLOW_RECORD] = json.dumps(
            {"changed": {"LINUX_BUILD_RUNNER": {"before": self.DEAD32, "after": self.LIVE16}}})
        written, value, _ = self.run_pass(switch, "", self.NOW)
        self.assertNotIn("LINUX_BUILD_RUNNER", written)
        self.assertEqual(written["LINUX_RUNNER_DARWIN_CROSS"], self.LIVE16)

    def test_an_unreadable_variable_is_not_moved(self) -> None:
        switch = self.outage()
        real = switch.get_variable

        def get_variable(name):
            if name == "LINUX_BUILD_RUNNER":
                raise RuntimeError("GitHub API GET (502)")
            return real(name)

        switch.get_variable = get_variable
        written, _, _ = self.run_pass(switch, "", self.NOW)
        self.assertNotIn("LINUX_BUILD_RUNNER", written)
        self.assertEqual(written["LINUX_RUNNER_DARWIN_CROSS"], self.LIVE16)

    def test_the_substitute_is_the_same_image_largest_live_size_at_most_the_dead_one(self) -> None:
        pools = runner_pools.load_pools()
        self.assertEqual(runner_pools.raw_substitute(self.DEAD32, {self.DEAD32}, pools), self.LIVE16)
        self.assertEqual(runner_pools.raw_substitute(self.DEAD32, {self.DEAD32, self.LIVE16}, pools),
                         "blacksmith-8vcpu-ubuntu-2404")
        # Nothing smaller is live: the next size up.
        self.assertEqual(runner_pools.raw_substitute("blacksmith-2vcpu-ubuntu-2404", {"blacksmith-2vcpu-ubuntu-2404"},
                                                     pools), "blacksmith-4vcpu-ubuntu-2404")
        self.assertIsNone(runner_pools.raw_substitute(self.DEAD32, set(self.SIZES), pools))
        self.assertIsNone(runner_pools.raw_substitute("blacksmith-6vcpu-macos-26", set(), pools))

    def test_the_tree_build_variables_never_move_below_eight_vcpu(self) -> None:
        # 2026-11-18 13:31Z: LINUX_BUILD_RUNNER and LINUX_RUNNER_DARWIN_CROSS had moved to 2 vCPU, where the fat-LTO
        # tree build legs were SIGKILLed out of memory.
        pools = runner_pools.load_pools()
        small = {"blacksmith-2vcpu-ubuntu-2404", "blacksmith-4vcpu-ubuntu-2404"}
        dead = set(self.SIZES) - small
        self.assertEqual(runner_pools.raw_substitute(self.DEAD32, dead, pools), "blacksmith-4vcpu-ubuntu-2404")
        self.assertIsNone(runner_pools.raw_substitute(self.DEAD32, dead, pools, 8))
        live = {"LINUX_BUILD_RUNNER": "blacksmith-2vcpu-ubuntu-2404", "CI_CONTROL_RUNNER": "blacksmith-2vcpu-ubuntu-2404"}
        previous = {"LINUX_BUILD_RUNNER": {"home": "blacksmith-16vcpu-ubuntu-2404", "to": "blacksmith-2vcpu-ubuntu-2404"}}
        homes, lines = runner_pools.raw_homes(previous, live, dead, pools, owned=frozenset())
        # No size at or above 8 vCPU is live: it goes back home to wait there.
        self.assertEqual(homes["LINUX_BUILD_RUNNER"], {"home": "blacksmith-16vcpu-ubuntu-2404",
                                                       "to": "blacksmith-16vcpu-ubuntu-2404"})
        self.assertTrue(any("below its 8 vCPU floor" in line for line in lines), lines)
        value = {runner_pools.DEAD_KEY: {label: "2026-11-18T13:31:07Z" for label in dead},
                 runner_pools.RAW_HOME_KEY: homes}
        self.assertEqual(runner_pools.raw_writes(value, live, owned=frozenset()),
                         [("LINUX_BUILD_RUNNER", "blacksmith-16vcpu-ubuntu-2404", "blacksmith-2vcpu-ubuntu-2404",
                           "blacksmith-16vcpu-ubuntu-2404 is dead")])
        # 8 vCPU live again: it takes that, not 2.
        homes, _ = runner_pools.raw_homes(previous, live, dead - {"blacksmith-8vcpu-ubuntu-2404"}, pools,
                                          owned=frozenset())
        self.assertEqual(homes["LINUX_BUILD_RUNNER"]["to"], "blacksmith-8vcpu-ubuntu-2404")

    def test_the_pinned_spill_path_makes_the_same_moves(self) -> None:
        # Production runs main() through linux_pool_spill.py: a switch that records writes, then the spill re-parses
        # the recorded RUNNER_POOLS (parse_value()) and writes mirror_writes() over _live() itself.
        switch = self.outage()
        self.run_pass(switch, "", self.NOW)
        recorded = dict(switch.writes)
        value, dropped = runner_pools.parse_value(recorded["RUNNER_POOLS"], runner_pools.load_pools())
        self.assertEqual(dropped, [])
        self.assertIn(runner_pools.RAW_HOME_KEY, value)
        for name in ("LINUX_BUILD_RUNNER", "LINUX_RUNNER_DARWIN_CROSS"):
            switch.variables[name] = self.DEAD32  # the recorder never wrote them
        live, record, readable = runner_pools._live(switch, {})
        self.assertTrue(readable)
        writes = dict(runner_pools.mirror_writes(value, live, record=record))
        self.assertEqual((writes["LINUX_BUILD_RUNNER"], writes["LINUX_RUNNER_DARWIN_CROSS"]),
                         (self.LIVE16, self.LIVE16))

    def test_malformed_homes_are_dropped(self) -> None:
        pools = runner_pools.load_pools()
        for bad in ([], {"LINUX_BUILD_RUNNER": "x"}, {"NOT_A_RAW_VAR": {"home": self.DEAD32, "to": self.LIVE16}},
                    {"LINUX_BUILD_RUNNER": {"home": "blacksmith-6vcpu-macos-26", "to": self.LIVE16}}):
            value, dropped = runner_pools.parse_value(json.dumps({runner_pools.RAW_HOME_KEY: bad}), pools)
            self.assertNotIn(runner_pools.RAW_HOME_KEY, value)
            self.assertTrue(dropped)

    def test_every_variable_a_main_workflow_reads_ahead_of_a_linux_label_is_covered(self) -> None:
        # The detector for this class: `vars.X || ...` in an expression that falls back to a Blacksmith Linux label
        # or a Linux pool. A new such variable must join RAW_LABEL_VARS (or be the mirror or a routing record).
        pattern = re.compile(r"vars\.([A-Z0-9_]+) \|\|")
        linux = re.compile(r"blacksmith-\d+vcpu-ubuntu|RUNNER_POOLS\)\.(?:linux|promotion)")
        exempt = {*runner_pools.MIRRORS, runner_pools.VARIABLE, runner_pools.OVERFLOW_RECORD}
        found = set()
        for path in sorted((ROOT / ".github").rglob("*.y*ml")):
            for line in path.read_text(encoding="utf-8").splitlines():
                if linux.search(line):
                    found |= {name for name in pattern.findall(line) if not name.startswith("MACOS_")}
        self.assertTrue(found)
        self.assertEqual(sorted(found - exempt - set(runner_pools.RAW_LABEL_VARS)), [])
        self.assertFalse([name for name in runner_pools.RAW_LABEL_VARS if "MACOS" in name])



class TruncatedSnapshot(BlacksmithFailover, unittest.TestCase):
    def test_a_truncated_snapshot_is_no_snapshot_evidence(self) -> None:
        # A janitor sweep that listed part of the queue (queue_janitor.listing_state()) undercounts every pool.
        stalled = copy.deepcopy(RECORDED)
        stalled["pools"]["blacksmith-6vcpu-macos-26"].update(queued=3, running=0, oldest_queued_minutes=30)
        stalled["label_started"] = {}
        dead, _, _ = runner_pools.label_evidence(None, stalled, now=NOW)
        self.assertEqual(dead, {"blacksmith-6vcpu-macos-26"})
        dead, started, notes = runner_pools.label_evidence(None, dict(stalled, truncated=True), now=NOW)
        self.assertEqual((dead, started), (set(), set()))
        self.assertTrue(any("truncated" in note for note in notes))

    def test_a_truncated_snapshot_still_supplies_its_recent_starts(self) -> None:
        # 2026-11-18 14:14Z: the snapshot was truncated (the queue outgrew one sweep), the writer dropped all of it,
        # and with the probes alone (every x64 size but 2 vCPU stalled under the vCPU cap) every Linux pool went
        # to the 2 vCPU release valve, while its label_started showed 4 and 8 vCPU starting jobs minutes before.
        four, eight = "blacksmith-4vcpu-ubuntu-2404", "blacksmith-8vcpu-ubuntu-2404"
        sixteen, thirty_two = "blacksmith-16vcpu-ubuntu-2404", "blacksmith-32vcpu-ubuntu-2404"
        two = "blacksmith-2vcpu-ubuntu-2404"
        snapshot = copy.deepcopy(RECORDED)
        snapshot["generated_at"] = runner_pools.iso(NOW - dt.timedelta(minutes=1))
        snapshot["truncated"] = True
        # Its counts are partial: a queue they show must not mark anything dead.
        snapshot["pools"]["blacksmith-6vcpu-macos-26"].update(queued=3, running=0, oldest_queued_minutes=30)
        snapshot["label_started"] = {four: runner_pools.iso(NOW - dt.timedelta(minutes=2)),
                                     eight: runner_pools.iso(NOW - dt.timedelta(minutes=1))}
        probes = health({two: "started", four: "stalled", eight: "stalled", sixteen: "stalled",
                         thirty_two: "stalled"})
        dead, started, _ = runner_pools.label_evidence(probes, snapshot, now=NOW)
        # Its starts count; the probe's stalls do not (#46302): a partial snapshot cannot tell a dead size from
        # one the vCPU cap keeps full, so they mark nothing dead.
        self.assertEqual(dead, set())
        self.assertTrue({four, eight} <= started)
        self.assertNotIn("blacksmith-6vcpu-macos-26", dead)
        pools = runner_pools.load_pools()
        covered = runner_pools.evidence_covers(probes, snapshot, pools, now=NOW)
        current = {"_dead": {four: runner_pools.iso(NOW - dt.timedelta(minutes=10)),
                             eight: runner_pools.iso(NOW - dt.timedelta(minutes=10))}}
        value, _ = runner_pools.reconcile(current, pools, dead_now=dead, served_now=started, now=NOW, covered=covered)
        self.assertEqual((value["linux"], value["linux_8"], value["linux_16"]), (four, eight, sixteen))
        self.assertNotEqual(value["linux_32"], two)


class CapBound(BlacksmithFailover, unittest.TestCase):
    """Blacksmith caps the org on vCPUs at once. A size that keeps starting jobs is serving however long a probe
    waits there, and a size the cap starves moves its jobs down in size, never up (2026-11-17)."""

    FOUR, EIGHT = "blacksmith-4vcpu-ubuntu-2404", "blacksmith-8vcpu-ubuntu-2404"
    SIXTEEN, THIRTY_TWO = "blacksmith-16vcpu-ubuntu-2404", "blacksmith-32vcpu-ubuntu-2404"

    def snapshot(self, starts):
        snapshot = copy.deepcopy(RECORDED)
        snapshot["generated_at"] = runner_pools.iso(NOW - dt.timedelta(minutes=1))
        snapshot["label_started"] = {label: runner_pools.iso(NOW - age) for label, age in starts.items()}
        return snapshot

    def test_a_probe_stall_on_a_size_that_keeps_starting_jobs_marks_it_serving(self) -> None:
        # 02:00:26Z on 2026-11-18: both probes waited out their 5 minutes under the cap, and RUNNER_POOLS marked
        # 4 vCPU dead while it had completed 11 jobs and ran 6 since 01:05Z.
        both_stalled = health({self.FOUR: "stalled", self.SIXTEEN: "stalled"})
        snapshot = self.snapshot({self.FOUR: dt.timedelta(minutes=2)})
        dead, started, _ = runner_pools.label_evidence(both_stalled, snapshot, now=NOW)
        self.assertNotIn(self.FOUR, dead)
        self.assertIn(self.FOUR, started)
        self.assertIn(self.SIXTEEN, dead)
        # A start older than RECENT_START is no longer evidence: the probe's stall stands.
        old = self.snapshot({self.FOUR: runner_pools.RECENT_START + dt.timedelta(minutes=5)})
        dead, _, _ = runner_pools.label_evidence(both_stalled, old, now=NOW)
        self.assertIn(self.FOUR, dead)
        # And a mark already on the serving size clears on the next pass.
        pools = runner_pools.load_pools()
        current = {"_dead": {self.FOUR: runner_pools.iso(NOW - dt.timedelta(minutes=5)),
                             self.SIXTEEN: runner_pools.iso(NOW - dt.timedelta(minutes=5))}}
        dead, started, _ = runner_pools.label_evidence(both_stalled, snapshot, now=NOW)
        value, _ = runner_pools.reconcile(current, pools, dead_now=dead, served_now=started, now=NOW,
                                          covered=runner_pools.evidence_covers(both_stalled, snapshot, pools, now=NOW))
        self.assertEqual(set(value["_dead"]), {self.SIXTEEN})
        self.assertEqual(value["linux"], self.FOUR)

    def test_linux_16_moves_down_to_8_vcpu_not_up_to_32(self) -> None:
        # 00:00-00:48Z on 2026-11-17: 32 vCPU started 1 of 282 jobs while linux_16 named it.
        pools = runner_pools.load_pools()
        value, _ = runner_pools.reconcile({}, pools, dead_now={self.SIXTEEN}, served_now={self.FOUR}, now=NOW)
        self.assertEqual(value["linux_16"], self.EIGHT)
        self.assertEqual(value["linux_32"], self.THIRTY_TWO)
        value, _ = runner_pools.reconcile({}, pools, dead_now={self.EIGHT}, served_now={self.FOUR}, now=NOW)
        self.assertEqual(value["linux_8"], self.FOUR)

    def test_every_linux_pool_fails_over_down_in_size_first(self) -> None:
        # The detector: a declared pool that lists a larger failover before a smaller one is a spec problem.
        for name, spec in runner_pools.load_pools().items():
            with self.subTest(pool=name):
                self.assertIsNone(runner_pools.grows_before_shrinking(runner_pools.members(spec)))
        grows = {"x": {"why": "x", "members": [self.SIXTEEN, self.THIRTY_TWO, self.EIGHT]}}
        self.assertIn("lists blacksmith-8vcpu-ubuntu-2404 after a larger failover",
                      "\n".join(runner_pools.spec_problems(grows)))
        self.assertIsNone(runner_pools.grows_before_shrinking([self.SIXTEEN, self.EIGHT, self.FOUR, self.THIRTY_TWO]))
        self.assertEqual(runner_pools.grows_before_shrinking([self.SIXTEEN, self.FOUR, self.EIGHT]), self.EIGHT)
        # Only Blacksmith Linux pools of one family: macOS and mixed lists keep their declared order.
        self.assertIsNone(runner_pools.grows_before_shrinking(["blacksmith-6vcpu-macos-26", "blacksmith-12vcpu-macos-26"]))



class RefusedRead(BlacksmithFailover, unittest.TestCase):
    """A refused snapshot read is asked once more with the workflow token (2026-11-18 11:18Z: the cmux-bot read
    token got 403, the writer judged on the probe alone, and every Linux pool went to the 2 vCPU release valve)."""

    FOUR, EIGHT = "blacksmith-4vcpu-ubuntu-2404", "blacksmith-8vcpu-ubuntu-2404"
    SIXTEEN, THIRTY_TWO = "blacksmith-16vcpu-ubuntu-2404", "blacksmith-32vcpu-ubuntu-2404"
    TWO = "blacksmith-2vcpu-ubuntu-2404"

    class Refused:
        def snapshot(self, *, now):
            raise RuntimeError("HTTP Error 403: Forbidden")

    def pass_with(self, fallback):
        # The 11:18Z probe: 2 vCPU started, every other size waited out its minutes behind the vCPU cap.
        switch = Main.Switch({runner_pools.HEALTH_VARIABLE: json.dumps(health({
            self.TWO: "started", self.FOUR: "stalled", self.EIGHT: "stalled", self.SIXTEEN: "stalled",
            self.THIRTY_TWO: "stalled"}))})
        self.assertEqual(runner_pools.main([], {"RUNNER_POOLS": ""}, api=self.Refused(), switch=switch, now=NOW,
                                           **({"fallback": fallback} if fallback is not None else {})), 0)
        return json.loads(switch.writes[0][1])

    def test_the_fallback_snapshot_keeps_serving_sizes_live(self) -> None:
        snapshot = copy.deepcopy(RECORDED)
        snapshot["generated_at"] = runner_pools.iso(NOW - dt.timedelta(minutes=1))
        snapshot["label_started"] = {label: runner_pools.iso(NOW - dt.timedelta(minutes=2))
                                     for label in (self.FOUR, self.EIGHT, self.SIXTEEN, self.THIRTY_TWO)}
        value = self.pass_with(Main.Api(snapshot))
        self.assertEqual(value["_dead"], {})
        self.assertEqual((value["linux"], value["linux_8"], value["linux_16"], value["linux_32"]),
                         (self.FOUR, self.EIGHT, self.SIXTEEN, self.THIRTY_TWO))

    class Counting:
        """A fallback reader that records each read and answers with a fixed result (or raises it)."""

        def __init__(self, result):
            self.result = result
            self.calls = 0

        def snapshot(self, *, now):
            self.calls += 1
            if isinstance(self.result, Exception):
                raise self.result
            return self.result

    def main_output(self, fallback):
        with contextlib.redirect_stdout(io.StringIO()) as out:
            value = self.pass_with(fallback)
        return value, out.getvalue()

    def test_a_refused_fallback_still_judges_on_the_probe(self) -> None:
        fallback = self.Counting(RuntimeError("HTTP Error 403: Forbidden"))
        value, out = self.main_output(fallback)
        self.assertEqual(fallback.calls, 1)
        # Every x64 size but 2 vCPU stalled with no snapshot: a probe stall marks a size dead only beside a fresh
        # janitor snapshot (#46302), so nothing is marked dead and no pool moves to the 2 vCPU valve, which is
        # what squeezed every Linux pool there at 11:18Z. linux_16 keeps its 16 vCPU member either way (#46366).
        self.assertEqual(value["_dead"], {})
        self.assertEqual(value["linux"], self.FOUR)
        self.assertEqual(value["linux_16"], self.SIXTEEN)
        self.assertIn("judging on the probe alone", out)

    def test_a_fallback_with_no_snapshot_warns_it_judges_on_the_probe(self) -> None:
        # GitHub.snapshot() returns None (no trusted snapshot artifact) without raising: that is not a read.
        fallback = self.Counting(None)
        value, out = self.main_output(fallback)
        self.assertEqual(fallback.calls, 1)
        self.assertEqual(value["_dead"], {})
        self.assertEqual(value["linux"], self.FOUR)
        self.assertEqual(value["linux_16"], self.SIXTEEN)
        self.assertIn("judging on the probe alone", out)
        self.assertNotIn("janitor snapshot read with the fallback token", out)

    def test_the_fallback_reader_is_built_from_the_workflow_token(self) -> None:
        # The workflow passes GH_TOKEN (the cmux-bot read token) and GH_FALLBACK_TOKEN (github.token).
        built = []
        real = runner_pools.pr_runner_pool.GitHub

        class Recording:
            def __init__(self, token, repo):
                built.append((token, repo))

            def snapshot(self, *, now):
                return None

        switch = Main.Switch({runner_pools.HEALTH_VARIABLE: json.dumps(health({self.TWO: "started"}))})
        env = {"RUNNER_POOLS": "", "GH_TOKEN": "bot-token", "GH_FALLBACK_TOKEN": "workflow-token",
               "GH_REPO": "manaflow-ai/cmux"}
        runner_pools.pr_runner_pool.GitHub = Recording
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                runner_pools.main([], env, api=self.Refused(), switch=switch, now=NOW)
            self.assertEqual(built, [("workflow-token", "manaflow-ai/cmux")])
            # The same token twice is no fallback: nothing more is built.
            built.clear()
            with contextlib.redirect_stdout(io.StringIO()):
                runner_pools.main([], {**env, "GH_FALLBACK_TOKEN": "bot-token"}, api=self.Refused(), switch=switch,
                                  now=NOW)
            self.assertEqual(built, [])
        finally:
            runner_pools.pr_runner_pool.GitHub = real

if __name__ == "__main__":
    unittest.main()
