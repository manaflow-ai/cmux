#!/usr/bin/env python3
"""Writes tests/oracle/corpus/e2e/coverage.json from the e2e batch manifests (p15-oracle-092..097).

Spec: plans/cmux-next/chrome-parity/p15-oracle.md, section 5 item 4 (66/66 e2e, converted or excluded with a
reason) and MQ-e2e. Stdlib only, Python 3.9+, safe under `python3 -I`.

The cases are written by hand, one per converted script; each batch task records its 11 scripts in
`tests/oracle/corpus/e2e/_batch-<first>-<last>.json`. This generator only counts: `total` is MQ-e2e
(`ls scripts/cmux-next/*-e2e.py scripts/cmux-next/*-e2e.sh`), `covered` the scripts a batch converted,
`excluded` the scripts a batch excluded with their reasons, and `missing` the scripts no batch names yet, which
`oracle.py check --coverage` reports as uncovered.

    python3 -I scripts/cmux-next/oracle/gen_e2e.py           # rewrite coverage.json
    python3 -I scripts/cmux-next/oracle/gen_e2e.py --check   # exit 1 when coverage.json is not current
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any, Dict

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
SCRIPTS = REPO / "scripts" / "cmux-next"
SUITE = REPO / "tests" / "oracle" / "corpus" / "e2e"
COVERAGE = SUITE / "coverage.json"


def mq_e2e() -> list:
    """MQ-e2e: the e2e scripts in `ls` order, repo-relative."""
    return sorted(f"scripts/cmux-next/{p.name}" for pattern in ("*-e2e.py", "*-e2e.sh") for p in SCRIPTS.glob(pattern))


def coverage() -> Dict[str, Any]:
    scripts = mq_e2e()
    entries: Dict[str, Dict[str, Any]] = {}
    for path in sorted(SUITE.glob("_batch-*.json")):
        for script, entry in json.loads(path.read_text(encoding="utf-8"))["scripts"].items():
            entries[script] = entry
    converted = {s: e["case"] for s, e in entries.items() if s in scripts and "case" in e}
    excluded = {s: e["excluded"] for s, e in entries.items() if s in scripts and "excluded" in e}
    return {
        "generator": "scripts/cmux-next/oracle/gen_e2e.py",
        "suite": "e2e",
        "catalog": "ls scripts/cmux-next/*-e2e.py scripts/cmux-next/*-e2e.sh",
        "total": len(scripts),
        "covered": len(converted),
        "converted": dict(sorted(converted.items())),
        "excluded": dict(sorted(excluded.items())),
        "missing": [s for s in scripts if s not in converted and s not in excluded],
        "unknown": sorted(s for s in entries if s not in scripts),
    }


def render() -> str:
    return json.dumps(coverage(), indent=2) + "\n"


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true", help="exit 1 when coverage.json is not current")
    args = parser.parse_args(argv)
    text = render()
    if args.check:
        current = COVERAGE.read_text(encoding="utf-8") if COVERAGE.is_file() else ""
        if current != text:
            print(f"{COVERAGE.relative_to(REPO)} is not current: run python3 -I {Path(__file__).relative_to(REPO)}")
            return 1
        return 0
    COVERAGE.write_text(text, encoding="utf-8")
    report = json.loads(text)
    print(f"e2e: {report['covered']}/{report['total']} converted, {len(report['excluded'])} excluded, "
          f"{len(report['missing'])} in no batch yet")
    return 0


if __name__ == "__main__":
    sys.exit(main())
