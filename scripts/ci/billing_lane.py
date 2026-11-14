#!/usr/bin/env python3
"""Routing and test selection for the Billing lane (.github/workflows/billing.yml).

Billing moves money, so every pull request that touches it runs every billing
test as its own check. This file is the one list of what "touches billing"
means. The workflow's `on.pull_request.paths` must equal the union of the
pattern lists below; tests/test_ci_billing_lane.py fails when they drift.

    billing_lane.py route              # writes web=, ios=, storekit= to $GITHUB_OUTPUT
    billing_lane.py web-tests          # every billing web test file, one per line
    billing_lane.py web-tests --db     # the CMUX_DB_TEST-gated subset of those

Patterns use GitHub's path filter syntax: `*` stops at `/`, `**` does not.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
from functools import lru_cache
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WEB = ROOT / "web"

# Edits to the lane itself run every job, so a pull request that changes the
# lane proves it on itself.
LANE_PATTERNS = (
    ".github/workflows/billing.yml",
    "scripts/ci/billing_lane.py",
    "tests/test_ci_billing_lane.py",
    "web/scripts/run-db-behavior-tests.sh",
)

WEB_PATTERNS = (
    "docs/billing/**",
    "web/services/billing/**",
    "web/services/vms/entitlements.ts",
    "web/services/vms/planUsage.ts",
    "web/app/api/billing/**",
    "web/app/api/stripe/**",
    "web/app/api/admin/subscriptions/**",
    "web/app/api/cron/apple-notifications/**",
    "web/app/api/cron/billing-*/**",
    "web/app/app-pricing/**",
    "web/dashboard-app/screens/billing/**",
    "web/orpc/server/dashboard/schemas/billing*",
    # Billing tables live in the shared schema; every migration can touch them.
    "web/db/schema*.ts",
    "web/db/migrations/**",
    "web/tests/apple-iap-*",
    "web/tests/billing-*",
    "web/tests/stripe-*",
    "web/tests/dashboard-billing-*",
    "web/tests/app-pricing-*",
    "web/tests/admin-*billing*",
    "web/tests/admin-*subscription*",
    "web/tests/*entitlement*",
    "web/tests/helpers/apple-*",
    "web/tests/helpers/*billing*",
)

IOS_PATTERNS = (
    "Packages/iOS/CmuxMobileBilling/**",
)

# Billing test files by name. Tests that exercise billing under another name
# are found by what they import (BILLING_IMPORT below).
TEST_NAME_GLOBS = (
    "apple-iap-*",
    "billing-*",
    "stripe-*",
    "dashboard-billing-*",
    "app-pricing-*",
    "cloud-billing-*",
    "vm-billing-*",
    "admin-*billing*",
    "admin-*subscription*",
    "*double-billing*",
    "*double-subscription*",
    "*entitlement*",
    "*plan-allowance*",
    "plan-usage*",
)

# A test that names a billing module in any string (an import, a dynamic
# import or a mock.module path) is a billing test.
BILLING_IMPORT = re.compile(
    r"""["'][^"'\n]*(?:"""
    r"services/billing(?:/|[\"'])"
    r"|services/vms/entitlements"
    r"|services/vms/planUsage"
    r"|app/api/billing/"
    r"|app/api/stripe/"
    r"|app/api/admin/subscriptions/"
    r"|app/api/cron/apple-notifications/"
    r"|app/api/cron/billing-"
    r"|app/app-pricing/"
    r"|dashboard-app/screens/billing/"
    r"|orpc/server/dashboard/schemas/billing"
    r""")[^"'\n]*["']"""
)
TEST_FILE = re.compile(r"(?:\.test|_test|\.spec|_spec)\.(?:js|jsx|ts|tsx|mjs|cjs|mts|cts)$")
DB_GATE = "process.env.CMUX_DB_TEST"


def workflow_paths() -> list[str]:
    """The pull_request path filter billing.yml must declare, in order."""
    return [*LANE_PATTERNS, *WEB_PATTERNS, *IOS_PATTERNS]


@lru_cache(maxsize=None)
def _compiled(pattern: str) -> re.Pattern[str]:
    out = []
    i = 0
    while i < len(pattern):
        if pattern.startswith("**/", i):
            out.append("(?:.*/)?")
            i += 3
        elif pattern.startswith("**", i):
            out.append(".*")
            i += 2
        elif pattern[i] == "*":
            out.append("[^/]*")
            i += 1
        elif pattern[i] == "?":
            out.append("[^/]")
            i += 1
        else:
            out.append(re.escape(pattern[i]))
            i += 1
    return re.compile("".join(out) + r"\Z")


def matches(path: str, patterns: tuple[str, ...] | list[str]) -> bool:
    return any(_compiled(pattern).match(path) for pattern in patterns)


def classify(paths: list[str]) -> dict[str, bool]:
    lane = any(matches(path, LANE_PATTERNS) for path in paths)
    ios = lane or any(matches(path, IOS_PATTERNS) for path in paths)
    return {
        "web": lane or any(matches(path, WEB_PATTERNS) for path in paths),
        "ios": ios,
        # The StoreKit simulator job rides on the iOS route; it skips cleanly
        # until a BillingStoreKitTests target exists.
        "storekit": ios,
    }


def changed_paths() -> list[str] | None:
    parent = subprocess.run(
        ["git", "rev-parse", "-q", "--verify", "HEAD^1"],
        cwd=ROOT, text=True, capture_output=True,
    )
    if parent.returncode != 0:
        return None
    diff = subprocess.run(
        ["git", "diff", "--no-renames", "--name-only", "-z", parent.stdout.strip(), "HEAD", "--"],
        cwd=ROOT, capture_output=True,
    )
    if diff.returncode != 0:
        return None
    return [os.fsdecode(path) for path in diff.stdout.split(b"\0") if path]


def route() -> int:
    every = {"web": True, "ios": True, "storekit": True}
    if os.environ.get("EVENT_NAME") == "workflow_dispatch":
        areas = every
    else:
        paths = changed_paths()
        if not paths:
            # Fail open: a missing diff must not skip money-critical tests.
            print("billing diff unavailable or empty; running every billing job")
            areas = every
        else:
            areas = classify(paths)
            touched = [path for path in paths if matches(path, workflow_paths())]
            print(f"{len(touched)} of {len(paths)} changed path(s) are billing paths:")
            for path in touched:
                print(f"  {path}")
    lines = "".join(f"{name}={'true' if value else 'false'}\n" for name, value in areas.items())
    print(lines, end="")
    output = os.environ.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a", encoding="utf-8") as handle:
            handle.write(lines)
    return 0


def _candidate_tests(web: Path) -> list[Path]:
    found = []
    for directory, subdirs, files in os.walk(web):
        subdirs[:] = sorted(d for d in subdirs if d != "node_modules" and not d.startswith("."))
        for name in files:
            if TEST_FILE.search(name):
                found.append(Path(directory) / name)
    return sorted(found)


def is_billing_test(path: Path, web: Path = WEB) -> bool:
    relative = path.relative_to(web).as_posix()
    if any(_compiled(glob).match(path.name) for glob in TEST_NAME_GLOBS):
        return True
    if matches(f"web/{relative}", WEB_PATTERNS) and not relative.startswith("tests/"):
        # A test that lives inside a billing module directory.
        return True
    return bool(BILLING_IMPORT.search(path.read_text(encoding="utf-8", errors="ignore")))


def web_tests(db_only: bool = False, web: Path = WEB) -> list[str]:
    selected = []
    for path in _candidate_tests(web):
        if not is_billing_test(path, web):
            continue
        if db_only and DB_GATE not in path.read_text(encoding="utf-8", errors="ignore"):
            continue
        selected.append("./" + path.relative_to(web).as_posix())
    return selected


def main(argv: list[str]) -> int:
    if argv == ["route"]:
        return route()
    if argv and argv[0] == "web-tests" and argv[1:] in ([], ["--db"]):
        files = web_tests(db_only=argv[1:] == ["--db"])
        if not files:
            print("no billing web tests selected; the selector is broken", file=sys.stderr)
            return 1
        print("\n".join(files))
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
