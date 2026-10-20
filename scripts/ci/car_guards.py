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
--where mac    swift:<pkg>:<T>   one `swift build --build-tests` per package, then
                                   `swift test --skip-build --filter <T>` per selected test target

--kinds guard,python runs only those kinds (the train's in-process adapter,
scripts/ci/nightly-next-car-guard.sh, runs the cheap ones on its own runner).

--prior FILE reuses the car's own PR CI: a JSON object of check name -> conclusion at the car's
exact tree. A kind whose PR checks all passed is skipped and reported as reused (REUSE below), so
the train never re-runs what already passed. The planner decides that the trees match.

Flakes: scripts/cmux-next/quarantine.json (the fast tier's list) also holds car-guard entries by
name (`python:tests/test_x.py`, `swift:CmuxNextFilesTests`). A quarantined entry still runs and
is reported, but does not fail the car.

The verdict (stdout, and --receipt) is one JSON object: {"car", "base", "head", "where",
"status": "pass"|"fail", "results": [{"name", "kind", "status", "seconds", "tail"}],
"reused": [...], "unmapped": [...]}. Exit 0 on pass, 1 on fail, 2 on bad input.
"""
from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import focused_tests  # noqa: E402

QUARANTINE = "scripts/cmux-next/quarantine.json"
LINUX_LANES = {"linux-guard"}
# The PR checks that already cover a kind: name prefixes (a matrix job reports one check per
# shard, `web / Web tests (1)`). A kind is reused when at least one check matches and every
# matching check passed. Native workspaces have no PR job of their own: never reused.
REUSE = {
    "guard": ("cmux-next checks (god files",),
    "python": ("cmux-next checks (god files", "nightly-guards / workflow-guard-"),
    "cargo": ("cmux-next fast tier (cargo)",),
    "swift": ("cmux-next fast tier", "cmux-next swift test"),
    "web": ("web / Web tests",),
}
PASSING = {"success", "neutral"}
CHEAP = {"guard", "python"}
TIMEOUT = {"guard": 600, "python": 300, "cargo": 1500, "swift": 2400, "web": 1200}
JOBS = int(os.environ.get("CAR_GUARDS_JOBS", str(max(2, (os.cpu_count() or 4)))))


def reused_kinds(prior: dict[str, str]) -> set[str]:
    """Kinds whose covering checks are present in `prior` and all passed."""
    out = set()
    for kind, prefixes in REUSE.items():
        found = [(value or "").lower() for name, value in prior.items()
                 if any(name.lower().startswith(p.lower()) for p in prefixes)]
        # `cmux-next fast tier` must not count `cmux-next fast tier (cargo)` for swift.
        if kind == "swift":
            found = [(value or "").lower() for name, value in prior.items()
                     if name.lower() in ("cmux-next fast tier", "cmux-next swift test")]
        if found and all(value in PASSING for value in found):
            out.add(kind)
    return out


def quarantined(root: Path) -> set[str]:
    path = root / QUARANTINE
    if not path.is_file():
        return set()
    return {e["name"] for e in json.loads(path.read_text(encoding="utf-8")).get("entries", []) if e.get("name")}


def entries(root: Path, base: str, head: str, where: str, the_plan: dict, skip: set[str]) -> list[dict]:
    """The commands this runner runs, as {name, kind, cmd, cwd}."""
    out = []
    if where == "linux":
        if "guard" not in skip:
            out.append({"name": "guard:prepush", "kind": "guard",
                        "cmd": [sys.executable, "-I", "scripts/cmux-next/prepush-gate.py", "--base", base, "--head", head]})
            out.append({"name": "guard:godfiles", "kind": "guard",
                        "cmd": ["bash", "scripts/cmux-next/check-no-godfiles.sh", "--base", base]})
        if "python" not in skip:
            for test in the_plan["python"]:
                if test["lane"] in LINUX_LANES:
                    out.append({"name": f"python:{test['path']}", "kind": "python",
                                "cmd": [sys.executable, test["path"]]})
        if "web" not in skip and the_plan["web"]:
            out.append({"name": "web", "kind": "web", "cwd": "webviews",
                        "env": {"CMUX_WEB_TEST_FILES": "\n".join(t["path"] for t in the_plan["web"])},
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
            # One build per package; its filters then run in turn on that build.
            script = f"swift build --build-tests --package-path {package}"
            for name in filters:
                script += f" && echo 'CAR-GUARD swift:{name}' && swift test --skip-build --package-path {package} --filter '^{name}\\.'"
            out.append({"name": f"swift:{package}", "kind": "swift", "cmd": ["bash", "-c", script],
                        "filters": filters})
    return out


def run_one(root: Path, entry: dict) -> dict:
    start = time.monotonic()
    try:
        proc = subprocess.run(entry["cmd"], cwd=root / entry.get("cwd", "."), capture_output=True, text=True,
                              timeout=TIMEOUT[entry["kind"]], env={**os.environ, **entry.get("env", {})})
        status = "pass" if proc.returncode == 0 else "fail"
        output = proc.stdout + proc.stderr
    except subprocess.TimeoutExpired as error:
        status = "fail"
        output = f"timed out after {TIMEOUT[entry['kind']]}s\n" + ((error.stdout or b"").decode(errors="replace")
                                                                  if isinstance(error.stdout, bytes) else (error.stdout or ""))
    return {"name": entry["name"], "kind": entry["kind"], "status": status,
            "seconds": round(time.monotonic() - start, 1), "tail": output[-4000:] if status != "pass" else ""}


def run(root: Path, base: str, head: str, where: str, the_plan: dict, prior: dict[str, str],
        kinds: set[str] | None = None) -> dict:
    skip = reused_kinds(prior)
    todo = [e for e in entries(root, base, head, where, the_plan, skip) if kinds is None or e["kind"] in kinds]
    flaky = quarantined(root)
    # Cheap first: the guards and python tests side by side (seconds each), then the heavy
    # entries (cargo, web, swift) one at a time, since each is parallel inside itself.
    cheap = [e for e in todo if e["kind"] in CHEAP]
    heavy = [e for e in todo if e["kind"] not in CHEAP]
    with concurrent.futures.ThreadPoolExecutor(max_workers=JOBS) as pool:
        results = list(pool.map(lambda e: run_one(root, e), cheap))
    results += [run_one(root, e) for e in heavy]
    todo = cheap + heavy
    for result, entry in zip(results, todo):
        names = [result["name"]] + [f"swift:{f}" for f in entry.get("filters", [])]
        if result["status"] == "fail" and any(n in flaky for n in names):
            result["status"] = "quarantined-fail"
    failed = [r for r in results if r["status"] == "fail"]
    return {"status": "fail" if failed else "pass", "results": results,
            "reused": sorted(skip), "unmapped": the_plan["unmapped"]}


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
        code = 0 if verdict["status"] == "pass" else 1
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
