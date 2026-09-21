import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/app_host_test_inventory.py"
SPEC = importlib.util.spec_from_file_location("app_host_test_inventory", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def document(enabled=(), disabled=(), errors=()):
    return {
        "errors": list(errors),
        "values": [{
            "testPlan": "cmux-unit",
            "enabledTests": [{"identifier": x} for x in enabled],
            "disabledTests": [{"identifier": x} for x in disabled],
        }],
    }


class AppHostTestInventoryTests(unittest.TestCase):
    def test_normalizes_flat_built_inventory(self) -> None:
        result = MODULE.normalize(
            document(
                enabled=[
                    "cmuxTests/ExampleTests/testOne",
                    "cmuxTests/ExampleTests/testTwo",
                    "cmuxTests/SwiftSuite/a parameterized test()",
                ],
                disabled=["cmuxTests/SkippedTests/testLater"],
            ),
            required_target="cmuxTests",
        )

        self.assertEqual(result["enabled_test_count"], 3)
        self.assertEqual(result["disabled_test_count"], 1)
        self.assertEqual(result["suite_count"], 2)
        self.assertEqual(
            result["enabled_tests_by_suite"],
            {
                "cmuxTests/ExampleTests": 2,
                "cmuxTests/SwiftSuite": 1,
            },
        )
        self.assertEqual(result["test_plans"], ["cmux-unit"])

    def test_rejects_zero_enabled_tests(self) -> None:
        with self.assertRaisesRegex(ValueError, "zero enabled tests"):
            MODULE.normalize(document(), required_target="cmuxTests")

    def test_rejects_enumeration_errors(self) -> None:
        with self.assertRaisesRegex(ValueError, "bundle failed to load"):
            MODULE.normalize(
                document(errors=[{"message": "bundle failed to load"}]),
                required_target="cmuxTests",
            )

    def test_rejects_enabled_disabled_overlap(self) -> None:
        identifier = "cmuxTests/ExampleTests/testOne"
        with self.assertRaisesRegex(ValueError, "both enabled and disabled"):
            MODULE.normalize(
                document(enabled=[identifier], disabled=[identifier]),
                required_target="cmuxTests",
            )

    def test_rejects_other_test_targets(self) -> None:
        with self.assertRaisesRegex(ValueError, "outside cmuxTests"):
            MODULE.normalize(
                document(enabled=["cmuxTests/A/testA", "cmuxUITests/B/testB"]),
                required_target="cmuxTests",
            )

    def test_reproducible_json_order(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            source = Path(temp_dir) / "raw.json"
            source.write_text(
                json.dumps(document(enabled=["cmuxTests/Z/testB", "cmuxTests/A/testA"])),
                encoding="utf-8",
            )
            normalized = MODULE.normalize(
                MODULE.load_inventory(source),
                required_target="cmuxTests",
            )
        self.assertEqual(
            normalized["enabled_tests"],
            ["cmuxTests/A/testA", "cmuxTests/Z/testB"],
        )


if __name__ == "__main__":
    unittest.main()
