#!/usr/bin/env python3
"""scripts/ci/visual_baseline.py turns the gallery receipt into the `cmux/visual-baseline` status.

Pure JSON: the cmux-shotdiff numbers are given, so nothing renders. The seeded regression on real
Chrome renders runs in shotdiff.yml.
"""
from pathlib import Path
import subprocess
import sys
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/ci"))
import visual_baseline as vb  # noqa: E402

SHA = "a" * 40


def image(state, why="own", status="changed", theme="Dark"):
    return {"state": state, "theme": theme, "status": status, "base_image": f"base/{state}.png",
            "head_image": f"head/{state}.png", "selected_by": {"why": why, "file": "x.tsx", "distance": 0}}


def row(state, passed=True, tile=1.0, theme="Dark", error=None):
    r = {"state": state, "theme": theme, "passed": passed, "reasons": [] if passed else ["changed_ratio 0.02 > 0.01"],
         "changed_ratio": 0.0, "ssim": 1.0, "tile_ssim": tile}
    if error:
        r = {"state": state, "theme": theme, "error": error}
    return r


def judge(images, rows, body=""):
    return vb.judge({"head_sha": SHA, "images": images}, {"head_sha": SHA, "images": rows}, body, SHA)


class VisualBaselineTest(unittest.TestCase):
    def test_own_change_past_defaults_fails_until_explained(self):
        imgs, rows = [image("kit.button/default")], [row("kit.button/default", passed=False)]
        self.assertEqual(judge(imgs, rows)["state"], "failure")
        self.assertEqual(judge(imgs, rows, "Visual-change: kit.button: new radius")["state"], "success")
        self.assertEqual(judge(imgs, rows, "Visual-change: *: restyle")["state"], "success")

    def test_thin_bar_on_another_components_state_fails(self):
        # A highlight bar: under 1% of pixels (shotdiff passes) but one tile moved.
        imgs = [image("sidebar.workspace-row/active", why="host-stylesheet")]
        rows = [row("sidebar.workspace-row/active", tile=0.45)]
        got = judge(imgs, rows)
        self.assertEqual(got["state"], "failure")
        self.assertIn("worst tile", got["failing"][0]["why"])

    def test_same_tile_move_on_own_state_passes(self):
        imgs, rows = [image("kit.button/default")], [row("kit.button/default", tile=0.45)]
        self.assertEqual(judge(imgs, rows)["state"], "success")

    def test_fails_open(self):
        imgs = [image("kit.a/x"), image("kit.b/new", status="new"), image("kit.c/gone", status="removed")]
        self.assertEqual(judge(imgs, [row("kit.a/x", error="missing render")])["state"], "success")
        self.assertEqual(vb.judge(None, None, "", SHA)["state"], "success")
        self.assertEqual(vb.judge({"head_sha": SHA, "images": imgs}, None, "", SHA)["state"], "success")
        other = {"head_sha": "b" * 40, "images": [image("kit.a/x")]}
        self.assertEqual(vb.judge(other, {"head_sha": "b" * 40, "images": [row("kit.a/x", passed=False)]},
                                  "", SHA)["state"], "success")

    def test_description_fits_a_status(self):
        imgs = [image(f"kit.e{i}/v") for i in range(9)]
        got = judge(imgs, [row(f"kit.e{i}/v", passed=False) for i in range(9)])
        self.assertLessEqual(len(got["description"]), 140)
        self.assertIn("9 unexplained", got["description"])


class PostThroughRateLimitTest(unittest.TestCase):
    """A rate-limited status post is asked again: a refused one left the status pending for good (cmux#65276)."""

    def run_post(self, replies):
        calls = []

        def fake_run(args, **kw):
            calls.append(args)
            code, err = replies[min(len(calls), len(replies)) - 1]
            return subprocess.CompletedProcess(args, code, "", err)

        with mock.patch.object(vb.subprocess, "run", fake_run), mock.patch.object(vb.time, "sleep") as sleep:
            code = vb.post("o/r", SHA, "success", "ok")
        return code, len(calls), sleep.call_count

    def test_rate_limit_is_waited_out(self):
        limited = (1, "gh: API rate limit exceeded for installation.\n")
        self.assertEqual(self.run_post([limited, limited, (0, "")]), (0, 3, 2))

    def test_other_refusal_fails_at_once(self):
        self.assertEqual(self.run_post([(1, "gh: Not Found (HTTP 404)\n")]), (1, 1, 0))

    def test_rounds_are_bounded(self):
        code, calls, sleeps = self.run_post([(1, "API rate limit exceeded")])
        self.assertEqual((code, calls, sleeps), (1, vb.POST_ROUNDS, vb.POST_ROUNDS - 1))


if __name__ == "__main__":
    unittest.main()
