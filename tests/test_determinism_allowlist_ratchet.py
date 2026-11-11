#!/usr/bin/env python3
"""The test-determinism allowlist only shrinks: per rule, and to zero for the rules whose debt is paid off.

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

# The old debt the per-function allowlist started from (cmux#41271, 2026-11-11), counted per rule without the hang
# guards: a new finding is fixed at the test (a recorded clock, a real completion signal, the n-vs-4n scaling ratio),
# never listed. Only ever lower these, as tests are fixed and their entries go (--strict fails a stale one).
DEBT_CEILING = {
    "sleep-then-assert": 247,
    "assert-on-duration": 170,
    "yield-count-poll": 41,
    "live-network-host": 3,
}


class AllowlistRatchet(unittest.TestCase):
    def test_the_ceilings_name_real_rules(self):
        self.assertLessEqual(set(CEILING), set(determinism.ALL_RULES))

    def test_no_rule_is_over_its_ceiling(self):
        entries = sorted(determinism.load_allowlist(ALLOWLIST))
        counts = Counter(rule for _path, _function, rule in entries)
        for rule, ceiling in CEILING.items():
            with self.subTest(rule):
                listed = [f"{path} {function}" for path, function, entry_rule in entries if entry_rule == rule]
                self.assertLessEqual(counts[rule], ceiling,
                                     f"{rule}: {counts[rule]} allowlist entries, at most {ceiling} allowed; fix "
                                     f"the test (a private mkdtemp / mktemp -d folder) instead: {listed}")

    def test_old_debt_only_shrinks(self):
        entries = determinism.load_allowlist_entries(ALLOWLIST)
        debt = Counter(entry.rule for entry in entries if not entry.is_hang_guard)
        for rule in set(debt) | set(DEBT_CEILING):
            with self.subTest(rule):
                listed = [f"{e.path} {e.function}" for e in entries if e.rule == rule and not e.is_hang_guard]
                self.assertLessEqual(debt[rule], DEBT_CEILING.get(rule, CEILING.get(rule, 0)),
                                     f"{rule}: {debt[rule]} debt entries, at most {DEBT_CEILING.get(rule, 0)}: fix the "
                                     f"test instead of listing it (a hang guard's reason starts 'hang guard:'): "
                                     f"{listed[-5:]}")

    def test_a_hang_guard_bounds_a_duration_and_says_what_would_hang(self):
        # A hang guard is a deadline-only bound, well above any normal run, kept so a hang fails instead of stalling
        # CI. Its entry names what would hang; it is never a sleep or a poll by another name.
        for entry in determinism.load_allowlist_entries(ALLOWLIST):
            if entry.is_hang_guard:
                with self.subTest(f"{entry.path} {entry.function}"):
                    self.assertEqual(entry.rule, "assert-on-duration")
                    self.assertGreater(len(entry.reason) - len(determinism.HANG_GUARD_PREFIX), 10, entry.reason)


if __name__ == "__main__":
    unittest.main()
