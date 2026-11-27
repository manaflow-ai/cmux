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
notes_sha="$(sha256sum "$TMP/notes.json" | awk '{print $1}')"
signature_sha="$(sha256sum "$TMP/notes.json.sig" | awk '{print $1}')"
cat > "$TMP/provenance.json" <<JSON
{"source_run":"45670426505","source_attempt":"1","source_sha":"36e9bf23b16acc13dce97cb4558ab5405c5ca597","build":"4567042650501","withdrawn":false,"notes_sha256":"$notes_sha","signature_sha256":"$signature_sha"}
JSON

python3 "$SCRIPT" --notes "$TMP/notes.json" --signature "$TMP/notes.json.sig" \
  --provenance "$TMP/provenance.json" --public-key "$pub" --dry-run > "$TMP/out"
grep -q '"create_only": true' "$TMP/out"
grep -q 'nightly-next/notes/4567042650501.json.sig' "$TMP/out"

cp "$TMP/notes.json.sig" "$TMP/tampered.sig"
printf 'tamper' >> "$TMP/tampered.sig"
if python3 "$SCRIPT" --notes "$TMP/notes.json" --signature "$TMP/tampered.sig" \
  --provenance "$TMP/provenance.json" --public-key "$pub" --dry-run 2>"$TMP/err"; then
  echo "tampered signature was accepted" >&2
  exit 1
fi
grep -q 'signature' "$TMP/err"

sed 's/"withdrawn":false/"withdrawn":true/' "$TMP/provenance.json" > "$TMP/withdrawn.json"
if python3 "$SCRIPT" --notes "$TMP/notes.json" --signature "$TMP/notes.json.sig" \
  --provenance "$TMP/withdrawn.json" --public-key "$pub" --dry-run 2>"$TMP/err"; then
  echo "withdrawn build was accepted" >&2
  exit 1
fi
grep -q 'withdrawn or unknown' "$TMP/err"

cat > "$TMP/approval.json" <<JSON
{"kind":"nightly-notes-restore","approved":true,"approved_by":"release-owner","environment":"release-next","withdrawal_authority":"release-next","source_run":"45670426505","source_attempt":"1","source_sha":"36e9bf23b16acc13dce97cb4558ab5405c5ca597","build":"4567042650501","withdrawn":false,"notes_sha256":"$notes_sha","signature_sha256":"$signature_sha"}
JSON
sed 's/"approved_by":"release-owner"/"approved_by":""/' "$TMP/approval.json" > "$TMP/bad-approval.json"
if GITHUB_ACTIONS=true GITHUB_REF=refs/heads/nightly-next RELEASE_ENVIRONMENT=release-next \
  R2_ENDPOINT=https://account.r2.cloudflarestorage.com AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test \
  GH_TOKEN=test python3 "$SCRIPT" --notes "$TMP/notes.json" --signature "$TMP/notes.json.sig" \
  --provenance "$TMP/provenance.json" --approval-receipt "$TMP/bad-approval.json" 2>"$TMP/err"; then
  echo "invalid approval was accepted" >&2
  exit 1
fi
grep -q 'approval receipt is missing approved_by' "$TMP/err"

if GITHUB_ACTIONS=true GITHUB_REF=refs/heads/nightly-next RELEASE_ENVIRONMENT=release-next \
  R2_ENDPOINT=https://account.r2.cloudflarestorage.com AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test \
  python3 "$SCRIPT" --notes "$TMP/notes.json" --signature "$TMP/notes.json.sig" \
  --provenance "$TMP/provenance.json" --public-key "$pub" 2>"$TMP/err"; then
  echo "caller-selected production key was accepted" >&2
  exit 1
fi
grep -q -- '--public-key is only allowed for dry-run fixtures' "$TMP/err"

if GITHUB_ACTIONS=true GITHUB_REF=refs/heads/nightly-next RELEASE_ENVIRONMENT=release-next \
  R2_ENDPOINT=https://account.r2.cloudflarestorage.com AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test \
  python3 "$SCRIPT" --notes "$TMP/notes.json" --signature "$TMP/notes.json.sig" \
  --provenance "$TMP/provenance.json" 2>"$TMP/err"; then
  echo "upload without approval was accepted" >&2
  exit 1
fi
grep -q 'release-owner approval receipt is required' "$TMP/err"

sed 's/"notes_sha256":"[0-9a-f]*/"notes_sha256":"0000000000000000000000000000000000000000000000000000000000000000/' "$TMP/provenance.json" > "$TMP/mismatch.json"
if python3 "$SCRIPT" --notes "$TMP/notes.json" --signature "$TMP/notes.json.sig" \
  --provenance "$TMP/mismatch.json" --public-key "$pub" --dry-run 2>"$TMP/err"; then
  echo "digest mismatch was accepted" >&2
  exit 1
fi
grep -q 'does not match provenance' "$TMP/err"

rm "$TMP/notes.json.sig"
if python3 "$SCRIPT" --notes "$TMP/notes.json" --signature "$TMP/notes.json.sig" \
  --provenance "$TMP/provenance.json" --public-key "$pub" --dry-run 2>"$TMP/err"; then
  echo "unsigned notes were accepted" >&2
  exit 1
fi
grep -q 'unsigned records need release-owner signing' "$TMP/err"
echo "nightly-notes-restore: ok"
