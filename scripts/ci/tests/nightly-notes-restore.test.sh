#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/ci/nightly-notes-restore.py"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/nightly-notes-restore.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

openssl genpkey -algorithm ED25519 -out "$TMP/key.pem" >/dev/null 2>&1
openssl pkey -in "$TMP/key.pem" -pubout -outform DER -out "$TMP/pub.der" >/dev/null 2>&1
pub="$(python3 - "$TMP/pub.der" <<'PY'
import base64, sys
raw = open(sys.argv[1], "rb").read()
print(base64.b64encode(raw[-32:]).decode())
PY
)"
cat > "$TMP/notes.json" <<'JSON'
{"build":"4567042650501","head":"36e9bf23b16acc13dce97cb4558ab5405c5ca597","whatsNew":{"entries":[{"title":{"en":"A change"}}]}}
JSON
openssl pkeyutl -sign -inkey "$TMP/key.pem" -rawin -in "$TMP/notes.json" -out "$TMP/notes.sig.bin"
base64 -w0 "$TMP/notes.sig.bin" > "$TMP/notes.json.sig"
cat > "$TMP/provenance.json" <<'JSON'
{"source_run":"45670426505","source_attempt":"1","source_sha":"36e9bf23b16acc13dce97cb4558ab5405c5ca597","build":"4567042650501","withdrawn":false}
JSON

python3 "$SCRIPT" --notes "$TMP/notes.json" --signature "$TMP/notes.json.sig" \
  --provenance "$TMP/provenance.json" --public-key "$pub" --dry-run > "$TMP/out"
grep -q '"create_only": true' "$TMP/out"
grep -q 'nightly-next/notes/4567042650501.json.sig' "$TMP/out"

sed 's/"withdrawn":false/"withdrawn":true/' "$TMP/provenance.json" > "$TMP/withdrawn.json"
if python3 "$SCRIPT" --notes "$TMP/notes.json" --signature "$TMP/notes.json.sig" \
  --provenance "$TMP/withdrawn.json" --public-key "$pub" --dry-run 2>"$TMP/err"; then
  echo "withdrawn build was accepted" >&2
  exit 1
fi
grep -q 'withdrawn or unknown' "$TMP/err"

rm "$TMP/notes.json.sig"
if python3 "$SCRIPT" --notes "$TMP/notes.json" --signature "$TMP/notes.json.sig" \
  --provenance "$TMP/provenance.json" --public-key "$pub" --dry-run 2>"$TMP/err"; then
  echo "unsigned notes were accepted" >&2
  exit 1
fi
grep -q 'unsigned records need release-owner signing' "$TMP/err"
echo "nightly-notes-restore: ok"
