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

Only the car's own reds fail it. A failed focused test (python, web, cargo, swift) runs again in a
worktree of BASE; red there too, it is `base-red` and the car rides. A runner missing a tool or
python module is `error`, never the car's fault. god files over its allowance is `warn`, as on
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
# Re-run at the base: a red that is red there too is the base's, not the car's.
BASE_CHECKED = {"python", "web", "cargo", "swift"}
MISSING_TOOL = re.compile(r"ModuleNotFoundError: No module named|command not found|No such file or directory: '(bun|cargo|swift)'")


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
                        "cmd": ["bash", "../scripts/ci/run-webviews-tests.sh"]})
        # A Native/ workspace has no PR job to reuse.
        for crate in the_plan["native"]:
            out.append({"name": f"native:{crate['manifest']}", "kind": "cargo",
                        "cmd": ["cargo", "test", "--locked", "--manifest-path", crate["manifest"]]})
        if "cargo" not in skip and the_plan["cargo"]["changed"]:
            out.append({"name": "cargo", "kind": "cargo", "cwd": "cmux-tui",
                        "cmd": [sys.executable, "-I", "../scripts/ci/cargo_affected.py", "--root", "..",
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
        status = "fail"
        partial = error.stdout or ""
        output = f"timed out after {timeout}s\n" + (partial.decode(errors="replace") if isinstance(partial, bytes) else partial)
    return {"name": entry["name"], "kind": entry["kind"], "status": status,
            "seconds": round(time.monotonic() - start, 1), "tail": output[-4000:] if status != "pass" else ""}


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


def at_base(root: Path, base: str, todo: list[dict], failed: list[str]) -> set[str]:
    """The failed entries that fail at the base too, run in a detached worktree of the base."""
    names = set(failed)
    again = [e for e in todo if e["name"] in names]
    builds = {e["needs"] for e in again if e.get("needs")}
    again = [e for e in todo if e["name"] in builds] + again
    if not again:
        return set()
    with tempfile.TemporaryDirectory() as tmp:
        tree = Path(tmp) / "base"
        added = subprocess.run(["git", "-C", str(root), "worktree", "add", "--quiet", "--detach", str(tree), base],
                               capture_output=True, text=True)
        if added.returncode != 0:
            return set()
        try:
            results = run_all(tree, again)
        finally:
            subprocess.run(["git", "-C", str(root), "worktree", "remove", "--force", str(tree)], capture_output=True)
    return {r["name"] for r in results if r["name"] in names and r["status"] == "fail"}


def run(root: Path, base: str, head: str, where: str, the_plan: dict, prior: dict[str, str],
        kinds: set[str] | None = None) -> dict:
    skip = reused_kinds(prior)
    todo = [e for e in entries(root, base, head, where, the_plan, skip)
            if kinds is None or e["kind"] in kinds or (e["kind"] == "swift-build" and "swift" in kinds)]
    flaky = quarantined(root)
    results = run_all(root, todo)
    for result in results:
        if result["status"] == "fail" and result["name"] in flaky:
            result["status"] = "quarantined-fail"
    checked = [r["name"] for r in results if r["status"] == "fail" and r["kind"] in BASE_CHECKED]
    red_at_base = at_base(root, base, todo, checked) if checked else set()
    for result in results:
        if result["name"] in red_at_base:
            result["status"] = "base-red"
    statuses = {r["status"] for r in results}
    # A build that fails at the car's head fails the car; one that fails at the base too is base-red.
    status = "fail" if "fail" in statuses else "error" if "error" in statuses else "pass"
    deferred = [f"web (browser lane): {t['path']}" for t in the_plan["web"] if t.get("browser")]
    if the_plan.get("swift_deferred"):
        deferred.append(f"swift: {the_plan['swift_deferred']}")
    return {"status": status, "results": results, "reused": sorted(skip),
            "deferred": deferred, "unmapped": the_plan["unmapped"]}


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
    sys.exit(main(sys.argv[1:]))
