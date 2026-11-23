"""pair-e2e's phone and Mac share one build space, and the rig tells a refused pairing code from a taken one.

A tagged dev Mac's hostd registers in dev:<tag> (CMUX_BUILD_SPACE); a phone lists only its own space's Macs.
The plain Demo phone build is in the default space, lists 0 Macs and refuses the Mac's code, which the rig
reported as "the phone took the code" (GHA run 45045971899 and every VM run since #49943).
"""
import importlib.util
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("cmux_next_pair_e2e", ROOT / "scripts/ci/cmux_next_pair_e2e.py")
pair = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(pair)


class PairingCodeLineTests(unittest.TestCase):
    # The phone's two lines (cmux-next-ios LiveCoordinator+PairInvite.swift); the Mac id is private in the log.
    REFUSED = "pairing code for a space this account is not in"
    TAKEN = "pairing code for <private>"

    def test_refused_code_is_not_taken(self):
        self.assertIsNotNone(pair.CODE_REFUSED.search(self.REFUSED))
        self.assertIsNone(pair.CODE_TAKEN.search(self.REFUSED))

    def test_taken_code(self):
        self.assertIsNotNone(pair.CODE_TAKEN.search(self.TAKEN))
        self.assertIsNone(pair.CODE_REFUSED.search(self.TAKEN))

    def test_lines_match_the_phone_source(self):
        src = (ROOT / "cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileLive/LiveCoordinator+PairInvite.swift").read_text()
        self.assertIn(f'log.info("{self.REFUSED}")', src)
        self.assertIn('log.info("pairing code for \\(invite.mac', src)


class SharedBuildSpaceTests(unittest.TestCase):
    def test_phone_build_gets_the_mac_tag_as_its_dev_tag(self):
        sh = (ROOT / "scripts/ci/cmux-next-ios-sim.sh").read_text()
        block = re.search(r'if \[\[ "\$mode" == pair-e2e \]\]; then\n(.*?)\nfi\n', sh, re.S)
        self.assertIsNotNone(block, "pair-e2e's phone build settings block")
        self.assertIn('mac_tag="iospair-', block.group(1))
        self.assertIn('build_settings+=("CMUX_MOBILE_DEV_TAG=.$mac_tag")', block.group(1))
        # The tag is set before the phone build and the Mac build uses that same tag.
        self.assertLess(block.start(), sh.index("build_command=(xcodebuild"))
        self.assertEqual(sh.count('mac_tag="iospair-'), 1)
        self.assertIn('./scripts/reload.sh --tag "$mac_tag"', sh)



class HostStateDirectoryTests(unittest.TestCase):
    """The restart leg finds hostd's state folder where the Mac writes it: under the account namespace's
    subfolder (IPhoneHostService stateRoot/<storageNamespace>/cmux-mobile-host). VM run 45063909078 paired,
    then failed "no state directory .../cmux-mobile-host" because the leg looked only one level down."""

    def test_namespaced_folder_with_paired_devices_wins(self):
        import os
        import tempfile
        with tempfile.TemporaryDirectory() as support:
            self.assertIsNone(pair.host_state_directory(support))
            os.makedirs(os.path.join(support, "cmux-mobile-host"))
            nested = os.path.join(support, "staging", "cmux-mobile-host")
            os.makedirs(nested)
            open(os.path.join(nested, "paired-devices.json"), "w").close()
            self.assertEqual(pair.host_state_directory(support), nested)

    def test_top_level_folder_when_no_namespace(self):
        import os
        import tempfile
        with tempfile.TemporaryDirectory() as support:
            top = os.path.join(support, "cmux-mobile-host")
            os.makedirs(top)
            self.assertEqual(pair.host_state_directory(support), top)


if __name__ == "__main__":
    unittest.main()
