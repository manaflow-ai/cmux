#!/usr/bin/env python3
"""perf-lab change-point alerts: catapult's find_change_points with catapult's defaults, and target_miss.

- find_change_points(): catapult `dashboard/dashboard/find_change_points.py` FindChangePoints. It runs
  the E-Divisive approximation (anomaly_edivisive.ClusterAndFindSplit) over the newest
  MAX_WINDOW_SIZE points, then keeps the candidates that pass _PassesThresholds, newest first.
- detect(): find_change_points on one series, split by the series' better direction into
  regressions (alerts) and improvements (recorded, never alerted).
- series_from_points(): one point per run, the median of its samples (or its p99, a separate series),
  from store.Point rows.
- row_floor(): MIN_ABSOLUTE_CHANGE for a series is the floor of its threshold row, read by reference
  (target_ref path + key) from the existing threshold file, never copied (p12 rule R4).
- target_miss(): the second rule, for the 12 fixed program targets: the newest segment (at least
  MIN_SEGMENT_SIZE points) has a median past the target and the segment before it did not.

The detection is reproducible: the permutation test draws from random.Random(DEFAULT_SEED) unless the
caller passes its own generator (catapult uses an unseeded one).

Load it by file path (spec_from_file_location); it needs only the standard library and
anomaly_edivisive.py and perf_stats.py next to it.
"""

#
# Copyright 2015 and 2021 The Chromium Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file:
#   https://chromium.googlesource.com/catapult/+/HEAD/LICENSE
#
# find_change_points, _passes_thresholds and the constants are ported line by line at catapult
# commit 0e8f52413a40b5c868739293e784428041275f81:
#   https://github.com/catapult-project/catapult/blob/0e8f52413a40b5c868739293e784428041275f81/dashboard/dashboard/find_change_points.py
#   https://github.com/catapult-project/catapult/blob/0e8f52413a40b5c868739293e784428041275f81/dashboard/dashboard/common/defaults.py
# (mirrored in AnomalyConfig, dashboard/dashboard/protobuf/sheriff.proto).
# Changes from catapult: ChangePoint drops the Welch's t-test fields (catapult only stores them; no
# filter reads them) and adds the window index of the split; logging calls are dropped.

import collections
import importlib.util
import json
import os
import random
import re
import sys


def _load_sibling(name, filename):
    if name in sys.modules:
        return sys.modules[name]
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), filename)
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


edivisive = _load_sibling("perf_lab_anomaly_edivisive", "anomaly_edivisive.py")
perf_stats = _load_sibling("perf_lab_perf_stats", "perf_stats.py")


# ---------- catapult defaults.py ----------

# Maximum number of points to consider at one time.
MAX_WINDOW_SIZE = 50

# Minimum number of points in a segment. This can help filter out erroneous
# results by ignoring results that were found from looking at too few points.
MIN_SEGMENT_SIZE = 6

# Minimum absolute difference between medians before and after. The lab passes
# the series' threshold-row floor instead (row_floor); this is catapult's default.
MIN_ABSOLUTE_CHANGE = 0

# Minimum relative difference between medians before and after.
MIN_RELATIVE_CHANGE = 0.1

# "Steppiness" is a number between 0 and 1 that indicates how similar the
# shape is to a perfect step function, where 1 represents a step function.
MIN_STEPPINESS = 0.5

# The "standard deviation" is based on a subset of points in the series.
# This parameter is the minimum acceptable ratio of the relative change
# and this standard deviation.
MULTIPLE_OF_STD_DEV = 2.5

# The seed of the permutation test's generator when the caller passes none (catapult's tests use 1).
DEFAULT_SEED = 1

# The per-run point statistic of each series kind: the median, and the p99 as a separate series.
POINT_STATISTICS = {"p50": 0.50, "p99": 0.99}

BETTER_DIRECTIONS = ("lower", "higher")


class AnomalyError(ValueError):
    """A detector input is malformed (unknown direction or statistic, unresolvable threshold row)."""


class ChangePoint(
        collections.namedtuple(
            'ChangePoint',
            (
                # The x-value of the first point after a step.
                'x_value',
                # The index of that point in the window.
                'index',
                # Median of the segments before and after the change point.
                'median_before',
                'median_after',
                # Number of points before and after the change point.
                'size_before',
                'size_after',
                # X-values of the first and last point in the series window used.
                'window_start',
                'window_end',
                # Relative change from before to after.
                'relative_change',
                # Standard deviation of points before.
                'std_dev_before',
                # Extended possible change point range
                'extended_start',
                'extended_end',
            ))):
    """A ChangePoint represents a change in a series -- a potential alert."""

    __slots__ = ()

    def AsDict(self):
        """Returns a dictionary mapping attributes to values."""
        return self._asdict()


class Detection(collections.namedtuple('Detection', ('regressions', 'improvements'))):
    """detect()'s result: regressions alert; improvements are recorded only. Both newest first."""

    __slots__ = ()


class TargetMiss(
        collections.namedtuple('TargetMiss', ('x_value', 'target', 'better', 'median_before', 'median_after'))):
    """The newest segment crossed a fixed target: x_value is its first point."""

    __slots__ = ()


# ---------- catapult find_change_points.py ----------


def find_change_points(series,
                       max_window_size=MAX_WINDOW_SIZE,
                       min_segment_size=MIN_SEGMENT_SIZE,
                       min_absolute_change=MIN_ABSOLUTE_CHANGE,
                       min_relative_change=MIN_RELATIVE_CHANGE,
                       min_steppiness=MIN_STEPPINESS,
                       multiple_of_std_dev=MULTIPLE_OF_STD_DEV,
                       rand=None):
    """Finds change points in the given series.

    Only the last |max_window_size| points are examined, regardless of how many
    points are passed in. The reason why it might make sense to limit the number
    of points to look at is that if there are multiple change-points in the window
    that's looked at, then this function will be less likely to find any of them.

    This uses a clustering change detector (an approximation of E-divisive) in
    anomaly_edivisive.

    Args:
      series: A list of (x, y) pairs.
      max_window_size: Number of points to analyze.
      min_segment_size: Min size of segments before or after change point.
      min_absolute_change: Absolute change threshold.
      min_relative_change: Relative change threshold.
      min_steppiness: Threshold for how similar to a step a change point must be.
      multiple_of_std_dev: Threshold for change as multiple of std. deviation.
      rand: The permutation test's random.Random; None means random.Random(DEFAULT_SEED).

    Returns:
      A list of zero to many ChangePoint object(s), newest first.
    """
    if len(series) < 2:
        return []  # Not enough points to possibly contain a valid split point.
    series = list(series)[-max_window_size:]
    _, y_values = list(zip(*series))

    change_points = []
    for point in reversed(candidate_points(y_values, rand)):
        passed_filter, _ = passes_thresholds(
            y_values,
            point[0],
            min_segment_size=min_segment_size,
            min_absolute_change=min_absolute_change,
            min_relative_change=min_relative_change,
            min_steppiness=min_steppiness,
            multiple_of_std_dev=multiple_of_std_dev)
        if passed_filter:
            change_points.append(point)

    return [make_change_point(series, point) for point in change_points]


def candidate_points(y_values, rand=None):
    """The E-Divisive candidates [(index, (extended_start, extended_end))], oldest first; [] if none."""
    if rand is None:
        rand = random.Random(DEFAULT_SEED)
    try:
        return edivisive.ClusterAndFindSplit(y_values, rand)
    except edivisive.InsufficientData:
        return []


def make_change_point(series, point):
    """Makes a ChangePoint object for the given series at the given point.

    Args:
      series: A list of (x, y) pairs.
      point: (index of the first point after the split, (extended_start, extended_end)).

    Returns:
      A ChangePoint object.
    """
    split_index, (lower, upper) = point
    assert 0 <= split_index < len(series)
    x_values, y_values = list(zip(*series))
    left, right = y_values[:split_index], y_values[split_index:]
    left_median, right_median = edivisive.Median(left), edivisive.Median(right)
    return ChangePoint(
        x_value=x_values[split_index],
        index=split_index,
        median_before=left_median,
        median_after=right_median,
        size_before=len(left),
        size_after=len(right),
        window_start=x_values[0],
        window_end=x_values[-1],  # inclusive bound
        relative_change=edivisive.RelativeChange(left_median, right_median),
        std_dev_before=edivisive.StandardDeviation(left),
        extended_start=x_values[lower],
        extended_end=x_values[upper],
    )


def passes_thresholds(values, split_index, min_segment_size, min_absolute_change, min_relative_change,
                      min_steppiness, multiple_of_std_dev):
    """Checks whether a point in a series appears to be an change point (catapult _PassesThresholds).

    Args:
      values: A list of numbers.
      split_index: An index in the list of numbers.
      min_segment_size: Threshold for size of segments before or after a point.
      min_absolute_change: Minimum absolute median change threshold.
      min_relative_change: Minimum relative median change threshold.
      min_steppiness: Threshold for how similar to a step a change point must be.
      multiple_of_std_dev: Threshold for change as multiple of std. deviation.

    Returns:
      A tuple of (bool, string) where the bool indicates whether the split index
      passes the thresholds and the string being the reason it did not.
    """
    left, right = values[:split_index], values[split_index:]
    left_median, right_median = edivisive.Median(left), edivisive.Median(right)

    # 1. Segment size filter.
    if len(left) < min_segment_size or len(right) < min_segment_size:
        return (False, 'min_segment_size')

    # 2. Absolute change filter.
    absolute_change = abs(left_median - right_median)
    if absolute_change < min_absolute_change:
        return (False, 'min_absolute_change')

    # 3. Relative change filter.
    relative_change = edivisive.RelativeChange(left_median, right_median)
    if relative_change < min_relative_change:
        return (False, 'min_relative_change')

    # 4. Multiple of standard deviation filter.
    min_std_dev = min(edivisive.StandardDeviation(left), edivisive.StandardDeviation(right))
    if absolute_change < multiple_of_std_dev * min_std_dev:
        return (False, 'min_std_dev')

    # 5. Steppiness filter.
    steppiness = edivisive.Steppiness(values, split_index)
    if steppiness < min_steppiness:
        return (False, 'min_steppiness')

    # Passed all filters!
    return (True, 'passed')


# ---------- the lab's use of it ----------


def is_regression(change_point, better):
    """True when the change point moves the median the wrong way for `better` ('lower' or 'higher')."""
    _check_better(better)
    if better == "lower":
        return change_point.median_after > change_point.median_before
    return change_point.median_after < change_point.median_before


def detect(series, better, min_absolute_change=MIN_ABSOLUTE_CHANGE, rand=None):
    """find_change_points with catapult's defaults and the row floor; improvements are not alerts.

    Args:
      series: A list of (x, y) pairs, oldest first (series_from_points).
      better: 'lower' or 'higher', the series' improvement direction.
      min_absolute_change: The series' threshold-row floor (row_floor).
      rand: As in find_change_points.
    """
    _check_better(better)
    points = find_change_points(series, min_absolute_change=min_absolute_change, rand=rand)
    regressions = [p for p in points if is_regression(p, better)]
    improvements = [p for p in points if not is_regression(p, better)]
    return Detection(regressions, improvements)


def point_value(samples, statistic="p50"):
    """One run's point: the median of its samples ('p50') or their p99 ('p99'), perf_stats.pct."""
    if statistic not in POINT_STATISTICS:
        raise AnomalyError(f"statistic {statistic!r} is not one of {', '.join(POINT_STATISTICS)}")
    value = perf_stats.pct(samples, POINT_STATISTICS[statistic])
    if value is None:
        raise AnomalyError("a run point needs at least one numeric sample")
    return value


def series_from_points(points, statistic="p50"):
    """[(commit_pos, point_value)] from store.Point rows (store.series_points order, oldest first)."""
    return [(point.commit_pos, point_value(point.samples, statistic)) for point in points]


def row_floor(target_ref, repo_root):
    """MIN_ABSOLUTE_CHANGE for a series: the `floor` of the threshold row its target_ref names.

    target_ref is a perf_result.TargetRef or its dict form with `path` (repository-relative threshold
    file with a `rows` object, such as scripts/cmux-next/perf-budgets.json) and `key`. The key is a row
    name: the exact row key, else the first row pattern that full-matches it (perf-budgets.py's rule).
    None, or a ref without a path (a targets.json id), or a row without a floor gives catapult's default.
    """
    if target_ref is None:
        return MIN_ABSOLUTE_CHANGE
    ref = target_ref if isinstance(target_ref, dict) else target_ref.to_dict()
    path, key = ref.get("path"), ref.get("key")
    if path is None:
        return MIN_ABSOLUTE_CHANGE
    if not key:
        raise AnomalyError(f"target_ref {ref!r} names a file but no row key")
    file_path = os.path.join(repo_root, path)
    try:
        with open(file_path, encoding="utf-8") as handle:
            rows = json.load(handle).get("rows")
    except (OSError, ValueError, AttributeError) as error:
        raise AnomalyError(f"threshold file {path}: {error}") from error
    if not isinstance(rows, dict):
        raise AnomalyError(f"threshold file {path} has no rows object")
    row = rows.get(key)
    if row is None:
        row = next((spec for pattern, spec in rows.items() if re.fullmatch(pattern, key)), None)
    if row is None:
        raise AnomalyError(f"threshold file {path} has no row for {key!r}")
    return row.get("floor", MIN_ABSOLUTE_CHANGE)


def target_miss(series, target, better="lower", rand=None):
    """The newest segment's median crosses the fixed target and the segment before it did not.

    Segments are the window's E-Divisive candidates (the significance-tested splits, before the
    _PassesThresholds filters: a target crossing needs no 10 % step), newest first, keeping only a
    split that leaves at least MIN_SEGMENT_SIZE points on both sides of it.

    Args:
      series: A list of (x, y) pairs, or of plain values (x is then the value's index; this is how
        alerts.CatapultDetector calls it), oldest first.
      target: The fixed target value, in the series' unit.
      better: 'lower' (a miss is a median above the target) or 'higher' (below it).
      rand: As in find_change_points.

    Returns:
      A TargetMiss, or None.
    """
    _check_better(better)
    window = _as_pairs(series)[-MAX_WINDOW_SIZE:]
    if len(window) < 2 * MIN_SEGMENT_SIZE:
        return None
    x_values, y_values = list(zip(*window))
    splits = []
    end = len(y_values)
    for index, _ in reversed(candidate_points(y_values, rand)):
        if end - index >= MIN_SEGMENT_SIZE and index >= MIN_SEGMENT_SIZE:
            splits.append(index)
            end = index
            if len(splits) == 2:
                break
    if not splits:
        return None
    newest_start = splits[0]
    previous_start = splits[1] if len(splits) > 1 else 0
    median_after = edivisive.Median(y_values[newest_start:])
    median_before = edivisive.Median(y_values[previous_start:newest_start])
    if better == "lower":
        crossed = median_after > target >= median_before
    else:
        crossed = median_after < target <= median_before
    if not crossed:
        return None
    return TargetMiss(x_values[newest_start], target, better, median_before, median_after)


def _as_pairs(series):
    """(x, y) pairs from a list of pairs or of plain numbers (enumerated)."""
    series = list(series)
    if series and isinstance(series[0], (int, float)):
        return list(enumerate(series))
    return series


def _check_better(better):
    if better not in BETTER_DIRECTIONS:
        raise AnomalyError(f"better {better!r} is not one of {', '.join(BETTER_DIRECTIONS)}")
