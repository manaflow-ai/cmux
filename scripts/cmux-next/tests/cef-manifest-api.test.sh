#!/usr/bin/env bash
# The pinned CEF fork must report a cmux_cef_api_version of at least
# MIN_FORK_API. Stage S5 (pane resize frame owner) needs resize sync (API 27)
# and layer hosting (API 26); the pin must carry both. The manifest's version,
# tag and fork_ref must agree, and so must its x86_64 object.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
manifest="$here/../cef-manifest.json"
MIN_FORK_API=27
fail() { echo "FAIL: $*" >&2; exit 1; }

/usr/bin/python3 - "$manifest" "$MIN_FORK_API" <<'PY' || fail "manifest does not meet the fork API floor"
import json, sys
m = json.load(open(sys.argv[1]))
minimum = int(sys.argv[2])
api = m["cmux_cef_api_version"]
assert api >= minimum, f"pinned fork API {api} < {minimum} ({m['version']})"
assert m["tag"] == m["version"], (m["tag"], m["version"])
assert m["version"].endswith(f"cmux.{m['version'].rsplit('cmux.', 1)[1]}"), m["version"]
assert m["cef"] in m["version"] and m["cef"] in m["tag"], m["version"]
x = m["x86_64"]
assert x["fork_ref"] == m["fork_ref"], "x86_64 fork_ref differs from arm64"
assert x["asset"].replace("-x86_64", "-arm64") == m["asset"], (x["asset"], m["asset"])
PY

echo "ok: pinned CEF fork API >= $MIN_FORK_API"
