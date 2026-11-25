#!/usr/bin/env python3
"""The cmux NEXT PR fast tier (hq#1915): every registered suite, every PR.

Entries live in scripts/cmux-next/fast-tier.json. Each has a name, an owner
lane, an optional bead and one of three kinds:
  swift   {package, filter}: `swift test --skip-build --filter` after one
          `swift build --build-tests` and one `swift test --list-tests` per package
  cargo   {path, package[, filter, lib]}: `cargo test --locked -p` in path; lib: true
          builds and runs only the package's library unit tests (`--lib`)
  script  {path[, args]}: python3 -I for a .py path, bash otherwise
An entry must be deterministic, need no window server or gui token, and finish
within --max-seconds (60) after the build. A swift or cargo entry whose filter
runs no test fails.

--kind KIND (repeatable) runs only the entries of those kinds, so one registry
feeds two CI jobs: cmux-next.yml's `fast-tier-cargo` job runs
`--kind cargo --kind script` and the Mac `fast-tier` job runs `--kind swift`.
A --kind that selects no entry is a bad registry (exit 2), never an empty pass.

--changed-files PATH (NUL- or newline-separated paths, a pull request's diff)
runs only the entries the change reaches and builds only their packages:
affected_jobs.py's crate graph for a cargo entry, cmux_next_route.py's test
targets for a CmuxNext suite, the package and its local dependencies for another
swift package, the script's folder for a script entry. The others print SKIP and
run in the post-merge batch (cmux-next-fast-tier-batch.yml). An unreadable list,
the full-ci label, a change to the runner or its registry, or any routing error
runs every entry (docs/ci/cmux-next-workflow-notes.md#note-559).

Flake policy: a failed entry runs once more only to classify it. Fail then pass
is FLAKY, and FLAKY fails the tier like FAIL: it is never silently retried. Its
owner quarantines it (scripts/cmux-next/quarantine.json, with a bead) or fixes
it. A quarantined entry still runs and reports QUARANTINED-PASS/-FAIL but does
not gate. --repeat N is the admission run: an entry gates only after N runs on
one head agree (ADMISSIBLE), and any mixed result is NOT-ADMISSIBLE.

Every result is one line, `FAST-TIER <STATUS> <name> <seconds>s owner=... bead=...`,
then the entry's output on failure. With `--receipt PATH`, the same run also
writes a compact JSON timing receipt for CI artifacts. Exit 0 when nothing
gating failed, 1 when something did, 2 for a bad registry.
"""
import argparse
import json
import os
from pathlib import Path
import re
import signal
import shlex
import subprocess
import sys
import threading
import time

KINDS = {"swift": ("package", "filter"), "cargo": ("path", "package"), "script": ("path",)}


def load_entries(path):
    entries = json.loads(Path(path).read_text())["entries"]
    names = set()
    for entry in entries:
        name = entry.get("name") or "<unnamed>"
        problems = []
        if entry.get("kind") not in KINDS:
            problems.append(f"kind must be one of {sorted(KINDS)}")
        else:
            problems += [f"{key} is required" for key in KINDS[entry["kind"]] if not entry.get(key)]
        if not entry.get("owner"):
            problems.append("owner is required (the lane that fixes or quarantines it)")
        if name in names:
            problems.append("duplicate name")
        names.add(name)
        if problems:
            print(f"fast-tier: entry {name}: " + "; ".join(problems), file=sys.stderr)
            raise SystemExit(2)
    return entries


def quarantined(path):
    if not path or not Path(path).exists():
        return set()
    return {e["name"] for e in json.loads(Path(path).read_text()).get("entries", [])}


# What changes every entry's run: the runner, its registry and quarantine list.
RUNNER_INPUTS = ("scripts/cmux-next/fast-tier.py", "scripts/cmux-next/fast-tier.json", "scripts/cmux-next/quarantine.json")
SWIFT_LOCAL_PACKAGE = re.compile(r'\.package\(\s*path:\s*"([^"]+)"')


def read_changed(path):
    """The changed paths in FILE (NUL- or newline-separated), or None when it cannot be read."""
    try:
        text = Path(path).read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return None
    return [item.strip() for item in re.split(r"[\0\n]", text) if item.strip()]


def event_labels():
    """The pull request's labels from $GITHUB_EVENT_PATH (empty when there is none)."""
    try:
        event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text(encoding="utf-8"))
    except (KeyError, OSError, ValueError):
        return set()
    return {str(label.get("name") or "") for label in (event.get("pull_request") or {}).get("labels") or []}


def _under(path, prefix):
    prefix = prefix.rstrip("/")
    return path == prefix or path.startswith(prefix + "/")


def _ci_modules(root):
    ci = str(Path(root).resolve() / "scripts" / "ci")
    if ci not in sys.path:
        sys.path.insert(0, ci)


def cargo_scope(root, entries, changed):
    """{name: why} for the cargo entries CHANGED reaches, through affected_jobs.py's crate graph (the crate the
    entry tests, everything it compiles and reads, and affected-jobs.json's workspace inputs), and whether the
    cargo compile is reached at all (a touched entry or a file the job itself reads)."""
    _ci_modules(root)
    import affected_jobs  # noqa: PLC0415 - scripts/ci
    import fast_tier_cargo_route  # noqa: PLC0415 - scripts/ci
    import git_tree  # noqa: PLC0415 - scripts/ci

    workspace, _ = affected_jobs.load_map((Path(root) / affected_jobs.MAP).read_text(encoding="utf-8"))
    graph = affected_jobs.Graph(git_tree.GitTree(Path(root)), workspace, [])
    touched = {}
    for entry in entries:
        crate = fast_tier_cargo_route.package_dir(Path(root), entry["path"], entry["package"])
        if crate is None:
            touched[entry["name"]] = f"no crate folder of {entry['path']} names {entry['package']}"
            continue
        reads = set(workspace) | set(fast_tier_cargo_route.LINKED)
        reads |= {graph.outside_submodule(item) for item in graph.crate(crate.rstrip("/"), (), True)}
        hit = next((path for path in changed if any(_under(path, read) for read in reads)), None)
        if hit:
            touched[entry["name"]] = f"{hit} is an input of {entry['package']}"
    compile_reads = fast_tier_cargo_route.JOB_INPUTS + tuple(workspace) + fast_tier_cargo_route.LINKED
    compile_hit = next((path for path in changed if any(_under(path, read) for read in compile_reads)), None)
    return touched, bool(touched) or compile_hit is not None


def script_scope(entries, changed):
    """{name: why} for the script entries CHANGED reaches: the script's own folder or what it reads."""
    import importlib  # noqa: PLC0415
    reads_outside = importlib.import_module("fast_tier_cargo_route").SCRIPT_INPUTS
    touched = {}
    for entry in entries:
        reads = (entry["path"].rsplit("/", 1)[0] + "/", *reads_outside)
        hit = next((path for path in changed if any(_under(path, read) for read in reads)), None)
        if hit:
            touched[entry["name"]] = f"{hit} is read by {entry['path']}"
    return touched


def swift_scope(root, entries, changed, labels):
    """{name: why} for the swift entries CHANGED reaches, and the packages whose compile it reaches. A CmuxNext
    entry: cmux_next_route.py routes every test (a change to every tier or the swift job), or a test target
    that holds the entry's suite, or names the suite as a priority suite. Another package's entry: a change
    under the package or a local package it uses."""
    _ci_modules(root)
    import cmux_next_route  # noqa: PLC0415 - scripts/ci

    touched, packages = {}, set()
    cmux_next = cmux_next_route.PACKAGE.rstrip("/")
    route = graph = None
    if any(entry["package"] == cmux_next for entry in entries):
        route = cmux_next_route.route(Path(root), "pull_request", changed, labels)
        graph = cmux_next_route.load_graph(Path(root))
        if route.fast_tier():
            packages.add(cmux_next)
    for entry in entries:
        if entry["package"] == cmux_next:
            if route.full or route.all_tests or route.fast_registry:
                why = "cmux_next_route.py routes every test"
            elif entry["filter"] in route.priority_suites:
                why = f"a changed file names {entry['filter']}"
            else:
                hit = sorted(cmux_next_route.suite_targets(Path(root), graph, entry["filter"]) & route.tests)
                why = f"cmux_next_route.py routes {', '.join(hit)}" if hit else None
        else:
            package = Path(root) / entry["package"]
            try:
                manifest = (package / "Package.swift").read_text(encoding="utf-8")
                local = [os.path.normpath(os.path.join(entry["package"], rel))
                         for rel in SWIFT_LOCAL_PACKAGE.findall(manifest)]
            except OSError:
                local = []
            hit = next((path for path in changed
                        if any(_under(path, read) for read in (entry["package"], *local))), None)
            why = f"{hit} is in {entry['package']} or a local package it uses" if hit else None
        if why:
            touched[entry["name"]] = why
            packages.add(entry["package"])
    return touched, packages


def scope(root, entries, changed, labels):
    """(entries to run, entries whose package to build, {name: why skipped}) for a pull request whose changed paths
    are CHANGED: only the entries the diff reaches run; the post-merge batch runs every entry at the merged
    head (cmux-next-fast-tier-batch.yml). An unread change, a full-ci label, a change to the runner or its
    registry, or a scope that cannot be read runs every entry."""
    if changed is None:
        return entries, entries, {}
    if "full-ci" in labels:
        return entries, entries, {}
    if any(path in RUNNER_INPUTS for path in changed):
        return entries, entries, {}
    by_kind = {kind: [e for e in entries if e["kind"] == kind] for kind in KINDS}
    touched, build_packages_of = {}, set()
    try:
        if by_kind["cargo"]:
            found, compile_reached = cargo_scope(root, by_kind["cargo"], changed)
            touched |= found
            if compile_reached:
                build_packages_of |= {("cargo", e["package"]) for e in by_kind["cargo"]}
        if by_kind["script"]:
            _ci_modules(root)
            touched |= script_scope(by_kind["script"], changed)
        if by_kind["swift"]:
            found, packages = swift_scope(root, by_kind["swift"], changed, labels)
            touched |= found
            build_packages_of |= {("swift", package) for package in packages}
    except Exception as error:  # noqa: BLE001 - an unread scope runs every entry
        print(f"fast-tier: could not scope the run to the change ({error!r}): every entry runs", file=sys.stderr)
        return entries, entries, {}
    for name, why in touched.items():
        print(f"fast-tier: {name}: {why}", flush=True)
    run = [e for e in entries if e["name"] in touched]
    build = [e for e in entries if e["name"] in touched or (e["kind"], e.get("package")) in build_packages_of]
    skipped = {e["name"]: "the change reaches none of its inputs; the post-merge batch runs it"
               for e in entries if e["name"] not in touched}
    return run, build, skipped


def command(entry):
    """(argv, working directory relative to the root) for one run of the entry."""
    kind = entry["kind"]
    if kind == "swift":
        return ["swift", "test", "--skip-build", "--package-path", entry["package"], "--filter", entry["filter"]], "."
    if kind == "cargo":
        argv = ["cargo", "test", "--locked", "-p", entry["package"], *cargo_targets(entry)]
        if entry.get("filter"):
            argv += ["--", entry["filter"]]
        return argv, entry["path"]
    runner = ["python3", "-I"] if entry["path"].endswith(".py") else ["bash"]
    return runner + [entry["path"], *entry.get("args", [])], "."


def cargo_targets(entry):
    """`--lib` for an entry whose tests are the library's own: without it `cargo test -p`
    builds every integration-test binary and doctest of the package, which the entry never runs
    (cmux-tui-core: 32 test binaries, 6.5 of the job's 9 min prebuild, job 137303235769)."""
    return ["--lib"] if entry.get("lib") else []


def describe(argv, cwd):
    text = shlex.join(argv)
    return text if cwd == "." else f"{text} (in {cwd})"


# Test counts in swift test (XCTest, Swift Testing) and cargo test output.
TEST_COUNTS = re.compile(r"Executed (\d+) tests?|Test run with (\d+) tests?|test result: \w+\. (\d+) passed")


def ran_no_test(entry, output):
    """A swift or cargo entry whose filter matched nothing: a renamed test must
    not silently leave the tier as a vacuous pass."""
    if entry["kind"] == "script":
        return False
    return not any(int(n) for match in TEST_COUNTS.findall(output) for n in match if n)


def descendants(pid):
    """Every live process below pid, from one ps table (macOS and Linux)."""
    try:
        out = subprocess.run(["ps", "-A", "-o", "pid=,ppid=,pgid="], capture_output=True, text=True,
                             timeout=10).stdout
    except (OSError, subprocess.SubprocessError):
        return []
    rows = [tuple(int(x) for x in line.split()) for line in out.splitlines() if len(line.split()) == 3]
    children = {}
    for child, parent, pgid in rows:
        children.setdefault(parent, []).append((child, pgid))
    found, todo = [], [pid]
    while todo:
        for child, pgid in children.get(todo.pop(), []):
            found.append((child, pgid))
            todo.append(child)
    return found


def stop_tree(pid):
    """SIGKILL the entry's process group and every process below it, in whatever
    group it sits: SwiftPM starts xctest in a group of its own. Never our own group."""
    mine = os.getpgrp()
    targets = descendants(pid)
    for group in {pid, *(pgid for _, pgid in targets)} - {mine}:
        try:
            os.killpg(group, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
    for child, _ in targets:
        try:
            os.kill(child, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass


def run_once(root, entry, max_seconds):
    argv, cwd = command(entry)
    started = time.monotonic()
    # Its own session, so a timeout stops everything the entry started: swift test
    # runs the tests in an xctest child that outlives it (cmux19, run 39360407187:
    # six orphan xctest processes after three timed-out entries).
    proc = subprocess.Popen(argv, cwd=root / cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, start_new_session=True)
    try:
        output, _ = proc.communicate(timeout=max_seconds)
        ok = proc.returncode == 0
        if ok and ran_no_test(entry, output):
            ok, output = False, output + "\nmatched no test: check the entry's filter"
    except subprocess.TimeoutExpired:
        stop_tree(proc.pid)
        try:
            output, _ = proc.communicate(timeout=5)
        except subprocess.TimeoutExpired:  # something outside the tree still holds the pipe
            proc.stdout.close()
            proc.wait()
            output = "(output cut off: a process outside the entry still held it)"
        ok, output = False, (output or "") + f"\ntimed out after {max_seconds}s"
    finally:
        # A child that outlived a finished entry dies with it too.
        stop_tree(proc.pid)
    return ok, time.monotonic() - started, output


def line(status, entry, seconds, extra=""):
    tail = f" {extra}" if extra else ""
    return f"FAST-TIER {status} {entry['name']} {seconds:.1f}s owner={entry['owner']} bead={entry.get('bead') or 'none'}{tail}"


def run_build(root, argv, cwd, what, log_lock):
    """One build, its output streamed line by line under a `[what]` prefix so a
    build running beside another stays readable. Returns (returncode, seconds, the
    lines naming a lock cargo refused to update under --locked)."""
    started = time.monotonic()
    # A cargo build runs inside fixit-compile (ci-oops 0a): when every error has a machine-applicable fix it writes
    # the fixup patch for fixit-compile-push and still exits with cargo's status.
    if argv[0] == "cargo" and FIXIT_COMPILE.is_file():
        argv = [sys.executable, "-I", str(FIXIT_COMPILE), "run", "--kind", "cargo", "--root", str(root), "--", *argv]
    proc = subprocess.Popen(argv, cwd=root / cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, errors="replace")
    # cargo's stale-lock refusal, kept for cargo-locks.py explain: the only lines a failed build's cause needs.
    refusals = []
    for output_line in proc.stdout:
        with log_lock:
            print(f"[{what}] {output_line.rstrip()}", flush=True)
        if STALE_LOCK_HINT in output_line:
            refusals.append(output_line)
    return proc.wait(), time.monotonic() - started, refusals


FIXIT_COMPILE = Path(__file__).resolve().parent.parent / "ci" / "oops" / "fixit_compile.py"

# The words every spelling of cargo's stale-lock refusal ends with (scripts/cmux-next/cargo-locks.py knows them all).
STALE_LOCK_HINT = "--locked was passed"


def stale_lock_explained(root, refusals):
    """True when REFUSALS hold cargo's stale-lock refusal: cargo-locks.py explain has then printed its cause and fix."""
    if not refusals:
        return False
    explain = [sys.executable, str(Path(__file__).resolve().parent / "cargo-locks.py"), "explain", "-",
               "--repo", str(Path(root).resolve())]
    return subprocess.run(explain, input="".join(refusals), text=True).returncode == 0


def build_packages(root, entries, dry_run, timing):
    """Builds every Swift package and cargo test binary once, outside the entries' time cap.

    The Swift builds and the cargo builds share no outputs, so the two groups run
    side by side (each group in order): on a warm runner the CmuxNext build
    (~160 s) and the cmux-tui test build (~115 s) used to run one after the other.
    """
    # After each Swift build, one `swift test --list-tests` pays the test run's
    # package planning outside the cap too: on the CmuxNext package the first
    # `swift test --skip-build` sat in "Planning build" past 60 s and timed out
    # before any test ran, and a killed plan is planned again by the next entry
    # (runs 41537871686, 41546766492).
    swift = [step
             for package in dict.fromkeys(e["package"] for e in entries if e["kind"] == "swift")
             for step in ((["swift", "build", "--build-tests", "--package-path", package], ".", package),
                          (["swift", "test", "--skip-build", "--list-tests", "--package-path", package], ".",
                           f"{package} test plan"))]
    # One build per cargo package, the same `-p` its entry runs with: one build of
    # `-p cmux-tui-core -p cmux-layout-reducer` unifies the two packages' dependency
    # features, so the reducer entry's own `cargo test -p cmux-layout-reducer`
    # rebuilt libc, serde_json and proptest inside its 60 s cap (57.6 s of build,
    # then a timeout: job 137088937648 on cmux-runner-pool).
    cargo = [(["cargo", "test", "--locked", "--no-run", "-p", package, *targets], path, f"{path} {package}")
             for path, package, targets in dict.fromkeys(
                 (e["path"], e["package"], tuple(cargo_targets(e))) for e in entries if e["kind"] == "cargo")]
    builds = swift + cargo
    if dry_run:
        for argv, cwd, what in builds:
            print("BUILD " + describe(argv, cwd), flush=True)
            timing.append({"name": what, "command": describe(argv, cwd), "seconds": 0.0, "status": "dry-run"})
        return True

    log_lock = threading.Lock()
    results = {}

    def run_group(group):
        for argv, cwd, what in group:
            with log_lock:
                print("BUILD " + describe(argv, cwd), flush=True)
            returncode, seconds, refusals = run_build(root, argv, cwd, what, log_lock)
            results[what] = (returncode, seconds, refusals)
            if returncode != 0:
                return

    threads = [threading.Thread(target=run_group, args=(group,)) for group in (swift, cargo) if group]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()

    ok = True
    for argv, cwd, what in builds:
        if what not in results:
            continue
        returncode, seconds, refusals = results[what]
        status = "pass" if returncode == 0 else "fail"
        timing.append({"name": what, "command": describe(argv, cwd), "seconds": round(seconds, 3), "status": status})
        if returncode != 0:
            if stale_lock_explained(root, refusals):
                print(f"FAST-TIER FAIL build:{what}: a stale Cargo.lock (cargo --locked refused it; the fix is above)",
                      flush=True)
            else:
                print(f"FAST-TIER FAIL build:{what}: the tests do not build", flush=True)
            ok = False
    return ok


def write_receipt(path, *, status, started_wall, builds, results, total_seconds, kinds=None):
    if not path:
        return
    cache = {}
    for kind in ("swift", "cargo"):
        key = os.environ.get(f"CMUX_FAST_{kind.upper()}_CACHE_KEY")
        hit = os.environ.get(f"CMUX_FAST_{kind.upper()}_CACHE_HIT")
        if key or hit:
            cache[kind] = {"key": key or "", "exact_hit": hit == "true"}
    # The seed a restore by prefix picked (cmux-next.yml fast-tier): a warm run
    # is told apart from a cold one even when no exact key hit.
    matched = os.environ.get("CMUX_FAST_CACHE_MATCHED_KEY")
    if matched:
        cache["matched_key"] = matched
    payload = {
        "schema": "cmux-next-fast-tier-receipt.v1",
        "status": status,
        "kinds": sorted(kinds) if kinds else sorted(KINDS),
        "started_at": started_wall,
        "total_seconds": round(total_seconds, 3),
        "build_seconds": round(sum(item["seconds"] for item in builds), 3),
        "builds": builds,
        "entries": [
            {"name": entry["name"], "status": result, "seconds": round(seconds, 3),
             "owner": entry["owner"], "bead": entry.get("bead") or "none"}
            for result, entry, seconds in results
        ],
        "cache": cache,
        "github": {
            key: os.environ[key]
            for key in ("GITHUB_EVENT_NAME", "GITHUB_SHA", "GITHUB_REF", "GITHUB_RUN_ID", "RUNNER_NAME")
            if os.environ.get(key)
        },
    }
    receipt = Path(path)
    receipt.parent.mkdir(parents=True, exist_ok=True)
    receipt.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    here = Path(__file__).resolve().parent
    parser.add_argument("--root", default=str(here.parent.parent), help="repository root")
    parser.add_argument("--registry", default=str(here / "fast-tier.json"))
    parser.add_argument("--quarantine", default=str(here / "quarantine.json"))
    parser.add_argument("--max-seconds", type=int, default=60, help="time cap per entry run, after the build")
    parser.add_argument("--only", action="append", default=[], help="run only this entry (repeatable)")
    parser.add_argument("--kind", action="append", default=[], choices=sorted(KINDS),
                        help="run only the entries of this kind (repeatable)")
    parser.add_argument("--repeat", type=int, default=0, help="admission: run each entry N times, no classify rerun")
    parser.add_argument("--dry-run", action="store_true", help="print the build and test commands only")
    parser.add_argument("--receipt", help="write a JSON timing receipt at this path")
    parser.add_argument("--changed-files",
                        help="a pull request's changed paths (NUL- or newline-separated): run only the entries "
                             "they reach and build only the compiles they reach (scope)")
    args = parser.parse_args()

    root = Path(args.root)
    entries = load_entries(args.registry)
    if args.only:
        entries = [e for e in entries if e["name"] in args.only]
    if args.kind:
        entries = [e for e in entries if e["kind"] in args.kind]
        if not entries:
            print(f"fast-tier: no entry of kind {', '.join(sorted(set(args.kind)))} to run", file=sys.stderr)
            return 2
    build_entries, skipped, registered = entries, {}, {e["name"]: e for e in entries}
    if args.changed_files:
        entries, build_entries, skipped = scope(root, entries, read_changed(args.changed_files), event_labels())
    held = quarantined(args.quarantine)
    started = time.monotonic()
    started_wall = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    builds = []
    skips = []
    for name, why in skipped.items():
        entry = registered[name]
        print(line("SKIP", entry, 0.0, why), flush=True)
        skips.append(("SKIP", entry, 0.0))
    if args.dry_run:
        build_packages(root, build_entries, True, builds)
        for entry in entries:
            print(f"RUN {entry['name']}: " + describe(*command(entry)))
        return 0
    if not build_packages(root, build_entries, False, builds):
        write_receipt(args.receipt, status="fail", started_wall=started_wall, builds=builds, results=[],
                      total_seconds=time.monotonic() - started, kinds=args.kind)
        return 1

    gating_failed = False
    results = list(skips)
    for entry in entries:
        if args.repeat:
            runs = [run_once(root, entry, args.max_seconds) for _ in range(args.repeat)]
            failed = sum(not ok for ok, _, _ in runs)
            seconds = max(s for _, s, _ in runs)
            if failed in (0, args.repeat):
                status, extra = "ADMISSIBLE", f"{args.repeat - failed}/{args.repeat} passed"
                if failed:
                    status, extra = "NOT-ADMISSIBLE", f"{failed}/{args.repeat} failed every time"
            else:
                status, extra = "NOT-ADMISSIBLE", f"{failed}/{args.repeat} failed: the result changes between runs"
            gating_failed |= status != "ADMISSIBLE"
            print(line(status, entry, seconds, extra), flush=True)
            if failed:
                print(next(out for ok, _, out in runs if not ok).rstrip(), flush=True)
            results.append((status, entry, seconds))
            continue
        ok, seconds, output = run_once(root, entry, args.max_seconds)
        status, extra = "PASS", ""
        if not ok:
            again, _, _ = run_once(root, entry, args.max_seconds)
            status = "FLAKY" if again else "FAIL"
            if again:
                extra = "failed, then passed on the classify run: fix it or quarantine it with a bead"
            elif "timed out after" in output:
                extra = f"timed out after {args.max_seconds}s"
            elif "matched no test" in output:
                extra = "matched no test: check the entry's filter"
        if entry["name"] in held:
            status = "QUARANTINED-PASS" if ok else "QUARANTINED-FAIL"
            extra = ""
        else:
            gating_failed |= status != "PASS"
        print(line(status, entry, seconds, extra), flush=True)
        if not ok:
            print(output.rstrip(), flush=True)
        results.append((status, entry, seconds))

    total = time.monotonic() - started
    write_receipt(args.receipt, status="fail" if gating_failed else "pass", started_wall=started_wall,
                  builds=builds, results=results, total_seconds=total, kinds=args.kind)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as out:
            build_total = sum(item["seconds"] for item in builds)
            heading = f"cmux NEXT fast tier ({', '.join(sorted(set(args.kind)))})" if args.kind else "cmux NEXT fast tier"
            out.write(f"### {heading}\n\n{len(results)} entries, {total:.0f}s total ({build_total:.0f}s build).\n\n")
            out.write("| Entry | Result | Seconds | Owner | Bead |\n| --- | --- | ---: | --- | --- |\n")
            for status, entry, seconds in results:
                out.write(f"| {entry['name']} | {status} | {seconds:.1f} | {entry['owner']} | {entry.get('bead') or 'none'} |\n")
    return 1 if gating_failed else 0


if __name__ == "__main__":
    sys.exit(main())
