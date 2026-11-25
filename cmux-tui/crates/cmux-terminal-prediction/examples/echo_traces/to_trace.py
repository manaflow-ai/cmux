#!/usr/bin/env python3
"""to_trace.py IN.json [OUT.trace]: capture_echo.py's JSON to echo_trace_sim's lines (stdout without OUT)."""
import json, sys
d = json.load(open(sys.argv[1]))
f = open(sys.argv[2], "w") if len(sys.argv) > 2 else sys.stdout
f.write(d["preamble"] + "\n")
for k in d["keys"]:
    f.write(k["key"].encode().hex() + " " + (k["echo"] or "") + "\n")
