#!/usr/bin/env python3
"""Compare one Nightly's field histograms with the Nightlies before it. Run by hand, never in CI.

Input is the read-only `--nightlies` export of schema-3 hang reports (p09-observability.md section 3D):

  cd web && DATABASE_URL=... bun scripts/hang-reports-histograms.ts --nightlies --days 30 > nightlies.json
  python3 scripts/cmux-next/field-histograms.py web/nightlies.json [--nightly BUILD] [--baselines 3]

For every ordered histogram and each of p50, p95 and p99, it compares Nightly N (the newest build, or
--nightly) with Nightlies N-1..N-3 pooled. The interval is a 95% bootstrap interval of the relative change,
resampling installs on both sides (one install's launches are not independent samples). A row is named a
regression when the change is above --threshold (10%) and the whole interval is above zero, so it is both
large and outside what resampling the same installs produces. Chromium's perf dashboard asks the same two
things of a step (catapult dashboard/dashboard/find_change_points.py: a minimum relative size and a
significance test). Reports keep only bucket counts, as Chromium's base/metrics/histogram.cc does, so a
percentile is read from the merged buckets, interpolated inside its bucket. Every bucket arrives with its
value range from the server's catalog (web/services/hangReports/histogramCatalog.ts), so this script has no
bucket layout of its own; a percentile in an overflow bucket reads as that bucket's lower end.

A higher value is worse for every exported unit (durations, sizes, counts, percents); the export leaves out
enumerations and Chromium-bucketed histograms, which have no known bucket ends.

  --self-test   plants a 20% p95 regression in synthetic Nightlies and checks it is named, that noise-only
                Nightlies name nothing, and that too few installs are skipped.
"""

import argparse
import json
import random
import sys

EXPORT_FORMAT = "cmux-field-histograms/1"
QUANTILES = (("p50", 0.50), ("p95", 0.95), ("p99", 0.99))


class ExportError(Exception):
    """The input is not a hang-reports-histograms.ts --nightlies export, or cannot be compared."""


def quantile(buckets, fraction):
    """The `fraction` quantile of sorted ((low, high), count) pairs, interpolated inside its bucket.

    A bucket [low, high] holds the integers low..high, read as the interval [low, high + 1); the overflow
    bucket (high None) reads as its low end.
    """
    total = sum(count for _, count in buckets)
    if total == 0:
        return None
    rank = fraction * total
    seen = 0
    for (low, high), count in buckets:
        if seen + count >= rank:
            if high is None:
                return float(low)
            return low + (high + 1 - low) * (rank - seen) / count
        seen += count
    return None


def merge(parts):
    """Sum per-install {(low, high): count} maps into sorted ((low, high), count) pairs."""
    merged = {}
    for part in parts:
        for bucket, count in part.items():
            merged[bucket] = merged.get(bucket, 0) + count
    return sorted(merged.items(), key=lambda item: item[0][0])


def number_key(text):
    head = (text or "").split("-")[0]
    return tuple(int(part) if part.isdigit() else 0 for part in head.split("."))


def nightly_key(sample):
    """A Nightly is one build; builds sort by version, then by build number."""
    build = str(sample.get("build") or "")
    return (number_key(sample.get("version")), number_key(build), build)


def load_export(document):
    if not isinstance(document, dict) or document.get("format") != EXPORT_FORMAT:
        raise ExportError(f"expected a --nightlies export with format {EXPORT_FORMAT!r}")
    samples = document.get("samples")
    if not isinstance(samples, list):
        raise ExportError("samples is not a list")
    return samples


def bucket_counts(pairs):
    counts = {}
    for entry in pairs or []:
        low, high, count = entry
        if count > 0:
            bucket = (int(low), None if high is None else int(high))
            counts[bucket] = counts.get(bucket, 0) + int(count)
    return counts


def install_histograms(samples):
    """{nightly: {name: (unit, {install: {(low, high): count}})}}."""
    nightlies = {}
    for sample in samples:
        install = sample.get("install")
        if not install or not sample.get("build"):
            continue
        names = nightlies.setdefault(nightly_key(sample), {})
        for histogram in sample.get("histograms") or []:
            name, unit = histogram.get("name"), histogram.get("unit")
            entry = names.setdefault(name, (unit, {}))
            if entry[0] != unit:
                continue  # never happens while catalog names keep their meaning; compare the unit seen first
            target = entry[1].setdefault(install, {})
            for bucket, count in bucket_counts(histogram.get("buckets")).items():
                target[bucket] = target.get(bucket, 0) + count
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
            for bucket, count in counts.items():
                target[bucket] = target.get(bucket, 0) + count
    return unit, list(installs.values())


def resample(rng, parts):
    return merge(rng.choice(parts) for _ in parts)


def interpolated(sorted_values, fraction):
    position = fraction * (len(sorted_values) - 1)
    low = int(position)
    high = min(low + 1, len(sorted_values) - 1)
    return sorted_values[low] + (sorted_values[high] - sorted_values[low]) * (position - low)


def compare(target, baseline, iterations, rng):
    """Per quantile: (target value, baseline value, change, interval low, interval high)."""
    target_merged, baseline_merged = merge(target), merge(baseline)
    changes = {label: [] for label, _ in QUANTILES}
    for _ in range(iterations):
        target_sample, baseline_sample = resample(rng, target), resample(rng, baseline)
        for label, fraction in QUANTILES:
            new, old = quantile(target_sample, fraction), quantile(baseline_sample, fraction)
            if new is not None and old:
                changes[label].append(new / old - 1)
    rows = {}
    for label, fraction in QUANTILES:
        new, old = quantile(target_merged, fraction), quantile(baseline_merged, fraction)
        values = sorted(changes[label])
        if new is None or not old or not values:
            continue
        rows[label] = (new, old, new / old - 1, interpolated(values, 0.025), interpolated(values, 0.975))
    return rows


def choose_nightlies(order, nightly, baselines):
    if nightly is not None:
        matches = [key for key in order if key[2] == nightly]
        if not matches:
            raise ExportError(f"no samples from build {nightly}")
        position = order.index(matches[0])
    else:
        position = len(order) - 1
    if position < 1:
        raise ExportError("need the target Nightly and at least one earlier Nightly")
    return order[position], order[max(0, position - baselines):position]


def analyze(samples, nightly=None, baselines=3, threshold=0.10, iterations=1000, min_installs=5, seed=1):
    nightlies = install_histograms(samples)
    target_key, baseline_keys = choose_nightlies(sorted(nightlies), nightly, baselines)
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
        for label, (new, old, change, low, high) in compare(target, baseline, iterations, rng).items():
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

def synthetic_range(value):
    """The catalog's log-linear bucket of `value` (histogramCatalog.ts), to build synthetic exports."""
    if value < 4:
        return value, value
    octave = value.bit_length() - 1
    width = 1 << (octave - 2)
    low = (1 << octave) + ((value >> (octave - 2)) & 3) * width
    return low, low + width - 1


def synthetic_samples(rng, nightlies, installs, scale_by_nightly):
    """Samples where each install's values are log-normal around its own speed, bucketed like the catalog."""
    samples = []
    for nightly in range(nightlies):
        for install in range(installs):
            speed = rng.lognormvariate(0, 0.15)
            histograms = []
            for name, median in (("key.frame.view", 4000), ("main.turn", 900)):
                scale = scale_by_nightly.get((nightly, name), 1.0)
                counts = {}
                for _ in range(150):
                    bucket = synthetic_range(int(median * speed * scale * rng.lognormvariate(0, 0.6)))
                    counts[bucket] = counts.get(bucket, 0) + 1
                histograms.append({"name": name, "unit": "us",
                                   "buckets": [[low, high, count] for (low, high), count in sorted(counts.items())]})
            # Some installs run every Nightly, others only one.
            samples.append({"install": f"install-{nightly}-{install}" if install % 3 else f"install-{install}",
                            "version": "0.72.0", "build": str(2100 + nightly), "histograms": histograms})
    return samples


def self_test():
    failures = []

    def check(condition, message):
        if not condition:
            failures.append(message)

    for value in [*range(5000), 2**31 - 1, 2**40 + 12345]:
        low, high = synthetic_range(value)
        check(low <= value <= high, f"value {value} outside its synthetic bucket [{low}, {high}]")
    check(synthetic_range(1024) == (1024, 1279), "bucket of 1024 is not 1024..1279 (catalog bucket 40)")
    check(quantile([((7, 7), 1), ((8, 8), 1)], 0.5) == 8.0, "a linear bucket does not read as [low, high + 1)")
    check(quantile([((10, 10), 1), ((101, None), 3)], 0.95) == 101.0, "an overflow percentile is not its low end")

    planted = synthetic_samples(random.Random(7), 4, 40, {(3, "key.frame.view"): 1.2})
    result = analyze(planted, iterations=400, seed=3)
    regressions = {(row["name"], row["quantile"]) for row in result["rows"] if row["regression"]}
    p95 = next(row for row in result["rows"] if row["name"] == "key.frame.view" and row["quantile"] == "p95")
    check(("key.frame.view", "p95") in regressions, f"planted 20% p95 regression not named: {p95}")
    check(0.12 < p95["change"] < 0.28, f"planted p95 change {p95['change']:.3f} not near +20%")
    check(not any(name == "main.turn" for name, _ in regressions), f"noise named as a regression: {regressions}")
    check(result["baselines"] == ["2100", "2101", "2102"] and result["nightly"] == "2103",
          f"wrong Nightly order: {result['nightly']} against {result['baselines']}")

    older = analyze(planted, nightly="2102", iterations=200, seed=3)
    check(older["baselines"] == ["2100", "2101"] and not any(row["regression"] for row in older["rows"]),
          f"--nightly 2102 compared wrongly: {older['baselines']}")

    for seed in range(5):
        noise = synthetic_samples(random.Random(100 + seed), 4, 40, {})
        named = [(row["name"], row["quantile"]) for row in analyze(noise, iterations=300, seed=seed)["rows"]
                 if row["regression"]]
        check(not named, f"noise seed {seed} named {named}")

    few = analyze(synthetic_samples(random.Random(9), 2, 3, {}), iterations=50)
    check(not few["rows"] and len(few["skipped"]) == 2, "too few installs were compared")

    for document in ({"samples": []}, {"format": "cmux-hang-report-histograms/1", "samples": []}):
        try:
            load_export(document)
            failures.append(f"an export with format {document.get('format')!r} was accepted")
        except ExportError:
            pass

    for failure in failures:
        print(f"FAIL {failure}")
    print("self-test ok" if not failures else f"self-test FAILED ({len(failures)})")
    return 1 if failures else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("export", nargs="?", help="hang-reports-histograms.ts --nightlies output, or - for stdin")
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
    except (OSError, ValueError, TypeError, ExportError) as error:
        print(f"field-histograms: {error}", file=sys.stderr)
        return 2
    if opts.json:
        print(json.dumps(result, indent=2))
    else:
        print_text(result, opts.all)
    return 0


if __name__ == "__main__":
    sys.exit(main())
