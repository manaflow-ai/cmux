import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
WRAPPER = ROOT / "cmux-tui/scripts/build-tui-musl.sh"


class MuslBuildTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="musl build ")
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        tools = root / "tools"
        tools.mkdir()
        self.sysroot = root / "rust sysroot"
        self.linker = self.sysroot / "lib/rustlib/test-host/bin/rust-lld"
        self.linker.parent.mkdir(parents=True)
        self.linker.write_text("#!/bin/sh\nexit 0\n")
        self.linker.chmod(0o755)
        rustc = tools / "rustc"
        rustc.write_text(
            '#!/bin/sh\ncase "$1" in\n'
            '  --print) printf "%s\\n" "$FAKE_SYSROOT" ;;\n'
            '  -vV) printf "host: test-host\\n" ;;\nesac\n'
        )
        rustc.chmod(0o755)
        cargo = tools / "cargo"
        cargo.write_text(
            "#!/usr/bin/env python3\nimport json, os, sys\n"
            "key = 'CARGO_TARGET_' + sys.argv[-1].replace('-', '_').upper() + '_LINKER'\n"
            "data = {name: os.environ.get(name) for name in "
            "[key, 'RUSTFLAGS', 'CARGO_ENCODED_RUSTFLAGS']}\n"
            "data['argv'] = sys.argv[1:]\n"
            "open(os.environ['CAPTURE_FILE'], 'w').write(json.dumps(data))\n"
        )
        cargo.chmod(0o755)
        self.capture = root / "capture.json"
        self.env = dict(os.environ)
        for name in ("RUSTC", "RUSTFLAGS", "CARGO_ENCODED_RUSTFLAGS"):
            self.env.pop(name, None)
        self.env.update(
            PATH=str(tools) + os.pathsep + self.env["PATH"],
            FAKE_SYSROOT=str(self.sysroot),
            CAPTURE_FILE=str(self.capture),
        )

    def run_wrapper(self, target):
        return subprocess.run(
            ["bash", str(WRAPPER), target, "-p", "example", "--release"],
            env=self.env, text=True, capture_output=True,
        )

    def test_both_linux_targets_use_rust_final_linker_and_keep_cargo_zigbuild(self):
        for target in ("x86_64-unknown-linux-musl", "aarch64-unknown-linux-musl"):
            with self.subTest(target=target):
                result = self.run_wrapper(target)
                self.assertEqual(result.returncode, 0, result.stderr)
                data = json.loads(self.capture.read_text())
                key = "CARGO_TARGET_" + target.replace("-", "_").upper() + "_LINKER"
                self.assertEqual(data[key], str(self.linker))
                self.assertEqual(data["argv"], ["zigbuild", "-p", "example", "--release", "--target", target])
                self.assertEqual(data["CARGO_ENCODED_RUSTFLAGS"].split("\x1f"), self.linker_flags())

    def linker_flags(self):
        return ["-Clinker-flavor=ld.lld", "-Clink-self-contained=yes", "-Clinker=" + str(self.linker)]

    def test_preserves_existing_rust_flags(self):
        self.env["RUSTFLAGS"] = " \t--cfg=existing\n -Clinker=old-zigcc  "
        self.assertEqual(self.run_wrapper("x86_64-unknown-linux-musl").returncode, 0)
        data = json.loads(self.capture.read_text())
        self.assertEqual(data["CARGO_ENCODED_RUSTFLAGS"].split("\x1f"), ["--cfg=existing", "-Clinker=old-zigcc"] + self.linker_flags())

    def test_preserves_encoded_rust_flags_including_empty_value(self):
        for original in ("", "--cfg=existing\x1f-Clinker=old-zigcc"):
            with self.subTest(original=original):
                self.env["CARGO_ENCODED_RUSTFLAGS"] = original
                self.assertEqual(self.run_wrapper("x86_64-unknown-linux-musl").returncode, 0)
                data = json.loads(self.capture.read_text())
                expected = (original.split("\x1f") if original else []) + self.linker_flags()
                self.assertEqual(data["CARGO_ENCODED_RUSTFLAGS"].split("\x1f"), expected)

    def test_honors_explicit_rustc_over_path_default(self):
        default = Path(self.env["PATH"].split(os.pathsep)[0]) / "rustc"
        selected = self.capture.parent / "selected rustc"
        selected.write_text(default.read_text())
        selected.chmod(0o755)
        default.write_text("#!/bin/sh\nexit 99\n")
        self.env["RUSTC"] = str(selected)
        result = self.run_wrapper("x86_64-unknown-linux-musl")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_unsupported_target_before_building(self):
        result = self.run_wrapper("aarch64-apple-darwin")
        self.assertEqual(result.returncode, 2)
        self.assertFalse(self.capture.exists())

    def test_missing_bundled_linker_fails_before_building(self):
        self.linker.unlink()
        result = self.run_wrapper("x86_64-unknown-linux-musl")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("bundled linker is unavailable", result.stderr)
        self.assertFalse(self.capture.exists())


if __name__ == "__main__":
    unittest.main()
