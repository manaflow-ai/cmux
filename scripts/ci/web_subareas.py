#!/usr/bin/env python3
"""Route expensive web CI subareas from the changed path set."""

from __future__ import annotations

from dataclasses import dataclass, replace
from functools import lru_cache
import hashlib
import importlib.util
import os
from pathlib import Path
import re
import subprocess
import sys
import tomllib


@dataclass(frozen=True)
class WebSubareas:
    db: bool
    diff_sidecar: bool
    instant: bool
    production_build: bool
    react_apps: bool
    typecheck: bool
    unit_tests: bool
    # The real-daemon lane need not run for unrelated standalone test edits.
    agent_pane: bool = False
    # chat-flow-shift-budget: the agent pane's inputs but acpmux's (it runs on the stand-in daemon, no Rust build).
    chat_flow: bool = False

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
            agent_pane=True,
            chat_flow=True,
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
            handle.write(f"agent_pane={str(self.agent_pane).lower()}\n")
        print(
            "web subareas: "
            f"db={str(self.db).lower()} "
            f"diff_sidecar={str(self.diff_sidecar).lower()} "
            f"instant={str(self.instant).lower()} "
            f"production_build={str(self.production_build).lower()} "
            f"react_apps={str(self.react_apps).lower()} "
            f"typecheck={str(self.typecheck).lower()} "
            f"unit_tests={str(self.unit_tests).lower()}"
            f" agent_pane={str(self.agent_pane).lower()}"
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
    # web/tests/next-docs.test.ts and the docs-shortcuts tests build the docs
    # references from these at the head (the committed copies are bot-only, RFD
    # 0048), so a change to either must run the web tests (#38631 changed
    # action-surfaces.json with Web tests skipped and broke base).
    "plans/cmux-next/action-surfaces.json",
    "schemas/settings/settings-schema.json",
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
    # A feat-cmux-next pull request's run on the fleet (ci/steps.toml's react-apps-check) and the rule both sides ask.
    "scripts/ci/react-apps-check-fleet.sh",
    "scripts/ci/react_apps_fleet.py",
    # It also runs the test of the PR scoping of ui-rules and gallery coverage.
    "scripts/tests/test_pr_scoped_webviews_checks.py",
    "scripts/check-webviews-bun-version.sh",
    "scripts/webviews_bun_version.py",
    "scripts/check-webviews-react-compiler.mjs",
    # The generated agent pane page, its build and regenerate scripts, and
    # the merge driver that keeps it mergeable: react-apps-check verifies
    # the page and runs the driver's test.
    # The relay's params rule and its Rust mirror: webviews/test/agent-pane-relay-params-contract.test.ts
    # checks every key the page sends against both, so a relay-only PR runs it too (cmux#46563).
    "Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/AcpmuxPaneMethods.swift",
    "Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/AcpmuxPaneMethods+Params.swift",
    "cmux-tui/crates/cmux-agent-pane-policy/policy.json",
    "Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/Resources/agent-pane/index.html",
    "Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/Resources/agent-pane/pane.js",
    "scripts/cmux-next/build-agent-pane-web.sh",
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

# agent-pane-real-acpmux runs two browser tests against a built acpmux daemon; chat-flow-shift-budget runs the
# chat flows' layout-shift budget on the same routing.
# Browser tests load the app through Vite, beyond their static imports. Keep all
# runtime/build inputs and support helpers; only unrelated standalone test files
# can be excluded without losing shared or dynamically loaded dependencies.
AGENT_PANE_EXACT = {
    "webviews/test/agent-pane-new-chat-settles.test.ts",
    "webviews/test/agent-pane-picks-hold.test.ts",
    "webviews/test/chat-flow-shift-budget-browser.test.ts",
}
CHAT_FLOW_PREFIXES = (
    ".github/actions/playwright-apt-cache/",
    "scripts/ci/playwright-apt-deps.sh",
)
# A cmux-tui/ path routes the real-daemon lane through acpmux_build_input (below), not by prefix.
AGENT_PANE_PREFIXES = (
    ".github/actions/setup-cmux-tui-rust/",
    # Inputs of `cargo build -p acpmux --bin acpmux` outside cmux-tui/ (the same set as ci/steps.toml's
    # agent-pane-real-acpmux inputs): the real-daemon lane only, the chat-flow lane builds no Rust.
    ".cargo/",
    "skills/",
    "persisted-formats/",
    "Resources/sidebar-looks/",
    "Resources/theme-files/",
    *CHAT_FLOW_PREFIXES,
)
ACPMUX_BUILD_EXACT = {
    "ghostty-next",
    "workers/cmux-vm/cli/crates/cmux-vm-codegen/src/normalize.rs",
    "plans/cmux-next/spec-proposals/visuals/design-tokens.json",
    "docs/remote-agents-and-cloud.md",
}

# agent-pane-real-acpmux builds one Rust binary, `cargo build -p acpmux --bin acpmux`: of cmux-tui/crates/, only
# the crates in its build (its [dependencies] and [build-dependencies] by path, transitively) and the crates their
# sources include files from (`include_str!("../../cmux-browser-host/js/guide.md")`, a build script's
# rerun-if-changed) are its inputs. Every other cmux-tui/ path (the workspace manifest and lockfile, vendor/,
# bindings/, a crate not in the tree yet) still routes it. Before this, every cmux-tui/ change ran the real-daemon
# lane: about one feat-cmux-next pull request in five changed only crates acpmux does not build (2026-11-26, the
# last 400 merges: 182 routed the web-browser job, 142 needed it).
ACPMUX_CRATE = "acpmux"
_INCLUDED_FILE = re.compile(
    r'include(?:_str|_bytes)?!\s*\(\s*(?:concat!\s*\(\s*env!\s*\(\s*"CARGO_MANIFEST_DIR"\s*\)\s*,\s*)?"([^"]*\.\./[^"]*)"'
)
_RERUN_IF_CHANGED = re.compile(r'rerun-if-changed=([^"\s]*\.\./[^"\s]*)')


def _path_dependencies(manifest: dict, workspace_deps: dict):
    """(path, from_workspace) for each path dependency of a crate's manifest that its build compiles."""
    tables = [manifest.get("dependencies", {}), manifest.get("build-dependencies", {})]
    for target in manifest.get("target", {}).values():
        tables += [target.get("dependencies", {}), target.get("build-dependencies", {})]
    for table in tables:
        for name, spec in table.items():
            if not isinstance(spec, dict):
                continue
            if "path" in spec:
                yield spec["path"], False
            elif spec.get("workspace"):
                shared = workspace_deps.get(spec.get("package", name), workspace_deps.get(name))
                if isinstance(shared, dict) and "path" in shared:
                    yield shared["path"], True


@lru_cache(maxsize=None)
def acpmux_build_crates(root: str) -> frozenset[str] | None:
    """The cmux-tui/crates/ directories acpmux's build reads, for the tree at `root`; None when they cannot be read
    (then every cmux-tui/ path routes the lane)."""
    tui = Path(root) / "cmux-tui"
    crates = (tui / "crates").resolve()
    try:
        workspace_deps = tomllib.loads((tui / "Cargo.toml").read_text(encoding="utf-8")).get("workspace", {}).get(
            "dependencies", {})
        built: set[Path] = set()
        todo = [crates / ACPMUX_CRATE]
        while todo:
            crate = todo.pop().resolve()
            if crate in built:
                continue
            built.add(crate)
            manifest = tomllib.loads((crate / "Cargo.toml").read_text(encoding="utf-8"))
            for dep, from_workspace in _path_dependencies(manifest, workspace_deps):
                todo.append((tui if from_workspace else crate) / dep)
    except (OSError, UnicodeError, ValueError):
        return None
    read = {crate.name for crate in built if crate.parent == crates}
    for crate in built:
        sources = list((crate / "src").rglob("*.rs")) + [crate / "build.rs"]
        for source in sources:
            try:
                text = source.read_text(encoding="utf-8", errors="ignore")
            except OSError:
                continue
            for match in [*_INCLUDED_FILE.finditer(text), *_RERUN_IF_CHANGED.finditer(text)]:
                # include_str! is relative to the file, concat!(env!("CARGO_MANIFEST_DIR"), ..) and a build
                # script's paths to the crate: either may land in another crate.
                for base in (source.parent, crate):
                    target = (base / match.group(1)).resolve()
                    if crates in target.parents:
                        name = target.relative_to(crates).parts[0]
                        if (crates / name / "Cargo.toml").is_file():
                            read.add(name)
    return frozenset(read)


def acpmux_build_input(path: str, root: Path) -> bool:
    """Whether a cmux-tui/ path is an input of the acpmux daemon agent-pane-real-acpmux builds."""
    if not path.startswith("cmux-tui/"):
        return False
    parts = path.split("/")
    if len(parts) < 4 or parts[1] != "crates":
        return True
    built = acpmux_build_crates(str(root.resolve()))
    return built is None or parts[2] in built or not (root / "cmux-tui" / "crates" / parts[2]).is_dir()

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


# The green-marker keys (ci500k, Leo: "de facto, im asking for 99% fewer minutes of ci time, period."). A pull
# request whose merge tree and merge parent hold the same React inputs as a head that already passed
# (a base merge, a label event, a push that touched no React input) has nothing new to prove: ci-web.yml looks the
# key up in the Actions cache (reuse step) and skips the job, and the passing run saves it. Only the inputs
# the router already names count, plus the scripts and actions the jobs run; a change to any of them is a new key.
KEY_VERSION = "v1"
KEY_COMMON_EXACT = {".github/workflows/ci-web.yml"}
KEY_COMMON_PREFIXES = ("scripts/ci/", "scripts/cmux-next/", ".github/actions/")


def _is_react_input(path: str, matcher) -> bool:
    return path in REACT_EXACT or path.startswith(REACT_PREFIXES) or (matcher is not None and matcher(path))


def _is_agent_pane_input(path: str, matcher, root: Path) -> bool:
    # The same set routes() runs the lane on: a cmux-tui/ path counts only when acpmux's build reads it.
    return (
        path in AGENT_PANE_EXACT
        or path.startswith(AGENT_PANE_PREFIXES)
        or acpmux_build_input(path, root)
        or _is_react_input(path, matcher)
    )


def tree_input_key(rev: str, root: Path, predicate) -> str | None:
    """sha256 of the (path, blob) pairs of `rev`'s tree that `predicate` selects, or None when the tree is unreadable."""
    listing = subprocess.run(["git", "ls-tree", "-r", "-z", rev], capture_output=True, cwd=root)
    if listing.returncode != 0:
        return None
    digest = hashlib.sha256()
    for entry in listing.stdout.split(b"\0"):
        if not entry:
            continue
        meta, _, raw = entry.partition(b"\t")
        path = os.fsdecode(raw)
        if path in ALL_SUBAREA_INPUTS or path in KEY_COMMON_EXACT or path.startswith(KEY_COMMON_PREFIXES) or predicate(path):
            digest.update(meta.split(b" ")[2] + b" " + raw + b"\n")
    return digest.hexdigest()


def green_key(kind: str, root: Path | None = None) -> str:
    """`kind` is react or agent. The key of HEAD's inputs and its merge parent's, or "" (no reuse) when unreadable."""
    root = Path.cwd() if root is None else root
    matcher = web_bundle_input_matcher(str(root.resolve()))
    if kind == "react":
        predicate = lambda p: _is_react_input(p, matcher)  # noqa: E731
    else:
        predicate = lambda p: _is_agent_pane_input(p, matcher, root)  # noqa: E731
    heads = [tree_input_key(rev, root, predicate) for rev in ("HEAD", "HEAD^1")]
    if None in heads:
        return ""
    return hashlib.sha256(f"{KEY_VERSION} {kind} {heads[0]} {heads[1]}".encode()).hexdigest()[:40]


def is_react_input(path: str, repo_root: Path) -> bool:
    """True when a change to `path` runs react-apps-check: the one test classify_paths applies, so a content-addressed
    key over these paths (react_shard_receipt.py) names exactly the files whose change the router already runs the
    check for."""
    if path in ALL_SUBAREA_INPUTS or path in REACT_EXACT or path.startswith(REACT_PREFIXES):
        return True
    matcher = web_bundle_input_matcher(str(repo_root.resolve()))
    if matcher is None:
        raise RuntimeError("web bundle inputs unavailable")
    return bool(matcher(path))


def classify_paths(paths: list[str], repo_root: Path | None = None) -> WebSubareas:
    root = Path.cwd() if repo_root is None else repo_root
    db = False
    diff_sidecar = False
    instant = False
    production_build = False
    react_apps = False
    typecheck = False
    unit_tests = False
    agent_pane = False
    chat_flow = False

    for path in paths:
        if path in ALL_SUBAREA_INPUTS:
            db = diff_sidecar = instant = production_build = react_apps = typecheck = unit_tests = agent_pane = True
            chat_flow = True
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

        react_input = path in REACT_EXACT or path.startswith(REACT_PREFIXES)
        if not react_input and (matcher := web_bundle_input_matcher(str(root.resolve()))) is not None:
            react_input = matcher(path)
        if react_input:
            react_apps = True
            standalone_test = path.startswith("webviews/test/") and path.endswith((".test.ts", ".test.tsx"))
            if not standalone_test or path in AGENT_PANE_EXACT or path.startswith("webviews/test/support/"):
                agent_pane = chat_flow = True

        if path in TYPECHECK_EXACT or (
            path.startswith("web/")
            and (path.endswith(TYPECHECK_EXTENSIONS) or path.endswith(".json"))
        ):
            typecheck = True

        if path in AGENT_PANE_EXACT or path.startswith(CHAT_FLOW_PREFIXES):
            agent_pane = chat_flow = True
        if path in ACPMUX_BUILD_EXACT or path.startswith(AGENT_PANE_PREFIXES) or acpmux_build_input(path, root):
            agent_pane = True

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
        agent_pane=agent_pane,
        chat_flow=chat_flow,
    )


def changed_paths(base: str, head: str) -> list[str] | None:
    result = subprocess.run(
        ["git", "diff", "--no-renames", "--name-only", "-z", base, head, "--"],
        capture_output=True,
    )
    if result.returncode != 0:
        return None
    return [os.fsdecode(path) for path in result.stdout.split(b"\0") if path]


# The push base that runs every web subarea, whatever the push changed.
EVERY_SUBAREA = "all"


def route() -> int:
    output = Path(os.environ["GITHUB_OUTPUT"])
    if os.environ.get("EVENT_NAME") == "workflow_dispatch":
        WebSubareas.all().emit(output)
        return 0

    # A feat-cmux-next push routes from what the push brought (event.before), not its last
    # commit: a multi-commit push can end on a commit that touches no web path.
    push_base = os.environ.get("WEB_SUBAREAS_BASE", "").strip()
    if push_base == EVERY_SUBAREA:
        # A coalesced cmux-next-web.yml push run whose covered range is unknown (scripts/ci/web_coalesce.py), or a
        # post-merge batch call (ci-web.yml inputs.sha set), which runs every subarea.
        print("the range this push covers is unknown; running every web subarea")
        WebSubareas.all().emit(output)
        return 0
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
    if os.environ.get("EVENT_NAME") == "pull_request" and not push_base:
        with output.open("a", encoding="utf-8") as handle:
            handle.write(f"react_key={green_key('react') if areas.react_apps else ''}\n")
            handle.write(f"agent_key={green_key('agent') if areas.agent_pane else ''}\n")
    return 0


def has(subarea: str, paths_file: str | None) -> int:
    """Exit 0 when the change routes SUBAREA, 1 when it does not: a ci/steps.toml step's own finer router, over the
    paths `ci/run` lists in $CI_PATHS_FILE. No list, an unreadable one or an empty one routes it (everything changed)."""
    if subarea not in WebSubareas.__dataclass_fields__:
        raise SystemExit(f"web_subareas.py has: no subarea {subarea!r} (one of {sorted(WebSubareas.__dataclass_fields__)})")
    paths = None
    if paths_file:
        try:
            paths = [p for p in Path(paths_file).read_text(encoding="utf-8").splitlines() if p]
        except (OSError, UnicodeError):
            paths = None
    if not paths:
        print(f"web subarea {subarea}: the change's paths are unknown; it runs")
        return 0
    routed = getattr(classify_paths(paths), subarea)
    print(f"web subarea {subarea}: {'routed' if routed else 'not routed'} by {len(paths)} changed paths")
    return 0 if routed else 1


def main() -> int:
    if sys.argv[1:] == ["route"]:
        return route()
    if len(sys.argv) == 3 and sys.argv[1] == "has":
        return has(sys.argv[2], os.environ.get("CI_PATHS_FILE"))
    raise SystemExit("usage: web_subareas.py route | has SUBAREA (reads $CI_PATHS_FILE)")


if __name__ == "__main__":
    raise SystemExit(main())
