#!/usr/bin/env python3
"""Routing and test selection for the Billing lane (.github/workflows/billing.yml).

Billing moves money, so every pull request that touches it runs every billing
test as its own check. This file is the one list of what "touches billing"
means. The workflow's `on.pull_request.paths` must equal the union of the
pattern lists below; tests/test_ci_billing_lane.py fails when they drift.

    billing_lane.py route              # writes web=, ios=, storekit=, storekit_kind=,
                                       # storekit_path= to $GITHUB_OUTPUT
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
    "web/app/api/cron/team-seats/**",
    "web/app/app-pricing/**",
    "web/app/components/pro-plan-card.tsx",
    "web/dashboard-app/screens/billing/**",
    "web/orpc/server/dashboard/schemas/billing*",
    # Billing tables live in the shared schema; every migration can touch them.
    "web/db/schema*.ts",
    "web/db/migrations/**",
    "web/scripts/stripe/**",
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
    # Billing code outside those directories, by name: team billing and seat
    # procedures, the billing gateway, checkout and pricing UI, Stripe
    # analytics, billing alerts, entitlement overrides.
    "web/**/*billing*",
    "web/**/*billing*/**",
    "web/**/*Billing*",
    "web/**/*Billing*/**",
    "web/**/*stripe*",
    "web/**/*stripe*/**",
    "web/**/*Stripe*",
    "web/**/*entitlement*",
    "web/**/*Entitlement*",
    "web/**/*subscription*",
    "web/**/*subscription*/**",
    "web/**/*Subscription*",
    "web/**/*pricing*",
    "web/**/*pricing*/**",
    "web/**/*Pricing*",
    "web/**/*checkout*",
    "web/**/*checkout*/**",
    "web/**/*Checkout*",
    "web/**/*seats*",
    "web/**/*Seats*",
    "web/**/*apple-iap*",
)

# The SwiftPM billing packages ios-billing runs `swift test` for (any
# Packages/iOS/*Billing* package), their dependencies, and the classic app's
# billing composition and StoreKit config, whose closest test is that package.
IOS_PACKAGE_PATTERNS = (
    "Packages/iOS/CmuxMobileBilling/**",
    "Packages/iOS/*Billing*/**",
    "Packages/Shared/CMUXMobileCore/**",
    "Packages/iOS/CmuxMobileSupport/**",
    "Packages/iOS/**/*Billing*",
    "ios/**/*Billing*",
    "ios/**/*.storekit",
)

# The cmux-next iPhone app's billing client (being rewritten) and its StoreKit
# configuration files. These route only the StoreKit Testing slot; the rest of
# CmuxMobileKit is tested by cmux-next-ios-kit.yml.
IOS_APP_PATTERNS = (
    "cmux-next-ios/CmuxMobileKit/Sources/**/Billing*",
    "cmux-next-ios/**/*Billing*/**",
    "cmux-next-ios/**/*.storekit",
    # Where a BillingStoreKitTests target gets declared.
    "cmux-next-ios/project.yml",
    "cmux-next-ios/*/Package.swift",
)

IOS_PATTERNS = (*IOS_PACKAGE_PATTERNS, *IOS_APP_PATTERNS)

# StoreKit Testing slot. The rewritten billing client is expected to add an
# SKTestSession suite backed by a .storekit file as a target named
# BillingStoreKitTests: either a SwiftPM test directory
# (cmux-next-ios/<Package>/Tests/BillingStoreKitTests) or an xcodegen target in
# cmux-next-ios/project.yml. Until one exists the slot skips cleanly.
STOREKIT_TARGET = "BillingStoreKitTests"

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
# import or a mock.module path) is a billing test: a relative or `@/` module
# path with a billing word in it.
BILLING_IMPORT = re.compile(
    r"""["'](?:\.{1,2}/|@/)[^"'\n]*(?:"""
    r"billing|stripe|entitlement|seats|checkout|pricing|subscription"
    r"|apple-iap|apple-notifications|planUsage|pro-plan-card"
    r""")[^"'\n]*["']""",
    re.IGNORECASE,
)
TEST_FILE = re.compile(r"(?:\.test|_test|\.spec|_spec)\.(?:js|jsx|ts|tsx|mjs|cjs|mts|cts)$")
DB_GATE = "process.env.CMUX_DB_TEST"


def workflow_paths() -> list[str]:
    """The pull_request path filter billing.yml must declare, in order."""
    return [*LANE_PATTERNS, *WEB_PATTERNS, *IOS_PATTERNS]


@lru_cache(maxsize=None)
def _compiled(pattern: str) -> re.Pattern[str]:
    # Only `*` and `**` mean the same here as in GitHub's filter syntax, where
    # `?`, `+`, `[]` and `!` are operators; refuse them rather than guess.
    if any(char in pattern for char in "?+[]!"):
        raise ValueError(f"unsupported path filter syntax in {pattern!r}")
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
        else:
            out.append(re.escape(pattern[i]))
            i += 1
    return re.compile("".join(out) + r"\Z")


def matches(path: str, patterns: tuple[str, ...] | list[str]) -> bool:
    return any(_compiled(pattern).match(path) for pattern in patterns)


def classify(paths: list[str]) -> dict[str, bool]:
    lane = any(matches(path, LANE_PATTERNS) for path in paths)
    return {
        "web": lane or any(matches(path, WEB_PATTERNS) for path in paths),
        "ios": lane or any(matches(path, IOS_PACKAGE_PATTERNS) for path in paths),
        "storekit": lane or any(matches(path, IOS_PATTERNS) for path in paths),
    }


def storekit_target(root: Path = ROOT) -> tuple[str, str]:
    """("package", <package dir>), ("project", "cmux-next-ios") or ("", "")."""
    app = root / "cmux-next-ios"
    if not app.is_dir():
        return "", ""
    for directory, subdirs, _ in os.walk(app):
        subdirs[:] = sorted(d for d in subdirs if not d.startswith(".") and d not in ("node_modules", "target"))
        if Path(directory).name != STOREKIT_TARGET:
            continue
        for parent in Path(directory).parents:
            if (parent / "Package.swift").is_file():
                return "package", parent.relative_to(root).as_posix()
            if parent == app:
                break
    project = app / "project.yml"
    if project.is_file() and re.search(
        rf"^[ \t]+[\"']?{STOREKIT_TARGET}[\"']?[ \t]*:", project.read_text(encoding="utf-8"), re.MULTILINE
    ):
        return "project", "cmux-next-ios"
    return "", ""


def changed_paths() -> list[str] | None:
    # A push routes from its `before` (the workflow fetches it); a pull
    # request from HEAD^1, the base its merge commit sits on.
    base = os.environ.get("PUSH_BASE", "").strip() or "HEAD^1"
    parent = subprocess.run(
        ["git", "rev-parse", "-q", "--verify", f"{base}^{{commit}}"],
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
            if os.environ.get("EVENT_NAME") in ("pull_request", "push") and not any(areas.values()):
                # GitHub's path filter started this run, so some billing path
                # changed even though these patterns disagree: run everything.
                print("GitHub's path filter matched but no billing route did; running every billing job")
                areas = every
            touched = [path for path in paths if matches(path, workflow_paths())]
            print(f"{len(touched)} of {len(paths)} changed path(s) are billing paths:")
            for path in touched:
                print(f"  {path}")
    lines = "".join(f"{name}={'true' if value else 'false'}\n" for name, value in areas.items())
    kind, path = storekit_target() if areas["storekit"] else ("", "")
    if areas["storekit"] and not kind:
        print(f"no {STOREKIT_TARGET} target under cmux-next-ios; the StoreKit slot skips")
    lines += f"storekit_kind={kind}\nstorekit_path={path}\n"
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
