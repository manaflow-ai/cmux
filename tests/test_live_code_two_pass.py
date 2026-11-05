#!/usr/bin/env python3
"""scripts/live-code/lib/two-pass.sh: live_code_check against a fake dyld_info, a bind name it cut short included."""
import os
import stat
import subprocess
import tempfile
import unittest

ROOT = os.path.realpath(os.path.join(os.path.dirname(__file__), ".."))
LIB = os.path.join(ROOT, "scripts", "live-code", "lib", "two-pass.sh")
CUT = 4096 - len("<this-image>/") - 1

# A Swift initializer with many labeled arguments: its name is longer than dyld_info prints.
LONG = "_$s16CmuxNextSettings0A14ConfigSnapshotV4root" + "7density" * 600 + "tcfC"
SHORT = "_$s11CmuxNextApp4mainyyF"


def check(exports, binds, symbols=()):
    with tempfile.TemporaryDirectory() as tmp:
        bin_dir, out = os.path.join(tmp, "bin"), os.path.join(tmp, "out")
        os.makedirs(bin_dir)
        os.makedirs(out)
        with open(os.path.join(tmp, "exports"), "w") as f:
            f.writelines(f"0x00001000  {name}\n" for name in exports)
        with open(os.path.join(tmp, "fixups"), "w") as f:
            # dyld_info writes "<this-image>/NAME" into 4096 bytes.
            f.writelines(f"        __DATA  __la_symbol_ptr  0x10000{i:04X}  lazy-bind  {('<this-image>/' + name)[:4095]}\n"
                         for i, name in enumerate(binds))
        with open(os.path.join(tmp, "symbols"), "w") as f:
            f.writelines(f"{name}\n" for name in symbols)
        fakes = {
            "xcrun": f'#!/bin/bash\n[[ "$2" == -exports ]] && cat {tmp}/exports || cat {tmp}/fixups\n',
            "nm": f'#!/bin/bash\n[[ "$1" == -j ]] && cat {tmp}/symbols\n',
        }
        for name, body in fakes.items():
            path = os.path.join(bin_dir, name)
            with open(path, "w") as f:
                f.write(body)
            os.chmod(path, stat.S_IRWXU)
        open(os.path.join(out, "interposable.txt"), "w").close()
        app = os.path.join(tmp, "app")
        open(app, "w").close()
        env = dict(os.environ, PATH=f"{bin_dir}:{os.environ['PATH']}")
        result = subprocess.run(["bash", "-c", f'source "{LIB}"; live_code_check "{app}" "{out}"'],
                                env=env, capture_output=True, text=True)
        missing = open(os.path.join(out, "missing-2.txt")).read().split()
        return result, missing


class LiveCodeCheckTests(unittest.TestCase):
    def test_a_bind_name_cut_short_matches_its_export(self):
        result, missing = check([LONG, SHORT], [LONG, SHORT])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(missing, [])
        self.assertIn(f"cut at {CUT} characters", result.stderr)

    def test_a_cut_name_that_starts_no_export_is_still_missing(self):
        result, missing = check([SHORT], [LONG, SHORT])
        self.assertEqual(result.returncode, 1)
        self.assertEqual(missing, [LONG[:CUT]])

    def test_a_name_of_exactly_the_cut_length_is_not_taken_for_a_cut_one(self):
        whole = LONG[:CUT]
        result, missing = check([LONG, SHORT], [whole, SHORT], symbols=[whole, LONG, SHORT])
        self.assertEqual(result.returncode, 1)
        self.assertEqual(missing, [whole])

    def test_a_short_unexported_bind_fails(self):
        result, missing = check([LONG], [LONG, SHORT])
        self.assertEqual(result.returncode, 1)
        self.assertEqual(missing, [SHORT])


if __name__ == "__main__":
    unittest.main()
