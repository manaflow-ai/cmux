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

Shipped Rust workspaces outside cmux-tui/Cargo.toml (EXTRA_MANIFESTS: the
CCmuxAppFFI crates, cmux-rd-host, the remote browser hosts, Native/OptChat/*,
Native/DiffSidecar, cmux-next-ios/rust) are report-only. Each is linted from
its own directory, so rustup uses the rust-toolchain.toml that applies there
(1.95.0 for cmux-tui/* and cmux-next-ios/rust, 1.98.1 for Native/DiffSidecar;
Native/OptChat has no pin and uses the host's default toolchain), with no
target flags (the default targets are the lib and the bins; `--lib` fails on
a bin-only package) and with --locked when the workspace has a Cargo.lock
(delete the lock cargo writes for one that has none). From the repo root:
  FLAGS=$(rust_panic_ratchet.py --flags)
  for m in $(rust_panic_ratchet.py --list-manifests); do
    (cd "$(dirname "$m")" && cargo clippy --manifest-path "$PWD/Cargo.toml" --workspace \
      $([ -f Cargo.lock ] && echo --locked) --message-format=json -- $FLAGS) > "$(echo "$m" | tr / _).jsonl"
  done
and compared with one --manifest CARGO_TOML [LABEL=]JSONL per run (repeat a
manifest with linux= and macos= runs to merge them):
  rust_panic_ratchet.py --manifest Native/DiffSidecar/Cargo.toml linux=Native_DiffSidecar_Cargo.toml.jsonl ... --report md
A row is a package, named by its repo-relative directory. These rows live in
rust-panic-extra-baseline.json, which only a --manifest run reads or writes
and CI never reads: counts above it warn and exit 0, an unfinished run is
listed and exits 2 after the report of the rest, and rust-panic-baseline.json
is never read or written.
"""
import argparse
import collections
import json
import os
import posixpath
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
BASELINE = os.path.join(HERE, "rust-panic-baseline.json")
# Report-only rows of the separate workspaces (EXTRA_MANIFESTS); CI never reads this file.
EXTRA_BASELINE = os.path.join(HERE, "rust-panic-extra-baseline.json")
# Shipped Rust workspaces that cmux-tui/Cargo.toml does not build (each has its own [workspace]):
# plans/cmux-next/chrome-parity/p10-stability.md, "E. Rust".
EXTRA_MANIFESTS = [
    "cmux-tui/crates/cmux-app-ffi/Cargo.toml",
    "cmux-tui/crates/cmux-rd-ffi/Cargo.toml",
    "cmux-tui/crates/cmux-layout-reducer-ffi/Cargo.toml",
    "cmux-tui/crates/cmux-rd-host/Cargo.toml",
    "cmux-tui/crates/cmux-remote-browser-host/Cargo.toml",
    "cmux-tui/crates/cmux-remote-browser-testhost/Cargo.toml",
    "Native/OptChat/chief-turn/Cargo.toml",
    "Native/OptChat/optchat-chief/Cargo.toml",
    "Native/OptChat/optchat-core/Cargo.toml",
    "Native/OptChat/optchat-host/Cargo.toml",
    "Native/OptChat/optchat-wasm/Cargo.toml",
    "Native/DiffSidecar/Cargo.toml",
    "cmux-next-ios/rust/Cargo.toml",
]
LIB_KINDS = ("lib", "rlib", "bin", "cdylib", "staticlib", "proc-macro", "dylib")

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


def under_workspace(path, workspace):
    """`path` (absolute, or relative to the workspace root) as a repo-relative path inside `workspace`, else None.

    `workspace` is the repo-relative directory of a separate workspace's root manifest. An absolute path
    from any checkout keeps its part from that directory on, so runs on two hosts name a file alike.
    """
    path = path.replace("\\", "/")
    if not path.startswith("/"):
        path = posixpath.normpath(posixpath.join(workspace, path))
        return path if path == workspace or path.startswith(workspace + "/") else None
    padded = path + "/"
    at = padded.rfind(f"/{workspace}/")
    return None if at < 0 else padded[at + 1:].rstrip("/")


def package_dir(item):
    """The absolute directory of the package a cargo JSON line belongs to."""
    manifest = item.get("manifest_path")
    if manifest:
        return posixpath.dirname(manifest.replace("\\", "/"))
    match = re.search(r"path\+file://([^#)\s]+)", item.get("package_id", ""))
    return match.group(1) if match else None


class ClippyRun:
    """One clippy --message-format=json run: the crates it checked, whether it finished, its hits."""

    def __init__(self, label, workspace=None):
        self.label = label
        # A separate workspace's repo-relative root, or None for the cmux-tui workspace.
        self.workspace = workspace
        self.checked = set()
        self.finished = None
        # (workspace file, line, column, lint) -> crate, in first-seen order.
        self.hits = {}

    def crate(self, item):
        """The row a cargo JSON line counts under, or None for a package this run does not report."""
        if self.workspace is None:
            name = package_name(item.get("package_id", ""))
            return None if name in FROZEN_FIXTURES else name
        # A path dependency outside the workspace (cmux-app-ffi -> cmux-rd-ffi) has its own run.
        directory = package_dir(item)
        return under_workspace(directory, self.workspace) if directory else None


def read_run(path, label=None, workspace=None):
    """Read one clippy run; `workspace` names a separate workspace's repo-relative root (a --manifest run)."""
    run = ClippyRun(label or os.path.splitext(os.path.basename(path))[0], workspace)
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
                name = run.crate(item)
                if name and any(k in LIB_KINDS for k in item.get("target", {}).get("kind", [])):
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
            if lint not in LINTS:
                continue
            span = next((s for s in message.get("spans", []) if s.get("is_primary")), None)
            if span is None:
                continue
            file_name = span.get("file_name", "")
            if workspace is None:
                crate = crate_of(file_name) or package_name(item.get("package_id", ""))
                file_name = workspace_path(file_name)
            else:
                crate = run.crate(item)
                file_name = under_workspace(file_name, workspace)
            if crate is None or file_name is None:
                continue  # vendor/ or registry code: third-party
            if crate in FROZEN_FIXTURES:
                continue
            # The same source line seen through a lib and a bin target counts once.
            run.hits.setdefault((file_name, span.get("line_start"), span.get("column_start"), lint), crate)
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


def read_clippy(path):
    """One run: (checked crate set, {crate: {lint: count}}, {crate: {file: count}}, finished, hits)."""
    return merge_runs([read_run(path)])[:5]


def parse_run_arg(value):
    """`LABEL=PATH` or `PATH` (the label is then the file name without its extension)."""
    label, sep, path = value.partition("=")
    if sep and re.fullmatch(r"[A-Za-z0-9_.-]+", label) and not os.path.exists(value):
        return label, path
    return None, value


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


BASELINE_DOC = ("Per-crate clippy hit counts of production code (scripts/cmux-next/rust_panic_ratchet.py). "
                "Counts only go down. A crate with every deny lint at 0 is at deny.")
EXTRA_BASELINE_DOC = ("Report-only per-package clippy hit counts of the shipped Rust workspaces outside cmux-tui/Cargo.toml "
                      "(rust_panic_ratchet.py --manifest; rows are repo-relative package directories). CI never reads "
                      "this file. Counts only go down, through --manifest ... --update-baseline.")


def load_baseline(path=None):
    path = path or BASELINE
    if not os.path.exists(path):
        return {}
    with open(path, encoding="utf-8") as handle:
        return json.load(handle).get("crates", {})


def write_baseline(crates, path=None, doc=BASELINE_DOC):
    path = path or BASELINE
    data = {
        "_doc": doc,
        "lints": LINTS,
        "deny_lints": DENY_LINTS,
        "crates": {crate: {lint: crates[crate].get(lint, 0) for lint in LINTS} for crate in sorted(crates)},
    }
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(data, handle, indent=1, sort_keys=False)
        handle.write("\n")


def is_deny(lints):
    return all(lints.get(lint, 0) == 0 for lint in DENY_LINTS)


SHORT = {"unwrap_used": "unwrap", "expect_used": "expect", "panic": "panic", "unreachable": "unreach",
         "todo": "todo", "unimplemented": "unimpl", "indexing_slicing": "index", "string_slice": "strslice",
         "panic_in_result_fn": "panic_in_result", "arithmetic_side_effects": "arith",
         "cast_possible_truncation": "cast_trunc"}


def deny_total(lints):
    return sum(lints.get(lint, 0) for lint in DENY_LINTS)


def versus_baseline(counts, base):
    """A row's deny total against its baseline row: `new`, `=`, `+N` or `-N` (a --manifest report)."""
    if base is None:
        return "new"
    delta = deny_total(counts) - deny_total(base)
    return "=" if delta == 0 else f"{delta:+d}"


def report(checked, counts, files, fmt, only=None, baseline=None):
    """Print the per-crate table; `baseline` (a --manifest report) adds each row's deny total against it."""
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
            if baseline is not None:
                out[crate]["baseline"] = baseline.get(crate)
            if only:
                out[crate]["only_in"] = {label: [{"loc": loc, "lint": lint} for loc, lint in sorted(by_crate.get(crate, []))]
                                         for label, by_crate in only.items()}
        print(json.dumps(out, indent=1))
        return
    extra = baseline is not None
    print("| crate | " + " | ".join(SHORT[l] for l in LINTS) + " | deny |" + (" vs baseline |" if extra else "")
          + " top files |")
    print("|" + " --- |" * (len(LINTS) + 3 + extra))
    rows.sort(key=lambda r: -deny_total(r[1]))
    for crate, c, deny, top in rows:
        delta = f" {versus_baseline(c, baseline.get(crate))} |" if extra else ""
        print(f"| {crate} | " + " | ".join(str(c.get(l, 0)) for l in LINTS) + f" | {'yes' if deny else 'no'} |{delta} {top} |")
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


def workspace_of(repo, manifest):
    """A --manifest argument as the repo-relative directory of that workspace's root, or None if absent."""
    rel = posixpath.normpath(manifest.replace("\\", "/"))
    if posixpath.basename(rel) == "Cargo.toml":
        rel = posixpath.dirname(rel)
    if rel.startswith("../") or rel.startswith("/") or not os.path.isfile(os.path.join(repo, rel, "Cargo.toml")):
        return None
    return rel


def main_extra(args, parser):
    """Report-only rows of the separate shipped workspaces (--manifest); reads only EXTRA_BASELINE."""
    if args.clippy_json:
        parser.error("--manifest runs are report-only and never mix with the --clippy-json run of cmux-tui, whose "
                     "baseline CI reads; run them as two commands")
    if not (args.report or args.update_baseline or args.init_baseline):
        parser.error("--manifest is report-only: add --report md|json, or --update-baseline / --init-baseline to "
                     "write rust-panic-extra-baseline.json")
    groups = {}
    for manifest, value in args.manifest:
        workspace = workspace_of(args.repo, manifest)
        if workspace is None:
            parser.error(f"--manifest {manifest}: no Cargo.toml there (give a path relative to the repo root)")
        label, path = parse_run_arg(value)
        run = read_run(path, label, workspace)
        if any(other.label == run.label for other in groups.get(workspace, [])):
            parser.error(f"two --manifest {workspace} runs are labelled {run.label!r}; name them LABEL=PATH")
        groups.setdefault(workspace, []).append(run)

    unfinished = sorted(f"{workspace} ({run.label})" for workspace, runs in groups.items() for run in runs
                        if not run.checked or run.finished is not True)
    checked, counts, files, hits, only = set(), {}, {}, {}, {}
    for workspace, runs in sorted(groups.items()):
        if any(not run.checked or run.finished is not True for run in runs):
            continue  # counts from a partial build prove nothing; listed below
        # Merged per workspace, so a macOS run of one workspace does not mark another's hits Linux-only.
        ws_checked, ws_counts, ws_files, _, ws_hits, ws_only = merge_runs(runs)
        checked |= ws_checked
        counts.update(ws_counts)
        files.update(ws_files)
        hits.update(ws_hits)
        for label, by_crate in ws_only.items():
            only.setdefault(label, collections.defaultdict(list)).update(by_crate)
    listed = {posixpath.dirname(m) for m in EXTRA_MANIFESTS}
    not_run = sorted(listed - set(groups))

    baseline = {} if args.init_baseline else load_baseline(EXTRA_BASELINE)
    if args.report:
        report(checked, counts, files, args.report, only, baseline)
    if args.report == "md":
        for title, items in (("Separate workspaces not in this run", not_run),
                             ("Runs that did not finish (no rows)", unfinished)):
            if items:
                print(f"\n### {title} ({len(items)})\n")
                print("\n".join(f"- {item}" for item in items))

    grew = []
    for crate in sorted(checked):
        base = baseline.get(crate)
        now = counts.get(crate, collections.Counter())
        if base is not None and not args.init_baseline:
            grew.extend(f"{crate}: clippy::{lint} {now.get(lint, 0)} > baseline {base.get(lint, 0)}"
                        for lint in LINTS if now.get(lint, 0) > base.get(lint, 0))
    for line in grew:
        print(f"::warning title=rust panic ratchet (report-only)::{line}", file=sys.stderr)
    for crate in sorted(checked):
        for line in _allow_scan(args.repo, os.path.join(args.repo, crate, "src")):
            print(f"::warning title=rust panic ratchet (report-only)::{line}", file=sys.stderr)

    if args.init_baseline or args.update_baseline:
        merged = dict(baseline)
        for crate in checked:
            now = counts.get(crate, collections.Counter())
            base = merged.get(crate)
            # Report-only: a new row records its debt as found; an existing row only goes down.
            merged[crate] = {l: now.get(l, 0) if base is None else min(now.get(l, 0), base.get(l, 0)) for l in LINTS}
        write_baseline(merged, EXTRA_BASELINE, EXTRA_BASELINE_DOC)
        print(f"rust-panic-ratchet: wrote {len(checked)} row(s) of {os.path.relpath(EXTRA_BASELINE, args.repo)}"
              + (f"; kept the old rows of {len(unfinished)} unfinished run(s)" if unfinished and args.update_baseline else ""), file=sys.stderr)

    deny = sorted(c for c in checked if is_deny(counts.get(c, {})))
    print(f"rust-panic-ratchet: report-only, {len(groups)} separate workspace(s), {len(checked)} crates checked, "
          f"{len(deny)} at deny, {len(grew)} count(s) above rust-panic-extra-baseline.json", file=sys.stderr)
    if not_run:
        print("::warning title=rust panic ratchet (report-only)::separate workspaces not in this run: "
              + ", ".join(not_run), file=sys.stderr)
    if unfinished:
        print("rust-panic-ratchet: these clippy runs did not finish successfully (no build-finished success line), "
              "so they have no rows: " + ", ".join(unfinished), file=sys.stderr)
        return 2
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
    parser.add_argument("--manifest", action="append", nargs=2, metavar=("CARGO_TOML", "[LABEL=]JSONL"),
                        help="report-only: one clippy run of a separate workspace (repo-relative manifest path); "
                             "repeat per workspace and per run")
    parser.add_argument("--list-manifests", action="store_true",
                        help="print the separate shipped workspaces' manifests (EXTRA_MANIFESTS) and exit")
    args = parser.parse_args()
    if args.flags:
        print(lint_flags())
        return 0
    if args.list_manifests:
        print("\n".join(EXTRA_MANIFESTS))
        return 0
    if args.manifest:
        return main_extra(args, parser)
    if not args.clippy_json:
        parser.error("--clippy-json is required")
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
