"""The owner proof establishes explicit-off state instead of assuming a default."""
import sys
import subprocess
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts/ci"))
import cmux_next_owner_access_proof as proof


class ExplicitOffTests(unittest.TestCase):
    def test_pretty_cli_receipt_is_read_as_one_object(self):
        result = subprocess.CompletedProcess([], 0, '{\n  "devices": [\n    {"id": "phone"}\n  ]\n}\n', '')
        with patch.object(proof.subprocess, "run", return_value=result):
            self.assertEqual(proof._cli("acpmux", {}, ["ticket", "ls"], namespace="host"),
                             {"devices": [{"id": "phone"}]})

    def test_on_by_default_is_turned_off_and_read_back(self):
        on = {"id": "phone", "role": "phone", "revoked_at": None, "full_access": True}
        off = dict(on, full_access=False)
        with patch.object(proof, "_cli", side_effect=[{"devices": [on]}, {"device": off},
                                                     {"devices": [off]}]) as cli:
            proof._start_with_full_access_off("acpmux", {"ACPMUX_HOME": "/proof/owned"})
        self.assertEqual(cli.call_args_list[1].args[2], ["ticket", "full-access", "phone", "off"])
        self.assertEqual(cli.call_args_list[2].args[2], ["ticket", "ls"])

    def test_success_response_with_setting_still_on_is_refused(self):
        on = {"id": "phone", "role": "phone", "full_access": True}
        with patch.object(proof, "_cli", side_effect=[{"devices": [on]},
                         {"device": dict(on, full_access=False)}, {"devices": [on]}]):
            with self.assertRaises(proof.ProofFailure):
                proof._start_with_full_access_off("acpmux", {"ACPMUX_HOME": "/proof/owned"})

    def test_ambiguous_or_revoked_phone_is_never_changed(self):
        phone = {"id": "phone", "role": "phone"}
        for devices in ([], [phone, dict(phone, id="other")], [dict(phone, revoked_at="now")]):
            with self.subTest(devices=devices), patch.object(proof, "_cli", return_value={"devices": devices}) as cli:
                with self.assertRaises(proof.ProofFailure):
                    proof._start_with_full_access_off("acpmux", {"ACPMUX_HOME": "/proof/owned"})
                self.assertEqual(cli.call_count, 1)

    def test_shared_daemon_environment_is_refused_before_cli(self):
        for env in ({}, {"ACPMUX_HOME": "/proof/owned", "ACPMUX_SOCKET": "/shared.sock"}):
            with patch.object(proof, "_cli") as cli:
                with self.assertRaises(proof.ProofFailure):
                    proof._start_with_full_access_off("acpmux", env)
                cli.assert_not_called()


if __name__ == "__main__":
    unittest.main()
