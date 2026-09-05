#!/usr/bin/env python3
"""Fail-closed verification for browser runtime build artifacts.

The Chromium browser implementation is intentionally optional for local/offline
builds, but an optional build must never be mistaken for a native Chromium build
when it is being used as release or merge evidence.  This helper classifies the
checked-out source and validates the corresponding app bundle:

* a checkout containing the CEF integration must contain the versioned CEF
  framework and all five helper bundles; and
* a checkout without the integration must not inherit a stale CEF bundle from a
  reused DerivedData directory.

The helper also verifies that the artifact was built from the exact SHA supplied
by the caller.  It is deliberately usable on Linux in unit tests; codesigning
and other platform-specific checks remain owned by the macOS build lanes.
"""

from __future__ import annotations

import argparse
import os
import plistlib
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


class VerificationError(RuntimeError):
    """Raised when a build artifact cannot be trusted as browser evidence."""


@dataclass(frozen=True)
class VerificationResult:
    """Evidence produced by :func:`verify_artifact`."""

    runtime_mode: str
    helper_count: int
    source_sha: str | None


_SHA_RE = re.compile(r"^[0-9a-fA-F]{40}$")
_CEF_SOURCE_MARKERS = (
    "Packages/macOS/CmuxCEF/Package.swift",
    "Packages/macOS/CmuxCEF/Sources/CmuxCEF",
    "scripts/embed-cef.sh",
    "scripts/ensure-cef.sh",
)
_CEF_FRAMEWORK_NAME = "Chromium Embedded Framework.framework"
_CEF_HELPER_SUFFIXES = ("", " (GPU)", " (Renderer)", " (Plugin)", " (Alerts)")


def _normalize_path(path: str) -> str:
    normalized = path.strip().replace("\\", "/")
    while normalized.startswith("./"):
        normalized = normalized[2:]
    return normalized


def is_browser_engine_path(path: str) -> bool:
    """Return whether a changed path needs the browser runtime gate.

    The classifier is intentionally conservative for executable macOS and
    control-plane paths rather than relying on a substring search:
    documentation mentioning Chromium must not queue a paid UI run, while an
    unfamiliar source or guard file must not silently bypass runtime
    verification.
    """

    normalized = _normalize_path(path)
    lower = normalized.lower()
    # Keep clearly non-macOS documentation and standalone projects out of the
    # paid macOS runtime lane before applying the broader fail-closed rules.
    if lower.startswith(("docs/", "design/", "plans/", "skills/", "web/", "cmux-tui/")):
        return False
    if lower in {"readme.md", "readme.txt", "license", "license.md"}:
        return False
    # The native browser runtime gate is macOS-only. iOS browser surfaces have
    # their own build/test lane and must not be mistaken for a macOS CEF edit
    # merely because their directory name contains "browser".
    if lower.startswith(("ios/", "packages/ios/")):
        return False
    if lower.startswith(".github/"):
        return True
    # Browser panes are composed through the macOS app target, not only the
    # files whose names mention Browser/Chromium. Route the complete macOS
    # source/test surface and all CI/build control-plane edits through the
    # trusted smoke lane. This is deliberately conservative: a new shared
    # host integration must not silently become an unverified merge merely
    # because its filename is unfamiliar to this classifier.
    broad_prefixes = (
        "cli/",
        "packages/macos/",
        "packages/shared/",
        "native/",
        "resources/",
        "scripts/",
        "sources/",
        "cmuxtests/",
        "cmuxuitests/",
    )
    if lower.startswith(broad_prefixes):
        return True

    prefixes = (
        "packages/macos/cmuxbrowser/",
        "packages/macos/cmuxcef/",
        "sources/panels/browser",
        "sources/panels/chromium",
        "sources/browser",
        "sources/terminalcontroller+browser",
        "sources/terminalcontroller+chromium",
        "sources/chromium",
        "cli/cmuxcli+browser",
        "cli/cmux.swift",
        "cli/cmux_open.swift",
        "cmuxtests/browser",
        "cmuxuitests/browser",
    )
    if lower.startswith(prefixes):
        return True
    if lower in {
        ".github/workflows/ci.yml",
        ".github/workflows/required-ci.yml",
        ".github/workflows/reload-build.yml",
        ".github/workflows/test-e2e.yml",
        "scripts/ci/detect_browser_engine_changes.py",
        "scripts/ci/verify_browser_runtime_artifact.py",
        "scripts/ci/verify_required_ci_run.py",
        "ghostty",
        "homebrew-cmux",
        "cmux.xcodeproj/project.pbxproj",
        "cmux.xcworkspace/contents.xcworkspacedata",
        "cmux.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/package.resolved",
        "scripts/reload.sh",
    }:
        return True
    if lower.startswith("vendor/"):
        return True
    if any(token in lower for token in ("/browser", "/chromium", "/cmuxcef", "cef/")):
        return True
    # Unknown repository paths are unsafe to classify as cheap. A new app
    # target, build input, bundled source tree (for example cmux-browser/), or
    # control-plane helper can change the runtime without containing a familiar
    # Browser/Chromium token. Keep only clearly non-macOS documentation and
    # standalone web/mobile projects on the cheap side; everything else must
    # receive the real runtime gate.
    return True


def _source_contains_cef(source_root: Path) -> bool:
    """Detect the CEF integration without trusting generated build output."""

    for marker in _CEF_SOURCE_MARKERS:
        marker_path = source_root / marker
        if marker_path.is_file() or (
            marker_path.is_dir() and any(marker_path.rglob("*.swift"))
        ):
            return True

    # A package may be represented by tracked files even when a checkout has
    # not materialized an empty directory yet.  Use git only as a fallback so
    # the helper remains testable against synthetic source trees.
    try:
        completed = subprocess.run(
            ["git", "ls-files", "--", "Packages/macOS/CmuxCEF/**", "scripts/*cef*"],
            cwd=source_root,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError) as error:
        # A real checkout whose source inventory cannot be inspected is not
        # evidence of a fallback build. Synthetic unit-test roots have no Git
        # metadata and may still use the marker-based path above.
        git_metadata = source_root / ".git"
        if git_metadata.exists():
            raise VerificationError("could not inspect the checked-out source tree") from error
        return False
    return any(line.strip() for line in completed.stdout.splitlines())


def _git_sha(source_root: Path) -> str | None:
    try:
        completed = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=source_root,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError):
        return None
    value = completed.stdout.strip()
    return value if _SHA_RE.fullmatch(value) else None


def _require_file(path: Path, description: str, *, executable: bool = False) -> None:
    if not path.is_file():
        raise VerificationError(f"missing {description}: {path}")
    if executable and not os.access(path, os.X_OK):
        raise VerificationError(f"{description} is not executable: {path}")


def _read_info_plist(app: Path) -> dict[str, object]:
    """Load and validate the app's processed ``Info.plist`` document."""

    info_plist = app / "Contents" / "Info.plist"
    _require_file(info_plist, "app Info.plist")
    try:
        with info_plist.open("rb") as handle:
            document = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException) as error:
        raise VerificationError(f"could not parse app Info.plist: {info_plist}") from error
    if not isinstance(document, dict):
        raise VerificationError(f"app Info.plist is not a dictionary: {info_plist}")
    return document


def _bundle_source_sha(app: Path) -> str | None:
    """Read the full source SHA stamped into the processed app Info.plist."""

    document = _read_info_plist(app)
    value = document.get("CMUXBuildSourceSHA")
    if not isinstance(value, str) or not _SHA_RE.fullmatch(value):
        return None
    return value.lower()


def _verify_app_executable(app: Path) -> None:
    """Verify the executable named by ``CFBundleExecutable``.

    Tagged development builds intentionally rename both the app bundle and
    executable (for example ``cmux DEV <tag>``), so assuming a literal
    ``cmux`` filename would reject a valid artifact.
    """

    document = _read_info_plist(app)
    executable_name = document.get("CFBundleExecutable")
    if (
        not isinstance(executable_name, str)
        or not executable_name
        or "/" in executable_name
        or "\\" in executable_name
    ):
        raise VerificationError("app Info.plist has an invalid CFBundleExecutable")
    _require_file(
        app / "Contents" / "MacOS" / executable_name,
        "app executable",
        executable=True,
    )


def _verify_native_cef(app: Path) -> int:
    frameworks = app / "Contents" / "Frameworks"
    framework = frameworks / _CEF_FRAMEWORK_NAME
    current = framework / "Versions" / "Current"
    _require_file(
        current / "Resources" / "Info.plist",
        "versioned CEF Info.plist",
    )
    _require_file(
        current / "Chromium Embedded Framework",
        "CEF framework binary",
        executable=True,
    )

    expected_helpers = {
        f"cmux CEF Helper{suffix}.app": f"cmux CEF Helper{suffix}"
        for suffix in _CEF_HELPER_SUFFIXES
    }
    helper_count = 0
    for bundle_name, executable_name in expected_helpers.items():
        executable = frameworks / bundle_name / "Contents" / "MacOS" / executable_name
        _require_file(executable, f"CEF helper {bundle_name}", executable=True)
        helper_count += 1
    return helper_count


def verify_artifact(
    *,
    app: Path,
    source_root: Path,
    expected_sha: str | None,
) -> VerificationResult:
    """Verify *app* against the source tree and optional exact SHA."""

    app = app.resolve()
    source_root = source_root.resolve()
    if not app.is_dir():
        raise VerificationError(f"app bundle does not exist: {app}")
    _verify_app_executable(app)

    actual_sha = _git_sha(source_root)
    if expected_sha:
        normalized_expected = expected_sha.strip()
        if not _SHA_RE.fullmatch(normalized_expected):
            raise VerificationError(f"expected source SHA is not a full commit SHA: {expected_sha!r}")
        if actual_sha is None:
            raise VerificationError("could not resolve the checked-out source SHA")
        if actual_sha.lower() != normalized_expected.lower():
            raise VerificationError(
                f"artifact source SHA mismatch: expected {normalized_expected}, got {actual_sha}"
            )
        bundle_sha = _bundle_source_sha(app)
        if bundle_sha is None:
            raise VerificationError(
                "app bundle is missing a full CMUXBuildSourceSHA provenance value"
            )
        if bundle_sha != normalized_expected.lower():
            raise VerificationError(
                f"app bundle source SHA mismatch: expected {normalized_expected}, got {bundle_sha}"
            )

    has_cef_source = _source_contains_cef(source_root)
    framework = app / "Contents" / "Frameworks" / _CEF_FRAMEWORK_NAME
    if has_cef_source:
        helper_count = _verify_native_cef(app)
        runtime_mode = "native-cef"
    else:
        stale_helpers = sorted(
            path.name
            for path in (app / "Contents" / "Frameworks").glob("cmux CEF Helper*.app")
        )
        if framework.exists() or stale_helpers:
            raise VerificationError(
                "CEF framework/helper bundles are present in an artifact whose source tree has no "
                "CEF integration; this is likely stale DerivedData"
            )
        helper_count = 0
        runtime_mode = "fallback"

    return VerificationResult(
        runtime_mode=runtime_mode,
        helper_count=helper_count,
        source_sha=actual_sha,
    )


def _write_outputs(result: VerificationResult, output_path: str | None) -> None:
    if not output_path:
        return
    with Path(output_path).open("a", encoding="utf-8") as handle:
        handle.write(f"runtime_mode={result.runtime_mode}\n")
        handle.write(f"helper_count={result.helper_count}\n")
        if result.source_sha:
            handle.write(f"source_sha={result.source_sha}\n")


def parse_args(argv: Iterable[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True, help="built .app bundle to inspect")
    parser.add_argument(
        "--source-root",
        type=Path,
        default=Path("."),
        help="checkout that produced the app (default: current directory)",
    )
    parser.add_argument(
        "--expected-sha",
        default="",
        help="full source SHA that must match git HEAD",
    )
    parser.add_argument(
        "--github-output",
        default=os.environ.get("GITHUB_OUTPUT"),
        help="optional GitHub Actions output file",
    )
    return parser.parse_args(list(argv))


def main(argv: Iterable[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    try:
        result = verify_artifact(
            app=args.app,
            source_root=args.source_root,
            expected_sha=args.expected_sha or None,
        )
    except VerificationError as error:
        print(f"::error::{error}", file=sys.stderr)
        return 1

    _write_outputs(result, args.github_output)
    print(f"browser runtime mode: {result.runtime_mode}")
    print(f"CEF helper bundles: {result.helper_count}")
    if result.source_sha:
        print(f"verified source SHA: {result.source_sha}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
