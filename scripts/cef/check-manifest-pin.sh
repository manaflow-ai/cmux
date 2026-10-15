#!/usr/bin/env bash
# Compares Classic's CEF pin (scripts/cef/cef-manifest.json) with cmux Next's
# (scripts/cmux-next/cef-manifest.json on a git ref, default
# origin/feat-cmux-next), so the two apps don't drift onto different Chromium
# builds unnoticed. Both read the same artifacts (controller store, R2, the
# manaflow-ai/cef release); the shim sources are a copy of Next's
# (Packages/macOS/CmuxCEF/CEFShim), so a pin bump on one side usually needs the
# matching shim change on the other.
#
#   check-manifest-pin.sh [--ref REF] [--strict] [--next-manifest FILE]
#
# Prints the compared fields. Exit 0 when they match; on a mismatch it warns
# and exits 0, or exits 1 with --strict. A missing ref (a checkout without
# feat-cmux-next) is a skip, not a failure.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ref=origin/feat-cmux-next
strict=0
next_file=""
while (($#)); do
  case "$1" in
    --ref) ref="${2:?--ref needs a git ref}"; shift 2 ;;
    --strict) strict=1; shift ;;
    --next-manifest) next_file="${2:?--next-manifest needs a file}"; shift 2 ;;
    *) echo "usage: $0 [--ref REF] [--strict] [--next-manifest FILE]" >&2; exit 2 ;;
  esac
done
classic="$ROOT/scripts/cef/cef-manifest.json"
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
if [[ -n "$next_file" ]]; then
  cp "$next_file" "$tmp"
elif ! git -C "$ROOT" show "$ref:scripts/cmux-next/cef-manifest.json" > "$tmp" 2>/dev/null; then
  echo "skip: $ref has no scripts/cmux-next/cef-manifest.json in this checkout"
  exit 0
fi
python3 -I - "$classic" "$tmp" "$strict" <<'PY'
import json, sys
classic, nxt, strict = json.load(open(sys.argv[1])), json.load(open(sys.argv[2])), sys.argv[3] == "1"
fields = ["version", "chromium", "sha256", "cmux_cef_api_version", "x86_64.sha256"]
def get(d, key):
    for part in key.split("."):
        d = d.get(part) if isinstance(d, dict) else None
    return d
diff = []
for key in fields:
    a, b = get(classic, key), get(nxt, key)
    print(f"{key}: classic={a} next={b}")
    if a != b:
        diff.append(key)
if diff:
    print(("error" if strict else "warning") + ": the CEF pins differ in " + ", ".join(diff) +
          "; bump both manifests (and the CEFShim copy) together", file=sys.stderr)
    sys.exit(1 if strict else 0)
print("CEF pins match")
PY
