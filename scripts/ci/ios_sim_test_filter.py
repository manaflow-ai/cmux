#!/usr/bin/env python3
"""Fail a simulator test run whose filter selected no test.

`xcodebuild test -only-testing:X` runs nothing and exits 0 when X names no test
(a suite in another target, a typo), so a proof run can pass having run zero
tests. cmux-next-ios-sim.sh calls this after each filtered run with the result
bundle's test tree (`xcrun xcresulttool get test-results tests --compact`, which
keep_test_logs saves as NAME-tests.json) and the filter items it passed:

  python3 -I scripts/ci/ios_sim_test_filter.py TESTS_JSON ITEM [ITEM...]

ITEM is TARGET, TARGET/SUITE or TARGET/SUITE/test (the -only-testing: form,
with or without that prefix). Exit 0 when every item matched at least one test
case that ran (passed, failed or expected failure); exit 1 naming each item that
matched none, and when the tree is missing or holds no test case at all.
"""

import json
import sys

PREFIX = "-only-testing:"
RAN = {"Passed", "Failed", "Expected Failure"}
BUNDLES = {"Unit test bundle", "UI test bundle"}


def cases(node, target=None, suites=()):
    """Yield (target, suites, case name, result) for every test case under node."""
    kind = node.get("nodeType")
    name = node.get("name", "")
    if kind in BUNDLES:
        target = name
    elif kind == "Test Suite":
        suites = suites + (name,)
    elif kind == "Test Case":
        yield target, suites, name, node.get("result")
        return
    for child in node.get("children") or []:
        yield from cases(child, target, suites)


def matches(item, target, suites, case):
    parts = item.split("/")
    if parts[0] != target:
        return False
    if len(parts) >= 2 and parts[1] not in suites:
        return False
    if len(parts) == 3 and case.split("(")[0] != parts[2].split("(")[0]:
        return False
    return True


def check(tree, items):
    """Return the problems, one line each; empty when every item ran a test."""
    found = [c for root in (tree or {}).get("testNodes") or [] for c in cases(root)]
    if not found:
        return ["no test case ran at all (filter: %s)" % ",".join(items)]
    problems = []
    for item in items:
        hit = [c for c in found if matches(item, c[0], c[1], c[2])]
        if not hit:
            targets = sorted({c[0] for c in found if c[0]})
            problems.append("%s matched no test (targets that ran: %s)" % (item, ", ".join(targets) or "none"))
        elif not any(c[3] in RAN for c in hit):
            problems.append("%s matched %d test(s), none ran (all skipped)" % (item, len(hit)))
    return problems


def main(argv):
    if len(argv) < 3:
        print("usage: ios_sim_test_filter.py TESTS_JSON ITEM [ITEM...]", file=sys.stderr)
        return 2
    items = [a[len(PREFIX):] if a.startswith(PREFIX) else a for a in argv[2:]]
    try:
        with open(argv[1]) as f:
            tree = json.load(f)
    except (OSError, ValueError) as error:
        tree = None
        print("ios_sim_test_filter: no readable test tree at %s (%s)" % (argv[1], error), file=sys.stderr)
    problems = check(tree, items)
    for line in problems:
        print("test filter: FAIL: " + line)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
