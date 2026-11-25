"""cmux-next-ios-sim.sh puts the simulator device set on the boot volume when the step's checkout is not on it.

aws-m4pro-3, 2026-11-17..21: its job root is the NVMe instance store /Volumes/ephemeral0. TCC refuses
CoreSimulatorService there (even root gets "Operation not permitted" listing the volume), so every
`simctl --set <checkout>/.build/ios-sim/sims create` failed EINVAL (NSPOSIXErrorDomain 22) and the host was
excluded while 23 simulator steps queued up to 14.6 h. A set under $TMPDIR (the boot volume) creates fine there.
"""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/ci/cmux-next-ios-sim.sh"


def block():
    script = SCRIPT.read_text()
    start = script.index("# sim_create NAME DEVICE_TYPE RUNTIME [SET]")
    return script[start:script.index("# --- end sim_create", start)]


class SimSetVolumeTests(unittest.TestCase):
    def set_dir(self, work, mount):
        tmp = tempfile.mkdtemp(prefix="cmux-sim-set-")
        self.addCleanup(__import__("shutil").rmtree, tmp, True)
        harness = Path(tmp) / "h.sh"
        harness.write_text("set -euo pipefail\n" + block() + '\nsim_set_dir "$1" "$2"\n')
        env = {**os.environ, "CMUX_CI_SIM_SET_ROOT": tmp}
        r = subprocess.run(["bash", str(harness), work, mount], env=env, text=True, capture_output=True, timeout=20)
        self.assertEqual(r.returncode, 0, r.stderr)
        return r.stdout.strip(), tmp

    def test_a_checkout_on_the_boot_volume_keeps_its_set(self):
        work = tempfile.mkdtemp(prefix="cmux-sim-work-")
        self.addCleanup(__import__("shutil").rmtree, work, True)
        for mount in ("/", "/System/Volumes/Data"):
            got, _ = self.set_dir(work, mount)
            self.assertEqual(got, work + "/sims", mount)
            self.assertTrue(Path(got).is_dir())

    def test_a_checkout_on_another_volume_gets_a_set_on_the_boot_volume(self):
        got, root = self.set_dir("/Volumes/ephemeral0/cmux-ci/steps/x/src/.build/ios-sim", "/Volumes/ephemeral0")
        self.assertTrue(got.startswith(root + "/cmux-ios-sim-sims."), got)
        self.assertTrue(Path(got).is_dir(), "the set directory is made")
        other, _ = self.set_dir("/Volumes/ephemeral0/a/.build/ios-sim", "/Volumes/ephemeral0")
        self.assertNotEqual(got, other, "two steps never share one set")

    def test_the_step_uses_it_and_its_cleanup_removes_it(self):
        script = SCRIPT.read_text()
        self.assertIn('sims="$(sim_set_dir "$work" "$(df -P "$work" | awk \'NR==2 {print $6}\')")"', script)
        self.assertNotIn('sims="$work/sims"', script)
        self.assertIn('rm -rf "$sims"', script[script.index("cleanup() {"):])


if __name__ == "__main__":
    unittest.main()
