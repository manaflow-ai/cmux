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
        (self.script.parent / "lib").mkdir()
        shutil.copyfile(SCRIPT.parent / "lib/ios-sim-reduce-motion.sh", self.script.parent / "lib/ios-sim-reduce-motion.sh")
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

    def fake_runtime_helper(self):
        """The runtime helper records its arguments and refuses device=nope as the real one would."""
        (self.script.parent / "ios_sim_runtime.py").write_text(
            "import json, os, sys\n"
            "json.load(sys.stdin)\n"
            "open(os.path.join(os.environ['FIXTURE_ROOT'], 'helper-argv.json'), 'w').write(json.dumps(sys.argv[1:]))\n"
            "if os.environ.get('FIXTURE_HELPER_STOP'):\n"
            "    raise SystemExit('fixture: stop at the simulator choice')\n"
            "if 'nope' in sys.argv:\n"
            "    raise SystemExit('cmux-next-ios-sim.sh: device=nope: this runtime has no such device type; "
            "available iPhone types: iPhone 16e, iPhone 17')\n"
            "print('fixture-runtime fixture-device', 'Fixture Phone (2nd generation)')\n"
        )
        # listperf and energy check that the head has the list rig before anything else.
        for rel in ("cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileShell/ListStressRig.swift",
                    "cmux-next-ios/verify/feedperf/summarize.py"):
            (self.root / rel).parent.mkdir(parents=True, exist_ok=True)
            (self.root / rel).write_text("# fixture\n")
        return self.root / "helper-argv.json"

    def test_device_and_reducemotion_are_taken_out_for_every_simulator_mode(self):
        argv = self.fake_runtime_helper()
        for args in [("build", "device=iPhone,16e"), ("test", "only=A/B", "reducemotion=1", "device=iPhone 16e"),
                     ("shots", "device=iPhone-SE-(3rd-generation)", "settings=-cmux-mobile-tab,settings"),
                     ("listperf", "reps=1", "device=iPhone,17,Pro,Max"), ("energy", "device=iPhone,16e", "seconds=10")]:
            with self.subTest(args=args):
                # Each mode's own parsing accepted what was left (it refuses with exit 2 before the
                # helper runs), so the step reached the simulator choice with the device named.
                result = self.run_script(*args, FIXTURE_HELPER_STOP="1")
                self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
                self.assertIn("fixture: stop at the simulator choice", result.stderr)
                device = next(a for a in args if a.startswith("device="))[len("device="):]
                self.assertEqual(json.loads(argv.read_text()), ["--with-name", "--device", device])

    def test_the_log_names_the_chosen_device(self):
        self.fake_runtime_helper()
        result = self.run_script("build", "device=iPhone,16e", FIXTURE_BUILD_FAILURE="65")
        self.assertIn("simulator device type: Fixture Phone (2nd generation) (fixture-device), from device=iPhone,16e",
                      result.stdout)

    def test_no_device_keeps_the_default_choice(self):
        argv = self.fake_runtime_helper()
        self.run_script("build", FIXTURE_HELPER_STOP="1")
        self.assertEqual(json.loads(argv.read_text()), ["--with-name"])

    def test_unknown_device_exits_3_with_the_list_before_the_build(self):
        self.fake_runtime_helper()
        result = self.run_script("shots", "device=nope", "settings=-cmux-mobile-tab,settings")
        self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
        self.assertIn("available iPhone types: iPhone 16e, iPhone 17", result.stderr)
        self.assertFalse(any(c[0] == "xcodebuild" and c[1:] != ["-version"] for c in self.calls()))

    def test_bad_simulator_options_are_refused_before_any_work(self):
        for args, message in [(("release-build", "device=iPhone,16e"), "boots no simulator"),
                              (("shots", "reducemotion=0", "a=b"), "only reducemotion=1"),
                              (("build", "device=iPhone,16e", "device=iPhone,17"), "device= given twice"),
                              (("build", "device=iPhone;rm"), "device= wants")]:
            with self.subTest(args=args):
                result = self.run_script(*args)
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertIn(message, result.stderr)


FAKE_XCRUN = r"""#!/usr/bin/env bash
# simctl [--set SET] spawn UDID defaults write|read ... / notifyutil: records the call, answers the read.
printf '%s\n' "$*" >>"$FIXTURE_CALLS"
case "$*" in
  *"defaults read com.apple.Accessibility ReduceMotionEnabled") printf '%s\n' "$FIXTURE_READ_BACK" ;;
esac
"""


class ReduceMotionTests(unittest.TestCase):
    """reducemotion=1: the simulator write and read-back, and the app's own launch line, each fail with exit 3."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ios-sim-reduce-motion-test-")
        self.addCleanup(self.temp.cleanup)
        self.dir = Path(self.temp.name)
        (self.dir / "xcrun").write_text(FAKE_XCRUN)
        (self.dir / "xcrun").chmod(0o755)
        self.calls = self.dir / "calls"
        self.lib = SCRIPT.parent / "lib/ios-sim-reduce-motion.sh"

    def bash(self, body, read_back="1"):
        env = {**os.environ, "PATH": f"{self.dir}:{os.environ['PATH']}", "FIXTURE_CALLS": str(self.calls),
               "FIXTURE_READ_BACK": read_back}
        return subprocess.run(["bash", "-c", f"set -euo pipefail; source {shlex.quote(str(self.lib))}; {body}"],
                              env=env, capture_output=True, text=True, timeout=30)

    def test_write_then_read_back_inside_the_simulator(self):
        p = self.bash('v="$(sim_reduce_motion UDID1 /sims)"; echo "value=$v"')
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("value=1", p.stdout)
        calls = self.calls.read_text().splitlines()
        self.assertEqual(calls[0], "simctl --set /sims spawn UDID1 defaults write com.apple.Accessibility ReduceMotionEnabled -bool true")
        self.assertEqual(calls[-1], "simctl --set /sims spawn UDID1 defaults read com.apple.Accessibility ReduceMotionEnabled")

    def test_a_read_back_other_than_1_fails(self):
        for read_back in ("0", "", "The domain/default pair does not exist"):
            with self.subTest(read_back=read_back):
                p = self.bash('v="$(sim_reduce_motion UDID1)" || { echo "failed with $v"; exit 3; }', read_back)
                self.assertEqual(p.returncode, 3, p.stdout + p.stderr)

    def test_the_app_must_report_true(self):
        for log, verdict, status in (
            ("... [dev.cmux.mobile:accessibility] launch: isReduceMotionEnabled=true", "true", 0),
            ("... [dev.cmux.mobile:accessibility] launch: isReduceMotionEnabled=false", "false", 3),
            ("", "not logged", 3),
        ):
            with self.subTest(verdict=verdict):
                p = self.bash(f'v="$(reduce_motion_app_verdict {shlex.quote(log)})" || {{ echo "v=$v"; exit 3; }}; echo "v=$v"')
                self.assertEqual(p.returncode, status, p.stdout + p.stderr)
                self.assertIn("v=" + verdict, p.stdout)

    def test_step_turns_it_on_before_install_and_fails_with_3(self):
        text = SCRIPT.read_text()
        launch = text.index('simctl install "$udid" "$app"')
        write = text.index('rm_value="$(sim_reduce_motion "$udid" "$sims")" || {')
        check = text.index('a11y_seen="$(reduce_motion_app_verdict "$a11y_log")" || a11y_ok=0')
        self.assertLess(write, launch)
        self.assertGreater(check, launch)
        self.assertIn("exit 3", text[write:launch])
        self.assertIn('if [[ $reduce_motion -eq 1 && $a11y_ok -eq 0 ]]; then', text[check:check + 400])
        self.assertIn("exit 3", text[check:check + 400])


if __name__ == "__main__":
    unittest.main()
