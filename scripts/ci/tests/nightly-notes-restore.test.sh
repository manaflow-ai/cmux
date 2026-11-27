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
mkdir -p "$TMP/artifact"
cp "$TMP/notes.json" "$TMP/artifact/4567042650501.json"
cp "$TMP/notes.json.sig" "$TMP/artifact/4567042650501.json.sig"
(cd "$TMP/artifact" && zip -q "$TMP/release-notes.zip" 4567042650501.json 4567042650501.json.sig)
artifact_sha="$(sha256sum "$TMP/release-notes.zip" | awk '{print $1}')"
cat > "$TMP/provenance.json" <<JSON
{"source_run":"45670426505","source_attempt":"1","source_sha":"36e9bf23b16acc13dce97cb4558ab5405c5ca597","build":"4567042650501","notes_sha256":"$notes_sha","signature_sha256":"$signature_sha","artifact_run":"45679817194","artifact_attempt":"1","artifact_id":"15055020121","artifact_sha256":"$artifact_sha","artifact_name":"release-notes"}
JSON
printf '[]\n' > "$TMP/pulled.json"

cat > "$TMP/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == api ]] || exit 2
path="$2"
case "$path" in
  repos/manaflow-ai/cmux/actions/runs/45670426505/attempts/1)
    cat <<'JSON'
{"id":45670426505,"run_attempt":1,"path":".github/workflows/nightly.yml","head_branch":"nightly-next","head_sha":"36e9bf23b16acc13dce97cb4558ab5405c5ca597","event":"push","status":"completed","conclusion":"cancelled","repository":{"full_name":"manaflow-ai/cmux"},"head_repository":{"full_name":"manaflow-ai/cmux"}}
JSON
    ;;
  repos/manaflow-ai/cmux/actions/runs/45670426505/jobs*)
    printf '{"jobs":[{"name":"nightly-next-one","conclusion":"success"}]}'
    ;;
  repos/manaflow-ai/cmux/actions/runs/45679817194/attempts/1)
    cat <<'JSON'
{"id":45679817194,"run_attempt":1,"path":".github/workflows/nightly.yml","head_branch":"nightly-next","head_sha":"36e9bf23b16acc13dce97cb4558ab5405c5ca597","event":"workflow_dispatch","status":"completed","conclusion":"failure","repository":{"full_name":"manaflow-ai/cmux"},"head_repository":{"full_name":"manaflow-ai/cmux"}}
JSON
    ;;
  repos/manaflow-ai/cmux/actions/runs/45679817194/jobs*)
    printf '{"jobs":[{"name":"published-in","conclusion":"success"}]}'
    ;;
  repos/manaflow-ai/cmux/actions/artifacts/15055020121)
    printf '{"id":15055020121,"name":"release-notes","expired":false,"digest":"sha256:%s","workflow_run":{"id":45679817194,"head_sha":"36e9bf23b16acc13dce97cb4558ab5405c5ca597"}}\n' "$ARTIFACT_SHA"
    ;;
  repos/manaflow-ai/cmux/actions/artifacts/15055020121/zip)
    cat "$ARTIFACT_ZIP"
    ;;
  *) echo "unexpected fake gh path: $path" >&2; exit 3 ;;
esac
SH
chmod +x "$TMP/gh"

PATH="$TMP:$PATH" ARTIFACT_SHA="$artifact_sha" ARTIFACT_ZIP="$TMP/release-notes.zip" NIGHTLY_NEXT_PULLED_URL="file://$TMP/pulled.json" \
  python3 "$SCRIPT" --notes "$TMP/notes.json" --signature "$TMP/notes.json.sig" \
  --provenance "$TMP/provenance.json" --public-key "$pub" --dry-run > "$TMP/out"
grep -q '"create_only": true' "$TMP/out"
grep -q '"source_record_checked": true' "$TMP/out"

python3 - "$TMP/notes.json.sig" "$TMP/tampered.sig" <<'PY'
import base64, sys
raw = bytearray(base64.b64decode(open(sys.argv[1]).read()))
raw[0] ^= 1
open(sys.argv[2], "w").write(base64.b64encode(raw).decode())
PY
if PATH="$TMP:$PATH" ARTIFACT_SHA="$artifact_sha" ARTIFACT_ZIP="$TMP/release-notes.zip" NIGHTLY_NEXT_PULLED_URL="file://$TMP/pulled.json" \
  python3 "$SCRIPT" --notes "$TMP/notes.json" --signature "$TMP/tampered.sig" \
  --provenance "$TMP/provenance.json" --public-key "$pub" --dry-run 2>"$TMP/err"; then
  echo "tampered signature was accepted" >&2
  exit 1
fi
grep -q 'signature' "$TMP/err"

printf '[{"build":"4567042650501","reason":"test","pulledAt":"2026-01-01T00:00:00Z","serve":"4567042650401"}]\n' > "$TMP/pulled.json"
if PATH="$TMP:$PATH" ARTIFACT_SHA="$artifact_sha" ARTIFACT_ZIP="$TMP/release-notes.zip" NIGHTLY_NEXT_PULLED_URL="file://$TMP/pulled.json" \
  python3 "$SCRIPT" --notes "$TMP/notes.json" --signature "$TMP/notes.json.sig" \
  --provenance "$TMP/provenance.json" --public-key "$pub" --dry-run 2>"$TMP/err"; then
  echo "withdrawn build was accepted" >&2
  exit 1
fi
grep -q 'withdrawn in the protected pulled.json' "$TMP/err"
printf '[]\n' > "$TMP/pulled.json"

if PATH="$TMP:$PATH" ARTIFACT_SHA="$artifact_sha" ARTIFACT_ZIP="$TMP/release-notes.zip" NIGHTLY_NEXT_PULLED_URL="file://$TMP/pulled.json" \
  GITHUB_ACTIONS=true GITHUB_REF=refs/heads/nightly-next RELEASE_ENVIRONMENT=release-next \
  R2_ENDPOINT=https://account.r2.cloudflarestorage.com AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test \
  python3 "$SCRIPT" --notes "$TMP/notes.json" --signature "$TMP/notes.json.sig" \
  --provenance "$TMP/provenance.json" --public-key "$pub" 2>"$TMP/err"; then
  echo "caller-selected production key was accepted" >&2
  exit 1
fi
grep -q -- '--public-key is only allowed for dry-run fixtures' "$TMP/err"

sed 's/"notes_sha256":"[0-9a-f]*/"notes_sha256":"0000000000000000000000000000000000000000000000000000000000000000/' "$TMP/provenance.json" > "$TMP/mismatch.json"
if PATH="$TMP:$PATH" ARTIFACT_SHA="$artifact_sha" ARTIFACT_ZIP="$TMP/release-notes.zip" NIGHTLY_NEXT_PULLED_URL="file://$TMP/pulled.json" \
  python3 "$SCRIPT" --notes "$TMP/notes.json" --signature "$TMP/notes.json.sig" \
  --provenance "$TMP/mismatch.json" --public-key "$pub" --dry-run 2>"$TMP/err"; then
  echo "digest mismatch was accepted" >&2
  exit 1
fi
grep -q 'does not match provenance' "$TMP/err"

rm "$TMP/notes.json.sig"
if PATH="$TMP:$PATH" ARTIFACT_SHA="$artifact_sha" ARTIFACT_ZIP="$TMP/release-notes.zip" NIGHTLY_NEXT_PULLED_URL="file://$TMP/pulled.json" \
  python3 "$SCRIPT" --notes "$TMP/notes.json" --signature "$TMP/notes.json.sig" \
  --provenance "$TMP/provenance.json" --public-key "$pub" --dry-run 2>"$TMP/err"; then
  echo "unsigned notes were accepted" >&2
  exit 1
fi
grep -q 'unsigned records need release-owner signing' "$TMP/err"
echo "nightly-notes-restore: ok"
