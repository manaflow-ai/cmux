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

# stories.d/motion.json's cmd_n metric floor_ref, as the catalog stores it.
with open(os.path.join(LAB, "stories.d", "motion.json"), encoding="utf-8") as _handle:
    MOTION_CMD_N_FLOOR_REF = next(m["floor_ref"] for m in json.load(_handle)["metrics"] if m["name"].startswith("cmd_n"))

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


def _rises(change_point):
    return change_point.median_after > change_point.median_before


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
                found = anomaly.find_change_points(_step_series(random.Random(1000 + after), 20, after, 0.15))
                if after < anomaly.MIN_SEGMENT_SIZE:
                    self.assertEqual(found, [])
                else:
                    self.assertEqual([c.x_value for c in found][:1], [20])
                    self.assertTrue(all(_rises(c) for c in found))

    def test_step_after_17_points_matches_catapult(self):
        series = _step_series(random.Random(1017), 20, 17, 0.15)
        self.assertEqual([c.x_value for c in anomaly.find_change_points(series)], [20, 18])

    def test_8_percent_step_ignored(self):
        for after in range(6, 31):
            with self.subTest(after=after):
                series = _step_series(random.Random(2000 + after), 20, after, 0.08)
                self.assertEqual(anomaly.find_change_points(series), [])

    def test_at_most_10_alerts_on_1000_noise_series(self):
        # Every change point counts, in either direction: a stricter bound than regressions only.
        rng = random.Random(3000)
        alerts = 0
        for _ in range(1000):
            base = rng.uniform(5, 200)
            series = [(k, rng.gauss(base, base * 0.05)) for k in range(60)]
            alerts += len(anomaly.find_change_points(series))
        self.assertLessEqual(alerts, 10)

    def test_min_absolute_change_is_the_floor_filter(self):
        series = _step_series(random.Random(1012), 20, 12, 0.15)
        self.assertEqual(len(anomaly.find_change_points(series, min_absolute_change=1.0)), 1)
        self.assertEqual(anomaly.find_change_points(series, min_absolute_change=50.0), [])

    def test_only_the_window_is_examined(self):
        old_step = _step_series(random.Random(5000), 20, 60, 0.3)
        self.assertEqual(anomaly.find_change_points(old_step), [])

    def test_counts_must_be_integers(self):
        series = _step_series(random.Random(1012), 20, 12, 0.15)
        for config in ({"max_window_size": 40.0}, {"max_window_size": 0}, {"min_segment_size": 6.0},
                       {"min_segment_size": -1}, {"max_window_size": True}):
            with self.subTest(config=config), self.assertRaises(anomaly.AnomalyError):
                anomaly.find_change_points(series, **config)

    def test_unknown_direction_raises(self):
        with self.assertRaises(anomaly.AnomalyError):
            anomaly.target_miss([(0, 1.0), (1, 2.0)], 1.5, better="faster")


class RowFloor(unittest.TestCase):
    def test_a_stories_floor_ref_resolves_to_the_perf_budgets_floor(self):
        with open(os.path.join(REPO, "scripts", "cmux-next", "perf-budgets.json"), encoding="utf-8") as handle:
            rows = json.load(handle)["rows"]
        self.assertEqual(MOTION_CMD_N_FLOOR_REF["key"], "/rows/cmd_n\\..*/floor")
        expected = rows["cmd_n\\..*"]["floor"]
        self.assertEqual(anomaly.row_floor(MOTION_CMD_N_FLOOR_REF, REPO), expected)
        ref = anomaly.catalog.Ref(MOTION_CMD_N_FLOOR_REF["path"], MOTION_CMD_N_FLOOR_REF["key"])
        self.assertEqual(anomaly.row_floor(ref, REPO), expected)

    def test_every_catalog_floor_ref_resolves(self):
        stories = anomaly.catalog.load_catalog(anomaly.catalog.Path(REPO)).stories
        refs = [m.floor_ref for story in stories for m in story.metrics if m.floor_ref is not None]
        self.assertTrue(refs)
        for ref in refs:
            with self.subTest(ref=ref.describe()):
                self.assertGreaterEqual(anomaly.row_floor(ref, REPO), 0)

    def test_python_name_key_reference(self):
        with tempfile.TemporaryDirectory() as root:
            with open(os.path.join(root, "budgets.py"), "w", encoding="utf-8") as handle:
                handle.write("FLOORS = {'sidebar_rows_shown': 2.5}\n")
            self.assertEqual(anomaly.row_floor({"path": "budgets.py", "key": "FLOORS/sidebar_rows_shown"}, root), 2.5)

    def test_broken_references_raise_typed_errors(self):
        with self.assertRaises(anomaly.catalog.RefError):
            anomaly.row_floor({"path": "scripts/cmux-next/perf-budgets.json", "key": "/rows/no-such-row/floor"}, REPO)
        with self.assertRaises(anomaly.catalog.RefError):
            anomaly.row_floor({"path": "scripts/perf-lab/missing.json", "key": "/rows/a/floor"}, REPO)
        with self.assertRaises(anomaly.AnomalyError):
            anomaly.row_floor({"target": "key-frame-p50"}, REPO)

    def test_no_reference_is_catapult_default(self):
        self.assertEqual(anomaly.row_floor(None, REPO), anomaly.MIN_ABSOLUTE_CHANGE)


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

    def test_plain_values_are_indexed(self):
        series = _step_series(random.Random(6000), 20, 8, 0.15, base=7.5, noise=0.1)
        self.assertEqual(anomaly.target_miss([y for _, y in series], 8.3).x_value, 20)


class AlertsDetectorSeam(unittest.TestCase):
    """alerts.CatapultDetector, the consumer of this module, driving the real anomaly.py."""

    @classmethod
    def setUpClass(cls):
        cls.alerts = _load("perf_lab_alerts_for_anomaly", os.path.join(LAB, "alerts.py"))
        cls.detector = cls.alerts.CatapultDetector()

    def test_change_points_map_to_value_indexes(self):
        values = [y for _, y in _step_series(random.Random(5100), 20, 8, 0.15)]
        change, = self.detector.change_points(values, {"min_absolute_change": 0.0})
        self.assertLessEqual(change.extended_start, 20)
        self.assertGreaterEqual(change.extended_end, 20)
        self.assertGreater(change.median_after, change.median_before)

    def test_every_config_key_is_a_find_change_points_keyword(self):
        config = {key: getattr(anomaly, key.upper()) for key in self.alerts.ANOMALY_CONFIG_KEYS}
        values = [y for _, y in _step_series(random.Random(5100), 20, 8, 0.15)]
        self.assertEqual(len(self.detector.change_points(values, config)), 1)

    def test_target_miss_takes_plain_values_in_both_directions(self):
        lower = [y for _, y in _step_series(random.Random(6000), 20, 8, 0.15, base=7.5, noise=0.1)]
        self.assertEqual(self.detector.target_miss(lower, 8.3, "lower"), 20)
        higher = [y for _, y in _step_series(random.Random(6004), 20, 10, -0.15, base=125.0, noise=1.0)]
        self.assertEqual(self.detector.target_miss(higher, 118.0, "higher"), 20)
        self.assertIsNone(self.detector.target_miss(higher, 118.0, "lower"))

    def test_change_points_are_newest_first(self):
        values = [y for _, y in _step_series(random.Random(1017), 20, 17, 0.15)]
        starts = [change.extended_start for change in self.detector.change_points(values, {})]
        self.assertEqual(len(starts), 2)
        self.assertEqual(starts, sorted(starts, reverse=True))

    def test_a_parsed_whole_float_config_runs_the_real_detector(self):
        entry, = self.alerts.Subscriptions.parse({"build_configs": ["bench"], "subscriptions": [
            {"name": "x", "kind": "perf-hot", "owner": "A", "match": {"metric": "*"},
             "anomaly_config": {"max_window_size": 40.0, "min_segment_size": 6.0}}]}).entries
        values = [y for _, y in _step_series(random.Random(5100), 20, 8, 0.15)]
        self.assertEqual(len(self.detector.change_points(values, entry.anomaly_config)), 1)


if __name__ == "__main__":
    unittest.main()
