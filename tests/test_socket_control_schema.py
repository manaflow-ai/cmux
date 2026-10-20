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


if __name__ == "__main__":
    unittest.main()
