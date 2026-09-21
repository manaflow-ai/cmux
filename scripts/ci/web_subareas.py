#!/usr/bin/env python3
"""Route expensive web CI subareas from the changed path set."""

from __future__ import annotations

from dataclasses import dataclass
import os
from pathlib import Path
import subprocess
import sys


@dataclass(frozen=True)
class WebSubareas:
    db: bool
    diff_sidecar: bool
    instant: bool
    production_build: bool
    react_apps: bool
    unit_tests: bool

    @classmethod
    def all(cls) -> "WebSubareas":
        return cls(
            db=True,
            diff_sidecar=True,
            instant=True,
            production_build=True,
            react_apps=True,
            unit_tests=True,
        )

    def emit(self, output: Path) -> None:
        with output.open("a", encoding="utf-8") as handle:
            handle.write(f"db={str(self.db).lower()}\n")
            handle.write(f"diff_sidecar={str(self.diff_sidecar).lower()}\n")
            handle.write(f"instant={str(self.instant).lower()}\n")
            handle.write(f"production_build={str(self.production_build).lower()}\n")
            handle.write(f"react_apps={str(self.react_apps).lower()}\n")
            handle.write(f"unit_tests={str(self.unit_tests).lower()}\n")
        print(
            "web subareas: "
            f"db={str(self.db).lower()} "
            f"diff_sidecar={str(self.diff_sidecar).lower()} "
            f"instant={str(self.instant).lower()} "
            f"production_build={str(self.production_build).lower()} "
            f"react_apps={str(self.react_apps).lower()} "
            f"unit_tests={str(self.unit_tests).lower()}"
        )


ALL_SUBAREA_INPUTS = {
    ".github/workflows/ci-web.yml",
    "scripts/ci/web_subareas.py",
}

DB_EXACT = {
    "web/bun.lock",
    "web/drizzle.config.ts",
    "web/package.json",
    "web/scripts/db-local.sh",
    "web/scripts/run-db-behavior-tests.sh",
}
DB_PREFIXES = (
    "web/app/api/",
    "web/app/v1/",
    "web/db/",
    "web/openapi/",
    "web/orpc/",
    "web/services/",
    "web/tests/",
    "web/types/",
)

INSTANT_EXACT = {
    "web/bun.lock",
    "web/next.config.ts",
    "web/package.json",
    "web/playwright.instant.config.ts",
    "web/proxy.ts",
    # proxy.ts imports this directly for reflection routing.
    "web/services/coderouter/vmGuestEnv.ts",
}
INSTANT_PREFIXES = (
    "web/app/",
    "web/data/",
    "web/e2e/instant/",
    "web/i18n/",
    "web/messages/",
)

DIFF_SIDECAR_EXACT = {
    "scripts/benchmark-diff-viewer.sh",
    "scripts/build-diff-sidecar.sh",
    "scripts/generate-diff-sidecar-types.sh",
    "scripts/install-rust-ci.sh",
    "scripts/run-diff-sidecar-cargo.sh",
    "Sources/Panels/CmuxDiffViewerURLSchemeHandler.swift",
    "Sources/Panels/DiffSidecarBridge.swift",
    "webviews/bun.lock",
    "webviews/package.json",
}
DIFF_SIDECAR_PREFIXES = (
    "Native/DiffSidecar/",
    "Packages/macOS/CmuxBrowser/Sources/CmuxBrowser/DiffViewer/",
    "webviews/bench/",
    "webviews/src/diff/",
)

PRODUCTION_BUILD_EXACT = {
    ".npmrc",
    ".vercelignore",
    "CHANGELOG.md",
    "bun.lock",
    "bunfig.toml",
    "config/iroh/managed-relay-catalog.json",
    "package.json",
    "vercel.json",
    "workers/presence/src/generated/managedRelayCatalog.ts",
}
PRODUCTION_BUILD_EXCLUDED_PREFIXES = (
    "web/e2e/",
    "web/tests/",
)
PRODUCTION_BUILD_EXCLUDED_EXACT = {
    "web/playwright.instant.config.ts",
    "web/scripts/run-db-behavior-tests.sh",
    "web/scripts/run-tests.sh",
}

UNIT_TESTS_EXACT = {
    "CHANGELOG.md",
    "config/iroh/managed-relay-catalog.json",
    "workers/presence/src/generated/managedRelayCatalog.ts",
}
UNIT_TESTS_EXCLUDED_PREFIXES = (
    "web/e2e/",
)

REACT_EXACT = {
    "scripts/build-webviews-app.sh",
    "scripts/check-webviews-react-compiler.mjs",
}
REACT_PREFIXES = (
    "Resources/markdown-viewer/",
    "webviews/",
)


def classify_paths(paths: list[str]) -> WebSubareas:
    db = False
    diff_sidecar = False
    instant = False
    production_build = False
    react_apps = False
    unit_tests = False

    for path in paths:
        if path in ALL_SUBAREA_INPUTS:
            db = diff_sidecar = instant = production_build = react_apps = unit_tests = True
            continue

        if path in DB_EXACT or path.startswith(DB_PREFIXES):
            db = True

        if path in DIFF_SIDECAR_EXACT or path.startswith(DIFF_SIDECAR_PREFIXES):
            diff_sidecar = True

        if path in INSTANT_EXACT or path.startswith(INSTANT_PREFIXES):
            instant = True

        if path in PRODUCTION_BUILD_EXACT:
            production_build = True
        elif (
            path.startswith("web/")
            and path not in PRODUCTION_BUILD_EXCLUDED_EXACT
            and not path.startswith(PRODUCTION_BUILD_EXCLUDED_PREFIXES)
        ):
            production_build = True

        if path in REACT_EXACT or path.startswith(REACT_PREFIXES):
            react_apps = True

        if path in UNIT_TESTS_EXACT or (
            path.startswith("web/") and not path.startswith(UNIT_TESTS_EXCLUDED_PREFIXES)
        ):
            unit_tests = True

    return WebSubareas(
        db=db,
        diff_sidecar=diff_sidecar,
        instant=instant,
        production_build=production_build,
        react_apps=react_apps,
        unit_tests=unit_tests,
    )


def changed_paths(base: str, head: str) -> list[str] | None:
    result = subprocess.run(
        ["git", "diff", "--no-renames", "--name-only", "-z", base, head, "--"],
        capture_output=True,
    )
    if result.returncode != 0:
        return None
    return [os.fsdecode(path) for path in result.stdout.split(b"\0") if path]


def route() -> int:
    output = Path(os.environ["GITHUB_OUTPUT"])
    if os.environ.get("EVENT_NAME") == "workflow_dispatch":
        WebSubareas.all().emit(output)
        return 0

    base = subprocess.run(
        ["git", "rev-parse", "-q", "--verify", "HEAD^1"],
        text=True,
        capture_output=True,
    )
    if base.returncode != 0:
        print("comparison parent unavailable; running every web subarea")
        WebSubareas.all().emit(output)
        return 0

    paths = changed_paths(base.stdout.strip(), "HEAD")
    if paths is None or not paths:
        print("web subarea diff unavailable or empty; running every web subarea")
        WebSubareas.all().emit(output)
        return 0

    classify_paths(paths).emit(output)
    return 0


def main() -> int:
    if sys.argv[1:] == ["route"]:
        return route()
    raise SystemExit("usage: web_subareas.py route")


if __name__ == "__main__":
    raise SystemExit(main())
