#!/usr/bin/env python3
"""perf-lab statistics: the one place benches, bisect and anomaly detection get their numbers.

- pct(): the one percentile definition (linear interpolation between closest ranks, C = 1), the same
  code as scripts/cmux-next/perf-budgets.py pct (which stays self-contained; a parity test checks it).
- summary(): n, p50, p95, p99, max and IQR of a sample.
- MannWhitneyU(), KolmogorovSmirnov(): catapult Pinpoint's tests, ported line by line (normal
  approximation and asymptotic distribution only; there is no exact-distribution path).
- compare(): catapult Pinpoint's Compare, returning both of its verdicts (see compare()).
- magnitude_from(): Pinpoint's comparison magnitude in multiples of the IQR, with catapult's own
  C = 1/2 IQR (math_utils.Iqr), not pct(), so a Pinpoint threshold row matches catapult's.
- HighThreshold(), LowThreshold(): from pinpoint_thresholds.py (catapult's thresholds.py).

Load it by file path (spec_from_file_location); it needs only the standard library and
pinpoint_thresholds.py next to it.
"""

import bisect
import collections
import importlib.util
import itertools
import math
import os
import sys


def _load_thresholds():
    name = "perf_lab_pinpoint_thresholds"
    if name in sys.modules:
        return sys.modules[name]
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "pinpoint_thresholds.py")
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    sys.modules[name] = module
    return module


_thresholds = _load_thresholds()
HighThreshold = _thresholds.HighThreshold
LowThreshold = _thresholds.LowThreshold


# ---------- percentiles ----------


def pct(values, q):
    """The q-quantile (q in [0, 1]) of the numeric values, linear interpolation; None when empty.

    Same code as perf-budgets.py pct; tests/test_perf_stats.py proves they agree.
    """
    vals = sorted(v for v in values if isinstance(v, (int, float)))
    if not vals:
        return None
    k = (len(vals) - 1) * q
    lo, hi = int(k), min(int(k) + 1, len(vals) - 1)
    return vals[lo] + (vals[hi] - vals[lo]) * (k - lo)


def iqr(values):
    """Interquartile range pct(0.75) - pct(0.25); None when empty."""
    q1, q3 = pct(values, 0.25), pct(values, 0.75)
    return None if q1 is None else q3 - q1


def summary(values):
    """{n, p50, p95, p99, max, iqr} of the numeric values; every statistic is None when n is 0."""
    vals = [v for v in values if isinstance(v, (int, float))]
    return {
        "n": len(vals),
        "p50": pct(vals, 0.50),
        "p95": pct(vals, 0.95),
        "p99": pct(vals, 0.99),
        "max": max(vals) if vals else None,
        "iqr": iqr(vals),
    }


# ---------- catapult Pinpoint statistics ----------
#
# Copyright 2016 and 2018 The Chromium Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file:
#   https://chromium.googlesource.com/catapult/+/HEAD/LICENSE
#
# Ported line by line at catapult commit 0e8f52413a40b5c868739293e784428041275f81:
#   https://github.com/catapult-project/catapult/blob/0e8f52413a40b5c868739293e784428041275f81/dashboard/dashboard/pinpoint/models/compare/mann_whitney_u.py
#   https://github.com/catapult-project/catapult/blob/0e8f52413a40b5c868739293e784428041275f81/dashboard/dashboard/pinpoint/models/compare/kolmogorov_smirnov.py
#   https://github.com/catapult-project/catapult/blob/0e8f52413a40b5c868739293e784428041275f81/dashboard/dashboard/pinpoint/models/compare/compare.py
#   https://github.com/catapult-project/catapult/blob/0e8f52413a40b5c868739293e784428041275f81/dashboard/dashboard/common/math_utils.py
#   https://github.com/catapult-project/catapult/blob/0e8f52413a40b5c868739293e784428041275f81/dashboard/dashboard/pinpoint/models/job_state.py
# The two tests are adapted there from SciPy (BSD-style license):
#   https://github.com/scipy/scipy/blob/master/scipy/stats/stats.py
# There is also a JavaScript version in Catapult:
#   https://github.com/catapult-project/catapult/blob/master/tracing/third_party/mannwhitneyu/mannwhitneyu.js
# Changes from catapult: 4-space indent, and the samples are copied to lists so tuples and lists mix.


# --- math_utils.py (Iqr, Percentile) and job_state.py (_Compare's magnitude) ---


def _PinpointIqr(values):
    """Returns the interquartile range of an iterable of values.

    The quartiles used correspond to "Method 3" in:
      https://en.wikipedia.org/wiki/Quartile
    """
    return _PinpointPercentile(values, 0.75) - _PinpointPercentile(values, 0.25)


def _PinpointPercentile(values, percentile):
    """Returns a percentile of an iterable of values. C = 1/2

    The closest ranks are interpolated as in "C = 1/2" in:
      https://en.wikipedia.org/wiki/Percentile
    """
    values = sorted(values)
    index = float(len(values)) * percentile - 0.5
    floor = max(math.floor(index), 0)
    ceil = min(math.ceil(index), len(values) - 1)
    if floor == ceil:
        return values[int(index)]
    low = values[int(floor)] * (ceil - index)
    high = values[int(ceil)] * (index - floor)
    return low + high


def magnitude_from(delta, values_a, values_b):
    """Pinpoint's comparison magnitude: |delta| / max(Iqr(a), Iqr(b), 0.001), or 1.0 with no delta.

    job_state.py _Compare computes it only when both samples are non-empty; an empty sample counts
    as IQR 0 here.
    """
    if not delta:
        return 1.0
    max_iqr = max(
        max(_PinpointIqr(values_a) if values_a else 0.0, _PinpointIqr(values_b) if values_b else 0.0),
        0.001)
    return abs(delta / max_iqr)


# --- mann_whitney_u.py ---


def MannWhitneyU(x, y):
    """Computes the Mann-Whitney rank test on samples x and y.

    The distribution of U is approximately normal for large samples. This
    implementation uses the normal approximation, so it's recommended to have
    sample sizes > 20.
    """
    x, y = list(x), list(y)
    n1 = len(x)
    n2 = len(y)
    ranked = _RankData(x + y)
    rankx = ranked[0:n1]  # get the x-ranks
    u1 = n1 * n2 + n1 * (n1 + 1) / 2.0 - sum(rankx)  # calc U for x
    u2 = n1 * n2 - u1  # remainder is U for y
    t = _TieCorrectionFactor(ranked)
    if t == 0:
        return 1.0
    sd = math.sqrt(t * n1 * n2 * (n1 + n2 + 1) / 12.0)

    mean_rank = n1 * n2 / 2.0 + 0.5
    big_u = max(u1, u2)

    z = (big_u - mean_rank) / sd
    return 2 * _NormSf(abs(z))


def _RankData(a):
    """Assigns ranks to data. Ties are given the mean of the ranks of the items.

    This is called "fractional ranking":
      https://en.wikipedia.org/wiki/Ranking
    """
    sorter = _ArgSortReverse(a)
    ranked_min = [0] * len(sorter)
    for i, j in reversed(list(enumerate(sorter))):
        ranked_min[j] = i

    sorter = _ArgSort(a)
    ranked_max = [0] * len(sorter)
    for i, j in enumerate(sorter):
        ranked_max[j] = i

    return [1 + (x + y) / 2.0 for x, y in zip(ranked_min, ranked_max)]


def _ArgSort(a):
    """Returns the indices that would sort an array.

    Ties are given indices in ordinal order."""
    return sorted(list(range(len(a))), key=a.__getitem__)


def _ArgSortReverse(a):
    """Returns the indices that would sort an array.

    Ties are given indices in reverse ordinal order."""
    return list(reversed(sorted(list(range(len(a))), key=a.__getitem__, reverse=True)))


def _TieCorrectionFactor(rankvals):
    """Tie correction factor for ties in the Mann-Whitney U test."""
    arr = sorted(rankvals)
    cnt = [len(list(group)) for _, group in itertools.groupby(arr)]
    size = len(arr)
    if size < 2:
        return 1.0
    return 1.0 - sum(x**3 - x for x in cnt) / float(size**3 - size)


def _NormSf(x):
    """Survival function of the standard normal distribution. (1 - cdf)"""
    return (1 - math.erf(x / math.sqrt(2))) / 2


# --- kolmogorov_smirnov.py ---


def KolmogorovSmirnov(x, y):
    """Computes the 2-sample Kolmogorov-Smirnov test.

    This is a two-sided test for the null hypothesis that 2 independent samples
    are drawn from the same continuous distribution.
    """
    n1 = len(x)
    n2 = len(y)
    x = sorted(x)
    y = sorted(y)
    data_all = x + y
    cdf1 = [bisect.bisect(x, value) / float(n1) for value in data_all]
    cdf2 = [bisect.bisect(y, value) / float(n2) for value in data_all]
    d = max(math.fabs(a - b) for a, b in zip(cdf1, cdf2))
    # Note: d absolute not signed distance
    en = math.sqrt(n1 * n2 / float(n1 + n2))
    return _Kolmogorov((en + 0.12 + 0.11 / en) * d)


def _Kolmogorov(y):
    """Survival function of the Kolmogorov-Smirnov two-sided test for large N.

    https://github.com/scipy/scipy/blob/master/scipy/special/cephes/kolmogorov.c
    """
    if y < 1.1e-16:
        return 1.0

    x = -2.0 * y * y
    sign = 1.0
    p = 0.0
    r = 1.0

    while True:
        t = math.exp(x * r * r)
        p += sign * t
        if t == 0.0:
            break
        r += 1.0
        sign = -sign
        if t / p <= 1.1e-16:
            break

    return p + p


# --- compare.py ---

DIFFERENT = 'different'
PENDING = 'pending'
SAME = 'same'
UNKNOWN = 'unknown'

_MIN_HIGH_THRESHOLDS_FUNCTIONAL = 0.10
_MIN_LOW_THRESHOLDS_FUNCTIONAL = 0.05


class ComparisonResults(
        collections.namedtuple('ComparisonResults', ('result', 'p_value', 'low_threshold', 'high_threshold'))):
    __slots__ = ()


class Comparison(collections.namedtuple('Comparison', ('original', 'floored', 'ks_p_value', 'mwu_p_value'))):
    """Both of Pinpoint's verdicts for one comparison, and the two tests' p-values.

    original: catapult's original rule, DIFFERENT p <= LowThreshold() (0.01), UNKNOWN p <= HighThreshold,
      else SAME. Culprit verification and the try receipt's headline use it.
    floored: catapult's "new" rule, thresholds floored at 0.05 and 0.10: DIFFERENT p <= 0.05,
      SAME p > max(HighThreshold, 0.10), else UNKNOWN. Pinpoint returns it when benchmark_arguments is
      set (it only logs it as BisectDebug otherwise); the bisect step uses it.
    """

    __slots__ = ()

    @property
    def p_value(self):
        return self.original.p_value


def compare(values_a, values_b, attempt_count=None, mode='performance', magnitude=1.0):
    """Decide whether two samples are the same, different, or unknown, by both of Pinpoint's rules.

    Arguments:
      values_a: A list of sortable values. They don't need to be numeric.
      values_b: A list of sortable values. They don't need to be numeric.
      attempt_count: The average number of attempts made. None means
        (len(values_a) + len(values_b)) // 2, the sample_count job_state.py passes for performance.
      mode: 'functional' or 'performance'. We use different significance
        thresholds for each type.
      magnitude: An estimate of the size of differences to look for. We need more
        values to find smaller differences. If mode is 'functional', this is the
        failure rate, a float between 0 and 1. If mode is 'performance', this is a
        multiple of the interquartile range (IQR) (see magnitude_from).

    Returns:
      A Comparison with both ComparisonResults:
        DIFFERENT: The samples are unlikely to come from the same
                   distribution, and are therefore likely different. Reject
                   the null hypothesis.
        SAME     : The samples are unlikely to come from distributions that
                   differ by the given magnitude. Cannot reject the null
                   hypothesis.
        UNKNOWN  : Not enough evidence to reject either hypothesis. We should
                   collect more data before making a final decision.
    """
    values_a, values_b = list(values_a), list(values_b)
    if attempt_count is None:
        attempt_count = (len(values_a) + len(values_b)) // 2
    low_threshold = LowThreshold()
    high_threshold = HighThreshold(mode, magnitude, attempt_count)
    new_low_threshold = max(low_threshold, _MIN_LOW_THRESHOLDS_FUNCTIONAL)
    new_high_threshold = max(high_threshold, _MIN_HIGH_THRESHOLDS_FUNCTIONAL)

    if not (len(values_a) > 0 and len(values_b) > 0):
        # A sample has no values in it.
        return Comparison(
            ComparisonResults(UNKNOWN, None, low_threshold, high_threshold),
            ComparisonResults(UNKNOWN, None, new_low_threshold, new_high_threshold), None, None)

    # MWU is bad at detecting changes in variance, and K-S is bad with discrete
    # distributions. So use both. We want low p-values for the below examples.
    #        a                     b               MWU(a, b)  KS(a, b)
    # [0]*20            [0]*15+[1]*5                0.0097     0.4973
    # range(10, 30)     range(10)+range(30, 40)     0.4946     0.0082
    # catapult's MWU column above is stale: it is the one-sided p-value. The code is two-sided
    # (2 * _NormSf) and returns 0.0195 and 0.9892; tests/test_perf_stats.py asserts those.
    kolmogorov_p_value = KolmogorovSmirnov(values_a, values_b)
    mann_p_value = MannWhitneyU(values_a, values_b)
    p_value = min(kolmogorov_p_value, mann_p_value)

    if p_value <= new_low_threshold:
        new_comparison_result = ComparisonResults(DIFFERENT, p_value, new_low_threshold, new_high_threshold)
    elif p_value > new_high_threshold:
        new_comparison_result = ComparisonResults(SAME, p_value, new_low_threshold, new_high_threshold)
    else:
        new_comparison_result = ComparisonResults(UNKNOWN, p_value, new_low_threshold, new_high_threshold)

    if p_value <= low_threshold:
        # The p-value is less than the significance level. Reject the null
        # hypothesis.
        comparison_result = ComparisonResults(DIFFERENT, p_value, low_threshold, high_threshold)
    elif p_value <= high_threshold:
        # The p-value is not less than the significance level, but it's small
        # enough to be suspicious. We'd like to investigate more closely.
        comparison_result = ComparisonResults(UNKNOWN, p_value, low_threshold, high_threshold)
    else:
        # The p-value is quite large. We're not suspicious that the two samples might
        # come from different distributions, and we don't care to investigate more.
        comparison_result = ComparisonResults(SAME, p_value, low_threshold, high_threshold)

    return Comparison(comparison_result, new_comparison_result, kolmogorov_p_value, mann_p_value)
