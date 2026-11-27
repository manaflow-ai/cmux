#!/usr/bin/env python3
"""install-zig-ci.sh installs only a Zig version that the license review
recorded: the shipped one (toolchains.json zig ci_version, whose LICENSE the app
and packages ship) or the Zig SDK conformance version
(cmux-tui/bindings/zig/build.zig.zon). Any other version stops the job before it
downloads anything."""

from __future__ import annotations

import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import os
from pathlib import Path
import re
import subprocess
import tempfile
import threading
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/install-zig-ci.sh"
TOOLCHAINS = ROOT / "cmux-tui/build-support/notices/toolchains/toolchains.json"


def fake_zig(directory: Path, version: str) -> None:
    lib = directory / "lib"
    (lib / "std").mkdir(parents=True)
    (lib / "std/std.zig").write_text("// fixture\n")
    zig = directory / "zig"
    zig.write_text(
        "#!/bin/sh\n"
        f'if [ "$1" = version ]; then echo {version}; exit 0; fi\n'
        f'if [ "$1" = env ]; then echo \'{{"lib_dir": "{lib}"}}\'; exit 0; fi\n'
        "exit 1\n"
    )
    zig.chmod(0o755)


# Zig versions whose std install-zig-ci.sh patches (the reused Zig must be the patched one).
STD_PATCHED = {"0.17.0"}
UNREACHABLE = "http://127.0.0.1:9/unreachable"


def run(version: str, fake: str | None = None, fleet_tree: str | None = None) -> subprocess.CompletedProcess[str]:
    with tempfile.TemporaryDirectory() as raw:
        tmp = Path(raw)
        fake_zig(tmp / "fake", fake or version)
        # The fleet's prebaked trees (<fleet>/tools/zig-<version>): none unless the case makes one, so a fleet
        # Mac's real tree cannot answer for the fixture.
        fleet_tools = tmp / "fleet-tools"
        fleet_tools.mkdir()
        if fleet_tree is not None:
            fake_zig(fleet_tools / f"zig-{version}", fleet_tree)
        # Only the fixture's Zig is a reuse candidate: a persistent runner keeps a patched Zig in /usr/local/bin
        # (guards run 44762407859, tooling-tests: 0.17.0 was reused and the run exited 0).
        # The runner's installer options and persistent caches must not answer for the fixture.
        # Clear the whole option namespace, including options added after this test. Both R2 defaults
        # are explicitly off: under GITHUB_ACTIONS they otherwise bypass the unreachable mirrors.
        env = {key: value for key, value in os.environ.items() if not key.startswith("ZIG_")}
        env.update({"ZIG_REQUIRED": version, "PATH": f"{tmp / 'fake'}:{os.environ['PATH']}",
               "ZIG_INDEX_URL": UNREACHABLE, "ZIG_MIRROR_URL": UNREACHABLE, "ZIG_SECONDARY_MIRROR_URL": UNREACHABLE,
               "ZIG_TERTIARY_MIRROR_URL": UNREACHABLE, "ZIG_OFFICIAL_URL": UNREACHABLE,
               "ZIG_REUSE_CANDIDATES": "", "ZIG_DOWNLOAD_ATTEMPTS": "1", "ZIG_DOWNLOAD_RETRY_DELAY": "0", "ZIG_FORCE_LOCAL_INSTALL": "0",
               "ZIG_FLEET_TOOLS_DIR": str(fleet_tools), "ZIG_TREE_R2_URL": "", "ZIG_TARBALL_R2_URL": "",
               "RUNNER_TEMP": str(tmp / "runner"), "GITHUB_PATH": "", "GITHUB_ENV": ""})
        result = subprocess.run(["bash", str(SCRIPT)], cwd=ROOT, env=env, capture_output=True, text=True, timeout=60)
        if fleet_tree is not None:
            # The fleet's tree is never edited (a clone takes the std fix).
            assert (fleet_tools / f"zig-{version}/lib/std/std.zig").read_text() == "// fixture\n"
            assert not (fleet_tools / f"zig-{version}/lib/std/Io").exists()
        return result


class ReviewedZigVersionTest(unittest.TestCase):
    def test_runner_tarball_bucket_cannot_answer_for_the_fixture(self) -> None:
        requests = []

        class Bucket(BaseHTTPRequestHandler):
            def do_GET(self):
                requests.append(self.path)
                self.send_error(404)

            do_HEAD = do_GET

            def log_message(self, *args):
                pass

        with ThreadingHTTPServer(("127.0.0.1", 0), Bucket) as server:
            worker = threading.Thread(target=server.serve_forever)
            worker.start()
            try:
                url = f"http://127.0.0.1:{server.server_port}"
                with mock.patch.dict(os.environ, {"GITHUB_ACTIONS": "true", "ZIG_TARBALL_R2_URL": url}):
                    result = run("0.17.0")
            finally:
                server.shutdown()
                worker.join()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(requests, [], "the fixture read the runner's tarball bucket")

    def test_runner_installer_options_cannot_change_the_fixture(self) -> None:
        with mock.patch.dict(os.environ, {"ZIG_PRINT_TREE_KEY": "1", "ZIG_PUBLISH_ENV": "RUNNER_ZIG"}):
            result = run("0.17.0")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("lacks the reviewed std/Io/Threaded.zig", result.stderr)
        self.assertIn(UNREACHABLE, result.stderr)

    def test_the_reviewed_ci_versions_are_accepted(self) -> None:
        versions = [zig["ci_version"] for zig in json.loads(TOOLCHAINS.read_text())["zig"]]
        self.assertIn("0.17.0", versions)
        for version in versions:
            with self.subTest(version=version):
                result = run(version)
                if version in STD_PATCHED:
                    # Reviewed (no refusal), but the fake Zig has no patched std, so it
                    # is not reused: the run goes on to download a verified copy.
                    self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertNotIn("not a reviewed Zig version", result.stderr)
                    self.assertIn("lacks the reviewed std/Io/Threaded.zig", result.stderr)
                    self.assertIn(UNREACHABLE, result.stderr)
                else:
                    self.assertEqual(result.returncode, 0, result.stderr)

    def test_the_sdk_conformance_version_is_accepted(self) -> None:
        zon = (ROOT / "cmux-tui/bindings/zig/build.zig.zon").read_text()
        version = re.search(r'\.minimum_zig_version\s*=\s*"([^"]+)"', zon).group(1)
        result = run(version)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_another_version_stops_before_download(self) -> None:
        result = run("0.16.1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("toolchains.json", result.stderr)
        self.assertIn("0.16.1", result.stderr)


class FleetPrebakedZigTest(unittest.TestCase):
    """The build-fleet worker keeps <fleet>/tools/zig-<version> on every owned Mac; the installer takes it
    instead of downloading, and downloads (saying so) only when it is missing."""

    def test_a_fleet_tree_whose_std_needs_no_fix_is_used_without_download(self) -> None:
        version = re.search(r'\.minimum_zig_version\s*=\s*"([^"]+)"',
                            (ROOT / "cmux-tui/bindings/zig/build.zig.zon").read_text()).group(1)
        self.assertNotIn(version, STD_PATCHED)
        # The PATH zig is the wrong version, so only the fleet tree can serve.
        result = run(version, fake="0.0.1", fleet_tree=version)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("using the fleet-prebaked tree", result.stdout)
        self.assertNotIn(UNREACHABLE, result.stderr)

    def test_a_fleet_tree_that_needs_the_std_fix_is_cloned_not_downloaded(self) -> None:
        # The fixture tree has no Threaded.zig to fix, so the fix stops the run, on the clone, before any download.
        result = run("0.17.0", fake="0.0.1", fleet_tree="0.17.0")
        self.assertIn("cloned the fleet-prebaked tree", result.stdout)
        self.assertNotIn(UNREACHABLE, result.stderr)
        self.assertNotIn("Installing verified zig", result.stdout)

    def test_no_fleet_tree_downloads_and_says_so(self) -> None:
        version = re.search(r'\.minimum_zig_version\s*=\s*"([^"]+)"',
                            (ROOT / "cmux-tui/bindings/zig/build.zig.zon").read_text()).group(1)
        result = run(version, fake="0.0.1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(f"no fleet-prebaked zig {version}", result.stderr)
        self.assertIn(UNREACHABLE, result.stderr)

    def test_a_fleet_tree_of_another_version_is_not_used(self) -> None:
        version = re.search(r'\.minimum_zig_version\s*=\s*"([^"]+)"',
                            (ROOT / "cmux-tui/bindings/zig/build.zig.zon").read_text()).group(1)
        result = run(version, fake="0.0.1", fleet_tree="0.0.2")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("is not a complete zig", result.stderr)
        self.assertIn(UNREACHABLE, result.stderr)


if __name__ == "__main__":
    unittest.main()
