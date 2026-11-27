#!/usr/bin/env python3
"""Build one production workspace example and retain exact native-reuse/cost receipts."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import resource
import signal
import subprocess
import time

ROOT = Path(__file__).resolve().parents[3]
SOURCE = ROOT / "cmux-tui/crates/ghostty-vt/examples/phone_default_speed.rs"
BASELINE = ROOT / "scripts/bench/phone-default-speed/baseline.tsv"
CARGO = ["cargo", "build", "--locked", "--profile", "dev", "-p", "ghostty-vt",
         "--features", "phone-speed", "--example", "phone_default_speed", "-vv"]



def stop_tree(pid):
    """Stop only this child tree; retain the CI step's group for outer cancellation."""
    stopped = []
    def visit(child):
        try:
            os.kill(child, signal.SIGSTOP)
        except ProcessLookupError:
            return
        stopped.append(child)
        # A stopped process cannot spawn more children while we enumerate every thread.
        for task in (Path("/proc") / str(child) / "task").glob("*/children"):
            try:
                children = task.read_text().split()
            except FileNotFoundError:
                continue
            for descendant in children:
                visit(int(descendant))
    visit(pid)
    for child in reversed(stopped):
        try:
            os.kill(child, signal.SIGKILL)
        except ProcessLookupError:
            pass


def run(name, command, output, env, timeout=180, expected=0):
    def cancelled(signum, _frame):
        if process.poll() is None:
            stop_tree(process.pid)
            process.wait()
        raise SystemExit(128 + signum)

    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    start = time.monotonic()
    log = output / f"{name}.log"
    with log.open("w") as stream:
        process = subprocess.Popen(command, cwd=ROOT / "cmux-tui", env=env,
                                   stdout=stream, stderr=subprocess.STDOUT)
        previous = signal.signal(signal.SIGTERM, cancelled)
        try:
            code = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            stop_tree(process.pid)
            process.wait()
            code = 124
        finally:
            signal.signal(signal.SIGTERM, previous)
    after = resource.getrusage(resource.RUSAGE_CHILDREN)
    receipt = {"command": command, "exit": code, "cpu_complete": code != 124, "cpu_scope": "waited child processes; external cache daemons excluded", "wall_seconds": time.monotonic() - start,
               "user_seconds": after.ru_utime - before.ru_utime,
               "system_seconds": after.ru_stime - before.ru_stime}
    (output / f"{name}.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(f"{name}: {json.dumps(receipt)}", flush=True)
    text = log.read_text()
    if (expected == 0 and code != 0) or (expected != 0 and code == 0):
        print(text[-12000:], flush=True)
        raise RuntimeError(f"{name}: unexpected exit {code}; {log}")
    return text


def fresh(log):
    if "Fresh ghostty-vt-sys v" not in log or "Compiling ghostty-vt-sys v" in log:
        raise RuntimeError("warm example did not reuse ghostty-vt-sys; inspect native fingerprints")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--study", action="store_true", help="explicitly record baseline and mutation receipts in a fresh target")
    parser.add_argument("--output", type=Path, default=Path("/tmp/phone-default-speed-receipt"))
    args = parser.parse_args()
    if os.uname().sysname != "Linux" or os.uname().machine != "x86_64":
        raise RuntimeError("instruction baseline requires Linux x86_64")
    if not args.study and not BASELINE.is_file():
        raise RuntimeError("instruction baseline missing; run explicit managed study before enabling the gate")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ)
    env.update(CMUX_GHOSTTY_VT_ZIG_CPU="baseline", CMUX_GHOSTTY_SRC="", CARGO_INCREMENTAL="0")
    # ci/run's Zig install path is temporary. The pinned executable is selected
    # from PATH; keeping these overrides unset avoids a different Cargo input
    # merely because a new CI_TOOLS directory was allocated.
    env.pop("ZIG", None)
    env.pop("CMUX_ZIG", None)
    if args.study:
        # Cold-study CPU includes rustc itself rather than an external compiler cache daemon.
        env.pop("RUSTC_WRAPPER", None)
        env.pop("RUSTC_WORKSPACE_WRAPPER", None)
        target = ROOT / ".build" / f"phone-default-speed-study-{os.getpid()}"
        target.mkdir(parents=True, exist_ok=False)
        env["CARGO_TARGET_DIR"] = str(target)
    target = Path(env.get("CARGO_TARGET_DIR", ROOT / "cmux-tui/target"))
    if not target.is_absolute():
        target = ROOT / "cmux-tui" / target
    binary = target / "debug/examples/phone_default_speed"
    (output / "identity.json").write_text(json.dumps({
        "head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "ghostty": subprocess.check_output(["git", "rev-parse", "HEAD:ghostty-next"], cwd=ROOT, text=True).strip(),
        "target": str(target), "profile": "dev", "cpu": "baseline", "study": args.study,
    }, indent=2) + "\n")
    first = run("cold-build" if args.study else "setup-build", CARGO, output, env, timeout=1800 if args.study else 900)
    print(f"initial native artifact fresh: {'Fresh ghostty-vt-sys v' in first}", flush=True)
    fresh(run("warm-build", CARGO, output, env, timeout=60))
    run("unit-tests", ["cargo", "test", "--locked", "-p", "ghostty-vt", "--features", "phone-speed",
                       "--example", "phone_default_speed"], output, env, timeout=120)
    if args.study:
        # Rebaselining is explicit developer study, never the gating path.
        record_env = {key: value for key, value in env.items() if key != "CI"}
        run("record-baseline", [str(binary), "update"], output, record_env)
        (output / "baseline.tsv").write_bytes(BASELINE.read_bytes())
    print(run("check", [str(binary), "check"], output, env), flush=True)
    if args.study:
        run("check-repeat", [str(binary), "check"], output, env)
        original = SOURCE.read_text()
        mutation_source = SOURCE.with_name("phone_default_speed_mutation.rs")
        if mutation_source.exists():
            raise RuntimeError(f"refusing to overwrite {mutation_source}")
        mutation_cargo = [arg.replace("phone_default_speed", "phone_default_speed_mutation") for arg in CARGO]
        mutation_binary = binary.with_name("phone_default_speed_mutation")
        try:
            marker = "let runs = frame.runs();"
            assert original.count(marker) == 1
            mutation_source.write_text(original.replace(marker, "black_box(frame.runs());\n        black_box(frame.runs());\n        " + marker))
            fresh(run("expensive-build", mutation_cargo, output, env))
            failed = run("expensive-mutation", [str(mutation_binary), "check"], output, env, expected=1)
            assert "exceeds" in failed, "extra render work did not trip the budget"
            begin = original.index("        match operation {")
            end = original.index("        render", begin)
            mutation_source.write_text(original[:begin] + "        black_box(operation);\n" + original[end:])
            fresh(run("noop-build", mutation_cargo, output, env))
            for case in ("primary-100", "alternate-100"):
                failed = run(f"noop-{case}", [str(mutation_binary), "case", case], output, env, expected=1)
                assert "assertion" in failed, "no-op mutation failed without final-frame validation"
        finally:
            mutation_source.unlink(missing_ok=True)
        fresh(run("restored-build", CARGO, output, env))
        run("restored-check", [str(binary), "check"], output, env)
    print(f"PASS: workspace native reuse and instruction gate; receipts {output}")


if __name__ == "__main__":
    main()
