#!/usr/bin/env python3
"""cmux-rd's license gate and notices list (cmux-tui/crates/cmux-rd-host/scripts/release.py): the
crates a release links, read from `cargo metadata`'s resolve graph (normal edges, no proc macros),
stop on one that is GPL, LGPL or AGPL only or has no license unless it is this repository's own,
and the notices document exactly the gated list. Unit tests on fabricated metadata; the real crate
tree is checked by cmux-rd-host's tests/release_features.rs."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "cmux-tui/crates/cmux-rd-host/scripts/release.py"


def load():
    spec = importlib.util.spec_from_file_location("cmux_rd_release", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


release = load()

class LicenseClass(unittest.TestCase):
    def test_permissive_expressions(self):
        for expression in (
            "MIT",
            "MIT OR Apache-2.0",
            "MIT/Apache-2.0",
            "Apache-2.0 WITH LLVM-exception OR Apache-2.0 OR MIT",
            "(MIT OR Apache-2.0) AND Unicode-3.0",
            "ISC AND MIT",
            "BSD-2-Clause",
            "Zlib OR Apache-2.0 OR MIT",
        ):
            self.assertEqual(release.license_class(expression), "permissive", expression)

    def test_a_permissive_alternative_is_enough(self):
        self.assertEqual(release.license_class("GPL-3.0-or-later OR MIT"), "permissive")
        self.assertEqual(release.license_class("LGPL-2.1-or-later OR (MIT AND ISC)"), "permissive")

    def test_gpl_family_only_is_strong(self):
        for expression in ("GPL-3.0-or-later", "LGPL-2.1-only", "AGPL-3.0", "GPL-2.0 OR LGPL-2.1", "MIT AND GPL-2.0-only"):
            self.assertEqual(release.license_class(expression), "strong", expression)

    def test_weak_and_unknown_are_listed(self):
        for expression in ("MPL-2.0", "MPL-2.0 OR GPL-3.0", "OpenSSL", None, ""):
            self.assertEqual(release.license_class(expression), "weak", expression)

    def test_two_groups(self):
        self.assertEqual(
            sorted(map(sorted, release._alternatives("(A OR B) AND (C OR D)"))),
            [["A", "C"], ["A", "D"], ["B", "C"], ["B", "D"]],
        )


REGISTRY = "registry+https://github.com/rust-lang/crates.io-index"


def metadata(deps):
    """A fabricated `cargo metadata`: cmux-rd-host from a path, and each (name, license, source,
    kind) one edge from it; `inner` deps hang off the first one."""
    def pkg(name, license, source, kind="lib"):
        return {"id": f"{name} 1.0.0", "name": name, "version": "1.0.0", "license": license,
                "source": source, "targets": [{"kind": [kind]}]}
    packages = [pkg("cmux-rd-host", "GPL-3.0-or-later", None)]
    nodes = []
    edges = []
    for name, license, source, kind, *rest in deps:
        packages.append(pkg(name, license, source, rest[0] if rest else "lib"))
        edges.append({"name": name, "pkg": f"{name} 1.0.0", "dep_kinds": [{"kind": kind, "target": None}]})
        nodes.append({"id": f"{name} 1.0.0", "deps": [], "features": []})
    nodes.append({"id": "cmux-rd-host 1.0.0", "deps": edges, "features": []})
    return {"packages": packages, "resolve": {"root": "cmux-rd-host 1.0.0", "nodes": nodes}}


class Closure(unittest.TestCase):
    def test_only_normal_edges_and_no_proc_macros(self):
        crates = release.linked_crates(metadata([
            ("serde", "MIT", REGISTRY, None),
            ("dev-only", "GPL-3.0", REGISTRY, "dev"),
            ("build-only", "GPL-3.0", REGISTRY, "build"),
            ("a-macro", "MIT", REGISTRY, None, "proc-macro"),
        ]))
        self.assertEqual([c["name"] for c in crates], ["cmux-rd-host", "serde"])


class Gate(unittest.TestCase):
    def gate(self, deps):
        return release.license_gate(release.linked_crates(metadata(deps)))

    def test_own_gpl_crate_and_permissive_crates_pass(self):
        code, table = self.gate([("cmux-rd-core", "GPL-3.0-or-later", None, None), ("serde", "MIT OR Apache-2.0", REGISTRY, None)])
        self.assertEqual(code, 0)
        self.assertIn("| cmux-rd-core | 1.0.0 | GPL-3.0-or-later | this repository's own crate", table)
        self.assertNotIn("serde", table)

    def test_a_registry_gpl_crate_stops_the_release(self):
        code, table = self.gate([("gpl-thing", "GPL-2.0-only", REGISTRY, None)])
        self.assertEqual(code, 1)
        self.assertIn("STOP", table)

    def test_no_license_stops_the_release(self):
        code, table = self.gate([("bare", None, REGISTRY, None)])
        self.assertEqual(code, 1)
        self.assertIn("STOP: no license field", table)

    def test_an_own_name_from_a_registry_is_not_ours(self):
        code, _ = self.gate([("cmux-rd-core", "GPL-3.0-or-later", REGISTRY, None)])
        self.assertEqual(code, 1)

    def test_mpl_is_listed_without_a_stop(self):
        code, table = self.gate([("serde", "MPL-2.0", REGISTRY, None)])
        self.assertEqual(code, 0)
        self.assertIn("| serde | 1.0.0 | MPL-2.0 | listed, no stop", table)


class NoticesReadTheGatedList(unittest.TestCase):
    def test_notices_document_exactly_the_gated_crates(self):
        meta = metadata([("serde", "MIT", REGISTRY, None), ("dev-only", "GPL-3.0", REGISTRY, "dev")])
        seen = {}
        real = release.crates_markdown

        def fake(cargo_tree, cache, tag, target=release.TARGET):
            seen["lines"] = cargo_tree.read_text(encoding="utf-8")
            raise SystemExit("stop after the crate list")

        release.crates_markdown = fake
        try:
            with tempfile.TemporaryDirectory() as tmp, self.assertRaises(SystemExit):
                release.notices(Path(tmp) / "n.md", Path(tmp) / "cache", metadata=meta)
        finally:
            release.crates_markdown = real
        self.assertEqual(seen["lines"], release.crate_lines(release.linked_crates(meta)))
        self.assertEqual(seen["lines"], "cmux-rd-host v1.0.0\nserde v1.0.0\n")

    def test_a_stopped_gate_writes_no_notices(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(SystemExit) as stop:
                release.notices(Path(tmp) / "n.md", Path(tmp) / "cache", metadata=metadata([("gpl", "GPL-2.0-only", REGISTRY, None)]))
            self.assertIn("no notices written", str(stop.exception))
            self.assertFalse((Path(tmp) / "n.md").exists())


if __name__ == "__main__":
    unittest.main()
