"""Regression cases for the pairing lint's test scope and production defaults."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location(
    "pairing_lint", Path(__file__).with_name("test_pairing_scheme_is_explicit_in_tests.py")
)
lint = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lint)


class PairingLintTests(unittest.TestCase):
    def test_root_and_package_test_targets_are_guarded(self):
        for root in ("cmuxTests", "cmuxUITests", "ios/cmuxUITests", "cmuxCLITests",
                     "cmuxCLITestSupport", "Packages/Shared/Core/Tests/CoreTests"):
            with self.subTest(root=root):
                self.assertTrue(lint.is_test_file(root + "/PairingTests.swift"))
                self.assertTrue(lint.implicit_calls("payload.encodedURL()"))
        self.assertFalse(lint.is_test_file("Sources/Pairing.swift"))

    def test_each_entry_point_requires_its_own_default(self):
        for _, method in lint.ENTRY_POINT_DECLARATIONS.values():
            with self.subTest(method=method):
                declaration = (f"public func {method}(pairingURLScheme: CmxPairingURLScheme? =\n"
                               " CmxPairingURLSchemeResolver().resolved) throws -> URL {}")
                self.assertTrue(lint.declaration_uses_resolver(declaration, method))
                removed = declaration.replace("CmxPairingURLSchemeResolver().resolved", "nil")
                comment = "/// Defaults to CmxPairingURLSchemeResolver().resolved\n"
                other = "func unrelated(pairingURLScheme: CmxPairingURLScheme? = CmxPairingURLSchemeResolver().resolved) {}"
                self.assertFalse(lint.declaration_uses_resolver(comment + removed + other, method))
                self.assertFalse(lint.declaration_uses_resolver("/* " + declaration + " */\n" + removed, method))


if __name__ == "__main__":
    unittest.main()
