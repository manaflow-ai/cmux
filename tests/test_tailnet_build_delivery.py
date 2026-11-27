#!/usr/bin/env python3
"""Exercise build-script Go invocations without downloading or compiling Go."""
import importlib.util
import json
import re
import os
import shlex
from pathlib import Path
import subprocess
import tempfile
import unittest
# tests/git_fixture_env.py, loaded by path: `python3 -I` puts no script folder on sys.path.
import importlib.util as _git_fixture_importlib  # noqa: E402
from os import path as _git_fixture_path  # noqa: E402
_git_fixture_spec = _git_fixture_importlib.spec_from_file_location(
    "git_fixture_env", _git_fixture_path.join(_git_fixture_path.dirname(_git_fixture_path.abspath(__file__)), "git_fixture_env.py"))
git_fixture_env = _git_fixture_importlib.module_from_spec(_git_fixture_spec)
_git_fixture_spec.loader.exec_module(git_fixture_env)

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
                       TARGET=target, HOST=host, CAPTURE=str(capture),
                       CARGO_MANIFEST_DIR=str(CRATE))
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
    def flags(self, manifest, target, *dep):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "Cargo.toml"
            path.write_text(manifest)
            return subprocess.check_output([str(ROOT / "scripts/ci/acpmux-build-features.sh"),
                                            str(path), target, *dep], text=True).strip()

    def test_standalone_build_names_the_acpmux_dependency(self):
        # The macOS legs build acpmux-standalone, which turns the shipping features on through its
        # acpmux dependency; a bare `--features=tailnet` would name a feature it does not have.
        manifest = "[features]\ntailnet = []\nhub-carrier = []\n"
        self.assertEqual(self.flags(manifest, "aarch64-apple-darwin", "acpmux"),
                         "--features=acpmux/tailnet,acpmux/hub-carrier")
        self.assertEqual(self.flags(manifest, "x86_64-pc-windows-gnu", "acpmux"), "")
        self.assertEqual(self.flags(manifest, "aarch64-apple-darwin"), "--features=tailnet,hub-carrier")

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


class ShippedAcpmuxCarriesItsFeaturesTests(unittest.TestCase):
    """The Linux package's acpmux is acpmux-standalone (#42682), built with no features until this test: the published
    x86_64-unknown-linux-musl acpmux had no hub carrier at all (a Linux machine on c10f26a1a, 2026-11-15)."""
    STANDALONE = ROOT / "cmux-tui/crates/acpmux-standalone/Cargo.toml"
    WORKFLOW = ROOT / ".github/workflows/cmux-tui-build-package.yml"

    def flags(self, manifest, target):
        return subprocess.check_output([str(ROOT / "scripts/ci/acpmux-build-features.sh"), str(manifest), target],
                                       text=True).strip()

    def test_standalone_gets_the_hub_carrier_on_every_shipped_unix_target(self):
        for target in ["x86_64-unknown-linux-musl", "aarch64-unknown-linux-musl", "x86_64-unknown-linux-gnu"]:
            self.assertEqual(self.flags(self.STANDALONE, target), "--features=hub-carrier", target)
        self.assertEqual(self.flags(self.STANDALONE, "aarch64-apple-darwin"), "--features=tailnet,hub-carrier")

    def test_standalone_passes_each_feature_to_acpmux(self):
        import tomllib
        features = tomllib.loads(self.STANDALONE.read_text())["features"]
        acpmux = tomllib.loads((ROOT / "cmux-tui/crates/acpmux/Cargo.toml").read_text())["features"]
        for name in ["tailnet", "hub-carrier"]:
            self.assertIn(name, acpmux)
            self.assertEqual(features.get(name), [f"acpmux/{name}"], name)

    def test_every_shipped_unix_acpmux_build_passes_the_shipping_features(self):
        # The Mac-built macOS legs' cargo builds are in scripts/ci/cmux-tui-mac-cargo-builds.sh.
        count = 0
        for path in (self.WORKFLOW, ROOT / "scripts/ci/cmux-tui-mac-cargo-builds.sh"):
            lines = path.read_text().splitlines()
            builds = [(n, line) for n, line in enumerate(lines, 1)
                      if re.search(r"-p acpmux(-standalone)? --bin", line) and "windows" not in line]
            count += len(builds)
            for n, line in builds:
                text = line + (lines[n] if line.rstrip().endswith("\\") else "")
                # A build may consume the shared shell variable or resolve the same
                # feature flags inline.  Both paths execute the shipping-feature
                # helper; require the inline form to name the standalone manifest so
                # it cannot silently calculate flags for a different package.
                has_shipping_features = (
                    "acpmux_features" in text
                    or re.search(
                        r"acpmux-build-features\.sh\s+crates/acpmux-standalone/Cargo\.toml\s+\"\$t\"",
                        text,
                    )
                )
                self.assertTrue(has_shipping_features,
                                f"{path.name}:{n} builds acpmux without its shipping features")
        self.assertGreaterEqual(count, 3)
        self.assertIn("acpmux-build-features.sh crates/acpmux-standalone/Cargo.toml", self.WORKFLOW.read_text())

    def test_grouped_and_inline_builds_resolve_shipping_feature_arguments(self):
        # Execute the workflow's actual command construction, without running Cargo.
        # The combined thin-LTO command must qualify features by package; the separate
        # fat-LTO group can use the standalone package's unqualified features.
        lines = self.WORKFLOW.read_text().splitlines()
        assignments = [line.strip() for line in lines
                       if line.strip().startswith('acpmux_features=')
                       or (line.strip().startswith(('acpmux_group=(', 'lead+='))
                           and '-p acpmux-standalone' in line)]
        self.assertEqual(len(assignments), 3, "expected feature resolution and both build commands")
        script = '\n'.join([
            'set -euo pipefail', 't=$1', 'lead=""',
            'zb() { echo cargo zigbuild; }', *assignments,
            'printf "%s\\n" "${acpmux_group[1]}" "$lead"',
        ])
        for target in ["x86_64-unknown-linux-musl", "aarch64-unknown-linux-musl",
                       "x86_64-unknown-linux-gnu", "aarch64-apple-darwin", "x86_64-apple-darwin"]:
            with self.subTest(target=target):
                commands = subprocess.check_output(
                    ['bash', '-c', script, 'shipping-features', target],
                    cwd=ROOT / 'cmux-tui', text=True, timeout=10).splitlines()
                self.assertEqual(len(commands), 2)
                required = ['hub-carrier']
                if target.endswith('apple-darwin'):
                    required.insert(0, 'tailnet')
                for command, prefix in zip(commands, ['', 'acpmux-standalone/']):
                    args = shlex.split(command)
                    self.assertIn('--features=' + ','.join(prefix + name for name in required), args)

    def test_the_apps_acpmux_carries_the_hub_carrier(self):
        """The app's acpmux is the cmux binary (bin/acpmux aliases bin/cmux), which took acpmux with no features:
        a joined Mac on 64821ccc5 ran no hub carrier and logged nothing about it (2026-11-15)."""
        import tomllib
        manifest = tomllib.loads((ROOT / "cmux-tui/crates/cmux-tui/Cargo.toml").read_text())
        unix = manifest["target"]["cfg(unix)"]["dependencies"].get("acpmux", {})
        self.assertIn("hub-carrier", unix.get("features", []), "cmux-tui's unix acpmux lacks the hub carrier")

    def test_every_shipping_script_builds_acpmux_with_its_features(self):
        scripts = [*sorted((ROOT / "scripts/ci/nightly-steps").glob("*.sh")), ROOT / "scripts/ci/macos-cross.sh"]
        found = set()
        for path in scripts:
            lines = path.read_text().splitlines()
            for n, line in enumerate(lines, 1):
                if not re.search(r"-p acpmux --bin acpmux\b", line):
                    continue
                found.add(path.name)
                text = line + (lines[n] if line.rstrip().endswith("\\") and n < len(lines) else "")
                self.assertIn("acpmux-build-features.sh", text, f"{path.relative_to(ROOT)}:{n} builds acpmux without its features")
        # The fast nightly's acpmux, the one that once shipped without the carrier, is among those checked.
        self.assertIn("app-build-fast-cmux-tui.sh", found)


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
