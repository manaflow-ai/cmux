#!/usr/bin/env python3
"""Require actual passing native Keychain test cases from xcresult test nodes."""
import json
import sys

class NativeKeychainTestReceipt:
    suite = "MobileRemoteKeychainNativeIntegrationTests"
    required = frozenset({
        "signedDataProtectionKeychainSupportsCrudWithoutPrompt",
        "signedDataProtectionKeychainKeepsScopesIsolated",
    })

    def verify(self, payload):
        passed = set()
        def walk(node, ancestry=()):
            if not isinstance(node, dict):
                return
            names = ancestry + (node.get("name", ""), node.get("nodeIdentifier", ""))
            if node.get("nodeType") == "Test Case" and node.get("result") == "Passed":
                for name in self.required:
                    if any(self.suite in part for part in names) and any(
                        name + "(" in part or part == name for part in names
                    ):
                        passed.add(name)
            for child in node.get("children", []):
                walk(child, names)
        for node in payload.get("testNodes", []):
            walk(node)
        missing = sorted(self.required - passed)
        if missing:
            raise ValueError("iOS result lacks passing native Keychain tests: " + ", ".join(missing))

if __name__ == "__main__":
    try:
        with open(sys.argv[1]) as file:
            NativeKeychainTestReceipt().verify(json.load(file))
    except (OSError, ValueError, IndexError) as error:
        sys.exit(str(error))
    print("Both native Keychain integration tests executed and passed.")
