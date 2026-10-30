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
Exit 1 when a crate gained a DENY_LINTS hit (a new crate: any), or an allow lacks a reason.
TRACKED_LINTS increases print a warning annotation and pass.
"""
import argparse
import collections
import json
import os
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
# Frozen test fixtures (a binary as it once shipped, never edited): the
# ratchet neither counts their hits nor scans their allows, so no lint or
# toolchain change can ask for an edit.
FROZEN_FIXTURES = {"cmux-holder-v3"}

ALLOW_ATTR = re.compile(r"#!?\[(?:cfg_attr\([^\]]*?,\s*)?(allow|expect)\(([^\]]*)\)\]", re.S)
REASON = re.compile(r"\breason\s*=")
LINT_NAME = re.compile(r"clippy::(\w+)")


def lint_flags():
    return " ".join(f"-W clippy::{lint}" for lint in LINTS)


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


def read_clippy(path):
    """Return (checked crate set, {crate: {lint: count}}, {crate: {file: count}})."""
    checked = set()
    finished = None
    seen = set()
    hits = collections.defaultdict(list)
    counts = collections.defaultdict(collections.Counter)
    files = collections.defaultdict(collections.Counter)
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
            if reason == "compiler-artifact":
                name = package_name(item.get("package_id", ""))
                if name and name not in FROZEN_FIXTURES and any(k in ("lib", "rlib", "bin", "cdylib", "staticlib", "proc-macro", "dylib")
                                for k in item.get("target", {}).get("kind", [])):
                    checked.add(name)
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
            if lint not in LINTS:
                continue
            span = next((s for s in message.get("spans", []) if s.get("is_primary")), None)
            if span is None:
                continue
            file_name = span.get("file_name", "")
            crate = crate_of(file_name) or package_name(item.get("package_id", ""))
            if crate is None:
                continue  # vendor/ or registry code: third-party
            if crate in FROZEN_FIXTURES:
                continue
            key = (file_name, span.get("line_start"), span.get("column_start"), lint)
            if key in seen:
                continue  # the same source line seen through a lib and a bin target
            seen.add(key)
            counts[crate][lint] += 1
            hits[(crate, lint)].append(f"{file_name}:{span.get('line_start')}:{span.get('column_start')}")
            files[crate][file_name.split("cmux-tui/", 1)[-1]] += 1
    return checked, counts, files, finished, hits


def allow_without_reason(root):
    """Production-source allow/expect attributes on our lints that carry no reason."""
    bad = []
    for top in ("crates", "bindings"):
        bad.extend(_allow_scan(root, os.path.join(root, "cmux-tui", top)))
    return bad


def _allow_scan(root, crates_dir):
    bad = []
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
                text = open(path, encoding="utf-8", errors="replace").read()
            except OSError:
                continue
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


def report(checked, counts, files, fmt):
    rows = []
    for crate in sorted(checked | set(counts)):
        c = counts.get(crate, {})
        top = ", ".join(f"{f} {n}" for f, n in files.get(crate, collections.Counter()).most_common(3))
        rows.append((crate, c, is_deny(c), top))
    if fmt == "json":
        print(json.dumps({crate: {"counts": dict(c), "deny": deny, "top": top} for crate, c, deny, top in rows}, indent=1))
        return
    short = {"unwrap_used": "unwrap", "expect_used": "expect", "panic": "panic", "unreachable": "unreach",
             "todo": "todo", "unimplemented": "unimpl", "indexing_slicing": "index", "string_slice": "strslice",
             "panic_in_result_fn": "panic_in_result", "arithmetic_side_effects": "arith",
             "cast_possible_truncation": "cast_trunc"}
    print("| crate | " + " | ".join(short[l] for l in LINTS) + " | deny | top files |")
    print("|" + " --- |" * (len(LINTS) + 3))
    rows.sort(key=lambda r: -sum(r[1].get(l, 0) for l in DENY_LINTS))
    for crate, c, deny, top in rows:
        print(f"| {crate} | " + " | ".join(str(c.get(l, 0)) for l in LINTS) + f" | {'yes' if deny else 'no'} | {top} |")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--flags", action="store_true", help="print the clippy lint flags and exit")
    parser.add_argument("--clippy-json", help="cargo clippy --message-format=json output")
    parser.add_argument("--repo", default=REPO)
    parser.add_argument("--update-baseline", action="store_true", help="lower the baseline to the counts seen")
    parser.add_argument("--init-baseline", action="store_true", help="write the baseline from scratch (first run only)")
    parser.add_argument("--report", choices=["md", "json"])
    args = parser.parse_args()
    if args.flags:
        print(lint_flags())
        return 0
    if not args.clippy_json:
        parser.error("--clippy-json is required")
    checked, counts, files, finished, hits = read_clippy(args.clippy_json)
    if not checked or finished is not True:
        print("rust-panic-ratchet: the clippy run did not finish successfully (no build-finished success line);"
              " counts from a partial build prove nothing", file=sys.stderr)
        return 2
    if args.report:
        report(checked, counts, files, args.report)
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
              + "; lower scripts/cmux-next/rust-panic-baseline.json with --update-baseline in this commit,"
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
