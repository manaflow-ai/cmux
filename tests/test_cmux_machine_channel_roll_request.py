"""MACHINE_CHANNEL_ROLL (#64621): the Cloud VM image roll is requested from the Linux machine build, not behind Mac legs."""
import pathlib
import unittest

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]
NOT_CONSUMED = ("build", "build-darwin-fallback", "darwin-fallback-plan", "build-aarch64", "build-windows", "publish")


class MachineRollRequest(unittest.TestCase):
    def setUp(self):
        self.jobs = yaml.safe_load((ROOT / ".github/workflows/cmux-machine-channel.yml").read_text())["jobs"]

    def test_the_roll_is_requested_once_the_linux_machine_build_is_pointed(self):
        job = self.jobs["request-image-roll"]
        self.assertEqual(job["needs"], ["point-linux"])
        self.assertIn("point-linux.result == 'success'", job["if"])
        self.assertIn("refs/heads/feat-cmux-next", job["if"])

    def test_no_leg_the_image_does_not_consume_gates_the_request(self):
        needs = self.jobs["request-image-roll"]["needs"]
        for name in NOT_CONSUMED:
            self.assertNotIn(name, needs)

    def test_it_dispatches_the_roll_for_this_commit(self):
        text = yaml.safe_dump(self.jobs["request-image-roll"])
        self.assertIn("cloud-vm-image-roll.yml", text)
        self.assertIn('commit="$GITHUB_SHA"', text)

    def test_the_image_lock_pins_only_the_x86_64_musl_programs(self):
        pin = (ROOT / "images/cmux-vm/pin-cmux-tui.ts").read_text()
        self.assertIn('const TARGET = "x86_64-unknown-linux-musl"', pin)


if __name__ == "__main__":
    unittest.main()
