#!/usr/bin/env python3
"""List workflow patterns that start a runner for no work.

Findings:
  no-concurrency   pull request workflow without a top-level concurrency group
                   (a new push does not cancel the stale run)
  mac-no-gate      job on a macOS runner with no `needs:` and no job-level `if:`
                   (a Mac is taken even when a cheap Linux check would fail first)
  step-skip        job whose steps exit early with a "skipping" echo
                   (the skip happens after the runner started)

Usage: python3 scripts/ci/runner_waste_audit.py [--json] [workflows_dir]
"""
import json, re, sys
from pathlib import Path
import yaml

MAC = re.compile(r"mac|macos|glaeda|admission", re.I)
# Controllers that must see every event (a stale-run cancel would drop a land or a freeze verdict).
NO_CONCURRENCY_OK = {"cmux-next-batch.yml", "merge-freeze.yml"}
SKIP = re.compile(r"echo[^\n]*\bskipping\b[^\n]*\n\s*exit 0", re.I)

def triggers(doc):
    on = doc.get("on", doc.get(True))
    if isinstance(on, str): return {on}
    if isinstance(on, list): return set(on)
    return set(on or {})

def audit(d):
    out = []
    for f in sorted(Path(d).glob("*.yml")):
        try: doc = yaml.safe_load(f.read_text()) or {}
        except yaml.YAMLError: continue
        t = triggers(doc)
        pr = bool(t & {"pull_request", "pull_request_target"})
        jobs_all = [j for j in (doc.get("jobs") or {}).values() if isinstance(j, dict)]
        if pr and f.name not in NO_CONCURRENCY_OK and "concurrency" not in doc and not all("concurrency" in j for j in jobs_all if "uses" not in j):
            out.append((f.name, "-", "no-concurrency"))
        for name, job in (doc.get("jobs") or {}).items():
            if not isinstance(job, dict) or "uses" in job: continue
            ro = str(job.get("runs-on", ""))
            if pr and MAC.search(ro) and "needs" not in job and "if" not in job:
                out.append((f.name, name, "mac-no-gate"))
            body = "\n".join(str(s.get("run", "")) for s in job.get("steps") or [] if isinstance(s, dict))
            if SKIP.search(body):
                out.append((f.name, name, "step-skip"))
    return out

def main():
    args = [a for a in sys.argv[1:] if a != "--json"]
    rows = audit(args[0] if args else ".github/workflows")
    if "--json" in sys.argv:
        print(json.dumps([dict(workflow=w, job=j, finding=k) for w, j, k in rows], indent=2))
    else:
        for w, j, k in rows: print(f"{k:15} {w}:{j}")
        print(f"{len(rows)} findings")

if __name__ == "__main__":
    main()
