#!/usr/bin/env python3
"""Two builds in one DerivedData: a stale explicit module (the CMUX-571 memory A/B, 2026-11-17).

scripts/measure/perf-idle-ab.sh builds base, then head, in one checkout. Both went into .build/DerivedData/cmux-measure,
and the head build failed (exit 65): "file '.../cmux_layout_reducer_ffi.h' has been modified since the module file
'.../SwiftExplicitPrecompiledModules/CCmuxLayoutReducerFFI-*.pcm' was built". A generated FFI header that differs
between two commits cannot meet the other commit's precompiled module, so each arm needs its own DerivedData.

This is the detector for that class. It checks (1) arm-derived-data.sh gives every arm a different path, the head arm
the checkout's warm default; (2) every scripts/measure script that checks commits out one after the other in its own
checkout and runs reload.sh sources the helper before the first checkout and gives every reload.sh a per-arm
CMUX_DERIVED_DATA. A script that builds each commit in its own worktree (reload.sh's default DerivedData is the
worktree's) is not in the class. Run: python3 -I scripts/measure/tests/arm-derived-data.test.py"""
import os, re, subprocess, tempfile, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
MEASURE = os.path.normpath(os.path.join(HERE, ".."))
HELPER = os.path.join(MEASURE, "arm-derived-data.sh")


def logical_lines(text):
    """The script's lines with backslash continuations joined and whole-line comments dropped."""
    out, cur = [], ""
    for raw in text.splitlines():
        if not cur and raw.lstrip().startswith("#"):
            continue
        if raw.endswith("\\"):
            cur += raw[:-1] + " "
            continue
        out.append(cur + raw)
        cur = ""
    return out


class ArmDerivedData(unittest.TestCase):
    def test_arms_get_different_paths(self):
        self.assertTrue(os.path.exists(HELPER), "scripts/measure/arm-derived-data.sh is missing")
        with tempfile.TemporaryDirectory() as repo:
            subprocess.run(["git", "init", "-q", repo], check=True)
            cmd = f'. "{HELPER}"; for a in base head at-0123456789ab; do measure_arm_derived_data "$a"; done'
            res = subprocess.run(["bash", "-c", cmd], cwd=repo, capture_output=True, text=True)
            self.assertEqual(res.returncode, 0, res.stderr)
            root = os.path.realpath(repo)
            dd = os.path.join(root, ".build", "DerivedData")
            self.assertEqual(res.stdout.split(), [
                os.path.join(dd, "cmux-measure-base"),
                os.path.join(dd, "cmux-measure"),
                os.path.join(dd, "cmux-measure-at-0123456789ab"),
            ])

    def test_every_in_place_two_arm_script_gives_each_arm_its_own_derived_data(self):
        checked = []
        for name in sorted(os.listdir(MEASURE)):
            if not name.endswith(".sh"):
                continue
            with open(os.path.join(MEASURE, name), encoding="utf-8") as f:
                lines = logical_lines(f.read())
            # A reload.sh that names its own --derived-data (perf-lab-build.sh: one per config, by design) is its owner's.
            reloads = [i for i, l in enumerate(lines) if "scripts/reload.sh" in l and "--tag" in l and "--derived-data" not in l]
            checkouts = [i for i, l in enumerate(lines) if re.search(r"\bgit\b.*\bcheckout\b.*--detach", l)]
            if not reloads or not checkouts:
                continue
            checked.append(name)
            source = [i for i, l in enumerate(lines) if "arm-derived-data.sh" in l and re.match(r"\s*(\.|source)\s", l)]
            self.assertTrue(source, f"{name} checks commits out in place and builds each, without sourcing arm-derived-data.sh")
            self.assertLess(min(source), min(checkouts), f"{name} sources arm-derived-data.sh after its first checkout (a base may predate it)")
            for i in reloads:
                self.assertIn("CMUX_DERIVED_DATA=\"$(measure_arm_derived_data", lines[i],
                              f"{name}: reload.sh without a per-arm DerivedData: {lines[i].strip()[:120]}")
        for name in ("perf-idle-ab.sh", "nightly-fresh-launch.sh", "update-click-ab.sh"):
            self.assertIn(name, checked, f"the detector no longer sees {name} as a two-arm in-place script")

    def test_build_at_uses_a_derived_data_per_commit(self):
        with open(os.path.join(MEASURE, "app-at-commit.sh"), encoding="utf-8") as f:
            text = f.read()
        self.assertNotIn('cmux-measure-at"', text)
        self.assertIn('measure_arm_derived_data "at-', text)


if __name__ == "__main__":
    unittest.main()
