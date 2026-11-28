#!/usr/bin/env python3
"""local_summary_gate.py: the labeled set is whole and redacted, scoring catches a false status claim, and a
baseline run reports every gate field (a run with no model runtime says no-runtime, never pass)."""
from __future__ import annotations

import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "scripts" / "measure"))
import local_summary_gate as g  # noqa: E402

cases = g.load(g.FIXTURES)
assert len(cases) >= 30, len(cases)
assert len({c["id"] for c in cases}) == len(cases)
blob = g.FIXTURES.read_text()
for pat in (r"/home/\w", r"/Users/\w", r"gh[pousr]_[A-Za-z0-9]{20}", r"\bLeo\b", r"[\w.+-]+@[\w-]+\.(com|dev|io)"):
    assert not re.search(pat, blob), f"unredacted: {pat}"
for c in cases:
    lab = c["label"]
    assert lab["status"] in g.STATUSES, c["id"]
    low = c["reply"].lower()
    for alts in lab["facts"]:
        assert any(a.lower() in low for a in alts), (c["id"], alts)

one = next(c for c in cases if c["label"]["status"] != "done" and c["label"]["false_claims"])
good = g.score(one, f"{one['label']['status']}: " + " ".join(a[0] for a in one["label"]["facts"]))
assert good["status_ok"] and not good["unsupported"], good
bad = g.score(one, "done: " + " ".join(a[0] for a in one["label"]["facts"]) + " merged")
assert bad["unsupported"], bad

with tempfile.TemporaryDirectory() as d:
    r = subprocess.run([sys.executable, str(ROOT / "scripts/measure/local_summary_gate.py"), "--runtime", "baseline",
                        "--out", d], capture_output=True, text=True, timeout=300)
    assert r.returncode == 0, r.stderr
    rep = json.loads(r.stdout)
    s = rep["rows"][-1]["summary"]
    for k in ("warm_p95_ms", "cold_p95_ms", "max_chars", "unsupported", "key_fact_recall", "status_accuracy"):
        assert s[k] is not None, k
    assert rep["verdict"] in ("pass", "fail")
    assert (Path(d) / "raw.jsonl").read_text().count("\n") == len(cases)
print("ok")
