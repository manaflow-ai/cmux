#!/usr/bin/env python3
"""scripts/cmux-next/gen-motion-scale.py: the settle reaches the app from the one token file.

Leo 2026-11-07, of a reference panel's folds: "they dont overshoot but they decelerate at the end. i
think that might be the key", then of the measured curve: "this is the new system". The web got the
settle (--cmux-ease-settle over --cmux-motion-settle); the app's MotionScale.generated.swift, the Motion
tunables' defaults, must carry the same length and curve, so `MotionCurve.settle` and a page's fold run
on one value. Each test reads schemas/motion-scale/motion-scale.json, or writes the generator's output
for a changed copy of it.

Not on CI (Lawrence 2026-10-23: no new CI tests): run python3 tests/test_cmux_next_motion_settle.py
after changing gen-motion-scale.py or motion-scale.json (under 1 s, no build).
"""
import copy
import importlib.util
import json
import math
from pathlib import Path
import re
import subprocess
import sys
import unittest

SOURCE = Path(__file__).resolve().parents[1]
SWIFT = SOURCE / "Packages/macOS/CmuxNext/Sources/CmuxNextDesignTokens/Motion/MotionScale.generated.swift"


def load():
    spec = importlib.util.spec_from_file_location("cmux_next_gen_motion_scale", SOURCE / "scripts/cmux-next/gen-motion-scale.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def swift_settle(text):
    """MotionScale.settle and MotionScale.settleCurve as written in `text`, or None for a missing one."""
    length = re.search(r"public static let settle: TimeInterval = ([0-9.]+)\n", text)
    curve = re.search(r"public static let settleCurve: \(Float, Float, Float, Float\) = \(([^)]*)\)\n", text)
    return (float(length.group(1)) if length else None,
            [float(value) for value in curve.group(1).split(",")] if curve else None)


def bezier(points, t):
    """CSS cubic-bezier(x1, y1, x2, y2) progress at time fraction t, by bisection on x."""
    x1, y1, x2, y2 = points

    def axis(a, b, s):
        return 3 * a * s * (1 - s) ** 2 + 3 * b * s * s * (1 - s) + s ** 3

    low, high = 0.0, 1.0
    for _ in range(60):
        middle = (low + high) / 2
        if axis(x1, x2, middle) < t:
            low = middle
        else:
            high = middle
    return axis(y1, y2, (low + high) / 2)


class MotionSettleTests(unittest.TestCase):
    def setUp(self):
        self.module = load()
        self.data = self.module.load()

    def test_the_app_copy_carries_the_settle_length_and_curve(self):
        length, curve = swift_settle(SWIFT.read_text())
        self.assertIsNotNone(length, "MotionScale.generated.swift has no MotionScale.settle")
        self.assertIsNotNone(curve, "MotionScale.generated.swift has no MotionScale.settleCurve")
        self.assertAlmostEqual(length, self.data["settle"]["ms"] / 1000)
        self.assertEqual(curve, self.data["settle"]["bezier"])
        # The measured values (split-motion-sweep): 265 ms on cubic-bezier(0.16, 1, 0.3, 1).
        self.assertAlmostEqual(length, 0.265)
        self.assertEqual(curve, [0.16, 1, 0.3, 1])

    def test_every_copy_is_what_the_generator_writes(self):
        result = subprocess.run([sys.executable, str(SOURCE / "scripts/cmux-next/gen-motion-scale.py"), "--check"],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_a_changed_token_reaches_the_app(self):
        changed = copy.deepcopy(self.data)
        changed["settle"]["ms"] = 300
        changed["settle"]["bezier"] = [0.2, 0.9, 0.25, 1]
        length, curve = swift_settle(self.module.swift(changed))
        self.assertAlmostEqual(length, 0.3)
        self.assertEqual(curve, [0.2, 0.9, 0.25, 1])
        # The web copies follow the same token.
        self.assertIn("MOTION_SETTLE_MS = 300;", self.module.ts(changed))
        self.assertIn("--cmux-ease-settle: cubic-bezier(0.2, 0.9, 0.25, 1);", self.module.css_block(changed))

    def test_the_curve_is_the_measured_exponential_with_no_overshoot(self):
        # The recording: x = 1 - e^(-t / 38 ms), at full speed from the first frame, never past its end.
        points = self.data["settle"]["bezier"]
        seconds = self.data["settle"]["ms"] / 1000
        previous = 0.0
        for step in range(1, 266):
            t = step / 1000
            value = bezier(points, min(1.0, t / seconds))
            self.assertLessEqual(value, 1.0 + 1e-9, "past its end at %d ms" % step)
            self.assertGreaterEqual(value, previous - 1e-9, "turned back at %d ms" % step)
            self.assertLess(abs(value - (1 - math.exp(-t / 0.038))), 0.03, "off the measured curve at %d ms" % step)
            previous = value
        # Full speed at the start: a 120 Hz frame covers far more than a critically damped spring's first frame.
        self.assertGreater(bezier(points, (1 / 120) / seconds), 0.15)


if __name__ == "__main__":
    unittest.main()
