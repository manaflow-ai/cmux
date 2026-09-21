#!/usr/bin/env python3

import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/app_host_test_inventory.py"
SPEC = importlib.util.spec_from_file_location("app_host_test_inventory", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


def sample_payload():
    return {
        "errors": [],
        "values": [
            {
                "testPlan": "cmux-unit",
                "enabledTests": [
                    {"identifier": "cmuxTests/FooTests/testOne"},
                    {"identifier": "cmuxTests/FooTests/testTwo"},
                    {"identifier": "cmuxTests/SwiftSuite/aSwiftTest()"},
                    {"identifier": "OtherTests/IgnoreTests/testNope"},
                ],
                "disabledTests": [
                    {"identifier": "cmuxTests/DisabledTests/testSkipped"},
                ],
            }
        ],
    }


def test_normalizes_flat_enumeration():
    report = MODULE.normalize(sample_payload())
    assert report["enabled_test_count"] == 3
    assert report["suite_count"] == 2
    assert report["disabled_test_count"] == 1
    assert report["suites"] == ["cmuxTests/FooTests", "cmuxTests/SwiftSuite"]
    assert report["test_plans"] == ["cmux-unit"]


def test_rejects_zero_enabled_cmux_tests():
    payload = sample_payload()
    payload["values"][0]["enabledTests"] = [
        {"identifier": "OtherTests/IgnoreTests/testNope"}
    ]
    try:
        MODULE.normalize(payload)
    except ValueError as error:
        assert "zero enabled cmuxTests" in str(error)
    else:
        raise AssertionError("zero enabled cmuxTests must fail")


def test_rejects_xcode_enumeration_errors():
    payload = sample_payload()
    payload["errors"] = ["bundle could not be loaded"]
    try:
        MODULE.normalize(payload)
    except ValueError as error:
        assert "bundle could not be loaded" in str(error)
    else:
        raise AssertionError("Xcode enumeration errors must fail")


def test_rejects_suite_only_identifier():
    payload = sample_payload()
    payload["values"][0]["enabledTests"] = [{"identifier": "cmuxTests/FooTests"}]
    try:
        MODULE.normalize(payload)
    except ValueError as error:
        assert "target/suite/test" in str(error)
    else:
        raise AssertionError("suite-only enumeration identifier must fail")


def test_cli_writes_normalized_inventory_and_summary():
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        raw = root / "raw.json"
        normalized = root / "normalized.json"
        summary = root / "summary.md"
        raw.write_text(json.dumps(sample_payload()), encoding="utf-8")
        completed = subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                str(raw),
                "--output",
                str(normalized),
                "--summary",
                str(summary),
                "--print-suites",
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        assert completed.returncode == 0, completed.stderr
        assert "3 enabled tests in 2 suites" in completed.stdout
        assert "ENUM_SUITE cmuxTests/FooTests" in completed.stdout
        report = json.loads(normalized.read_text(encoding="utf-8"))
        assert report["enabled_test_count"] == 3
        assert "compiled-test enumeration" in summary.read_text(encoding="utf-8")


if __name__ == "__main__":
    for name, value in sorted(globals().items()):
        if name.startswith("test_") and callable(value):
            value()
    print("ok")
