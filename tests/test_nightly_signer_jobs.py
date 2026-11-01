#!/usr/bin/env python3
"""nightly.yml's release-pool signer jobs (signer-*): opt-in, the macOS signer
job as their fallback, and the secrets kept in the release-pool jobs; and
verify_appcast_item.py checks the Sparkle item against the pinned key.

Only signer-dmg, after the DMG is notarized and its appcast checked, hands
output on, under the names the macOS signer job uses. That job runs whenever
signer-dmg did not pass, so a failed, skipped or not-opted-in pool run signs as
before, and exactly one of the two produces what verify-final-dmg-nightly and
publish-nightly read. The pool path has one Mac job (signer-dmg-image) before
that decision, which also runs verify-signed-nightly's checks of the app (that
job runs for the macOS signer's app only); the final DMG's Mac checks run in
verify-final-dmg-nightly, which publish needs anyway.
"""

from __future__ import annotations

import base64
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))
from nightly_workflow_text import nightly_text  # noqa: E402

WORKFLOW = yaml.safe_load(nightly_text())
JOBS = WORKFLOW["jobs"]
SIGNER_JOBS = ("signer-build", "signer-app", "signer-app-notary", "signer-dmg-image", "signer-dmg")
SECRET_JOBS = {"signer-app", "signer-app-notary", "signer-dmg"}
VERIFY = ROOT / "scripts/ci/release-signer/verify_appcast_item.py"
FINAL_DMG = "cmux-nightly-next-signer-final-dmg-${{ needs.resolve-nightly-cmux-tui-client.outputs.build_short_sha }}"
TIP_APPCAST = ROOT / "scripts/ci/tip_appcast_linux.py"


def needs(job: dict) -> list[str]:
    value = job.get("needs") or []
    return [value] if isinstance(value, str) else list(value)


class Wiring(unittest.TestCase):
    def test_only_the_input_or_the_variable_turns_them_on(self):
        gate = JOBS["signer-build"]["if"]
        self.assertIn("needs.decide.outputs.track == 'nightly-next'", gate)
        self.assertIn("(inputs.sign_pool || vars.CI_NIGHTLY_NEXT_SIGN_POOL == '1')", gate)
        on = WORKFLOW.get("on") or WORKFLOW.get(True)
        self.assertEqual(on["workflow_dispatch"]["inputs"]["sign_pool"]["default"], False)
        # Every other signer job runs only after signer-build (directly or through another).
        for name in SIGNER_JOBS[1:]:
            with self.subTest(job=name):
                self.assertTrue(set(needs(JOBS[name])) & set(SIGNER_JOBS), name)
                self.assertNotIn("always()", str(JOBS[name].get("if", "")))

    def test_the_macos_signer_is_the_fallback_and_one_path_hands_on(self):
        signed = "(needs.build-sign-notarize-nightly.result == 'success' || needs.signer-dmg.result == 'success')"
        fallback = JOBS["build-sign-notarize-nightly"]
        self.assertIn("signer-dmg", needs(fallback))
        self.assertTrue(fallback["if"].startswith("!cancelled() && "))
        self.assertIn("needs.signer-dmg.result != 'success'", fallback["if"])
        # Its own status check replaces the implicit success(), so it names every other need's success.
        for need in needs(fallback):
            if need != "signer-dmg":
                self.assertIn(f"needs.{need}.result == 'success'", fallback["if"])
        for name in ("verify-final-dmg-nightly", "publish-nightly"):
            with self.subTest(job=name):
                self.assertIn("signer-dmg", needs(JOBS[name]))
                self.assertIn(signed, JOBS[name]["if"])
                self.assertNotRegex(JOBS[name]["if"], r"\(needs\.build-sign-notarize-nightly\.result == 'success' &&")
        # verify-signed-nightly checks the macOS signer's app only; signer-dmg-image checks a
        # pool-signed one (signer-verify-signed.sh), and publish takes signer-dmg's success for it.
        verify = JOBS["verify-signed-nightly"]
        self.assertIn("signer-dmg", needs(verify))
        self.assertTrue(verify["if"].startswith("!cancelled() && needs.build-sign-notarize-nightly.result == 'success' && "
                                                "needs.signer-dmg.result != 'success' && "), verify["if"])
        self.assertIn("(needs.signer-dmg.result == 'success' || needs.verify-signed-nightly.result == 'success')",
                      JOBS["publish-nightly"]["if"])
        self.assertIn("OWN_VERIFIED: ${{ needs.signer-dmg.result == 'success' && 'success' || needs.verify-signed-nightly.result }}",
                      yaml.safe_dump(JOBS["publish-nightly"], width=1000))
        self.assertIn("signer-dmg-image", needs(JOBS["signer-dmg"]))
        # A pool run that passed reads as the job's own success in publish's source pick.
        self.assertIn("(needs.build-sign-notarize-nightly.result == 'success' || needs.signer-dmg.result == 'success') && 'success' || needs.build-sign-notarize-nightly.result",
                      yaml.safe_dump(JOBS["publish-nightly"], width=1000))
        # Only signer-dmg is needed outside the signer jobs; the failure report and its close
        # never need a signer job, so a pool run the fallback covered raises no failure issue.
        for name, job in JOBS.items():
            if name in SIGNER_JOBS:
                continue
            with self.subTest(job=name):
                self.assertLessEqual(set(needs(job)) & set(SIGNER_JOBS), {"signer-dmg"})
        for name in ("report-nightly-failure", "close-nightly-failure-issue"):
            self.assertFalse(set(needs(JOBS[name])) & set(SIGNER_JOBS), name)

    def test_signer_dmg_hands_on_only_after_every_check(self):
        steps = JOBS["signer-dmg"]["steps"]
        uploads = [i for i, s in enumerate(steps) if "upload-artifact" in str(s.get("uses", ""))]
        checks = [i for i, s in enumerate(steps) if "run" in s]
        self.assertTrue(uploads and checks)
        self.assertGreater(min(uploads), max(checks))
        names = {steps[i]["with"]["name"] for i in uploads}
        self.assertEqual(names, {"cmux-nightly-variant-arm64", FINAL_DMG})
        # Never replace what the macOS job uploaded: the verify jobs may already have passed on it, and a
        # rerun of failed jobs would not run them again on the replacement.
        for i in uploads:
            self.assertNotIn("overwrite", steps[i]["with"], steps[i]["with"]["name"])
        # "Re-run failed jobs" after a pool failure also reruns the jobs that need signer-dmg, even when
        # they passed: each of their uploads must take the place of its earlier one in this run.
        for job in ("build-sign-notarize-nightly", "verify-final-dmg-nightly", "publish-nightly"):
            for step in JOBS[job]["steps"]:
                name = str((step.get("with") or {}).get("name", ""))
                if "upload-artifact" not in str(step.get("uses", "")) or "github.run_attempt" in name:
                    continue
                self.assertIs(step["with"].get("overwrite"), True, f"{job}: {name}")
        # The macOS job may replace what a pool run uploaded before it failed.
        for step in JOBS["build-sign-notarize-nightly"]["steps"]:
            name = str((step.get("with") or {}).get("name", ""))
            if "upload-artifact" in str(step.get("uses", "")) and (name.startswith("cmux-nightly-variant-") or "-signed-app-" in name):
                self.assertIs(step["with"].get("overwrite"), True, name)

    def test_secrets_stay_in_the_release_pool_jobs_of_the_release_environment(self):
        for name in SIGNER_JOBS:
            job = JOBS[name]
            text = yaml.safe_dump(job)
            with self.subTest(job=name):
                if name in SECRET_JOBS:
                    self.assertEqual(job["environment"], "${{ needs.decide.outputs.environment }}")
                    self.assertIn("needs.pick-nightly-sign-runner.outputs.linux", job["runs-on"])
                    self.assertIn("linux_alternate", job["runs-on"])
                    self.assertNotIn("macos", job["runs-on"])
                    self.assertNotIn("secrets.", yaml.safe_dump(job.get("env") or {}))
                else:
                    self.assertNotIn("environment", job)
                    self.assertNotIn("secrets.", text)

    def test_signer_compiler_uses_the_blacksmith_linux_set(self):
        runs_on = JOBS["signer-build"]["runs-on"]
        self.assertIn("needs.pick-nightly-sign-runner.outputs.attempt == github.run_attempt", runs_on)
        self.assertIn("needs.pick-nightly-sign-runner.outputs.linux_alternate", runs_on)
        self.assertIn("needs.pick-nightly-sign-runner.outputs.linux", runs_on)
        self.assertIn("contains(fromJSON('[\"blacksmith-4vcpu-ubuntu-2404\",\"blacksmith-16vcpu-ubuntu-2404\",\"blacksmith-32vcpu-ubuntu-2404\"]')", runs_on)
        self.assertIn("pick-nightly-sign-runner", needs(JOBS["signer-build"]))

    def test_production_signers_never_use_hosted_or_single_label_routes(self):
        """Every credentialed signer reads the reconciled Blacksmith pool."""
        runner_map = json.loads((ROOT / ".github/runners.json").read_text())
        linux_set = runner_map["fleets"]["blacksmith"]
        self.assertEqual(
            {linux_set["linux"], linux_set["linux_16"], linux_set["linux_32"]},
            {
                "blacksmith-4vcpu-ubuntu-2404",
                "blacksmith-16vcpu-ubuntu-2404",
                "blacksmith-32vcpu-ubuntu-2404",
            },
        )
        for name in ("signer-build", "signer-app", "signer-app-notary", "signer-dmg"):
            runs_on = JOBS[name]["runs-on"]
            with self.subTest(job=name):
                self.assertIn("needs.pick-nightly-sign-runner.outputs.linux", runs_on)
                # Fork/manual runs have no repository variables; the owner
                # guard keeps their expression from evaluating RUNNER_POOLS.
                # The production branch after that guard must never use hosted
                # Ubuntu or a fixed Linux label.
                owner_guard = "github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' ||"
                self.assertIn(owner_guard, runs_on)
                self.assertNotIn("ubuntu-24.04", runs_on.split(owner_guard, 1)[1])
                self.assertNotIn("vars.LINUX_RUNNER", runs_on)
                self.assertIn("blacksmith-16vcpu-ubuntu-2404", runs_on)
                self.assertIn("blacksmith-32vcpu-ubuntu-2404", runs_on)

    def test_the_helper_is_notarized_first_and_every_signer_call_is_checked(self):
        steps = {step.get("name"): step for step in JOBS["signer-app"]["steps"]}
        sign = steps["Sign the app, the Computer Use helper notarized first"]
        self.assertEqual(sign["env"]["CMUX_SIGN_MODE"], "helper-first")
        self.assertIn("scripts/ci/release-signer/sign-app.sh", sign["run"])
        # The signer binary is checked against the digest its build printed.
        for name in SECRET_JOBS:
            install = next(s for s in JOBS[name]["steps"] if s.get("name") == "Install the signer")
            self.assertIn("release-signer/install.sh", install["run"])
            self.assertEqual(install["env"]["SIGNER_SHA256"], "${{ needs.signer-build.outputs.sha256 }}")
        # A rerun of failed jobs reads the signer by the name its build attempt gave it.
        self.assertEqual(JOBS["signer-build"]["outputs"]["artifact"], "nightly-signer-${{ github.run_attempt }}")
        text = yaml.safe_dump({k: JOBS[k] for k in SIGNER_JOBS[1:]})
        self.assertNotIn("nightly-signer-${{ github.run_attempt }}", text)
        self.assertIn("name: ${{ needs.signer-build.outputs.artifact }}", text)

    def test_the_mac_jobs_run_every_apple_check_including_the_copied_helper(self):
        checks = (ROOT / "scripts/ci/nightly-steps/signer-apple-checks.sh").read_text()
        for command in ("codesign --verify --deep --strict", "stapler validate", "spctl -a -vv -t exec",
                        "syspolicy_check distribution", "ditto \"$helper\"", "source=Notarized Developer ID"):
            self.assertIn(command, checks)
        self.assertIn("signer-apple-checks.sh", yaml.safe_dump(JOBS["signer-dmg-image"]))
        self.assertIn("verify_appcast_item.py", (ROOT / "scripts/ci/nightly-steps/signer-appcast.sh").read_text())
        # The final DMG's Mac checks run in verify-final-dmg-nightly, for a pool-signed DMG only.
        final = next(s for s in JOBS["verify-final-dmg-nightly"]["steps"]
                     if s.get("name") == "Apple's checks of a pool-signed DMG and the app in it")
        self.assertEqual(final["if"], "needs.signer-dmg.result == 'success'")
        script = (ROOT / "scripts/ci/nightly-steps/signer-final-dmg-checks.sh").read_text()
        for command in ("set -euo pipefail", "codesign --verify", "-t open", "source=Notarized Developer ID",
                        "verify_appcast_item.py", "$NIGHTLY_NEXT_SPARKLE_PUBLIC_KEY", "signer-apple-checks.sh"):
            self.assertIn(command, script)
        steps = [s.get("name") for s in JOBS["verify-final-dmg-nightly"]["steps"]]
        self.assertGreater(steps.index(final["name"]), steps.index("Verify final DMG artifact"))
        self.assertLess(steps.index(final["name"]), steps.index("Upload tested DMG digests"))
        # signer-dmg.sh changes directory, so the tools path must be absolute first.
        dmg = (ROOT / "scripts/ci/nightly-steps/signer-dmg.sh").read_text()
        self.assertLess(dmg.index('TOOLS="$(cd "$TOOLS" && pwd)"'), dmg.index("cd signer-out"))

    def test_job_level_keys_are_plain_so_tools_that_read_the_text_see_them(self):
        # Delivery tooling reads needs:/if: from the job's text and refuses a job whose own keys use an
        # anchor, alias or merge key; only step items may share an anchor.
        text = (ROOT / ".github/workflows/nightly.yml").read_text()
        for name in SIGNER_JOBS:
            block = text[text.index(f"\n  {name}:\n"):]
            block = block[: re.search(r"\n  [A-Za-z0-9_-]+:\n", block[1:]).start() + 1]
            for line in block.splitlines()[1:]:
                with self.subTest(job=name, line=line):
                    self.assertNotRegex(line, r"^    [\w-]+:\s*[&*!]|^    <<:")

    def test_no_signer_job_names_the_tool_in_its_step_names(self):
        for name in SIGNER_JOBS:
            for step in JOBS[name]["steps"]:
                self.assertNotRegex(str(step.get("name", "")), re.compile("rcodesign|linux", re.IGNORECASE))


    def test_the_dmg_mac_runs_verify_signed_checks_beside_the_dmg(self):
        # A pool-signed app goes to one office Mac only: signer-dmg-image runs the signed-app checks
        # and verify-signed-nightly's checks on copies in the background while the DMG is built and
        # sent, and fails after the upload when one fails (signer-dmg needs the job's success).
        image = JOBS["signer-dmg-image"]["steps"]
        names = [s.get("name") for s in image]
        unpack = names.index("Unpack the signed app")
        start_checks = image[names.index("Start the signed-app checks")]
        self.assertEqual(start_checks["env"]["PACKAGE_HANDOFF"], "false")
        self.assertEqual(start_checks["run"], 'bash scripts/ci/signed-app-checks.sh start "$SIGNER_WORK/$CHANNEL_APP_NAME.app"')
        verify = image[names.index("Start the verify-signed checks")]
        self.assertIn("signer-verify-signed.sh start", verify["run"])
        self.assertEqual(verify["env"]["BUNDLE_REMOTE_DAEMON_ASSETS"],
                         JOBS["verify-signed-nightly"]["env"]["BUNDLE_REMOTE_DAEMON_ASSETS"])
        daemon = names.index("Download SSH daemon assets")
        dmg = names.index("Build the unsigned DMG")
        upload = next(i for i, s in enumerate(image) if "upload-artifact" in str(s.get("uses", "")))
        finish = names.index("Finish the signed-app and verify-signed checks")
        self.assertLess(unpack, names.index("Start the signed-app checks"))
        # The checks start before the staple, so they run while Apple notarizes the app; Apple's
        # checks of the stapled app come after it, before the DMG is built from it.
        staple = names.index("Staple the app's notarization ticket")
        apple = names.index("Apple's checks of the stapled app")
        self.assertLess(names.index("Start the verify-signed checks"), staple)
        self.assertLess(staple, apple)
        self.assertLess(apple, names.index("Build the unsigned DMG"))
        self.assertIn("signer-staple-app.sh", image[staple]["run"])
        self.assertIn("signer-apple-checks.sh", image[apple]["run"])
        self.assertLess(daemon, names.index("Start the verify-signed checks"))
        self.assertLess(names.index("Start the verify-signed checks"), dmg)
        self.assertLess(upload, finish)
        self.assertEqual(finish, len(image) - 1)
        for mode in ("signed-app-checks.sh finish", "signer-verify-signed.sh finish"):
            self.assertIn(mode, image[finish]["run"])
        self.assertNotIn("continue-on-error", image[finish])
        self.assertNotIn("if", image[finish])
        image_uploads = [s["with"]["name"] for s in image if "upload-artifact" in str(s.get("uses", ""))]
        self.assertEqual(image_uploads, ["cmux-nightly-next-signer-unsigned-dmg-${{ needs.resolve-nightly-cmux-tui-client.outputs.build_short_sha }}"])
        app_upload = next(s for s in JOBS["signer-app"]["steps"] if "upload-artifact" in str(s.get("uses", "")))
        self.assertEqual(app_upload["with"]["compression-level"], 6)
        # verify-signed-nightly's checks, by the commands it runs.
        script = (ROOT / "scripts/ci/nightly-steps/signer-verify-signed.sh").read_text()
        for command in ("./scripts/cmux-next/check-version-surfaces.sh", "./scripts/cmux-next/check-bundled-cli-commands.sh",
                        "./scripts/verify-diff-sidecar-artifact.sh",
                        "--require-signed", "REQUIRE_HELPER_TICKET=true bash scripts/ci/nightly-steps/verify-signed-app-checks.sh",
                        "./tests/test_bundled_ghostty_theme_picker_helper.sh", "scripts/verify_remote_daemon_release.py"):
            self.assertIn(command, script)
        verify_text = yaml.safe_dump(JOBS["verify-signed-nightly"], width=1000)
        for command in ("check-version-surfaces.sh", "check-bundled-cli-commands.sh", "verify-diff-sidecar-artifact.sh", "verify-signed-app-checks.sh",
                        "test_bundled_ghostty_theme_picker_helper.sh", "verify_remote_daemon_release.py"):
            self.assertIn(command, verify_text)
        self.assertFalse([s for s in JOBS["signer-dmg"]["steps"] if "signed-app-handoff" in yaml.safe_dump(s)])

    def test_the_mac_staples_the_ticket_of_the_app_signer_app_notary_submits(self):
        # signer-app hands the signed app on before Apple sees it; signer-app-notary notarizes those
        # bytes (signer-app's digest) while signer-dmg-image downloads and checks them, and the Mac
        # staples Apple's ticket. signer-dmg needs both, so a rejected app never reaches the DMG.
        sign = JOBS["signer-app"]["steps"]
        names = [s.get("name") for s in sign]
        self.assertNotIn("secrets.ASC_API_KEY_P8_BASE64", yaml.safe_dump(sign[names.index("Pack the signed app"):]))
        self.assertFalse([s for s in sign if "notarize-app.sh" in str(s.get("run", ""))])
        upload = next(s for s in sign if "upload-artifact" in str(s.get("uses", "")))
        self.assertEqual(upload["with"]["path"], "signer-out/signed-app.tar")
        notary = JOBS["signer-app-notary"]
        self.assertEqual(set(needs(notary)) & set(SIGNER_JOBS), {"signer-build", "signer-app"})
        steps = notary["steps"]
        names = [s.get("name") for s in steps]
        unpack = steps[names.index("Unpack the signed app")]
        # Both jobs unpack the one tar after checking it against signer-app's digest.
        self.assertIn('echo "$APP_SHA256  signer-app/signed-app.tar" | "${sum[@]}" -c -', unpack["run"])
        self.assertEqual(unpack["env"]["APP_SHA256"], "${{ needs.signer-app.outputs.sha256 }}")
        notarize = steps[names.index("Notarize the app")]
        self.assertIn("release-signer/notarize-app.sh", notarize["run"])
        self.assertLess(names.index("Unpack the signed app"), names.index("Notarize the app"))
        image = JOBS["signer-dmg-image"]
        self.assertNotIn("signer-app-notary", needs(image))
        self.assertIn("signer-app-notary", needs(JOBS["signer-dmg"]))
        image_steps = {s.get("name"): s for s in image["steps"]}
        self.assertEqual(image_steps["Unpack the signed app"], unpack)
        self.assertIn("signer-app/signed-app.tar", (ROOT / "scripts/ci/nightly-steps/signer-appcast.sh").read_text())

    def test_the_stapled_app_download_retries_once(self):
        # Run 40809822736: GetSignedArtifactURL timed out on an office mini, signer-dmg-image failed
        # and the macOS signer covered the build about 8 min later. Each signer job that reads the
        # stapled app now tries for 5 min, then once more; the tar's digest is checked after.
        for job in ("signer-dmg-image", "signer-dmg"):
            with self.subTest(job=job):
                steps = JOBS[job]["steps"]
                names = [s.get("name") for s in steps]
                first = steps[names.index("Download the signed app")]
                retry = steps[names.index("Download the signed app (retry)")]
                self.assertEqual(names.index("Download the signed app (retry)"), names.index("Download the signed app") + 1)
                self.assertEqual((first["id"], first["continue-on-error"], first["timeout-minutes"]),
                                 ("signer-download-app", True, 5))
                self.assertEqual(retry["if"], "steps.signer-download-app.outcome == 'failure'")
                self.assertNotIn("continue-on-error", retry)
                self.assertEqual(first["with"], retry["with"])
                later = yaml.safe_dump(steps[names.index("Download the signed app (retry)") + 1:], width=1000)
                self.assertIn("signer-app/signed-app.tar", later)
                self.assertIn("APP_SHA256", later)

    def test_verify_final_reads_one_copy_of_a_pool_signed_dmg(self):
        # cmux-nightly-variant-arm64 holds the DMG under two names; verify-final-dmg-nightly runs on
        # an office Mac, so a pool-signed build hands it the DMG once, with the appcast.
        upload = next(s for s in JOBS["signer-dmg"]["steps"] if (s.get("with") or {}).get("name") == FINAL_DMG)
        self.assertEqual(upload["with"]["path"].splitlines(), ["signer-out/${{ env.NIGHTLY_DMG_RELEASE }}",
                                                         "signer-out/appcast-arm64.xml"])
        steps = {s.get("name"): s for s in JOBS["verify-final-dmg-nightly"]["steps"]}
        self.assertEqual(steps["Download final DMG"]["with"]["name"],
                         "${{ needs.signer-dmg.result == 'success' && format('cmux-nightly-next-signer-final-dmg-{0}', "
                         "needs.resolve-nightly-cmux-tui-client.outputs.build_short_sha) || format('cmux-nightly-variant-{0}', matrix.variant) }}")
        verify = steps["Verify final DMG artifact"]
        self.assertEqual(verify["env"]["POOL_SIGNED"], "${{ needs.signer-dmg.result == 'success' }}")
        run = verify["run"]
        # The immutable copy is made from the release DMG before the verifier and the byte check
        # read it, so its tested line is the verified digest; a copy already present is refused.
        self.assertLess(run.index('cp "$release" "$immutable"'), run.index("verify-dmg-artifact.sh"))
        self.assertLess(run.index('cp "$release" "$immutable"'), run.index('for dmg in final-dmg/'))
        self.assertIn('[ ! -e "$immutable" ] ||', run)
        # signer-dmg.sh makes the published immutable DMG the same way.
        self.assertIn('cp "$NIGHTLY_DMG_RELEASE" "$NIGHTLY_DMG_IMMUTABLE"',
                      (ROOT / "scripts/ci/nightly-steps/signer-dmg.sh").read_text())


class VerifyAppcastItem(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp()).resolve()
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.seed = os.urandom(32)
        pkcs8 = bytes.fromhex("302e020100300506032b657004220420") + self.seed
        spki = subprocess.run(["openssl", "pkey", "-inform", "DER", "-pubout", "-outform", "DER"],
                              input=pkcs8, capture_output=True, check=True).stdout
        self.public = base64.b64encode(spki[12:]).decode()
        self.dmg = self.tmp / "cmux-nightly-next-macos-arm64-77.dmg"
        self.dmg.write_bytes(os.urandom(4096))
        app = self.tmp / "plist" / "cmux NEXT.app" / "Contents"
        app.mkdir(parents=True)
        import plistlib
        (app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleVersion": "77", "CFBundleShortVersionString": "1.0.0-nightly.77",
                                                         "SUPublicEDKey": self.public, "CFBundleName": "cmux NEXT"}))
        subprocess.run([sys.executable, "-I", "-m", "zipfile", "-c", str(self.tmp / "plist.zip"), "cmux NEXT.app"],
                       cwd=self.tmp / "plist", check=True)
        self.appcast = self.tmp / "appcast-arm64.xml"
        subprocess.run([sys.executable, "-I", str(TIP_APPCAST), "KEY", str(self.dmg), str(self.tmp / "plist.zip"), "cmux NEXT",
                        "https://github.com/manaflow-ai/cmux/releases/download/nightly-next/",
                        "https://github.com/manaflow-ai/cmux/releases/tag/nightly-next", "77", str(self.appcast)],
                       env=dict(os.environ, KEY=base64.b64encode(self.seed).decode()), check=True, capture_output=True)

    def verify(self, *, appcast=None, dmg=None, key=None, build="77"):
        return subprocess.run([sys.executable, "-I", str(VERIFY), str(appcast or self.appcast), str(dmg or self.dmg),
                               key or self.public, build], capture_output=True, text=True)

    def test_accepts_the_item_signed_by_the_pinned_key(self):
        result = self.verify()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("verified with the pinned key", result.stdout)

    def test_refuses_another_key(self):
        other = base64.b64encode(os.urandom(32)).decode()
        self.assertIn("does not verify", self.verify(key=other).stderr)

    def test_refuses_changed_bytes_another_build_or_length(self):
        changed = self.tmp / self.dmg.name.replace(".dmg", "-x.dmg")
        changed.write_bytes(self.dmg.read_bytes())
        renamed = self.tmp / "renamed" / self.dmg.name
        renamed.parent.mkdir()
        data = bytearray(self.dmg.read_bytes())
        data[0] ^= 1
        renamed.write_bytes(bytes(data))
        self.assertIn("does not verify", self.verify(dmg=renamed).stderr)
        self.assertIn("does not name", self.verify(dmg=changed).stderr)
        self.assertIn("not 78", self.verify(build="78").stderr)
        short = self.tmp / "short" / self.dmg.name
        short.parent.mkdir()
        short.write_bytes(self.dmg.read_bytes()[:-1])
        self.assertIn("length", self.verify(dmg=short).stderr)

    def test_matches_rfc_8032_test_2_without_openssl(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("verify_appcast_item", VERIFY)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        public = bytes.fromhex("3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c")
        signature = bytes.fromhex("92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da"
                                  "085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00")
        message = self.tmp / "rfc8032-test-2"
        message.write_bytes(bytes.fromhex("72"))
        self.assertTrue(module.ed25519_verify(public, signature, str(message)))
        self.assertFalse(module.ed25519_verify(public, signature[:-1] + b"\x01", str(message)))
        message.write_bytes(bytes.fromhex("73"))
        self.assertFalse(module.ed25519_verify(public, signature, str(message)))


class SignerVerifySigned(unittest.TestCase):
    """signer-verify-signed.sh runs verify-signed-nightly's checks on a copy of the app in the
    background and hands back their status; the build tree's scripts are stubs here."""

    SCRIPT = ROOT / "scripts/ci/nightly-steps/signer-verify-signed.sh"
    STUBS = ("scripts/cmux-next/check-version-surfaces.sh", "scripts/cmux-next/check-bundled-cli-commands.sh",
             "scripts/verify-diff-sidecar-artifact.sh",
             "scripts/ci/nightly-steps/verify-signed-app-checks.sh", "tests/test_bundled_ghostty_theme_picker_helper.sh")

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp()).resolve()
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.work = self.tmp / "work"
        self.app = self.work / "signer-work" / "cmux NEXT.app"
        (self.app / "Contents" / "MacOS").mkdir(parents=True)
        (self.app / "Contents" / "MacOS" / "cmux").write_text("binary")
        self.log = self.tmp / "calls.log"
        for stub in self.STUBS:
            path = self.work / stub
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('#!/usr/bin/env bash\nprintf \'%s|%s|%s|%s\\n\' "${0##*/}" "${REQUIRE_HELPER_TICKET:-}" "${CHANNEL_APP_PATH:-${CMUX_APP_PATH:-}}" "$*" >> "$CALLS"\n'
                            '[[ "${FAIL:-}" == "${0##*/}" ]] && exit 9\n'
                            # A check that writes into the bundle it was given.
                            'touch "${CHANNEL_APP_PATH:-${CMUX_APP_PATH:-$1}}/written-by-${0##*/}" 2>/dev/null || true\n')
            path.chmod(0o755)
        (self.work / "scripts" / "verify_remote_daemon_release.py").write_text(
            "import os, sys\nopen(os.environ['CALLS'], 'a').write('daemon|' + ' '.join(sys.argv[1:]) + '\\n')\n")
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir()
        (bin_dir / "ditto").write_text('#!/bin/sh\nexec cp -a "$1" "$2"\n')
        (bin_dir / "lipo").write_text('#!/bin/sh\necho arm64\n')
        (bin_dir / "uname").write_text('#!/bin/sh\necho arm64\n')
        for tool in ("ditto", "lipo", "uname"):
            (bin_dir / tool).chmod(0o755)
        (self.tmp / "runner").mkdir()
        self.env = dict(os.environ, PATH=f"{bin_dir}:{os.environ.get('PATH', '')}", RUNNER_TEMP=str(self.tmp / "runner"),
                        CALLS=str(self.log), NIGHTLY_BUILD="77", BUNDLE_REMOTE_DAEMON_ASSETS="false",
                        CHANNEL_RELEASE_TAG="nightly-next", CHANNEL_ENTITLEMENTS="cmux.entitlements", TRACK="nightly-next")

    def run_step(self, *args, **env):
        return subprocess.run(["bash", str(self.SCRIPT), *args], cwd=self.work, env=dict(self.env, **env),
                              capture_output=True, text=True)

    def calls(self):
        return self.log.read_text().splitlines() if self.log.exists() else []

    def test_every_check_runs_on_a_copy_and_finish_passes(self):
        self.assertEqual(self.run_step("start", str(self.app)).returncode, 0)
        done = self.run_step("finish")
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        calls = self.calls()
        self.assertEqual([c.split("|")[0] for c in calls],
                         ["check-version-surfaces.sh", "check-bundled-cli-commands.sh", "verify-diff-sidecar-artifact.sh",
                          "verify-signed-app-checks.sh", "test_bundled_ghostty_theme_picker_helper.sh", "daemon"])
        copy = str(self.tmp / "runner" / "signer-verify-signed" / "snapshot" / "cmux NEXT.app")
        self.assertTrue(calls[1].endswith(f"|{copy}"), calls[1])
        self.assertIn(f"|{copy}|", calls[3])
        self.assertTrue(calls[3].startswith("verify-signed-app-checks.sh|true|"))
        self.assertIn(f"{copy}/Contents/Resources/bin/cmux-diff-sidecar --archs arm64 --require-signed", calls[2])
        self.assertEqual(calls[5], f"daemon|--manifest remote-daemon-assets/cmuxd-remote-manifest-77.json "
                                   f"--assets-dir remote-daemon-assets --app {copy}")
        # Nothing a check wrote reached the app the DMG is built from, and the copy is gone.
        self.assertEqual(sorted(p.name for p in self.app.iterdir()), ["Contents"])
        self.assertFalse((self.tmp / "runner" / "signer-verify-signed").exists())

    def test_the_daemon_contract_takes_the_bundled_assets_and_the_cli_check_as_verify_signed_does(self):
        self.assertEqual(self.run_step("start", str(self.app), BUNDLE_REMOTE_DAEMON_ASSETS="true",
                                       CHANNEL_RELEASE_TAG="nightly").returncode, 0)
        self.assertEqual(self.run_step("finish").returncode, 0)
        self.assertTrue(self.calls()[-1].endswith(" --require-bundled-assets --verify-cli"), self.calls()[-1])

    def test_a_failed_check_fails_finish_after_the_rest_ran(self):
        self.assertEqual(self.run_step("start", str(self.app), FAIL="verify-diff-sidecar-artifact.sh").returncode, 0)
        done = self.run_step("finish")
        self.assertNotEqual(done.returncode, 0)
        self.assertIn("Verify signed diff sidecar protocol contract: FAILED", done.stdout)
        self.assertEqual(len(self.calls()), 6)

    def test_finish_without_start_fails(self):
        self.assertNotEqual(self.run_step("finish").returncode, 0)

    def test_start_refuses_a_missing_app_or_setting(self):
        self.assertNotEqual(self.run_step("start", str(self.tmp / "none.app")).returncode, 0)
        env = dict(self.env)
        del env["NIGHTLY_BUILD"]
        done = subprocess.run(["bash", str(self.SCRIPT), "start", str(self.app)], cwd=self.work, env=env,
                              capture_output=True, text=True)
        self.assertNotEqual(done.returncode, 0)


class SignerStapleApp(unittest.TestCase):
    """signer-staple-app.sh asks Apple's stapler for the ticket until it exists, then validates it,
    and fails at its deadline. xcrun is a stub that finds the ticket on a given attempt."""

    SCRIPT = ROOT / "scripts/ci/nightly-steps/signer-staple-app.sh"

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp()).resolve()
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.app = self.tmp / "cmux NEXT.app"
        (self.app / "Contents").mkdir(parents=True)
        self.calls = self.tmp / "calls"
        self.xcrun = self.tmp / "xcrun"
        self.xcrun.write_text('#!/usr/bin/env bash\n'
                              'echo "$*" >> "$CALLS"\n'
                              'n=$(grep -c "^stapler staple" "$CALLS")\n'
                              'if [[ "$1 $2" == "stapler staple" && "$n" -lt "$READY_AT" ]]; then echo "CloudKit query failed: Record not found"; exit 65; fi\n'
                              'if [[ "$1 $2" == "stapler validate" && "${BAD_VALIDATE:-}" == 1 ]]; then exit 1; fi\n'
                              'echo "The $2 action worked!"\n')
        self.xcrun.chmod(0o755)

    def run_script(self, ready_at, max_wait="30", **env):
        return subprocess.run(["bash", str(self.SCRIPT), str(self.app)], capture_output=True, text=True,
                              env=dict(os.environ, XCRUN_TOOL=str(self.xcrun), CALLS=str(self.calls), READY_AT=str(ready_at),
                                       STAPLE_RETRY_SECONDS="1", STAPLE_MAX_WAIT_SECONDS=max_wait,
                                       GITHUB_STEP_SUMMARY=str(self.tmp / "summary"), **env))

    def test_retries_until_apple_has_the_ticket_then_validates(self):
        done = self.run_script(3)
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertEqual(self.calls.read_text().splitlines(),
                         [f"stapler staple {self.app}"] * 3 + [f"stapler validate {self.app}"])
        self.assertIn("attempt 2 after", done.stdout)
        self.assertIn("Record not found", done.stdout)

    def test_fails_at_the_deadline_without_a_ticket(self):
        done = self.run_script(1000, max_wait="2")
        self.assertNotEqual(done.returncode, 0)
        self.assertIn("no notarization ticket", done.stderr)
        self.assertNotIn("stapler validate", self.calls.read_text())

    def test_a_staple_that_does_not_validate_fails(self):
        self.assertNotEqual(self.run_script(1, BAD_VALIDATE="1").returncode, 0)

    def test_refuses_a_missing_app(self):
        done = subprocess.run(["bash", str(self.SCRIPT), str(self.tmp / "none.app")], capture_output=True, text=True,
                              env=dict(os.environ, XCRUN_TOOL=str(self.xcrun)))
        self.assertNotEqual(done.returncode, 0)


if __name__ == "__main__":
    unittest.main()
