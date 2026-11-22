#!/usr/bin/env bash
# CEF's own LICENSE.txt (BSD-3-Clause, Marshall A. Greenblatt and Google) in the
# cmux-next app. install-cef-license.sh puts it in the embedded CEF framework's
# Resources: the CEF artifact's own LICENSE.txt when it has one, else the stock
# copy checked in at scripts/cmux-next/cef-license/LICENSE.txt (pinned by
# sha256). bundle-map.json requires it next to Chromium's CREDITS.html for
# every CEF binary.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
S="$ROOT/scripts/cmux-next"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
FW="Chromium Embedded Framework.framework"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
new_res() { rm -rf "$TMP/res"; mkdir -p "$TMP/res"; }

# 1. No LICENSE.txt in the artifact (the manaflow-ai/cef fork ships none): the stock copy.
mkdir -p "$TMP/dist1/$FW/Resources"; new_res
"$S/install-cef-license.sh" "$TMP/dist1" "$TMP/res" || fail "stock fallback failed"
cmp -s "$S/cef-license/LICENSE.txt" "$TMP/res/LICENSE.txt" || fail "stock LICENSE.txt was not copied byte for byte"
grep -q 'Marshall A. Greenblatt' "$TMP/res/LICENSE.txt" || fail "LICENSE.txt is not CEF's license"

# 2. The artifact's own LICENSE.txt (dist root or framework Resources) wins.
for where in . "$FW/Resources"; do
  mkdir -p "$TMP/dist2/$FW/Resources"; new_res
  printf 'artifact license\n' > "$TMP/dist2/$where/LICENSE.txt"
  "$S/install-cef-license.sh" "$TMP/dist2" "$TMP/res" || fail "artifact license ($where) failed"
  cmp -s "$TMP/dist2/$where/LICENSE.txt" "$TMP/res/LICENSE.txt" || fail "artifact license ($where) was not used as is"
  rm -rf "$TMP/dist2"
done

# 3. A changed stock copy fails (it is pinned by sha256).
mkdir -p "$TMP/copy/scripts/cmux-next/cef-license" "$TMP/dist3/$FW/Resources"; new_res
cp "$S/install-cef-license.sh" "$TMP/copy/scripts/cmux-next/"
printf 'edited\n' > "$TMP/copy/scripts/cmux-next/cef-license/LICENSE.txt"
if "$TMP/copy/scripts/cmux-next/install-cef-license.sh" "$TMP/dist3" "$TMP/res" 2>/dev/null; then fail "an edited stock LICENSE.txt passed"; fi

# 4. bundle-map.json requires LICENSE.txt for the CEF framework, the shim and the helpers.
python3 - "$ROOT/scripts/cmux-next/notices/bundle-map.json" <<'PY' || fail "bundle-map.json does not require CEF's LICENSE.txt"
import json, sys
need = "file:Contents/Frameworks/Chromium Embedded Framework.framework/Resources/LICENSE.txt"
entries = json.load(open(sys.argv[1]))["entries"]
cef = [e for e in entries if "CREDITS.html" in " ".join(e["notices"])]
assert len(cef) == 3 and all(need in e["notices"] for e in cef), cef
PY
printf 'cef-license tests: ok\n'
