#!/usr/bin/env python3
"""scripts/ci/simslim: the iOS simulator step's slim simulators and their per-run opt-outs.

The helper runs against a fake simslim that records its arguments, so this needs no
simulator: what matters is which simslim commands each mode runs, that a broken gate
fails the run, and that a missing simslim falls back to stock. Run: python3 -I THIS.
"""
import json
import os
import pathlib
import subprocess
import tempfile
import textwrap
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
LIB = ROOT / "scripts/ci/simslim/simslim.sh"
PROFILE_PY = ROOT / "scripts/ci/simslim/profile.py"
FLEET = ROOT / "scripts/ci/simslim/fleet.json"
SCRIPT = ROOT / "scripts/ci/cmux-next-ios-sim.sh"

# simslim v0.14.0 `doctor --list`: the daemons behind each feature the fleet requires.
REQUIRED = {
    "push": ["com.apple.apsd"],
    "storekit": ["com.apple.storekitd", "com.apple.itunesstored", "com.apple.amsaccountsd",
                 "com.apple.amsengagementd", "com.apple.amsondevicestoraged", "com.apple.passd",
                 "com.apple.financed"],
    "universal-links": ["com.apple.swcd"],
}

FAKE = textwrap.dedent("""\
    #!/bin/bash
    printf '%s\\n' "$*" >> "$FAKE_LOG"
    case "$*" in
      --version) echo "simslim ${FAKE_VERSION:-0.14.0}" ;;
      *" doctor "*|doctor*) [[ -n "${FAKE_DOCTOR_FAIL:-}" ]] && { echo "  BROKEN push"; exit 1; }; echo ok ;;
      *" verify "*|verify*) [[ -n "${FAKE_VERIFY_FAIL:-}" ]] && { echo drift; exit 1; }; echo ok ;;
      *" measure "*|measure*) echo '{"processes": 80, "bytes": 1118744576, "cpu": 0.3}' ;;
    esac
    """)


class Harness:
    def __init__(self, test):
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        test.addCleanup(subprocess.run, ["rm", "-rf", str(self.tmp)])
        self.fake = self.tmp / "simslim"
        self.fake.write_text(FAKE)
        self.fake.chmod(0o755)
        self.log = self.tmp / "calls.log"
        self.log.touch()
        # xcrun: records `simctl ...` calls into the same log, prefixed.
        bindir = self.tmp / "bin"
        bindir.mkdir()
        xcrun = bindir / "xcrun"
        xcrun.write_text('#!/bin/bash\nprintf \'xcrun %s\\n\' "$*" >> "$FAKE_LOG"\n')
        xcrun.chmod(0o755)
        self.bindir = bindir

    def run(self, body, **env):
        full = {"PATH": f"{self.bindir}:{os.environ['PATH']}", "HOME": str(self.tmp), "FAKE_LOG": str(self.log),
                "CMUX_SIMSLIM_BIN": str(self.fake)}
        full.update(env)
        script = f"""
            set -euo pipefail
            note() {{ printf '%s\\n' "$*" >> "{self.tmp}/SUMMARY.md"; }}
            source "{LIB}"
            cmux_simslim_init "{self.tmp}/work" "{self.tmp}/out"
            {body}
        """
        return subprocess.run(["bash", "-c", script], env=full, capture_output=True, text=True)

    def calls(self):
        return [line for line in self.log.read_text().splitlines() if line != "--version"]

    def summary(self):
        p = self.tmp / "SUMMARY.md"
        return p.read_text() if p.exists() else ""


class FleetProfileTest(unittest.TestCase):
    def test_keeps_every_daemon_of_the_required_features(self):
        profile = json.loads(FLEET.read_text())
        kept = set(profile["keep"])
        for feature, labels in REQUIRED.items():
            missing = [l for l in labels if l not in kept]
            self.assertEqual(missing, [], f"fleet.json turns off {feature}: {missing}")
        self.assertEqual(sorted(profile), ["description", "except", "keep", "name"],
                         "simslim rejects unknown profile fields")

    def test_the_gate_requires_the_same_features(self):
        self.assertIn("cmux_simslim_requires=push,storekit,universal-links", LIB.read_text())


class ProfileMergeTest(unittest.TestCase):
    def merge(self, keep):
        return subprocess.run(["python3", "-I", str(PROFILE_PY), str(FLEET), keep], capture_output=True, text=True)

    def test_categories_go_to_except_and_labels_to_keep(self):
        r = self.merge("photos, search,com.apple.assetsd,photos")
        self.assertEqual(r.returncode, 0, r.stderr)
        out = json.loads(r.stdout)
        self.assertEqual(out["except"], ["photos", "search"])
        self.assertEqual(out["keep"][-1], "com.apple.assetsd")
        self.assertEqual(out["keep"].count("com.apple.assetsd"), 1)
        self.assertEqual(out["name"], "cmux-fleet+keep")

    def test_empty_keep_is_the_fleet_profile(self):
        r = self.merge("")
        self.assertEqual(json.loads(r.stdout), json.loads(FLEET.read_text()))

    def test_a_word_that_is_neither_fails(self):
        for bad in ("Photos!", "x", "com.apple.$(id)"):
            r = self.merge(bad)
            self.assertEqual(r.returncode, 2, bad)


class HelperTest(unittest.TestCase):
    LIFECYCLE = """
        cmux_simslim_prepare UDID-1 /sims
        cmux_simslim_gate UDID-1 /sims
        cmux_simslim_measure UDID-1 launch /sims
        cmux_simslim_prepare UDID-2
        cmux_simslim_gate UDID-2
    """

    def test_default_slims_before_boot_then_gates(self):
        h = Harness(self)
        r = h.run(self.LIFECYCLE)
        self.assertEqual(r.returncode, 0, r.stderr)
        calls = h.calls()
        profile = str(h.tmp / "work/simslim/profile.json")
        self.assertEqual(calls[0], f"--set /sims on UDID-1 --preserve-boot-state --profile {profile}")
        self.assertEqual(calls[1], "--set /sims doctor UDID-1 --requires push,storekit,universal-links")
        self.assertEqual(calls[2], f"--set /sims verify UDID-1 --profile {profile}")
        self.assertEqual(calls[3], "--set /sims measure UDID-1 --json")
        self.assertEqual(calls[4], f"on UDID-2 --preserve-boot-state --profile {profile}",
                         "a simulator in the default set gets no --set")
        self.assertIn("simulators: slim", h.summary())
        self.assertIn("80 processes, 1.12 GB", h.summary())
        self.assertTrue((h.tmp / "out/simslim/launch.json").is_file())
        self.assertTrue((h.tmp / "out/simslim/profile.json").is_file())

    def test_full_sim_never_changes_a_simulator(self):
        h = Harness(self)
        r = h.run(self.LIFECYCLE, CMUX_SIM_FULL="1")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(h.calls(), ["--set /sims measure UDID-1 --json"], "stock runs only measure")
        self.assertIn("stock (CMUX_SIM_FULL=1)", h.summary())

    def test_keep_reaches_the_applied_profile(self):
        h = Harness(self)
        r = h.run("cmux_simslim_prepare UDID-1", CMUX_SIM_KEEP="photos,com.apple.corespeechd")
        self.assertEqual(r.returncode, 0, r.stderr)
        applied = json.loads((h.tmp / "work/simslim/profile.json").read_text())
        self.assertEqual(applied["except"], ["photos"])
        self.assertIn("com.apple.corespeechd", applied["keep"])
        self.assertIn("keep photos,com.apple.corespeechd", h.summary())

    def test_a_bad_keep_fails_before_any_simulator(self):
        h = Harness(self)
        r = h.run("cmux_simslim_prepare UDID-1", CMUX_SIM_KEEP="not a category")
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(h.calls(), [])

    def test_a_broken_required_feature_fails_the_gate(self):
        h = Harness(self)
        r = h.run("cmux_simslim_prepare U; cmux_simslim_gate U", FAKE_DOCTOR_FAIL="1")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("simslim gate FAILED on U", h.summary())

    def test_drift_from_the_profile_fails_the_gate(self):
        h = Harness(self)
        r = h.run("cmux_simslim_prepare U; cmux_simslim_gate U", FAKE_VERIFY_FAIL="1")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("drift from the profile", h.summary())

    def test_no_simslim_falls_back_to_stock_with_a_warning(self):
        h = Harness(self)
        r = h.run(self.LIFECYCLE, CMUX_SIMSLIM_BIN=str(h.tmp / "missing"))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("WARNING stock, simslim 0.14.0 unavailable (no executable at", h.summary())
        self.assertEqual(h.calls(), [])

    def test_slim_boots_and_gates_before_xcodebuild(self):
        h = Harness(self)
        r = h.run("cmux_simslim_boot_and_gate U /sims")
        self.assertEqual(r.returncode, 0, r.stderr)
        calls = h.calls()
        self.assertEqual(calls[0], "xcrun simctl --set /sims boot U")
        self.assertEqual(calls[1], "xcrun simctl --set /sims bootstatus U -b")
        self.assertTrue(calls[2].startswith("--set /sims doctor U"))

    def test_stock_leaves_the_boot_to_xcodebuild(self):
        # Before SimSlim, a test iPhone was booted by xcodebuild after it compiled; a stock run
        # (CMUX_SIM_FULL=1 or no simslim) keeps that, so no idle stock simulator waits on a build.
        for env in ({"CMUX_SIM_FULL": "1"}, {"CMUX_SIMSLIM_BIN": "/nonexistent"}):
            h = Harness(self)
            r = h.run("cmux_simslim_prepare U; cmux_simslim_boot_and_gate U", **env)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual(h.calls(), [], env)

    def test_parallel_testing_clones_are_reported(self):
        h = Harness(self)
        log = h.tmp / "ui-test.log"
        log.write_text("Testing started\nClone 1 of iPhone 17 Pro (ABC)\n")
        r = h.run(f"cmux_simslim_check_clones {log}; cmux_simslim_check_clones {h.tmp}/none.log")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("ui-test.log ran on parallel-testing clones", h.summary())
        quiet = Harness(self)
        log2 = quiet.tmp / "t.log"
        log2.write_text("Testing started\n")
        quiet.run(f"cmux_simslim_check_clones {log2}")
        self.assertNotIn("clones", quiet.summary())

    def test_a_doctor_that_cannot_check_says_so(self):
        h = Harness(self)
        fake = h.fake.read_text().replace('echo "  BROKEN push"; ', '')
        h.fake.write_text(fake)
        r = h.run("cmux_simslim_gate U", FAKE_DOCTOR_FAIL="1")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("doctor could not check it", h.summary())

    def test_another_simslim_version_is_not_used(self):
        h = Harness(self)
        r = h.run(self.LIFECYCLE, FAKE_VERSION="0.13.0")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(h.calls(), [], "a simslim other than the pinned one changes nothing")
        self.assertIn("unavailable", h.summary())


class StepWiringTest(unittest.TestCase):
    def test_every_simulator_the_step_creates_is_prepared_before_it_boots(self):
        import re
        lines = SCRIPT.read_text().splitlines()
        creates = [i for i, l in enumerate(lines) if re.search(r"simctl.* create ", l) and "=" in l]
        self.assertGreaterEqual(len(creates), 4)
        for i in creates:
            var = re.match(r"\s*([a-z_]+)=", lines[i]).group(1)
            window = lines[i + 1:i + 6]
            prep = [j for j, l in enumerate(window) if f'cmux_simslim_prepare "${var}"' in l]
            boots = [j for j, l in enumerate(lines[i + 1:i + 40]) if re.search(rf'simctl.* boot "\${var}"', l)]
            self.assertTrue(prep, f"line {i + 1}: {var} is not prepared right after create")
            self.assertTrue(not boots or prep[0] < boots[0], f"line {i + 1}: {var} boots before it is prepared")
            rest = "\n".join(lines[i + 1:i + 40])
            self.assertTrue(f'cmux_simslim_gate "${var}"' in rest or f'cmux_simslim_boot_and_gate "${var}"' in rest,
                            f"line {i + 1}: {var} is never gated")


if __name__ == "__main__":
    unittest.main()
