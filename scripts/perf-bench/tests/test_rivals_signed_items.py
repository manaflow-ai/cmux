#!/usr/bin/env python3
"""rivals.py's RFD 0131 rows on a fake bundle tree (no Mac needed): `signed-items` counts every Mach-O file and every
sealed bundle once (symlinks such as a framework's Versions/Current are not followed, a Java class file is not
Mach-O), the quarantine value has a browser download's shape, Zed is in the app list as a native app, and the
report shows the new rows.
Run: python3 -I scripts/perf-bench/tests/test_rivals_signed_items.py"""
import io, json, os, re, sys, tempfile, unittest
from contextlib import redirect_stdout

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
import rivals  # noqa: E402  (procs is imported lazily inside rivals, so this loads on Linux)

THIN64 = b"\xcf\xfa\xed\xfe" + b"\x07\x00\x00\x01" + b"\0" * 24
FAT2 = b"\xca\xfe\xba\xbe" + (2).to_bytes(4, "big") + b"\0" * 24
JAVA = b"\xca\xfe\xba\xbe" + b"\x00\x00\x00\x34" + b"\0" * 24  # class file version 52


def put(root, rel, data=b"text"):
    path = os.path.join(root, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as handle:
        handle.write(data)


def fake_app(root):
    """Fake.app: main executable (fat), a framework with Versions/A and the Current symlinks, a helper app,
    an XPC service, a loose dylib, a Java class, plain resources."""
    app = os.path.join(root, "Fake.app")
    put(app, "Contents/Info.plist")
    put(app, "Contents/MacOS/Fake", FAT2)
    put(app, "Contents/_CodeSignature/CodeResources")
    fw = "Contents/Frameworks/Fake Framework.framework"
    put(app, fw + "/Versions/A/Fake Framework", THIN64)
    put(app, fw + "/Versions/A/_CodeSignature/CodeResources")
    put(app, fw + "/Versions/A/Libraries/libgl.dylib", THIN64)
    put(app, fw + "/Versions/A/Resources/en.lproj/strings.pak")
    os.symlink("A", os.path.join(app, fw, "Versions/Current"))
    os.symlink("Versions/Current/Fake Framework", os.path.join(app, fw, "Fake Framework"))
    os.symlink("Versions/Current/Resources", os.path.join(app, fw, "Resources"))
    put(app, "Contents/Frameworks/Fake Helper (GPU).app/Contents/MacOS/Fake Helper (GPU)", THIN64)
    put(app, "Contents/Frameworks/Fake Helper (GPU).app/Contents/_CodeSignature/CodeResources")
    put(app, "Contents/XPCServices/updater.xpc/Contents/MacOS/updater", THIN64)
    put(app, "Contents/XPCServices/updater.xpc/Contents/_CodeSignature/CodeResources")
    put(app, "Contents/Frameworks/libloose.dylib", THIN64)
    put(app, "Contents/Resources/Thing.class", JAVA)
    put(app, "Contents/Resources/app.asar", b"\x04\x00\x00\x00" + b"\0" * 28)
    put(app, "Contents/Resources/empty")
    open(os.path.join(app, "Contents/Resources/empty"), "wb").close()
    return app


class SignedItems(unittest.TestCase):
    def test_counts_each_macho_and_sealed_bundle_once(self):
        with tempfile.TemporaryDirectory() as root:
            got = rivals.signed_items(fake_app(root))
        # Mach-O: Fake, Fake Framework, libgl.dylib, Fake Helper (GPU), updater, libloose.dylib.
        self.assertEqual(got["machos"], 6)
        # Sealed: Fake.app, Fake Framework.framework (once, not again via Versions/Current), the helper app, the xpc.
        self.assertEqual(got["kinds"], {"app": 2, "framework": 1, "xpc": 1})
        self.assertEqual(got["bundles"], 4)
        self.assertEqual(got["count"], 10)

    def test_version_folder_with_a_dot_still_names_the_framework(self):
        with tempfile.TemporaryDirectory() as root:
            app = os.path.join(root, "V.app")
            put(app, "Contents/_CodeSignature/CodeResources")
            put(app, "Contents/Frameworks/Lib.framework/Versions/C.1/_CodeSignature/CodeResources")
            put(app, "Contents/Frameworks/Lib.framework/Versions/C.1/Lib", THIN64)
            got = rivals.signed_items(app)
        self.assertEqual(got["kinds"], {"app": 1, "framework": 1})
        self.assertEqual(got["count"], 3)

    def test_java_class_and_short_files_are_not_macho(self):
        with tempfile.TemporaryDirectory() as root:
            put(root, "a.class", JAVA)
            put(root, "short", b"\xca\xfe")
            put(root, "fat", FAT2)
            put(root, "thin", THIN64)
            self.assertFalse(rivals.is_macho(os.path.join(root, "a.class")))
            self.assertFalse(rivals.is_macho(os.path.join(root, "short")))
            self.assertTrue(rivals.is_macho(os.path.join(root, "fat")))
            self.assertTrue(rivals.is_macho(os.path.join(root, "thin")))
            self.assertFalse(rivals.is_macho(os.path.join(root, "missing")))


class Quarantine(unittest.TestCase):
    def test_value_has_a_browser_downloads_shape(self):
        value = rivals.quarantine_value(now=0x6566F2A1)
        self.assertRegex(value, r"^0083;6566f2a1;Safari;[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$")


class AppList(unittest.TestCase):
    def test_zed_is_a_native_rival(self):
        self.assertIn("zed", rivals.ORDER)
        self.assertEqual(rivals.LABELS["zed"], "Zed")
        self.assertIn("zed", rivals.NATIVE)
        self.assertNotIn("zed", rivals.CHROMIUM | rivals.ELECTRON | rivals.SYSTEM)

    def test_rows_have_units(self):
        for row in ("signed-items", "quarantined-window", "quarantined-cpu", "quarantined-memory-peak"):
            self.assertIn(row, rivals.UNITS)


class Report(unittest.TestCase):
    def test_report_shows_signed_items_and_the_quarantined_row(self):
        with tempfile.TemporaryDirectory() as out:
            meta = {"machine": {}, "args": {}, "purge": False,
                    "apps": {"cmux": {"name": "cmux NEXT"}, "zed": {"name": "Zed"}}}
            with open(os.path.join(out, "meta.json"), "w") as handle:
                json.dump(meta, handle)
            samples = [
                {"browser": "cmux", "round": 1, "row": "signed-items", "value": 240},
                {"browser": "zed", "round": 1, "row": "signed-items", "value": 3},
                {"browser": "zed", "round": 1, "row": "quarantined-window", "value": 1520.0},
                {"browser": "cmux", "round": 1, "row": "quarantined-window", "value": None,
                 "note": "no window within 60 s: the first-open prompt waits for a click (needs a fleet Mac that approves it)"},
            ]
            with open(os.path.join(out, "samples.jsonl"), "w") as handle:
                handle.write("\n".join(json.dumps(s) for s in samples) + "\n")
            buffer = io.StringIO()
            with redirect_stdout(buffer):
                rivals.report(out, None, os.path.join(out, "results.json"))
            text = buffer.getvalue()
            with open(os.path.join(out, "results.json")) as handle:
                rows = json.load(handle)["rows"]
        self.assertRegex(text, r"\| Signed code items in the bundle .*\(n\) \| 240 \| 3 \(cmux 80\.0x more\) \|")
        self.assertRegex(text, r"\| First launch of a quarantined download.*\(ms\) \| – \| 1,520 \|")
        self.assertIn("cmux NEXT quarantined-window: no window within 60 s", text)
        self.assertEqual(rows["signed-items"]["zed"]["median"], 3)
        self.assertTrue(re.search(r"\| Row \| cmux NEXT \| Zed \|", text))


if __name__ == "__main__":
    unittest.main()
