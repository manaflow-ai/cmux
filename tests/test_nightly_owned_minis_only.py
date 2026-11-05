#!/usr/bin/env python3
"""Every nightly.yml job runs only on our own Mac minis.

Lawrence, 2026-10-30: nightlies run ONLY on our own Mac minis. Not Blacksmith
(tests/test_nightly_never_blacksmith.py), and not GitHub-hosted Ubuntu or macOS or the fleet's
GCP Linux VMs either. Run 41751864551 still put decide and sentry-dsyms-nightly on ubuntu-24.04
and the release-signer pool (signer-build, signer-app, signer-dmg-image, signer-dmg, and the
legacy-identity copies) on Linux.

1. Each job's runs-on, evaluated for manaflow-ai over sampled attempts, refs, events and picker
   outputs, names a glaeda label (or a variable that holds one). PENDING_GLAEDA lists the jobs that
   hold a release secret and that glaeda's exclusive class does not admit yet
   (teamleaderleo/glaeda scripts/glaeda-cmux-runner-hook SIGNING_JOBS): until glaeda gives them the
   whole mini they stay on hosted Ubuntu, and this list may only shrink.
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

import json
import os
import random
import re
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
from test_nightly_never_blacksmith import JOBS, ROOT, manaflow_route  # noqa: E402
from test_ci_signing_owned_mac import CLAIM, CLAIM_GATE_ID, claim_gate_for, picker_ref_failures  # noqa: E402

import yaml  # noqa: E402

WORKFLOW_TEXT = (ROOT / ".github/workflows/nightly.yml").read_text(encoding="utf-8")
RAW = yaml.safe_load(WORKFLOW_TEXT)

# Secret jobs glaeda does not admit as exclusive yet (signing-jobs.patch adds them); they keep hosted Ubuntu.
PENDING_GLAEDA = {
    "promote-nightly-next-acked", "keep-published-dsyms", "sentry-dsyms-nightly", "sign-release-notes",
    "publish-release-notes", "publish-nightly-reel", "publish-nightly-identity-legacy", "republish-nightly-deltas",
    "legacy-identity-target",
}
# Secret jobs glaeda's SIGNING_JOBS already gives the whole mini, that hold no signing keychain.
EXCLUSIVE_PUBLISHERS = ("promote-nightly-next", "publish-nightly", "publish-nightly-next-github",
                        "publish-nightly-next-github-names")
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
            if name in PENDING_GLAEDA or job.get("uses"):
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

    def test_pending_glaeda_jobs_are_only_those_that_still_need_it(self) -> None:
        hosted = {name for name in JOBS if NOT_OURS.search(manaflow_route(name))}
        self.assertLessEqual(hosted, PENDING_GLAEDA, "only the jobs glaeda does not admit yet may stay hosted")
        for name in PENDING_GLAEDA & set(JOBS):
            with self.subTest(job=name):
                self.assertIn("secrets.", json.dumps(JOBS[name]), "a pending job without a secret moves to the minis now")


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
        self.assertEqual(manaflow_route("promote-nightly-next"),
                         "${{  vars.CI_NIGHTLY_MINI != '' && vars.CI_NIGHTLY_SIGN_RUNNER || "
                         "github.event_name == 'push' && github.ref == 'refs/heads/nightly-next' && "
                         "vars.CI_NIGHTLY_SIGN_RUNNER || "
                         "vars.CI_NIGHTLY_NEXT_BUILD_RUNNER || 'glaeda-nightly-std-xcode-26.6' }}")
        for name in EXCLUSIVE_PUBLISHERS:
            with self.subTest(job=name):
                route = manaflow_route(name)
                if name != "promote-nightly-next":
                    self.assertIn("needs.pick-nightly-sign-runner.outputs.attempt == github.run_attempt && "
                                  "needs.pick-nightly-sign-runner.outputs.sign_owned_pool", route)
                self.assertNotRegex(route, NOT_OURS)
                self.assertNotIn("CI_NIGHTLY_ONLY_RUNNER", route)
                self.assertNotIn("glaeda-nightly-only-m4pro", route)
                if name != "promote-nightly-next":
                    self.assertTrue(route.rstrip(" }").endswith(
                        "vars.CI_NIGHTLY_SIGNING_POOL || 'glaeda-trusted-next-signing'"))

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
