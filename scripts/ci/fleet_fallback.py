#!/usr/bin/env python3
"""Say why a fleet-default job ran on a Mac.

Several Mac jobs have a fleet job partner that answers first (scheme compile, Swift canary, Release compile). When
the partner is skipped, fails or gives no usable verdict, the Mac job silently does the work itself: cmux#55653's
scheme compile took 27 minutes of a Mac because its fleet job was skipped by a switch nobody saw. Each Mac partner
runs this as its first step when it did not take the fleet answer, so every fall says, in an annotation, the step
summary and one JSON line (`fleet-fallback: {...}`), which fleet job it fell from and why:

- `gate`: a switch in the fleet job's `if:` was false (`--gate 'CI_SCHEME_COMPILE_FLEET is not 0=false'`). The
  workflow passes each gate as a label and its value; a secret-like value is passed as presence only.
- `skipped`: the fleet job did not run though every named gate held (a need or its route skipped it).
- `failure`, `cancelled`: the fleet job ended that way.
- `verdict`: the fleet job ran and answered something other than pass (empty, unavailable, fail).

It never fails the job: a missing answer is a warning, never a red.

    fleet_fallback.py --job 'cmux app scheme compile (Debug)' --fleet 'cmux app scheme compile (build fleet)' \
      --result skipped --verdict '' --gate 'CI_SCHEME_COMPILE_FLEET is not 0=false'
"""

from __future__ import annotations

import argparse
import json
import os
import sys

TAKEN = {"pass", "superseded"}


def parse_gate(raw: str) -> tuple[str, bool]:
    label, sep, value = raw.rpartition("=")
    if not sep or not label:
        raise argparse.ArgumentTypeError(f"--gate wants LABEL=true|false, got {raw!r}")
    return label, value.strip().lower() == "true"


def reason(result: str, verdict: str, gates: list[tuple[str, bool]],
           taken: frozenset[str] | set[str] = frozenset(TAKEN)) -> tuple[str, str] | None:
    """(kind, text) of why the fleet answer was not taken, or None when it was. `taken`: the verdicts this caller
    accepts (the scheme compile takes only `pass`, so a `superseded` answer there is a fall, not a take)."""
    result = (result or "").strip()
    verdict = (verdict or "").strip()
    if result == "success" and verdict in taken:
        return None
    off = [label for label, value in gates if not value]
    if result in ("", "skipped") and off:
        return "gate", "its gate is off: " + "; ".join(off)
    if result in ("", "skipped"):
        return "skipped", "it was skipped though its gates held (a need or its route skipped it)"
    if result in ("failure", "cancelled"):
        return result, f"it ended {result}" + (f" (verdict {verdict})" if verdict else "")
    return "verdict", f"it answered {verdict or 'nothing'}"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--job", required=True, help="the Mac job's name")
    parser.add_argument("--fleet", required=True, help="the fleet job's name")
    parser.add_argument("--result", default="", help="needs.<fleet>.result")
    parser.add_argument("--verdict", default="", help="needs.<fleet>.outputs.verdict")
    parser.add_argument("--gate", action="append", type=parse_gate, default=[], help="LABEL=true|false")
    parser.add_argument("--take", default=",".join(sorted(TAKEN)),
                        help="comma-separated verdicts the Mac job accepts as the fleet answer (default: pass,superseded)")
    args = parser.parse_args(argv)

    taken = {v.strip() for v in args.take.split(",") if v.strip()}
    found = reason(args.result, args.verdict, args.gate, taken)
    if found is None:
        print(f"{args.job}: took the {args.fleet} answer ({args.verdict}).")
        return 0
    kind, text = found
    line = f"{args.job} runs on a Mac: {args.fleet} gave no answer to take; {text}."
    print(f"::warning title=fleet fallback::{line}")
    record = {
        "job": args.job,
        "fleet": args.fleet,
        "kind": kind,
        "reason": text,
        "result": args.result,
        "verdict": args.verdict,
        "gates": {label: value for label, value in args.gate},
        "run": os.environ.get("GITHUB_RUN_ID", ""),
        "sha": os.environ.get("GITHUB_SHA", ""),
        "event": os.environ.get("GITHUB_EVENT_NAME", ""),
    }
    print("fleet-fallback: " + json.dumps(record, sort_keys=True))
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write(f"### Fleet fallback\n\n{line}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
