#!/usr/bin/env python3
"""The look's planner (scripts/cmux-next/hot-verify.py plan) takes its web layer from the webview router.

cmux#56364 at 40124f05: the planner chose layers=rust while land-judge's webview_routes (the router,
scripts/ci/web_subareas.py classify_paths react_apps) routed schemas/settings/source/machines.json to the
webviews. live_apply filed schemas/ as no-app, so the look never showed the web the change makes. The planner now
asks the router itself, so the two never keep two lists.

    python3 tests/test_hot_verify_plan_web_routes.py
"""
from __future__ import annotations

import importlib.util
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("hot_verify_under_test", ROOT / "scripts/cmux-next/hot-verify.py")
hv = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hv)

SCHEMA = "schemas/settings/source/machines.json"
RUST = "cmux-tui/crates/acpmux/src/lib.rs"


def git(repo: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, text=True).stdout.strip()


class PlanWebRoutes(unittest.TestCase):
    def plan(self, changed: list[str], parts: list[str]) -> dict:
        """hv.plan of a head that changes CHANGED over its base, with hot-apply's own rules faked to PARTS (as
        live_apply sorts the paths: schemas/ is no-app there) and the real webview router of this checkout."""
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            git(repo, "init", "-q")
            git(repo, "config", "user.email", "t@example.com")
            git(repo, "config", "user.name", "t")
            (repo / "README").write_text("base\n")
            git(repo, "add", "-A")
            git(repo, "commit", "-qm", "base")
            base = git(repo, "rev-parse", "HEAD")
            git(repo, "update-ref", f"refs/remotes/origin/{hv.BASE_BRANCH}", base)
            for path in changed:
                (repo / path).parent.mkdir(parents=True, exist_ok=True)
                (repo / path).write_text("changed\n")
            git(repo, "add", "-A")
            git(repo, "commit", "-qm", "head")
            head = git(repo, "rev-parse", "HEAD")
            h = SimpleNamespace(
                _plan=lambda *a, **k: {"parts": parts, "left": {hv.LEFT_WEB: []}, "notes": [], "tree_key": "k",
                                       "published": True},
                abi_at=lambda repo, commit: 1, tree_key=lambda rules, commit: "k", published=lambda key: True)
            with mock.patch.object(hv, "hot", return_value=h), \
                    mock.patch.object(hv, "rules_for", return_value=ROOT), \
                    mock.patch.object(hv, "pins_differ", return_value=False):
                return hv.plan(repo, f"sha:{head}", base=base)

    def test_router_routes_the_settings_schema(self) -> None:
        self.assertEqual(hv.webview_routed(ROOT, [SCHEMA, RUST, "docs/x.md"]), [SCHEMA])

    def test_settings_schema_plans_the_web_layer(self) -> None:
        planned = self.plan([SCHEMA, RUST], ["rust"])
        self.assertIn("web", planned["layers"])
        self.assertIn("rust", planned["layers"])
        self.assertFalse(planned["needs_build"], planned["build"])

    def test_rust_only_change_still_plans_rust_alone(self) -> None:
        planned = self.plan([RUST], ["rust"])
        self.assertEqual(planned["layers"], ["rust"])

    def test_docs_only_change_plans_no_layer(self) -> None:
        self.assertEqual(self.plan(["docs/notes.md"], [])["layers"], [])

    def test_router_loads_on_a_python_with_no_tomllib(self) -> None:
        """`cmux app try` runs hot-verify.py on the Mac's own python3 (3.9 on macOS), which has no tomllib: the
        router's top-level `import tomllib` failed every try (team-dev-build-swap, hq#30355's row,
        ModuleNotFoundError at web_subareas.py:15). The router still routes; acpmux's crates just go unread."""
        with mock.patch.dict(sys.modules, {"tomllib": None, "hot_verify_web_subareas": None}):
            sys.modules.pop("hot_verify_web_subareas")
            self.assertEqual(hv.webview_routed(ROOT, [SCHEMA, RUST, "docs/x.md"]), [SCHEMA])
            router = sys.modules["hot_verify_web_subareas"]
            self.assertIsNone(router.tomllib)
            self.assertIsNone(router.acpmux_build_crates.__wrapped__(str(ROOT)))


if __name__ == "__main__":
    unittest.main()
