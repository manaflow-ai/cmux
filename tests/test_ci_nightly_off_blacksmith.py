#!/usr/bin/env python3
"""Nightlies never use Blacksmith, ever, and never depend on one host.

Lawrence, 2026-10-30: "nightly should NEVER use blacksmith ... nightly should
only use our own mac minis" (for cmux-next and classic). Every job of every
nightly workflow (and every reusable workflow one calls) runs on our own Mac
minis on every path: its primary label, its fallbacks, a re-run or the owned-pool
rescue's attempt, the cloud overflow switch, any input or repository variable.
Native and signing work takes owned pickers, then the owned nightly slot
(vars.CI_NIGHTLY_NEXT_BUILD_RUNNER), then the owned side lane; everything else
takes the owned nightly-ops runners (`cmux-nightly-ops`,
scripts/ci/nightly-ops-install.sh, on two minis). A nightly may not name a
runner-specific label or rely on the old dedicated builder tuple.
"""

from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
sys.path.insert(0, str(ROOT / "tests"))
from runs_on_labels import Unknown, resolve_labels  # noqa: E402

OVERFLOW_RECORD = '{"probe":"blacksmith-4vcpu-ubuntu-2404"}'
SWITCH_OFF = {"CI_CLOUD_OVERFLOW_SAVED": []}
# The probe's runs-on reads the record's .probe, which the resolver does not model;
# the test still checks it names no macOS label.
OVERFLOW_UNREAD = ("ci-cloud-overflow-probe.yml#probe",)
OPS_LABEL = "cmux-nightly-ops"
OPS_EXPRESSION = "${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || 'cmux-nightly-ops' }}"
# The nightly jobs that hold no release secrets and need no Mac.
LIGHT_NIGHTLY_JOBS = ("decide", "resolve-nightly-cmux-tui-client", "resolve-nightly-ghostty-cli-helper",
                      "pick-nightly-build-runner", "prepare-nightly-variant-primary",
                      "prepare-nightly-variant-fallback", "prepare-nightly-variant", "pick-nightly-sign-runner",
                      "find-nightly-next-recovery")

SINGLE_HOST = re.compile(r"cmux22|glaeda-runner-[a-z0-9][a-z0-9-]*", re.IGNORECASE)
OLD_NIGHTLY_RUNNER = re.compile(r"CI_NIGHTLY_(?:NEXT_)?TRUSTED_(?:POOL|RUNNER)")
# The cmux-tui nightly calls the shared package builder, which keeps its own
# fallbacks for other callers; the nightly must override every runner input.
TUI_NIGHTLY_RUNNER_INPUTS = (
    "macos_runner",
    "macos_retry_runner",
    "linux_runner",
    "linux_arm64_runner",
    "windows_runner",
)


def nightly_workflows() -> list[Path]:
    paths = set(WORKFLOWS.glob("*nightly*.yml")) | set(WORKFLOWS.glob("*notarization*.yml"))
    return sorted(paths)


def code_lines(path: Path):
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        if line.lstrip().startswith("#"):
            continue
        yield number, line.split(" # ", 1)[0]


class NightlyPooledRoutingTests(unittest.TestCase):
    def test_nightly_workflows_are_discovered(self) -> None:
        names = {path.name for path in nightly_workflows()}
        for required in ("nightly.yml", "auto-resume-nightly-notarization.yml"):
            self.assertIn(required, names)

    def test_nightly_jobs_use_pools_not_single_hosts(self) -> None:
        failures = [
            f"{path.name}:{number}: {line.strip()}"
            for path in nightly_workflows()
            for number, line in code_lines(path)
            if SINGLE_HOST.search(line)
        ]
        self.assertEqual(failures, [], "nightly workflows must not depend on a single host")

    def test_nightly_jobs_do_not_read_the_retired_dedicated_runner_tuple(self) -> None:
        failures = [
            f"{path.name}:{number}: {line.strip()}"
            for path in nightly_workflows()
            for number, line in code_lines(path)
            if OLD_NIGHTLY_RUNNER.search(line) and "runs-on:" in line
        ]
        self.assertEqual(failures, [], "nightly workflows must not use the retired dedicated runner tuple")

    def test_nightlies_skip_the_benchmark_mini(self) -> None:
        """cmux11s is the dedicated benchmark mini (since 2026-10-20, a153).

        Its runners are off and must stay idle, so no nightly job may name it or
        any pool it carries: the std PR/side/session pools and the shared
        side-lane or daemon variables (which an operator may point at a std
        pool). Nightly macOS work uses only the cmux15 trusted tuple or the
        light side lane (light-class minis; cmux11s is std class).
        """
        forbidden = re.compile(r"cmux11s|vars\.(CI_NEXT_DAEMON_POOL|CI_NEXT_PROMOTE_POOL|CI_PIN_DAEMON_POOL)\b")
        failures = []
        for path in nightly_workflows():
            for number, line in code_lines(path):
                if forbidden.search(line):
                    failures.append(f"{path.name}:{number}: {line.strip()}")
        self.assertEqual(failures, [], "nightly jobs must never reach the benchmark mini cmux11s")

    @unittest.skipUnless((WORKFLOWS / "cmux-tui-nightly.yml").exists(), "no cmux-tui nightly on this branch")
    def test_tui_nightly_overrides_every_package_builder_runner(self) -> None:
        text = (WORKFLOWS / "cmux-tui-nightly.yml").read_text(encoding="utf-8")
        block = text[text.index("uses: ./.github/workflows/cmux-tui-build-package.yml"):]
        block = block[: block.index("\n  publish-npm:")]
        for name in TUI_NIGHTLY_RUNNER_INPUTS:
            with self.subTest(input=name):
                match = re.search(rf"^\s+{name}: (.+)$", block, re.MULTILINE)
                self.assertIsNotNone(match, f"cmux-tui nightly must pass {name}")
                self.assertNotRegex(match.group(1), SINGLE_HOST)

    def test_native_nightlies_take_owned_pickers_then_the_owned_nightly_slot(self) -> None:
        text = (WORKFLOWS / "nightly.yml").read_text(encoding="utf-8")
        job = text[text.index("\n  build-nightly-app:"):]
        runs_on = re.search(r"^    runs-on: (.+)$", job, re.MULTILINE).group(1)
        self.assertIn("needs.pick-nightly-build-runner.outputs.owned", runs_on)
        self.assertIn("vars.CI_NIGHTLY_NEXT_BUILD_RUNNER", runs_on)
        self.assertNotIn("blacksmith", runs_on.lower())

    def test_secret_bearing_nightlies_use_owned_macs_only(self) -> None:
        text = (WORKFLOWS / "nightly.yml").read_text(encoding="utf-8")
        for name in ("build-sign-notarize-nightly", "sign-nightly-identity-legacy", "recover-nightly-next-notarization"):
            job = text[text.index(f"\n  {name}:"):]
            runs_on = re.search(r"^    runs-on: (.+)$", job, re.MULTILINE).group(1)
            with self.subTest(job=name):
                # glaeda gives these (its SIGNING_JOBS) the whole mini on the owned nightly slot; the nightly-ops
                # runners are outside glaeda and would fail the claim gate, so signing never falls to them.
                # The literal last choice is never reached while check_repo_variables.py holds the variables owned;
                # if it were, the claim gate (the job's first step) stops the job before any credential there.
                self.assertTrue(runs_on.endswith("|| vars.CI_NIGHTLY_NEXT_BUILD_RUNNER || vars.CI_SIDE_LANE_RUNNER "
                                                 "|| 'cmux-nightly-ops' }}"), runs_on)
                self.assertNotIn("blacksmith", runs_on.lower())

    def test_prepare_runs_on_owned_ops_and_executes_no_mach_o(self) -> None:
        """prepare-nightly-variant only moves and reads files, so it runs on the owned nightly-ops Macs.

        The cmux-tui client install (it runs the client), Apple's strip and the
        capability probes run in build-nightly-app; the theme picker regression
        and the diff sidecar handshake (they run Mach-O) run on the signed app
        in verify-signed-nightly. On Linux (a fork) llvm-lipo thins, which gives
        Apple lipo's bytes; on a Mac Apple's lipo does.
        """
        import yaml
        document = yaml.safe_load((WORKFLOWS / "nightly.yml").read_text(encoding="utf-8"))
        jobs = document["jobs"]
        for name in ("prepare-nightly-variant-primary", "prepare-nightly-variant-fallback"):
            self.assertEqual(jobs[name]["runs-on"], OPS_EXPRESSION)
        moved_out = ("install-cmux-tui-client.sh", "strip-release-bundle.sh", "write-cmux-tui-version.sh",
                     "check-daemon-capabilities.sh", "test_bundled_ghostty_theme_picker_helper.sh",
                     "verify-diff-sidecar-artifact.sh", "select-ci-xcode.sh", "ditto ", "otool", "codesign")
        for name in ("prepare-nightly-variant-primary", "prepare-nightly-variant-fallback"):
            runs = "\n".join(step.get("run", "") for step in jobs[name]["steps"])
            steps = {step.get("name"): step for step in jobs[name]["steps"]}
            with self.subTest(job=name):
                for needle in moved_out:
                    self.assertNotIn(needle, runs)
                self.assertTrue(steps["Put llvm-lipo on PATH as lipo"]["if"].startswith("runner.os == 'Linux' && "))
                self.assertIn("Require the cmux-tui client build-nightly-app bundled", steps)
                self.assertIn("thin-app-bundle.sh", runs)
                self.assertIn("verify_app_libintl.py", runs)
        build = "\n".join(step.get("run", "") for step in jobs["build-nightly-app"]["steps"])
        for needle in ("install-cmux-tui-client.sh", "write-cmux-tui-version.sh", "check-daemon-capabilities.sh"):
            self.assertIn(needle, build)
        steps = [step.get("name") for step in jobs["build-nightly-app"]["steps"]]
        self.assertLess(steps.index("Strip unsigned nightly app before transfer"), steps.index("Bundle the cmux-tui client"))
        self.assertLess(steps.index("Bundle the cmux-tui client"), steps.index("Archive unsigned nightly app"))
        verify = "\n".join(step.get("run", "") for step in jobs["verify-signed-nightly"]["steps"])
        self.assertIn("test_bundled_ghostty_theme_picker_helper.sh", verify)
        self.assertIn("verify-diff-sidecar-artifact.sh", verify)
        helper = "\n".join(step.get("run", "") for step in jobs["build-nightly-ghostty-cli-helper"]["steps"])
        self.assertIn("strip -S -x nightly-helper/ghostty", helper)

    def test_light_nightly_jobs_take_the_owned_nightly_ops_runners(self) -> None:
        """The jobs that hold no release secrets and need no Mac build run on the owned nightly-ops runners.

        Until 2026-10-30 they ran on Blacksmith Linux. They stay off glaeda's PR runners, which would bill each
        as a compile and queue it behind PR work.
        """
        import yaml
        jobs = yaml.safe_load((WORKFLOWS / "nightly.yml").read_text(encoding="utf-8"))["jobs"]
        for name in LIGHT_NIGHTLY_JOBS:
            with self.subTest(job=name):
                self.assertEqual(jobs[name]["runs-on"], OPS_EXPRESSION)
                self.assertNotIn("secrets.APPLE", yaml.dump(jobs[name]))
                self.assertNotIn("secrets.CMUX_RELEASE_APP_KEY", yaml.dump(jobs[name]))

    def test_no_job_takes_a_mac_only_while_the_overflow_switch_is_on(self) -> None:
        """The overflow switch never sends a job to a macOS label it would not take otherwise.

        GitHub fixes a job's label when it creates the job, so a macOS label the
        switch adds strands every job created during a flap on the macOS queue.
        """
        import yaml
        record = {"CI_CLOUD_OVERFLOW_SAVED": [OVERFLOW_RECORD]}
        checked, unread = 0, set()
        for path in sorted(WORKFLOWS.glob("*.y*ml")):
            jobs = (yaml.safe_load(path.read_text(encoding="utf-8")) or {}).get("jobs") or {}
            for name, job in jobs.items():
                runs_on = (job or {}).get("runs-on")
                if "CI_CLOUD_OVERFLOW_SAVED" not in str(runs_on):
                    continue
                checked += 1
                key = f"{path.name}#{name}"
                if key in OVERFLOW_UNREAD:
                    unread.add(key)
                    self.assertIn("ubuntu", str(runs_on))
                    self.assertNotIn("macos", str(runs_on))
                    continue
                with self.subTest(job=key):
                    on = {label for label in resolve_labels(runs_on, variables=record) if isinstance(label, str)}
                    off = {label for label in resolve_labels(runs_on, variables=SWITCH_OFF) if isinstance(label, str)}
                    self.assertFalse({label for label in on - off if "macos" in label.lower()},
                                     f"{path.name}#{name}: the overflow switch adds a macOS label")
        self.assertGreater(checked, 10)
        self.assertEqual(unread, set(OVERFLOW_UNREAD), "an OVERFLOW_UNREAD entry no longer names a job")

    def test_the_overflow_rules_fail_on_a_mac_overflow(self) -> None:
        mac = ("${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || "
               "vars.CI_CLOUD_OVERFLOW_SAVED && 'blacksmith-6vcpu-macos-26' || vars.LINUX_RUNNER || "
               "'blacksmith-4vcpu-ubuntu-2404' }}")
        on = resolve_labels(mac, variables={"CI_CLOUD_OVERFLOW_SAVED": [OVERFLOW_RECORD]})
        self.assertIn("blacksmith-6vcpu-macos-26", on - resolve_labels(mac, variables=SWITCH_OFF))

    def test_the_canary_takes_the_owned_side_label_then_owned_ops(self) -> None:
        import yaml
        jobs = yaml.safe_load((WORKFLOWS / "nightly-next-canary.yml").read_text(encoding="utf-8"))["jobs"]
        self.assertTrue(jobs["canary"]["runs-on"].endswith("|| vars.CI_SIDE_LANE_RUNNER || 'cmux-nightly-ops' }}"))
        for name in ("pick", "verdict"):
            with self.subTest(job=name):
                self.assertTrue(jobs[name]["runs-on"].endswith("|| 'cmux-nightly-ops' }}"))

    def test_promotion_requests_never_wait_on_blacksmith(self) -> None:
        """The jobs that start a NEXT nightly are part of the nightly path.

        A feat-cmux-next push asks main to promote nightly-next from
        cmux-next.yml and cmux-tui-artifacts.yml (`request-nightly-next`). On
        Blacksmith those requests queued behind its pool like the nightly's own
        jobs, so no nightly started. They take LINUX_RUNNER, which the overflow
        switch moves off a stalled Blacksmith label, never a single host.
        """
        for name in ("cmux-next.yml", "cmux-tui-artifacts.yml"):
            text = (WORKFLOWS / name).read_text(encoding="utf-8")
            if "\n  request-nightly-next:" not in text:
                continue
            job = text[text.index("\n  request-nightly-next:") + 1:]
            following = re.search(r"\n  [A-Za-z0-9_-]+:\n", job[1:])
            job = job[: following.start() + 1] if following else job
            runs_on = re.search(r"^    runs-on: (.+)$", job, re.MULTILINE).group(1)
            with self.subTest(workflow=name):
                self.assertNotRegex(runs_on, SINGLE_HOST)

    @unittest.skipUnless((WORKFLOWS / "cmux-next.yml").exists(), "no cmux-next on this branch")
    def test_finished_push_runs_start_a_nightly_next_with_a_thirty_minute_catch_up(self) -> None:
        """Every finished feat-cmux-next push run asks for a NEXT nightly.

        A push whose own request was cancelled by the next push, or whose
        request waited on a stalled pool, asked for nothing. The tick closes
        that gap from events and every 30 minutes (the dedicated builder is
        cmux22, plans/cmux-next/nightly-builder-DESIGN.md). It starts when a
        cmux-next or cmux-tui artifacts push run on feat-cmux-next completes,
        whatever its conclusion, and can be started by hand. GitHub runs
        `workflow_run` only from the default branch, so the file must exist
        on main too.
        """
        path = WORKFLOWS / "nightly-next-tick.yml"
        self.assertTrue(path.exists(), "nightly-next-tick.yml must exist")
        text = path.read_text(encoding="utf-8")
        self.assertRegex(text, r"(?m)^\s+schedule:\s*$")
        self.assertRegex(text, r'(?m)^\s+- cron: "7,37 \* \* \* \*"$')
        self.assertIn("workflow_run:", text)
        workflows = re.search(r"(?m)^\s+workflows: \[(.+)\]$", text)
        self.assertIsNotNone(workflows, "workflow_run must name its workflows")
        self.assertIn('"cmux-next"', workflows.group(1))
        self.assertIn('"cmux-tui artifacts"', workflows.group(1))
        self.assertRegex(text, r"(?m)^\s+branches: \[feat-cmux-next\]$")
        self.assertRegex(text, r"(?m)^\s+types: \[completed\]$")
        self.assertIn("github.event.workflow_run.event == 'push'", text)
        self.assertIn("workflow_dispatch:", text)
        self.assertIn("scripts/cmux-next/request-nightly-next.sh --tree-ready", text)
        self.assertIn("cancel-in-progress: false", text)

    def test_no_workflow_reads_the_retired_decide_runner_variable(self) -> None:
        """CI_NIGHTLY_DECIDE_RUNNER named a Blacksmith pool and is deleted."""
        for path in sorted(WORKFLOWS.glob("*.yml")):
            with self.subTest(workflow=path.name):
                self.assertNotIn("CI_NIGHTLY_DECIDE_RUNNER", path.read_text(encoding="utf-8"))


# The only repository variables a nightly runs-on may read. Each must hold an owned glaeda- label, which
# scripts/ci/check_repo_variables.py (NIGHTLY_RUNNER_VARIABLES) checks against the live values every 15 minutes.
NIGHTLY_RUNNER_VARIABLES = ("CI_NIGHTLY_NEXT_BUILD_RUNNER", "CI_SIDE_LANE_RUNNER", "CI_SEED_TRUSTED_POOL")
# Variables a nightly runs-on may read only in a condition, never as a label.
NIGHTLY_CONDITION_VARIABLES = ("CI_PR_POOL_OWNED",)
# Picker outputs a nightly runs-on may use as a label: each comes from a picker that offers only owned labels,
# read from live runner lists. A picker output that can name Blacksmith (side_lane_placement.py's runner) is read
# only behind startsWith(..., 'glaeda-').
OWNED_PICKS = {
    "needs.pick-nightly-build-runner.outputs.owned", "needs.pick-nightly-build-runner.outputs.helper",
    "needs.pick-nightly-build-runner.outputs.dedicated", "needs.pick-nightly-sign-runner.outputs.owned",
    "needs.pick-train-runner.outputs.owned", "needs.pick-archive-runner.outputs.dedicated",
    "needs.route-visual-gate-nightly.outputs.runs_on", "needs.pick.outputs.runner",
}
GUARDED_PICKS = {"needs.pick.outputs.runner": "startsWith(needs.pick.outputs.runner, 'glaeda-') && needs.pick.outputs.runner"}
# sign_owned is a JSON runs-on array of owned labels (scripts/ci/signing_runner.py), read only through fromJSON.
JSON_PICKS = {"needs.pick-nightly-sign-runner.outputs.sign_owned"}
# Literal labels: the owned nightly-ops runners and the owned light side lane the cmux-tui nightly builds on.
OWNED_LITERALS = {OPS_LABEL, "glaeda-side-light-xcode-26.6"}
# GitHub-hosted, never Blacksmith, with the reason no owned Mac can do it.
HOSTED_EXCEPTIONS = {
    ("cmux-tui-nightly.yml", "publish-npm"): "npm provenance is issued only to a GitHub-hosted runner",
}
# A fork's own CI and a fork's pull request into manaflow-ai take GitHub-hosted runners: never Blacksmith, and
# never an owned Mac (fork code; tests/test_ci_fork_runner_routing.py). Neither is a nightly.
FORK_BRANCH = re.compile(r"github\.repository_owner != 'manaflow-ai' && '(?:ubuntu-24\.04|macos-26)' \|\| "
                         r"(?:github\.event_name == 'pull_request' && github\.event\.pull_request\.head\.repo\.full_name "
                         r"!= github\.repository && '(?:ubuntu-24\.04|macos-26)' \|\| )?")
DENIED = re.compile(r"blacksmith|vars\.(?:LINUX_RUNNER|LINUX_ARM64_RUNNER|MACOS_RUNNER\w*|WINDOWS_RUNNER|CI_CLOUD\w*|"
                    r"CI_TRUSTED_RUNNER|CI_PAID\w*)|\binputs\.\w*(?:runner|label|pool)\w*", re.IGNORECASE)


def nightly_jobs():
    """Every (workflow, job, runner values) of the nightly workflows and the reusable workflows they call."""
    import yaml
    for path in nightly_workflows():
        jobs = (yaml.safe_load(path.read_text(encoding="utf-8")) or {}).get("jobs") or {}
        for name, job in jobs.items():
            job = job or {}
            values = []
            if "runs-on" in job:
                values.append(("runs-on", job["runs-on"]))
            matrix = ((job.get("strategy") or {}).get("matrix") or {})
            if "matrix." in str(job.get("runs-on", "")):
                values.append(("matrix", matrix))
            for key, value in (job.get("with") or {}).items():
                if "runner" in key or "runs_on" in key:
                    values.append((f"with.{key}", value))
            yield path.name, name, job, values


def labels_of(value) -> set:
    if isinstance(value, dict):
        return set().union(*(labels_of(v) for v in value.values())) if value else set()
    if isinstance(value, list):
        return set().union(*(labels_of(v) for v in value)) if value else set()
    return resolve_labels(value, variables={"CI_CLOUD_OVERFLOW_SAVED": [OVERFLOW_RECORD]})


class NightlyNeverBlacksmith(unittest.TestCase):
    """No path routes a nightly job to Blacksmith: not a fallback, a re-run, the overflow switch, an input or a variable."""

    def test_no_nightly_runner_value_can_name_blacksmith(self) -> None:
        checked = 0
        for workflow, name, job, values in nightly_jobs():
            for where, value in values:
                checked += 1
                with self.subTest(job=f"{workflow}#{name}", field=where):
                    text = str(value)
                    self.assertNotRegex(text, DENIED, "nightlies never use Blacksmith (Lawrence, 2026-10-30)")
        self.assertGreater(checked, 80)

    def test_every_nightly_label_is_owned(self) -> None:
        for workflow, name, job, values in nightly_jobs():
            for where, value in values:
                key = (workflow, name)
                with self.subTest(job=f"{workflow}#{name}", field=where):
                    if key in HOSTED_EXCEPTIONS:
                        self.assertIn(str(value), ("ubuntu-latest", "ubuntu-24.04"))
                        continue
                    text = str(value)
                    for pick, guarded in GUARDED_PICKS.items():
                        if pick in text:
                            self.assertIn(guarded, text, f"{pick} can name Blacksmith; read it only as `{guarded}`")
                    for label in labels_of(value):
                        if isinstance(label, Unknown):
                            ref = label.name
                            ok = (ref in {f"vars.{v}" for v in NIGHTLY_RUNNER_VARIABLES} or ref in OWNED_PICKS
                                  or ref.startswith("fromjson(") and any(p in text for p in JSON_PICKS)
                                  or ref.startswith("matrix."))
                            self.assertTrue(ok, f"{workflow}#{name} can take {ref}, which is not an owned label source")
                        elif isinstance(label, str) and label:
                            if label in ("ubuntu-24.04", "macos-26") and FORK_BRANCH.match(text.removeprefix("${{ ")):
                                continue  # a fork pull request's GitHub-hosted runner (test_the_fork_branch_is_the_only_hosted_label)
                            self.assertTrue(label in OWNED_LITERALS or label.startswith("glaeda-"),
                                            f"{workflow}#{name} can take {label!r}")
                    for var in re.findall(r"vars\.([A-Z0-9_]+)", text):
                        self.assertIn(var, NIGHTLY_RUNNER_VARIABLES + NIGHTLY_CONDITION_VARIABLES,
                                      f"{workflow}#{name} reads vars.{var}")

    def test_the_fork_branch_is_the_only_hosted_label(self) -> None:
        for workflow, name, job, values in nightly_jobs():
            for where, value in values:
                if (workflow, name) in HOSTED_EXCEPTIONS or not isinstance(value, str):
                    continue
                with self.subTest(job=f"{workflow}#{name}", field=where):
                    rest = FORK_BRANCH.sub("", value)
                    self.assertNotRegex(rest, r"'(?:ubuntu|macos|windows)-[\w.-]+'")

    def test_no_nightly_job_is_a_blacksmith_twin(self) -> None:
        for workflow, name, job, values in nightly_jobs():
            with self.subTest(job=f"{workflow}#{name}"):
                self.assertNotIn("blacksmith", name.lower())

    def test_the_overflow_switch_never_writes_a_nightly_variable(self) -> None:
        sys.path.insert(0, str(ROOT / "scripts" / "ci"))
        import cloud_overflow_switch as switch
        managed = set(switch.OVERRIDABLE_VARIABLES) | set(switch.SWITCHED_VARIABLES) | set(switch.SIGNING_VARIABLES)
        managed |= {switch.RECORD_VARIABLE, switch.OVERRIDES_VARIABLE}
        self.assertFalse(managed & set(NIGHTLY_RUNNER_VARIABLES + NIGHTLY_CONDITION_VARIABLES))

    def test_the_live_check_covers_the_nightly_variables(self) -> None:
        sys.path.insert(0, str(ROOT / "scripts" / "ci"))
        import check_repo_variables
        self.assertEqual(tuple(check_repo_variables.NIGHTLY_RUNNER_VARIABLES), NIGHTLY_RUNNER_VARIABLES)

    def test_the_ops_runners_admit_every_workflow_that_names_them(self) -> None:
        sys.path.insert(0, str(ROOT / "scripts" / "ci"))
        import nightly_ops_runner
        users = set()
        for path in sorted(WORKFLOWS.glob("*.y*ml")):
            if OPS_LABEL in path.read_text(encoding="utf-8"):
                users.add(path.name)
        self.assertTrue(users)
        self.assertLessEqual(users, set(nightly_ops_runner.WORKFLOWS))

    def test_the_guard_catches_every_blacksmith_route(self) -> None:
        """Mutations: each must fail the guard (a guard that passes everything proves nothing)."""
        bad = [
            "${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || 'blacksmith-4vcpu-ubuntu-2404' }}",
            "${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || vars.MACOS_RUNNER_26 }}",
            "${{ vars.LINUX_RUNNER || 'cmux-nightly-ops' }}",
            "${{ github.run_attempt > 1 && 'Blacksmith-6vcpu-macos-26' || 'cmux-nightly-ops' }}",
            "${{ vars.CI_CLOUD_OVERFLOW_SAVED && 'x' || 'cmux-nightly-ops' }}",
            "${{ inputs.macos_runner || 'cmux-nightly-ops' }}",
        ]
        for value in bad:
            with self.subTest(value=value):
                self.assertRegex(value, DENIED)
        for value in ("${{ needs.x.outputs.alternate || 'cmux-nightly-ops' }}", "${{ vars.SOMETHING_NEW }}",
                      "${{ 'some-label' }}", "${{ needs.pick.outputs.runner || 'cmux-nightly-ops' }}"):
            with self.subTest(value=value):
                labels = labels_of(value)
                owned = all((isinstance(l, Unknown) and (l.name in OWNED_PICKS and l.name not in GUARDED_PICKS))
                            or l in OWNED_LITERALS for l in labels)
                guarded = all(g in value for p, g in GUARDED_PICKS.items() if p in value)
                self.assertFalse(owned and guarded, value)


if __name__ == "__main__":
    unittest.main()
