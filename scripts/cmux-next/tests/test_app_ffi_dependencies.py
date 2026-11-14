"""The pin and router follow library dependencies, never test-only crates."""
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "scripts/ci"))
import app_ffi_pin
import cmux_next_route


class LibraryDependencies(unittest.TestCase):
    def test_normal_build_target_and_workspace_dependencies_only(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            crates = root / "cmux-tui/crates"
            crates.mkdir(parents=True)
            (root / "cmux-tui/Cargo.toml").write_text(
                '[workspace.dependencies]\nshared = { path = "crates/shared" }\n'
            )
            manifests = {
                "cmux-app-ffi": '''[dependencies]
client = { path = "../client" }
[build-dependencies]
builder = { path = "../builder" }
[target.'cfg(unix)'.dependencies]
unix = { path = "../unix" }
[target.'cfg(unix)'.build-dependencies]
generator = { path = "../generator" }
[dev-dependencies]
test-only = { path = "../test-only" }
[target.'cfg(unix)'.dev-dependencies]
target-test-only = { path = "../target-test-only" }
''',
                "client": '''[dependencies.shared]
workspace = true
[dependencies.test-only]
path = "../test-only"
[dev-dependencies]
book = { path = "../book" }
''',
                "builder": "", "unix": "", "generator": "", "shared": "",
                "test-only": "", "target-test-only": "", "book": "",
            }
            for name, manifest in manifests.items():
                (crates / name).mkdir()
                (crates / name / "Cargo.toml").write_text(manifest)
            expected = {f"cmux-tui/crates/{name}" for name in
                        ("cmux-app-ffi", "client", "builder", "unix", "generator", "shared", "test-only")}
            self.assertEqual(set(app_ffi_pin.library_crates(root)), expected)
            # Both callers use the same dependency graph. A crate that is also
            # a normal dependency stays included even if another edge is dev-only.
            routed = {p.rstrip("/") for p in cmux_next_route._app_ffi_inputs(root)
                      if p.rstrip("/") in {f"cmux-tui/crates/{n}" for n in manifests}}
            self.assertEqual(routed, expected)
            result = subprocess.run(
                ["bash", str(ROOT / "scripts/cmux-next/check-app-ffi-pin.sh"),
                 "--tree", str(root), "--list-inputs"],
                capture_output=True, text=True, check=True,
            )
            self.assertEqual(set(result.stdout.splitlines()), expected | {
                "cmux-tui/rust-toolchain.toml", "scripts/cmux-next/build-app-ffi.sh"})


if __name__ == "__main__":
    unittest.main()
