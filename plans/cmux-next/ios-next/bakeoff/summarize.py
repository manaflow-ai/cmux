#!/usr/bin/env python3
"""Print the D2 tables from a result directory or an explicit manifest.

The manifest form keeps a comparison tied to an exact file set.  A directory
that contains ``manifest.json`` uses that manifest automatically; passing a
manifest path explicitly is preferred for release notes and CI artifacts.
"""
import glob, json, os, re, statistics, sys

here = os.path.dirname(os.path.abspath(__file__))
selector = sys.argv[1] if len(sys.argv) > 1 else os.path.join(here, "results")

RESULT_SCHEMA = "cmux-link-bench/1"
MANIFEST_SCHEMA = "cmux-link-bench-manifest/1"


def load_json(path):
    with open(path, encoding="utf-8") as stream:
        return json.load(stream)


def result_group(path):
    """Keep the historical ``-rN`` grouping for directory-only runs."""
    return re.sub(r"-r\d+$", "", os.path.basename(path)[:-5])


def checked_result(path):
    value = load_json(path)
    if not isinstance(value, dict) or value.get("schema") != RESULT_SCHEMA:
        raise ValueError("{} is not a {} result".format(path, RESULT_SCHEMA))
    return value


def manifest_results(manifest_path, manifest=None):
    """Return ``(result, metadata)`` pairs listed by a manifest.

    Result paths are relative to the manifest and are constrained to that
    directory.  This prevents a comparison from silently reaching into an
    unrelated checkout when a manifest is copied or reviewed.
    """
    if manifest is None:
        manifest = load_json(manifest_path)
    if not isinstance(manifest, dict) or manifest.get("schema") != MANIFEST_SCHEMA:
        raise ValueError("{} is not a {} manifest".format(manifest_path, MANIFEST_SCHEMA))

    entries = manifest.get("results")
    if not isinstance(entries, list) or not entries:
        raise ValueError("{} must list at least one result".format(manifest_path))

    base = os.path.realpath(os.path.dirname(manifest_path))
    selected = []
    for index, entry in enumerate(entries):
        if isinstance(entry, str):
            relative_path = entry
            metadata = {}
        elif isinstance(entry, dict):
            relative_path = entry.get("path")
            metadata = entry
        else:
            raise ValueError("{} result {} is not an object or path".format(manifest_path, index))
        if not isinstance(relative_path, str) or not relative_path:
            raise ValueError("{} result {} has no path".format(manifest_path, index))

        path = os.path.realpath(os.path.join(base, relative_path))
        if os.path.commonpath([base, path]) != base:
            raise ValueError("{} result {} escapes the manifest directory".format(manifest_path, index))
        if not os.path.isfile(path):
            raise ValueError("{} result {} is missing: {}".format(manifest_path, index, relative_path))
        selected.append((checked_result(path), metadata))
    return selected


def select_results(value):
    """Resolve a result directory, a manifest, or one raw result file."""
    value = os.path.abspath(value)
    if os.path.isdir(value):
        manifest_path = os.path.join(value, "manifest.json")
        if os.path.isfile(manifest_path):
            return manifest_results(manifest_path), manifest_path
        paths = sorted(glob.glob(os.path.join(value, "*.json")))
        paths = [path for path in paths if os.path.basename(path) != "manifest.json"]
        if not paths:
            raise ValueError("no JSON results in {}".format(value))
        return [(checked_result(path), {"path": os.path.basename(path)}) for path in paths], None

    if not os.path.isfile(value):
        raise ValueError("result selector does not exist: {}".format(value))
    document = load_json(value)
    if isinstance(document, dict) and document.get("schema") == MANIFEST_SCHEMA:
        return manifest_results(value, document), value
    return [(checked_result(value), {"path": os.path.basename(value)})], None


try:
    selected, manifest_path = select_results(selector)
except (OSError, ValueError, json.JSONDecodeError) as error:
    raise SystemExit("summarize.py: {}".format(error))

def get(r, *path):
    for p in path:
        if r is None: return None
        r = r.get(p)
    return r

def med(rs, *path):
    vals = [v for v in (get(r, *path) for r in rs) if v is not None]
    return statistics.median(vals) if vals else None

def fmt(v, d=1):
    return "n/a" if v is None else f"{v:.{d}f}"

groups = {}
for result, metadata in selected:
    name = metadata.get("group") or result_group(metadata.get("path", ""))
    if not name:
        # A manifest entry without a group should still produce a useful row
        # when it is supplied as an inline path without a filename-derived
        # group.
        name = result.get("rig") or result.get("carrier") or "result"
    groups.setdefault(name, []).append(result)

if manifest_path:
    manifest = load_json(manifest_path)
    source_commit = manifest.get("sourceCommit", "unknown")
    print("# manifest: {} (source commit: {}; {} result files)".format(
        os.path.relpath(manifest_path, os.getcwd()), source_commit, len(selected)
    ))

print("| Rig | runs | first byte p50 ms | RTT p50/p99 ms | under bulk p50/p99 ms | flood Mbit/s (CPU ms/MiB) | bulk Mbit/s (CPU ms/MiB) | raw Mbit/s | reconnect ms | roam ms (session kept) | max RSS MiB |")
print("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |")
for name, rs in groups.items():
    kept = [not any(get(r, "roam", "sessionReconnected") or [True]) for r in rs if get(r, "roam")]
    errors = sum(len(r["errors"]) for r in rs)
    print(f"| {name} | {len(rs)}{' (' + str(errors) + ' err)' if errors else ''} | {fmt(med(rs,'coldConnect','firstByte','p50'))} "
          f"| {fmt(med(rs,'rttIdle','p50'),2)}/{fmt(med(rs,'rttIdle','p99'),2)} "
          f"| {fmt(med(rs,'rttUnderBulk','rtt','p50'))}/{fmt(med(rs,'rttUnderBulk','rtt','p99'))} "
          f"| {fmt(med(rs,'terminalFlood','megabitsPerSecond'),0)} ({fmt(med(rs,'terminalFlood','cpuMillisecondsPerMiB'),0)}) "
          f"| {fmt(med(rs,'bulkFile','megabitsPerSecond'),0)} ({fmt(med(rs,'bulkFile','cpuMillisecondsPerMiB'),0)}) "
          f"| {fmt(med(rs,'rawTransport','megabitsPerSecond'),0)} "
          f"| {fmt(med(rs,'reconnect','recovered','p50'))} | {fmt(med(rs,'roam','recovered','p50'))} ({'yes' if kept and all(kept) else 'no' if kept else 'n/a'}) "
          f"| {fmt(med(rs,'memory','finalMaxResidentMiB'),0)} |")
