#!/usr/bin/env python3
"""nightly.yml's release-pool signer jobs (signer-*): opt-in, the macOS signer
job as their fallback, and the secrets kept in the release-pool jobs; and
verify_appcast_item.py checks the Sparkle item against the pinned key.

Only signer-dmg, after the DMG is notarized and its appcast checked, hands
output on, under the names the macOS signer job uses. That job runs whenever
signer-dmg did not pass, so a failed, skipped or not-opted-in pool run signs as
before, and exactly one of the two produces what verify-signed-nightly,
verify-final-dmg-nightly and publish-nightly read. The pool path has one Mac job
(signer-dmg-image) before that decision; the final DMG's Mac checks run in
verify-final-dmg-nightly, which publish needs anyway.
"""

from __future__ import annotations

import base64
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
SIGNER_JOBS = ("signer-build", "signer-app", "signer-dmg-image", "signer-dmg")
SECRET_JOBS = {"signer-app", "signer-dmg"}
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
        for name in ("verify-signed-nightly", "verify-final-dmg-nightly", "publish-nightly"):
            with self.subTest(job=name):
                self.assertIn("signer-dmg", needs(JOBS[name]))
                self.assertIn(signed, JOBS[name]["if"])
                self.assertNotRegex(JOBS[name]["if"], r"\(needs\.build-sign-notarize-nightly\.result == 'success' &&")
        self.assertIn("REQUIRE_HELPER_TICKET: ${{ needs.signer-dmg.result == 'success' }}",
                      yaml.safe_dump(JOBS["verify-signed-nightly"]["env"], width=1000))
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
        self.assertEqual(names, {"cmux-nightly-variant-arm64",
                                 "cmux-${{ needs.decide.outputs.channel }}-signed-app-arm64-${{ needs.resolve-nightly-cmux-tui-client.outputs.build_short_sha }}",
                                 FINAL_DMG})
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
                    self.assertIn("ubuntu", job["runs-on"])
                    self.assertNotIn("macos", job["runs-on"])
                    self.assertNotIn("secrets.", yaml.safe_dump(job.get("env") or {}))
                else:
                    self.assertNotIn("environment", job)
                    self.assertNotIn("secrets.", text)

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


    def test_the_verify_handoff_is_made_on_linux_not_sent_from_the_mac(self):
        # signer-dmg-image's Mac sends only the unsigned DMG over the office uplink: the verify
        # job's handoff is made in signer-dmg from the stapled-app.tar, gzipped while the DMG waits
        # on Apple, and the stapled app reaches the Mac deflated.
        image = JOBS["signer-dmg-image"]["steps"]
        checks = next(s for s in image if s.get("name") == "The signed-app checks")
        self.assertEqual(checks["env"]["PACKAGE_HANDOFF"], "false")
        image_uploads = [s["with"]["name"] for s in image if "upload-artifact" in str(s.get("uses", ""))]
        self.assertEqual(image_uploads, ["cmux-nightly-next-signer-unsigned-dmg-${{ needs.resolve-nightly-cmux-tui-client.outputs.build_short_sha }}"])
        app_upload = next(s for s in JOBS["signer-app"]["steps"] if "upload-artifact" in str(s.get("uses", "")))
        self.assertEqual(app_upload["with"]["compression-level"], 6)
        steps = JOBS["signer-dmg"]["steps"]
        names = [s.get("name") for s in steps]
        start = names.index("Start packaging the stapled app for the verify job")
        self.assertLess(start, names.index("Sign, notarize and staple the DMG"))
        self.assertNotIn("secrets.", yaml.safe_dump(steps[start]))
        self.assertIn("signer-handoff.sh start", steps[start]["run"])
        finish = names.index("Finish packaging the stapled app for the verify job")
        self.assertIn("signer-handoff.sh finish", steps[finish]["run"])
        handoff = next(i for i, s in enumerate(steps) if (s.get("with") or {}).get("path") == "signed-app-handoff/*")
        self.assertLess(finish, handoff)
        self.assertFalse([s for s in steps if "download-artifact" in str(s.get("uses", ""))
                          and "signer-handoff" in str((s.get("with") or {}).get("name", ""))])

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


class SignerHandoff(unittest.TestCase):
    """signer-handoff.sh makes the layout verify-signed-nightly restores: the app at the top of
    cmux-signed-app.tar.gz, beside a shasum line for it."""

    SCRIPT = ROOT / "scripts/ci/nightly-steps/signer-handoff.sh"

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp()).resolve()
        self.addCleanup(shutil.rmtree, self.tmp, True)
        app = self.tmp / "src" / "cmux NEXT.app" / "Contents"
        (app / "MacOS").mkdir(parents=True)
        (app / "MacOS" / "cmux").write_bytes(os.urandom(70000))
        (app / "Info.plist").write_text("<plist/>")
        (app / "Frameworks").symlink_to("MacOS")
        (self.tmp / "work" / "signer-app").mkdir(parents=True)
        self.tar = self.tmp / "work" / "signer-app" / "stapled-app.tar"
        subprocess.run(["tar", "-C", str(self.tmp / "src"), "-cf", str(self.tar), "cmux NEXT.app"], check=True)
        self.sha = subprocess.run(["sha256sum", str(self.tar)], capture_output=True, text=True, check=True).stdout.split()[0]
        (self.tmp / "runner").mkdir()

    def run_step(self, mode, sha=None):
        env = dict(os.environ, RUNNER_TEMP=str(self.tmp / "runner"), APP_SHA256=sha or self.sha)
        return subprocess.run(["bash", str(self.SCRIPT), mode], cwd=self.tmp / "work", env=env,
                              capture_output=True, text=True)

    def test_start_then_finish_hands_on_the_stapled_app(self):
        self.assertEqual(self.run_step("start").returncode, 0)
        done = self.run_step("finish")
        self.assertEqual(done.returncode, 0, done.stderr)
        out = self.tmp / "work" / "signed-app-handoff"
        subprocess.run(["sha256sum", "-c", "cmux-signed-app.tar.gz.sha256"], cwd=out, check=True, capture_output=True)
        restored = self.tmp / "signed"
        restored.mkdir()
        subprocess.run(["tar", "-C", str(restored), "-xzf", str(out / "cmux-signed-app.tar.gz")], check=True)
        app = restored / "cmux NEXT.app" / "Contents"
        self.assertEqual((app / "MacOS" / "cmux").read_bytes(),
                         (self.tmp / "src" / "cmux NEXT.app" / "Contents" / "MacOS" / "cmux").read_bytes())
        self.assertTrue((app / "Frameworks").is_symlink())
        self.assertFalse((self.tmp / "runner" / "signer-handoff").exists())

    def test_a_tar_that_is_not_the_checked_one_is_refused(self):
        self.assertNotEqual(self.run_step("start", sha="0" * 64).returncode, 0)
        self.assertFalse((self.tmp / "work" / "signed-app-handoff").exists())

    def test_finish_without_start_fails(self):
        self.assertNotEqual(self.run_step("finish").returncode, 0)

    def test_a_failed_packaging_fails_finish(self):
        # A gzip (or pigz) that fails in the background: start has already returned, finish fails.
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir()
        for tool in ("gzip", "pigz"):
            (bin_dir / tool).write_text("#!/bin/sh\nexit 7\n")
            (bin_dir / tool).chmod(0o755)
        env_path = f"{bin_dir}:{os.environ.get('PATH', '')}"
        env = dict(os.environ, PATH=env_path, RUNNER_TEMP=str(self.tmp / "runner"), APP_SHA256=self.sha)
        run = lambda mode: subprocess.run(["bash", str(self.SCRIPT), mode], cwd=self.tmp / "work", env=env,
                                          capture_output=True, text=True)
        self.assertEqual(run("start").returncode, 0)
        done = run("finish")
        self.assertNotEqual(done.returncode, 0)
        self.assertIn("status 7", done.stderr)

if __name__ == "__main__":
    unittest.main()
