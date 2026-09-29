#!/usr/bin/env python3
"""Behavioral tests for scripts/ci/appcast_minimum_system_version.py.

cmux-next requires macOS 26; the legacy app ran on macOS 14. These cover the
floor read from a built bundle, the appcast item for the new archive, and the
pinned legacy item that keeps macOS 14/15 on the last legacy build.
"""

from __future__ import annotations

import importlib.util
import plistlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "ci" / "appcast_minimum_system_version.py"
spec = importlib.util.spec_from_file_location("appcast_floor", SCRIPT)
floor_tool = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(floor_tool)


def appcast(*items: str) -> str:
    return (
        '<?xml version="1.0" standalone="yes"?>\n'
        '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">\n'
        "    <channel>\n        <title>cmux</title>\n" + "\n".join(items) + "\n    </channel>\n</rss>\n"
    )


def item(version: str, archive: str, minimum: str | None, deltas: bool = False) -> str:
    min_line = f"            <sparkle:minimumSystemVersion>{minimum}</sparkle:minimumSystemVersion>\n" if minimum else ""
    delta = (
        "            <sparkle:deltas>\n"
        f'                <enclosure url="https://example.invalid/{archive}-old.delta" sparkle:deltaFrom="1" length="1" type="application/octet-stream"/>\n'
        "            </sparkle:deltas>\n"
        if deltas
        else ""
    )
    return (
        "        <item>\n"
        f"            <title>{version}</title>\n"
        f"            <sparkle:version>{version}</sparkle:version>\n"
        f"{min_line}"
        f'            <enclosure url="https://github.com/manaflow-ai/cmux/releases/download/v{version}/{archive}" length="3" type="application/octet-stream" sparkle:edSignature="sig"/>\n'
        f"{delta}"
        "        </item>"
    )


def make_app(root: Path, minimum: str | None) -> Path:
    app = root / "cmux.app"
    (app / "Contents" / "MacOS").mkdir(parents=True)
    info = {"CFBundleExecutable": "cmux", "CFBundleIdentifier": "com.cmuxterm.app"}
    if minimum is not None:
        info["LSMinimumSystemVersion"] = minimum
    with (app / "Contents" / "Info.plist").open("wb") as handle:
        plistlib.dump(info, handle)
    (app / "Contents" / "MacOS" / "cmux").write_text("binary")
    return app


class FloorTests(unittest.TestCase):
    def test_reads_the_bundle_floor(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            app = make_app(Path(tmp), "26.0")
            self.assertEqual(floor_tool.floor(app, minos_reader=lambda _: ["26.0", "26.0"]), "26.0")

    def test_missing_floor_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            app = make_app(Path(tmp), None)
            with self.assertRaisesRegex(floor_tool.FloorError, "no LSMinimumSystemVersion"):
                floor_tool.floor(app, minos_reader=lambda _: ["26.0"])

    def test_floor_below_the_binary_deployment_target_fails(self) -> None:
        # A macOS 26 binary whose plist still says 14.0 would be offered to macOS 14.
        with tempfile.TemporaryDirectory() as tmp:
            app = make_app(Path(tmp), "14.0")
            with self.assertRaisesRegex(floor_tool.FloorError, "below the executable's deployment target 26.0"):
                floor_tool.floor(app, minos_reader=lambda _: ["26.0"])

    def test_reads_minos_from_a_real_mach_o(self) -> None:
        if sys.platform != "darwin":
            self.skipTest("needs otool")
        self.assertTrue(all(floor_tool.parse_version(v) for v in floor_tool.executable_minos(Path("/bin/ls"))))


class EnforceTests(unittest.TestCase):
    def test_keeps_a_matching_floor(self) -> None:
        xml = appcast(item("107", "cmux-macos.dmg", "26.0"))
        self.assertEqual(floor_tool.enforce(xml, "cmux-macos.dmg", "26.0"), xml)

    def test_inserts_a_missing_floor_only_on_the_new_archive(self) -> None:
        xml = appcast(
            item("3700000000002", "cmux-nightly-macos-arm64-3700000000002.dmg", None, deltas=True),
            item("3700000000001", "cmux-nightly-macos-arm64-3700000000001.dmg", "14.0"),
        )
        patched = floor_tool.enforce(xml, "cmux-nightly-macos-arm64-3700000000002.dmg", "26.0")
        new_item, old_item = floor_tool.ITEM_RE.findall(patched)
        self.assertIn("<sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>", new_item)
        self.assertLess(new_item.index("minimumSystemVersion"), new_item.index("<enclosure"))
        self.assertIn("<sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>", old_item)

    def test_a_lower_floor_on_the_new_archive_fails(self) -> None:
        xml = appcast(item("107", "cmux-macos.dmg", "14.0"))
        with self.assertRaisesRegex(floor_tool.FloorError, "expected 26.0"):
            floor_tool.enforce(xml, "cmux-macos.dmg", "26.0")

    def test_equivalent_spellings_match(self) -> None:
        xml = appcast(item("107", "cmux-macos.dmg", "26"))
        self.assertEqual(floor_tool.enforce(xml, "cmux-macos.dmg", "26.0.0"), xml)

    def test_archive_named_only_by_a_delta_is_not_matched(self) -> None:
        xml = appcast(item("107", "other.dmg", "26.0", deltas=True))
        with self.assertRaisesRegex(floor_tool.FloorError, "no appcast item"):
            floor_tool.enforce(xml, "other.dmg-old.delta", "26.0")


class LegacyItemTests(unittest.TestCase):
    legacy = item("106", "cmux-macos.dmg", "14.0", deltas=True)

    def test_appends_the_last_legacy_build_below_the_floor(self) -> None:
        xml = appcast(item("107", "cmux-macos.dmg", "26.0"))
        patched = floor_tool.append_legacy(xml, self.legacy, "26.0")
        items = floor_tool.ITEM_RE.findall(patched)
        self.assertEqual(len(items), 2)
        self.assertIn("<sparkle:version>106</sparkle:version>", items[1])
        self.assertNotIn("sparkle:deltas", items[1])
        self.assertTrue(patched.rstrip().endswith("</rss>"))
        # Idempotent.
        self.assertEqual(floor_tool.append_legacy(patched, self.legacy, "26.0"), patched)

    def test_rejects_an_item_that_is_not_below_the_floor(self) -> None:
        with self.assertRaisesRegex(floor_tool.FloorError, "not below the floor"):
            floor_tool.append_legacy(appcast(), item("106", "x.dmg", "26.0"), "26.0")


class CommandLineTests(unittest.TestCase):
    def test_enforce_rewrites_the_file(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "appcast.xml"
            path.write_text(appcast(item("107", "cmux-macos.dmg", None)))
            result = subprocess.run(
                [sys.executable, str(SCRIPT), "enforce", str(path), "--archive", "cmux-macos.dmg", "--minimum", "26.0"],
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("<sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>", path.read_text())

    def test_floor_failure_exits_nonzero(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            app = make_app(Path(tmp), None)
            result = subprocess.run([sys.executable, str(SCRIPT), "floor", str(app)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn("LSMinimumSystemVersion", result.stderr)


if __name__ == "__main__":
    unittest.main()
