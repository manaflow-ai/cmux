#!/usr/bin/env python3
"""reload.sh's cmux-next free-space floor comes from one declared file.

A cmux-next tour needs CMUX_NEXT_MIN_FREE_GIB free on the home volume (40 GiB,
about 4x a cold build's peak). The runners that take tours had their own
floor of 30 GiB, so a runner with 27-39 GiB free took a tour that then failed
reload.sh's check. The tour's need now lives in
scripts/cmux-next/tour-requirements.json, which reload.sh reads for its
default, so runner config elsewhere can read the same number instead of
copying it. The file holds only the number.

This runs reload.sh's floor block against a fake df and a temporary
requirements file: the default comes from the file, the environment variable
still overrides it, and a missing or malformed file stops the build.
"""

import json
import os
import re
import subprocess
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RELOAD = os.path.join(ROOT, "scripts", "reload.sh")
REQUIREMENTS = os.path.join(ROOT, "scripts", "cmux-next", "tour-requirements.json")
BLOCK_START = re.compile(r"^cmux_next_requirements=", re.M)
BLOCK_END = "  export CMUX_ALLOW_LOW_SPACE_BUILD=1\nfi\n"


def floor_block() -> str:
    with open(RELOAD, encoding="utf-8") as f:
        text = f.read()
    start = BLOCK_START.search(text)
    if start is None:
        raise AssertionError("reload.sh does not read its floor from cmux_next_requirements")
    end = text.find(BLOCK_END, start.start())
    if end < 0:
        raise AssertionError("reload.sh floor block has no end")
    return text[start.start():end + len(BLOCK_END)]


class TourRequirementsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.script_dir = os.path.join(self.tmp.name, "scripts")
        os.makedirs(os.path.join(self.script_dir, "cmux-next"))
        self.bin = os.path.join(self.tmp.name, "bin")
        os.makedirs(self.bin)
        df = os.path.join(self.bin, "df")
        with open(df, "w") as f:
            # 20 GiB free, in 1K blocks, the way `df -Pk` prints it.
            f.write("#!/bin/sh\necho 'Filesystem 1024-blocks Used Available Capacity Mounted'\n"
                    "echo '/dev/disk1 100000000 0 20971520 0% /'\n")
        os.chmod(df, 0o755)

    def write_requirements(self, text):
        with open(os.path.join(self.script_dir, "cmux-next", "tour-requirements.json"), "w") as f:
            f.write(text)

    def run_block(self, env_floor=None):
        env = {k: v for k, v in os.environ.items()
               if k not in ("CMUX_NEXT_MIN_FREE_GIB", "CMUX_ALLOW_LOW_SPACE_BUILD")}
        env["PATH"] = self.bin + os.pathsep + env.get("PATH", "")
        env["HOME"] = self.tmp.name
        if env_floor is not None:
            env["CMUX_NEXT_MIN_FREE_GIB"] = env_floor
        script = f'set -euo pipefail\nSCRIPT_DIR="{self.script_dir}"\n{floor_block()}'
        return subprocess.run(["bash", "-c", script], env=env, capture_output=True, text=True, timeout=30)

    def test_the_file_holds_only_the_tour_floor(self):
        with open(REQUIREMENTS, encoding="utf-8") as f:
            data = json.load(f)
        self.assertEqual(set(data), {"min_free_gib"})
        self.assertIsInstance(data["min_free_gib"], int)
        self.assertGreater(data["min_free_gib"], 0)

    def test_the_default_floor_comes_from_the_file(self):
        self.write_requirements('{"min_free_gib": 21}\n')
        result = self.run_block()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("needs 21 GiB free", result.stderr)

        self.write_requirements('{"min_free_gib": 19}\n')
        result = self.run_block()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("20 GiB free >= 19 GiB", result.stdout)

    def test_the_environment_still_overrides_the_file(self):
        self.write_requirements('{"min_free_gib": 21}\n')
        result = self.run_block(env_floor="19")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(">= 19 GiB", result.stdout)

    def test_a_missing_or_malformed_file_stops_the_build(self):
        for text in (None, "{", '{"min_free_gib": "40"}', '{"min_free_gib": 0}', "{}"):
            with self.subTest(text=text):
                path = os.path.join(self.script_dir, "cmux-next", "tour-requirements.json")
                if os.path.exists(path):
                    os.remove(path)
                if text is not None:
                    self.write_requirements(text)
                result = self.run_block()
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn("tour-requirements.json", result.stderr)

    def test_the_real_file_sets_the_real_default(self):
        with open(REQUIREMENTS, encoding="utf-8") as f:
            text = f.read()
        self.write_requirements(text)
        floor = json.loads(text)["min_free_gib"]
        result = self.run_block()
        self.assertIn(f"needs {floor} GiB free" if floor > 20 else f">= {floor} GiB",
                      result.stderr + result.stdout)


if __name__ == "__main__":
    unittest.main()
