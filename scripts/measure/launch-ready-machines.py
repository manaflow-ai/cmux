#!/usr/bin/env python3
"""launch-ready.sh's machines=N seed: N Cloud machine sections in each sidebar snapshot of a home.

  launch-ready-machines.py HOME_ROOT N

A person signed in to Cloud with N Cloud machines quits with one machine section per machine in the
sidebar snapshot (`sidebar-snapshot-v1.json`, one per build folder), each with no workspaces in it; the next
launch draws them all before it hears from any machine. A fleet Mac has no Cloud sign-in, so its own quits
save none: before every launch this writes them back, so each launch reads the same N sections. A section
this seed did not write (the local machine's, a document's) is kept as it is.

Prints one `LR-MACHINES {json}` line: the snapshot files found and the sections each holds now.
"""
import json
import sys
from pathlib import Path

PREFIX = "vm_launchready"


def seed(path, count):
    doc = json.loads(path.read_text())
    for window in doc.get("windows") or []:
        snapshot = window.setdefault("snapshot", {})
        kept = [s for s in snapshot.get("sections") or [] if not str(s.get("machineID") or "").startswith(PREFIX)]
        snapshot["sections"] = kept + [
            {"isCollapsed": False, "nodes": [], "machineKind": "cloud", "machineName": f"Cloud machine {i + 1}",
             "machineID": f"{PREFIX}{i:04d}"}
            for i in range(count)
        ]
    path.write_text(json.dumps(doc))
    return [len(w.get("snapshot", {}).get("sections") or []) for w in doc.get("windows") or []]


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if len(argv) != 2 or not argv[1].isdigit():
        print("usage: launch-ready-machines.py HOME_ROOT N", file=sys.stderr)
        return 2
    root, count = Path(argv[0]), int(argv[1])
    files = {str(p.relative_to(root)): seed(p, count) for p in sorted(root.rglob("sidebar-snapshot-v1.json"))}
    print("LR-MACHINES " + json.dumps({"machines": count, "files": files}), flush=True)
    return 0 if files else 1


if __name__ == "__main__":
    sys.exit(main())
