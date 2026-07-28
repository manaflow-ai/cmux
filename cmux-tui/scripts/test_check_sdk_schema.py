#!/usr/bin/env python3
"""Regression tests for SDK schema and runtime-inventory consistency."""

from __future__ import annotations

import copy
import importlib.util
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("check-sdk-schema.py")
SPEC = importlib.util.spec_from_file_location("check_sdk_schema", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot load {SCRIPT}")
CHECKER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECKER)


class DuplicateKeyTests(unittest.TestCase):
    def test_duplicate_object_keys_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "duplicate.json"
            path.write_text('{"event": 1, "event": 2}\n', encoding="utf-8")
            with self.assertRaisesRegex(CHECKER.SdkSchemaError, "duplicate JSON"):
                CHECKER.load_json(path)


class LiveSchemaTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.document = CHECKER.load_json(CHECKER.SPEC / "sdk-schema.json")
        cls.schema = CHECKER.load_json(CHECKER.SPEC / "sdk-schema.schema.json")
        cls.inventory = CHECKER.load_json(CHECKER.SPEC / "inventory.json")
        cls.ir = CHECKER.load_ir(CHECKER.SPEC / "sdk-schema.json")

    def validate(self, document: dict, inventory: dict) -> None:
        ir = CHECKER.load_ir_document(document)
        CHECKER.validate_sdk_ir(ir, document, self.schema, inventory)

    def test_live_schema_matches_runtime_inventory(self) -> None:
        CHECKER.validate_sdk_ir(
            self.ir,
            self.document,
            self.schema,
            self.inventory,
        )

    def test_missing_command_is_rejected(self) -> None:
        document = copy.deepcopy(self.document)
        document["commands"].pop("ping")
        with self.assertRaisesRegex(CHECKER.SdkSchemaError, "SDK command drift"):
            self.validate(document, self.inventory)

    def test_wrong_command_authority_is_rejected(self) -> None:
        document = copy.deepcopy(self.document)
        document["commands"]["ping"]["authority"] = "frontend"
        with self.assertRaisesRegex(CHECKER.SdkSchemaError, "authority drift"):
            self.validate(document, self.inventory)

    def test_missing_request_field_is_rejected(self) -> None:
        document = copy.deepcopy(self.document)
        document["commands"]["send"]["request"]["fields"].pop("surface")
        with self.assertRaisesRegex(CHECKER.SdkSchemaError, "request field"):
            self.validate(document, self.inventory)

    def test_wrong_request_field_presence_is_rejected(self) -> None:
        document = copy.deepcopy(self.document)
        document["commands"]["send"]["request"]["fields"]["paste"]["presence"] = "required"
        with self.assertRaisesRegex(CHECKER.SdkSchemaError, "presence drift"):
            self.validate(document, self.inventory)

    def test_wrong_request_field_type_is_rejected(self) -> None:
        document = copy.deepcopy(self.document)
        document["commands"]["resize-surface"]["request"]["fields"]["cols"]["type"] = {
            "kind": "scalar",
            "name": "uint32",
        }
        with self.assertRaisesRegex(CHECKER.SdkSchemaError, "type drift"):
            self.validate(document, self.inventory)

    def test_wrong_flattened_request_alias_is_rejected(self) -> None:
        document = copy.deepcopy(self.document)
        document["commands"]["create-workspace"]["request"]["fields"][
            "expected_revision"
        ]["aliases"] = []
        with self.assertRaisesRegex(CHECKER.SdkSchemaError, "alias drift"):
            self.validate(document, self.inventory)

    def test_wrong_event_stream_is_rejected(self) -> None:
        document = copy.deepcopy(self.document)
        document["events"]["bell"]["streams"] = ["attach-byte"]
        with self.assertRaisesRegex(CHECKER.SdkSchemaError, "event stream drift"):
            self.validate(document, self.inventory)


if __name__ == "__main__":
    unittest.main()
