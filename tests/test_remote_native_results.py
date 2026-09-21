"""Behavioral acceptance of xcresult native test receipts."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location(
    "native_receipt", Path(__file__).resolve().parents[1] / "scripts/verify-remote-native-tests.py"
)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class NativeReceiptTests(unittest.TestCase):
    def receipt(self, results=("Passed", "Passed")):
        names = sorted(module.NativeKeychainTestReceipt.required)
        return {"testNodes": [{
            "name": "MobileRemoteKeychainNativeIntegrationTests",
            "nodeType": "Test Suite",
            "children": [{"nodeType": "Test Case", "name": name + "()", "result": result}
                         for name, result in zip(names, results)]
        }]}

    def test_accepts_both_executed_tests(self):
        module.NativeKeychainTestReceipt().verify(self.receipt())

    def test_rejects_skipped_failed_expected_failure_and_missing(self):
        for result in ("Skipped", "Failed", "Expected Failure", "unknown", None):
            with self.subTest(result=result), self.assertRaises(ValueError):
                module.NativeKeychainTestReceipt().verify(self.receipt(("Passed", result)))
        with self.assertRaises(ValueError):
            module.NativeKeychainTestReceipt().verify(self.receipt(("Passed",)))
        with self.assertRaises(ValueError):
            module.NativeKeychainTestReceipt().verify({"testNodes": []})

    def test_similar_methods_in_different_suite_do_not_pass(self):
        payload = self.receipt()
        payload["testNodes"][0]["name"] = "UnrelatedTests"
        with self.assertRaises(ValueError):
            module.NativeKeychainTestReceipt().verify(payload)

    def test_suite_only_result_is_not_execution(self):
        payload = self.receipt()
        for test in payload["testNodes"][0]["children"]:
            test["nodeType"] = "Test Suite"
        with self.assertRaises(ValueError):
            module.NativeKeychainTestReceipt().verify(payload)

if __name__ == "__main__":
    unittest.main()
