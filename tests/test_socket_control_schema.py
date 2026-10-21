#!/usr/bin/env python3
import json
from pathlib import Path
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]


class SocketControlSchemaTests(unittest.TestCase):
    def socket_settings(self):
        schema = json.loads((REPO_ROOT / "web" / "data" / "cmux.schema.json").read_text())
        return schema["properties"]["automation"]["properties"]

    def test_default_matches_the_same_user_runtime_contract(self):
        mode = self.socket_settings()["socketControlMode"]
        self.assertEqual(mode["default"], "automation")
        self.assertIn("same OS user", mode["description"])

    def test_unusable_plaintext_password_mode_is_not_published(self):
        settings = self.socket_settings()
        self.assertNotIn("password", settings["socketControlMode"]["enum"])
        self.assertNotIn("socketPassword", settings)

    def test_cross_user_modes_are_not_published(self):
        modes = self.socket_settings()["socketControlMode"]["enum"]
        for legacy in ("allowAll", "openAccess", "fullOpenAccess", "full"):
            self.assertNotIn(legacy, modes)


if __name__ == "__main__":
    unittest.main()
