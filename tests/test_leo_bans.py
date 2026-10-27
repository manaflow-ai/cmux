#!/usr/bin/env python3
"""Leo's bans hold: the UI font is Inter, bundled, with its calculated tracking (ask-52da478628).

scripts/cmux-next/check-leo-bans.py fails when the UI family, the tracking constants or table, the
generated `--font-ui` or Swift family, or the bundled font change from schemas/type-scale/leo-bans.json,
when a webviews stylesheet names the system font instead of `var(--font-ui)`, and when the pin
changes without a `Leo-order:` trailer. Each test builds a small git repository with those files.
"""
import json
import math
import os
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import git_fixture_env  # disables git auto maintenance  # noqa: F401

SOURCE = Path(__file__).resolve().parents[1]
CHECK = SOURCE / "scripts/cmux-next/check-leo-bans.py"
A, B, C = -0.0223, 0.185, -0.1745
SIZES = {"caption": 11, "detail": 12, "body": 13, "field": 14, "title": 15, "heading": 20}
TABLE = {name: round(A + B * math.exp(C * size), 4) for name, size in SIZES.items()}
FONTS = "Packages/macOS/CmuxNext/Sources/CmuxNextDesign/Resources/Fonts/"


def ttf(family: str) -> bytes:
    """A font file with only a name table naming `family` (name ID 1, Windows platform)."""
    name = family.encode("utf-16-be")
    table = struct.pack(">HHH", 0, 1, 18) + struct.pack(">HHHHHH", 3, 1, 0x409, 1, len(name), 0) + name
    header = struct.pack(">IHHHH", 0x00010000, 1, 16, 0, 0)
    entry = struct.pack(">4sIII", b"name", 0, 12 + 16, len(table))
    return header + entry + table


def type_scale(family="Inter", file_family="Inter Variable", constants=(A, B, C), table=None):
    table = table or TABLE
    return {
        "font": {"family": family, "fileFamily": file_family,
                 "files": {"native": "InterVariable.ttf", "web": "InterVariable.woff2"}},
        "tracking": dict(zip("abc", constants)),
        "steps": [{"name": n, "size": s, "lineHeight": s + 4, "for": "x", "tracking": table[n]} for n, s in SIZES.items()],
    }


def pin(table=None):
    return {"uiFont": {"family": "Inter", "fileFamily": "Inter Variable"},
            "tracking": {"a": A, "b": B, "c": C}, "trackingTable": table or TABLE}


def desktop_css(stack='"Inter", -apple-system, system-ui, sans-serif', table=None):
    table = table or TABLE
    spacing = "\n".join(f"  --text-{n}--letter-spacing: {v}em;" for n, v in table.items())
    return ("/* shared */\n/* type-scale:begin. GENERATED; do not edit. */\n:root {\n"
            f"  --font-ui: {stack};\n{spacing}\n}}\n/* type-scale:end */\n")


def swift(family="Inter"):
    return (f'public static let family = "{family}"\npublic static let fileFamily = "Inter Variable"\n'
            f"public static let trackingA: CGFloat = {A}\npublic static let trackingB: CGFloat = {B}\n"
            f"public static let trackingC: CGFloat = {C}\n")


class LeoBansTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="leo-bans-")
        self.repo = Path(self.tmp.name)
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.email", "test@example.com")
        self.git("config", "user.name", "Test")
        self.write("schemas/type-scale/type-scale.json", json.dumps(type_scale()))
        self.write("schemas/type-scale/leo-bans.json", json.dumps(pin()))
        self.write("webviews/src/pages/shared/desktop.css", desktop_css())
        self.write("Packages/macOS/CmuxNext/Sources/CmuxNextDesign/TypeScale.generated.swift", swift())
        self.write("Packages/macOS/CmuxNext/Sources/CmuxNextDesign/CheckedFont.swift",
                   "case .default: BundledFonts.uiFont(size: size, weight: weight)\n")
        self.write(FONTS + "InterVariable.ttf", ttf("Inter Variable"))
        self.write(FONTS + "InterVariable.woff2", b"wOF2fake")
        self.write("webviews/src/page.css", ".page { font: 13px var(--font-ui); }\n"
                   "code { font-family: ui-monospace, \"SF Mono\", Menlo, monospace; }\n"
                   "/* was system-ui before Inter */\n"
                   ".standalone { font: 13px var(--font-ui, \"Inter\", -apple-system, system-ui, sans-serif); }\n")
        self.commit("base\n\nLeo-order: WE SAID INTER")
        self.base = self.git("rev-parse", "HEAD").strip()

    def tearDown(self):
        self.tmp.cleanup()

    def git(self, *args: str) -> str:
        return subprocess.run(["git", "-C", str(self.repo), *args], check=True, capture_output=True, text=True).stdout

    def write(self, path: str, content):
        target = self.repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        if isinstance(content, bytes):
            target.write_bytes(content)
        else:
            target.write_text(content, encoding="utf-8")

    def commit(self, message: str):
        self.git("add", "-A")
        self.git("commit", "-q", "-m", message)

    def check(self, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run([sys.executable, "-I", str(CHECK), "--repo", str(self.repo), *args],
                              capture_output=True, text=True)

    def assert_fails(self, needle: str, *args: str):
        result = self.check(*args)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn(needle, result.stdout)

    def test_inter_with_its_tracking_passes(self):
        for args in ((), ("--rev", "HEAD"), ("--rev", "HEAD", "--base", self.base)):
            with self.subTest(args=args):
                result = self.check(*args)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_another_ui_family_fails(self):
        self.write("schemas/type-scale/type-scale.json", json.dumps(type_scale(family="Geist")))
        self.assert_fails("UI font is 'Geist'")

    def test_changed_tracking_constants_fail(self):
        self.write("schemas/type-scale/type-scale.json", json.dumps(type_scale(constants=(-0.011, 0, 0))))
        self.assert_fails("tracking.a is -0.011")

    def test_a_step_off_the_table_fails(self):
        table = dict(TABLE, body=-0.011)
        self.write("schemas/type-scale/type-scale.json", json.dumps(type_scale(table=table)))
        self.assert_fails("step body tracking is -0.011")

    def test_font_ui_that_does_not_start_with_inter_fails(self):
        self.write("webviews/src/pages/shared/desktop.css", desktop_css(stack="system-ui, sans-serif"))
        self.assert_fails("--font-ui starts with 'system-ui'")

    def test_generated_letter_spacing_off_the_table_fails(self):
        self.write("webviews/src/pages/shared/desktop.css", desktop_css(table=dict(TABLE, title=0)))
        self.assert_fails("--text-title--letter-spacing is 0em")

    def test_swift_family_that_is_not_inter_fails(self):
        self.write("Packages/macOS/CmuxNext/Sources/CmuxNextDesign/TypeScale.generated.swift", swift(family="SF Pro"))
        self.assert_fails("TypeScale.family is 'SF Pro'")

    def test_default_design_off_the_bundled_face_fails(self):
        self.write("Packages/macOS/CmuxNext/Sources/CmuxNextDesign/CheckedFont.swift",
                   "case .default: .systemFont(ofSize: size, weight: weight)\n")
        self.assert_fails("no longer draws in the bundled UI font")

    def test_a_bundled_font_of_another_family_fails(self):
        self.write(FONTS + "InterVariable.ttf", ttf("Geist"))
        self.assert_fails("its family is 'Geist'")

    def test_a_stylesheet_naming_the_system_font_fails(self):
        for rule in (".row { font-family: system-ui; }", ".menu{font:13px -apple-system,BlinkMacSystemFont,sans-serif}",
                     ":root { --ui-font: -apple-system, sans-serif; }"):
            with self.subTest(rule=rule):
                self.write("webviews/src/agent/row.css", rule + "\n")
                self.assert_fails("webviews/src/agent/row.css:1: names the system font")

    def test_a_pin_change_needs_leo_order(self):
        self.write("schemas/type-scale/leo-bans.json", json.dumps(dict(pin(), note="moved")))
        self.commit("tweak the pin")
        self.assert_fails("no `Leo-order: <Leo's words>` trailer", "--rev", "HEAD", "--base", self.base)
        self.write("schemas/type-scale/leo-bans.json", json.dumps(dict(pin(), note="moved again")))
        self.commit("move the pin\n\nLeo-order: use this tracking")
        result = self.check("--rev", "HEAD", "--base", self.base)
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_the_repository_keeps_leo_bans(self):
        result = subprocess.run([sys.executable, "-I", str(CHECK), "--repo", str(SOURCE)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    os.environ.pop("GIT_DIR", None)
    unittest.main()
