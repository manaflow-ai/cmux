#!/usr/bin/env python3
"""catapult's E-Divisive approximation, step-likeness score and math helpers, ported line by line.

anomaly.py is the only caller: it runs ClusterAndFindSplit over a series window, then filters the
candidates with catapult's _PassesThresholds (which uses Steppiness and the math helpers here).

Load it by file path (spec_from_file_location); it needs only the standard library.
"""

#
# Copyright 2015 and 2019 The Chromium Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file:
#   https://chromium.googlesource.com/catapult/+/HEAD/LICENSE
#
# Ported line by line at catapult commit 0e8f52413a40b5c868739293e784428041275f81:
#   https://github.com/catapult-project/catapult/blob/0e8f52413a40b5c868739293e784428041275f81/dashboard/dashboard/common/clustering_change_detector.py
#   https://github.com/catapult-project/catapult/blob/0e8f52413a40b5c868739293e784428041275f81/dashboard/dashboard/find_step.py
#   https://github.com/catapult-project/catapult/blob/0e8f52413a40b5c868739293e784428041275f81/dashboard/dashboard/common/math_utils.py
# Changes from catapult:
#   - 4-space indent; logging calls dropped (they only log).
#   - ClusterAndCompare is not ported: nothing in the detector calls it, and the Pinpoint compare it
#     wraps is perf_stats.compare.
#   - PermutationTest needs an explicit rand (catapult falls back to an unseeded random.Random()), so
#     every detection is reproducible; anomaly.py passes a seeded one.
#   - From find_step.py only Steppiness and its helpers; from math_utils.py only what they use.

import itertools
import math

# ---------- clustering_change_detector.py ----------

# This number controls the maximum number of iterations we perform when doing
# permutation testing to identify potential change-points hidden in the
# sub-clustering of values. The higher the number, the more CPU time we're
# likely to spend finding these potential hidden change-points.
_PERMUTATION_TESTING_ITERATIONS = 199

# This is the threshold percentage that permutation testing must meet for us to
# consider the sub-range that might contain a potential change-point.
_MIN_SIGNIFICANCE = 0.95

# The subsampling length is the maximum length we're letting the permutation
# testing use to find potential rearrangements of the underlying data.
_MAX_SUBSAMPLING_LENGTH = 20

# Extend the change range based on the estimate value in the range of tolerance.
_CHANGE_RANGE_TOLERANCE = 0.90


class Error(Exception):
    pass


class InsufficientData(Error):
    pass


def Cluster(sequence, partition_point):
    """Return a tuple (left, right) where partition_point is part of right."""
    return (sequence[:partition_point], sequence[partition_point:])


def Midpoint(sequence):
    """Return an index in the sequence representing the midpoint."""
    return (len(sequence) - 1) // 2


def PermutationTest(sequence, change_point, rand):
    """Run permutation testing on a sequence.

    Determine whether there's a potential change point within the sequence,
    using randomised permutation testing.

    Arguments:
      - sequence: an iterable of values to perform permutation testing on.
      - change_point: the possible change point calculated by Estimator.
      - rand: an implementation of a pseudo-random generator (see random.Random))

    Returns significance of the change point we are testing.
    """
    if len(sequence) < 3:
        return 0.0

    segment_start = max(change_point - (_MAX_SUBSAMPLING_LENGTH // 2), 0)
    segment_end = min(change_point + (_MAX_SUBSAMPLING_LENGTH // 2), len(sequence))
    segment = list(sequence[segment_start:segment_end])
    change_point_q = Estimator(segment, change_point - segment_start)

    # Significance is defined by how many change points in random permutations
    # are less significant than the one we choose. This works because the change
    # point should be less significant if we mixing the left and right part
    # seperated by the point.
    significance = 0
    for _ in range(_PERMUTATION_TESTING_ITERATIONS):
        rand.shuffle(segment)
        _, q, _ = ChangePointEstimator(segment)
        if q < change_point_q:
            significance += 1

    return float(significance) / (_PERMUTATION_TESTING_ITERATIONS + 1)


def Estimator(sequence, index):
    cluster_a, cluster_b = Cluster(sequence, index)
    if len(cluster_a) == 0 or len(cluster_b) == 0:
        return float('NaN')
    a_array = tuple(abs(a - b)**2 for a, b in itertools.combinations(cluster_a, 2))
    if not a_array:
        a_array = (0.,)
    b_array = tuple(abs(a - b)**2 for a, b in itertools.combinations(cluster_b, 2))
    if not b_array:
        b_array = (0.,)
    y = sum(abs(a - b)**2 for a, b in itertools.product(cluster_a, cluster_b))
    x_a = sum(a_array)
    x_b = sum(b_array)
    a_len = len(cluster_a)
    b_len = len(cluster_b)
    a_len_combinations = len(a_array)
    b_len_combinations = len(b_array)
    y_scaler = 2.0 / (a_len * b_len)
    a_estimate = (x_a / a_len_combinations)
    b_estimate = (x_b / b_len_combinations)
    e = (y_scaler * y) - a_estimate - b_estimate
    return (e * a_len * b_len) / (a_len + b_len)


def ChangePointEstimator(sequence):
    # This algorithm does the following:
    #   - For each element in the sequence:
    #     - Partition the sequence into two clusters (X[a], X[b])
    #     - Compute the intra-cluster distances squared (X[n])
    #     - Scale the intra-cluster distances by the number of intra-cluster
    #       pairs. (X'[n] = X[n] / combinations(|X[n]|, 2) )
    #     - Compute the inter-cluster distances squared (Y)
    #     - Scale the inter-cluster distances by the number of total pairs
    #       multiplied by 2 (Y' = (Y * 2) / |X[a]||X[b]|)
    #     - Sum up as: Y' - X'[a] - X'[b]
    #   - Return the index of the highest estimator.
    #
    # The computation is based on Euclidean distances between measurements
    # within and across clusters to show the likelihood that the values on
    # either side of a sequence is likely to show a divergence.
    #
    # This algorithm is O(N^2) to the size of the sequence.
    margin = 1
    max_estimate = None
    max_index = 0
    estimates = [Estimator(sequence, i) for i, _ in enumerate(sequence) if margin <= i < len(sequence)]
    if not estimates:
        return (0, 0, False)
    for index, estimate in enumerate(estimates):
        if max_estimate is None or estimate > max_estimate:
            max_estimate = estimate
            max_index = index
    return (max_index + margin, max_estimate, True)


def ExtendChangePointRange(change_point, sequence):
    max_estimate = Estimator(sequence, change_point)

    left, right = 1, len(sequence) - 1

    for index in range(change_point, 0, -1):
        if Estimator(sequence, index) < _CHANGE_RANGE_TOLERANCE * max_estimate:
            left = index + 1
            break

    for index in range(change_point, len(sequence) - 1):
        if Estimator(sequence, index) < _CHANGE_RANGE_TOLERANCE * max_estimate:
            right = index - 1
            break

    return (left, right)


def ClusterAndFindSplit(values, rand):
    """Finds a list of indices where we can detect significant changes.

    This algorithm looks for the point at which clusterings of the "left" and
    "right" datapoints show a significant difference. We understand that this
    algorithm is working on potentially already-aggregated data (means, etc.) and
    it would work better if we had access to all the underlying data points, but
    for now we can do our best with the points we have access to.

    In the E-Divisive paper, this is a two-step process: first estimate potential
    change points, then test whether the clusters partitioned by the proposed
    change point internally has potentially hidden change-points through random
    permutation testing. Because the current implementation only returns a single
    change-point, we do the change point estimation through bisection, and use the
    permutation testing to identify whether we should continue the bisection, not
    to find all potential change points.

    Arguments:
      - values: a sequence of values in time series order.
      - rand: a random.Random used for subsequence permutation testing.

    Returns:
      - A sorted list of (index, (extended_start, extended_end)) into values
        where we can detect potential split points.

    Raises:
      - InsufficientData when the algorithm cannot find potential change points
        with statistical significance testing.
    """
    length = len(values)
    if length <= 3:
        raise InsufficientData('Sequence is not larger than minimum length (%s <= %s)' % (length, 3))
    candidate_indices = set()
    exploration_queue = [(0, length)]
    while exploration_queue:
        # Find the most likely change point in the whole range, only excluding the
        # first and last elements. We're doing this because we want to still be able
        # to pick a candidate within the margins (excluding the ends) if we have
        # enough confidence that it is a change point.
        start, end = exploration_queue.pop(0)
        segment = values[start:end]

        partition_point, _, _ = ChangePointEstimator(segment)
        probability = PermutationTest(segment, partition_point, rand)
        if probability < _MIN_SIGNIFICANCE:
            continue
        lower, upper = ExtendChangePointRange(partition_point, segment)
        candidate_indices.add((start + partition_point, (start + lower, start + upper)))

        exploration_queue.append((start, start + partition_point))
        exploration_queue.append((start + partition_point, end))

    if not candidate_indices:
        raise InsufficientData('Not enough data to suggest a change point.')
    return list(sorted(candidate_indices))


# ---------- find_step.py ----------


def Steppiness(values, step_index):
    """Returns a number between 0 and 1 that indicates how step-like |values| is.

    Args:
      values: A list of numbers. Should have non-zero variance, non-zero length.
      step_index: An index in values.

    Returns:
      A number between zero and one that indicates how similar the shape of the
      given series is to a step function.
    """
    normalized = _Normalize(values)
    return 1.0 - _DistanceFromStep(normalized, step_index)


def _Normalize(values):
    """Makes a series with the same shape but with variance = 1, mean = 0."""
    mean = Mean(values)
    zeroed = [x - mean for x in values]
    stddev = StandardDeviation(zeroed)
    return [Divide(x, stddev) for x in zeroed]


def _DistanceFromStep(values, step_index):
    """Returns the root-mean-square deviation from a step function."""
    step_values = _StepFunctionValues(values, step_index)
    return _RootMeanSquareDeviation(values, step_values)


def _StepFunctionValues(values, step_index):
    """Makes values for a step function corresponding to |values|."""
    left, right = values[:step_index], values[step_index:]
    step_left = len(left) * [Mean(left)]
    step_right = len(right) * [Mean(right)]
    return step_left + step_right


def _RootMeanSquareDeviation(values1, values2):
    """Returns the root-mean-square deviation between two lists of values."""
    if len(values1) == 0:
        return 0.0
    return math.sqrt(_SumOfSquaredResiduals(values1, values2) / len(values1))


def _SumOfSquaredResiduals(values1, values2):
    """Returns the sum of the squared deviations between corresponding values."""
    return sum((v1 - v2)**2 for v1, v2 in zip(values1, values2))


# ---------- math_utils.py ----------


def Mean(values):
    """Returns the arithmetic mean, or NaN if the input is empty."""
    return Divide(sum(values), len(values))


def Median(values):
    """Returns the median, or NaN if the input is empty."""
    if not values:
        return float('nan')
    sorted_values = sorted(values)
    mid, mod = divmod(len(values), 2)
    if mod == 1:
        return float(sorted_values[mid])
    return (sorted_values[mid - 1] + sorted_values[mid]) / 2.0


def Variance(values):
    """Returns the population variance, or NaN if the input is empty."""
    if not values:
        return float('nan')
    mean = Mean(values)
    return Mean([(x - mean)**2 for x in values])


def StandardDeviation(values):
    """Returns the population std. dev., or NaN if the input is empty."""
    if not values:
        return float('nan')
    return math.sqrt(Variance(values))


def Divide(a, b):
    """Returns the quotient, or NaN if the divisor is zero."""
    if b == 0:
        return float('nan')
    return a / float(b)


def RelativeChange(before, after):
    """Returns the absolute value of the relative change between two values.

    Args:
      before: First value.
      after: Second value.

    Returns:
      Relative change from the first to the second value, or infinity if the
      first value is zero. This is guaranteed to be non-negative.
    """
    return abs((after - before) / float(before)) if before else float('inf')
