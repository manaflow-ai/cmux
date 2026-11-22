#!/usr/bin/env python3
"""rust-live.py's outside_reads(): every form a cmux-tui crate uses to read a file outside cmux-tui/
while it builds, found from the source, so `cmux live start --rust --build-host H` sends it. The
cmux-tui test `rust_live_sends_every_outside_input` checks the whole set against cargo's dep-info;
this one pins each form on a small tree, with no cargo."""
import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("rust_live", ROOT / "scripts/cmux-next/rust-live.py")
rust_live = importlib.util.module_from_spec(spec)
sys.modules["rust_live"] = rust_live  # dataclasses look their module up here
spec.loader.exec_module(rust_live)


class OutsideReads(unittest.TestCase):
    def test_each_form_that_leaves_the_workspace(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp).resolve()
            crate = repo / "cmux-tui/crates/tokens"
            (crate / "src/spec").mkdir(parents=True)
            (crate / "Cargo.toml").write_text("[package]\nname = \"tokens\"\n")
            (crate / "src/lib.rs").write_text(
                'pub static A: &str = include_str!("../../../../plans/design-tokens.json");\n'
                "pub static B: &[u8] = include_bytes!(concat!(\n"
                '    env!("CARGO_MANIFEST_DIR"),\n'
                '    "/../../../Resources/logo.png"\n'
                "));\n"
                '/// `include_str!("../../../../docs/example-only.md")` in a doc comment reads nothing.\n'
                'pub static C: &str = include_str!("inside.txt");\n'
            )
            (crate / "src/spec/nested.rs").write_text(
                'const D: &str = include_str!(\n    "../../../../../schemas/x/vectors.json"\n);\n'
            )
            (crate / "build.rs").write_text(
                'const TOKENS: &str = "../../../plans/motion.json";\n'
                'fn main() { let _ = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../ghostty-next"); '
                'let _ = "../sibling-crate"; }\n'
            )
            reads = {p.relative_to(repo).as_posix() for p in rust_live.outside_reads(repo / "cmux-tui")}
            self.assertEqual(reads, {
                "plans/design-tokens.json",
                "Resources/logo.png",
                "schemas/x/vectors.json",
                "plans/motion.json",
                "ghostty-next",
            })


if __name__ == "__main__":
    unittest.main()
