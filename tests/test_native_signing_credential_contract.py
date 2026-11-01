#!/usr/bin/env python3
"""Guard native credentials from regressing to raw secret files."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
KEYCHAIN = ROOT / "scripts/ci/signing-keychain.sh"
NOTARY = ROOT / "scripts/ci/lib/notary-auth.sh"
FD_FIXTURE = ROOT / "tests/test_signing_keychain_fd_import.sh"
NATIVE = ROOT / "scripts/ci/release-signer"


class NativeCredentialContractTests(unittest.TestCase):
    def test_keychain_native_import_is_fd_and_explicitly_pkcs12(self):
        text = KEYCHAIN.read_text()
        create = text[text.index("create_keychain()"):text.index("unlock_keychains()")]
        self.assertIn("exec 3< <(", create)
        self.assertIn("import /dev/fd/3", create)
        self.assertIn("-f pkcs12", create)
        self.assertIn("default-keychain -d user -s", create)
        self.assertIn("restore_default_keychain", text)

    def test_notary_native_profile_is_fd_backed(self):
        text = NOTARY.read_text()
        self.assertIn("CMUX_NOTARY_USE_KEYCHAIN_PROFILE", text)
        self.assertIn("exec 3< <(", text)
        self.assertIn("--key /dev/fd/3", text)
        self.assertIn("--keychain-profile", text)
        self.assertIn("--keychain", text)
        self.assertIn("NOTARY_AUTH_MODE=keychain-profile", text)

    def test_native_wrappers_select_profile_mode(self):
        wrappers = sorted(NATIVE.glob("native-*.sh"))
        self.assertGreaterEqual(len(wrappers), 2)
        for path in wrappers:
            text = path.read_text()
            self.assertIn("CMUX_NOTARY_USE_KEYCHAIN_PROFILE=true", text, path.name)
            self.assertNotIn("--key \\\"$", text, path.name)

    def test_fixture_proves_fd_import_without_secret_paths(self):
        text = FD_FIXTURE.read_text()
        self.assertIn("import /dev/fd/3", text)
        self.assertIn("-f pkcs12", text)
        self.assertNotIn("identity.p12", text)
        self.assertNotIn("AuthKey_", text)
        self.assertNotIn("> \\\"$TMP_DIR/", text)


if __name__ == "__main__":
    unittest.main()
