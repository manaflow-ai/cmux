#!/usr/bin/env python3
"""The plan and the judge of power_user_native.py on synthetic traces: the same seed is the same plan, and each rule
(frames, blank, flashes, shift per input class, lost input, lag) flags what it names and passes a clean burst.
Run: python3 -I scripts/perf-bench/tests/test_power_user_native.py"""
import os, sys, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
import power_user_native as pu  # noqa: E402

R = 1000 / 120


def row(pane, x, y, w, h, alpha=1.0, cw=None, ch=None):
    cw, ch = (w if cw is None else cw), (h - 30 if ch is None else ch)
    return [pane, x, y, w, h, alpha, 0, x, y, w, h, cw, ch, 1.0, x, y + 30, cw, ch]


def sample(t, panes, late=(), window=(1600, 1000)):
    return {"t": t, "panes": panes, "late": list(late), "window": list(window)}


def frames(intervals, first=100.0):
    return {"intervals_ms": intervals, "first_frame_s": first, "refresh_ms": R}


TWO = [row("a", 0, 0, 800, 1000), row("b", 804, 0, 796, 1000)]


class Plan(unittest.TestCase):
    def test_same_seed_same_plan_and_classes_apart(self):
        self.assertEqual(pu.plan_run(7), pu.plan_run(7))
        self.assertNotEqual(pu.plan_run(7), pu.plan_run(8))
        self.assertEqual(pu.plan_run(7, ["tab"]), [b for b in pu.plan_run(7) if b["class"] == "tab"])

    def test_bursts_end_known(self):
        for b in pu.plan_run(3, bursts=20):
            last = b["events"][-1]
            if b["class"] == "workspace":
                self.assertEqual((last["kind"], last["how"]), ("ws", "digit"))
            elif b["class"] == "tab":
                self.assertEqual((last["kind"], last["how"]), ("tab", "number"))
            else:  # resize and mixed come back to the start size
                self.assertEqual((last.get("dw"), last.get("dh")), (0, 0))
            gaps = [e["at_ms"] for e in b["events"]]
            self.assertEqual(gaps, sorted(gaps))


class Judge(unittest.TestCase):
    def test_frame_window_percentiles_and_long(self):
        fw = pu.frame_window(frames([R] * 98 + [60.0, 3 * R]), 100.0, 101.5)
        self.assertEqual(fw["frames"], 100)
        self.assertEqual(fw["long"], 1)
        self.assertEqual(fw["missed"], 2)
        self.assertAlmostEqual(fw["p50_ms"], R, places=2)

    def test_blank_and_flashes(self):
        s = [sample(0, TWO), sample(8, TWO, late=[["b", 0, 0, 1, 1, 1, 0]]), sample(16, TWO), sample(24, [])]
        out = pu.blank_judge(s)
        self.assertEqual((out["blank_frames"], out["flashes"]), (2, 2))

    def test_tab_shift(self):
        rest = pu.pane_rows({"panes": TWO})
        clean = [sample(i * 8, TWO) for i in range(5)]
        self.assertEqual(pu.shift_tab(clean, rest, {})["shift_frames"], 0)
        moved = clean + [sample(48, [row("a", 0, 0, 802.5, 1000), TWO[1]])]
        self.assertEqual(pu.shift_tab(moved, rest, {})["shift_frames"], 1)
        relaid = clean + [sample(48, [row("a", 0, 0, 800, 1000, ch=900), TWO[1]])]
        self.assertEqual(pu.shift_tab(relaid, rest, {})["shift_frames"], 1)
        self.assertEqual(pu.shift_tab(relaid, rest, {"a": [(800, 970), (800, 900)]})["shift_frames"], 0)

    def test_workspace_rigid_slide_passes_jitter_fails(self):
        one = [row("c", 0, 0, 1600, 1000)]
        refs = {"w1": pu.pane_rows({"panes": TWO}), "w2": pu.pane_rows({"panes": one})}
        slide = [sample(i * 8, [row("a", -100 * i, 0, 800, 1000), row("b", 804 - 100 * i, 0, 796, 1000),
                                row("c", 1600 - 100 * i, 0, 1600, 1000)]) for i in range(5)]
        self.assertEqual(pu.shift_workspace(slide, refs)["shift_frames"], 0)
        jitter = slide + [sample(48, [row("a", -500, 0, 800, 1000), row("b", 804 - 497, 0, 796, 1000)])]
        self.assertEqual(pu.shift_workspace(jitter, refs)["shift_frames"], 1)
        grown = [sample(0, [row("c", 0, 0, 1500, 1000)])]
        self.assertEqual(pu.shift_workspace(grown, refs)["shift_frames"], 1)
        stranger = [sample(0, [row("z", 0, 0, 1600, 1000)])]
        self.assertEqual(pu.shift_workspace(stranger, refs)["shift_frames"], 1)

    def resize_trace(self, widths, layout):
        return [sample(i * 8, layout(w), window=(w, 1000)) for i, w in enumerate(widths)]

    def test_resize_clean_walk(self):
        def layout(w):
            return [row("a", 0, 0, w / 2 - 2, 1000), row("b", w / 2 + 2, 0, w / 2 - 2, 1000)]
        widths = [1600, 1500, 1400, 1400, 1400, 1300, 1500, 1600, 1600, 1600]
        s = self.resize_trace(widths, layout)
        start, end = pu.pane_rows({"panes": layout(1600)}), pu.pane_rows({"panes": layout(1600)})
        out = pu.shift_resize(s, start, end, s[0])
        self.assertEqual((out["shift_frames"], out["lag_run"]), (0, 0), out)

    def test_resize_unprovoked_hysteresis_return_lag(self):
        def layout(w):
            return [row("a", 0, 0, w / 2 - 2, 1000), row("b", w / 2 + 2, 0, w / 2 - 2, 1000)]
        s = self.resize_trace([1600, 1400, 1400, 1400], layout)
        s.append(sample(32, [row("a", 0, 0, 690, 1000), row("b", 702, 0, 698, 1000)], window=(1400, 1000)))
        out = pu.shift_resize(s, pu.pane_rows({"panes": layout(1600)}), pu.pane_rows({"panes": layout(1600)}), s[0])
        self.assertGreaterEqual(out["unprovoked"], 1)
        late = self.resize_trace([1600, 1400, 1200, 1000], lambda w: layout(1600))
        out = pu.shift_resize(late, pu.pane_rows({"panes": layout(1600)}), pu.pane_rows({"panes": layout(1590)}), late[0])
        self.assertEqual(out["lag_run"], 3)
        self.assertFalse(out["returned"])

    def test_lost_input_and_breaches(self):
        burst = {"class": "workspace", "index": 0, "mode": "digit", "events": [{"at_ms": 0}] * 4}
        refs = {"w1": pu.pane_rows({"panes": TWO})}
        run = {"trace": {"t0_s": 100.0, "samples": [sample(i * R, TWO) for i in range(60)]},
               "frames": frames([R] * 60), "first_s": 100.05, "last_s": 100.1, "before": sample(0, TWO),
               "after": sample(0, TWO), "expected_ws": "w1", "observed_ws": "w1"}
        clean = pu.judge_burst(burst, run, refs, {})
        self.assertEqual(pu.breaches(clean, pu.BUDGETS), [], clean)
        lost = pu.judge_burst(burst, {**run, "observed_ws": "w2"}, refs, {})
        self.assertEqual(lost["lost"], 1)
        self.assertTrue(any(b.startswith("lost") for b in pu.breaches(lost, pu.BUDGETS)))
        slow = pu.judge_burst(burst, {**run, "frames": frames([R] * 40 + [30.0] * 20)}, refs, {})
        self.assertTrue(any(b.startswith("p95_ms") for b in pu.breaches(slow, pu.BUDGETS)))


if __name__ == "__main__":
    unittest.main()
