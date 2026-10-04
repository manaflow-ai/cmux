#!/usr/bin/env python3
"""Prints one compact row per browser-stages.mjs JSON line (stdin)."""
import json
import sys

for line in sys.stdin:
    line = line.strip()
    if not line.startswith("{"):
        continue
    d = json.loads(line)
    m = {k: round(v) for k, v in d["marks"].items()}
    rpc = d["rpc"][0] if d["rpc"] else None
    patch = d["patch"][0] if d["patch"] else None
    print(d["label"], d["browser"], m,
          "rpc", rpc and round(rpc["end"] - rpc["start"]),
          "patchFetch", patch and round(patch["end"] - patch["start"]),
          "stream", d.get("streamElapsedMs"), "files", d.get("fileCount"),
          "longtask", round(d["longtaskMs"]), "max", round(d["maxLongtaskMs"]),
          "heapMB", d.get("jsHeapMB") and round(d["jsHeapMB"]), "rssMB", d.get("rssMB") and round(d["rssMB"]),
          "workerMsgs", d["workerMessages"], "hl", d.get("highlightedVisible"), "/", d.get("visibleLines"),
          "err", d["consoleErrors"][:1])
