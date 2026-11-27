#!/usr/bin/env python3
"""Measure sparse phone-pair source setup and validate its Cargo manifest graph.

cmux-ci run --class exclusive --os linux --measurement --ref HARNESS_SHA \
  --script scripts/measure/phone-pair-source-setup.py --arg SOURCE_SHA
Reports setup wall time, CPU time, file count, and offline Cargo metadata validity;
does not compile binaries or establish a phone connection verdict.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import resource
import subprocess
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source_sha")
    parser.add_argument("--head", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    head = args.head.resolve()
    spec = importlib.util.spec_from_file_location("pair_matrix", head / "scripts/ci/mobile_pair_matrix.py")
    matrix = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(matrix)
    receipt = {"source_sha": args.source_sha, "harness_sha": subprocess.check_output(
        ["git", "-C", str(head), "rev-parse", "HEAD"], text=True).strip(),
        "load_average": os.getloadavg(), "scope": "source setup and offline Cargo metadata; no compilation"}
    start = time.monotonic()
    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    with tempfile.TemporaryDirectory(prefix="phone-pair-source-measure-") as directory:
        tree = Path(directory) / "source"
        added = []
        try:
            matrix.prepare_source(head, args.source_sha, tree, added)
            receipt["setup_wall_seconds"] = time.monotonic() - start
            metadata = matrix.run_source([
                "cargo", "metadata", "--offline", "--no-deps", "--format-version", "1"],
                cwd=tree / "cmux-next-ios/rust", stdout=subprocess.PIPE)
            receipt["metadata_package_count"] = len(json.loads(metadata.stdout)["packages"])
            receipt["materialized_files"] = sum(p.is_file() for p in tree.rglob("*"))
            receipt["passed"] = True
        except Exception as error:
            receipt.update(passed=False, error=str(error))
            raise
        finally:
            try:
                matrix.cleanup_sources(head, added)
            finally:
                after = resource.getrusage(resource.RUSAGE_CHILDREN)
                receipt["wall_seconds"] = time.monotonic() - start
                receipt["cpu_seconds"] = after.ru_utime + after.ru_stime - before.ru_utime - before.ru_stime
                output = json.dumps(receipt, indent=2) + "\n"
                if args.output:
                    args.output.write_text(output)
                print(output, end="", flush=True)


if __name__ == "__main__":
    main()
