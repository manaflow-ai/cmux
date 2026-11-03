#!/usr/bin/env python3
"""Run the existing scroll harness against two model.ts versions on one fleet worker.

Use only in an isolated cmux-ci checkout, after installing webviews dependencies/WebKit:
  python3 scripts/cmux-next/scroll-lead-ab.py --baseline BASE_SHA --out /tmp/scroll-lead-ab

Everything except model.ts (including the benchmark and browser regressions) stays identical.
The original source is restored even on a failing command. Logs and a receipt retain each
command's exit status; a baseline reduction-test failure is expected, not a passing product test.
"""
import argparse
import json
import os
from pathlib import Path
import platform
import subprocess


ROOT = Path(__file__).resolve().parents[2]
MODEL = "webviews/src/agent-session/acpmux/model.ts"


def git(*args):
    return subprocess.check_output(["git", *args], cwd=ROOT)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", required=True)
    parser.add_argument("--out", required=True)
    opts = parser.parse_args()
    candidate = git("rev-parse", "HEAD").decode().strip()
    baseline = git("rev-parse", "--verify", f"{opts.baseline}^{{commit}}").decode().strip()
    source = ROOT / MODEL
    original = source.read_bytes()
    if original != git("show", f"{candidate}:{MODEL}"):
        raise SystemExit("model.ts has uncommitted changes; use a dedicated fleet checkout")
    before = git("show", f"{baseline}:{MODEL}")
    # The comparison must isolate the candidate's range policy from unrelated model changes.
    marker = b"export function scrollLeadRanges("
    end = b'\nimport { layout, prepare, type PreparedText }'
    def outside(data):
        start = data.index(marker)
        finish = data.index(end, start)
        return data[:start], data[finish:]
    if outside(original) != outside(before):
        raise SystemExit("baseline differs outside scrollLeadRanges; choose the candidate's base")
    out = Path(opts.out).resolve()
    out.mkdir(parents=True, exist_ok=True)
    receipt = {"host": platform.node(), "candidate": candidate, "baseline": baseline, "runs": []}
    commands = [
        ("range", ["bun", "test", "test/transcript-scroll-lead.test.ts"], False),
        ("browser", ["bun", "test", "test/transcript-fling.test.ts"], False),
        ("timing", ["bun", "bench/transcript-scroll-frame.bench.ts", "3000", "2", "120"], False),
        ("coverage", ["bun", "bench/transcript-scroll-frame.bench.ts", "3000", "2", "120"], True),
    ]
    expected_source = original
    try:
        for name, data in (("baseline", before), ("candidate", original)):
            if source.read_bytes() != expected_source:
                raise RuntimeError("model.ts changed concurrently; refusing to overwrite it")
            source.write_bytes(data)
            expected_source = data
            for check, command, coverage in commands:
                env = {**os.environ, "CMUX_BROWSER_TESTS": "1", "CMUX_SCROLL_COVERAGE": "1" if coverage else "0"}
                log = out / f"{name}-{check}.log"
                print(f"scroll-lead-ab {name} {check}: {' '.join(command)}", flush=True)
                with log.open("w") as stream:
                    try:
                        status = subprocess.run(command, cwd=ROOT / "webviews", env=env,
                                                stdout=stream, stderr=subprocess.STDOUT, timeout=600).returncode
                    except subprocess.TimeoutExpired:
                        status = 124
                receipt["runs"].append({"variant": name, "check": check, "exit": status, "log": str(log)})
                print(log.read_text(), end="", flush=True)
    finally:
        if source.read_bytes() == expected_source:
            source.write_bytes(original)
        else:
            # Preserve concurrent work rather than restoring over it; keep our original separately.
            (out / "model.ts.original").write_bytes(original)
            receipt["restore_error"] = "model.ts changed concurrently; original retained in output folder"
        (out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    runs = receipt["runs"]
    return (len(runs) == 8 and not receipt.get("restore_error")
            and all(r["exit"] == 0 for r in runs if r["variant"] == "candidate")
            and all(r["exit"] == 0 for r in runs if r["variant"] == "baseline" and r["check"] != "range")
            and any(r["exit"] == 1 for r in runs if r["variant"] == "baseline" and r["check"] == "range"))


if __name__ == "__main__":
    raise SystemExit(0 if main() else 1)
