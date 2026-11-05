#!/usr/bin/env python3
"""Exercise build-script Go invocations without downloading or compiling Go."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
CRATE = ROOT / "cmux-tui/crates/cmux-tailnet"


class TailnetArchiveTargetTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.scratch = tempfile.TemporaryDirectory(prefix="tailnet-build-test-")
        cls.root = Path(cls.scratch.name)
        cls.executable = cls.root / "build-script"
        subprocess.run(["rustc", "--edition=2024", str(CRATE / "build.rs"),
                        "-o", str(cls.executable)], check=True,
                       env={**os.environ, "CARGO_MANIFEST_DIR": str(CRATE)})
        cls.fake_bin = cls.root / "bin"
        cls.fake_bin.mkdir()
        (cls.fake_bin / "git").write_text("#!/bin/sh\nexit 0\n")
        (cls.fake_bin / "go").write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
pathlib.Path(os.environ["CAPTURE"]).write_text(json.dumps(dict(os.environ)))
pathlib.Path(sys.argv[sys.argv.index("-o") + 1]).touch()
''')
        for binary in cls.fake_bin.iterdir():
            binary.chmod(0o755)

    @classmethod
    def tearDownClass(cls):
        cls.scratch.cleanup()

    def invocation(self, target, host, **overrides):
        with tempfile.TemporaryDirectory(dir=self.root) as tmp:
            root = Path(tmp)
            source = root / "source"
            source.mkdir()
            output = root / "out"
            output.mkdir()
            capture = root / "capture.json"
            env = {key: value for key, value in os.environ.items()
                   if not key.startswith(("GO", "CC", "CGO", "LIBTAILSCALE", "TARGET", "HOST"))}
            env.update(PATH=f"{self.fake_bin}:{env['PATH']}", CARGO_CFG_UNIX="",
                       OUT_DIR=str(output), LIBTAILSCALE_SRC=str(source),
                       CARGO_CFG_TARGET_ARCH=target.split("-")[0],
                       CARGO_CFG_TARGET_OS="macos" if "apple" in target else "linux",
                       TARGET=target, HOST=host, CAPTURE=str(capture))
            env.update(overrides)
            result = subprocess.run([str(self.executable)], env=env,
                                    capture_output=True, text=True)
            return result, json.loads(capture.read_text()) if capture.exists() else None

    def test_native_mac_cross_architecture_uses_darwin_and_clang(self):
        result, env = self.invocation("x86_64-apple-darwin", "aarch64-apple-darwin",
                                      CGO_CFLAGS="-DKEEP=1", MACOSX_DEPLOYMENT_TARGET="14.5")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((env["GOOS"], env["GOARCH"], env["CC"]), ("darwin", "amd64", "clang"))
        self.assertIn("-DKEEP=1", env["CGO_CFLAGS"])
        self.assertIn("-arch x86_64", env["CGO_CFLAGS"])
        self.assertIn("-mmacosx-version-min=14.5", env["CGO_LDFLAGS"])

    def test_cross_host_uses_target_wrapper_instead_of_host_compiler(self):
        result, env = self.invocation("aarch64-apple-darwin", "x86_64-unknown-linux-gnu",
                                      CC_aarch64_apple_darwin="/sdk/bin/cc-darwin", CC="host-cc",
                                      GOOS="linux", GOARCH="amd64", SDKROOT="/sdk/sysroot")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((env["GOOS"], env["GOARCH"], env["CC"]),
                         ("darwin", "arm64", "/sdk/bin/cc-darwin"))
        self.assertEqual(env["SDKROOT"], "/sdk/sysroot")

    def test_cross_host_without_compiler_fails_before_go_runs(self):
        result, env = self.invocation("aarch64-apple-darwin", "x86_64-unknown-linux-gnu")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("requires CC_aarch64_apple_darwin", result.stderr)
        self.assertIsNone(env)

    def test_native_linux_ignores_inherited_go_target(self):
        result, env = self.invocation("x86_64-unknown-linux-gnu", "x86_64-unknown-linux-gnu",
                                      GOOS="darwin", GOARCH="arm64")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((env["GOOS"], env["GOARCH"]), ("linux", "amd64"))


class ShippingFeatureTests(unittest.TestCase):
    def flags(self, manifest, target):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "Cargo.toml"
            path.write_text(manifest)
            return subprocess.check_output([str(ROOT / "scripts/ci/acpmux-build-features.sh"),
                                            str(path), target], text=True).strip()

    def test_mac_ships_tailnet_when_supported(self):
        for target in ["aarch64-apple-darwin", "x86_64-apple-darwin"]:
            self.assertEqual(self.flags("[features]\ntailnet = []\n", target), "--features=tailnet")

    def test_pinned_old_tree_has_no_unknown_feature(self):
        self.assertEqual(self.flags("[features]\nother = []\n", "aarch64-apple-darwin"), "")

    def test_other_platforms_preserve_feature_defaults(self):
        for target in ["x86_64-unknown-linux-musl", "x86_64-pc-windows-gnu"]:
            self.assertEqual(self.flags("[features]\ntailnet = []\n", target), "")

    def test_dependency_name_does_not_enable_feature(self):
        self.assertEqual(self.flags("[dependencies]\ntailnet = {}\n", "aarch64-apple-darwin"), "")


class TreeKeyTests(unittest.TestCase):
    def test_shipping_helpers_change_published_artifact_key(self):
        spec = importlib.util.spec_from_file_location("tree_key", ROOT / "scripts/ci/cmux_tui_tree_key.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            module.ROOT = root
            module.INPUTS = ROOT / "scripts/cmux-next/cmux-tui-tree-inputs.txt"
            def git(*args):
                return subprocess.check_output(["git", "-C", str(root), *args], text=True).strip()
            git("init", "-q")
            git("config", "user.name", "test")
            git("config", "user.email", "test@example.com")
            git("config", "core.hooksPath", "/dev/null")
            # Absent optional blobs are permitted; required trees/gitlinks exist.
            for line in module.INPUTS.read_text().splitlines():
                if line.startswith("tree "):
                    path = root / line.split(maxsplit=1)[1]
                    path.mkdir(parents=True, exist_ok=True)
                    (path / "fixture").touch()
            path = root / "scripts/cmux-next/build-layout-reducer-ffi.sh"
            path.parent.mkdir(parents=True, exist_ok=True)
            path.touch()
            git("add", "."); git("commit", "-qm", "initial")
            commit = git("rev-parse", "HEAD")
            for name in ["ghostty", "ghostty-next"]:
                git("update-index", "--add", "--cacheinfo", f"160000,{commit},{name}")
            git("commit", "-qm", "gitlinks")
            previous = module.tree_key("HEAD")
            for name in ["acpmux-build-features.sh", "tailnet-go.sh"]:
                path = root / "scripts/ci" / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("changed build input\n")
                git("add", str(path.relative_to(root))); git("commit", "-qm", name)
                changed = module.tree_key("HEAD")
                self.assertNotEqual(previous, changed, name)
                previous = changed


if __name__ == "__main__":
    unittest.main()
