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
    react_apps: bool

    @classmethod
    def all(cls) -> "WebSubareas":
        return cls(db=True, diff_sidecar=True, instant=True, react_apps=True)

    def emit(self, output: Path) -> None:
        with output.open("a", encoding="utf-8") as handle:
            handle.write(f"db={str(self.db).lower()}\n")
            handle.write(f"diff_sidecar={str(self.diff_sidecar).lower()}\n")
            handle.write(f"instant={str(self.instant).lower()}\n")
            handle.write(f"react_apps={str(self.react_apps).lower()}\n")
        print(
            "web subareas: "
            f"db={str(self.db).lower()} "
            f"diff_sidecar={str(self.diff_sidecar).lower()} "
            f"instant={str(self.instant).lower()} "
            f"react_apps={str(self.react_apps).lower()}"
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
    react_apps = False

    for path in paths:
        if path in ALL_SUBAREA_INPUTS:
            db = diff_sidecar = instant = react_apps = True
            continue

        if path in DB_EXACT or path.startswith(DB_PREFIXES):
            db = True

        if path in DIFF_SIDECAR_EXACT or path.startswith(DIFF_SIDECAR_PREFIXES):
            diff_sidecar = True

        if path in INSTANT_EXACT or path.startswith(INSTANT_PREFIXES):
            instant = True

        if path in REACT_EXACT or path.startswith(REACT_PREFIXES):
            react_apps = True

    return WebSubareas(
        db=db,
        diff_sidecar=diff_sidecar,
        instant=instant,
        react_apps=react_apps,
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
