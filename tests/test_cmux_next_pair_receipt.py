import importlib.util
import json
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/cmux-next/validate-dogfood-pair-receipt.py"
SPEC = importlib.util.spec_from_file_location("pair_receipt", SCRIPT)
PAIR_RECEIPT = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
SPEC.loader.exec_module(PAIR_RECEIPT)


SHA = "cff9e2e9cff22df187c664b542c8047deba34d8b"
TAG = "nxd3"
BUNDLE = "dev.cmux.ios.nxd3"
DEVICE = "SIM-RECEIPT-TEST"


def receipt():
    return {
        "schema": "cmux-ios-dogfood-readiness-v1",
        "readiness": "mac-rpc",
        "git_sha": SHA,
        "tooling_checkout_sha": SHA,
        "tag": TAG,
        "bundle_id": BUNDLE,
        "target": "simulator_injection",
        "target_id": DEVICE,
        "mac_tag": TAG,
        "socket_path": "/tmp/cmux-debug-nxd3.sock",
        "readiness_latency_ms": 12,
        "attempt_count": 1,
        "connection_id": "connection",
        "client_id": "client",
        "workspace_count": 1,
        "stream_id": "stream",
        "transport": "iroh",
        "auth_proof": "stack_same_account_rpc",
        "installed_bundle": {
            "bundle_id": BUNDLE,
            "target": "simulator_injection",
            "target_id": DEVICE,
            "source": "installed_bundle",
            "metadata_source": "simulator_container",
            "source_git_sha": SHA,
            "dev_tag": TAG,
            "executable_sha256": "a" * 64,
        },
    }


def mac_info():
    return {
        "CFBundleIdentifier": "dev.cmuxterm.app.nxd3",
        "CFBundleExecutable": "cmux DEV nxd3",
        "CMUXGitSHA": SHA,
        "CMUXDevTag": TAG,
    }


class PairReceiptTests(unittest.TestCase):
    def test_exact_head_pair_passes_and_is_secret_free(self):
        summary = PAIR_RECEIPT.validate(
            receipt(), mac_info(), expected_sha=SHA, expected_tag=TAG, expected_bundle_id=BUNDLE
        )
        self.assertEqual(summary["status"], "pass")
        self.assertEqual(summary["source_sha"], SHA)
        self.assertNotIn("connection", json.dumps(summary))

    def test_stale_ios_source_fails_closed(self):
        value = receipt()
        value["git_sha"] = "0" * 40
        with self.assertRaisesRegex(PAIR_RECEIPT.ValidationError, "receipt.git_sha"):
            PAIR_RECEIPT.validate(value, mac_info(), expected_sha=SHA, expected_tag=TAG,
                                   expected_bundle_id=BUNDLE)

    def test_stale_mac_source_fails_closed(self):
        value = mac_info()
        value["CMUXGitSHA"] = "0" * 40
        with self.assertRaisesRegex(PAIR_RECEIPT.ValidationError, "Mac CMUXGitSHA"):
            PAIR_RECEIPT.validate(receipt(), value, expected_sha=SHA, expected_tag=TAG,
                                   expected_bundle_id=BUNDLE)

    def test_short_installed_and_mac_shas_match_exact_head(self):
        value = receipt()
        short_sha = SHA[:10]
        value["git_sha"] = short_sha
        value["installed_bundle"]["source_git_sha"] = short_sha
        info = mac_info()
        info["CMUXGitSHA"] = short_sha
        summary = PAIR_RECEIPT.validate(
            value, info, expected_sha=SHA, expected_tag=TAG, expected_bundle_id=BUNDLE
        )
        self.assertEqual(summary["source_sha"], SHA)

    def test_legacy_or_uninspected_bundle_is_not_pair_evidence(self):
        value = receipt()
        value["installed_bundle"]["metadata_source"] = "legacy_receipt_writer"
        with self.assertRaisesRegex(PAIR_RECEIPT.ValidationError, "inspected app bundle"):
            PAIR_RECEIPT.validate(value, mac_info(), expected_sha=SHA, expected_tag=TAG,
                                   expected_bundle_id=BUNDLE)

    def test_secret_like_fields_are_rejected(self):
        value = receipt()
        value["diagnostics"] = {"attach_token": "must never be recorded"}
        with self.assertRaisesRegex(PAIR_RECEIPT.ValidationError, "secret-like"):
            PAIR_RECEIPT.validate(value, mac_info(), expected_sha=SHA, expected_tag=TAG,
                                   expected_bundle_id=BUNDLE)

    def test_cli_reads_only_receipt_and_info_plist(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            receipt_path = root / "readiness.json"
            plist_path = root / "Info.plist"
            receipt_path.write_text(json.dumps(receipt()), encoding="utf-8")
            with plist_path.open("wb") as stream:
                plistlib.dump(mac_info(), stream)
            completed = subprocess.run(
                [
                    "python3", str(SCRIPT), "--receipt", str(receipt_path),
                    "--mac-info-plist", str(plist_path), "--expected-sha", SHA,
                    "--expected-tag", TAG, "--expected-bundle-id", BUNDLE,
                ], capture_output=True, text=True, check=False
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertEqual(json.loads(completed.stdout)["mac_provenance"], "Info.plist")


if __name__ == "__main__":
    unittest.main()
