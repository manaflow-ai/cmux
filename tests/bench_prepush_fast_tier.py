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
            code, receipt = fixture.tier()
            fast.append({"exit": code, **receipt})
        print(json.dumps({
            "harness": "same goal.ts and goal.test.ts; warm project typecheck+unit vs selected source typecheck+unit",
            "baseline_median_ms": statistics.median(row["elapsed_ms"] for row in baseline),
            "tier_median_ms": statistics.median(row["elapsed_ms"] for row in fast),
            "baseline": baseline, "tier": fast,
        }, indent=2))
        return 1 if any(row["exit"] or row["status"] != "passed" for row in fast) else 0
    finally:
        fixture.doCleanups()


if __name__ == "__main__":
    raise SystemExit(main())
