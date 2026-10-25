#!/usr/bin/env python3
"""anomaly.py and anomaly_edivisive.py: catapult parity, the lab's step and noise acceptance, target_miss.

Run: python3 -m unittest scripts/perf-lab/tests/test_anomaly.py
The expected candidates come from running catapult's own modules at commit
0e8f52413a40b5c868739293e784428041275f81 (find_change_points_test.py and
clustering_change_detector_test.py fixtures, and seeded series), not from this port.
"""

import importlib.util
import json
import os
import random
import sys
import tempfile
import unittest
from collections import namedtuple

HERE = os.path.dirname(os.path.abspath(__file__))
LAB = os.path.dirname(HERE)
REPO = os.path.dirname(os.path.dirname(LAB))


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


anomaly = _load("perf_lab_anomaly_under_test", os.path.join(LAB, "anomaly.py"))
ccd = anomaly.edivisive
perf_result = _load("perf_lab_perf_result_for_anomaly", os.path.join(LAB, "perf_result.py"))

# find_change_points_test.py testFindChangePoints_ShortSequences: (values, max_window_size,
# catapult's ClusterAndFindSplit candidates, catapult's FindChangePoints x-values).
SHORT_SEQUENCES = [
    ([1, 1, 1, 9, 9, 9, 9, 9, 9, 9], 10, [(3, (3, 3))], [3]),
    ([1, 1, 5, 5, 5, 5, 9, 9, 9, 9], 10, [(6, (6, 6))], [6]),
    ([1, 1, 1, 1, 6, 6, 6, 6, 9, 9, 9], 11, [(4, (4, 4)), (8, (8, 8))], [4]),
    ([1, 1, 1, 1, 1, 1, 6, 6, 6, 6, 12, 12, 12, 12], 14, [(6, (6, 6)), (10, (10, 10))], [10, 6]),
    ([1, 1, 5, 5, 5, 5, 9, 9, 9, 9, 9], 11, [(6, (6, 6))], [6]),
]

# clustering_change_detector_test.py sequences and catapult's full ClusterAndFindSplit output.
CLUSTER_FIXTURES = [
    ([1] * 10 + [10] * 10, [(10, (10, 10))]),
    ([1] * 10 + [2] * 10 + [1] * 10, [(10, (10, 10)), (20, (20, 20))]),
    ([1] * 15 + [800] + [1000] * 20, [(15, (15, 16))]),
    ([1] * 50 + [1000] * 10 + [1] * 50 + [500] * 50, [(50, (48, 50)), (60, (60, 60)), (110, (108, 113))]),
    ([100] * 120 + [200] * 10 + [100] * 110 + [500] * 2,
     [(120, (114, 120)), (130, (130, 130)), (240, (240, 241))]),
]

# catapult FindChangePoints with its defaults and rand=random.Random(x=1) on _seeded_series(i):
# (x_value, extended_start, extended_end, median_before, median_after) per change point, newest first.
SEEDED_EXPECTED = {
    0: [(1024, 1024, 1024, 87.715934814, 112.531136617)],
    6: [(1034, 1033, 1036, 90.77072136, 108.01582839)],
    7: [(1011, 1011, 1011, 94.518298177, 124.191307395)],
    9: [(1011, 1011, 1011, 9.4775431, 11.390582479)],
    13: [(1025, 1024, 1025, 84.458818172, 104.121938257)],
    16: [(1025, 1024, 1026, 83.064075864, 99.694802027)],
    18: [(1017, 1016, 1017, 168.445119783, 222.43696438)],
    24: [(1006, 1006, 1006, 163.608753347, 133.771815309)],
    25: [(1016, 1015, 1016, 135.035290893, 113.968816757)],
    28: [(1014, 1014, 1015, 45.205813165, 38.124018676)],
}
SEEDED_COUNT = 30


def _seeded_series():
    r = random.Random(20261025)
    out = []
    for _ in range(SEEDED_COUNT):
        base = r.uniform(5, 200)
        noise = base * r.uniform(0.01, 0.08)
        n = r.randint(20, 70)
        at = r.randint(3, n - 3)
        step = r.choice([0.0, 0.05, 0.12, 0.2, -0.15, 0.3])
        ys = [r.gauss(base, noise) + (base * step if k >= at else 0) for k in range(n)]
        out.append(list(zip(range(1000, 1000 + n), ys)))
    return out


def _step_series(rng, before, after, step, base=100.0, noise=1.0):
    ys = [rng.gauss(base, noise) for _ in range(before)]
    ys += [rng.gauss(base * (1 + step), noise) for _ in range(after)]
    return list(enumerate(ys))


class Constants(unittest.TestCase):
    def test_catapult_defaults_and_detector_constants(self):
        self.assertEqual(anomaly.MAX_WINDOW_SIZE, 50)
        self.assertEqual(anomaly.MIN_SEGMENT_SIZE, 6)
        self.assertEqual(anomaly.MIN_ABSOLUTE_CHANGE, 0)
        self.assertEqual(anomaly.MIN_RELATIVE_CHANGE, 0.1)
        self.assertEqual(anomaly.MIN_STEPPINESS, 0.5)
        self.assertEqual(anomaly.MULTIPLE_OF_STD_DEV, 2.5)
        self.assertEqual(ccd._PERMUTATION_TESTING_ITERATIONS, 199)
        self.assertEqual(ccd._MIN_SIGNIFICANCE, 0.95)
        self.assertEqual(ccd._MAX_SUBSAMPLING_LENGTH, 20)
        self.assertEqual(ccd._CHANGE_RANGE_TOLERANCE, 0.90)


class CatapultParity(unittest.TestCase):
    def test_short_sequence_candidates_equal_catapult(self):
        for values, window, candidates, x_values in SHORT_SEQUENCES:
            with self.subTest(values=values):
                self.assertEqual(ccd.ClusterAndFindSplit(values[-window:], random.Random(1)), candidates)
                found = anomaly.find_change_points(
                    list(enumerate(values)), max_window_size=window, min_segment_size=3, min_absolute_change=0,
                    min_relative_change=0.01, min_steppiness=0.4, multiple_of_std_dev=2.5,
                    rand=random.Random(1))
                self.assertEqual([c.x_value for c in found], x_values)

    def test_zero_segment_size(self):
        found = anomaly.find_change_points(
            list(enumerate([10, 10, 10, 10, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1])), max_window_size=50,
            min_segment_size=0, min_absolute_change=0, min_relative_change=0.01, min_steppiness=0.4,
            multiple_of_std_dev=2.5, rand=random.Random(1))
        self.assertEqual([c.x_value for c in found], [4])

    def test_find_change_points_fields(self):
        found = anomaly.find_change_points(
            list(enumerate([1, 1, 2, 1, 1, 8, 8, 8, 9, 8, 9])), max_window_size=10, multiple_of_std_dev=3,
            min_relative_change=0.5, min_absolute_change=1, min_steppiness=0.4, min_segment_size=3,
            rand=random.Random(1))
        self.assertEqual(found, [anomaly.ChangePoint(
            x_value=5, index=4, median_before=1, median_after=8, size_before=4, size_after=6, window_start=1,
            window_end=10, relative_change=7, std_dev_before=0.4330127018922193, extended_start=5,
            extended_end=5)])

    def test_empty_series(self):
        self.assertEqual(anomaly.find_change_points([]), [])

    def test_cluster_fixtures_equal_catapult(self):
        for sequence, expected in CLUSTER_FIXTURES:
            with self.subTest(length=len(sequence)):
                self.assertEqual(ccd.ClusterAndFindSplit(sequence, random.Random(1)), expected)

    def test_spikes_are_insufficient_data(self):
        with self.assertRaises(ccd.InsufficientData):
            ccd.ClusterAndFindSplit([1] * 15 + [500, 1000, 500] + [1] * 15, random.Random(1))

    def test_seeded_series_equal_catapult_with_defaults(self):
        for i, series in enumerate(_seeded_series()):
            with self.subTest(series=i):
                found = anomaly.find_change_points(series, rand=random.Random(1))
                got = [(c.x_value, c.extended_start, c.extended_end, round(c.median_before, 9),
                        round(c.median_after, 9)) for c in found]
                self.assertEqual(got, SEEDED_EXPECTED.get(i, []))

    def test_default_rand_is_seeded_and_reproducible(self):
        series = _seeded_series()[0]
        self.assertEqual(anomaly.find_change_points(series), anomaly.find_change_points(series, rand=random.Random(1)))


class PassesThresholds(unittest.TestCase):
    """find_change_points_test.py testIsAnomalous_* cases."""

    def check(self, data, index, **overrides):
        args = dict(multiple_of_std_dev=0, min_relative_change=0, min_absolute_change=0, min_segment_size=0,
                    min_steppiness=0)
        args.update(overrides)
        return anomaly.passes_thresholds(data, index, **args)

    def test_segment_size(self):
        sample = [1, 1, 5, 5, 5, 9, 9]
        self.assertEqual(self.check(sample, 2, min_segment_size=3), (False, 'min_segment_size'))
        self.assertEqual(self.check(sample, 5, min_segment_size=3), (False, 'min_segment_size'))
        self.assertEqual(self.check(sample, 2, min_segment_size=2), (True, 'passed'))
        self.assertEqual(self.check(sample, 5, min_segment_size=2), (True, 'passed'))

    def test_absolute_change(self):
        sample = [2, 2, 2, 4, 4, 4, 4, 8, 8, 8]
        self.assertEqual(self.check(sample, 7), (True, 'passed'))
        self.assertEqual(self.check(sample, 7, min_absolute_change=4), (True, 'passed'))
        self.assertEqual(self.check(sample, 3, min_absolute_change=4), (False, 'min_absolute_change'))

    def test_relative_change(self):
        sample = [2, 2, 2, 6, 6, 6, 6, 10, 10, 10]
        self.assertEqual(self.check(sample, 3), (True, 'passed'))
        self.assertEqual(self.check(sample, 3, min_relative_change=1), (True, 'passed'))
        self.assertEqual(self.check(sample, 7, min_relative_change=1), (False, 'min_relative_change'))

    def test_multiple_of_std_dev(self):
        noisy = [2, 8, 5, 1, 7, 13, 19, 10, 15, 17]
        steady = [5, 5, 5, 5, 5, 15, 15, 15, 15, 15]
        self.assertEqual(self.check(steady, 5, multiple_of_std_dev=1), (True, 'passed'))
        self.assertEqual(self.check(steady, 5, multiple_of_std_dev=8), (True, 'passed'))
        self.assertEqual(self.check(noisy, 5, multiple_of_std_dev=1), (True, 'passed'))
        self.assertEqual(self.check(noisy, 5, multiple_of_std_dev=8), (False, 'min_std_dev'))

    def test_multiple_of_std_dev_low_on_one_side(self):
        left = [3, 2, 3, 4, 3, 5, 30, 1, 50, 10]
        right = [5, 30, 1, 50, 10, 3, 2, 3, 4, 3]
        self.assertEqual(self.check(left, 5, multiple_of_std_dev=7), (True, 'passed'))
        self.assertEqual(self.check(right, 5, multiple_of_std_dev=7), (True, 'passed'))


class LabAcceptance(unittest.TestCase):
    def test_15_percent_step_found_once_six_points_follow(self):
        # Found as soon as MIN_SEGMENT_SIZE points follow it, and the newest change point from then on.
        # catapult itself also returns a second candidate inside the old segment on some windows
        # (after=17 gives [20, 18] from its own FindChangePoints); the alert group merges it.
        for after in range(1, 31):
            with self.subTest(after=after):
                series = _step_series(random.Random(1000 + after), 20, after, 0.15)
                detection = anomaly.detect(series, "lower")
                found = [c.x_value for c in detection.regressions]
                if after < anomaly.MIN_SEGMENT_SIZE:
                    self.assertEqual(found, [])
                else:
                    self.assertEqual(found[:1], [20])
                self.assertEqual(detection.improvements, [])

    def test_step_after_17_points_matches_catapult(self):
        series = _step_series(random.Random(1017), 20, 17, 0.15)
        self.assertEqual([c.x_value for c in anomaly.find_change_points(series)], [20, 18])

    def test_8_percent_step_ignored(self):
        for after in range(6, 31):
            with self.subTest(after=after):
                series = _step_series(random.Random(2000 + after), 20, after, 0.08)
                self.assertEqual(anomaly.find_change_points(series), [])

    def test_at_most_10_alerts_on_1000_noise_series(self):
        rng = random.Random(3000)
        alerts = 0
        for _ in range(1000):
            base = rng.uniform(5, 200)
            series = [(k, rng.gauss(base, base * 0.05)) for k in range(60)]
            alerts += len(anomaly.detect(series, "lower").regressions)
        self.assertLessEqual(alerts, 10)

    def test_improvement_recorded_not_alerted(self):
        series = _step_series(random.Random(4000), 20, 12, -0.15)
        detection = anomaly.detect(series, "lower")
        self.assertEqual(detection.regressions, [])
        self.assertEqual([c.x_value for c in detection.improvements], [20])
        flipped = anomaly.detect(series, "higher")
        self.assertEqual([c.x_value for c in flipped.regressions], [20])
        self.assertEqual(flipped.improvements, [])

    def test_row_floor_is_min_absolute_change(self):
        series = _step_series(random.Random(1012), 20, 12, 0.15)
        self.assertEqual(len(anomaly.detect(series, "lower", min_absolute_change=1.0).regressions), 1)
        self.assertEqual(anomaly.detect(series, "lower", min_absolute_change=50.0).regressions, [])

    def test_only_the_window_is_examined(self):
        old_step = _step_series(random.Random(5000), 20, 60, 0.3)
        self.assertEqual(anomaly.find_change_points(old_step), [])

    def test_unknown_direction_raises(self):
        with self.assertRaises(anomaly.AnomalyError):
            anomaly.detect([(0, 1.0), (1, 2.0)], "faster")


class PointValues(unittest.TestCase):
    Point = namedtuple("Point", "commit_pos samples")

    def test_median_and_p99_series(self):
        points = [self.Point(10, [1.0, 2.0, 9.0]), self.Point(11, [4.0, 2.0, 3.0, 5.0])]
        self.assertEqual(anomaly.series_from_points(points), [(10, 2.0), (11, 3.5)])
        p99 = anomaly.series_from_points(points, "p99")
        self.assertAlmostEqual(p99[0][1], 8.86)
        self.assertAlmostEqual(p99[1][1], 4.97)

    def test_empty_samples_and_unknown_statistic_raise(self):
        with self.assertRaises(anomaly.AnomalyError):
            anomaly.point_value([])
        with self.assertRaises(anomaly.AnomalyError):
            anomaly.point_value([1.0], "p90")


class RowFloor(unittest.TestCase):
    def test_reads_the_perf_budgets_row_by_reference(self):
        with open(os.path.join(REPO, "scripts", "cmux-next", "perf-budgets.json"), encoding="utf-8") as handle:
            rows = json.load(handle)["rows"]
        pattern, spec = next(iter(rows.items()))
        ref = perf_result.TargetRef(path="scripts/cmux-next/perf-budgets.json", key=pattern)
        self.assertEqual(anomaly.row_floor(ref, REPO), spec["floor"])
        self.assertEqual(anomaly.row_floor(ref.to_dict(), REPO), spec["floor"])

    def test_row_name_matches_the_first_full_match_pattern(self):
        with tempfile.TemporaryDirectory() as root:
            with open(os.path.join(root, "t.json"), "w", encoding="utf-8") as handle:
                json.dump({"rows": {"a\\..*": {"floor": 0.3}, "a\\.b": {"floor": 3.0}, "c": {}}}, handle)
            self.assertEqual(anomaly.row_floor({"path": "t.json", "key": "a.b"}, root), 0.3)
            self.assertEqual(anomaly.row_floor({"path": "t.json", "key": "a\\.b"}, root), 3.0)
            self.assertEqual(anomaly.row_floor({"path": "t.json", "key": "c"}, root), anomaly.MIN_ABSOLUTE_CHANGE)
            with self.assertRaises(anomaly.AnomalyError):
                anomaly.row_floor({"path": "t.json", "key": "zzz"}, root)
            with self.assertRaises(anomaly.AnomalyError):
                anomaly.row_floor({"path": "missing.json", "key": "a"}, root)

    def test_no_reference_is_catapult_default(self):
        self.assertEqual(anomaly.row_floor(None, REPO), anomaly.MIN_ABSOLUTE_CHANGE)
        self.assertEqual(anomaly.row_floor({"target": "key-frame-p50"}, REPO), anomaly.MIN_ABSOLUTE_CHANGE)


class TargetMiss(unittest.TestCase):
    def test_newest_segment_crossing_the_target_fires(self):
        series = _step_series(random.Random(6000), 20, 8, 0.15, base=7.5, noise=0.1)
        miss = anomaly.target_miss(series, 8.3)
        self.assertIsNotNone(miss)
        self.assertEqual(miss.x_value, 20)
        self.assertLessEqual(miss.median_before, 8.3)
        self.assertGreater(miss.median_after, 8.3)

    def test_short_newest_segment_does_not_fire(self):
        series = _step_series(random.Random(6001), 20, 5, 0.15, base=7.5, noise=0.1)
        self.assertIsNone(anomaly.target_miss(series, 8.3))

    def test_step_that_stays_under_the_target_does_not_fire(self):
        series = _step_series(random.Random(6002), 20, 10, 0.05, base=7.5, noise=0.05)
        self.assertIsNone(anomaly.target_miss(series, 8.3))

    def test_previous_segment_already_missing_does_not_fire(self):
        series = _step_series(random.Random(6003), 20, 10, 0.15, base=9.0, noise=0.1)
        self.assertIsNone(anomaly.target_miss(series, 8.3))

    def test_higher_is_better_fires_on_a_drop_below(self):
        series = _step_series(random.Random(6004), 20, 10, -0.15, base=125.0, noise=1.0)
        miss = anomaly.target_miss(series, 118.0, better="higher")
        self.assertIsNotNone(miss)
        self.assertEqual(miss.x_value, 20)
        self.assertIsNone(anomaly.target_miss(series, 118.0, better="lower"))

    def test_noise_around_a_met_target_does_not_fire(self):
        rng = random.Random(6005)
        series = [(k, rng.gauss(7.0, 0.3)) for k in range(50)]
        self.assertIsNone(anomaly.target_miss(series, 8.3))


if __name__ == "__main__":
    unittest.main()
