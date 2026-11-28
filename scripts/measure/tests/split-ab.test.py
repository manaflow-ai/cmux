#!/usr/bin/env python3
"""scripts/measure/split-ab.sh and split_ab_summary.py: arguments, per-arm medians and the head - base delta."""
import json
import os
import subprocess
import sys
import tempfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "scripts", "measure"))
import split_ab_summary as sab  # noqa: E402

A, B = "a" * 40, "b" * 40


def run_sh(*args, env=None):
    e = dict(os.environ, SPLIT_AB_PARSE_ONLY="1", **(env or {}))
    return subprocess.run(["bash", os.path.join(ROOT, "scripts/measure/split-ab.sh"), *args],
                          capture_output=True, text=True, env=e, cwd=ROOT)


def write_round(out, arm, i, rc, report):
    d = os.path.join(out, f"{arm}-{i}")
    os.makedirs(d)
    open(os.path.join(d, "rc"), "w").write(f"{rc}\n")
    if report is not None:
        json.dump(report, open(os.path.join(d, "report.json"), "w"))


def cells(first):
    return {"cells": {"s1-empty-w1": {"split": {"first_frame_ms": first, "settled_ms": first * 3, "blank_frames": 0}}},
            "rows": [{"name": "split.first_frame", "p50": first, "p95": first + 4}], "display": {"refresh_ms": 8.3}}


def test_args():
    p = run_sh(f"base={A}", f"head={B}", "rounds=3", "--suite=split-scale", "--quick", "--vdisplay=120")
    assert p.returncode == 0, p.stderr
    assert p.stdout.strip() == f"base={A} head={B} rounds=3 phase= args=--suite=split-scale --quick --vdisplay=120", p.stdout
    p = run_sh(f"base={A}", f"head={B}", env={"CMUX_MEASURE_PHASE": "build"})
    assert p.returncode == 0 and "phase=build" in p.stdout, (p.stdout, p.stderr)
    for bad in ([f"base={A}"], [f"base={A}", "head=xyz"], [f"base={A}", f"head={B}", "rounds=7"],
                [f"base={A}", f"head={B}", "--build-only"]):
        assert run_sh(*bad).returncode == 2, bad
    assert run_sh(f"base={A}", f"head={B}", env={"CMUX_MEASURE_PHASE": "later"}).returncode == 2


def test_summary():
    with tempfile.TemporaryDirectory() as out:
        for i, (b, h) in enumerate([(30, 20), (34, 22)], start=1):
            write_round(out, "base", i, 0, cells(b))
            write_round(out, "head", i, 1, cells(h))  # a gate verdict, still a measured round
        summary, code = sab.summarize(out, 2)
        assert code == 0, code
        assert summary["base"]["median"]["s1-empty-w1/split/first_frame_ms"] == 32
        assert summary["head"]["median"]["s1-empty-w1/split/first_frame_ms"] == 21
        assert summary["delta"]["s1-empty-w1/split/first_frame_ms"] == -11
        assert summary["delta"]["split.first_frame/p95"] == -11
        assert not any(k.startswith("display") for k in summary["delta"])
        assert sab.main(["x", out, "2"]) == 0 and os.path.exists(os.path.join(out, "summary.json"))
    with tempfile.TemporaryDirectory() as out:
        write_round(out, "base", 1, 0, cells(30))
        write_round(out, "head", 1, 3, None)
        assert sab.summarize(out, 1)[1] == 1
    with tempfile.TemporaryDirectory() as out:
        assert sab.summarize(out, 1)[1] == 3  # nothing ran


if __name__ == "__main__":
    test_args()
    test_summary()
    print("ok")
