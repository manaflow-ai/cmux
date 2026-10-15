#!/usr/bin/env python3
"""build_names.py: the restore journey finds a DEV build's control socket, daemon session and
acpmux home by the app's own rule (schemas/build-identity/vectors.json), also for a capture
slot's clone, whose bundle id (`<id>.capslot<N>`) does not end in the tag it ships."""

import importlib.util
import json
import os
import plistlib
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("build_names", HERE.parent / "build_names.py")
assert SPEC and SPEC.loader
build_names = importlib.util.module_from_spec(SPEC)
sys.modules["build_names"] = build_names
SPEC.loader.exec_module(build_names)

VECTORS = json.loads((HERE.parents[2] / "schemas" / "build-identity" / "vectors.json").read_text())


class BuildNamesTests(unittest.TestCase):
    def test_every_dev_vector(self):
        home = VECTORS["user_home"]
        cases = [c for c in VECTORS["cases"] if c["kind"] == "dev" and c.get("app_daemon")]
        self.assertGreater(len(cases), 5)
        for case in cases:
            with self.subTest(case["name"]):
                got = build_names.names(case["bundle_id"], case["bundled_tag"], home)
                self.assertEqual(got["socket"], case["app_daemon"]["control_socket"])
                self.assertEqual(got["session"], case["app_daemon"]["session"])
                self.assertEqual(got["acpmux_home"], case["acpmux_home"])

    def test_a_capture_slot_clone_gets_names_of_its_key(self):
        # Seen live: `cmux DEV rjar.app` cloned into slot 2 listens on /tmp/cmux-debug--7c2fab35.sock.
        with tempfile.TemporaryDirectory() as root:
            app = os.path.join(root, "cmux DEV rjar.app")
            os.makedirs(os.path.join(app, "Contents"))
            with open(os.path.join(app, "Contents", "Info.plist"), "wb") as f:
                plistlib.dump({"CFBundleIdentifier": "com.cmuxterm.app.debug.rjar.capslot2",
                               "LSEnvironment": {"CMUX_TAG": "rjar"}}, f)
            got = build_names.of_app(app, user_home="/Users/cmux")
        self.assertEqual(got["socket"], "/tmp/cmux-debug--7c2fab35.sock")
        self.assertEqual(got["session"], "cmux-app--7c2fab35")
        self.assertEqual(got["acpmux_home"], "/Users/cmux/.acpmux/builds/com.cmuxterm.app.debug.rjar.capslot2--rjar")

    def test_the_real_socket_is_in_the_state_folder_before_its_tmp_link(self):
        tmp = "/tmp/cmux-debug--7c2fab35.sock"
        self.assertEqual(build_names.socket_paths(tmp, "/Users/cmux"),
                         ["/Users/cmux/.local/state/cmux/cmux-debug--7c2fab35.sock", tmp])
        # A state path past sun_path keeps the socket at its /tmp name.
        self.assertEqual(build_names.socket_paths(tmp, "/Users/" + "x" * 90), [tmp])


if __name__ == "__main__":
    unittest.main()
