#!/usr/bin/env python3
"""Every nightly.yml job runs only on our own Mac minis.

Lawrence, 2026-10-30: nightlies run ONLY on our own Mac minis. Not Blacksmith
(tests/test_nightly_never_blacksmith.py), and not GitHub-hosted Ubuntu or macOS or the fleet's
GCP Linux VMs either. Run 41751864551 still put decide and sentry-dsyms-nightly on ubuntu-24.04
and the release-signer pool (signer-build, signer-app, signer-dmg-image, signer-dmg, and the
legacy-identity copies) on Linux.

1. Each job's runs-on, evaluated for manaflow-ai over sampled attempts, refs, events and picker
   outputs, names a glaeda label (or a variable that holds one). Lawrence, 2026-11-04: "Never move a
   nightly job to Blacksmith, a GitHub-hosted runner or another mini". HOSTED_TAIL_JOBS are the only
   exceptions, each with its reason, and this list may only shrink. Each one holds a release secret
   (so never the nightly mini's shared light runners) and runs only in the tail (run_tail: on nightly-next
   the dispatched run outside the push group), so a hosted queue never holds the push group or the
   feed: GitHub-hosted ubuntu-24.04 had 307 jobs queued, the oldest for 39 min, on 2026-11-08. On the
   trusted signing runner each would hold the whole Mac (glaeda's exclusive class) for a long or
   wait-bound stretch while the next run builds and signs there. Every job in the push run, and every
   short secret job, takes the trusted signing runner instead. HOSTED_LOOP_JOBS is Leo's override for one
   loop-run job, the GitHub release upload (2026-11-08: "no. if this is still a good idea, we can still do it."):
   it holds the release App key, so it runs on an ephemeral hosted VM, as publish-release-notes does with the
   same key, rather than holding the whole signing Mac; it never takes a mini or the whole-Mac claim.
2. The Linux release-signer pool is gone: the jobs, the sign_pool input and the
   CI_NIGHTLY_NEXT_SIGN_POOL switch. The Mac signers sign every nightly.
3. The fleet-Linux early admission is gone from decide: no step starts or reads it.
4. The secret-holding jobs glaeda already admits as exclusive hold the whole mini as the Mac
   signing jobs do: the claim gate first, the claim before any secret, a clean workdir, and an
   always() step that wipes this job's credentials and files.
5. The notarization recovery takes an owned pick of its own (signing_runner.py owned, held to its
   attempt), not the side lane.
6. ensure-gh.sh and reel-install-ffmpeg.sh work on a Mac (Homebrew), with no apt-get or sudo.
"""

from __future__ import annotations

import hashlib
import json
import os
import random
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_ci_fork_runner_routing import parse_expression  # noqa: E402
from test_nightly_trusted_routing import evaluate  # noqa: E402
import test_nightly_never_blacksmith as never_blacksmith  # noqa: E402
from test_nightly_never_blacksmith import JOBS, ROOT  # noqa: E402
from test_nightly_never_blacksmith import manaflow_route as fork_free_route  # noqa: E402
from test_ci_signing_owned_mac import CLAIM, CLAIM_GATE_ID, claim_gate_for, picker_ref_failures  # noqa: E402

import yaml  # noqa: E402

WORKFLOW_TEXT = (ROOT / ".github/workflows/nightly.yml").read_text(encoding="utf-8")
RAW = yaml.safe_load(WORKFLOW_TEXT)

# The only nightly.yml jobs on GitHub-hosted Ubuntu: secret jobs that run only in the tail, outside the push group,
# whose whole-Mac hold on the trusted signing runner would be long or wait-bound. job -> why it stays hosted.
HOSTED_TAIL_JOBS = {
    "sentry-dsyms-nightly": "a Sentry upload of 10.8 and 19.7 min (runs 41471126151, 41466468306)",
    "sign-release-notes": "a span fetch that waits through API rate limits (70 min), and release-notes.py's "
                          "openssl pkeyutl -rawin, which macOS's LibreSSL lacks",
    "publish-release-notes": "up to 130 min of publish-lease and API rate-limit waits",
    "publish-nightly-reel": "an ffmpeg render of up to 90 min",
}
# Leo's override (2026-11-08, "no. if this is still a good idea, we can still do it."): a loop-run job on GitHub-hosted
# Ubuntu. job -> why. Its whole-Mac hold on cmux15 (289-406 s a build, after 79-412 s queued behind keep-published-dsyms:
# runs 42547726872, 42552327203, 42555458535, 42563930397) kept the signer from the next sign; a hosted job queued
# 2-89 s in the same runs' tails. It holds the push group as before, so a hosted queue like 2026-11-08's 39 min would
# hold it too: the stated cost.
HOSTED_LOOP_JOBS = {
    "publish-nightly-next-github": "uploads only, with the release App key that publish-release-notes already takes to "
                                   "an ephemeral hosted VM; on the signer it held the whole Mac",
}
# A secret-free preflight on GitHub-hosted Ubuntu, ahead of decide. job -> why. It judges whether the labels the run
# would wait on (vars.CI_NIGHTLY_MINI, or the nightly-only label) have an online runner, so it must not wait on one of
# them itself: 2026-11-10 CI_NIGHTLY_MINI named cmux-lawrence-2-light, whose runners went offline at 00:45Z, and every
# job, decide first, sat queued for 3+ h while the dedicated nightly Macs were idle. It holds no secret and reads only
# vars.CI_RUNNER_STATE (scripts/ci/nightly_runner_preflight.py, tests/test_nightly_runner_preflight.py). Its cost: a
# hosted queue delays decide by that queue's wait.
HOSTED_PREFLIGHT_JOBS = {
    "runner-preflight": "fails the run in minutes when its routing label has no online runner; on that label it "
                        "would itself wait for hours",
}
# Jobs on our minis for nightly-next only. Every other track (classic, RC) goes GitHub-hosted through this
# short-circuit, as before #38596: its release uploads may wait out the API rate limit for up to 360 min, which must
# not hold the exclusive signing Mac. job -> why.
NIGHTLY_NEXT_ONLY_OWNED = {
    "republish-nightly-deltas": "classic and RC release uploads wait out the rate limit (360 min timeout)",
}
TRACK_HOSTED = "github.ref != 'refs/heads/nightly-next' && 'ubuntu-24.04' ||"
# Leo, 2026-11-10: "It's fine to sign on GitHub hosted tonight" (the only signer had no power). An operator switch:
# vars.CI_NIGHTLY_MINI_SIGNER set to exactly macos-26 sends the three signing jobs to a fresh GitHub-hosted macOS
# VM, and vars.CI_NIGHTLY_MINI_PUBLISHER set to exactly ubuntu-24.04 sends the three Linux publishers to hosted
# Ubuntu; any other value, or unset, leaves every route below as it was. Each variable is compared, never used as
# the label. These tests check the owned route behind it.
HOSTED_SIGNING_SWITCHES = {
    "build-sign-notarize-nightly": "vars.CI_NIGHTLY_MINI_SIGNER == 'macos-26' && 'macos-26' || ",
    "recover-nightly-next-notarization": "vars.CI_NIGHTLY_MINI_SIGNER == 'macos-26' && 'macos-26' || ",
    "generate-nightly-deltas": "vars.CI_NIGHTLY_MINI_SIGNER == 'macos-26' && 'macos-26' || ",
    "publish-nightly": "vars.CI_NIGHTLY_MINI_PUBLISHER == 'ubuntu-24.04' && 'ubuntu-24.04' || ",
    "keep-published-dsyms": "vars.CI_NIGHTLY_MINI_PUBLISHER == 'ubuntu-24.04' && 'ubuntu-24.04' || ",
    "republish-nightly-deltas": "vars.CI_NIGHTLY_MINI_PUBLISHER == 'ubuntu-24.04' && 'ubuntu-24.04' || ",
}


def manaflow_route(name: str) -> str:
    """The manaflow-ai route of a nightly-next run: past the fork, the other-track short-circuits and the
    operator's hosted signing switch."""
    route = fork_free_route(name)
    if name in HOSTED_SIGNING_SWITCHES:
        route = route.replace(HOSTED_SIGNING_SWITCHES[name], "", 1)
    return route.replace(TRACK_HOSTED, "", 1) if name in NIGHTLY_NEXT_ONLY_OWNED else route


# Secret jobs glaeda's SIGNING_JOBS gives the whole mini, that hold no signing keychain. The last three ran on
# GitHub-hosted Ubuntu until glaeda admitted them on the trusted signing runner; keep-published-dsyms holds the
# push group (it runs in the loop run), republish-nightly-deltas follows generate-nightly-deltas' own hold.
EXCLUSIVE_PUBLISHERS = ("promote-nightly-next", "publish-nightly",
                        "keep-published-dsyms", "republish-nightly-deltas", "promote-nightly-next-acked")
# Of those, the ones that need no sign pick: promote-nightly-next and its retired (if: false) acked twin share a route.
PROMOTE_ROUTE = ("promote-nightly-next", "promote-nightly-next-acked")
SIGNER = "glaeda-trusted-next-signing"
SIGNER_POOL = ("launch-smoke-nightly", "signer-build", "signer-app", "signer-dmg-image", "signer-dmg",
               "legacy-signer-app", "legacy-signer-dmg-image", "legacy-signer-dmg",
               "verify-nightly-identity-legacy-pool")
RECOVERY = ("recover-nightly-next-notarization", "verify-recovered-nightly-next")
# A label or variable that is not one of our minis: hosted, Blacksmith or fleet Linux.
NOT_OURS = re.compile(r"ubuntu-|macos-\d|windows-|blacksmith|cmux-fleet-linux", re.IGNORECASE)
OWNED_PICK = ("needs.find-nightly-next-recovery.outputs.attempt == github.run_attempt && "
              "needs.find-nightly-next-recovery.outputs.sign_owned && "
              "fromJSON(needs.find-nightly-next-recovery.outputs.sign_owned)")


def sample(source: str, rng: random.Random) -> dict:
    context = never_blacksmith.sample(source, rng)
    for ref in list(context):
        if ref == "needs.find-nightly-next-recovery.outputs.sign_owned":
            context[ref] = rng.choice((never_blacksmith.OWNED_LABEL, ""))
    return context


def steps(name: str) -> list[dict]:
    return [step for step in JOBS[name].get("steps") or [] if isinstance(step, dict)]


class EveryJobOnOurMinis(unittest.TestCase):
    def test_every_route_resolves_to_a_mini(self) -> None:
        rng = random.Random(41751864551)
        failures = {}
        for name, job in JOBS.items():
            if name in HOSTED_TAIL_JOBS or name in HOSTED_LOOP_JOBS or name in HOSTED_PREFLIGHT_JOBS or job.get("uses"):
                continue
            runs_on = str(job.get("runs-on", ""))
            if runs_on == "${{ needs.route-visual-gate-nightly.outputs.runs_on }}":
                continue  # cmux_next_media_runner.py --idle-now: an idle owned session runner, else the job skips
            if runs_on == "${{ matrix.pool }}":
                bad = [p for p in job["strategy"]["matrix"]["pool"]
                       if NOT_OURS.search(re.sub(r"github\.repository_owner != 'manaflow-ai' && '[^']*' \|\|", "", p))]
                if bad:
                    failures[name] = bad
                continue
            if not runs_on.startswith("${{"):
                if not runs_on or NOT_OURS.search(runs_on):
                    failures[name] = runs_on
                continue
            source = manaflow_route(name).removeprefix("${{").removesuffix("}}")
            expression = parse_expression(source)
            for _ in range(400):
                context = sample(source, rng)
                value = evaluate(expression, context)
                if not value or NOT_OURS.search(str(value)) or not re.search(r"glaeda", str(value)):
                    failures[name] = (value, {k: v for k, v in context.items() if v})
                    break
        self.assertEqual(sorted(failures), [], "\n".join(f"{k}: {v}" for k, v in sorted(failures.items())))

    def test_other_tracks_keep_the_hosted_route(self) -> None:
        for name in NIGHTLY_NEXT_ONLY_OWNED:
            with self.subTest(job=name):
                self.assertTrue(fork_free_route(name).lstrip("${ ").startswith(TRACK_HOSTED),
                                "a non-nightly-next track must not hold the signing Mac through its rate-limit waits")

    def test_the_hosted_signing_switch_is_only_on_the_signing_jobs(self) -> None:
        for name in JOBS:
            with self.subTest(job=name):
                route = str(JOBS[name].get("runs-on", ""))
                switches = route.count("CI_NIGHTLY_MINI_SIGNER") + route.count("CI_NIGHTLY_MINI_PUBLISHER")
                self.assertEqual(switches, 1 if name in HOSTED_SIGNING_SWITCHES else 0)
                if name in HOSTED_SIGNING_SWITCHES:
                    self.assertIn(HOSTED_SIGNING_SWITCHES[name], route)

    def test_only_the_listed_tail_jobs_are_hosted(self) -> None:
        hosted = {name for name in JOBS if not JOBS[name].get("uses") and NOT_OURS.search(manaflow_route(name))}
        self.assertEqual(hosted, set(HOSTED_TAIL_JOBS) | set(HOSTED_LOOP_JOBS) | set(HOSTED_PREFLIGHT_JOBS),
                         "a nightly job may not reach a GitHub-hosted runner")
        for name in HOSTED_PREFLIGHT_JOBS:
            with self.subTest(job=name):
                self.assertNotIn("secrets.", json.dumps(JOBS[name]), "the preflight holds no secret")
                # issues: write only, for the nightly-next-failure notice (the job's GITHUB_TOKEN; no secret).
                self.assertEqual(JOBS[name].get("permissions"), {"issues": "write"})
        for name in (*HOSTED_TAIL_JOBS, *HOSTED_LOOP_JOBS):
            with self.subTest(job=name):
                self.assertIn("secrets.", json.dumps(JOBS[name]), "a hosted job without a secret moves to the light runners")

    def test_the_hosted_loop_upload_never_reaches_a_mini(self) -> None:
        # Leo's override covers this one job only, and only on a hosted VM: no variable, pick or one-mini mode may put
        # the release App key on a mini without the whole-Mac claim, so its route is the literal hosted label.
        self.assertEqual(set(HOSTED_LOOP_JOBS), {"publish-nightly-next-github"})
        for name in HOSTED_LOOP_JOBS:
            job = JOBS[name]
            with self.subTest(job=name):
                self.assertEqual(str(job.get("runs-on")),
                                 "${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || 'ubuntu-24.04' }}")
                self.assertIn("secrets.CMUX_RELEASE_APP_KEY", json.dumps(job))
                self.assertIn("release-next", str(job.get("environment")))
                self.assertNotIn("pick-nightly-sign-runner", json.dumps(job))
                # It stays in the loop run, which the next decide reads (tests/test_nightly_next_tail_off_push_group).
                self.assertIn("needs.published-build.outputs.cross_run != 'true'", str(job.get("if")))
                ids = [step.get("id") for step in steps(name)]
                self.assertNotIn(CLAIM_GATE_ID, ids)
                self.assertFalse(any(CLAIM in str(step.get("run", "")) for step in steps(name)))

    def test_a_hosted_job_runs_only_in_the_tail(self) -> None:
        # The push run holds the push group until its last job ends: a hosted queue there delays the next build.
        # A hosted job runs only when published-build says the tail runs here (run_tail), or after a job that does.
        def tail_only(name: str, seen: frozenset = frozenset()) -> bool:
            condition = str(JOBS[name].get("if", ""))
            if "needs.published-build.outputs.run_tail == 'true'" in condition:
                return True
            return any(other not in seen and other in JOBS and tail_only(other, seen | {name})
                       for other in re.findall(r"needs\.([\w-]+)\.result == 'success'", condition))
        for name in HOSTED_TAIL_JOBS:
            with self.subTest(job=name):
                self.assertTrue(tail_only(name), f"{name} may run in the push run, which holds the push group")
                self.assertNotIn("always()", str(JOBS[name].get("if", "")))


class NoLinuxSignerPool(unittest.TestCase):
    def test_the_pool_jobs_are_gone(self) -> None:
        self.assertEqual([name for name in SIGNER_POOL if name in JOBS], [])
        for name, job in JOBS.items():
            needs = job.get("needs") or []
            needs = [needs] if isinstance(needs, str) else needs
            with self.subTest(job=name):
                self.assertFalse(set(needs) & set(SIGNER_POOL))
                self.assertFalse(re.search(r"needs\.(?:%s)\." % "|".join(map(re.escape, SIGNER_POOL)), json.dumps(job)))

    def test_no_switch_turns_it_on(self) -> None:
        dispatch = ((RAW.get("on") or RAW.get(True) or {}).get("workflow_dispatch") or {}).get("inputs") or {}
        self.assertNotIn("sign_pool", dispatch)
        self.assertNotIn("inputs.sign_pool", WORKFLOW_TEXT)
        self.assertNotIn("CI_NIGHTLY_NEXT_SIGN_POOL", WORKFLOW_TEXT)


class NoFleetLinuxAdmission(unittest.TestCase):
    def test_decide_starts_no_linux_admission(self) -> None:
        runs = " ".join(str(step.get("run", "")) for step in steps("decide"))
        self.assertNotIn("nightly_linux_admission.py", runs)
        self.assertNotIn("OVERFLOW_LINUX", json.dumps(JOBS["decide"]))

    def test_no_job_reads_a_linux_placement(self) -> None:
        for name in JOBS:
            with self.subTest(job=name):
                self.assertNotRegex(json.dumps(JOBS[name]),
                                    r"needs\.decide\.outputs\.early_(?:linux_\w+|admission_ready|resolve_\w+_runner|"
                                    r"find_\w+_runner|build_nightly_inputs_runner)\b"
                                    r"|needs\.build-nightly-app\.outputs\.light_linux_runner\b")
        self.assertNotIn("cmux-fleet-linux", WORKFLOW_TEXT)


class PublishersHoldTheWholeMini(unittest.TestCase):
    def test_route_is_the_owned_pool_held_to_its_attempt(self) -> None:
        # promote-nightly-next runs alone (a main dispatch, no build) and keeps its earlier route: the signer
        # refuses a dispatch (test_nightly_signing_on_cmux15.test_promote_keeps_its_earlier_route). The nightly-only
        # minis' admission (glaeda-nightly-only-admit) refuses every signing-class job, so no publisher may land there.
        for name in PROMOTE_ROUTE:
            self.assertEqual(manaflow_route(name),
                             "${{  vars.CI_NIGHTLY_MINI != '' && vars.CI_NIGHTLY_SIGN_RUNNER || "
                             "github.event_name == 'push' && github.ref == 'refs/heads/nightly-next' && "
                             "vars.CI_NIGHTLY_SIGN_RUNNER || "
                             "'glaeda-nightly-std-xcode-26.6' }}")
        for name in EXCLUSIVE_PUBLISHERS:
            with self.subTest(job=name):
                route = manaflow_route(name)
                if name not in PROMOTE_ROUTE:
                    self.assertIn("needs.pick-nightly-sign-runner.outputs.attempt == github.run_attempt && "
                                  "needs.pick-nightly-sign-runner.outputs.sign_owned_pool", route)
                    self.assertIn(f"vars.CI_NIGHTLY_MINI != '' && '{SIGNER}'", route)
                self.assertNotRegex(route, NOT_OURS)
                self.assertNotIn("CI_NIGHTLY_ONLY_RUNNER", route)
                self.assertNotIn("glaeda-nightly-only-m4pro", route)
                if name not in PROMOTE_ROUTE:
                    self.assertTrue(route.rstrip(" }").endswith(
                        "'glaeda-trusted-next-signing'"))

    def test_claim_gate_first_then_claim_and_clean_workdir_before_any_secret(self) -> None:
        for name in EXCLUSIVE_PUBLISHERS:
            with self.subTest(job=name):
                job_steps = steps(name)
                gate = job_steps[0]
                self.assertEqual(gate.get("id"), CLAIM_GATE_ID)
                self.assertEqual(str(gate.get("run", "")).strip(), claim_gate_for("nightly.yml").strip())
                self.assertFalse(set(gate) - {"name", "run", "shell", "id"})
                first_secret = next(i for i, step in enumerate(job_steps) if "secrets." in json.dumps(step))
                claim = next((i for i, step in enumerate(job_steps) if CLAIM in str(step.get("run", ""))), None)
                # Second, before any checkout: the workspace an earlier job left is emptied on an owned Mac.
                clean = job_steps[1]
                self.assertEqual(clean.get("id"), "clean-workdir")
                self.assertNotIn("if", clean)
                self.assertRegex(str(clean.get("run", "")), r'find "\$ws" -mindepth 1 -maxdepth 1 -exec rm -rf')
                self.assertIsNotNone(claim)
                self.assertLess(claim, first_secret)
                self.assertFalse(JOBS[name].get("env") and "secrets." in json.dumps(JOBS[name]["env"]))

    def test_credentials_are_wiped_after_the_job(self) -> None:
        for name in EXCLUSIVE_PUBLISHERS:
            with self.subTest(job=name):
                last = steps(name)[-1]
                self.assertEqual(last.get("id"), "wipe-credentials")
                self.assertEqual(str(last.get("if", "")), "always()")
                run = str(last.get("run", ""))
                self.assertIn('find "$tmp" -mindepth 1 -maxdepth 1', run)
                self.assertIn('find "$ws" -mindepth 1 -maxdepth 1 -exec rm -rf', run)


class OwnedWorkdirSteps(unittest.TestCase):
    """The clean and wipe steps, run: they empty the workspace (and the temp dir, but the runner's own) on an
    owned Mac, and touch nothing on an ephemeral runner."""

    def run_step(self, step: dict, runner: str) -> tuple[set, set]:
        with tempfile.TemporaryDirectory() as temp:
            ws, tmp = Path(temp) / "ws", Path(temp) / "tmp"
            for directory in (ws / "nightly-out", ws / ".publish-tooling", tmp / "gh-app-token", tmp / "_runner_file_commands"):
                directory.mkdir(parents=True)
            (ws / "appcast.xml").write_text("feed")
            (tmp / "gh-app-token" / "token").write_text("x")
            subprocess.run(["/bin/bash", "-e", "-c", str(step["run"])], check=True,
                           env={"PATH": "/usr/bin:/bin", "HOME": temp, "RUNNER_NAME": runner,
                                "GITHUB_WORKSPACE": str(ws), "RUNNER_TEMP": str(tmp)})
            return {p.name for p in ws.iterdir()}, {p.name for p in tmp.iterdir()}

    def test_clean_empties_the_workspace_on_an_owned_mac(self) -> None:
        clean = steps("publish-nightly")[1]
        self.assertEqual(self.run_step(clean, "glaeda-runner-cmux15-glaeda-nightly-only-3"),
                         (set(), {"gh-app-token", "_runner_file_commands"}))
        self.assertEqual(self.run_step(clean, "GitHub Actions 12")[0], {"nightly-out", ".publish-tooling", "appcast.xml"})

    def test_wipe_removes_tokens_and_files_but_the_runners_own(self) -> None:
        wipe = steps("publish-nightly")[-1]
        self.assertEqual(self.run_step(wipe, "glaeda-runner-cmux7s-glaeda-nightly-only-4"), (set(), {"_runner_file_commands"}))
        self.assertEqual(self.run_step(wipe, "GitHub Actions 12")[1], {"gh-app-token", "_runner_file_commands"})


class RecoveryTakesAnOwnedPick(unittest.TestCase):
    def test_find_recovery_picks_an_owned_mini(self) -> None:
        job = JOBS["find-nightly-next-recovery"]
        outputs = job.get("outputs") or {}
        self.assertEqual(str(outputs.get("attempt", "")).strip(), "${{ github.run_attempt }}")
        step_id = re.search(r"steps\.([\w-]+)\.outputs\.owned\b", str(outputs.get("sign_owned", "")))
        self.assertTrue(step_id, outputs.get("sign_owned"))
        pick = next(step for step in steps("find-nightly-next-recovery") if step.get("id") == step_id.group(1))
        self.assertIn("scripts/ci/signing_runner.py owned", str(pick.get("run", "")))
        self.assertNotIn("sign_runner", outputs)
        self.assertNotIn("sign_alternate", outputs)
        self.assertEqual(picker_ref_failures("find-nightly-next-recovery", job), [])

    def test_recovery_jobs_read_the_pick(self) -> None:
        for name in RECOVERY:
            with self.subTest(job=name):
                route = re.sub(r"\s+", " ", manaflow_route(name))
                self.assertIn(OWNED_PICK, route)
                self.assertNotIn("CI_SIDE_LANE_RUNNER", route)
                self.assertNotIn("'glaeda-std-xcode-26.6'", route)


def stub(directory: Path, name: str, body: str) -> None:
    path = directory / name
    path.write_text("#!/bin/bash\n" + body + "\n")
    path.chmod(path.stat().st_mode | stat.S_IEXEC)


class ToolInstallersWorkOnAMac(unittest.TestCase):
    def run_script(self, script: str, present: tuple[str, ...]) -> tuple[subprocess.CompletedProcess, str]:
        with tempfile.TemporaryDirectory() as temp:
            bin_dir, log = Path(temp) / "bin", Path(temp) / "calls.log"
            bin_dir.mkdir()
            for tool in ("bash", "cat", "chmod", "dirname", "mkdir", "grep", "tr", "head"):
                real = subprocess.run(["/usr/bin/which", tool], capture_output=True, text=True).stdout.strip()
                if real:
                    os.symlink(real, bin_dir / tool)
            stub(bin_dir, "uname", 'echo Darwin')
            for tool in ("sudo", "apt-get", "dpkg"):
                stub(bin_dir, tool, f'echo "{tool} $*" >> "{log}"; exit 1')
            stub(bin_dir, "brew", f'echo "brew $*" >> "{log}"\n'
                                  f'if [ "$1" = install ]; then shift; for t in "$@"; do '
                                  f'[ "$t" = fontconfig ] && t=fc-match; '
                                  f'printf "#!/bin/bash\\n" > "{bin_dir}/$t"; chmod +x "{bin_dir}/$t"; done; fi')
            for tool in present:
                stub(bin_dir, tool, "exit 0")
            result = subprocess.run(["/bin/bash", str(ROOT / script)], capture_output=True, text=True,
                                    env={"PATH": str(bin_dir), "HOME": temp})
            return result, log.read_text() if log.exists() else ""

    def test_ensure_gh_installs_with_brew(self) -> None:
        result, calls = self.run_script("scripts/ci/nightly-steps/ensure-gh.sh", ())
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("brew install gh", calls)
        self.assertNotRegex(calls, r"sudo|apt-get")

    def test_ensure_gh_keeps_an_installed_gh(self) -> None:
        result, calls = self.run_script("scripts/ci/nightly-steps/ensure-gh.sh", ("gh",))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(calls, "")

    def run_pinned_gh(self, sha256: str | None) -> tuple[subprocess.CompletedProcess, str, str, Path]:
        """ensure-gh.sh on a Linux x86_64 runner without gh: curl serves a local gh_<v>_linux_amd64.tar.gz.
        Returns the result, the calls log, the GITHUB_PATH file's text and the RUNNER_TEMP dir (deleted after)."""
        temp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, temp, True)
        bin_dir, log, gh_path = temp / "bin", temp / "calls.log", temp / "github_path"
        bin_dir.mkdir()
        for tool in ("bash", "cat", "chmod", "dirname", "mkdir", "grep", "tr", "head", "cut", "rm", "mv", "cp",
                     "tar", "gzip", "sha256sum", "shasum", "perl"):
            real = shutil.which(tool)
            if real:
                os.symlink(real, bin_dir / tool)
        stub(bin_dir, "uname", 'case "$1" in -m) echo x86_64 ;; *) echo Linux ;; esac')
        for tool in ("sudo", "apt-get", "dpkg", "brew"):
            stub(bin_dir, tool, f'echo "{tool} $*" >> "{log}"; exit 1')
        version = re.search(r"^GH_PIN_VERSION=(\S+)", (ROOT / "scripts/ci/nightly-steps/ensure-gh.sh").read_text(), re.M)[1]
        name = f"gh_{version}_linux_amd64"
        (temp / "src" / name / "bin").mkdir(parents=True)
        stub(temp / "src" / name / "bin", "gh", 'echo "gh version test"')
        archive = temp / f"{name}.tar.gz"
        subprocess.run(["tar", "-czf", str(archive), "-C", str(temp / "src"), name], check=True)
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        stub(bin_dir, "curl", f'echo "curl $*" >> "{log}"\n'
                              f'while [ $# -gt 0 ]; do [ "$1" = -o ] && cp "{archive}" "$2"; shift; done')
        runner_temp = temp / "runner"
        runner_temp.mkdir()
        result = subprocess.run(["/bin/bash", str(ROOT / "scripts/ci/nightly-steps/ensure-gh.sh")],
                                capture_output=True, text=True,
                                env={"PATH": str(bin_dir), "HOME": str(temp), "RUNNER_TEMP": str(runner_temp),
                                     "GITHUB_PATH": str(gh_path), "GH_PIN_URL": f"https://example.invalid/{name}.tar.gz",
                                     "GH_PIN_SHA256": sha256 if sha256 is not None else digest})
        return (result, log.read_text() if log.exists() else "",
                gh_path.read_text() if gh_path.exists() else "", runner_temp)

    def test_ensure_gh_takes_the_pinned_checksummed_release_first(self) -> None:
        result, calls, github_path, runner_temp = self.run_pinned_gh(None)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("from the pinned, sha256-checked release", result.stdout)
        self.assertIn("curl ", calls)
        self.assertNotRegex(calls, r"brew|sudo|apt-get")
        added = github_path.strip()
        self.assertTrue(added.startswith(str(runner_temp)), github_path)
        self.assertTrue(os.access(Path(added) / "gh", os.X_OK))

    def test_ensure_gh_refuses_a_release_with_the_wrong_sha256(self) -> None:
        result, calls, github_path, _ = self.run_pinned_gh("0" * 64)
        self.assertIn("not the pinned", result.stdout)
        self.assertEqual(github_path, "")
        # It falls back to the old route (apt here; every stub refuses), then fails loudly.
        self.assertIn("apt-get", calls)
        self.assertEqual(result.returncode, 1)
        self.assertIn("::error title=No GitHub CLI::", result.stdout)

    def test_ensure_gh_pins_every_runner_platform(self) -> None:
        script = (ROOT / "scripts/ci/nightly-steps/ensure-gh.sh").read_text()
        for platform in ("Darwin/arm64", "Darwin/x86_64", "Linux/x86_64", "Linux/aarch64"):
            self.assertRegex(script, re.escape(platform) + r"[^\n]*sum=[0-9a-f]{64}")

    def test_reel_ffmpeg_installs_with_brew(self) -> None:
        result, calls = self.run_script("scripts/ci/nightly-steps/reel-install-ffmpeg.sh", ())
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("brew install", calls)
        self.assertIn("ffmpeg", calls)
        self.assertNotRegex(calls, r"sudo|apt-get")

    def test_reel_ffmpeg_keeps_installed_tools(self) -> None:
        result, calls = self.run_script("scripts/ci/nightly-steps/reel-install-ffmpeg.sh", ("ffmpeg", "fc-match"))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(calls, "")


if __name__ == "__main__":
    unittest.main()
