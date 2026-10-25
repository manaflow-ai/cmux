#!/usr/bin/env python3
"""perf_stats: catapult Pinpoint MWU, KS, thresholds and compare, pct parity with perf-budgets.py.

Run: python3 -m unittest scripts/perf-lab/tests/test_perf_stats.py
The expected values come from catapult's own code at commit 0e8f52413a40b5c868739293e784428041275f81
(its *_test.py files and a recompute of its modules), not from this port.
"""

import hashlib
import importlib.util
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
LAB = os.path.dirname(HERE)
REPO = os.path.dirname(os.path.dirname(LAB))


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


ps = _load("perf_stats", os.path.join(LAB, "perf_stats.py"))
thresholds = _load("pinpoint_thresholds_under_test", os.path.join(LAB, "pinpoint_thresholds.py"))
perf_budgets = _load("perf_budgets", os.path.join(REPO, "scripts", "cmux-next", "perf-budgets.py"))

# sha256 of catapult thresholds.py from its "# Run thresholds_functional.py" line to the end of the file.
CATAPULT_TABLE_SHA256 = "afe6ac6d7b187c28a1923e8c0eced4a08b692a7fcdb7282d2ac20ad35d7d88af"

TOL = 0.0005
DISCRETE_A, DISCRETE_B = [0] * 20, [0] * 15 + [1] * 5
SPREAD_A, SPREAD_B = list(range(10, 30)), list(range(10)) + list(range(30, 40))


class AcceptanceVectors(unittest.TestCase):
    """compare.py's comment examples, with the values the current two-sided code returns."""

    def test_discrete_shift(self):
        self.assertAlmostEqual(ps.MannWhitneyU(DISCRETE_A, DISCRETE_B), 0.0195, delta=TOL)
        self.assertAlmostEqual(ps.KolmogorovSmirnov(DISCRETE_A, DISCRETE_B), 0.4973, delta=TOL)

    def test_variance_change(self):
        self.assertAlmostEqual(ps.MannWhitneyU(SPREAD_A, SPREAD_B), 0.9892, delta=TOL)
        self.assertAlmostEqual(ps.KolmogorovSmirnov(SPREAD_A, SPREAD_B), 0.0082, delta=TOL)

    def test_mwu_is_two_sided_not_the_stale_one_sided_comment(self):
        # catapult's comment says 0.0097 and 0.4946: half of the two-sided values.
        self.assertNotAlmostEqual(ps.MannWhitneyU(DISCRETE_A, DISCRETE_B), 0.0097, delta=TOL)
        self.assertNotAlmostEqual(ps.MannWhitneyU(SPREAD_A, SPREAD_B), 0.4946, delta=TOL)


class MannWhitneyUTest(unittest.TestCase):
    """catapult mann_whitney_u_test.py."""

    def test_basic(self):
        self.assertAlmostEqual(ps.MannWhitneyU(list(range(10)), list(range(20, 30))), 0.00018267179110955002)
        self.assertAlmostEqual(ps.MannWhitneyU(list(range(5)), list(range(10))), 0.13986357686781267)

    def test_duplicate_values(self):
        self.assertAlmostEqual(ps.MannWhitneyU([0] * 5, [1] * 5), 0.0039767517097886512)

    def test_small_samples(self):
        self.assertEqual(ps.MannWhitneyU([0], [1]), 1.0)

    def test_all_values_identical(self):
        self.assertEqual(ps.MannWhitneyU([0] * 5, [0] * 5), 1.0)

    def test_small_samples_use_the_normal_approximation(self):
        # The exact two-sided p for [0]*5 vs [1]*5 is 2/252 = 0.0079; the port has no exact path.
        self.assertNotAlmostEqual(ps.MannWhitneyU([0] * 5, [1] * 5), 2 / 252, delta=TOL)

    def test_tuples_and_lists_mix(self):
        self.assertEqual(ps.MannWhitneyU(tuple(range(5)), list(range(10))), ps.MannWhitneyU(list(range(5)), list(range(10))))


class KolmogorovSmirnovTest(unittest.TestCase):
    """catapult kolmogorov_smirnov_test.py."""

    def test_basic(self):
        self.assertAlmostEqual(ps.KolmogorovSmirnov(list(range(10)), list(range(20, 30))), 1.8879793657162556e-05)
        self.assertAlmostEqual(ps.KolmogorovSmirnov(list(range(5)), list(range(10))), 0.26680230985258474)

    def test_duplicate_values(self):
        self.assertAlmostEqual(ps.KolmogorovSmirnov([0] * 5, [1] * 5), 0.0037813540593701006)

    def test_small_samples(self):
        self.assertEqual(ps.KolmogorovSmirnov([0], [1]), 0.2890414283708268)

    def test_all_values_identical(self):
        self.assertEqual(ps.KolmogorovSmirnov([0] * 5, [0] * 5), 1.0)


class ThresholdsTest(unittest.TestCase):
    """catapult thresholds_test.py plus table lookups recomputed with catapult's thresholds.py."""

    def test_spec_lookup(self):
        self.assertEqual(ps.HighThreshold('performance', 1.0, 10), 0.5708)

    def test_lookups_equal_catapult(self):
        cases = [
            (('functional', 0.5, 20), 0.0195),  # thresholds_test.py
            (('performance', 10, 5), 0.0122),  # thresholds_test.py: magnitude clamped to the 4.0 row
            (('performance', 0.1, 20), 0.9893),  # magnitude clamped to the 0.3 row
            (('performance', 2.0, 3), 0.6626),
            (('performance', 1.5, 50), 0.009),  # sample size clamped to the row's last entry
            (('functional', 1.0, 100), 0.004),
            (('performance', 0.35, 2), 0.6986),  # int(3.5) - 3 = row 0.3
        ]
        for args, expected in cases:
            with self.subTest(args=args):
                self.assertEqual(ps.HighThreshold(*args), expected)

    def test_unknown_mode(self):
        with self.assertRaises(NotImplementedError):
            ps.HighThreshold('unknown mode', 1, 20)

    def test_performance_falls_below_low_threshold(self):
        self.assertLessEqual(ps.HighThreshold('performance', 1.5, 20), ps.LowThreshold())
        self.assertLessEqual(ps.HighThreshold('performance', 1.5, 50), ps.LowThreshold())

    def test_low_threshold(self):
        self.assertEqual(ps.LowThreshold(), 0.01)

    def test_table_text_is_catapults(self):
        with open(os.path.join(LAB, "pinpoint_thresholds.py"), encoding="utf-8") as f:
            text = f.read()
        tables = text[text.index(thresholds.TABLE_START):]
        self.assertEqual(hashlib.sha256(tables.encode("utf-8")).hexdigest(), CATAPULT_TABLE_SHA256)
        self.assertEqual(thresholds.TABLE_SHA256, CATAPULT_TABLE_SHA256)

    def test_table_shape(self):
        self.assertEqual(len(thresholds._HIGH_THRESHOLDS_PERFORMANCE), 38)  # 0.3 to 4.0 IQR
        self.assertEqual(len(thresholds._HIGH_THRESHOLDS_FUNCTIONAL), 10)  # 0.1 to 1.0 failure rate


class CompareTest(unittest.TestCase):
    """catapult compare_test.py on the original verdict, and the floored verdict where they differ."""

    def test_no_values(self):
        for a, b, mode in (([], [0] * 10, 'functional'), (list(range(10)), [], 'performance')):
            c = ps.compare(a, b, 10, mode, 1)
            self.assertEqual((c.original.result, c.floored.result), (ps.UNKNOWN, ps.UNKNOWN))
            self.assertIsNone(c.p_value)
            self.assertIsNone(c.floored.p_value)

    def test_functional(self):
        c = ps.compare([0] * 10, [1] * 10, 10, 'functional', 0.5)
        self.assertEqual(c.original.result, ps.DIFFERENT)
        self.assertLessEqual(c.p_value, c.original.low_threshold)
        c = ps.compare([0] * 10, [0] * 9 + [1], 10, 'functional', 0.5)
        self.assertEqual(c.original.result, ps.UNKNOWN)
        self.assertLessEqual(c.p_value, c.original.high_threshold)
        c = ps.compare([0] * 10, [0] * 10, 10, 'functional', 0.5)
        self.assertEqual(c.original.result, ps.SAME)
        self.assertGreater(c.p_value, c.original.high_threshold)

    def test_performance(self):
        c = ps.compare(list(range(10)), list(range(7, 17)), 10, 'performance', 1)
        self.assertEqual(c.original.result, ps.DIFFERENT)
        self.assertLessEqual(c.p_value, c.original.low_threshold)
        c = ps.compare(list(range(10)), list(range(3, 13)), 10, 'performance', 1)
        self.assertEqual(c.original.result, ps.UNKNOWN)
        self.assertLessEqual(c.p_value, c.original.high_threshold)
        c = ps.compare(list(range(10)), list(range(10)), 10, 'performance', 1)
        self.assertEqual(c.original.result, ps.SAME)
        self.assertGreater(c.p_value, c.original.high_threshold)

    def test_p_value_is_min_of_ks_and_mwu(self):
        c = ps.compare(SPREAD_A, SPREAD_B)
        self.assertEqual(c.p_value, min(c.ks_p_value, c.mwu_p_value))
        self.assertAlmostEqual(c.ks_p_value, 0.0082, delta=TOL)
        self.assertEqual((c.original.result, c.floored.result), (ps.DIFFERENT, ps.DIFFERENT))

    def test_default_attempt_count_is_the_mean_sample_size(self):
        self.assertEqual(ps.compare(DISCRETE_A, DISCRETE_B), ps.compare(DISCRETE_A, DISCRETE_B, 20))

    def test_floored_different_where_original_is_unknown(self):
        # p = 0.0195: above 0.01, at most 0.05.
        c = ps.compare(DISCRETE_A, DISCRETE_B)
        self.assertEqual(c.original, ps.ComparisonResults(ps.UNKNOWN, c.p_value, 0.01, 0.0859))
        self.assertEqual(c.floored, ps.ComparisonResults(ps.DIFFERENT, c.p_value, 0.05, 0.10))

    def test_floored_unknown_where_original_is_same(self):
        # p = 0.0581: above HighThreshold('performance', 2.0, 10) = 0.0073, at most the 0.10 floor.
        c = ps.compare(list(range(10)), list(range(3, 13)), 10, 'performance', 2.0)
        self.assertAlmostEqual(c.p_value, 0.0581, delta=TOL)
        self.assertEqual((c.original.result, c.floored.result), (ps.SAME, ps.UNKNOWN))
        self.assertEqual((c.original.high_threshold, c.floored.high_threshold), (0.0073, 0.10))


class PercentileTest(unittest.TestCase):
    VECTORS = [
        ([5, 1, 4, 2, 3, 9, 7, 8, 6, 10], (0.0, 0.25, 0.5, 0.95, 0.99, 1.0)),
        ([42], (0.0, 0.5, 0.95, 1.0)),
        ([0.5, 0.25], (0.1, 0.5, 0.9)),
        ([3, None, "x", 1.5, 2, 7, 7, 7, 100], (0.25, 0.5, 0.75, 0.95, 0.99)),
        ([float(i * i % 17) for i in range(37)], (0.01, 0.33, 0.5, 0.9, 0.95, 0.99)),
    ]

    def test_pct_equals_perf_budgets_pct(self):
        for values, qs in self.VECTORS:
            for q in qs:
                with self.subTest(values=values, q=q):
                    self.assertEqual(ps.pct(values, q), perf_budgets.pct(values, q))
        self.assertIsNone(ps.pct([], 0.5))
        self.assertIsNone(perf_budgets.pct([], 0.5))

    def test_pct_interpolates_linearly(self):
        self.assertEqual(ps.pct([1, 2, 3, 4], 0.5), 2.5)
        self.assertAlmostEqual(ps.pct(list(range(1, 11)), 0.95), 9.55)

    def test_summary(self):
        s = ps.summary([5, 1, 4, 2, 3, 9, 7, 8, 6, 10])
        self.assertEqual((s["n"], s["p50"], s["max"], s["iqr"]), (10, 5.5, 10, 4.5))
        self.assertAlmostEqual(s["p95"], 9.55)
        self.assertAlmostEqual(s["p99"], 9.91)
        self.assertEqual(ps.summary([]), {"n": 0, "p50": None, "p95": None, "p99": None, "max": None, "iqr": None})

    def test_magnitude_from(self):
        # catapult math_utils.Iqr (C = 1/2): [1..5] has IQR 4.25 - 1.75 = 2.5; pct() (C = 1) gives 2.
        self.assertAlmostEqual(ps.magnitude_from(3.0, [1, 2, 3, 4, 5], [1, 1, 1, 1]), 1.2)
        self.assertAlmostEqual(ps.magnitude_from(-3.0, [1, 2, 3, 4, 5], [1, 1, 1, 1]), 1.2)
        self.assertEqual(ps.iqr([1, 2, 3, 4, 5]), 2.0)
        # [1, 2, 10, 20]: C = 1/2 gives 15 - 1.5 = 13.5, C = 1 gives 12.5 - 1.75 = 10.75.
        self.assertAlmostEqual(ps.magnitude_from(13.5, [1, 2, 10, 20], [0]), 1.0)
        self.assertEqual(ps.iqr([1, 2, 10, 20]), 10.75)
        self.assertEqual(ps.magnitude_from(5.0, [7], [3, 3]), 5000.0)  # one value: Percentile edge
        self.assertAlmostEqual(ps.magnitude_from(0.01, [1, 1], [2, 2]), 10.0)  # IQR floor 0.001
        self.assertEqual(ps.magnitude_from(None, [1], [2]), 1.0)
        self.assertEqual(ps.magnitude_from(0, [1], [2]), 1.0)


if __name__ == "__main__":
    unittest.main()
