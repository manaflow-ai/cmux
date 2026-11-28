#!/usr/bin/env python3
"""scripts/ci/ios_link_ffi.sh: the build fleet builds the framework, a fleet red is the step's red, and a copy is
marked with its input key, so the job's next step reuses it.

Only a run that cannot ask the fleet (no client, no OIDC token: a fork's pull request) builds on its Mac.

The `ios` job runs ios-kit (`ios_link_ffi.sh 8`) and then ios-phone-cells (`ios_link_ffi.sh 4`) in one checkout. Only
a fleet copy was marked, so after a Mac fallback the second step built the framework again (1.9 min of Blacksmith run
45720177041). The test runs the script in a throwaway repo with the key script and the build script stubbed.
"""
import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/ios_link_ffi.sh"

KEY_STUB = """import os, sys
k = os.environ.get("STUB_KEY", "")
if not k:
    sys.exit(1)
print(k)
"""

BUILD_STUB = """#!/usr/bin/env bash
echo build >> "$STUB_COUNT"
[[ "${STUB_BUILD_FAIL:-0}" == 1 ]] && exit 7
d=cmux-next-ios/CmuxMobileKit/Frameworks/CmuxMobileLinkFFI.xcframework
mkdir -p "$d"
echo plist > "$d/Info.plist"
"""


class Repo(unittest.TestCase):
    """A throwaway repo with the key script and the build script stubbed (no tests of its own)."""

    def setUp(self):
        self.dir = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.dir)
        (self.dir / "scripts/ci").mkdir(parents=True)
        shutil.copy(SCRIPT, self.dir / "scripts/ci/ios_link_ffi.sh")
        (self.dir / "scripts/ci/ios_link_ffi_key.py").write_text(KEY_STUB)
        build = self.dir / "cmux-next-ios/rust/scripts/build-xcframework.sh"
        build.parent.mkdir(parents=True)
        build.write_text(BUILD_STUB)
        self.tmp = self.dir / "runner-temp"
        self.tmp.mkdir()
        self.count = self.dir / "builds.txt"

    def run_step(self, key="k1", **extra):
        env = {
            "PATH": os.environ["PATH"],
            "HOME": str(self.dir),
            "RUNNER_TEMP": str(self.tmp),
            "RUNNER_NAME": "blacksmith-6vcpu-macos-26-test",  # a hosted runner: always the Mac build
            "STUB_KEY": key,
            "STUB_COUNT": str(self.count),
            **extra,
        }
        return subprocess.run(["bash", "scripts/ci/ios_link_ffi.sh", "4"], cwd=self.dir, env=env,
                              capture_output=True, text=True)

    def builds(self):
        return len(self.count.read_text().splitlines()) if self.count.exists() else 0

class MacBuildMarkTest(Repo):
    """A hosted Mac with no client and no OIDC token (a fork's pull request): the one Mac build left."""

    def test_second_step_reuses_a_mac_build(self):
        first = self.run_step()
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        self.assertIn("Mac fallback", first.stdout)
        self.assertEqual((self.tmp / "link-ffi-fleet.key").read_text().strip(), "k1")
        second = self.run_step()
        self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
        self.assertIn("an earlier step's copy", second.stdout)
        self.assertEqual(self.builds(), 1)

    def test_changed_inputs_build_again(self):
        self.assertEqual(self.run_step(key="k1").returncode, 0)
        self.assertEqual(self.run_step(key="k2").returncode, 0)
        self.assertEqual(self.builds(), 2)
        self.assertEqual((self.tmp / "link-ffi-fleet.key").read_text().strip(), "k2")

    def test_a_failed_build_marks_nothing_and_keeps_its_exit(self):
        r = self.run_step(STUB_BUILD_FAIL="1")
        self.assertEqual(r.returncode, 7, r.stdout + r.stderr)
        self.assertFalse((self.tmp / "link-ffi-fleet.key").exists())

    def test_no_key_marks_nothing(self):
        r = self.run_step(key="")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertFalse((self.tmp / "link-ffi-fleet.key").exists())
        self.assertEqual(self.run_step(key="").returncode, 0)
        self.assertEqual(self.builds(), 2)


CLIENT_STUB = """#!/usr/bin/env bash
echo "$*" >> "$STUB_FLEET"
out=""; while [[ $# -gt 0 ]]; do [[ "$1" == --out ]] && out="$2"; shift; done
rc="${STUB_FLEET_RC:-0}"
if [[ "$rc" == 0 ]]; then mkdir -p "$out/CmuxMobileLinkFFI.xcframework"; echo fleet > "$out/CmuxMobileLinkFFI.xcframework/Info.plist"; fi
exit "$rc"
"""


class FleetTest(Repo):
    """The fleet is the builder: its copy is installed and marked; its red or no answer fails the step."""

    def setUp(self):
        super().setUp()
        self.fleet = self.dir / "fleet.txt"
        subprocess.run(["git", "init", "-q"], cwd=self.dir, check=True)
        subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "x"],
                       cwd=self.dir, check=True)
        client = self.dir / ".local/bin/cmux-ci"
        client.parent.mkdir(parents=True)
        client.write_text(CLIENT_STUB)
        client.chmod(0o755)
        route = self.dir / "scripts/ci/fleet_ios_build.py"
        route.write_text("import os, subprocess, sys\n"
                         "sys.exit(subprocess.call([os.environ['HOME'] + '/.local/bin/cmux-ci', 'route'] + sys.argv[1:]))\n")

    def run_fleet(self, **extra):
        return self.run_step(**{"STUB_FLEET": str(self.fleet), "RUNNER_NAME": "cmux-mac-1", **extra})

    def fleet_calls(self):
        return self.fleet.read_text().splitlines() if self.fleet.exists() else []

    def framework(self):
        return (self.dir / "cmux-next-ios/CmuxMobileKit/Frameworks/CmuxMobileLinkFFI.xcframework/Info.plist").read_text()

    def test_owned_mac_takes_the_fleet_copy(self):
        r = self.run_fleet()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertNotIn("Mac fallback", r.stdout)
        self.assertEqual(self.builds(), 0)
        self.assertEqual(self.framework().strip(), "fleet")
        self.assertIn("--queue-timeout 600", self.fleet_calls()[0])
        self.assertEqual((self.tmp / "link-ffi-fleet.key").read_text().strip(), "k1")
        again = self.run_fleet()
        self.assertIn("an earlier step's copy", again.stdout)
        self.assertEqual(len(self.fleet_calls()), 1)

    def test_a_fleet_red_fails_the_step_with_no_mac_build(self):
        r = self.run_fleet(STUB_FLEET_RC="1")
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("::error", r.stdout)
        self.assertIn("bindings", r.stdout)
        self.assertEqual(self.builds(), 0)
        self.assertFalse((self.tmp / "link-ffi-fleet.key").exists())

    def test_no_fleet_answer_fails_the_step_with_no_mac_build(self):
        r = self.run_fleet(STUB_FLEET_RC="2")
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("no answer from the build fleet", r.stdout)
        self.assertEqual(self.builds(), 0)

    def test_hosted_mac_asks_the_oidc_route(self):
        (self.dir / ".local/bin/cmux-ci").rename(self.dir / ".local/bin/stub")
        (self.dir / "scripts/ci/fleet_ios_build.py").write_text(
            "import os, subprocess, sys\n"
            "sys.exit(subprocess.call([os.environ['HOME'] + '/.local/bin/stub', 'route'] + sys.argv[1:]))\n")
        r = self.run_fleet(RUNNER_NAME="blacksmith-6vcpu-macos-26", ACTIONS_ID_TOKEN_REQUEST_URL="https://token.example")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.builds(), 0)
        self.assertTrue(self.fleet_calls()[0].startswith("route --what ffi"), self.fleet_calls())

    def test_the_kill_switch_builds_on_the_mac(self):
        r = self.run_fleet(CI_IOS_FFI_FLEET="0")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("Mac fallback", r.stdout)
        self.assertEqual(self.fleet_calls(), [])
        self.assertEqual(self.builds(), 1)


if __name__ == "__main__":
    unittest.main()
