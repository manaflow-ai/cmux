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

The verdict (stdout, and --receipt) is one JSON object: {"car", "base", "head", "where",
"status": "pass"|"fail"|"error", "results": [{"name", "kind", "status", "seconds", "tail"}],
"reused": [...], "deferred": [...], "unmapped": [...]}. Exit 0 on pass, 1 on fail (the car's
own red), 2 on error or bad input.
"""
from __future__ import annotations

import argparse
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
JOBS = int(os.environ.get("CAR_GUARDS_JOBS", str(max(2, (os.cpu_count() or 4)))))
# Only the runner's own tools and pinned modules make a red the runner's: anything else a test
# cannot import or run is the car's (it may have deleted or renamed it).
MISSING_TOOL = re.compile(r"ModuleNotFoundError: No module named '(yaml|bashlex)'|\b(bun|cargo|swift|zig): command not found")
WEB_RESULT = re.compile(r"^(FAIL|TIMEOUT) (?:\./)?(\S+) \(limit ", re.M)


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
            out.append({"name": "guard:prepush", "kind": "guard",
                        "cmd": [sys.executable, "-I", "scripts/cmux-next/prepush-gate.py", "--base", base, "--head", head]})
            # As the checks job runs it: warn-only over the allowance (rc 1 is ratchet debt, a
            # warning on the PR), so the train is no stricter than PR CI.
            out.append({"name": "guard:godfiles", "kind": "guard", "warn_codes": [1],
                        "env": {"GODFILES_WARN_SLACK": "20"},
                        "cmd": ["bash", "scripts/cmux-next/check-no-godfiles.sh", "--base", base]})
        for test in the_plan["python"]:
            if test["lane"] in LINUX_LANES:
                out.append({"name": f"python:{test['path']}", "kind": "python", "serial": test.get("serial", False),
                            "cmd": [sys.executable, test["path"]]})
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


def run_one(root: Path, entry: dict) -> dict:
    start = time.monotonic()
    timeout = TIMEOUT[entry["kind"]]
    try:
        proc = subprocess.run(entry["cmd"], cwd=root / entry.get("cwd", "."), capture_output=True, text=True,
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
        status = "timeout"  # the car's red at its head; never a base red at the base
        partial = error.stdout or ""
        output = f"timed out after {timeout}s\n" + (partial.decode(errors="replace") if isinstance(partial, bytes) else partial)
    result = {"name": entry["name"], "kind": entry["kind"], "status": status,
              "seconds": round(time.monotonic() - start, 1), "tail": output[-4000:] if status != "pass" else ""}
    if entry["kind"] == "web" and status in ("fail", "timeout"):
        result["files"] = {m.group(2): m.group(1) for m in WEB_RESULT.finditer(output)}
    return result


def run_all(root: Path, todo: list[dict]) -> list[dict]:
    """Cheap first: the guards and python tests side by side (a `serial` test alone after them),
    then the heavy entries one at a time (each is parallel inside itself). An entry whose
    `needs` did not pass is skipped."""
    by_name: dict[str, dict] = {}
    cheap = [e for e in todo if e["kind"] in CHEAP and not e.get("serial")]
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
            again = run_all(tree, [by_name[n] for n in python])
            red = {r["name"] for r in again if r["status"] == "fail"}
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
        kinds: set[str] | None = None) -> dict:
    skip = reused_kinds(prior)
    todo = [e for e in entries(root, base, head, where, the_plan, skip)
            if kinds is None or e["kind"] in kinds or (e["kind"] == "swift-build" and "swift" in kinds)]
    flaky = quarantined(root)
    results = run_all(root, todo)
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
    status = "fail" if statuses & {"fail", "timeout"} else "error" if "error" in statuses else "pass"
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
        verdict = dict(head, where=args.where, **run(root, args.base, args.head, args.where, the_plan, prior, kinds))
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
