#!/usr/bin/env python3
"""Fast guards for one car of the nightly train (workstreams/cmux-next-nightly-train.md 1.2).

A car is a squash-merged PR or one direct push: a commit range BASE..HEAD on feat-cmux-next.
Its fast guards run on that range's own diff, in seconds to minutes, on a CI runner (never
on cosmic-gray or air-blue). A car that fails one is quarantined before the candidate build.

    car_guards.py plan --base B --head H [--car ID]           # what would run, as JSON
    car_guards.py run  --base B --head H [--car ID] --where linux|mac [--prior P] [--receipt R]

The checkout must be at HEAD with BASE's commit present (fetch-depth covers the range).

--where linux  the repo guards and the Linux-able focused tests:
                 guard:prepush     scripts/cmux-next/prepush-gate.py --base B --head H
                                   (the checks job's scanners, ast-grep, swiftformat, swiftlint;
                                   only what the car adds, never base debt)
                 guard:godfiles    scripts/cmux-next/check-no-godfiles.sh --base B
                                   (an entry fails only when the car grows it past its budget)
                 python:<test>     tests the focused map selects in the linux-guard lane
                 cargo             cargo test --locked on cargo_affected.py's crates (cmux-tui
                                   changes only; the crates that own a file plus their dependents)
                 native:<manifest> cargo test --locked on a Native/ workspace the car touches
                 web               run-webviews-tests.sh on the focused webviews files (one bun
                                   process each; needs `bun install` in webviews/ first)
--where mac    swift-build:<pkg>  one build of the package's tests, then
               swift:<T>          one --skip-build run per selected test target

--kinds guard,python runs only those kinds (the train's in-process adapter,
scripts/ci/nightly-next-car-guard.sh, runs the cheap ones on its own runner).

--prior FILE reuses the car's own PR CI: a JSON object of check name -> conclusion at the car's
exact tree. A kind whose PR checks all passed is skipped and reported as reused (REUSE below), so
the train never re-runs what already passed. The planner decides that the trees match.

Flakes: scripts/cmux-next/quarantine.json (the fast tier's list) also holds car-guard entries by
name (`python:tests/test_x.py`, `swift:CmuxNextFilesTests`). A quarantined entry still runs and
is reported, but does not fail the car.

Only the car's own reds fail it. A failed python test, or webviews file, that exists at BASE runs
again in a worktree of BASE (webviews only when webviews/bun.lock is unchanged); a real failure
there too (not a timeout) makes it `base-red` and it does not fail the car. Webviews files are
judged one by one. Cargo, native and Swift reds are never excused. A runner missing one of its
own tools (bun, cargo, swift, zig) or pinned modules (yaml, bashlex) is `error`; any other
missing module or command is the car's red. An internal crash exits 2, never 1. god files over its allowance is `warn`, as on
the checks job (GODFILES_WARN_SLACK=20). Browser-lane webviews files and a Swift selection of a
whole package (a manifest or target-graph change) are `deferred` to the candidate build.

A busy runner makes the guards slower, never red (cmux#41742's class). A guard or python entry that times out is
retried once, alone, with a longer limit (RETRY_TIMEOUT), the entries the car touches first. If it times out again,
it fails the car only when the car touches what it runs: a focused test, webviews file, crate or Swift target is
selected by the car's own change, so its timeout fails; a guard runs on every car, so its timeout fails only when
the car changes the guard's folder, and otherwise is `warn` naming the guard. Heavy entries already run alone and
fill the job's time, so they are not retried.

The whole run has one deadline (--deadline, CAR_GUARDS_DEADLINE, default 1500 s, under the train's 1800 s bound):
each entry, retry and base re-run takes at most the time left, and one that cannot start is `unrun` (named in the
verdict, status `error`), so a slow car ends with a verdict instead of being killed with none.

The verdict (stdout, and --receipt) is one JSON object: {"car", "base", "head", "where",
"status": "pass"|"fail"|"error", "results": [{"name", "kind", "status", "seconds", "tail"}],
"reused": [...], "deferred": [...], "unmapped": [...]}. Exit 0 on pass, 1 on fail (the car's
own red), 2 on error or bad input.
"""
from __future__ import annotations

import argparse
import ast
import concurrent.futures
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import focused_tests  # noqa: E402
from ci_process_tree import run_bounded  # noqa: E402

QUARANTINE = "scripts/cmux-next/quarantine.json"
LINUX_LANES = {"linux-guard"}
# The PR checks that already cover a kind exactly. A kind is reused when at least one check
# matches and every matching check passed (a skipped tier proved nothing). Python and webviews
# are never reused: no PR job runs the car's focused set (the checks job runs a fixed list, and
# ci-web's `web / Web tests` is web/, not webviews/).
REUSE = {
    "guard": ("cmux-next checks (god files, concurrency, crash safety, l10n)",),
    "cargo": ("cmux-next fast tier (cargo)",),
    "swift": ("cmux-next fast tier", "cmux-next swift test"),
}
PASSING = {"success", "neutral"}
CHEAP = {"guard", "python"}
TIMEOUT = {"guard": 600, "python": 300, "cargo": 1500, "swift": 900, "swift-build": 2400, "web": 1200}
# A cheap entry that timed out runs again alone with this limit. Heavy kinds already run alone.
RETRY_TIMEOUT = {"guard": 900, "python": 450}
# Seconds the retries of entries the car does not touch may start within; past it they are not retried (and warn).
RETRY_BUDGET = 900
JOBS = int(os.environ.get("CAR_GUARDS_JOBS", str(max(2, (os.cpu_count() or 4)))))
# A planned python file with at least SHARD_MIN_TESTS test methods in at least two TestCase classes runs as SHARDS
# commands, its classes split across them by test count, side by side in the cheap pool; its verdict stays one result.
# Run 46068974948's class: a 681-file car ran tests/test_base_red_excuse.py (1139 tests, ~254 s) and
# tests/test_app_ffi_release_workflow.py (131 tests, ~202-354 s) each as one command, the car's longest entries.
SHARD_MIN_TESTS = int(os.environ.get("CAR_GUARDS_SHARD_MIN_TESTS", "100"))
SHARDS = int(os.environ.get("CAR_GUARDS_SHARDS", str(max(2, (os.cpu_count() or 4) // 8))))
# The whole car's bound, in seconds. The train stops a car guard at 1800 s and keeps nothing it did (run 46068974948:
# pr-62654 and pr-58290 each "timed out after 1800 seconds", no verdict, no name of what was slow). Every entry takes
# at most the time left, so a slow car ends before the train's bound with a verdict that names what it did not run.
DEADLINE = float(os.environ.get("CAR_GUARDS_DEADLINE", "1500"))
# Below this many seconds left an entry is not started (it could not finish), and is `unrun`.
MIN_SLICE = 10.0
_deadline_at: float | None = None


def time_left() -> float | None:
    return None if _deadline_at is None else _deadline_at - time.monotonic()
# Only the runner's own tools and pinned modules make a red the runner's: anything else a test
# cannot import or run is the car's (it may have deleted or renamed it).
MISSING_TOOL = re.compile(r"ModuleNotFoundError: No module named '(yaml|bashlex)'|\b(bun|cargo|swift|zig): command not found")
WEB_RESULT = re.compile(r"^(FAIL|TIMEOUT) (?:\./)?(\S+) \(limit ", re.M)
# A red entry's log is its output's last TAIL_CHARS, plus every failing-test line the cut dropped (NAMED_FAILURE, at
# most NAMED_LINES), so the job log names each failure its runner's summary counts. Run 45372757083 (cmux#50304, job
# 'car guards (portable)'): tests/test_base_red_excuse.py's tail kept 6 of its 27 `FAIL:` lines under `FAILED
# (failures=27, errors=1, skipped=1)`, and base_red_excuse.py refused the job as "its log reports more failing tests
# than it names" (test_reds.runner_unnamed), so no failure in it could be compared with anything.
TAIL_CHARS = 4000
NAMED_LINES = 400
NAMED_FAILURE = re.compile(r"^(?:FAIL|ERROR): \S+ \(|^FAILED \S+::\S")  # unittest, pytest (test_reds.FAILED)


def reused_kinds(prior: dict[str, str]) -> set[str]:
    """Kinds whose covering checks are present in `prior` and all passed."""
    lowered = {name.lower(): (value or "").lower() for name, value in prior.items()}
    out = set()
    for kind, checks in REUSE.items():
        found = [lowered[c.lower()] for c in checks if c.lower() in lowered]
        if found and all(value in PASSING for value in found):
            out.add(kind)
    return out


def quarantined(root: Path) -> set[str]:
    path = root / QUARANTINE
    if not path.is_file():
        return set()
    return {e["name"] for e in json.loads(path.read_text(encoding="utf-8")).get("entries", []) if e.get("name")}


def entries(root: Path, base: str, head: str, where: str, the_plan: dict, skip: set[str]) -> list[dict]:
    """The commands this runner runs, as {name, kind, cmd, cwd, env, serial, needs}."""
    out = []
    if where == "linux":
        if "guard" not in skip:
            # A guard runs on every car; its own folder is what a car changes to touch it.
            out.append({"name": "guard:prepush", "kind": "guard", "inputs": ["scripts/cmux-next/"],
                        "cmd": [sys.executable, "-I", "scripts/cmux-next/prepush-gate.py", "--base", base, "--head", head]})
            # As the checks job runs it: warn-only over the allowance (rc 1 is ratchet debt, a
            # warning on the PR), so the train is no stricter than PR CI.
            out.append({"name": "guard:godfiles", "kind": "guard", "warn_codes": [1], "inputs": ["scripts/cmux-next/"],
                        "env": {"GODFILES_WARN_SLACK": "20"},
                        "cmd": ["bash", "scripts/cmux-next/check-no-godfiles.sh", "--base", base]})
        for test in the_plan["python"]:
            if test["lane"] in LINUX_LANES:
                out.extend(python_entries(root, test["path"], test.get("serial", False)))
        web = [t["path"] for t in the_plan["web"] if not t.get("browser")]
        if web:
            out.append({"name": "web", "kind": "web", "cwd": "webviews",
                        "env": {"CMUX_WEB_TEST_FILES": "\n".join(web)},
                        "cmd": ["bash", str(HERE / "run-webviews-tests.sh")]})
        # A Native/ workspace has no PR job to reuse.
        for crate in the_plan["native"]:
            out.append({"name": f"native:{crate['manifest']}", "kind": "cargo",
                        "cmd": ["cargo", "test", "--locked", "--manifest-path", crate["manifest"]]})
        if "cargo" not in skip and the_plan["cargo"]["changed"]:
            out.append({"name": "cargo", "kind": "cargo", "cwd": "cmux-tui",
                        "cmd": [sys.executable, "-I", str(HERE / "cargo_affected.py"), "--root", "..",
                                "--base", base, "--head", head, "--", "cargo", "test", "--locked"]})
    elif where == "mac" and "swift" not in skip:
        packages: dict[str, list[str]] = {}
        for test in the_plan["swift"]:
            packages.setdefault(test["package"], []).append(test["filter"])
        for package, filters in sorted(packages.items()):
            # One build per package; each filter is its own entry on that build.
            build = f"swift-build:{package}"
            out.append({"name": build, "kind": "swift-build",
                        "cmd": ["swift", "build", "--build-tests", "--package-path", package]})
            for name in filters:
                out.append({"name": f"swift:{name}", "kind": "swift", "needs": build,
                            "cmd": ["swift", "test", "--skip-build", "--package-path", package, "--filter", f"^{name}\\."]})
    return out


TESTCASE_BASES = {"TestCase", "IsolatedAsyncioTestCase"}


def test_classes(source: str) -> dict[str, int] | None:
    """{class: test methods} for every module-level unittest.TestCase subclass in SOURCE, in file order, or None when
    the file cannot be split safely by class: it does not parse, does not end in unittest.main() (or
    unittest_shard.main()), defines load_tests, builds a TestCase class anywhere but the module's top level, or
    derives one from a base this file does not define (its tests could not be counted, nor the class named alone)."""
    try:
        tree = ast.parse(source)
    except (SyntaxError, ValueError):
        return None
    mains = [node for node in tree.body if isinstance(node, ast.If) and "__main__" in ast.unparse(node.test)]
    if not any(isinstance(call, ast.Call) and isinstance(call.func, ast.Attribute) and call.func.attr == "main"
               and isinstance(call.func.value, ast.Name) and call.func.value.id in ("unittest", "unittest_shard")
               for node in mains for call in ast.walk(node)):
        return None
    top = {node.name: node for node in tree.body if isinstance(node, ast.ClassDef)}
    if any(isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name == "load_tests" for node in tree.body):
        return None
    nested = [node for node in ast.walk(tree) if isinstance(node, ast.ClassDef) and top.get(node.name) is not node]
    if any(any(isinstance(b, (ast.Name, ast.Attribute)) and ast.unparse(b).split(".")[-1] in TESTCASE_BASES
               for b in node.bases) for node in nested):
        return None

    def base_names(node: ast.ClassDef) -> list[str]:
        return [ast.unparse(b) for b in node.bases]

    def is_case(name: str, seen: frozenset = frozenset()) -> bool | None:
        """True a TestCase, False not one, None unknown (a base from elsewhere)."""
        node = top.get(name)
        if node is None or name in seen:
            return None
        verdicts = []
        for base in base_names(node):
            if base in ("object",):
                verdicts.append(False)
            elif base.split(".")[-1] in TESTCASE_BASES and (base.startswith("unittest.") or base in TESTCASE_BASES):
                verdicts.append(True)
            elif base in top:
                verdicts.append(is_case(base, seen | {name}))
            else:
                verdicts.append(None)
        if True in verdicts:
            return True if None not in verdicts else None
        return None if None in verdicts else False

    def tests_of(name: str, seen: frozenset = frozenset()) -> set[str]:
        node = top[name]
        own = {item.name for item in node.body
               if isinstance(item, (ast.FunctionDef, ast.AsyncFunctionDef)) and item.name.startswith("test")}
        for base in base_names(node):
            if base in top and base not in seen:
                own |= tests_of(base, seen | {name})
        return own

    out: dict[str, int] = {}
    for name in top:
        verdict = is_case(name)
        if verdict is None:
            # A class with bases from elsewhere is only a problem when it might be a TestCase with tests.
            if any(b.split(".")[-1] not in ("object",) for b in base_names(top[name])) and tests_of(name):
                return None
            continue
        if verdict and tests_of(name):
            out[name] = len(tests_of(name))
    return out


def python_entries(root: Path, path: str, serial: bool = False) -> list[dict]:
    """The entries that run the python test file PATH: one command for the file, or, for a large file (SHARD_MIN_TESTS
    tests in two or more TestCase classes), up to SHARDS commands that each run some of its classes by name, balanced
    by test count. Shards run the file as the whole-file entry does (`python3 FILE Class ...`: `-I -m unittest
    tests.test_x.Class` cannot import a file under tests/, which is no package, since -I puts no folder on sys.path),
    and merge_shards folds their results back into one `python:FILE` verdict."""
    name = f"python:{path}"
    whole = {"name": name, "kind": "python", "serial": serial, "cmd": [sys.executable, path]}
    if serial or SHARDS < 2:
        return [whole]
    try:
        source = (root / path).read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return [whole]
    classes = test_classes(source)
    if not classes or len(classes) < 2 or sum(classes.values()) < SHARD_MIN_TESTS:
        return [whole]
    count = min(SHARDS, len(classes))
    groups: list[list[str]] = [[] for _ in range(count)]
    weight = [0] * count
    # Largest class first onto the lightest shard; each shard keeps its classes in file order.
    order = {cls: n for n, cls in enumerate(classes)}
    for cls in sorted(classes, key=lambda c: (-classes[c], order[c])):
        slot = min(range(count), key=lambda i: (weight[i], i))
        groups[slot].append(cls)
        weight[slot] += classes[cls]
    out = []
    for index, group in enumerate(groups, 1):
        group.sort(key=order.__getitem__)
        out.append({"name": f"{name}#{index}/{count}", "kind": "python", "file": name, "classes": group,
                    "tests": weight[index - 1], "cmd": [sys.executable, path, *group]})
    return out


# Worst first: a file's merged status is its worst shard's. A timeout outranks a failure, so a file one shard of
# which timed out is never excused as base-red on another shard's failure alone.
SHARD_RANK = ["timeout", "fail", "quarantined-fail", "error", "unrun", "retry", "skipped", "warn", "base-red", "pass"]


def merge_shards(todo: list[dict], results: list[dict]) -> list[dict]:
    """RESULTS with each sharded file's shard results folded into one `python:FILE` result, in the place of its first
    shard: it passes only when every shard passed, takes its worst shard's status otherwise, and its tail names
    each shard that did not pass and the classes it ran (a timed-out shard, the classes that timed out)."""
    by_name = {e["name"]: e for e in todo}
    out: list[dict] = []
    merged: dict[str, dict] = {}
    for result in results:
        entry = by_name.get(result["name"], {})
        file = entry.get("file")
        if not file:
            out.append(result)
            continue
        whole = merged.get(file)
        if whole is None:
            whole = merged[file] = {"name": file, "kind": "python", "status": "pass", "seconds": 0.0, "tail": "",
                                    "shards": []}
            out.append(whole)
        whole["shards"].append({"name": result["name"], "classes": entry["classes"], "status": result["status"],
                                "seconds": result["seconds"]})
        # Shards run side by side: the file took as long as its slowest shard.
        whole["seconds"] = max(whole["seconds"], result["seconds"])
        if SHARD_RANK.index(result["status"]) < SHARD_RANK.index(whole["status"]):
            whole["status"] = result["status"]
        if result["status"] != "pass":
            what = "timed out" if result["status"] == "timeout" else result["status"]
            whole["tail"] += (f"shard {result['name'].rsplit('#', 1)[1]} {what}, classes: {', '.join(entry['classes'])}\n"
                              + result.get("tail", "") + "\n")
    return out


def touches(entry: dict, files: list[str]) -> bool:
    """Whether the car's FILES change what ENTRY runs. An entry without "inputs" was selected by the car's own
    change (a focused test, webviews file, crate or Swift target), so it is touched."""
    inputs = entry.get("inputs")
    if inputs is None:
        return True
    return any(path == item or (item.endswith("/") and path.startswith(item)) for path in files for item in inputs)


def run_one(root: Path, entry: dict, timeout: float | None = None) -> dict:
    start = time.monotonic()
    timeout = timeout or TIMEOUT[entry["kind"]]
    left = time_left()
    if left is not None:
        if left < MIN_SLICE:
            return {"name": entry["name"], "kind": entry["kind"], "status": "unrun", "seconds": 0,
                    "tail": f"not run: the car's {DEADLINE:.0f}s deadline was spent"}
        timeout = min(timeout, left)
    try:
        # A timed-out entry is stopped with everything it started, so its retry and the next entries never race it.
        proc = run_bounded(entry["cmd"], cwd=root / entry.get("cwd", "."), capture_output=True, text=True,
                           timeout=timeout, env={**os.environ, **entry.get("env", {})})
        output = proc.stdout + proc.stderr
        if proc.returncode == 0:
            status = "pass"
        elif proc.returncode in entry.get("warn_codes", ()):
            status = "warn"
        elif MISSING_TOOL.search(output):
            status = "error"  # the runner lacks a tool or module: not the car's fault
        else:
            status = "fail"
    except FileNotFoundError as error:
        status, output = "error", str(error)
    except subprocess.TimeoutExpired as error:
        # Not a verdict yet: retry_timeouts runs it again and decides whose red it is. Never a base red at the base.
        status = "retry"
        partial = error.stdout or ""
        output = f"timed out after {timeout}s\n" + (partial.decode(errors="replace") if isinstance(partial, bytes) else partial)
    result = {"name": entry["name"], "kind": entry["kind"], "status": status,
              "seconds": round(time.monotonic() - start, 1), "tail": tail_of(output) if status != "pass" else ""}
    if entry["kind"] == "web" and status in ("fail", "retry"):
        result["files"] = {m.group(2): m.group(1) for m in WEB_RESULT.finditer(output)}
    return result


def tail_of(output: str) -> str:
    """OUTPUT's last TAIL_CHARS, after the failing-test lines (NAMED_FAILURE) of the part cut off: each failure keeps
    its name in the job log, printed once."""
    if len(output) <= TAIL_CHARS:
        return output
    cut = output[:-TAIL_CHARS]
    # The cut's last piece runs on into the tail, which prints it (or its end): never repeated here.
    named = [line.rstrip("\r") for line in cut.split("\n")[:-1] if NAMED_FAILURE.match(line)]
    if not named:
        return output[-TAIL_CHARS:]
    more = f"... and {len(named) - NAMED_LINES} more\n" if len(named) > NAMED_LINES else ""
    return ("failing tests before the tail:\n" + "\n".join(named[:NAMED_LINES]) + "\n" + more
            + "...\n" + output[-TAIL_CHARS:])


def run_all(root: Path, todo: list[dict]) -> list[dict]:
    """Cheap first: the guards and python tests side by side (a `serial` test alone after them),
    then the heavy entries one at a time (each is parallel inside itself). An entry whose
    `needs` did not pass is skipped."""
    by_name: dict[str, dict] = {}
    cheap = [e for e in todo if e["kind"] in CHEAP and not e.get("serial")]
    # A large file's shards start first, heaviest first, so the car's longest work never starts last.
    cheap.sort(key=lambda e: -e.get("tests", 0))
    with concurrent.futures.ThreadPoolExecutor(max_workers=JOBS) as pool:
        for result in pool.map(lambda e: run_one(root, e), cheap):
            by_name[result["name"]] = result
    for entry in [e for e in todo if e["kind"] in CHEAP and e.get("serial")] + [e for e in todo if e["kind"] not in CHEAP]:
        need = entry.get("needs")
        if need and by_name.get(need, {}).get("status") != "pass":
            by_name[entry["name"]] = {"name": entry["name"], "kind": entry["kind"], "status": "skipped",
                                      "seconds": 0, "tail": f"{need} did not pass"}
            continue
        by_name[entry["name"]] = run_one(root, entry)
    return [by_name[e["name"]] for e in todo]


def retry_timeouts(root: Path, todo: list[dict], results: list[dict], files: list[str]) -> None:
    """Settles each entry run_one left at `retry` (it timed out). A cheap one runs again alone with its RETRY_TIMEOUT,
    touched ones first; a heavy one is not retried. One that timed out for good is `timeout` (the car's red) when
    the car touches what it runs, and `warn` naming it otherwise."""
    by_name = {e["name"]: e for e in todo}
    timed_out = sorted((r for r in results if r["status"] == "retry"),
                       key=lambda r: (not touches(by_name[r["name"]], files), r["name"]))
    started = time.monotonic()
    for result in timed_out:
        entry = by_name[result["name"]]
        touched = touches(entry, files)
        first = TIMEOUT[entry["kind"]]
        retry = RETRY_TIMEOUT.get(entry["kind"])
        if retry is None:
            how = f"timed out after {first}s"
        elif touched or time.monotonic() - started <= RETRY_BUDGET:
            again = run_one(root, entry, timeout=retry)
            again["seconds"] = round(result["seconds"] + again["seconds"], 1)
            result.update(again)
            if result["status"] != "retry":
                continue
            how = f"timed out after {first}s, and again after {retry}s alone"
        else:
            how = f"timed out after {first}s; not retried, the {RETRY_BUDGET}s retry budget was spent"
        if touched:
            result["status"] = "timeout"
            result["tail"] = f"{how}: this car changes what it runs\n" + result["tail"]
        else:
            result["status"] = "warn"
            result["tail"] = (f"{how} on this runner and is not checked; this car does not touch "
                              f"{', '.join(entry['inputs'])}, so it does not fail the car\n" + result["tail"])


def exists_at(root: Path, rev: str, path: str) -> bool:
    return subprocess.run(["git", "-C", str(root), "cat-file", "-e", f"{rev}:{path}"], capture_output=True).returncode == 0


def same_at(root: Path, base: str, head: str, path: str) -> bool:
    return subprocess.run(["git", "-C", str(root), "diff", "--quiet", base, head, "--", path], capture_output=True).returncode == 0


def at_base(root: Path, base: str, head: str, results: list[dict], todo: list[dict]) -> tuple[set[str], set[str], str]:
    """(python entries red at the base, webviews files red at the base, a note when the check
    could not run). Only a test that exists at the base and fails there (a real failure: not a
    timeout, not a missing tool) is the base's. Web files are compared one by one, and only when
    webviews/bun.lock is the same at both ends, so the head's node_modules serves the base.
    Cargo, native and Swift reds are never re-run: they fail the car."""
    by_name = {e["name"]: e for e in todo}
    python = [r["name"] for r in results if r["kind"] == "python" and r["status"] == "fail"
              and exists_at(root, base, r["name"].split(":", 1)[1])]
    web_failed = [f for r in results if r["kind"] == "web" for f, how in r.get("files", {}).items() if how == "FAIL"]
    web = [f for f in web_failed if exists_at(root, base, f"webviews/{f}")]
    if web and not (same_at(root, base, head, "webviews/bun.lock") and (root / "webviews/node_modules").is_dir()):
        web = []
    if not python and not web:
        return set(), set(), ""
    with tempfile.TemporaryDirectory() as tmp:
        tree = Path(tmp) / "base"
        added = subprocess.run(["git", "-C", str(root), "worktree", "add", "--quiet", "--detach", str(tree), base],
                               capture_output=True, text=True)
        if added.returncode != 0:
            return set(), set(), f"the base check did not run: {added.stderr.strip()[-300:]}"
        try:
            # A sharded file is planned again from the base's own copy (its classes may differ there).
            base_todo = [e for n in python for e in python_entries(tree, n.split(":", 1)[1], by_name.get(n, {}).get("serial", False))]
            by_name.update({e["name"]: e for e in base_todo})
            again = run_all(tree, base_todo)
            # A slow test timed out at the base where the head's got its alone retry (retry_timeouts): give the base
            # the same retry, else a test failing at both ends reads as the car's. Run 45372757083: the head's
            # tests/test_cmux_next_route.py failed after 647 s (300 s, then 347 s alone), and the same 7 failures at
            # the base were never read.
            for result in again:
                limit = RETRY_TIMEOUT.get(result["kind"])
                if result["status"] == "retry" and limit:
                    result.update(run_one(tree, by_name[result["name"]], timeout=limit))
            red = {r["name"] for r in merge_shards(base_todo, again) if r["status"] == "fail"}
            red_web: set[str] = set()
            if web:
                (tree / "webviews/node_modules").symlink_to(root / "webviews/node_modules")
                entry = dict(by_name["web"], env={"CMUX_WEB_TEST_FILES": "\n".join(web)})
                (result,) = run_all(tree, [entry])
                red_web = {f for f, how in result.get("files", {}).items() if how == "FAIL"}
        finally:
            subprocess.run(["git", "-C", str(root), "worktree", "remove", "--force", str(tree)], capture_output=True)
    return red, red_web, ""


def run(root: Path, base: str, head: str, where: str, the_plan: dict, prior: dict[str, str],
        kinds: set[str] | None = None, deadline: float | None = None) -> dict:
    global _deadline_at
    _deadline_at = time.monotonic() + deadline if deadline else None
    skip = reused_kinds(prior)
    todo = [e for e in entries(root, base, head, where, the_plan, skip)
            if kinds is None or e["kind"] in kinds or (e["kind"] == "swift-build" and "swift" in kinds)]
    flaky = quarantined(root)
    results = run_all(root, todo)
    retry_timeouts(root, todo, results, the_plan.get("files", []))
    results = merge_shards(todo, results)
    for result in results:
        if result["status"] in ("fail", "timeout") and result["name"] in flaky:
            result["status"] = "quarantined-fail"
    red, red_web, note = at_base(root, base, head, results, todo)
    for result in results:
        if result["name"] in red:
            result["status"] = "base-red"
        elif result["kind"] == "web" and result.get("files"):
            own = sorted(f for f, how in result["files"].items() if not (how == "FAIL" and f in red_web))
            result["base_red_files"] = sorted(red_web)
            if not own and result["status"] == "fail":
                result["status"] = "base-red"
            result["own_files"] = own
    statuses = {r["status"] for r in results}
    # An entry the deadline left unrun is not checked: the car's guard errs (the train warns, naming it), never fails.
    status = "fail" if statuses & {"fail", "timeout"} else "error" if statuses & {"error", "unrun"} else "pass"
    deferred = [f"web (browser lane): {t['path']}" for t in the_plan["web"] if t.get("browser")]
    if the_plan.get("web_dropped"):
        deferred.append(f"web: {the_plan['web_dropped']} more files past the nearest {len(the_plan['web'])}")
    if the_plan.get("swift_deferred"):
        deferred.append(f"swift: {the_plan['swift_deferred']}")
    verdict = {"status": status, "results": results, "reused": sorted(skip),
               "deferred": deferred, "unmapped": the_plan["unmapped"]}
    if note:
        verdict["base_check"] = note
    return verdict


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("mode", choices=("plan", "run"))
    parser.add_argument("--root", default=".")
    parser.add_argument("--base", required=True)
    parser.add_argument("--head", default="HEAD")
    parser.add_argument("--car", default="")
    parser.add_argument("--where", choices=("linux", "mac"))
    parser.add_argument("--prior", help="JSON {check name: conclusion} of the car's PR CI at its tree")
    parser.add_argument("--receipt")
    parser.add_argument("--deadline", type=float, default=DEADLINE,
                        help="seconds the whole run may take (CAR_GUARDS_DEADLINE, default 1500); 0: no bound")
    parser.add_argument("--kinds", help="comma-separated kinds to run (guard,python,web,cargo,swift); default all")
    args = parser.parse_args(argv)
    root = Path(args.root).resolve()
    try:
        files = focused_tests.changed_files(root, args.base, args.head)
    except subprocess.CalledProcessError as error:
        print(f"car_guards: cannot diff {args.base}...{args.head}: {error.stderr.strip()}", file=sys.stderr)
        return 2
    the_plan = focused_tests.plan(root, files)
    prior = json.loads(Path(args.prior).read_text(encoding="utf-8")) if args.prior else {}
    head = {"car": args.car, "base": args.base, "head": args.head}
    if args.mode == "plan":
        skip = reused_kinds(prior)
        verdict = dict(head, plan=the_plan, reused=sorted(skip),
                       linux=[e["name"] for e in entries(root, args.base, args.head, "linux", the_plan, skip)],
                       mac=[e["name"] for e in entries(root, args.base, args.head, "mac", the_plan, skip)])
        code = 0
    else:
        if not args.where:
            parser.error("run needs --where linux|mac")
        # The guards read the working tree: a checkout at another commit judges the wrong car.
        at = subprocess.run(["git", "-C", str(root), "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
        want = subprocess.run(["git", "-C", str(root), "rev-parse", args.head + "^{commit}"], capture_output=True, text=True).stdout.strip()
        if not at or at != want:
            print(f"car_guards: the checkout is at {at or 'nothing'}, not the car's head {args.head}", file=sys.stderr)
            return 2
        kinds = set(args.kinds.split(",")) if args.kinds else None
        verdict = dict(head, where=args.where, **run(root, args.base, args.head, args.where, the_plan, prior, kinds,
                                                       deadline=args.deadline))
        code = {"pass": 0, "fail": 1}.get(verdict["status"], 2)
        for result in verdict["results"]:
            print(f"CAR-GUARD {result['status'].upper()} {result['name']} {result['seconds']}s", file=sys.stderr)
            if result["tail"]:
                print(result["tail"], file=sys.stderr)
    text = json.dumps(verdict, indent=2)
    if args.receipt:
        Path(args.receipt).write_text(text + "\n", encoding="utf-8")
    print(text)
    return code


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Exception as error:  # noqa: BLE001 - a crash is the guard's error, never the car's red
        print(f"car_guards: internal error: {type(error).__name__}: {error}", file=sys.stderr)
        sys.exit(2)
