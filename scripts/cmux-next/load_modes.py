#!/usr/bin/env python3
"""The load modes every under-load harness shares, read from the one registry (webviews/bench/load-modes.json).

cmuxterm-hq docs/design/chat-instant-under-load.md, "The bench": "One harness, one set of load modes, used by typing
and by the tab and workspace harness, so numbers compare." Leo, 2026-11-16: "but typing under load is not good
enough".

The web harnesses read the same file through webviews/bench/loadModes.ts. Nothing here hard-codes a mode: a mode
added to the registry is offered by every harness that calls `load("all")`.

  python3 scripts/cmux-next/load_modes.py [L0,L2 | all]   prints the modes it would apply
"""
import json
import os
import sys

REGISTRY = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
                        "webviews", "bench", "load-modes.json")
# What the pre-mode spellings meant, so a harness's old --phases words still name a mode.
ALIASES = {"idle": "L0", "stream": "L1", "load": "L1"}


def registry(path=REGISTRY):
    with open(path) as handle:
        return json.load(handle)


def gate_p95_ms(path=REGISTRY):
    """The design's key-to-frame target (16 ms). A harness flag, not a CI gate."""
    return registry(path)["gate_p95_ms"]


def load(wanted, path=REGISTRY):
    """The named modes, in the order asked for; `all` is every mode in registry order."""
    modes = registry(path)["modes"]
    if wanted.strip() == "all":
        return modes
    by_id = {mode["id"]: mode for mode in modes}
    out = []
    for part in (name.strip() for name in wanted.split(",")):
        if not part:
            continue
        key = ALIASES.get(part.lower(), part.upper())
        if key not in by_id:
            raise KeyError(f"unknown load mode {part}; have {','.join(by_id)}")
        out.append(by_id[key])
    return out


if __name__ == "__main__":
    for mode in load(sys.argv[1] if len(sys.argv) > 1 else "all"):
        missing = "; ".join(mode.get("nativeMissing") or []) or "nothing"
        print(f"{mode['id']} {mode['label']}: {mode['what']}\n    native {json.dumps(mode['native'])}; "
              f"not expressed by the native surfaces: {missing}")
