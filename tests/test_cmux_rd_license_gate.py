#!/usr/bin/env python3
"""cmux-rd's license gate (cmux-tui/crates/cmux-rd-host/scripts/release.py license-gate), which
cmux-tui-artifacts.yml's build-cmux-rd runs before cmux-rd is published to the channel: it lists
every crate not under permissive licenses only and stops on one that is GPL, LGPL or AGPL only
and not this repository's own."""

from __future__ import annotations

import importlib.util
import json
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

LOCK = """
version = 4

[[package]]
name = "cmux-rd-host"
version = "0.2.6"

[[package]]
name = "serde"
version = "1.0.0"
source = "registry+https://github.com/rust-lang/crates.io-index"

[[package]]
name = "gpl-thing"
version = "0.1.0"
source = "registry+https://github.com/rust-lang/crates.io-index"
"""


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


class Gate(unittest.TestCase):
    def run_gate(self, crates):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            (tmp / "Cargo.lock").write_text(LOCK)
            (tmp / "license.json").write_text(json.dumps(crates))
            out = tmp / "table.md"
            code = release.license_gate(tmp / "license.json", out, lock=tmp / "Cargo.lock")
            return code, out.read_text()

    def test_own_gpl_crate_and_permissive_crates_pass(self):
        code, table = self.run_gate([
            {"name": "cmux-rd-host", "version": "0.2.6", "license": "GPL-3.0-or-later"},
            {"name": "serde", "version": "1.0.0", "license": "MIT OR Apache-2.0"},
        ])
        self.assertEqual(code, 0)
        self.assertIn("| cmux-rd-host | 0.2.6 | GPL-3.0-or-later | this repository's own crate", table)
        self.assertNotIn("serde", table)

    def test_a_registry_gpl_crate_stops_the_release(self):
        code, table = self.run_gate([{"name": "gpl-thing", "version": "0.1.0", "license": "GPL-2.0-only"}])
        self.assertEqual(code, 1)
        self.assertIn("STOP", table)

    def test_mpl_is_listed_without_a_stop(self):
        code, table = self.run_gate([{"name": "serde", "version": "1.0.0", "license": "MPL-2.0"}])
        self.assertEqual(code, 0)
        self.assertIn("| serde | 1.0.0 | MPL-2.0 | listed, no stop", table)


if __name__ == "__main__":
    unittest.main()
