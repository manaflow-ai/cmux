#!/usr/bin/env python3
"""Pairing-QR tests must name the URL scheme instead of resolving it.

`CmxPairingURLSchemeResolver` derives the pairing scheme from
`Bundle.main.bundleIdentifier`. On iOS that is the only branch it has, and in
an xctest process the main bundle belongs to the test runner, not to a cmux
build -- so `resolved` is nil, `CmxPairingQRCode.encode` returns nil, and
`MobileSyncPairingPayload.encodedURL()` throws `invalidURL`.

On macOS the same resolver has a deterministic fallback (`dev.cmux.ios`), so
every test that leans on it passes under `swift test` and fails the moment the
same target is run in an iOS Simulator. ci-macos-compat.yml is the only
workflow that does that, and eight tests in CMUXMobileCoreTests were failing
there on all four runners -- invisibly, because that workflow is
workflow_dispatch only.

The tests are not asserting anything about bundle identity, so the fix is to
pass the scheme they mean. This lint keeps them that way: it runs on Linux on
every pull request, where dispatching a compatibility matrix does not.
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
# The zero-argument initializer is the bundle-derived one. The memberwise
# initializer takes an identity and is deterministic, so tests of the
# resolver itself are free to use it.
BUNDLE_DERIVED_RESOLVER = "CmxPairingURLSchemeResolver()"
SCHEME_ARGUMENT = "pairingURLScheme:"

# Call sites that resolve the scheme from the bundle unless a caller names it,
# each paired with the production symbol that does the resolving. The second
# check below fails if one of those symbols stops reaching the resolver, so the
# rule cannot outlive the code it describes.
IMPLICIT_ENTRY_POINTS = {
    r"CmxPairingQRCode\(\)\s*\.\s*encode\(": "CmxPairingQRCode",
    r"\.encodedURL\(": "MobileSyncPairingPayload",
}
SOURCE_ROOT = "Packages/Shared/CMUXMobileCore/Sources/CMUXMobileCore/"
ENTRY_POINT_DECLARATIONS = {
    "CmxPairingQRCode": (SOURCE_ROOT + "CmxPairingQRCode.swift", "encode"),
    "MobileSyncPairingPayload": (SOURCE_ROOT + "MobileSyncProtocol.swift", "encodedURL"),
}


def is_test_file(path: str) -> bool:
    return "/Tests/" in path or path.startswith(
        ("cmuxTests/", "cmuxUITests/", "ios/cmuxUITests/", "cmuxCLITests/", "cmuxCLITestSupport/")
    )


def declaration_uses_resolver(text: str, method: str) -> bool:
    # Documentation mentioning the resolver is not a parameter default.
    code = re.sub(r"/\*.*?\*/|//[^\n]*", "", text, flags=re.DOTALL)
    default = re.compile(
        r"\bpairingURLScheme\s*:\s*CmxPairingURLScheme\?\s*=\s*"
        r"CmxPairingURLSchemeResolver\s*\(\s*\)\s*\.\s*resolved\s*(?:,|$)"
    )
    for match in re.finditer(rf"\bfunc\s+{re.escape(method)}\s*\(", code):
        if default.search(argument_span(code, match.end() - 1)):
            return True
    return False


def tracked_swift_files() -> list[str]:
    return subprocess.run(
        ["git", "ls-files", "*.swift"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=True,
    ).stdout.split()


def argument_span(text: str, open_paren: int) -> str:
    """The text between a call's parentheses, matched by nesting depth."""
    depth = 0
    for index in range(open_paren, len(text)):
        if text[index] == "(":
            depth += 1
        elif text[index] == ")":
            depth -= 1
            if depth == 0:
                return text[open_paren + 1 : index]
    return text[open_paren + 1 :]


def line_of(text: str, offset: int) -> int:
    return text.count("\n", 0, offset) + 1


def implicit_calls(text: str) -> list[tuple[int, str]]:
    found: list[tuple[int, str]] = []
    for pattern, symbol in IMPLICIT_ENTRY_POINTS.items():
        for match in re.finditer(pattern, text):
            open_paren = match.end() - 1
            if SCHEME_ARGUMENT not in argument_span(text, open_paren):
                found.append((line_of(text, match.start()), symbol))
    return found


def main() -> int:
    test_files = [p for p in tracked_swift_files() if is_test_file(p)]

    offenders: list[str] = []
    for path in test_files:
        text = (ROOT / path).read_text(encoding="utf-8", errors="ignore")
        start = 0
        while (index := text.find(BUNDLE_DERIVED_RESOLVER, start)) != -1:
            offenders.append(
                f"{path}:{line_of(text, index)}: "
                f"reads {BUNDLE_DERIVED_RESOLVER}"
            )
            start = index + 1
        for line, call in implicit_calls(text):
            offenders.append(
                f"{path}:{line}: {call} call without {SCHEME_ARGUMENT}"
            )

    if offenders:
        print("tests resolve the pairing scheme from the bundle:", file=sys.stderr)
        for offender in offenders:
            print(f"  - {offender}", file=sys.stderr)
        print(
            f"\nPass the scheme the test means, as "
            f"CmxPairingQRBitmapTests does:\n"
            f"  let scheme = try #require(CmxPairingURLScheme(rawValue: ...))\n"
            f"...then hand it to the call as {SCHEME_ARGUMENT}. Bundle.main "
            "in an xctest process is the test runner, so the resolver returns "
            "nil there and the call fails in an iOS Simulator.",
            file=sys.stderr,
        )
        return 1

    # The entry points above are only worth linting while they still reach the
    # resolver. If one stops defaulting to it, drop it rather than leave a rule
    # that no longer describes the code.
    stale = []
    for symbol in sorted(set(IMPLICIT_ENTRY_POINTS.values())):
        path, method = ENTRY_POINT_DECLARATIONS[symbol]
        source = ROOT / path
        if not source.is_file() or not declaration_uses_resolver(source.read_text("utf-8"), method):
            stale.append(symbol)
    if stale:
        print(
            "these no longer resolve the pairing scheme; drop them from "
            f"IMPLICIT_ENTRY_POINTS: {', '.join(stale)}",
            file=sys.stderr,
        )
        return 1

    print(
        f"{len(test_files)} Swift test files name the pairing scheme explicitly"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
