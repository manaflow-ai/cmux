#!/usr/bin/env python3
"""scripts/ci/check_default_path_fleet_only.py catches the shapes that reached users, and passes the rest."""
import importlib.util
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("chk", ROOT / "scripts/ci/check_default_path_fleet_only.py")
chk = importlib.util.module_from_spec(spec)
spec.loader.exec_module(chk)


def diff(path: str, *added: str) -> str:
    body = "\n".join("+" + a for a in added)
    return f"--- a/{path}\n+++ b/{path}\n@@ -1,1 +1,{len(added)} @@\n{body}\n"


class DefaultPathFleetOnly(unittest.TestCase):
    def hit(self, path, *added):
        return chk.findings(diff(path, *added))

    def test_catches_what_reached_users(self):
        rust = "cmux-tui/crates/acpmux/src/hub/x.rs"
        self.assertTrue(self.hit(rust, 'let on = !matches!(v.map(str::trim), Some("0" | "off"));'))
        self.assertTrue(self.hit(rust, 'const NOTE: &str = "use --harness claude-sr2";'))
        self.assertTrue(self.hit(rust, "let capacity_fallback_after = cfg.unwrap_or(true);"))
        self.assertTrue(self.hit(rust, 'hub.set_model(id, "claude-sonnet-5-5")'))
        self.assertTrue(self.hit("web/app/lib/posthog-client.ts", "posthog.init(key, { persistence: 'localStorage+cookie' })"))

    def test_passes_ordinary_changes_and_other_paths(self):
        self.assertFalse(self.hit("cmux-tui/crates/acpmux/src/hub/x.rs", "let n = items.len();"))
        self.assertFalse(self.hit("docs/notes.md", "use claude-sr2 on the fleet"))
        self.assertFalse(self.hit("cmux-tui/crates/acpmux/src/hub/x_tests.rs", "let on = !matches!(v, Some(\"0\"));"))
        self.assertFalse(self.hit("Packages/macOS/Fleet/Sources/A.swift", "// claude-sr2"))

    def test_marker_overrides_on_the_line_or_above(self):
        rust = "cmux-tui/crates/acpmux/src/hub/x.rs"
        self.assertFalse(self.hit(rust, 'let on = !matches!(v, Some("0")); // fleet-only-ok: everyone wants it'))
        self.assertFalse(self.hit(rust, "// fleet-only-ok: everyone wants it", 'let on = !matches!(v, Some("0"));'))


if __name__ == "__main__":
    unittest.main()
