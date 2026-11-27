#!/usr/bin/env python3
"""ui-build and test products=JOB of the simulator entrypoint, with tool doubles; no native build.

Build once, test on many hosts (Leo, 2026-11-27: "potentially the build/test dichotomy that xcode
sometimes have too"): `ui-build config=C` makes the UI tests' build-for-testing products and returns
them in evidence.zip; `test ui=... config=C products=JOB` runs them on another host. This checks the
routing (arguments, the one build-for-testing, the artifact's contents) on the Linux fleet:

    python3 scripts/ci/tests/test_ios_sim_ui_products.py
"""

import importlib.util
import json
import os
from pathlib import Path
import tarfile
import unittest
import zipfile

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("release_build", HERE / "test_ios_sim_release_build.py")
release_build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release_build)

# The release-build doubles, plus build-for-testing products (an .xctestrun beside the apps) and
# BSD stat's `-f %z` (the size of a file).
TOOL = release_build.TOOL.replace(
    'elif name == "xcodebuild":\n    if args == ["-version"]:',
    '''elif name == "stat":
    assert args[:2] == ["-f", "%z"], args
    print(pathlib.Path(args[2]).stat().st_size)
elif name == "xcodebuild" and args[:1] == ["build-for-testing"]:
    if int(os.environ.get("FIXTURE_BUILD_FAILURE", "0")):
        print("error: fixture compile failure")
        sys.exit(65)
    config = args[args.index("-configuration") + 1]
    products = pathlib.Path(args[args.index("-derivedDataPath") + 1]) / "Build/Products"
    for app in ["CmuxMobileApp.app", "CmuxMobileAppUITests-Runner.app"]:
        (products / (config + "-iphonesimulator") / app).mkdir(parents=True)
        (products / (config + "-iphonesimulator") / app / "exe").write_text("fixture")
    (products / ("CmuxMobileApp_CmuxMobileApp_iphonesimulator26.0-arm64.xctestrun")).write_text("<plist/>")
elif name == "xcodebuild":
    if args == ["-version"]:''',
)


class UIProductsTests(unittest.TestCase):
    run_script = release_build.ReleaseBuildTests.run_script
    calls = release_build.ReleaseBuildTests.calls

    def setUp(self):  # the release-build fixture, with the extended doubles
        release_build.ReleaseBuildTests.setUp(self)
        self.tool.write_text(TOOL)
        self.bash_env.write_text(self.bash_env.read_text() + 'stat() { fixture_tool stat "$@"; }\n')

    def builds(self):
        return [c for c in self.calls() if c[0] == "xcodebuild" and c[1:] != ["-version"]]

    def test_ui_build_builds_for_testing_once_and_returns_products(self):
        for config, configuration in [("demo", "Demo"), ("debug", "Debug")]:
            with self.subTest(config=config):
                trace = self.root / "calls.jsonl"
                if trace.exists():
                    trace.unlink()
                result = self.run_script("ui-build", f"config={config}")
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                builds = self.builds()
                self.assertEqual(len(builds), 1, builds)
                command = builds[0]
                self.assertEqual(command[1], "build-for-testing")
                self.assertEqual(command[command.index("-configuration") + 1], configuration)
                self.assertEqual(command[command.index("-destination") + 1], "generic/platform=iOS Simulator")
                self.assertIn("CMUX_MOBILE_APPLE_SIGN_IN=YES", command)
                demo = "SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DEBUG CMUX_MOBILE_DEMO"
                self.assertEqual(demo in command, configuration == "Demo")
                names = [c[0] for c in self.calls()]
                self.assertLess(names.index("ffi"), names.index("xcodegen"))
                self.assertNotIn("xcrun", names)  # no simulator, no runtime
                with zipfile.ZipFile(self.out / "evidence.zip") as archive:
                    self.assertIn("ui-products.tar.gz", archive.namelist())
                    info = json.loads(archive.read("ui-build.json"))
                    self.assertEqual(info["config"], configuration)
                    self.assertEqual(info["sha"], "a" * 40)
                    self.assertGreater(info["bytes"], 0)
                with tarfile.open(self.out / "ui-products.tar.gz") as tar:
                    members = tar.getnames()
                self.assertIn("Products/CmuxMobileApp_CmuxMobileApp_iphonesimulator26.0-arm64.xctestrun", members)
                self.assertIn(f"Products/{configuration}-iphonesimulator/CmuxMobileAppUITests-Runner.app/exe", members)

    def test_ui_build_failure_fails_without_products(self):
        result = self.run_script("ui-build", "config=demo", FIXTURE_BUILD_FAILURE="65")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertFalse((self.out / "ui-products.tar.gz").exists())
        self.assertIn("fixture compile failure", (self.out / "ui-build.log").read_text())

    def test_ui_build_refuses_other_arguments_before_any_work(self):
        for args in [(), ("config=release",), ("config=demo", "ui=X"), ("ui=X",), ("config=demo", "device=iPhone,16e")]:
            with self.subTest(args=args):
                result = self.run_script("ui-build", *args)
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertEqual(self.builds(), [])

    def test_products_refuses_what_would_build_here(self):
        job = "0" * 24
        cases = [
            (("ui=SomeUITests", f"products={job}"), "config="),
            (("ui=SomeUITests", "config=demo", f"products={job}", "only=CmuxMobileKitTests"), "without only="),
            (("ui=LaunchTTIColdUITests", "config=demo", f"products={job}"), "cold suites"),
            (("ui=SomeUITests", "config=demo", f"products={job}", "profile"), "profile"),
            (("ui=SomeUITests", "config=demo", f"products={job}", "duress=heavy"), "duress"),
            (("config=demo", f"products={job}"), "warm ui="),
            (("ui=SomeUITests", "config=demo", "products=xyz"), "24 hex"),
            (("ui=SomeUITests", "config=demo", f"products={job}"), "CMUX_CI_UI_PRODUCTS"),
        ]
        for args, message in cases:
            with self.subTest(args=args):
                result = self.run_script("test", *args)
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertIn(message, result.stderr)
                self.assertEqual(self.builds(), [])


if __name__ == "__main__":
    unittest.main()
