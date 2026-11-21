#!/usr/bin/env python3
"""The test-determinism allowlist only shrinks for the rules whose debt is paid off.

.github/test-determinism-allowlist.txt grandfathers findings that predate a rule. For the rules below the
debt is gone (cmux#40871 added them; its follow-up moved the last 13 predictable-tmp-path files to private
mkdtemp / mktemp -d folders), so an entry for one of them is new debt: fix the test instead. Lowering a
ceiling here is the only edit this file should get.
Run: python3 -I tests/test_determinism_allowlist_ratchet.py
"""
import importlib.util
import sys
import unittest
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ALLOWLIST = ROOT / ".github" / "test-determinism-allowlist.txt"
_spec = importlib.util.spec_from_file_location("check_test_determinism", ROOT / "scripts" / "check-test-determinism.py")
determinism = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = determinism  # its dataclasses look their module up by name
_spec.loader.exec_module(determinism)

# Most entries each rule may have. Only ever lower these.
CEILING = {
    determinism.RULE_PREDICTABLE_TMP_PATH: 0,
    "git-temp-repo-maintenance": 0,
    "git-fixture-env-dropped": 0,
    "git-bare-repo-unmanaged": 0,
    "isolated-import": 0,
}


class AllowlistRatchet(unittest.TestCase):
    def test_the_ceilings_name_real_rules(self):
        self.assertLessEqual(set(CEILING), set(determinism.ALL_RULES))

    def test_no_rule_is_over_its_ceiling(self):
        entries = sorted(determinism.load_allowlist(ALLOWLIST))
        counts = Counter(rule for _path, rule in entries)
        for rule, ceiling in CEILING.items():
            with self.subTest(rule):
                listed = [path for path, entry_rule in entries if entry_rule == rule]
                self.assertLessEqual(counts[rule], ceiling,
                                     f"{rule}: {counts[rule]} allowlist entries, at most {ceiling} allowed; fix "
                                     f"the test (a private mkdtemp / mktemp -d folder) instead: {listed}")


if __name__ == "__main__":
    unittest.main()
