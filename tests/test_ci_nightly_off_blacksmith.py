#!/usr/bin/env python3
"""Nightly routing uses pooled capacity and never a reserved host, nor Blacksmith.

Native work takes an owned controller-managed Mac pool: the picker's idle Mac, else
our nightly-only minis (Lawrence, 2026-10-30: nightlies never use Blacksmith). Light
controls take a current fleet placement, else GitHub-hosted Ubuntu; secret-holding
Linux jobs take GitHub-hosted Ubuntu, the ephemeral runner the signing-secret rules
allow. A nightly may not name a runner-specific label or rely on the old dedicated
builder tuple.
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
from runs_on_labels import resolve_labels  # noqa: E402

OVERFLOW_RECORD = '{"probe":"blacksmith-4vcpu-ubuntu-2404"}'
SWITCH_OFF = {"CI_CLOUD_OVERFLOW_SAVED": []}
# The probe's runs-on reads the record's .probe, which the resolver does not model;
# the test still checks it names no macOS label.
OVERFLOW_UNREAD = ("ci-cloud-overflow-probe.yml#probe",)
# A Blacksmith Linux route: a literal label, or a read of one of its per-size pools (.github/runners.json `pools`).
BLACKSMITH_LINUX = re.compile(r"blacksmith-\d+vcpu-ubuntu|fromJSON\(vars\.RUNNER_POOLS\)\.linux_\d+")
LINUX_LABEL = re.compile(r"blacksmith-\d+vcpu-ubuntu-\d{4}|ubuntu-24\.04")
# The nightly jobs that hold no release secrets and need no Mac.
LIGHT_NIGHTLY_JOBS = ("resolve-nightly-cmux-tui-client", "resolve-nightly-ghostty-cli-helper",
                      "pick-nightly-build-runner", "prepare-nightly-variant-primary",
                      "prepare-nightly-variant",
                      "find-nightly-next-recovery")

# A runs-on term that can put a nightly job on our own fleet: the owned nightly slot or side lane, or a picker's or
# placement's owned output (pick-nightly-build-runner, pick-nightly-sign-runner, build-nightly-app's light placement).
FLEET_ROUTE = re.compile(r"vars\.CI_NIGHTLY_ONLY_RUNNER|vars\.CI_NIGHTLY_NEXT_BUILD_RUNNER|vars\.CI_SIDE_LANE_RUNNER|vars\.CI_LIGHT_LANE_RUNNER"
                         r"|needs\.[\w-]+\.outputs\.(?:owned|owned_pool|sign_owned|sign_owned_pool|early_[a-z_]+_runner|light_mini_runner|light_linux_runner|mini_runner|runs_on|helper|dedicated)\b"
                         r"|matrix\.")
# nightly.yml jobs whose only route is still Blacksmith Linux. Empty since nightlies left Blacksmith entirely
# (Lawrence, 2026-10-30; tests/test_nightly_never_blacksmith.py): the signer route's jobs, the publication jobs and
# the sign pick take GitHub-hosted Ubuntu, the rest our own runners. It stays as a ratchet: a nightly job that rides
# Blacksmith Linux alone fails test_no_new_nightly_job_rides_blacksmith_linux_alone.
BLACKSMITH_LINUX_ONLY_DEBT: frozenset[str] = frozenset()

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
                               "vars.LINUX_RUNNER": "blacksmith-16vcpu-ubuntu-2404",
                               "vars.RUNNER_POOLS": '{"linux_16":"blacksmith-16vcpu-ubuntu-2404","linux_32":"blacksmith-32vcpu-ubuntu-2404"}' }
                    with self.subTest(job=name, attempt=attempt, placement=placement_attempt):
                        # Without a placement: the nightly-only minis on every attempt and track, never
                        # hosted Ubuntu or Blacksmith (nightlies run only on our own Mac minis).
                        self.assertEqual(evaluate(expression, context), "glaeda-nightly-only-m4pro")
                        context["needs.decide.outputs.track"] = "nightly"
                        self.assertEqual(evaluate(expression, context), "glaeda-nightly-only-m4pro")
                        context["github.repository_owner"] = "fork-owner"
                        self.assertEqual(evaluate(expression, context), "ubuntu-24.04")
            # decide's mini placement on the all-nightly reservation, for this attempt only.
            for runner in ("cmux-nightly-reservation-control", "glaeda-side-std-xcode-26.6"):
                context = {"github.repository_owner": "manaflow-ai", "github.run_attempt": 1,
                           "needs.decide.outputs.track": "nightly-next",
                           "needs.decide.outputs.early_attempt": "1",
                           "needs.decide.outputs.early_mini_jobs": f" {name} ",
                           "needs.decide.outputs.early_mini_runner": runner}
                self.assertEqual(evaluate(expression, context), runner)
                self.assertEqual(evaluate(expression, {**context, "github.run_attempt": 2}),
                                 "glaeda-nightly-only-m4pro")

    def test_mini_jobs_install_gh_before_their_gh_calls(self) -> None:
        import yaml
        jobs = yaml.safe_load((WORKFLOWS / "nightly.yml").read_text())["jobs"]
        for name, first_gh_step in (("resolve-nightly-cmux-tui-client", "Wait through GitHub API rate limits in this job's gh calls"),
                                    ("find-nightly-next-recovery", "List newer pending nightly-next notarizations")):
            steps = jobs[name]["steps"]
            names = [step.get("name") for step in steps]
            with self.subTest(job=name):
                ensure = next(i for i, step in enumerate(steps)
                              if step.get("run") == "bash scripts/ci/nightly-steps/ensure-gh.sh")
                # Every runner: a mini may lack gh too (the script installs it with Homebrew there).
                self.assertNotIn("if", steps[ensure])
                self.assertLess(ensure, names.index("Wait through GitHub API rate limits in this job's gh calls"))
                self.assertLess(ensure, names.index(first_gh_step))
        script = (ROOT / "scripts/ci/nightly-steps/ensure-gh.sh").read_text()
        self.assertIn("apt-get install -y -q gh", script)
        self.assertIn("HOMEBREW_NO_AUTO_UPDATE=1 \"$brew\" install gh", script)
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

    def test_native_nightlies_follow_owned_pool_then_our_nightly_builders(self) -> None:
        text = nightly_expand((WORKFLOWS / "nightly.yml").read_text(encoding="utf-8"))
        job = text[text.index("\n  build-nightly-app:"):]
        runs_on = re.search(r"^    runs-on: (.+)$", job, re.MULTILINE).group(1)
        # nightly-next: an idle owned Mac (pick-nightly-build-runner), else the plain nightly-only pool.
        self.assertIn("needs.pick-nightly-build-runner.outputs.owned", runs_on)
        self.assertNotIn("needs.pick-nightly-build-runner.outputs.blacksmith", runs_on)
        self.assertNotIn("vars.MACOS_RUNNER_26", runs_on)
        self.assertNotIn("RUNNER_POOLS", runs_on)
        self.assertTrue(runs_on.endswith("|| vars.CI_NIGHTLY_ONLY_RUNNER || 'glaeda-nightly-only-m4pro' }}"), runs_on)

    def test_secret_bearing_nightlies_use_the_trusted_owned_pool(self) -> None:
        text = nightly_expand((WORKFLOWS / "nightly.yml").read_text(encoding="utf-8"))
        # After their owned pick, only glaeda's signing label: the nightly slots of minis enrolled for signing.
        owned = "|| vars.CI_NIGHTLY_SIGNING_POOL || 'glaeda-signing-xcode-26.6' }}"
        for name in ("sign-nightly-identity-legacy", "build-sign-notarize-nightly", "recover-nightly-next-notarization"):
            runs_on = re.search(r"^    runs-on: (.+)$", text[text.index(f"\n  {name}:"):], re.MULTILINE).group(1)
            with self.subTest(job=name):
                self.assertNotIn("blacksmith", runs_on)
                self.assertNotIn("RUNNER_POOLS", runs_on)
                self.assertNotIn("MACOS_RUNNER", runs_on)
                self.assertNotIn("vars.CI_SEED_TRUSTED_POOL", runs_on)
                self.assertTrue(runs_on.endswith(owned), runs_on)

    def test_prepare_runs_on_linux_and_executes_no_mach_o(self) -> None:
        """prepare-nightly-variant only moves and reads files, so it runs on Linux or an owned Mac.

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
        # Unplaced, our nightly-only minis (never Blacksmith); the steps run on Linux or a Mac alike.
        owned = "vars.CI_NIGHTLY_ONLY_RUNNER || 'glaeda-nightly-only-m4pro' }}"
        for name in ("prepare-nightly-variant-primary", "prepare-nightly-variant"):
            # Never fleet Linux: nightlies run only on our own Mac minis.
            expected = ("${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || "
                        + light.replace("{job}", name) + owned)
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


    def test_light_nightly_overflow_never_takes_blacksmith_without_a_fleet_pick(self) -> None:
        """A job keeps the label it was created with after the overflow switch clears.

        On 2026-10-28 the light nightly jobs, created while the overflow record was
        set, waited hours on blacksmith-6vcpu-macos-26 after the switch had cleared,
        and the NEXT feed fell more than two hours behind. They hold no release
        secrets, so with the record set or not they take a current mini placement,
        else our nightly-only minis, never hosted Ubuntu or Blacksmith (Lawrence,
        2026-10-30; only a fork's fallback names hosted Ubuntu). The prepare steps
        run on Linux or a Mac (Apple's lipo, the Mac's tar).
        """
        import yaml
        jobs = yaml.safe_load(nightly_expand((WORKFLOWS / "nightly.yml").read_text(encoding="utf-8")))["jobs"]
        owned = {"glaeda-nightly-only-m4pro"}
        for name in LIGHT_NIGHTLY_JOBS:
            with self.subTest(job=name):
                runs_on = jobs[name]["runs-on"]
                expected_tail = "|| vars.CI_NIGHTLY_ONLY_RUNNER || 'glaeda-nightly-only-m4pro' }}"
                self.assertTrue(runs_on.endswith(expected_tail), runs_on)
                self.assertNotIn("blacksmith", runs_on)
                self.assertNotIn("RUNNER_POOLS", runs_on)
                self.assertNotIn("LINUX_RUNNER", runs_on)
                self.assertNotIn("macos", runs_on)
                labels = resolve_labels(runs_on, variables={"CI_CLOUD_OVERFLOW_SAVED": [OVERFLOW_RECORD],
                                                            "CI_NIGHTLY_ONLY_RUNNER": sorted(owned)}, silent=("needs",))
                self.assertTrue(labels)
                for label in labels:
                    self.assertIsInstance(label, str, f"{name} can take an unread label {label!r}")
                    self.assertTrue(label == "ubuntu-24.04" or label in owned, f"{name} can take {label!r}")
                self.assertNotIn("secrets.APPLE", yaml.dump(jobs[name]))
                self.assertNotIn("secrets.CMUX_RELEASE_APP_KEY", yaml.dump(jobs[name]))
        for name in ("prepare-nightly-variant-primary", "prepare-nightly-variant"):
            steps = {step.get("name"): step for step in jobs[name]["steps"]}
            with self.subTest(job=name):
                self.assertTrue(steps["Put llvm-lipo on PATH as lipo"]["if"].startswith("runner.os == 'Linux' && "))
                restore = steps["Restore unsigned nightly products"]["run"]
                self.assertIn('if [ "$RUNNER_OS" = Linux ]; then', restore)

    def test_legacy_identity_target_takes_the_signer_route(self) -> None:
        """The feed compare picks the signing job's build: hosted Ubuntu on every attempt, never Blacksmith.

        Its fleet-Linux picker waited three minutes and then sent it to Blacksmith in every run
        (2026-11-02, runs 41412703950..41418619409), on the old feed's path.
        """
        import yaml
        from test_nightly_trusted_routing import evaluate, parse_expression
        jobs = yaml.safe_load(nightly_expand((WORKFLOWS / "nightly.yml").read_text()))["jobs"]
        self.assertNotIn("pick-legacy-identity-runner", jobs)
        job = jobs["legacy-identity-target"]
        # It holds the release App key without glaeda's exclusive class yet, so it waits on hosted Ubuntu
        # until the glaeda signing-jobs change lands (tests/test_nightly_owned_minis_only.py PENDING_GLAEDA).
        self.assertEqual(job["runs-on"], "${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || 'ubuntu-24.04' }}")
        source = parse_expression(job["runs-on"].removeprefix("${{").removesuffix("}}"))
        self.assertEqual(evaluate(source, {"github.repository_owner": "manaflow-ai", "github.run_attempt": 1}), "ubuntu-24.04")
        self.assertEqual(evaluate(source, {"github.repository_owner": "manaflow-ai", "github.run_attempt": 2}),
                         "ubuntu-24.04")
        self.assertEqual(evaluate(source, {"github.repository_owner": "someone", "github.run_attempt": 2}), "ubuntu-24.04")

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
                 if BLACKSMITH_LINUX.search(str((job or {}).get("runs-on") or ""))
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
                # On the nightly-only minis now, so never a hosted light job.
                self.assertNotIn(f"nightly.yml#{name}", declared)
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
                      "vars.MACOS_RUNNER_26 || fromJSON(vars.RUNNER_POOLS).macos_26 }}", jobs["canary"]["runs-on"])
        for name in ("pick", "verdict"):
            with self.subTest(job=name):
                self.assertRegex(jobs[name]["runs-on"], r"(?:'blacksmith-\d+vcpu-ubuntu-2404'|fromJSON\(vars\.RUNNER_POOLS\)\.linux_\d+) }}$")

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
