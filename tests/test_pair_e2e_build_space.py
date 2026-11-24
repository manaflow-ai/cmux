"""The pair-e2e phone must be linked to this run's Mac, in the same tagged build space."""
import importlib.util
import json
from pathlib import Path
import re
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("cmux_next_pair_e2e", ROOT / "scripts/ci/cmux_next_pair_e2e.py")
pair = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(pair)


class PairingReceiptTests(unittest.TestCase):
    def test_only_current_link_to_rig_mac_is_evidence(self):
        receipt = {
            "nonce": "current", "signed_in": True, "phone_device_ids": ["Phone-A"],
            "paired_macs": [{"id": "rig", "linked": False}, {"id": "other", "linked": True}],
        }
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "readiness.json"
            path.write_text(json.dumps(receipt))
            self.assertFalse(pair.phone_receipt_ids(path, "stale", "rig", linked=False))
            self.assertEqual(pair.phone_receipt_ids(path, "current", "rig", linked=False), {"phone-a"})
            self.assertFalse(pair.phone_receipt_ids(path, "current", "rig", linked=True))
            receipt["paired_macs"][0]["linked"] = True
            path.write_text(json.dumps(receipt))
            self.assertEqual(pair.phone_receipt_ids(path, "current", "rig", linked=True), {"phone-a"})

    def test_mac_must_list_the_same_phone_paired_and_connected(self):
        card = {"phones": [
            {"id": "other", "paired": True, "connected": True},
            {"id": "Phone-A", "paired": True, "connected": False},
        ]}
        self.assertFalse(pair.connected_phone(card, {"phone-a"}))
        card["phones"][1]["connected"] = True
        self.assertTrue(pair.connected_phone(card, {"phone-a"}))


class SharedBuildSpaceTests(unittest.TestCase):
    def test_phone_build_gets_the_mac_tag_as_its_dev_tag(self):
        sh = (ROOT / "scripts/ci/cmux-next-ios-sim.sh").read_text()
        blocks = re.finditer(r'^if \[\[ "\$mode" == pair-e2e \]\]; then\n(.*?)^fi$', sh, re.M | re.S)
        block = next((match for match in blocks if 'mac_tag="iospair-' in match.group(1)), None)
        self.assertIsNotNone(block, "pair-e2e's phone build settings block")
        self.assertIn('mac_tag="iospair-', block.group(1))
        self.assertIn('"CMUX_MOBILE_DEV_TAG=.$mac_tag"', block.group(1))
        self.assertIn('"CMUX_MOBILE_TAG=.$mac_tag"', block.group(1))
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
        with tempfile.TemporaryDirectory() as support:
            self.assertIsNone(pair.host_state_directory(support))
            os.makedirs(os.path.join(support, "cmux-mobile-host"))
            nested = os.path.join(support, "staging", "cmux-mobile-host")
            os.makedirs(nested)
            open(os.path.join(nested, "paired-devices.json"), "w").close()
            self.assertEqual(pair.host_state_directory(support), nested)

    def test_top_level_folder_when_no_namespace(self):
        import os
        with tempfile.TemporaryDirectory() as support:
            top = os.path.join(support, "cmux-mobile-host")
            os.makedirs(top)
            self.assertEqual(pair.host_state_directory(support), top)


if __name__ == "__main__":
    unittest.main()
