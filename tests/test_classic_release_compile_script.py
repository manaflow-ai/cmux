#!/usr/bin/env python3
"""Exercise the Classic compile entrypoint with no native tools or real setup."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/ci/classic-nightly-release-compile.sh"
STUB = r'''
import json, os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["CALL_LOG"], "a") as stream:
    stream.write(json.dumps({"tool": name, "args": args, "cwd": os.getcwd(),
        "skip": os.environ.get("CMUX_SKIP_ZIG_BUILD"),
        "sdk": os.environ.get("CMUX_CI_REQUIRED_MACOS_SDK_MAJOR"),
        "developer": os.environ.get("DEVELOPER_DIR")}) + "\n")
if os.environ.get("FAIL_TOOL") == name:
    sys.exit(int(os.environ.get("FAIL_STATUS", "42")))
if name == "select-ci-xcode.sh":
    pathlib.Path(os.environ["GITHUB_ENV"]).write_text(
        "DEVELOPER_DIR=/fixture/Xcode.app/Contents/Developer\nIGNORED=value\n")
elif name == "git":
    print("a" * 40)
elif name == "xcodebuild" and os.environ.get("NO_PRODUCT") != "1":
    derived = pathlib.Path(args[args.index("-derivedDataPath") + 1])
    (derived / "Build/Products/Release/cmux.app").mkdir(parents=True)
'''


class ClassicReleaseCompile(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="classic-compile-fixture-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "scripts/ci").mkdir(parents=True)
        (self.root / "bin").mkdir()
        (self.root / "home").mkdir()
        self.script = self.root / "scripts/ci" / SCRIPT.name
        shutil.copyfile(SCRIPT, self.script)
        self.log = self.root / "calls.jsonl"
        # Only basic filesystem commands plus stubs are reachable. No host
        # cargo, xcodebuild, setup scripts, credentials or repository are used.
        for name in ("bash", "dirname", "mkdir", "mktemp", "rm", "env"):
            (self.root / "bin" / name).symlink_to(shutil.which(name))
        for path in ("scripts/ci/init-submodule.sh", "scripts/select-ci-xcode.sh",
                     "scripts/install-rust-ci.sh", "scripts/download-prebuilt-ghosttykit.sh",
                     "bin/xcodebuild", "bin/git"):
            target = self.root / path
            target.write_text(f"#!{sys.executable}\n" + STUB)
            if path.endswith("init-submodule.sh"):
                # The entrypoint invokes this helper with bash explicitly.
                target.write_text(f"#!/bin/bash\nexec '{sys.executable}' '{self.root}/bin/submodule-stub' \"$@\"\n")
                (self.root / "bin/submodule-stub").write_text(STUB.replace(
                    'name = pathlib.Path(sys.argv[0]).name', 'name = "init-submodule.sh"'))
            target.chmod(0o755)
        wrapper = self.root / "scripts/ci/run-xcodebuild-with-diagnostics.sh"
        wrapper.write_text('#!/bin/bash\n[[ "$1" == -- ]] || exit 91\nshift\nexec "$@"\n')
        wrapper.chmod(0o755)
        self.env = {"PATH": str(self.root / "bin"), "HOME": str(self.root / "home"),
                    "CALL_LOG": str(self.log), "LC_ALL": "C"}
        # setup-python's shared-library interpreter needs its loader path even
        # when the fixture removes host tools, credentials and shell startup.
        for name in ("LD_LIBRARY_PATH", "DYLD_LIBRARY_PATH"):
            if name in os.environ:
                self.env[name] = os.environ[name]

    def run_script(self, *args, **env):
        return subprocess.run(["/bin/bash", str(self.script), *args],
                              cwd=self.root / "home", env={**self.env, **env},
                              text=True, capture_output=True, timeout=10)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def test_default_compile_matches_full_nightly(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls()
        self.assertEqual([c["tool"] for c in calls], ["init-submodule.sh", "init-submodule.sh",
            "select-ci-xcode.sh", "install-rust-ci.sh", "download-prebuilt-ghosttykit.sh", "git", "xcodebuild"])
        self.assertEqual([c["args"] for c in calls[:2]], [["ghostty"], ["vendor/bonsplit"]])
        build = calls[-1]
        self.assertEqual(build["args"], ["-scheme", "cmux", "-configuration", "Release",
            "-derivedDataPath", str(self.root / ".build/classic-nightly-release-compile-arm64"),
            "-destination", "generic/platform=macOS", "-clonedSourcePackagesDirPath",
            str(self.root / ".build/classic-nightly-spm"), "-packageCachePath",
            str(self.root / ".build/classic-nightly-spm/.package-cache"), "-showBuildTimingSummary",
            "ARCHS=arm64", "ONLY_ACTIVE_ARCH=NO", "COMPILATION_CACHE_ENABLE_CACHING=YES",
            "COMPILATION_CACHE_LIMIT_SIZE=3221225472", "COMPILER_INDEX_STORE_ENABLE=NO",
            "CODE_SIGNING_ALLOWED=NO", "ASSETCATALOG_COMPILER_APPICON_NAME=AppIcon-Nightly", "build"])
        self.assertEqual((build["skip"], build["sdk"], build["developer"], build["cwd"]),
                         ("1", "26", "/fixture/Xcode.app/Contents/Developer", str(self.root)))
        self.assertEqual(list((self.root / ".build").glob("xcode-env.*")), [])

    def test_explicit_arch_and_paths_with_spaces(self):
        result = self.run_script("--archs", "x86_64", "derived data", CMUX_CI_REQUIRED_MACOS_SDK_MAJOR="27",
                                 CMUX_WORKLOAD_STATE_ROOT=str(self.root / "custom state"))
        self.assertEqual(result.returncode, 0, result.stderr)
        build = self.calls()[-1]
        self.assertIn("ARCHS=x86_64", build["args"])
        self.assertIn("derived data", build["args"])
        self.assertIn(str(self.root / "custom state/classic-nightly-spm"), build["args"])
        self.assertEqual(build["sdk"], "27")

    def test_explicit_arm64_default_derived_path(self):
        result = self.run_script("--archs", "arm64")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("ARCHS=arm64", self.calls()[-1]["args"])

    def test_invalid_arch_stops_before_setup(self):
        for args in (("--archs",), ("--archs", "universal"), ("--archs", "")):
            with self.subTest(args=args):
                result = self.run_script(*args)
                self.assertEqual(result.returncode, 2)
                self.assertIn("--archs takes arm64 or x86_64", result.stderr)
                self.assertEqual(self.calls(), [])

    def test_existing_submodules_are_not_initialized(self):
        for path in ("ghostty", "vendor/bonsplit"):
            directory = self.root / path
            directory.mkdir(parents=True)
            (directory / ".git").write_text("fixture")
        result = self.run_script("custom-derived")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("init-submodule.sh", [c["tool"] for c in self.calls()])

    def test_setup_failures_are_not_compile_verdicts(self):
        for tool in ("init-submodule.sh", "select-ci-xcode.sh", "install-rust-ci.sh",
                     "download-prebuilt-ghosttykit.sh"):
            with self.subTest(tool=tool):
                self.log.write_text("")
                result = self.run_script(FAIL_TOOL=tool)
                self.assertEqual(result.returncode, 75, result.stderr)
                self.assertIn("not judging the change", result.stderr)
                self.assertEqual(self.calls()[-1]["tool"], tool)
                self.assertNotIn("xcodebuild", [c["tool"] for c in self.calls()])

    def test_compile_failure_keeps_its_status(self):
        result = self.run_script(FAIL_TOOL="xcodebuild", FAIL_STATUS="65")
        self.assertEqual(result.returncode, 65, result.stderr)
        self.assertNotIn("not judging", result.stderr)

    def test_success_requires_app_product(self):
        result = self.run_script(NO_PRODUCT="1")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(self.calls()[-1]["tool"], "xcodebuild")


if __name__ == "__main__":
    unittest.main()
