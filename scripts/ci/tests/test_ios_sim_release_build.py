#!/usr/bin/env python3
"""Exercise the simulator entrypoint with tool doubles; no native build or launch.

Run on the Linux fleet: python3 scripts/ci/tests/test_ios_sim_release_build.py
Set CMUX_IOS_SIM_SCRIPT to a saved base script to demonstrate the missing route.
The copied entrypoint is unchanged. Only its external tools and FFI dependency
are replaced in a disposable fixture. This tests routing, not Swift compilation.
"""

import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile


ROOT = Path(__file__).resolve().parents[3]
SCRIPT = Path(os.environ.get("CMUX_IOS_SIM_SCRIPT", ROOT / "scripts/ci/cmux-next-ios-sim.sh")).resolve()

TOOL = r'''
import json, os, pathlib, sys, zipfile
name, *args = sys.argv[1:]
root = pathlib.Path(os.environ["FIXTURE_ROOT"])
with (root / "calls.jsonl").open("a") as f:
    f.write(json.dumps([name, *args]) + "\n")
if name == "curl":
    pathlib.Path(args[args.index("-o") + 1]).write_text("fixture download")
elif name == "shasum":
    print(os.environ["FIXTURE_XCODEGEN_SHA"] + "  archive")
elif name == "unzip":
    target = pathlib.Path(args[args.index("-d") + 1]) / "xcodegen/bin/xcodegen"
    target.parent.mkdir(parents=True)
    target.write_text("#!/usr/bin/env bash\nfixture_tool xcodegen \"$@\"\n")
    target.chmod(0o755)
elif name == "git":
    assert args == ["rev-parse", "HEAD"], args
    print("a" * 40)
elif name == "hostname":
    print("fixture")
elif name == "sysctl":
    print("8")
elif name == "sw_vers":
    print("26.0")
elif name == "xcodegen":
    assert args == ["generate", "-q"], args
    print("fixture project generated")
    sys.exit(int(os.environ.get("FIXTURE_XCODEGEN_FAILURE", "0")))
elif name == "ffi":
    print("fixture FFI built")
    sys.exit(int(os.environ.get("FIXTURE_FFI_FAILURE", "0")))
elif name == "xcodebuild":
    if args == ["-version"]:
        print("Xcode fixture")
    else:
        failure = int(os.environ.get("FIXTURE_BUILD_FAILURE", "0"))
        if failure:
            print("error: fixture compile failure\n** BUILD FAILED **")
            sys.exit(failure)
        config = args[args.index("-configuration") + 1]
        dd = pathlib.Path(args[args.index("-derivedDataPath") + 1])
        app = dd / "Build/Products" / (config + "-iphonesimulator") / "CmuxMobileApp.app"
        app.mkdir(parents=True)
        (app / "CmuxMobileApp").write_text("fixture executable")
        print("** BUILD SUCCEEDED **")
elif name == "ditto":
    app, archive = map(pathlib.Path, args[-2:])
    with zipfile.ZipFile(archive, "w") as z:
        for path in app.rglob("*"):
            if path.is_file():
                z.write(path, path.relative_to(app.parent))
elif name == "zip":
    assert args == ["-qr", "evidence.zip", ".", "-x", "evidence.zip"], args
    with zipfile.ZipFile("evidence.zip", "w") as z:
        for path in pathlib.Path(".").rglob("*"):
            if path.is_file() and path.name != "evidence.zip":
                z.write(path, path)
elif name == "xcrun":
    # Legacy modes must still select their runtime before building. Every other
    # simctl invocation is a test failure, especially in compile-only mode.
    if args == ["simctl", "list", "-j", "runtimes", "devicetypes"]:
        print("{}")
    else:
        raise SystemExit("unexpected simulator operation: " + repr(args))
else:
    raise SystemExit("unexpected tool: " + name)
'''

CACHE_TOOL = r'''
import json, os, pathlib, sys
root = pathlib.Path(os.environ["FIXTURE_ROOT"])
name, *args = sys.argv[1:]
with (root / "calls.jsonl").open("a") as f:
    f.write(json.dumps(["cache", name, *args]) + "\n")
if name == "key":
    pathlib.Path(args[1]).write_text("{}\n")
    print("b" * 64)
elif name == "restore":
    if os.environ.get("FIXTURE_CACHE_MODE") != "hit":
        raise SystemExit(1)
    app = pathlib.Path(args[0]) / "cmux-next-ios/CmuxMobileKit"
    (app / "Frameworks/CmuxMobileLinkFFI.xcframework").mkdir(parents=True)
    (app / "Frameworks/CmuxMobileLinkFFI.xcframework/Info.plist").write_text("fixture")
    (app / "Sources/CmuxMobileLinkFFI").mkdir(parents=True)
    (app / "Sources/CmuxMobileLinkFFI/CmuxMobileLinkFFI.swift").write_text("fixture")
elif name == "probe":
    pathlib.Path(args[1]).write_text("{}\n")
elif name == "store":
    pass
else:
    raise SystemExit("unexpected cache operation: " + name)
'''


class ReleaseBuildTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ios-release-route-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.script = self.root / "scripts/ci/cmux-next-ios-sim.sh"
        self.script.parent.mkdir(parents=True)
        shutil.copyfile(SCRIPT, self.script)
        guard = self.root / "scripts/cmux-next/lib/fleet-only.sh"
        guard.parent.mkdir(parents=True)
        guard.write_text("cmux_next_require_fleet() { :; }\n")
        ffi = self.root / "cmux-next-ios/rust/scripts/build-xcframework.sh"
        ffi.parent.mkdir(parents=True)
        ffi.write_text("fixture_tool ffi\n")
        cache = self.root / "scripts/ci/ios_ffi_cache.py"
        cache.parent.mkdir(parents=True, exist_ok=True)
        cache.write_text(CACHE_TOOL)
        (self.script.parent / "ios_sim_runtime.py").write_text(
            "import json, sys\njson.load(sys.stdin)\nprint('fixture-runtime fixture-device')\n"
        )
        self.developer = self.root / "developer"
        self.developer.mkdir()
        self.tool = self.root / "tool.py"
        self.tool.write_text(TOOL)
        self.bash_env = self.root / "bash-env.sh"
        self.bash_env.write_text(
            "fixture_tool() { "
            + shlex.quote(sys.executable)
            + " "
            + shlex.quote(str(self.tool))
            + ' "$@"; }\n'
            + "".join(
                f'{name}() {{ fixture_tool {name} "$@"; }}\n'
                for name in (
                    "curl", "shasum", "unzip", "git", "hostname", "sysctl",
                    "sw_vers", "xcodegen", "xcodebuild", "ditto", "zip", "xcrun",
                )
            )
        )
        self.env = {
            **os.environ,
            "BASH_ENV": str(self.bash_env),
            "FIXTURE_ROOT": str(self.root),
            "FIXTURE_XCODEGEN_SHA": re.search(
                r"^xcodegen_sha256=(\w+)$", SCRIPT.read_text(), re.MULTILINE
            ).group(1),
            "DEVELOPER_DIR": str(self.developer),
            "TMPDIR": str(self.root),
            "CMUX_CI_CACHE_DIR": str(self.root / "cache"),
            "FIXTURE_CACHE_MODE": "miss",
        }
        self.out = self.root / "artifacts/ios-sim"

    def run_script(self, *args, **env):
        return subprocess.run(
            ["bash", str(self.script), *args], cwd=self.root,
            env={**self.env, **env}, capture_output=True, text=True, timeout=30,
        )

    def calls(self):
        path = self.root / "calls.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def build_call(self):
        builds = [c for c in self.calls() if c[0] == "xcodebuild" and c[1:] != ["-version"]]
        self.assertEqual(len(builds), 1, self.calls())
        return builds[0]

    def assert_evidence(self, result, expected_status, logs):
        self.assertEqual(result.returncode, expected_status, result.stdout + result.stderr)
        with zipfile.ZipFile(self.out / "evidence.zip") as archive:
            self.assertIn("SUMMARY.md", archive.namelist())
            self.assertIn(f"- exit status: {expected_status}", archive.read("SUMMARY.md").decode())
            for log in logs:
                self.assertIn(log, archive.namelist())
                self.assertTrue(archive.read(log))

    def test_release_build_is_unsigned_compile_only_with_evidence(self):
        result = self.run_script("release-build")
        self.assert_evidence(result, 0, ["ffi.log", "xcodegen.log", "build.log"])
        command = self.build_call()
        self.assertEqual(command[command.index("-project") + 1], "cmux-next-ios/CmuxMobileApp.xcodeproj")
        self.assertEqual(command[command.index("-configuration") + 1], "Release")
        self.assertEqual(command[command.index("-destination") + 1], "generic/platform=iOS Simulator")
        self.assertEqual(command[-1], "build")
        self.assertIn("CODE_SIGNING_ALLOWED=NO", command)
        self.assertIn("CODE_SIGNING_REQUIRED=NO", command)
        self.assertFalse(any("DEBUG" in arg or "DEMO" in arg for arg in command))
        self.assertFalse(any(arg.startswith("SWIFT_ACTIVE_COMPILATION_CONDITIONS=") for arg in command))
        self.assertEqual(shlex.split((self.out / "build-command.txt").read_text()), command)
        names = [c[0] for c in self.calls()]
        self.assertLess(names.index("ffi"), names.index("xcodegen"))
        self.assertNotIn("xcrun", names)
        with zipfile.ZipFile(self.out / "evidence.zip") as archive:
            self.assertIn("CmuxMobileApp-Release-simulator.app.zip", archive.namelist())
        self.assertFalse((self.root / ".build/ios-sim/sims").exists())
        self.assertEqual(list(self.root.glob("cmux-next-ios-sim-xcodegen.*")), [])

    def test_release_build_cache_hit_skips_ffi_rebuild(self):
        result = self.run_script("release-build", FIXTURE_CACHE_MODE="hit")
        self.assert_evidence(result, 0, ["xcodegen.log", "build.log"])
        self.assertFalse(any(c[0] == "ffi" for c in self.calls()))
        cache_calls = [c for c in self.calls() if c[0] == "cache"]
        self.assertEqual([c[1] for c in cache_calls[:2]], ["key", "restore"])
        self.assertEqual(cache_calls[1][3], "b" * 64)
        self.assertIn("- FFI: ", (self.out / "SUMMARY.md").read_text())

    def test_release_build_cache_miss_rebuilds_and_probes(self):
        result = self.run_script("release-build", FIXTURE_CACHE_MODE="miss")
        self.assert_evidence(result, 0, ["ffi.log", "xcodegen.log", "build.log"])
        self.assertTrue(any(c[0] == "ffi" for c in self.calls()))
        cache_ops = [c[1] for c in self.calls() if c[0] == "cache"]
        self.assertEqual(cache_ops[:4], ["key", "restore", "probe", "store"])

    def test_release_rejects_extra_arguments_before_any_work(self):
        result = self.run_script("release-build", "ui=SomeSuite")
        self.assertEqual(result.returncode, 2)
        self.assertIn("takes no further arguments", result.stderr)
        self.assertEqual(self.calls(), [])

    def test_compile_failure_retains_evidence_and_fails(self):
        result = self.run_script("release-build", FIXTURE_BUILD_FAILURE="65")
        self.assert_evidence(result, 1, ["ffi.log", "xcodegen.log", "build.log"])
        self.assertIn("fixture compile failure", (self.out / "build.log").read_text())
        self.assertNotIn("xcrun", [c[0] for c in self.calls()])
        self.assertFalse((self.out / "CmuxMobileApp-Release-simulator.app.zip").exists())

    def test_ffi_failure_keeps_evidence_without_starting_app_build(self):
        result = self.run_script("release-build", FIXTURE_FFI_FAILURE="7")
        self.assert_evidence(result, 1, ["ffi.log"])
        self.assertNotIn("xcodegen", [c[0] for c in self.calls()])
        self.assertFalse(any(c[-1] == "build" for c in self.calls()))

    def test_project_generation_failure_keeps_evidence(self):
        result = self.run_script("release-build", FIXTURE_XCODEGEN_FAILURE="7")
        self.assert_evidence(result, 1, ["ffi.log", "xcodegen.log"])
        self.assertFalse(any(c[-1] == "build" for c in self.calls()))

    def test_existing_modes_still_build_demo(self):
        for args in [(), ("build",), ("test",), ("bench",), ("all",),
                     ("pair-e2e",), ("shots", "settings=-cmux-mobile-tab,settings")]:
            with self.subTest(args=args):
                trace = self.root / "calls.jsonl"
                if trace.exists():
                    trace.unlink()
                # Stop deliberately at the build, before the legacy launch path.
                result = self.run_script(*args, FIXTURE_BUILD_FAILURE="65")
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                command = self.build_call()
                self.assertEqual(command[command.index("-configuration") + 1], "Demo")
                self.assertIn("SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DEBUG CMUX_MOBILE_DEMO", command)
                self.assertNotIn("CODE_SIGNING_ALLOWED=NO", command)
                self.assertIn(["xcrun", "simctl", "list", "-j", "runtimes", "devicetypes"], self.calls())


if __name__ == "__main__":
    unittest.main()
