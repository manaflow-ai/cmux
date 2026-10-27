#!/usr/bin/env python3
"""Compiler-accurate panic ratchet for the cmux-tui Rust workspace.

Plan: plans/cmux-next/rust-panic-free.md. The production code of every
cmux-tui crate (the `--lib` and `--bins` targets; never `#[cfg(test)]`
code, `tests/`, `benches/`, `examples/` or build scripts) is checked with
the clippy lints in LINTS. A crate may never gain a hit of a lint; fixing
hits is free (lower the baseline with --update-baseline in the same commit).
A crate that is not in the baseline must have zero hits: new crates start
panic-free. A crate whose DENY_LINTS counts are all zero is "deny": any new
hit fails, the same as `#![deny(...)]`. TRACKED_LINTS (arithmetic, casts)
use the same baseline but only warn when they grow.

Why not `[workspace.lints.clippy] unwrap_used = "deny"`: Cargo applies the
workspace table to every target of every member with no per-crate or
per-target override, so a workspace deny would fail 56 crates at once, and
also fail test helpers in `tests/` and build scripts unless hundreds of
test roots carried an allow. Checking only the production targets keeps
tests free by construction and needs no Cargo.toml change.

A reviewed exception is `#[allow(clippy::<lint>, reason = "...")]` on the
smallest item (clippy honours it, so the hit is not counted). Every such
allow in production sources must carry `reason =`; one without fails.

Usage:
  # 1. lint (on rbx, a Testbox or CI; never the laptop):
  cargo clippy --workspace --lib --bins --locked --message-format=json -- $(rust_panic_ratchet.py --flags) > clippy.jsonl
  # 2. compare (laptop OK, read-only):
  rust_panic_ratchet.py --clippy-json clippy.jsonl [--update-baseline] [--report md|json]
  # 3. merge the Linux run with the macOS fleet run (scripts/cmux-next/rust-panic-macos.sh):
  rust_panic_ratchet.py --clippy-json linux=linux.jsonl --clippy-json macos=macos.jsonl --report md
Exit 1 when a crate gained a DENY_LINTS hit (a new crate: any), or an allow lacks a reason.
TRACKED_LINTS increases print a warning annotation and pass.

Several --clippy-json runs (each [LABEL=]PATH; the label defaults to the file
name without its extension) are merged into one set of hits: a hit is one
lint at one workspace-relative file:line:column, so a line both runs see
counts once, and a `#[cfg(target_os = ...)]` line only one run compiles is
added. The report then lists the hits only one run saw (the macOS-only
hits). The CI-read baseline stays the Linux run's, the one CI repeats, so a
merged run never writes it (--update-baseline and --init-baseline take one
run).

Report-only lints (REPORT_LINTS, lab only; plans/cmux-next/chrome-parity/p10-stability.md
task 114): CI uses --flags and never sees them. The lab run adds them with --report-flags and
the lab clippy.toml (await-holding-invalid-types, future-size-threshold):
  CLIPPY_CONF_DIR=lab/clippy cargo clippy --workspace --lib --bins --locked --message-format=json \
    -- $(rust_panic_ratchet.py --report-flags) > lab.jsonl
  rust_panic_ratchet.py --clippy-json lab.jsonl --tracked-report md [--update-report-baseline]
--tracked-report prints REPORT_LINTS and the per-crate count of `reason = "INVARIANT: ..."`
allowances against rust-panic-report-baseline.json and always exits 0 for a finished run. The
CI compare mode never reads that baseline, and REPORT_LINTS hits never count in it.
"""
import argparse
import collections
import json
import os
import platform
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
BASELINE = os.path.join(HERE, "rust-panic-baseline.json")

# Lints whose zero makes a crate "deny" (a panic in production code).
DENY_LINTS = [
    "unwrap_used",
    "expect_used",
    "panic",
    "unreachable",
    "todo",
    "unimplemented",
    "indexing_slicing",
    "string_slice",
    "panic_in_result_fn",
]
# Tracked by the same ratchet (never grow), but not required for "deny":
# integer overflow panics only in debug builds (release wraps), and a
# truncating cast never panics; both matter on parsers, which the fuzz
# targets cover (plans/cmux-next/rust-panic-free.md, "Arithmetic and casts").
TRACKED_LINTS = [
    "arithmetic_side_effects",
    "cast_possible_truncation",
]
LINTS = DENY_LINTS + TRACKED_LINTS
# Report-only (lab): never in --flags, never compared, never a CI failure. A lint moves to
# TRACKED_LINTS or a workspace clippy.toml only in a commit that brings every hit of it to 0.
REPORT_LINTS = [
    "undocumented_unsafe_blocks",
    "large_futures",
    "await_holding_invalid_type",
]
# Per-crate count of reviewed internal-invariant allowances on a DENY_LINTS lint:
# #[allow(clippy::expect_used, reason = "INVARIANT: <why it holds>")].
INVARIANT_ROW = "invariant_allows"
REPORT_ROWS = REPORT_LINTS + [INVARIANT_ROW]
REPORT_BASELINE = os.path.join(HERE, "rust-panic-report-baseline.json")
# Frozen test fixtures (a binary as it once shipped, never edited): the
# ratchet neither counts their hits nor scans their allows, so no lint or
# toolchain change can ask for an edit.
FROZEN_FIXTURES = {"cmux-holder-v3"}

ALLOW_ATTR = re.compile(r"#!?\[(?:cfg_attr\([^\]]*?,\s*)?(allow|expect)\(([^\]]*)\)\]", re.S)
REASON = re.compile(r"\breason\s*=")
INVARIANT_REASON = re.compile(r'\breason\s*=\s*r?#*"\s*INVARIANT:')
LINT_NAME = re.compile(r"clippy::(\w+)")


def lint_flags(lints=None):
    return " ".join(f"-W clippy::{lint}" for lint in (LINTS if lints is None else lints))


def crate_of(path):
    """crates/<name>/... -> <name>; bindings/<x>/... -> bindings-<x>; else None."""
    parts = path.replace("\\", "/").split("/")
    # clippy prints paths relative to the workspace root (cmux-tui/).
    if "cmux-tui" in parts:
        parts = parts[parts.index("cmux-tui") + 1:]
    if len(parts) >= 3 and parts[0] == "crates":
        return parts[1]
    if len(parts) >= 3 and parts[0] == "bindings":
        return "bindings-" + parts[1]
    return None


def package_name(package_id):
    # "path+file:///w/src/cmux-tui/crates/acpmux#0.1.0" or "acpmux 0.1.0 (path+file://...)"
    match = re.search(r"/crates/([^/#)\s]+)", package_id)
    if match:
        return match.group(1)
    match = re.search(r"/bindings/([^/#)\s]+)", package_id)
    if match:
        return "bindings-" + match.group(1)
    return None


def workspace_path(file_name):
    """A span's file as a cmux-tui workspace-relative path, so runs on two hosts name a file alike.

    clippy prints workspace members relative to the workspace root; an absolute
    path (a checkout at another place) keeps its part from crates/ or bindings/.
    """
    path = file_name.replace("\\", "/")
    if path.startswith("/"):
        for top in ("/cmux-tui/crates/", "/cmux-tui/bindings/"):
            at = path.find(top)
            if at >= 0:
                return path[at + len("/cmux-tui/"):]
    return path


class ClippyRun:
    """One clippy --message-format=json run: the crates it checked, whether it finished, its hits."""

    def __init__(self, label):
        self.label = label
        self.checked = set()
        self.finished = None
        # (workspace file, line, column, lint) -> crate, in first-seen order.
        self.hits = {}


def read_run(path, label=None, lints=None, skip_generated=False):
    """Read one run. Only `lints` (default LINTS) are kept, so a lab run with --report-flags gives the
    CI compare the same counts as a run with --flags. `skip_generated` drops hits in files clippy
    names by an absolute path outside the workspace (build-script output such as bindgen's
    OUT_DIR/bindings.rs)."""
    lints = set(LINTS if lints is None else lints)
    run = ClippyRun(label or os.path.splitext(os.path.basename(path))[0])
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
                run.finished = bool(item.get("success"))
                continue
            if reason == "compiler-artifact":
                name = package_name(item.get("package_id", ""))
                if name and name not in FROZEN_FIXTURES and any(k in ("lib", "rlib", "bin", "cdylib", "staticlib", "proc-macro", "dylib")
                                for k in item.get("target", {}).get("kind", [])):
                    run.checked.add(name)
                continue
            if reason != "compiler-message":
                continue
            if "custom-build" in (item.get("target") or {}).get("kind", []):
                continue  # build scripts run at build time, never in a daemon
            message = item.get("message") or {}
            code = (message.get("code") or {}).get("code") or ""
            if not code.startswith("clippy::"):
                continue
            lint = code[len("clippy::"):]
            if lint not in lints:
                continue
            span = next((s for s in message.get("spans", []) if s.get("is_primary")), None)
            if span is None:
                continue
            file_name = span.get("file_name", "")
            if skip_generated and workspace_path(file_name).startswith("/"):
                continue
            crate = crate_of(file_name) or package_name(item.get("package_id", ""))
            if crate is None:
                continue  # vendor/ or registry code: third-party
            if crate in FROZEN_FIXTURES:
                continue
            # The same source line seen through a lib and a bin target counts once.
            run.hits.setdefault((workspace_path(file_name), span.get("line_start"), span.get("column_start"), lint), crate)
    return run


def merge_runs(runs):
    """Return (checked, {crate: {lint: count}}, {crate: {file: count}}, finished, {(crate, lint): [loc]}, only).

    `only` maps a run's label to {crate: [(loc, lint)]}: the hits no other run saw.
    With one run it is empty.
    """
    checked = set()
    merged = {}
    seen_by = collections.defaultdict(set)
    for run in runs:
        checked |= run.checked
        for key, crate in run.hits.items():
            merged.setdefault(key, crate)
            seen_by[key].add(run.label)
    counts = collections.defaultdict(collections.Counter)
    files = collections.defaultdict(collections.Counter)
    hits = collections.defaultdict(list)
    only = {run.label: collections.defaultdict(list) for run in runs} if len(runs) > 1 else {}
    for key, crate in merged.items():
        file_name, line, column, lint = key
        loc = f"{file_name}:{line}:{column}"
        counts[crate][lint] += 1
        hits[(crate, lint)].append(loc)
        files[crate][file_name] += 1
        if only and len(seen_by[key]) == 1:
            only[next(iter(seen_by[key]))][crate].append((loc, lint))
    finished = all(run.finished is True for run in runs) if runs else None
    return checked, counts, files, finished, hits, only


def read_clippy(path, lints=None, skip_generated=False):
    """One run: (checked crate set, {crate: {lint: count}}, {crate: {file: count}}, finished, hits)."""
    return merge_runs([read_run(path, lints=lints, skip_generated=skip_generated)])[:5]


def parse_run_arg(value):
    """`LABEL=PATH` or `PATH` (the label is then the file name without its extension)."""
    label, sep, path = value.partition("=")
    if sep and re.fullmatch(r"[A-Za-z0-9_.-]+", label) and not os.path.exists(value):
        return label, path
    return None, value


def allow_without_reason(root):
    """Production-source allow/expect attributes on our lints that carry no reason."""
    bad = []
    for _crate, path, text in production_sources(root):
        for match in ALLOW_ATTR.finditer(text):
            kind, body = match.group(1), match.group(2)
            lints = [l for l in LINT_NAME.findall(body) if l in LINTS]
            if lints and kind == "expect":
                line = text.count("\n", 0, match.start()) + 1
                bad.append(f"{os.path.relpath(path, root)}:{line}: use allow, not expect, for {', '.join(lints)} "
                           "(the plain clippy run does not enable these lints, so expect is unfulfilled)")
            elif lints and not REASON.search(body):
                line = text.count("\n", 0, match.start()) + 1
                bad.append(f"{os.path.relpath(path, root)}:{line}: allow({', '.join(lints)}) needs reason = \"...\"")
    return bad


def invariant_allows(root):
    """{crate: count} of production allow attributes on a DENY_LINTS lint whose reason starts INVARIANT:."""
    counts = collections.Counter()
    for crate, _path, text in production_sources(root):
        for match in ALLOW_ATTR.finditer(text):
            body = match.group(2)
            if INVARIANT_REASON.search(body) and any(l in DENY_LINTS for l in LINT_NAME.findall(body)):
                counts[crate] += 1
    return counts


def production_sources(root):
    """(crate, path, text) for each production .rs file of cmux-tui/crates and cmux-tui/bindings."""
    for top, prefix in (("crates", ""), ("bindings", "bindings-")):
        crates_dir = os.path.join(root, "cmux-tui", top)
        for dirpath, dirnames, filenames in os.walk(crates_dir):
            rel = os.path.relpath(dirpath, crates_dir).replace("\\", "/")
            parts = rel.split("/")
            if parts[0] in FROZEN_FIXTURES:
                dirnames[:] = []
                continue
            if len(parts) >= 2 and parts[1] in ("tests", "benches", "examples", "fuzz", "target"):
                dirnames[:] = []
                continue
            dirnames[:] = [d for d in dirnames if d not in ("target", "tests", "benches", "examples", "fuzz")]
            for name in filenames:
                if not name.endswith(".rs") or name in ("build.rs",) or name.endswith("_tests.rs") or name == "tests.rs":
                    continue
                path = os.path.join(dirpath, name)
                try:
                    with open(path, encoding="utf-8", errors="replace") as handle:
                        text = handle.read()
                except OSError:
                    continue
                yield prefix + parts[0], path, text


def _changed_first(root, locations):
    """Hit locations in files changed against origin/feat-cmux-next first (where a new hit is)."""
    try:
        import subprocess
        out = subprocess.run(["git", "-C", root, "diff", "--name-only", "origin/feat-cmux-next...HEAD"],
                             capture_output=True, text=True, timeout=30).stdout
    except (OSError, subprocess.SubprocessError):
        out = ""
    changed = {line.split("cmux-tui/", 1)[-1] for line in out.splitlines()}
    return sorted(locations, key=lambda loc: (loc.split(":", 1)[0] not in changed, loc))


def load_baseline():
    if not os.path.exists(BASELINE):
        return {}
    with open(BASELINE, encoding="utf-8") as handle:
        return json.load(handle).get("crates", {})


def write_baseline(crates):
    data = {
        "_doc": "Per-crate clippy hit counts of production code (scripts/cmux-next/rust_panic_ratchet.py). "
                "Counts only go down. A crate with every deny lint at 0 is at deny.",
        "lints": LINTS,
        "deny_lints": DENY_LINTS,
        "crates": {crate: {lint: crates[crate].get(lint, 0) for lint in LINTS} for crate in sorted(crates)},
    }
    with open(BASELINE, "w", encoding="utf-8") as handle:
        json.dump(data, handle, indent=1, sort_keys=False)
        handle.write("\n")


def is_deny(lints):
    return all(lints.get(lint, 0) == 0 for lint in DENY_LINTS)


SHORT = {"unwrap_used": "unwrap", "expect_used": "expect", "panic": "panic", "unreachable": "unreach",
         "todo": "todo", "unimplemented": "unimpl", "indexing_slicing": "index", "string_slice": "strslice",
         "panic_in_result_fn": "panic_in_result", "arithmetic_side_effects": "arith",
         "cast_possible_truncation": "cast_trunc"}


def report(checked, counts, files, fmt, only=None):
    only = only or {}
    rows = []
    for crate in sorted(checked | set(counts)):
        c = counts.get(crate, {})
        top = ", ".join(f"{f} {n}" for f, n in files.get(crate, collections.Counter()).most_common(3))
        rows.append((crate, c, is_deny(c), top))
    if fmt == "json":
        out = {}
        for crate, c, deny, top in rows:
            out[crate] = {"counts": dict(c), "deny": deny, "top": top}
            if only:
                out[crate]["only_in"] = {label: [{"loc": loc, "lint": lint} for loc, lint in sorted(by_crate.get(crate, []))]
                                         for label, by_crate in only.items()}
        print(json.dumps(out, indent=1))
        return
    print("| crate | " + " | ".join(SHORT[l] for l in LINTS) + " | deny | top files |")
    print("|" + " --- |" * (len(LINTS) + 3))
    rows.sort(key=lambda r: -sum(r[1].get(l, 0) for l in DENY_LINTS))
    for crate, c, deny, top in rows:
        print(f"| {crate} | " + " | ".join(str(c.get(l, 0)) for l in LINTS) + f" | {'yes' if deny else 'no'} | {top} |")
    for label, by_crate in only.items():
        total = sum(len(v) for v in by_crate.values())
        print(f"\n### Hits only the {label} run saw ({total})\n")
        if not total:
            print("none")
            continue
        print("| crate | lint | location |")
        print("| --- | --- | --- |")
        for crate in sorted(by_crate):
            for loc, lint in sorted(by_crate[crate]):
                print(f"| {crate} | {SHORT[lint]} | {loc} |")


def load_report_baseline():
    if not os.path.exists(REPORT_BASELINE):
        return {}
    with open(REPORT_BASELINE, encoding="utf-8") as handle:
        return json.load(handle).get("crates", {})


def write_report_baseline(rows):
    data = {
        "_doc": "Report-only per-crate counts of the lab clippy run (rust_panic_ratchet.py --report-flags with "
                "CLIPPY_CONF_DIR=cmux-tui/lab/clippy) and of INVARIANT: allowances. Read only by --tracked-report; "
                "CI never reads it, so a count here is never a gate.",
        "rows": REPORT_ROWS,
        "platform": f"{platform.system().lower()}-{platform.machine()}",
        "totals": {row: sum(rows[crate].get(row, 0) for crate in rows) for row in REPORT_ROWS},
        "crates": {crate: {row: rows[crate].get(row, 0) for row in REPORT_ROWS} for crate in sorted(rows)},
    }
    with open(REPORT_BASELINE, "w", encoding="utf-8") as handle:
        json.dump(data, handle, indent=1, sort_keys=False)
        handle.write("\n")


def tracked_report(args, parser):
    if len(args.clippy_json) > 1 and args.update_report_baseline:
        parser.error("--update-report-baseline takes one --clippy-json run: the report baseline is one Linux run")
    runs = []
    for value in args.clippy_json:
        label, path = parse_run_arg(value)
        runs.append(read_run(path, label, lints=REPORT_LINTS, skip_generated=True))
    for run in runs:
        if not run.checked or run.finished is not True:
            print(f"rust-panic-ratchet: the {run.label} clippy run did not finish successfully (no build-finished"
                  " success line); counts from a partial build prove nothing", file=sys.stderr)
            return 2
    checked, counts, files, _, hits, _only = merge_runs(runs)
    invariants = invariant_allows(args.repo)
    rows = {}
    for crate in checked | set(counts):
        row = {lint: counts.get(crate, {}).get(lint, 0) for lint in REPORT_LINTS}
        row[INVARIANT_ROW] = invariants.get(crate, 0)
        rows[crate] = row
    baseline = load_report_baseline()
    if args.tracked_report == "json":
        print(json.dumps({crate: {"counts": rows[crate], "baseline": baseline.get(crate),
                                  "top": [f"{f} {n}" for f, n in files.get(crate, collections.Counter()).most_common(3)],
                                  "hits": {lint: hits.get((crate, lint), []) for lint in REPORT_LINTS
                                           if hits.get((crate, lint))}}
                          for crate in sorted(rows)}, indent=1))
    else:
        short = {"undocumented_unsafe_blocks": "unsafe_undoc", "large_futures": "large_fut",
                 "await_holding_invalid_type": "await_held", INVARIANT_ROW: "INVARIANT"}
        print("| crate | " + " | ".join(short[r] for r in REPORT_ROWS) + " | top files |")
        print("|" + " --- |" * (len(REPORT_ROWS) + 2))

        def cell(crate, row):
            now = rows[crate][row]
            base = (baseline.get(crate) or {}).get(row)
            return str(now) if base is None or base == now else f"{now} ({now - base:+d})"

        for crate in sorted(rows, key=lambda c: (-sum(rows[c].values()), c)):
            if not any(rows[crate].values()):
                continue
            top = ", ".join(f"{f} {n}" for f, n in files.get(crate, collections.Counter()).most_common(3))
            print(f"| {crate} | " + " | ".join(cell(crate, r) for r in REPORT_ROWS) + f" | {top} |")
        print("| **total** | " + " | ".join(str(sum(rows[c][r] for c in rows)) for r in REPORT_ROWS) + " | |")
    if args.update_report_baseline:
        write_report_baseline(rows)
        print(f"rust-panic-ratchet: wrote {os.path.relpath(REPORT_BASELINE, args.repo)} for {len(rows)} crates",
              file=sys.stderr)
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--flags", action="store_true", help="print the clippy lint flags and exit")
    parser.add_argument("--clippy-json", action="append", metavar="[LABEL=]PATH",
                        help="cargo clippy --message-format=json output; repeat to merge runs (Linux and macOS)")
    parser.add_argument("--repo", default=REPO)
    parser.add_argument("--update-baseline", action="store_true", help="lower the baseline to the counts seen")
    parser.add_argument("--init-baseline", action="store_true", help="write the baseline from scratch (first run only)")
    parser.add_argument("--report", choices=["md", "json"])
    parser.add_argument("--report-flags", action="store_true",
                        help="print the lab clippy flags (--flags plus the report-only lints) and exit")
    parser.add_argument("--tracked-report", choices=["md", "json"],
                        help="report-only: print REPORT_LINTS and INVARIANT allowances per crate against "
                             "rust-panic-report-baseline.json; never compares the CI baseline, exits 0")
    parser.add_argument("--update-report-baseline", action="store_true",
                        help="with --tracked-report: write rust-panic-report-baseline.json from this run")
    args = parser.parse_args()
    if args.flags:
        print(lint_flags())
        return 0
    if args.report_flags:
        print(lint_flags(LINTS + REPORT_LINTS))
        return 0
    if not args.clippy_json:
        parser.error("--clippy-json is required")
    if args.update_report_baseline and not args.tracked_report:
        parser.error("--update-report-baseline needs --tracked-report")
    if args.tracked_report:
        return tracked_report(args, parser)
    runs = []
    for value in args.clippy_json:
        label, path = parse_run_arg(value)
        run = read_run(path, label)
        if any(other.label == run.label for other in runs):
            parser.error(f"two --clippy-json runs are labelled {run.label!r}; name them LABEL=PATH")
        runs.append(run)
    if len(runs) > 1 and (args.update_baseline or args.init_baseline):
        parser.error("--update-baseline and --init-baseline take one --clippy-json run: the CI-read baseline is the"
                     " Linux run CI repeats, and a merged run would add hits CI never sees")
    for run in runs:
        if not run.checked or run.finished is not True:
            print(f"rust-panic-ratchet: the {run.label} clippy run did not finish successfully (no build-finished"
                  " success line); counts from a partial build prove nothing", file=sys.stderr)
            return 2
    checked, counts, files, _, hits, only = merge_runs(runs)
    if only:
        sizes = ", ".join(f"{run.label} {len(run.hits)}" for run in runs)
        alone = ", ".join(f"{label}-only {sum(len(v) for v in by.values())}" for label, by in only.items())
        print(f"rust-panic-ratchet: merged {len(runs)} runs by file:line:column (hits: {sizes});"
              f" {sum(sum(c.values()) for c in counts.values())} distinct, {alone}", file=sys.stderr)
    if args.report:
        report(checked, counts, files, args.report, only)
    baseline = load_baseline()
    if args.init_baseline:
        write_baseline({crate: counts.get(crate, collections.Counter()) for crate in checked})
        print(f"rust-panic-ratchet: wrote {os.path.relpath(BASELINE, args.repo)} for {len(checked)} crates")
        return 0

    failures = []
    warnings = []
    lowered = {}
    for crate in sorted(checked):
        now = counts.get(crate, collections.Counter())
        base = baseline.get(crate)
        for lint in LINTS:
            got = now.get(lint, 0)
            allowed = 0 if base is None else base.get(lint, 0)
            if got > allowed:
                where = "new crate (must be 0)" if base is None else f"baseline {allowed}"
                # Tracked lints warn only: an added `x + 1` must not block a landing.
                (failures if lint in DENY_LINTS else warnings).append(f"{crate}: clippy::{lint} {got} > {where}")
                if lint in DENY_LINTS:
                    for loc in _changed_first(args.repo, hits.get((crate, lint), []))[:20]:
                        failures.append(f"    {loc}")
        if base is not None and any(now.get(l, 0) < base.get(l, 0) for l in LINTS):
            lowered[crate] = {l: min(now.get(l, 0), base.get(l, 0)) for l in LINTS}

    missing = sorted(set(baseline) - checked)
    if missing and not args.init_baseline:
        print("::warning title=rust panic ratchet::baseline crates not checked by this run (a -p run, a removed "
              "member, or a bin with required-features): " + ", ".join(missing), file=sys.stderr)
    for line in allow_without_reason(args.repo):
        failures.append(line)

    if args.update_baseline:
        if failures:
            print("rust-panic-ratchet: refusing to update the baseline while it is red", file=sys.stderr)
        else:
            merged = dict(baseline)
            merged.update(lowered)
            for crate in checked:
                now = counts.get(crate, collections.Counter())
                merged.setdefault(crate, {l: (0 if l in DENY_LINTS else now.get(l, 0)) for l in LINTS})
            write_baseline(merged)
            print(f"rust-panic-ratchet: lowered {len(lowered)} crate(s)", file=sys.stderr)

    deny = sorted(c for c in checked if is_deny(counts.get(c, {})))
    print(f"rust-panic-ratchet: {len(checked)} crates checked, {len(deny)} at deny", file=sys.stderr)
    if lowered and not args.update_baseline:
        print("::warning title=rust panic ratchet::counts went down in " + ", ".join(sorted(lowered))
              + "; lower scripts/cmux-next/rust-panic-baseline.json with --update-baseline"
              + (" on the Linux run alone" if len(runs) > 1 else "") + " in this commit,"
              " or a later change can add hits up to the old count", file=sys.stderr)
    for line in warnings:
        print(f"::warning title=rust panic ratchet (tracked lint)::{line}", file=sys.stderr)
    if failures:
        print("rust-panic-ratchet: RED", file=sys.stderr)
        for line in failures:
            print("  " + line, file=sys.stderr)
        print("Fix the hit (a typed error handled at a boundary), or put a reviewed\n"
              "#[allow(clippy::<lint>, reason = \"...\")] on the smallest item. Never raise the baseline.",
              file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
