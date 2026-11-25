"""Fleet-only same-source comparison: project typecheck+unit feedback vs selected early tier.

Run after warm webviews setup. Reports failures/deferred coverage as well as latency;
the fast subset does not replace project validation. No wall-clock test assertion.
"""
import json
import statistics
import subprocess
import time

from test_prepush_fast_tier import ROOT, SOURCE, TEST, TierTest


def main():
    fixture = TierTest()
    fixture.setUp()
    try:
        fixture.write(SOURCE, (ROOT / SOURCE).read_text() + "\n// fast-tier measurement\n")
        fixture.commit()
        modules = fixture.repo / "webviews/node_modules"
        modules.mkdir()
        compiler = ROOT / "webviews/node_modules/typescript"
        if compiler.is_dir():
            (modules / "typescript").symlink_to(compiler.resolve(), target_is_directory=True)
        baseline, fast = [], []
        for _ in range(3):
            started = time.monotonic()
            result = subprocess.run(["bun", "run", "typecheck"], cwd=ROOT / "webviews",
                                    capture_output=True, text=True)
            test = subprocess.run(["bun", "test", "./" + TEST.removeprefix("webviews/")],
                                  cwd=ROOT / "webviews", capture_output=True, text=True)
            baseline.append({"elapsed_ms": round((time.monotonic() - started) * 1000, 2),
                             "typecheck_exit": result.returncode, "unit_exit": test.returncode})
            started = time.monotonic()
            code, receipt = fixture.tier()
            fast.append({"exit": code, **receipt,
                         "wall_ms": round((time.monotonic() - started) * 1000, 2)})
        summary = {
            "harness": "same goal.ts and goal.test.ts; warm project typecheck+unit vs selected source typecheck+unit",
            "baseline_median_ms": statistics.median(row["elapsed_ms"] for row in baseline),
            "tier_median_ms": statistics.median(row["wall_ms"] for row in fast),
        }
        print(json.dumps({**summary, "baseline": baseline, "tier": fast}, indent=2))
        print("PREPUSH_BENCHMARK=" + json.dumps(summary))
        invalid_baseline = any(row["typecheck_exit"] or row["unit_exit"] for row in baseline)
        invalid_tier = any(row["exit"] or row["status"] != "passed" for row in fast)
        return 1 if invalid_baseline or invalid_tier else 0
    finally:
        fixture.doCleanups()


if __name__ == "__main__":
    raise SystemExit(main())
