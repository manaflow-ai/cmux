import importlib.util
import os
import tempfile
import unittest
from pathlib import Path


BUILD_PATH = Path(__file__).parents[1] / "apple" / "build.py"
SPEC = importlib.util.spec_from_file_location("cmux_v3_apple_build", BUILD_PATH)
BUILD = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(BUILD)


class AppleFrameworkLayoutTests(unittest.TestCase):
    def test_framework_uses_versioned_macos_layout(self):
        with tempfile.TemporaryDirectory() as directory:
            stage = Path(directory)
            library = stage / "libcmux_v3_ffi.dylib"
            header = stage / "CmuxV3NativeFFI.h"
            library.write_bytes(b"binary")
            header.write_text("#pragma once\n")

            framework = BUILD.create_framework(stage, "macos-arm64_x86_64", library, header)
            version = framework / "Versions" / "A"

            self.assertTrue((version / "CmuxV3NativeFFI").is_file())
            self.assertTrue((version / "Headers" / "CmuxV3NativeFFI.h").is_file())
            self.assertTrue((version / "Modules" / "module.modulemap").is_file())
            self.assertTrue((version / "Resources" / "Info.plist").is_file())
            self.assertTrue(os.path.samefile(framework / "Info.plist", version / "Resources" / "Info.plist"))
            self.assertTrue(os.path.samefile(framework / "CmuxV3NativeFFI", version / "CmuxV3NativeFFI"))


if __name__ == "__main__":
    unittest.main()
