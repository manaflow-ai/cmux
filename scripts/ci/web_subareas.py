#!/usr/bin/env python3
"""Route expensive web CI subareas from the changed path set."""

from __future__ import annotations

from dataclasses import dataclass, replace
from functools import lru_cache
import importlib.util
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
    typecheck: bool
    unit_tests: bool

    @classmethod
    def all(cls) -> "WebSubareas":
        return cls(
            db=True,
            diff_sidecar=True,
            instant=True,
            production_build=True,
            react_apps=True,
            typecheck=True,
            unit_tests=True,
        )

    def emit(self, output: Path) -> None:
        with output.open("a", encoding="utf-8") as handle:
            handle.write(f"db={str(self.db).lower()}\n")
            handle.write(f"diff_sidecar={str(self.diff_sidecar).lower()}\n")
            handle.write(f"instant={str(self.instant).lower()}\n")
            handle.write(f"production_build={str(self.production_build).lower()}\n")
            handle.write(f"react_apps={str(self.react_apps).lower()}\n")
            handle.write(f"typecheck={str(self.typecheck).lower()}\n")
            handle.write(f"unit_tests={str(self.unit_tests).lower()}\n")
        print(
            "web subareas: "
            f"db={str(self.db).lower()} "
            f"diff_sidecar={str(self.diff_sidecar).lower()} "
            f"instant={str(self.instant).lower()} "
            f"production_build={str(self.production_build).lower()} "
            f"react_apps={str(self.react_apps).lower()} "
            f"typecheck={str(self.typecheck).lower()} "
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
    # The migration runner every database uses; its DB tests apply fixtures through it.
    "web/scripts/cloud-vm/apply-migrations.mjs",
    "web/scripts/db-local.sh",
    "web/scripts/db-migrate.mjs",
    "web/scripts/run-db-behavior-tests.sh",
}
DB_PREFIXES = (
    "web/app/api/",
    "web/app/v1/",
    "web/db/",
    "web/openapi/",
    "web/orpc/",
    "web/services/",
    "web/types/",
)

DB_TEST_PREFIX = "web/tests/"


def test_path_requires_db(path: str, repo_root: Path) -> bool:
    if not path.startswith(DB_TEST_PREFIX):
        return False
    candidate = repo_root / path
    if not candidate.is_file():
        # Deleted or unavailable tests are conservative: the old file may have
        # been one of the DB-behavior cases.
        return True
    try:
        return "CMUX_DB_TEST" in candidate.read_text(encoding="utf-8")
    except (OSError, UnicodeError):
        return True


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
    "webviews/bun.lock",
    "webviews/package.json",
}
DIFF_SIDECAR_PREFIXES = (
    "Native/DiffSidecar/",
    # The sidecar links this crate by path.
    "cmux-tui/crates/cmux-git/",
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

TYPECHECK_EXTENSIONS = (
    ".js",
    ".jsx",
    ".mjs",
    ".cjs",
    ".ts",
    ".tsx",
    ".mts",
    ".cts",
)
TYPECHECK_EXACT = {
    "web/bun.lock",
    "web/package.json",
    "web/tsconfig.json",
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
    # react-apps-check runs the webviews tests through it.
    "scripts/ci/run-webviews-tests.sh",
    # and splits and orders its files by recorded duration through this.
    "scripts/ci/webviews_test_shards.py",
    # and compares its reds with the base's through these.
    "scripts/ci/webviews-tests-new-reds.sh",
    "scripts/ci/webviews_test_results.py",
    "scripts/ci/guards_new_reds.py",
    # and the base's flake history that keeps a test flipping there a warning.
    "scripts/ci/webviews_test_history.py",
    # It also runs the test of the PR scoping of ui-rules and gallery coverage.
    "scripts/tests/test_pr_scoped_webviews_checks.py",
    "scripts/check-webviews-bun-version.sh",
    "scripts/check-webviews-react-compiler.mjs",
    # The generated agent pane page, its build and regenerate scripts, and
    # the merge driver that keeps it mergeable: react-apps-check verifies
    # the page and runs the driver's test.
    "Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/Resources/agent-pane/index.html",
    "Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/Resources/agent-pane/pane.js",
    "scripts/cmux-next/build-agent-pane-web.sh",
    "Packages/macOS/CmuxNext/Sources/CmuxNextPalette/Resources/palette-ranker.js",
    "scripts/cmux-next/build-palette-ranker.sh",
    "Packages/macOS/CmuxNext/Sources/CmuxNextAgentActivity/Resources/agent-activity/index.html",
    "scripts/cmux-next/build-agent-activity-web.sh",
    "scripts/cmux-next/regenerate-web-bundles.sh",
    "scripts/cmux-next/build-web-bundles.sh",
    "scripts/cmux-next/web-bundle-key.py",
    ".gitattributes",
    "scripts/install-git-hooks.sh",
    "tests/test_install_git_hooks.py",
}
REACT_PREFIXES = (
    "Resources/markdown-viewer/",
    "config/vite-plus/",
    "webviews/",
)

# Every other input of the web bundles (the settings schema, the What's New
# highlights, the model catalog, the string catalogs the pages read...) runs
# react-apps-check too, as web-bundle-key.py derives them (`--routed`); the same
# derivation routes the web area in detect_ci_change_areas.py.
WEB_BUNDLE_KEY = Path(__file__).resolve().parents[1] / "cmux-next" / "web-bundle-key.py"


@lru_cache(maxsize=None)
def web_bundle_input_matcher(root: str):
    """A predicate for the paths web-bundle-key.py routes the web checks on, for
    the tree at `root`; the key's declared inputs when it cannot derive them,
    None without the key script."""
    try:
        spec = importlib.util.spec_from_file_location("cmux_web_bundle_key", WEB_BUNDLE_KEY)
        if spec is None or spec.loader is None:
            return None
        key = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(key)
    except (OSError, SyntaxError, ImportError) as error:
        print(f"web bundle inputs unavailable ({error})", file=sys.stderr)
        return None
    try:
        return key.pathspec_matcher(key.routed_inputs(root))
    except (Exception, SystemExit) as error:  # noqa: BLE001  (fall back, never fail the router)
        print(f"web bundle inputs not derived ({error}); using the key's declared inputs", file=sys.stderr)
        return key.pathspec_matcher(key.INPUTS)


def classify_paths(paths: list[str], repo_root: Path | None = None) -> WebSubareas:
    root = Path.cwd() if repo_root is None else repo_root
    db = False
    diff_sidecar = False
    instant = False
    production_build = False
    react_apps = False
    typecheck = False
    unit_tests = False

    for path in paths:
        if path in ALL_SUBAREA_INPUTS:
            db = diff_sidecar = instant = production_build = react_apps = typecheck = unit_tests = True
            continue

        if path in DB_EXACT or path.startswith(DB_PREFIXES) or test_path_requires_db(path, root):
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
        elif (matcher := web_bundle_input_matcher(str(root.resolve()))) is not None and matcher(path):
            react_apps = True

        if path in TYPECHECK_EXACT or (
            path.startswith("web/")
            and (path.endswith(TYPECHECK_EXTENSIONS) or path.endswith(".json"))
        ):
            typecheck = True

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
        typecheck=typecheck,
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

    # A feat-cmux-next push routes from what the push brought (event.before), not its last
    # commit: a multi-commit push can end on a commit that touches no web path.
    push_base = os.environ.get("WEB_SUBAREAS_BASE", "").strip()
    base = subprocess.run(
        ["git", "rev-parse", "-q", "--verify", f"{push_base}^{{commit}}" if push_base else "HEAD^1"],
        text=True,
        capture_output=True,
    )
    if base.returncode != 0:
        print(f"comparison base {push_base or 'HEAD^1'} unavailable; running every web subarea")
        WebSubareas.all().emit(output)
        return 0

    paths = changed_paths(base.stdout.strip(), "HEAD")
    if paths is None or not paths:
        print("web subarea diff unavailable or empty; running every web subarea")
        WebSubareas.all().emit(output)
        return 0

    areas = classify_paths(paths)
    # feat-cmux-next is the base branch. A direct push must exercise the React
    # suite even when the pushed range contains no web path, or a base web red
    # remains invisible until a PR happens to touch webviews. Other web
    # subareas stay path-routed to keep unrelated pushes cheap.
    if (
        os.environ.get("EVENT_NAME") == "push"
        and os.environ.get("GITHUB_REF") == "refs/heads/feat-cmux-next"
    ):
        areas = replace(areas, react_apps=True)
    areas.emit(output)
    return 0


def main() -> int:
    if sys.argv[1:] == ["route"]:
        return route()
    raise SystemExit("usage: web_subareas.py route")


if __name__ == "__main__":
    raise SystemExit(main())
