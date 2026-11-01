#!/usr/bin/env python3
"""Nightly routing uses pooled capacity and never a reserved host.

Native work follows the dev-build route: an owned controller-managed Mac pool
first, then the trusted Blacksmith macOS pool. Control, verification and
publication steps use the Linux pool. A nightly may not name a runner-specific
label or rely on the old dedicated builder tuple.
"""

from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
from nightly_workflow_text import expand as nightly_expand  # noqa: E402  (moved step scripts back inline)

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
sys.path.insert(0, str(ROOT / "tests"))
from runs_on_labels import linux_runner_values, resolve_labels  # noqa: E402

OVERFLOW_RECORD = '{"probe":"blacksmith-4vcpu-ubuntu-2404"}'
SWITCH_OFF = {"CI_CLOUD_OVERFLOW_SAVED": []}
# The probe's runs-on reads the record's .probe, which the resolver does not model;
# the test still checks it names no macOS label.
OVERFLOW_UNREAD = ("ci-cloud-overflow-probe.yml#probe",)
LINUX_LABEL = re.compile(r"blacksmith-\d+vcpu-ubuntu-\d{4}|ubuntu-24\.04")
# The nightly jobs that hold no release secrets and need no Mac.
LIGHT_NIGHTLY_JOBS = ("resolve-nightly-cmux-tui-client", "resolve-nightly-ghostty-cli-helper",
                      "pick-nightly-build-runner", "prepare-nightly-variant-primary",
                      "prepare-nightly-variant",
                      "find-nightly-next-recovery")

# A runs-on term that can put a nightly job on our own fleet: the owned nightly slot or side lane, or a picker's or
# placement's owned output (pick-nightly-build-runner, pick-nightly-sign-runner, build-nightly-app's light placement).
FLEET_ROUTE = re.compile(r"vars\.CI_NIGHTLY_ONLY_RUNNER|vars\.CI_NIGHTLY_NEXT_BUILD_RUNNER|vars\.CI_SIDE_LANE_RUNNER|vars\.CI_LIGHT_LANE_RUNNER"
                         r"|needs\.[\w-]+\.outputs\.(?:owned|owned_pool|sign_owned|sign_owned_pool|early_[a-z_]+_runner|light_mini_runner|mini_runner|runs_on|helper|dedicated)\b"
                         r"|matrix\.")
# nightly.yml jobs whose only route is still Blacksmith Linux, as of 2026-10-31. Debt to move onto the fleet (portable
# placement, #29130/#29436), never to grow: a new nightly job on Blacksmith Linux alone fails, and an entry that has
# gained a fleet route (or no longer exists) must leave this list. decide left it first: run 41234993713 queued it on
# blacksmith-32vcpu-ubuntu-2404 with no fleet route, and every other nightly job waits on it.
BLACKSMITH_LINUX_ONLY_DEBT = frozenset({
    "promote-nightly-next", "await-release-surface-ack", "promote-nightly-next-acked",
    "attest-nightly-remote-daemon", "pick-nightly-sign-runner", "signer-build", "signer-app", "signer-app-notary",
    "signer-dmg", "route-visual-gate-nightly", "keep-published-dsyms",
    "publish-nightly-identity-legacy", "republish-nightly-deltas",
    "published-in", "sign-release-notes", "publish-release-notes", "publish-nightly-reel",
})

# Secret-free late bookkeeping and advisory verdicts have no fresh fleet lease.
# Only these centrally declared light jobs may bootstrap on hosted Linux.
PUBLICATION_POOL_JOBS = (
    "visual-gate-nightly-verdict", "report-visual-gate-nightly",
    "nightly-identity-legacy-published", "report-nightly-failure",
    "close-nightly-failure-issue",
)

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
    def test_resolver_and_recovery_use_overflow_without_current_placement(self) -> None:
        import yaml
        from test_nightly_trusted_routing import evaluate, parse_expression
        jobs = yaml.safe_load((WORKFLOWS / "nightly.yml").read_text())["jobs"]
        for name in ("resolve-nightly-cmux-tui-client", "find-nightly-next-recovery"):
            expression = parse_expression(jobs[name]["runs-on"].removeprefix("${{").removesuffix("}}"))
            for attempt in (1, 2, 3):
                for placement_attempt in ("", str(attempt - 1), str(attempt)):
                    context = {"github.repository_owner": "manaflow-ai", "github.run_attempt": attempt,
                               "needs.decide.outputs.track": "nightly-next",
                               "needs.decide.outputs.early_attempt": placement_attempt,
                               "vars.LINUX_RUNNER": "blacksmith-16vcpu-ubuntu-2404"}
                    with self.subTest(job=name, attempt=attempt, placement=placement_attempt):
                        self.assertEqual(evaluate(expression, context), "ubuntu-24.04" if attempt == 1 else "blacksmith-16vcpu-ubuntu-2404")
                        context["needs.decide.outputs.track"] = "nightly"
                        self.assertEqual(evaluate(expression, context), "blacksmith-16vcpu-ubuntu-2404")
                        context["github.repository_owner"] = "fork-owner"
                        self.assertEqual(evaluate(expression, context), "ubuntu-24.04")
            for runner in ("cmux-nightly-reservation-control", "glaeda-side-std-xcode-26.6"):
                output = name.replace("cmux-", "").replace("-", "_")
                context = {"github.repository_owner": "manaflow-ai", "github.run_attempt": 1,
                           "needs.decide.outputs.track": "nightly-next",
                           "needs.decide.outputs.early_attempt": "1",
                           f"needs.decide.outputs.early_{output}_runner": runner}
                self.assertEqual(evaluate(expression, context), runner)

    def test_fleet_linux_fallback_jobs_install_gh_before_their_gh_calls(self) -> None:
        import yaml
        jobs = yaml.safe_load((WORKFLOWS / "nightly.yml").read_text())["jobs"]
        for name, first_gh_step in (("resolve-nightly-cmux-tui-client", "Wait through GitHub API rate limits in this job's gh calls"),
                                    ("find-nightly-next-recovery", "List newer pending nightly-next notarizations")):
            steps = jobs[name]["steps"]
            names = [step.get("name") for step in steps]
            with self.subTest(job=name):
                ensure = next(i for i, step in enumerate(steps)
                              if step.get("run") == "bash scripts/ci/nightly-steps/ensure-gh.sh")
                self.assertEqual(steps[ensure].get("if"), "runner.os == 'Linux'")
                self.assertLess(ensure, names.index("Wait through GitHub API rate limits in this job's gh calls"))
                self.assertLess(ensure, names.index(first_gh_step))
        script = (ROOT / "scripts/ci/nightly-steps/ensure-gh.sh").read_text()
        self.assertIn("apt-get install -y -q gh", script)
        self.assertIn("https://cli.github.com/packages", script)
        self.assertIn("::error", script)

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

    def test_native_nightlies_follow_owned_pool_then_blacksmith(self) -> None:
        text = nightly_expand((WORKFLOWS / "nightly.yml").read_text(encoding="utf-8"))
        job = text[text.index("\n  build-nightly-app:"):]
        runs_on = re.search(r"^    runs-on: (.+)$", job, re.MULTILINE).group(1)
        # nightly-next: an idle owned Mac, else the moving Blacksmith label (pick-nightly-build-runner).
        self.assertIn("needs.pick-nightly-build-runner.outputs.owned", runs_on)
        self.assertIn("needs.pick-nightly-build-runner.outputs.blacksmith", runs_on)
        self.assertIn("vars.MACOS_RUNNER_26", runs_on)
        self.assertIn("blacksmith-6vcpu-macos-26", runs_on)

    def test_secret_bearing_nightlies_use_the_trusted_owned_pool(self) -> None:
        text = nightly_expand((WORKFLOWS / "nightly.yml").read_text(encoding="utf-8"))
        legacy = re.search(r"^    runs-on: (.+)$", text[text.index("\n  sign-nightly-identity-legacy:"):], re.MULTILINE).group(1)
        self.assertNotIn("blacksmith", legacy)
        self.assertTrue(legacy.endswith("|| vars.CI_NIGHTLY_NEXT_BUILD_RUNNER || vars.CI_SIDE_LANE_RUNNER || 'glaeda-std-xcode-26.6' }}"), legacy)
        for name in ("build-sign-notarize-nightly",):
            job = text[text.index(f"\n  {name}:"):]
            match = re.search(r"^    runs-on: (.+)$", job, re.MULTILINE)
            with self.subTest(job=name):
                self.assertNotIn("vars.CI_SEED_TRUSTED_POOL", match.group(1))
                self.assertIn("vars.MACOS_RUNNER_26", match.group(1))
                self.assertIn("blacksmith-6vcpu-macos-26", match.group(1))
                self.assertNotIn("vars.CI_SIDE_LANE_RUNNER", match.group(1))

    def test_prepare_runs_on_linux_and_executes_no_mach_o(self) -> None:
        """prepare-nightly-variant only moves and reads files, so it runs on Linux.

        The cmux-tui client install (it runs the client), Apple's strip and the
        capability probes run in build-nightly-app; the theme picker regression
        and the diff sidecar handshake (they run Mach-O) run on the signed app
        in verify-signed-nightly. llvm-lipo thins, which gives Apple lipo's bytes.
        """
        import yaml
        document = yaml.safe_load(nightly_expand((WORKFLOWS / "nightly.yml").read_text(encoding="utf-8")))
        jobs = document["jobs"]
        light = ("needs.build-nightly-app.outputs.light_attempt == format('{0}', github.run_attempt) && "
                 "contains(needs.build-nightly-app.outputs.light_mini_jobs, ' {job} ') && "
                 "needs.build-nightly-app.outputs.light_mini_runner || ")
        linux = ("vars.LINUX_RUNNER == 'blacksmith-16vcpu-ubuntu-2404' && "
                 "'blacksmith-16vcpu-ubuntu-2404' || 'blacksmith-32vcpu-ubuntu-2404' }}")
        for name in ("prepare-nightly-variant-primary", "prepare-nightly-variant"):
            expected = ("${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || "
                        + light.replace("{job}", name))
            if name == "prepare-nightly-variant":
                expected += ("needs.prepare-nightly-variant-primary.result == 'success' && "
                             "(vars.LINUX_RUNNER == 'blacksmith-16vcpu-ubuntu-2404' && "
                             "'blacksmith-16vcpu-ubuntu-2404' || 'blacksmith-32vcpu-ubuntu-2404') || "
                             "vars.LINUX_RUNNER == 'blacksmith-16vcpu-ubuntu-2404' && "
                             "'blacksmith-32vcpu-ubuntu-2404' || 'blacksmith-16vcpu-ubuntu-2404' }}")
            else:
                expected += linux
            with self.subTest(job=name):
                self.assertEqual(jobs[name]["runs-on"], expected)
        moved_out = ("install-cmux-tui-client.sh", "strip-release-bundle.sh", "write-cmux-tui-version.sh",
                     "check-daemon-capabilities.sh", "test_bundled_ghostty_theme_picker_helper.sh",
                     "verify-diff-sidecar-artifact.sh", "select-ci-xcode.sh", "ditto ", "otool", "codesign")
        for name in ("prepare-nightly-variant-primary", "prepare-nightly-variant"):
            runs = "\n".join(step.get("run", "") for step in jobs[name]["steps"])
            names = [step.get("name", "") for step in jobs[name]["steps"]]
            with self.subTest(job=name):
                for needle in moved_out:
                    self.assertNotIn(needle, runs)
                self.assertIn("Put llvm-lipo on PATH as lipo", names)
                self.assertIn("Require the cmux-tui client build-nightly-app bundled", names)
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


    def test_light_nightly_overflow_stays_on_linux_without_a_fleet_pick(self) -> None:
        """A job keeps the label it was created with after the overflow switch clears.

        On 2026-10-28 the light nightly jobs, created while the overflow record was
        set, waited hours on blacksmith-6vcpu-macos-26 after the switch had cleared,
        and the NEXT feed fell more than two hours behind. They hold no release
        secrets and need no Mac, so with the record set or not they run on Linux:
        LINUX_RUNNER (the switch's Linux failover while it is on), else Blacksmith Linux.
        Their steps still run on a Mac (Apple's lipo, the Mac's tar).
        """
        import yaml
        jobs = yaml.safe_load(nightly_expand((WORKFLOWS / "nightly.yml").read_text(encoding="utf-8")))["jobs"]
        linux = linux_runner_values()
        for name in LIGHT_NIGHTLY_JOBS:
            with self.subTest(job=name):
                runs_on = jobs[name]["runs-on"]
                # A member of the declared set: 16 vCPU when LINUX_RUNNER names it, else 32; a job
                # holding a secret takes the literal (the signing-keychain guard).
                # The sign pick takes GitHub-hosted Ubuntu, then Blacksmith Linux 4 vCPU on a re-run
                # (tests/test_nightly_trusted_routing.py, the signer route).
                self.assertTrue("vars.LINUX_RUNNER == 'blacksmith-16vcpu-ubuntu-2404' && 'blacksmith-16vcpu-ubuntu-2404' || " in runs_on
                                or runs_on.endswith("|| 'blacksmith-32vcpu-ubuntu-2404' }}") and "LINUX_RUNNER" not in runs_on
                                or name == "pick-nightly-sign-runner"
                                and runs_on.endswith("github.run_attempt > 1 && 'blacksmith-4vcpu-ubuntu-2404' || 'ubuntu-24.04' }}"),
                                runs_on)
                self.assertNotRegex(runs_on, r"vars\.LINUX_RUNNER \|\|")
                self.assertNotIn("macos", runs_on)
                labels = resolve_labels(runs_on, variables={"CI_CLOUD_OVERFLOW_SAVED": [OVERFLOW_RECORD],
                                                            "LINUX_RUNNER": sorted(linux)}, silent=("needs",))
                self.assertTrue(labels)
                for label in labels:
                    self.assertIsInstance(label, str, f"{name} can take an unread label {label!r}")
                    self.assertTrue(label in linux or LINUX_LABEL.fullmatch(label),
                                    f"{name} can take {label!r}")
                self.assertNotIn("secrets.APPLE", yaml.dump(jobs[name]))
                self.assertNotIn("secrets.CMUX_RELEASE_APP_KEY", yaml.dump(jobs[name]))
        for name in ("prepare-nightly-variant-primary", "prepare-nightly-variant"):
            steps = {step.get("name"): step for step in jobs[name]["steps"]}
            with self.subTest(job=name):
                self.assertTrue(steps["Put llvm-lipo on PATH as lipo"]["if"].startswith("runner.os == 'Linux' && "))
                restore = steps["Restore unsigned nightly products"]["run"]
                self.assertIn('if [ "$RUNNER_OS" = Linux ]; then', restore)

    def test_legacy_identity_target_uses_fresh_linux_placement(self) -> None:
        import yaml
        from test_nightly_trusted_routing import evaluate, parse_expression
        jobs = yaml.safe_load(nightly_expand((WORKFLOWS / "nightly.yml").read_text()))["jobs"]
        job = jobs["legacy-identity-target"]
        picker = jobs["pick-legacy-identity-runner"]
        self.assertEqual(set(picker["needs"]), set(job["needs"]) - {"pick-legacy-identity-runner"})
        self.assertEqual(picker["if"], job["if"])
        source = parse_expression(job["runs-on"].removeprefix("${{").removesuffix("}}"))
        prefix = "needs.pick-legacy-identity-runner.outputs."
        context = {"github.repository_owner": "manaflow-ai", "github.run_attempt": 1, prefix + "attempt": "1",
                   prefix + "runs_on": "cmux-fleet-linux-x64", prefix + "overflow": "blacksmith-4vcpu-ubuntu-2404",
                   prefix + "alternate": "blacksmith-16vcpu-ubuntu-2404"}
        self.assertEqual(evaluate(source, context), "cmux-fleet-linux-x64")
        self.assertEqual(evaluate(source, {**context, prefix + "runs_on": ""}), "blacksmith-4vcpu-ubuntu-2404")
        self.assertEqual(evaluate(source, {**context, "github.run_attempt": 2}), "blacksmith-16vcpu-ubuntu-2404")
        self.assertEqual(evaluate(source, {"github.repository_owner": "manaflow-ai", "github.run_attempt": 1, "vars.LINUX_RUNNER": "macos-26"}), "blacksmith-4vcpu-ubuntu-2404")
        self.assertEqual(evaluate(source, {"github.repository_owner": "manaflow-ai", "github.run_attempt": 2}), "blacksmith-8vcpu-ubuntu-2404")
        placement = next(step for step in picker["steps"] if step.get("id") == "place")
        self.assertEqual(placement["env"]["LINUX_ONLY"], "legacy-identity-target")
        self.assertEqual(placement["env"]["REQUIRE_LIVE_CAPACITY"], "1")
        self.assertEqual(placement["env"]["NIGHTLY_WAIT_FOR_FLEET"], "1")

    def test_nightly_never_queues_on_unverified_generic_fleet_label(self) -> None:
        """Fleet admission supplies unique reservations, never an unserved pool label."""
        import yaml
        jobs = yaml.safe_load(nightly_expand((WORKFLOWS / "nightly.yml").read_text(encoding="utf-8")))["jobs"]
        for name, job in jobs.items():
            with self.subTest(job=name):
                self.assertNotIn("cmux-fleet-linux-x64", str((job or {}).get("runs-on", "")))

    def test_no_new_nightly_job_rides_blacksmith_linux_alone(self) -> None:
        """No pins: a nightly job needs a fleet route ahead of its Blacksmith Linux label.

        The light-job test above only checked that these jobs stay on Linux, so decide's literal
        blacksmith-32vcpu-ubuntu-2404 pin passed it. This ratchets BLACKSMITH_LINUX_ONLY_DEBT down."""
        import yaml
        jobs = yaml.safe_load(nightly_expand((WORKFLOWS / "nightly.yml").read_text(encoding="utf-8")))["jobs"]
        import json
        light = json.loads((ROOT / ".github/runners.json").read_text()).get("hosted_light_jobs", {})
        alone = {name for name, job in jobs.items()
                 if re.search(r"blacksmith-\d+vcpu-ubuntu", str((job or {}).get("runs-on") or ""))
                 and not FLEET_ROUTE.search(str(job.get("runs-on")))
                 and not (f"nightly.yml#{name}" in light
                          and "github.run_attempt == 1 && 'ubuntu-24.04'" in str(job.get("runs-on")))}
        self.assertEqual(sorted(alone - BLACKSMITH_LINUX_ONLY_DEBT), [],
                         "these nightly jobs can only take Blacksmith Linux: give them a fleet route first")
        self.assertEqual(sorted(BLACKSMITH_LINUX_ONLY_DEBT - alone), [],
                         "these jobs left Blacksmith-only routing (or are gone): drop them from the debt list")
        self.assertIn("decide", jobs)
        self.assertNotIn("decide", BLACKSMITH_LINUX_ONLY_DEBT)

    def test_publication_controls_use_declared_light_routing_without_stale_dependencies(self) -> None:
        import json
        import yaml
        jobs = yaml.safe_load(nightly_expand((WORKFLOWS / "nightly.yml").read_text(encoding="utf-8")))["jobs"]
        declared = json.loads((ROOT / ".github/runners.json").read_text())["hosted_light_jobs"]
        for name in PUBLICATION_POOL_JOBS:
            with self.subTest(job=name):
                self.assertIn(f"nightly.yml#{name}", declared)
                self.assertNotIn("pick-nightly-build-runner", jobs[name]["needs"])
                self.assertNotIn("needs.pick-nightly-build-runner.outputs.", jobs[name]["runs-on"])
                self.assertNotIn("environment", jobs[name])

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

    def test_the_canary_takes_the_owned_side_label_then_blacksmith(self) -> None:
        import yaml
        jobs = yaml.safe_load((WORKFLOWS / "nightly-next-canary.yml").read_text(encoding="utf-8"))["jobs"]
        self.assertIn("vars.CI_PR_POOL_OWNED == '1' && github.run_attempt == 1 && vars.CI_SIDE_LANE_RUNNER || "
                      "vars.MACOS_RUNNER_26 || 'blacksmith-6vcpu-macos-26' }}", jobs["canary"]["runs-on"])
        for name in ("pick", "verdict"):
            with self.subTest(job=name):
                self.assertRegex(jobs[name]["runs-on"], r"'blacksmith-\d+vcpu-ubuntu-2404' }}$")

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


if __name__ == "__main__":
    unittest.main()
