#!/usr/bin/env python3
"""Compare one Nightly's field histograms with the Nightlies before it. Run by hand, never in CI.

Input is the read-only export of schema-3 hang reports (p09-observability.md section 3D, task 126):

  DATABASE_URL=... bun web/scripts/hang-reports-histograms.ts --days 30 > nightlies.json
  python3 scripts/cmux-next/field-histograms.py nightlies.json [--nightly BUILD] [--baselines 3]

For every catalog histogram and each of p50, p95 and p99, it compares Nightly N (the newest build, or
--nightly) with Nightlies N-1..N-3 pooled. The interval is a 95% bootstrap interval of the relative change,
resampling installs on both sides (one install's launches are not independent samples). A row is named a
regression when the change is above --threshold (10%) and the whole interval is above zero, so it is both
large and outside what resampling the same installs produces. Chromium's perf dashboard asks the same two
things of a step (catapult dashboard/dashboard/find_change_points.py: a minimum relative size and a
significance test); Chromium's base/metrics/histogram.cc keeps only bucket counts, as these reports do, so
percentiles are read from the merged buckets with linear interpolation inside a bucket.

A higher value is worse for every compared unit (durations, sizes, counts, percents). Enumeration and
Chromium-bucketed histograms have no ordered value and are skipped. Names outside ^[a-z0-9_.]{1,64}$ are
ignored, as the server drops them (task 064).

  --self-test   plants a 20% p95 regression in synthetic Nightlies and checks it is named, that noise-only
                Nightlies name nothing, and that the bucket edges match cmux-tui-core diagnostics.rs.
"""

import argparse
import json
import random
import re
import sys

EXPORT_FORMAT = "cmux-hang-report-histograms/1"
NAME_PATTERN = re.compile(r"^[a-z0-9_.]{1,64}$")
QUANTILES = (("p50", 0.50), ("p95", 0.95), ("p99", 0.99))

# How bucket indices map to values, by the wire unit (HistogramID.Unit, task 063). Log-linear units use the
# 4-sub-bucket layout shared by CmuxNextMetrics (task 052) and cmux-tui-core diagnostics.rs (task 131).
LOG_LINEAR_UNITS = {"us", "microseconds", "ms", "milliseconds", "kib", "kibibytes", "count"}
LINEAR_UNITS = {"percent", "pct"}
SUB_BUCKETS_LOG2 = 2
SUB_BUCKETS = 1 << SUB_BUCKETS_LOG2


class ExportError(Exception):
    """The input is not a hang-reports-histograms.ts export."""


def log_linear_index(value):
    """diagnostics.rs LogLinearHistogram::bucket_index."""
    if value < SUB_BUCKETS:
        return value
    octave = value.bit_length() - 1
    sub = (value >> (octave - SUB_BUCKETS_LOG2)) & (SUB_BUCKETS - 1)
    return octave * SUB_BUCKETS + sub


def bucket_range(unit, index):
    """The half-open value range [low, high) that bucket `index` of `unit` covers."""
    if unit in LINEAR_UNITS or index < SUB_BUCKETS:
        return float(index), float(index + 1)
    octave, sub = divmod(index, SUB_BUCKETS)
    width = 1 << (octave - SUB_BUCKETS_LOG2)
    low = (1 << octave) + sub * width
    return float(low), float(low + width)


def compared_unit(unit):
    return unit in LOG_LINEAR_UNITS or unit in LINEAR_UNITS


def quantile(unit, buckets, fraction):
    """The `fraction` quantile of sorted (index, count) pairs, interpolated inside its bucket."""
    total = sum(count for _, count in buckets)
    if total == 0:
        return None
    rank = fraction * total
    seen = 0
    for index, count in buckets:
        if count and seen + count >= rank:
            low, high = bucket_range(unit, index)
            return low + (high - low) * (rank - seen) / count
        seen += count
    return bucket_range(unit, buckets[-1][0])[1]


def merge(parts):
    """Sum per-install {index: count} maps into sorted (index, count) pairs."""
    merged = {}
    for part in parts:
        for index, count in part.items():
            merged[index] = merged.get(index, 0) + count
    return sorted(merged.items())


def version_key(text):
    head = (text or "").split("-")[0]
    return tuple(int(part) if part.isdigit() else 0 for part in head.split("."))


def nightly_key(report):
    """A Nightly is one build; builds sort by version, then by build number."""
    build = str(report.get("build") or "")
    return (version_key(report.get("version")), version_key(build), build)


def load_export(document):
    if not isinstance(document, dict) or document.get("format") != EXPORT_FORMAT:
        raise ExportError(f"expected an export with format {EXPORT_FORMAT!r}")
    reports = document.get("reports")
    if not isinstance(reports, list):
        raise ExportError("reports is not a list")
    return reports


def install_histograms(reports):
    """{nightly: {name: (unit, {install: {index: count}})}} for the compared units."""
    nightlies = {}
    for report in reports:
        install = report.get("install")
        if not install:
            continue
        names = nightlies.setdefault(nightly_key(report), {})
        for histogram in report.get("histograms") or []:
            name, unit = histogram.get("name"), histogram.get("unit")
            if not isinstance(name, str) or not NAME_PATTERN.match(name) or not compared_unit(unit):
                continue
            entry = names.setdefault(name, (unit, {}))
            if entry[0] != unit:
                continue  # a catalog unit change: compare only the unit seen first
            counts = entry[1].setdefault(install, {})
            for pair in histogram.get("buckets") or []:
                index, count = int(pair[0]), int(pair[1])
                if index >= 0 and count > 0:
                    counts[index] = counts.get(index, 0) + count
    return nightlies


def pooled(nightlies, keys, name):
    """One side's unit and per-install bucket maps for `name` across `keys` (an install's Nightlies merge)."""
    unit, installs = None, {}
    for key in keys:
        entry = nightlies.get(key, {}).get(name)
        if entry is None:
            continue
        unit = unit or entry[0]
        if entry[0] != unit:
            continue
        for install, counts in entry[1].items():
            target = installs.setdefault(install, {})
            for index, count in counts.items():
                target[index] = target.get(index, 0) + count
    return unit, list(installs.values())


def resample(rng, parts):
    return merge(rng.choice(parts) for _ in parts)


def percentile(sorted_values, fraction):
    position = fraction * (len(sorted_values) - 1)
    low = int(position)
    high = min(low + 1, len(sorted_values) - 1)
    return sorted_values[low] + (sorted_values[high] - sorted_values[low]) * (position - low)


def compare(unit, target, baseline, iterations, rng):
    """Per quantile: (target value, baseline value, change, interval low, interval high)."""
    target_merged, baseline_merged = merge(target), merge(baseline)
    changes = {label: [] for label, _ in QUANTILES}
    for _ in range(iterations):
        target_sample, baseline_sample = resample(rng, target), resample(rng, baseline)
        for label, fraction in QUANTILES:
            new, old = quantile(unit, target_sample, fraction), quantile(unit, baseline_sample, fraction)
            if new is not None and old:
                changes[label].append(new / old - 1)
    rows = {}
    for label, fraction in QUANTILES:
        new, old = quantile(unit, target_merged, fraction), quantile(unit, baseline_merged, fraction)
        values = sorted(changes[label])
        if new is None or not old or not values:
            continue
        rows[label] = (new, old, new / old - 1, percentile(values, 0.025), percentile(values, 0.975))
    return rows


def analyze(reports, nightly=None, baselines=3, threshold=0.10, iterations=1000, min_installs=5, seed=1):
    nightlies = install_histograms(reports)
    order = sorted(nightlies)
    if nightly is not None:
        matches = [key for key in order if key[2] == nightly]
        if not matches:
            raise ExportError(f"no reports from build {nightly}")
        position = order.index(matches[0])
    else:
        position = len(order) - 1
    if position < 1:
        raise ExportError("need the target Nightly and at least one earlier Nightly")
    target_key = order[position]
    baseline_keys = order[max(0, position - baselines):position]
    rng = random.Random(seed)
    result = {
        "nightly": target_key[2],
        "baselines": [key[2] for key in baseline_keys],
        "threshold": threshold,
        "rows": [],
        "skipped": [],
    }
    names = sorted(set(nightlies[target_key]) | {name for key in baseline_keys for name in nightlies[key]})
    for name in names:
        unit, target = pooled(nightlies, [target_key], name)
        baseline_unit, baseline = pooled(nightlies, baseline_keys, name)
        if unit is None or baseline_unit != unit:
            result["skipped"].append({"name": name, "reason": "missing on one side or unit changed"})
            continue
        if len(target) < min_installs or len(baseline) < min_installs:
            result["skipped"].append({"name": name, "reason": f"installs {len(target)} vs {len(baseline)}, "
                                                              f"need {min_installs} on each side"})
            continue
        for label, (new, old, change, low, high) in compare(unit, target, baseline, iterations, rng).items():
            result["rows"].append({
                "name": name, "unit": unit, "quantile": label, "nightly": new, "baseline": old,
                "change": change, "interval": [low, high],
                "installs": [len(target), len(baseline)],
                "regression": change > threshold and low > 0,
            })
    return result


def print_text(result, show_all):
    print(f"Nightly {result['nightly']} against {', '.join(result['baselines'])} "
          f"(regression: > {result['threshold']:.0%} and the 95% interval above 0)")
    rows = result["rows"] if show_all else [row for row in result["rows"] if row["regression"]]
    if not rows:
        print("no regressions" if not show_all else "no comparable histograms")
    for row in rows:
        low, high = row["interval"]
        mark = "REGRESSION " if row["regression"] else ""
        print(f"  {mark}{row['name']} {row['quantile']}: {row['baseline']:.1f} -> {row['nightly']:.1f} {row['unit']} "
              f"({row['change']:+.1%}, 95% [{low:+.1%}, {high:+.1%}], installs {row['installs'][0]} vs "
              f"{row['installs'][1]})")
    for skipped in result["skipped"]:
        print(f"  skipped {skipped['name']}: {skipped['reason']}")


# ---------------------------------------------------------------- self-test

def synthetic_reports(rng, nightlies, installs, scale_by_nightly):
    """Reports where each install's samples are log-normal around its own speed, bucketed like the app."""
    reports = []
    for nightly in range(nightlies):
        for install in range(installs):
            speed = rng.lognormvariate(0, 0.15)
            histograms = []
            for name, unit, median in (("key.frame.view", "us", 4000), ("main.turn", "us", 900)):
                scale = scale_by_nightly.get((nightly, name), 1.0)
                counts = {}
                for _ in range(150):
                    value = int(median * speed * scale * rng.lognormvariate(0, 0.6))
                    index = log_linear_index(value)
                    counts[index] = counts.get(index, 0) + 1
                histograms.append({"name": name, "unit": unit, "buckets": sorted(counts.items())})
            histograms.append({"name": "Bad-Name", "unit": "us", "buckets": [[40, 5]]})
            histograms.append({"name": "stability.unclean_exit", "unit": "enumeration", "buckets": [[1, 3]]})
            reports.append({"install": f"install-{nightly}-{install}" if install % 3 else f"install-{install}",
                            "version": "0.72.0", "build": str(100 + nightly), "day": "2026-10-26",
                            "histograms": histograms})
    return reports


def self_test():
    failures = []

    def check(condition, message):
        if not condition:
            failures.append(message)

    # Golden edges from diagnostics.rs: bucket_index and bucket_upper_bound.
    for value, index in ((0, 0), (3, 3), (4, 8), (5, 9), (7, 11), (8, 12), (1000, 39), (1023, 39), (1024, 40)):
        check(log_linear_index(value) == index, f"bucket_index({value}) is {log_linear_index(value)}, not {index}")
    for value in [*range(5000), 2**31 - 1, 2**40 + 12345, 2**63 - 1]:
        low, high = bucket_range("us", log_linear_index(value))
        check(low <= value < high, f"value {value} outside its bucket [{low}, {high})")
    check(bucket_range("us", 39) == (896.0, 1024.0), "bucket 39 is not [896, 1024)")
    check(bucket_range("percent", 37) == (37.0, 38.0), "percent bucket 37 is not [37, 38)")

    rng = random.Random(7)
    planted = synthetic_reports(rng, 4, 40, {(3, "key.frame.view"): 1.2})
    result = analyze(planted, iterations=400, seed=3)
    regressions = {(row["name"], row["quantile"]) for row in result["rows"] if row["regression"]}
    p95 = next(row for row in result["rows"] if row["name"] == "key.frame.view" and row["quantile"] == "p95")
    check(("key.frame.view", "p95") in regressions, f"planted 20% p95 regression not named: {p95}")
    check(0.12 < p95["change"] < 0.28, f"planted p95 change {p95['change']:.3f} not near +20%")
    check(not any(name == "main.turn" for name, _ in regressions), f"noise named as a regression: {regressions}")
    check(result["baselines"] == ["100", "101", "102"] and result["nightly"] == "103",
          f"wrong Nightly order: {result['nightly']} against {result['baselines']}")
    check({row["name"] for row in result["rows"]} == {"key.frame.view", "main.turn"},
          "a bad name or an enumeration was compared")

    for seed in range(5):
        noise = synthetic_reports(random.Random(100 + seed), 4, 40, {})
        named = [(row["name"], row["quantile"]) for row in analyze(noise, iterations=300, seed=seed)["rows"]
                 if row["regression"]]
        check(not named, f"noise seed {seed} named {named}")

    few = synthetic_reports(random.Random(9), 2, 3, {})
    skipped = analyze(few, iterations=50)
    check(not skipped["rows"] and len(skipped["skipped"]) == 2, "too few installs were compared")

    try:
        load_export({"reports": []})
        failures.append("an export without the format marker was accepted")
    except ExportError:
        pass

    for failure in failures:
        print(f"FAIL {failure}")
    print("self-test ok" if not failures else f"self-test FAILED ({len(failures)})")
    return 1 if failures else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("export", nargs="?", help="hang-reports-histograms.ts output, or - for stdin")
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--nightly", help="the build to check (default: the newest)")
    parser.add_argument("--baselines", type=int, default=3, help="earlier Nightlies to pool (default 3)")
    parser.add_argument("--threshold", type=float, default=0.10, help="smallest change named (default 0.10)")
    parser.add_argument("--iterations", type=int, default=1000, help="bootstrap resamples (default 1000)")
    parser.add_argument("--min-installs", type=int, default=5, help="installs needed on each side (default 5)")
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--all", action="store_true", help="print every comparison, not only regressions")
    parser.add_argument("--json", action="store_true")
    opts = parser.parse_args()
    if opts.self_test:
        return self_test()
    if not opts.export:
        parser.error("an export file (or -) is needed")
    try:
        if opts.export == "-":
            document = json.load(sys.stdin)
        else:
            with open(opts.export, encoding="utf-8") as handle:
                document = json.load(handle)
        result = analyze(load_export(document), nightly=opts.nightly, baselines=opts.baselines,
                         threshold=opts.threshold, iterations=opts.iterations, min_installs=opts.min_installs,
                         seed=opts.seed)
    except (OSError, ValueError, ExportError) as error:
        print(f"field-histograms: {error}", file=sys.stderr)
        return 2
    if opts.json:
        print(json.dumps(result, indent=2))
    else:
        print_text(result, opts.all)
    return 0


if __name__ == "__main__":
    sys.exit(main())
