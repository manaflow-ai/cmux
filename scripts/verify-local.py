#!/usr/bin/env python3
"""Run CMUX's fast CI static checks locally, before a native build or push."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time

import verification_receipt as receipt

# These are the production checks from CI's static-preflight job. Keep command
# ownership in the existing scripts; local and CI use this one recipe list.
CHECKS = (
    ("xcstrings", "static_analysis", "XCStrings structure", ["python3", "scripts/lint-xcstrings.py"]),
    ("localization", "static_analysis", "Localization parity", ["python3", "scripts/localization_catalog.py", "check"]),
    ("project-tests", "tests", "Project normalizer tests", ["python3", "tests/test_normalize_pbxproj.py"]),
    ("project", "static_analysis", "Xcode project normalization and version", ["bash", "scripts/check-pbxproj.sh"]),
    ("launch-policy", "static_analysis", "Generated Claude launch policy", ["python3", "scripts/generate-claude-launch-environment-policy.py", "--check"]),
    ("test-wiring", "static_analysis", "Swift test wiring and regression guard", ["bash", "tests/test_ci_pbxproj_test_wiring.sh"]),
    ("package-groups", "static_analysis", "Workspace Swift package groups", ["python3", "scripts/check-workspace-package-groups.py", "--check"]),
    ("feature-flags", "static_analysis", "Feature flag policy", ["python3", "scripts/lint-feature-flags.py"]),
)


def stop_process(proc):
    """Settle our process group before observing source or reporting interruption."""
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        proc.wait(timeout=2)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        proc.wait()


def execute(repo, item, timeout):
    name, phase, label, argv = item
    started = time.monotonic()
    result = {"id": name, "phase": phase, "label": label, "argv": argv,
              "status": "unsupported", "executed": False, "exit_code": None,
              "output_sha256": None, "tests": None, "cancelled": False}
    script = repo / argv[1]
    result["script_sha256"] = receipt.digest(script.read_bytes()) if script.is_file() else None
    # Child output never fills a pipe or the public receipt. Retain a bounded
    # diagnostic tail for this local invocation; the temporary raw log is removed.
    with tempfile.TemporaryFile() as log:
        try:
            proc = subprocess.Popen(argv, cwd=repo, stdout=log, stderr=subprocess.STDOUT,
                                    start_new_session=True)
            result["executed"] = True
            try:
                code = proc.wait(timeout=timeout)
                result["status"] = "passed" if code == 0 else "failed"
                if code < 0 or code in (130, 143):
                    result["status"] = "interrupted"
                result["exit_code"] = code
            except (subprocess.TimeoutExpired, KeyboardInterrupt) as error:
                stop_process(proc)
                result["status"] = "interrupted"
                result["exit_code"] = proc.returncode
                result["cancelled"] = isinstance(error, KeyboardInterrupt)
            log.seek(0)
            hashed = hashlib.sha256()
            tail = b""
            for chunk in iter(lambda: log.read(65536), b""):
                hashed.update(chunk)
                tail = (tail + chunk)[-8192:]
            result["output_sha256"] = hashed.hexdigest()
            output = tail.decode("utf-8", errors="replace")
            if phase == "tests":
                counts, ok = receipt.unittest_summary(output)
                result["tests"] = counts
                if result["status"] == "passed" and not (ok and (counts["executed"] or 0) > 0):
                    result["status"] = "failed"
                    output += "\nNo usable nonzero unittest execution summary; tests claim failed.\n"
        except OSError as error:
            output = str(error)
    result["elapsed_seconds"] = round(time.monotonic() - started, 3)
    return result, output


def swift_paths(repo, names):
    paths = []
    for name in names:
        path = (repo / name).resolve()
        if not path.is_relative_to(repo.resolve()) or not path.is_file() or path.suffix != ".swift":
            raise ValueError(f"--swift requires an existing .swift file inside the checkout: {name}")
        if path not in paths:
            paths.append(path)
    return paths


def observe_swift_inputs(repo, paths):
    inputs = []
    for path in paths:
        try:
            digest = receipt.digest(path.read_bytes())
        except OSError:
            digest = None
        inputs.append({"path": str(path.relative_to(repo.resolve())), "sha256": digest})
    return inputs


def changed_swift_files(repo, base):
    """Select the current working-tree contents, including nonignored new files."""
    def git(*args):
        return subprocess.run(["git", "-C", str(repo), *args], capture_output=True,
                              check=True, timeout=15).stdout
    try:
        base_sha = git("rev-parse", "--verify", "--end-of-options", f"{base}^{{commit}}").decode().strip()
        merge_base = git("merge-base", base_sha, "HEAD").decode().strip()
        changed = git("diff", "--name-only", "-z", "--diff-filter=ACMR", "--no-renames",
                      merge_base, "--")
        # Managed native caches may predate the checkout's ignore rules. Do not
        # select generated test runners there as contributor source edits.
        untracked = git("ls-files", "--others", "--exclude-standard", "-z", "--",
                        ".", ":(top,exclude).glaeda/apple-build/**")
    except (OSError, subprocess.SubprocessError) as error:
        raise ValueError(f"Cannot select changed Swift files against {base!r}; "
                         "check the Git checkout and local base ref") from error
    names = sorted({os.fsdecode(p) for p in (changed + untracked).split(b"\0") if p.endswith(b".swift")})
    return names, {"base_ref": base, "base_sha": base_sha, "merge_base_sha": merge_base,
                   "excluded_untracked_prefixes": [".glaeda/apple-build/"],
                   "contents": "current working tree, including staged/unstaged and nonignored untracked files"}


def stdin_swift_files(data):
    if data and not data.endswith(b"\0"):
        raise ValueError("--swift-stdin0 requires NUL-terminated paths; use git ... -z")
    return [os.fsdecode(p) for p in data.split(b"\0") if p.endswith(b".swift")]


def run(repo, selected, timeout, stream=sys.stdout, swift_files=None, swift_changed=None, swift_stdin0=None):
    before = receipt.observe(repo)
    names = list(swift_files or [])
    selection = {"explicit": bool(names)}
    if swift_changed is not None:
        changed, selection["changed"] = changed_swift_files(repo, swift_changed)
        names += changed
    if swift_stdin0 is not None:
        names += stdin_swift_files(swift_stdin0)
        selection["stdin0_sha256"] = receipt.digest(swift_stdin0)
    paths = swift_paths(repo, names)
    swift_requested = bool(paths) or swift_changed is not None or swift_stdin0 is not None
    selected = list(selected)
    if swift_requested and "swift-syntax" not in selected:
        selected.append("swift-syntax")
    if "swift-syntax" in selected and not swift_requested:
        raise ValueError("swift-syntax requires --swift FILE ..., --swift-changed [BASE], or --swift-stdin0")
    result = receipt.envelope()
    result["recipe"] = {"id": "cmux-fast-static-checks/v1", "revision": receipt.digest(Path(__file__).read_bytes()),
                        "claim_class": "pre_build_static_sanity",
                        "argv": ["python3", "scripts/verify-local.py"] +
                        [arg for name in selected for arg in ("--only", name)]}
    if paths:
        result["recipe"]["argv"] += ["--swift"] + [str(p.relative_to(repo.resolve())) for p in paths]
    elif swift_changed is not None:
        result["recipe"]["argv"] += ["--swift-changed", swift_changed]
    elif swift_stdin0 is not None:
        result["recipe"]["argv"] += ["--swift-stdin0"]
    result["source"]["repository"] = "cmux (caller-supplied checkout)"
    result["source"].update(before=before, head_sha=before["commit"], checkout_sha=before["commit"],
                             tree=before.get("tree"))
    result["environment"].update(platform=platform.system(), architecture=platform.machine(),
                                  configuration="static preflight", toolchain=None)
    executions = []
    items = [item for item in CHECKS if item[0] in selected]
    swift_before = observe_swift_inputs(repo, paths)
    compiler = shutil.which("swiftc") if paths else None
    cancelled = False
    if swift_requested:
        items.insert(0, ("swift-syntax", "parsing", f"Swift syntax ({len(paths)} selected files)",
                        ["swiftc", "-frontend", "-parse", "-swift-version", "5",
                         "-D", "DEBUG", "-enable-bare-slash-regex"] +
                        ["./" + str(p.relative_to(repo.resolve())) for p in paths]))
        if compiler:
            try:
                version = subprocess.run([compiler, "--version"], capture_output=True, text=True,
                                         timeout=min(timeout, 5), check=True)
                result["environment"]["toolchain"] = version.stdout.strip()[:2048]
            except KeyboardInterrupt:
                cancelled = True
                receipt.check(result, "preparation").update(
                    status="interrupted", executed=True, evidence="Interrupted while observing swiftc --version")
            except (OSError, subprocess.SubprocessError):
                pass  # The parser command still determines this check's result.
    if not items:
        raise ValueError("at least one known check must be selected")
    for item in items:
        if cancelled:
            executions.append({"id": item[0], "phase": item[1], "argv": item[3],
                               "status": "skipped", "executed": False, "tests": None})
            continue
        print(f"RUN {item[0]}: {item[2]}", file=stream, flush=True)
        if item[0] == "swift-syntax" and not paths:
            execution = {"id": item[0], "phase": item[1], "argv": [], "tests": None,
                         "status": "skipped", "reason": "no_swift_inputs", "executed": False,
                         "cancelled": False, "elapsed_seconds": 0}
            output = "No Swift files selected; parsing skipped."
        elif item[0] == "swift-syntax" and compiler is None:
            execution = {"id": item[0], "phase": item[1], "argv": item[3], "tests": None,
                         "status": "unsupported", "executed": False, "cancelled": False,
                         "elapsed_seconds": 0}
            output = "swiftc is unavailable; select an installed Swift toolchain and retry."
        else:
            execution, output = execute(repo, item, timeout)
        executions.append(execution)
        cancelled = execution["cancelled"]
        count = execution["tests"]
        details = f'; {count["executed"]} tests executed, {count["skipped"]} skipped' if count and count["executed"] is not None else ""
        print(f'{execution["status"].upper()} {item[0]} ({execution["elapsed_seconds"]:.2f}s{details})', file=stream)
        if execution["status"] != "passed":
            print(output[-8192:].rstrip(), file=stream)
        if execution["status"] not in ("passed", "skipped"):
            rerun = ["python3", "scripts/verify-local.py", "--only", item[0]]
            if item[0] == "swift-syntax":
                rerun += ["--swift"] + [str(p.relative_to(repo.resolve())) for p in paths]
            print(f"Rerun from this checkout: {shlex.join(rerun)}", file=stream)
    result["source"]["after"] = receipt.observe(repo)
    result["evidence"] = {"kind": "local_static_preflight", "executions": executions}
    swift_after = observe_swift_inputs(repo, paths)
    if swift_requested:
        result["evidence"]["swift_inputs"] = {"before": swift_before, "after": swift_after}
        selection["paths"] = [str(p.relative_to(repo.resolve())) for p in paths]
        result["evidence"]["swift_selection"] = selection
    result["checks"].append({"phase": "static_analysis", "status": "skipped", "executed": False, "evidence": None})
    for phase in ("parsing", "tests", "static_analysis"):
        matching = [e for e in executions if e["phase"] == phase]
        if not matching:
            continue
        states = {e["status"] for e in matching}
        state = next((s for s in ("interrupted", "unsupported", "failed", "skipped") if s in states), "passed")
        receipt.check(result, phase).update(status=state, executed=any(e["executed"] for e in matching),
                                             evidence="evidence.executions")
    tests = [e for e in executions if e["phase"] == "tests"]
    result["tests"]["selection"] = [e["argv"][1] for e in tests]
    if tests and all(e["tests"] and e["tests"]["executed"] is not None for e in tests):
        for key in ("executed", "runner_reported", "skipped"):
            result["tests"][key] = sum(e["tests"][key] for e in tests)
    result = receipt.assess(result)
    states = {e["status"] for e in executions if e.get("reason") != "no_swift_inputs"}
    if cancelled:
        states.add("interrupted")
    status = next((s for s in ("interrupted", "unsupported", "failed", "skipped") if s in states),
                  "passed" if states else "skipped")
    qualifications = result["assessment"]["qualifications"]
    if paths and (swift_before != swift_after or any(p["sha256"] is None for p in swift_before + swift_after)):
        status = "interrupted"
        qualifications.append("selected_swift_source_drift_observed")
        print("Selected Swift input changed or became unreadable; rerun parsing.", file=stream)
    if "source_drift_observed" in qualifications:
        status = "interrupted"
        print("Source changed during checks; rerun against the current checkout.", file=stream)
    if before["commit"] is None or result["source"]["after"]["commit"] is None:
        status = "unsupported"
        print("Git source observations unavailable; run from a CMUX Git checkout.", file=stream)
    result["outcome"] = {"status": status, "scope": "selected preflight checks"}
    if status == "skipped" and not states:
        result["outcome"]["reason"] = "no_swift_inputs"
    print(f'{status.upper()}: {sum(e["executed"] for e in executions)}/{len(items)} selected checks ran. '
          'Native compilation, app tests and app launch were not checked.', file=stream)
    print("Next for Swift changes: use the normal native build/test workflow in CONTRIBUTING.md.", file=stream)
    return result


def main():
    parser = argparse.ArgumentParser(
        description="Fast pre-build checks: shared CI sanity checks, with optional Swift syntax parsing.",
        usage="%(prog)s [--swift-changed [BASE]] [--only CHECK] [options]",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""Start here:
  python3 scripts/verify-local.py                         Shared CI static checks
  python3 scripts/verify-local.py --swift-changed          Also parse local Swift edits
  python3 scripts/verify-local.py --swift-changed origin/main  Include committed branch edits
  python3 scripts/verify-local.py --list                   Discover focused check names

Compose (use shell pipefail to preserve producer/check failures):
  git diff --name-only -z --diff-filter=ACMR HEAD -- |
    python3 scripts/verify-local.py --only swift-syntax --swift-stdin0 --receipt -

Parsing is not typechecking or test execution. Empty Swift selections are skipped
(exit 0); a failed, interrupted or unsupported check exits nonzero.
Details and examples: docs/verification-receipts.md""")
    selection = parser.add_argument_group("check selection")
    selection.add_argument("--only", action="append", metavar="CHECK", choices=[c[0] for c in CHECKS] + ["swift-syntax"],
                        help="Run this named check only; repeat to select several")
    selection.add_argument("--swift-changed", nargs="?", const="HEAD", metavar="BASE",
                        help="Parse dirty/new Swift files; with BASE, also include branch changes since its merge-base")
    selection.add_argument("--list", action="store_true", help="List check names and underlying commands without executing")
    composition = parser.add_argument_group("explicit selection and pipelines")
    composition.add_argument("--swift", nargs="+", action="extend", default=[], metavar="FILE",
                        help="Also parse these checkout-relative Swift files with the installed swiftc (no typecheck/build)")
    composition.add_argument("--swift-stdin0", action="store_true",
                        help="Read NUL-delimited checkout-relative paths from stdin, selecting only .swift files")
    composition.add_argument("--receipt", type=Path, help="Write JSON to this file (outside the source tree), or - for stdout")
    execution = parser.add_argument_group("execution")
    execution.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[1],
                           help="Target checkout (default: the checkout containing this script)")
    execution.add_argument("--timeout", type=float, default=60, help="Seconds per check (default 60)")
    args = parser.parse_args()
    if args.list:
        for name, phase, label, argv in CHECKS:
            print(f"{name}: {label} [{phase}]\n  {' '.join(argv)}")
        print("swift-syntax: Parse Swift files [parsing; --swift-changed [BASE], --swift-stdin0, or --swift FILE ...]")
        return 0
    if not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error("--timeout must be a finite positive number")
    selected = args.only or [c[0] for c in CHECKS]
    json_stdout = args.receipt == Path("-")
    try:
        result = run(args.repo.resolve(), selected, args.timeout,
                     stream=sys.stderr if json_stdout else sys.stdout, swift_files=args.swift,
                     swift_changed=args.swift_changed,
                     swift_stdin0=sys.stdin.buffer.read() if args.swift_stdin0 else None)
    except ValueError as error:
        parser.error(str(error))
    if args.receipt:
        encoded = json.dumps(result, indent=2, sort_keys=True) + "\n"
        if json_stdout:
            sys.stdout.write(encoded)
        else:
            args.receipt.write_text(encoded)
    return 0 if (result["outcome"]["status"] == "passed" or
                 result["outcome"].get("reason") == "no_swift_inputs") else 1


if __name__ == "__main__":
    sys.exit(main())
