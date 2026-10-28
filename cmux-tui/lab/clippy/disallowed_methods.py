#!/usr/bin/env python3
"""Per-crate clippy::disallowed_methods hits of the lab clippy run (p10-stability Q11, task 206).

Lab only; CI never runs it. Run clippy with CLIPPY_CONF_DIR=cmux-tui/lab/clippy as
cmux-tui/lab/clippy/clippy.toml says (Linux and macOS), then:

  python3 cmux-tui/lab/clippy/disallowed_methods.py linux=linux.jsonl macos=macos.jsonl [--json] [--check]

A hit is one method at one workspace file:line:column, so a line both runs see
counts once (the merge rust_panic_ratchet.py --clippy-json does), and a macro
span that expands to several methods counts each of them. Only the production
targets the run checked count; build scripts never do. --check exits 1 while
code outside the wrappers has a hit (p10-stability done check 10) or a run did
not finish. The wrappers are cmux-blocking, whose modules allow the lint, and
the two crates it depends on: cmux-threads (the sync primitives, spawn, work,
hang and cmux_threads::checked) and cmux-panic-log. Those two build the policy
itself and cannot call cmux-blocking without a dependency cycle, so the table
lists their hits on rows of their own and --check never counts them.
"""
import argparse
import collections
import json
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
sys.path.insert(0, os.path.join(REPO, "scripts", "cmux-next"))

from rust_panic_ratchet import FROZEN_FIXTURES, crate_of, package_name, workspace_path  # noqa: E402

LINT = "clippy::disallowed_methods"
# The sanctioned callers of the blocking std calls: (row, path prefix); the
# first prefix that matches names the row. cmux-blocking depends on
# cmux-threads and cmux-panic-log, so those layers call std directly.
WRAPPERS = (
    ("cmux-blocking", "crates/cmux-blocking/"),
    ("cmux-threads (checked)", "crates/cmux-threads/src/checked.rs"),
    ("cmux-threads", "crates/cmux-threads/"),
    ("cmux-panic-log", "crates/cmux-panic-log/"),
)
METHOD = re.compile(r"use of a disallowed method `([^`]+)`")


def read_run(path):
    """(finished, {(file, line, column, method): crate}) for one clippy JSON run."""
    finished = None
    hits = {}
    with open(path, encoding="utf-8", errors="replace") as handle:
        for line in handle:
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                item = json.loads(line)
            except json.JSONDecodeError:
                continue
            reason = item.get("reason")
            if reason == "build-finished":
                finished = bool(item.get("success"))
                continue
            if reason != "compiler-message":
                continue
            if "custom-build" in (item.get("target") or {}).get("kind", []):
                continue
            message = item.get("message") or {}
            if (message.get("code") or {}).get("code") != LINT:
                continue
            span = next((s for s in message.get("spans", []) if s.get("is_primary")), None)
            if span is None:
                continue
            file_name = span.get("file_name", "")
            crate = crate_of(file_name) or package_name(item.get("package_id", ""))
            if crate is None or crate in FROZEN_FIXTURES:
                continue
            match = METHOD.search(message.get("message", ""))
            method = match.group(1) if match else "?"
            path = workspace_path(file_name)
            crate = next((row for row, prefix in WRAPPERS if path.startswith(prefix)), crate)
            hits.setdefault((path, span.get("line_start"), span.get("column_start"), method), crate)
    return finished, hits


def parse_run_arg(value):
    label, sep, path = value.partition("=")
    if sep and re.fullmatch(r"[A-Za-z0-9_.-]+", label) and not os.path.exists(value):
        return label, path
    return os.path.splitext(os.path.basename(value))[0], value


def summarize(runs):
    """{"finished": bool, "crates": {crate: {"total": n, "methods": {method: n}}}} over merged runs."""
    merged = {}
    finished = True
    for _, path in runs:
        run_finished, hits = read_run(path)
        finished = finished and run_finished is True
        for key, value in hits.items():
            merged.setdefault(key, value)
    methods = collections.defaultdict(collections.Counter)
    for (_, _, _, method), crate in merged.items():
        methods[crate][method] += 1
    crates = {
        crate: {"total": sum(counter.values()), "methods": dict(counter.most_common())}
        for crate, counter in sorted(methods.items(), key=lambda item: (-sum(item[1].values()), item[0]))
    }
    return {"finished": finished, "crates": crates}


def outside_wrappers(summary):
    wrappers = {row for row, _ in WRAPPERS}
    return sum(entry["total"] for crate, entry in summary["crates"].items() if crate not in wrappers)


def markdown(summary):
    lines = ["| crate | disallowed_methods | top methods |", "| --- | ---: | --- |"]
    for crate, entry in summary["crates"].items():
        top = ", ".join(f"`{method}` {count}" for method, count in list(entry["methods"].items())[:5])
        lines.append(f"| {crate} | {entry['total']} | {top} |")
    lines.append("")
    lines.append(f"Outside the wrappers: {outside_wrappers(summary)}.")
    if not summary["finished"]:
        lines.append("A run did not finish: the counts are partial.")
    return "\n".join(lines)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("runs", nargs="+", metavar="[LABEL=]PATH", help="clippy --message-format=json output")
    parser.add_argument("--json", action="store_true", help="print JSON instead of a Markdown table")
    parser.add_argument("--check", action="store_true", help="exit 1 on a hit outside the wrappers or an unfinished run")
    args = parser.parse_args(argv)
    runs = [parse_run_arg(value) for value in args.runs]
    labels = [label for label, _ in runs]
    if len(set(labels)) != len(labels):
        parser.error("two runs have the same label; name them LABEL=PATH")
    summary = summarize(runs)
    print(json.dumps(summary, indent=2) if args.json else markdown(summary))
    if args.check and (outside_wrappers(summary) or not summary["finished"]):
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
