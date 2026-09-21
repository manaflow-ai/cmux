import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/app_host_layer_consumers.py"
import sys
sys.path.insert(0, str(SCRIPT.parent))
spec = importlib.util.spec_from_file_location("consumers", SCRIPT)
c = importlib.util.module_from_spec(spec)
spec.loader.exec_module(c)


class ConsumerPolicyTests(unittest.TestCase):
    def test_current_consumers_are_explicit_and_select_canonical_runtime_closure(self):
        policy = c.load_policy()
        expected = {f"app-host-unit-tests/{shard}" for shard in range(1, 7)} | {"tests-build-and-lag"}
        self.assertEqual((policy["schema"], policy["version"]), (c.SCHEMA, 1))
        self.assertEqual(set(policy["consumers"]), expected)
        for name in expected:
            self.assertEqual(c.required_layers(name, policy), ("app-cli", "runtime", "tests"))

    def test_unknown_consumer_fails_closed(self):
        with self.assertRaisesRegex(ValueError, "unknown app-host product consumer"):
            c.required_layers("future-consumer")

    def test_policy_rejects_unknown_duplicate_or_reordered_layers(self):
        original = c.load_policy()
        for layers in (["app-cli", "unknown"], ["app-cli", "tests", "tests"], ["runtime", "app-cli"]):
            with self.subTest(layers=layers):
                value = copy.deepcopy(original)
                value["consumers"]["tests-build-and-lag"] = layers
                with tempfile.TemporaryDirectory() as temporary:
                    path = Path(temporary) / "policy.json"
                    path.write_text(json.dumps(value))
                    with self.assertRaises(ValueError):
                        c.load_policy(path)


if __name__ == "__main__":
    unittest.main()
