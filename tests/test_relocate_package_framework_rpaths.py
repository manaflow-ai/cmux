#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
import unittest.mock

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/ci/relocate_package_framework_rpaths.py"
SPEC = importlib.util.spec_from_file_location("relocate", SCRIPT)
relocate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(relocate)

PRODUCER = "/tmp/cmux-ci-2/derived-data-compile-admission/Build/Products/Debug/PackageFrameworks"


class StaleRpaths(unittest.TestCase):
    def test_producer_roots_are_stale_for_another_products_directory(self):
        own = "/Users/cmux/_work/_temp/dd-shard-1-layers/Build/Products/Debug/PackageFrameworks"
        entries = [
            "/usr/lib/swift",
            PRODUCER,
            "/private/tmp/cmux-ci/derived-data-compile-admission/Build/Products/Debug/PackageFrameworks",
            "/tmp/cmux-ci-12/derived-data-compile-admission/Build/Products/Debug/PackageFrameworks/",
            "@executable_path/../Frameworks",
            "/private/tmp/cmux-app-host-package-frameworks",
        ]
        self.assertEqual(relocate.stale_rpaths(entries, own), sorted(entries[1:4]))

    def test_a_product_restored_where_it_was_compiled_keeps_its_rpath(self):
        own = "/private/tmp/cmux-ci/derived-data-compile-admission/Build/Products/Debug/PackageFrameworks"
        entries = ["/tmp/cmux-ci/derived-data-compile-admission/Build/Products/Debug/PackageFrameworks"]
        with unittest.mock.patch.object(relocate.os.path, "realpath", lambda p: p.replace("/private/tmp", "/tmp")):
            self.assertEqual(relocate.stale_rpaths(entries, own), [])

    def test_other_absolute_paths_are_left_alone(self):
        entries = ["/tmp/cmux-ci-x/derived-data-compile-admission/Build/Products/Debug/PackageFrameworks",
                   "/tmp/cmux-ci/derived-data/Build/Products/Debug/PackageFrameworks"]
        self.assertEqual(relocate.stale_rpaths(entries, "/elsewhere/PackageFrameworks"), [])


class Layout(unittest.TestCase):
    def test_only_a_frameworks_real_version_is_loadable(self):
        fw = Path("/p/PackageFrameworks/X_PackageProduct.framework")
        self.assertTrue(relocate.loadable(fw / "Versions/A/X_PackageProduct"))
        self.assertFalse(relocate.loadable(fw / "X_PackageProduct"))
        self.assertFalse(relocate.loadable(fw / "Versions/Current/X_PackageProduct"))
        self.assertTrue(relocate.loadable(Path("/p/cmux DEV.app/Contents/Resources/bin/cmux")))

    def test_signing_target_is_the_bundle_for_its_main_executable(self):
        with tempfile.TemporaryDirectory() as work:
            app = Path(work) / "cmux DEV.app"
            (app / "Contents/MacOS").mkdir(parents=True)
            (app / "Contents/Info.plist").write_bytes(
                b'<?xml version="1.0"?><plist version="1.0"><dict>'
                b"<key>CFBundleExecutable</key><string>cmux DEV</string></dict></plist>")
            self.assertEqual(relocate.signing_target(app / "Contents/MacOS/cmux DEV"), app)
            self.assertEqual(relocate.signing_target(app / "Contents/MacOS/cmux DEV.debug.dylib"),
                             app / "Contents/MacOS/cmux DEV.debug.dylib")
            fw = Path(work) / "X.framework/Versions/A/X"
            self.assertEqual(relocate.signing_target(fw), fw.parent)


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("clang") and shutil.which("codesign"),
                     "needs clang, install_name_tool and codesign")
class RoundTrip(unittest.TestCase):
    def test_relative_rpath_fits_where_a_long_absolute_one_does_not(self):
        with tempfile.TemporaryDirectory(prefix="relocate-rpaths-") as work:
            # A deep, long products directory like a runner's _work/_temp one.
            products = Path(work) / ("runner-temp-" + "x" * 90) / "Build/Products/Debug"
            nested = products / "cmux DEV.app/Contents/Resources/bin"
            nested.mkdir(parents=True)
            source = Path(work) / "main.c"
            source.write_text("int main(void) { return 0; }\n")
            binary = nested / "cmux"
            subprocess.run(["clang", str(source), "-o", str(binary), "-Wl,-rpath," + PRODUCER], check=True)
            subprocess.run([sys.executable, str(SCRIPT), str(products)], check=True, capture_output=True)
            self.assertEqual(relocate.rpaths(binary), ["@loader_path/../../../../PackageFrameworks"])
            subprocess.run([str(binary)], check=True)

    def test_both_producer_spellings_leave_one_rpath(self):
        with tempfile.TemporaryDirectory(prefix="relocate-rpaths-") as work:
            products = Path(work) / "Build/Products/Debug"
            products.mkdir(parents=True)
            source = Path(work) / "main.c"
            source.write_text("int main(void) { return 0; }\n")
            binary = products / "tool"
            subprocess.run(["clang", str(source), "-o", str(binary), "-Wl,-rpath," + PRODUCER,
                            "-Wl,-rpath,/private" + PRODUCER], check=True)
            subprocess.run([sys.executable, str(SCRIPT), str(products)], check=True, capture_output=True)
            self.assertEqual(relocate.rpaths(binary), ["@loader_path/PackageFrameworks"])
            subprocess.run(["codesign", "--verify", "--strict", str(binary)], check=True)

    def test_relocates_signs_and_is_idempotent(self):
        with tempfile.TemporaryDirectory(prefix="relocate-rpaths-") as work:
            products = Path(work) / "Build/Products/Debug"
            (products / "PackageFrameworks").mkdir(parents=True)
            source = Path(work) / "main.c"
            source.write_text("int main(void) { return 0; }\n")
            binary = products / "tool"
            subprocess.run(["clang", str(source), "-o", str(binary), "-Wl,-rpath," + PRODUCER,
                            "-Wl,-rpath,@executable_path/../Frameworks"], check=True)
            subprocess.run(["codesign", "-f", "-s", "-", str(binary)], check=True, capture_output=True)
            copy = products / "PackageFrameworks/X.framework/X"
            copy.parent.mkdir(parents=True)
            shutil.copy2(binary, copy)

            first = subprocess.run([sys.executable, str(SCRIPT), str(products)], check=True,
                                   capture_output=True, text=True)
            self.assertIn("pointed 1 Mach-O file(s)", first.stdout)
            self.assertEqual(relocate.rpaths(binary),
                             ["@loader_path/PackageFrameworks", "@executable_path/../Frameworks"])
            self.assertEqual(relocate.rpaths(copy)[0], PRODUCER)
            subprocess.run(["codesign", "--verify", "--strict", str(binary)], check=True)
            subprocess.run([str(binary)], check=True)

            second = subprocess.run([sys.executable, str(SCRIPT), str(products)], check=True,
                                    capture_output=True, text=True)
            self.assertIn("nothing to rewrite", second.stdout)


if __name__ == "__main__":
    unittest.main()
