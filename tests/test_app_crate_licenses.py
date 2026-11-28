#!/usr/bin/env python3
"""The app-linked crate license gate (plans/cmux-next/remote-desktop-c7.md 3):
x264, cmux-rd-host and OpenH264 source never enter an app-linked crate graph,
and every crate in it carries an allowed license or is one of the six named
first-party GPL crates. Runs on synthetic `cargo metadata` output, no cargo."""

import importlib.util
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "check_app_crate_licenses", ROOT / "scripts/cmux-next/check_app_crate_licenses.py"
)
gate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gate)


def metadata(packages, edges, root="cmux-app-ffi", features=None):
    """packages: {name: license}; edges: {name: [(dep, kind)]} with kind None (normal) or "build"/"dev";
    features: {name: [resolved features]}."""
    features = features or {}
    pkgs = [{"id": n, "name": n, "license": lic, "features": {}} for n, lic in packages.items()]
    nodes = [
        {
            "id": n,
            "features": features.get(n, []),
            "deps": [{"pkg": d, "dep_kinds": [{"kind": k}]} for d, k in edges.get(n, [])],
        }
        for n in packages
    ]
    return {"packages": pkgs, "resolve": {"root": root, "nodes": nodes}}


class AppCrateLicenseGate(unittest.TestCase):
    def test_a_clean_graph_passes(self):
        m = metadata(
            {"cmux-app-ffi": "GPL-3.0-or-later", "cmux-rd-ffi": "GPL-3.0-or-later", "serde": "MIT OR Apache-2.0"},
            {"cmux-app-ffi": [("cmux-rd-ffi", None)], "cmux-rd-ffi": [("serde", None)]},
        )
        self.assertEqual(gate.check(m, "cmux-app-ffi"), [])

    def test_x264_and_the_host_crate_are_refused(self):
        m = metadata(
            {"cmux-app-ffi": "GPL-3.0-or-later", "cmux-rd-host": "GPL-3.0-or-later", "x264-sys": "GPL-2.0"},
            {"cmux-app-ffi": [("cmux-rd-host", None)], "cmux-rd-host": [("x264-sys", None)]},
        )
        problems = "\n".join(gate.check(m, "cmux-app-ffi"))
        self.assertIn("cmux-rd-host", problems)
        self.assertIn("x264-sys", problems)

    def test_openh264_built_from_source_is_refused(self):
        m = metadata(
            {"cmux-app-ffi": "GPL-3.0-or-later", "openh264-sys2": "BSD-2-Clause"},
            {"cmux-app-ffi": [("openh264-sys2", None)]},
            features={"openh264-sys2": ["source"]},
        )
        self.assertTrue(any("openh264" in p for p in gate.check(m, "cmux-app-ffi")))

    def test_openh264_loading_ciscos_library_at_runtime_is_allowed(self):
        m = metadata(
            {"cmux-app-ffi": "GPL-3.0-or-later", "openh264-sys2": "BSD-2-Clause"},
            {"cmux-app-ffi": [("openh264-sys2", None)]},
            features={"openh264-sys2": ["libloading"]},
        )
        self.assertEqual(gate.check(m, "cmux-app-ffi"), [])

    def test_an_unlisted_gpl_crate_is_refused_but_build_and_dev_deps_are_ignored(self):
        m = metadata(
            {"cmux-app-ffi": "GPL-3.0-or-later", "gpl-thing": "GPL-3.0", "cc": "MIT OR Apache-2.0", "proptest": "GPL-3.0"},
            {"cmux-app-ffi": [("gpl-thing", None), ("cc", "build"), ("proptest", "dev")]},
        )
        problems = gate.check(m, "cmux-app-ffi")
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("gpl-thing", problems[0])

    def test_license_expressions(self):
        self.assertTrue(gate.license_allowed("MIT OR Apache-2.0"))
        self.assertTrue(gate.license_allowed("Apache-2.0 WITH LLVM-exception"))
        self.assertTrue(gate.license_allowed("(MIT OR Apache-2.0) AND Unicode-3.0"))
        self.assertTrue(gate.license_allowed("MIT/Apache-2.0"))
        self.assertFalse(gate.license_allowed("GPL-3.0-or-later"))
        self.assertFalse(gate.license_allowed("MIT AND GPL-2.0"))
        self.assertFalse(gate.license_allowed(None))

    def test_the_seven_first_party_gpl_crates_are_named_exactly(self):
        self.assertEqual(
            sorted(gate.FIRST_PARTY_GPL),
            sorted(
                [
                    "cmux-rd-ffi",
                    "cmux-app-ffi",
                    "cmux-rd-core",
                    "cmux-rd-proto",
                    "cmux-layout-reducer",
                    "cmux-layout-reducer-ffi",
                    "cmux-remote-browser",
                ]
            ),
        )

    def test_the_remote_browser_is_checked_by_default(self):
        self.assertIn("cmux-remote-browser", [root for _, root in gate.DEFAULT_ROOTS])
        self.assertIn("cmux-app-ffi", [root for _, root in gate.DEFAULT_ROOTS])


if __name__ == "__main__":
    unittest.main()
