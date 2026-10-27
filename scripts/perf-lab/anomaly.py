#!/usr/bin/env python3
"""perf-lab change-point alerts: catapult's find_change_points with catapult's defaults, and target_miss.

- find_change_points(): catapult `dashboard/dashboard/find_change_points.py` FindChangePoints. It runs
  the E-Divisive approximation (anomaly_edivisive.ClusterAndFindSplit) over the newest
  MAX_WINDOW_SIZE points, then keeps the candidates that pass _PassesThresholds, newest first.
- row_floor(): MIN_ABSOLUTE_CHANGE for a series is its catalog metric's floor_ref (stories.d), the
  threshold row's noise floor read by reference with catalog.resolve_ref, never copied (p12 rule R4).
- target_miss(): the second rule, for the 12 fixed program targets: the newest segment (at least
  MIN_SEGMENT_SIZE points) has a median past the target and the segment before it did not.

alerts.py is the consumer: it computes the per-run points (median, p99 as a separate series), passes
each series' row_floor as min_absolute_change, and records improvements without alerting them.

The detection is reproducible: the permutation test draws from random.Random(DEFAULT_SEED) unless the
caller passes its own generator (catapult uses an unseeded one).

Load it by file path (spec_from_file_location); it needs only the standard library and
anomaly_edivisive.py and catalog.py next to it.
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
import os
import random
import sys
from pathlib import Path


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
catalog = _load_sibling("perf_lab_catalog", "catalog.py")


# ---------- catapult defaults.py ----------

# Maximum number of points to consider at one time.
MAX_WINDOW_SIZE = 50

# Minimum number of points in a segment. This can help filter out erroneous
# results by ignoring results that were found from looking at too few points.
MIN_SEGMENT_SIZE = 6

# Minimum absolute difference between medians before and after. alerts.py passes
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

BETTER_DIRECTIONS = ("lower", "higher")


class AnomalyError(ValueError):
    """A detector input is malformed (an unknown direction, a window or segment size that is not a count)."""


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
    _check_count("max_window_size", max_window_size, least=1)
    _check_count("min_segment_size", min_segment_size, least=0)
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


def row_floor(floor_ref, repo_root):
    """MIN_ABSOLUTE_CHANGE for a series: the number its catalog metric's floor_ref names.

    floor_ref is a catalog.Ref or its {"path", "key"} dict, as stories.d writes it: a JSON pointer into a
    .json threshold file ({"path": "scripts/cmux-next/perf-budgets.json", "key": "/rows/<pattern>/floor"})
    or NAME/key in a .py file. catalog.resolve_ref reads it (raising catalog.RefError); None gives
    catapult's default.
    """
    if floor_ref is None:
        return MIN_ABSOLUTE_CHANGE
    if isinstance(floor_ref, dict):
        if set(floor_ref) != {"path", "key"}:
            raise AnomalyError(f"floor_ref {floor_ref!r} is not a {{path, key}} reference")
        floor_ref = catalog.Ref(floor_ref["path"], floor_ref["key"])
    return catalog.resolve_ref(Path(repo_root), floor_ref)


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


def _check_count(name, value, least):
    if isinstance(value, bool) or not isinstance(value, int) or value < least:
        raise AnomalyError(f"{name} {value!r} is not an integer of at least {least}")


def _check_better(better):
    if better not in BETTER_DIRECTIONS:
        raise AnomalyError(f"better {better!r} is not one of {', '.join(BETTER_DIRECTIONS)}")
