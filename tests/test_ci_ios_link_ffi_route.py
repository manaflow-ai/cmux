"""The Linux FFI binding check starts on a landing head that touches the FFI crate or its binding.

cmux#62170 changed a doc comment in cmux-mobile-link-ffi/src/pane_filter.rs (uniffi folds doc comments into
its checksums) and hand-edited CmuxMobileLinkFFI.swift instead of regenerating it. Its router run 46093023059
skipped ios-link-ffi-linux.yml ("landing on the affected tier: the full tier runs once an hour"), so the stale
binding merged (be9db84d) and "Swift to Rust FFI on Linux" stayed red on feat-cmux-next until cmux#64446.

cmux#65536 added `reads_without_wake` to cmux-cloud-handlers' Hint; the FFI's struct literal (cloud_wake.rs) stopped
compiling (E0063) and no pull request check built it, because a crate the FFI only depends on was outside `affects`.
FfiClosureCovered reads the FFI's path dependencies from the Cargo.toml files, transitively, and requires each one in
both globs, so a new dependency cannot fall out of the route.
"""
from __future__ import annotations

import os
import sys
import tomllib
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import pr_router  # noqa: E402

NAME = "ios-link-ffi-linux.yml"
CRATE_DOC = "cmux-next-ios/rust/crates/cmux-mobile-link-ffi/src/pane_filter.rs"
BINDING = "cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileLinkFFI/CmuxMobileLinkFFI.swift"
FFI = "cmux-next-ios/rust/crates/cmux-mobile-link-ffi"
# cmux#65536's changed files (merged 21862b8f): only the Rust one is a crate the FFI compiles.
PR_65536 = [
    "Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/CloudTunables.swift",
    "Packages/macOS/CmuxNext/Sources/CmuxNextApp/Cloud/AgentPaneCloudMachines+App.swift",
    "Packages/macOS/CmuxNext/Tests/Fixtures/default-render/native.txt",
    "cmux-tui/crates/cmux-cloud-handlers/src/wake_hint.rs",
    "cmux-tui/crates/cmux-cloud-handlers/src/wake_hint_tests.rs",
    "scripts/ci/cargo_affected.py",
]


def _workspace_deps(crate: Path) -> dict:
    for parent in (crate, *crate.parents):
        manifest = parent / "Cargo.toml"
        if manifest.is_file():
            data = tomllib.loads(manifest.read_text(encoding="utf-8"))
            if "workspace" in data:
                return {"root": parent, "deps": data["workspace"].get("dependencies", {})}
        if parent == ROOT:
            break
    return {"root": crate, "deps": {}}


def path_deps(crate: Path) -> set[Path]:
    """CRATE's path dependencies (normal and build, any target; `workspace = true` resolved), as resolved dirs."""
    data = tomllib.loads((crate / "Cargo.toml").read_text(encoding="utf-8"))
    ws = _workspace_deps(crate)
    tables = [data] + list(data.get("target", {}).values())
    out = set()
    for table in tables:
        for section in ("dependencies", "build-dependencies"):
            for name, spec in table.get(section, {}).items():
                if not isinstance(spec, dict):
                    continue
                if "path" in spec:
                    out.add((crate / spec["path"]).resolve())
                elif spec.get("workspace"):
                    shared = ws["deps"].get(spec.get("package", name), {})
                    if isinstance(shared, dict) and "path" in shared:
                        out.add((ws["root"] / shared["path"]).resolve())
    return out


def ffi_closure() -> list[str]:
    seen: set[Path] = set()
    pending = [(ROOT / FFI).resolve()]
    while pending:
        crate = pending.pop()
        if crate not in seen:
            seen.add(crate)
            pending.extend(path_deps(crate))
    return sorted(os.path.relpath(c, ROOT) for c in seen)


class IosLinkFfiRoute(unittest.TestCase):
    def setUp(self) -> None:
        self.callees = pr_router.load_manifest()
        repo = {"full_name": "manaflow-ai/cmux"}
        self.pr = {"draft": False, "head": {"repo": repo}, "base": {"ref": "feat-cmux-next", "repo": repo},
                   "labels": [{"name": "ready-to-land"}]}

    def route(self, action: str, path: str | list[str]) -> tuple[bool, str]:
        event = {"action": action, "label": {"name": "ready-to-land"}, "pull_request": self.pr}
        tier = pr_router.head_tier.tier("pull_request", event, land_switch="1", land_full_switch="0")
        self.assertTrue(pr_router.head_tier.land_affected(tier))
        files = [path] if isinstance(path, str) else path
        start, why = pr_router.route(event, self.callees, files, decided=tier)
        return NAME in start, why[NAME]

    def test_a_landing_head_that_touches_the_ffi_crate_or_binding_starts_it(self) -> None:
        for action in ("labeled", "synchronize"):
            for path in (CRATE_DOC, BINDING):
                with self.subTest(action=action, path=path):
                    starts, why = self.route(action, path)
                    self.assertTrue(starts, why)

    def test_a_landing_head_that_touches_no_ffi_input_skips_it(self) -> None:
        starts, why = self.route("synchronize", "docs/readme.md")
        self.assertFalse(starts, why)
        starts, why = self.route("synchronize", "cmux-tui/crates/cmux-core/src/lib.rs")
        self.assertFalse(starts, why)

    def test_cmux_65536_a_change_to_a_crate_the_ffi_compiles_starts_it(self) -> None:
        starts, why = self.route("labeled", PR_65536)
        self.assertTrue(starts, why)


class FfiClosureCovered(unittest.TestCase):
    """Every crate cmux-mobile-link-ffi compiles is in both of the route's glob lists."""

    def test_every_path_dependency_of_the_ffi_routes_it(self) -> None:
        config = pr_router.load_manifest()[NAME]
        closure = ffi_closure()
        self.assertIn("cmux-tui/crates/cmux-cloud-handlers", closure)
        missing = {}
        for crate in closure:
            probe = [f"{crate}/src/lib.rs"]
            gaps = [key for key, ok in (("paths", pr_router.matches_filter(config, probe)),
                                         ("affects", pr_router.affects(config, probe))) if not ok]
            if gaps:
                missing[crate] = gaps
        self.assertEqual(missing, {}, "add `<crate>/**` to ios-link-ffi-linux.yml's paths and affects in "
                                      "scripts/ci/pr_router.json")


if __name__ == "__main__":
    unittest.main()
