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
mkdir -p "$TMP/source-record"
cat > "$TMP/source-record/published-build.json" <<'JSON'
{"source_run":"45670426505","source_attempt":"1","source_sha":"36e9bf23b16acc13dce97cb4558ab5405c5ca597","publish_result":"success","push_clean":"true","track":"nightly-next","should_publish":"true","no_publish":"false","publish_build":"4567042650501","publish_build_sha":"36e9bf23b16acc13dce97cb4558ab5405c5ca597","publish_refused":"false","publish_already_published":"false","publish_source":"built"}
JSON
(cd "$TMP/source-record" && zip -q "$TMP/source-record.zip" published-build.json)
source_record_artifact_sha="$(sha256sum "$TMP/source-record.zip" | awk '{print $1}')"
cat > "$TMP/provenance.json" <<JSON
{"source_run":"45670426505","source_attempt":"1","source_sha":"36e9bf23b16acc13dce97cb4558ab5405c5ca597","build":"4567042650501","notes_sha256":"$notes_sha","signature_sha256":"$signature_sha","artifact_run":"45679817194","artifact_attempt":"1","artifact_id":"15055020121","artifact_sha256":"$artifact_sha","artifact_name":"release-notes","source_record_artifact_id":"15053076204","source_record_artifact_sha256":"$source_record_artifact_sha","source_record_artifact_name":"nightly-published-build-1"}
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
    printf '{"jobs":[{"name":"sign-release-notes","conclusion":"success"}]}'
    ;;
  repos/manaflow-ai/cmux/actions/artifacts/15053076204)
    printf '{"id":15053076204,"name":"nightly-published-build-1","expired":false,"digest":"sha256:%s","workflow_run":{"id":45670426505,"head_sha":"36e9bf23b16acc13dce97cb4558ab5405c5ca597"}}\n' "$SOURCE_RECORD_ARTIFACT_SHA"
    ;;
  repos/manaflow-ai/cmux/actions/artifacts/15053076204/zip)
    cat "$SOURCE_RECORD_ARTIFACT_ZIP"
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

PATH="$TMP:$PATH" ARTIFACT_SHA="$artifact_sha" ARTIFACT_ZIP="$TMP/release-notes.zip" SOURCE_RECORD_ARTIFACT_SHA="$source_record_artifact_sha" SOURCE_RECORD_ARTIFACT_ZIP="$TMP/source-record.zip" NIGHTLY_NEXT_PULLED_URL="file://$TMP/pulled.json" \
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
if PATH="$TMP:$PATH" ARTIFACT_SHA="$artifact_sha" ARTIFACT_ZIP="$TMP/release-notes.zip" SOURCE_RECORD_ARTIFACT_SHA="$source_record_artifact_sha" SOURCE_RECORD_ARTIFACT_ZIP="$TMP/source-record.zip" NIGHTLY_NEXT_PULLED_URL="file://$TMP/pulled.json" \
  python3 "$SCRIPT" --notes "$TMP/notes.json" --signature "$TMP/tampered.sig" \
  --provenance "$TMP/provenance.json" --public-key "$pub" --dry-run 2>"$TMP/err"; then
  echo "tampered signature was accepted" >&2
  exit 1
fi
grep -q 'signature' "$TMP/err"

printf '[{"build":"4567042650501","reason":"test","pulledAt":"2026-01-01T00:00:00Z","serve":"4567042650401"}]\n' > "$TMP/pulled.json"
if PATH="$TMP:$PATH" ARTIFACT_SHA="$artifact_sha" ARTIFACT_ZIP="$TMP/release-notes.zip" SOURCE_RECORD_ARTIFACT_SHA="$source_record_artifact_sha" SOURCE_RECORD_ARTIFACT_ZIP="$TMP/source-record.zip" NIGHTLY_NEXT_PULLED_URL="file://$TMP/pulled.json" \
  python3 "$SCRIPT" --notes "$TMP/notes.json" --signature "$TMP/notes.json.sig" \
  --provenance "$TMP/provenance.json" --public-key "$pub" --dry-run 2>"$TMP/err"; then
  echo "withdrawn build was accepted" >&2
  exit 1
fi
grep -q 'withdrawn in the protected pulled.json' "$TMP/err"
printf '[]\n' > "$TMP/pulled.json"

if PATH="$TMP:$PATH" ARTIFACT_SHA="$artifact_sha" ARTIFACT_ZIP="$TMP/release-notes.zip" SOURCE_RECORD_ARTIFACT_SHA="$source_record_artifact_sha" SOURCE_RECORD_ARTIFACT_ZIP="$TMP/source-record.zip" NIGHTLY_NEXT_PULLED_URL="file://$TMP/pulled.json" \
  GITHUB_ACTIONS=true GITHUB_REF=refs/heads/nightly-next RELEASE_ENVIRONMENT=release-next \
  R2_ENDPOINT=https://account.r2.cloudflarestorage.com AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test \
  python3 "$SCRIPT" --notes "$TMP/notes.json" --signature "$TMP/notes.json.sig" \
  --provenance "$TMP/provenance.json" --public-key "$pub" 2>"$TMP/err"; then
  echo "caller-selected production key was accepted" >&2
  exit 1
fi
grep -q -- '--public-key is only allowed for dry-run fixtures' "$TMP/err"

sed 's/"notes_sha256":"[0-9a-f]*/"notes_sha256":"0000000000000000000000000000000000000000000000000000000000000000/' "$TMP/provenance.json" > "$TMP/mismatch.json"
if PATH="$TMP:$PATH" ARTIFACT_SHA="$artifact_sha" ARTIFACT_ZIP="$TMP/release-notes.zip" SOURCE_RECORD_ARTIFACT_SHA="$source_record_artifact_sha" SOURCE_RECORD_ARTIFACT_ZIP="$TMP/source-record.zip" NIGHTLY_NEXT_PULLED_URL="file://$TMP/pulled.json" \
  python3 "$SCRIPT" --notes "$TMP/notes.json" --signature "$TMP/notes.json.sig" \
  --provenance "$TMP/mismatch.json" --public-key "$pub" --dry-run 2>"$TMP/err"; then
  echo "digest mismatch was accepted" >&2
  exit 1
fi
grep -q 'does not match provenance' "$TMP/err"

printf '[{"build":"4567042650501"}]\n' > "$TMP/pulled.json"
if PATH="$TMP:$PATH" ARTIFACT_SHA="$artifact_sha" ARTIFACT_ZIP="$TMP/release-notes.zip" SOURCE_RECORD_ARTIFACT_SHA="$source_record_artifact_sha" SOURCE_RECORD_ARTIFACT_ZIP="$TMP/source-record.zip" NIGHTLY_NEXT_PULLED_URL="file://$TMP/pulled.json" \
  python3 "$SCRIPT" --notes "$TMP/notes.json" --signature "$TMP/notes.json.sig" \
  --provenance "$TMP/provenance.json" --public-key "$pub" --dry-run 2>"$TMP/err"; then
  echo "malformed withdrawal record was accepted" >&2
  exit 1
fi
grep -q 'malformed entry' "$TMP/err"
printf '[]\n' > "$TMP/pulled.json"

sed 's/"build":"4567042650501"/"build":"4567042650502"/' "$TMP/provenance.json" > "$TMP/wrong-build.json"
if PATH="$TMP:$PATH" ARTIFACT_SHA="$artifact_sha" ARTIFACT_ZIP="$TMP/release-notes.zip" SOURCE_RECORD_ARTIFACT_SHA="$source_record_artifact_sha" SOURCE_RECORD_ARTIFACT_ZIP="$TMP/source-record.zip" NIGHTLY_NEXT_PULLED_URL="file://$TMP/pulled.json" \
  python3 "$SCRIPT" --notes "$TMP/notes.json" --signature "$TMP/notes.json.sig" \
  --provenance "$TMP/wrong-build.json" --public-key "$pub" --dry-run 2>"$TMP/err"; then
  echo "wrong build provenance was accepted" >&2
  exit 1
fi
grep -q 'does not encode source_run/attempt' "$TMP/err"

sed 's/"source_sha":"36e9bf23b16acc13dce97cb4558ab5405c5ca597"/"source_sha":"0000000000000000000000000000000000000000"/' "$TMP/provenance.json" > "$TMP/wrong-head.json"
if PATH="$TMP:$PATH" ARTIFACT_SHA="$artifact_sha" ARTIFACT_ZIP="$TMP/release-notes.zip" SOURCE_RECORD_ARTIFACT_SHA="$source_record_artifact_sha" SOURCE_RECORD_ARTIFACT_ZIP="$TMP/source-record.zip" NIGHTLY_NEXT_PULLED_URL="file://$TMP/pulled.json" \
  python3 "$SCRIPT" --notes "$TMP/notes.json" --signature "$TMP/notes.json.sig" \
  --provenance "$TMP/wrong-head.json" --public-key "$pub" --dry-run 2>"$TMP/err"; then
  echo "wrong head provenance was accepted" >&2
  exit 1
fi
grep -q 'notes head does not match' "$TMP/err"

cat > "$TMP/fake-uploader" <<'PY'
#!/usr/bin/env python3
import os
from pathlib import Path
import sys

log = Path(os.environ["UPLOAD_LOG"])
count = len(log.read_text().splitlines()) if log.exists() else 0
with log.open("a", encoding="utf-8") as handle:
    handle.write(" ".join(sys.argv[1:]) + "\n")
if os.environ.get("UPLOAD_FAIL_ON") == str(count + 1):
    raise SystemExit(17)
PY
chmod +x "$TMP/fake-uploader"
UPLOAD_LOG="$TMP/upload.log" : > "$TMP/upload.log"
TEST_PUBLIC_KEY="$pub" UPLOAD_LOG="$TMP/upload.log" GITHUB_ACTIONS=true GITHUB_REF=refs/heads/nightly-next RELEASE_ENVIRONMENT=release-next \
  R2_ENDPOINT=https://account.r2.cloudflarestorage.com AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test \
  python3 - "$SCRIPT" "$TMP" <<'PY'
import importlib.util
import os
import pathlib
import sys

script, tmp = sys.argv[1:]
spec = importlib.util.spec_from_file_location("nightly_notes_restore", script)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
module.CONTENT_PUBLIC_KEY = os.environ["TEST_PUBLIC_KEY"]
module.UPLOADER = pathlib.Path(tmp) / "fake-uploader"
module.verify_withdrawal_status = lambda build: None
module.verify_source_record = lambda provenance, notes, signature: None
sys.argv = [script, "--notes", f"{tmp}/notes.json", "--signature", f"{tmp}/notes.json.sig",
            "--provenance", f"{tmp}/provenance.json"]
raise SystemExit(module.main())
PY
[[ "$(wc -l < "$TMP/upload.log")" == 4 ]]
sed -n '1p' "$TMP/upload.log" | grep -q -- '--preflight-only'
sed -n '2p' "$TMP/upload.log" | grep -q -- '--preflight-only'
sed -n '3p' "$TMP/upload.log" | grep -q -- '--write-once'
sed -n '3p' "$TMP/upload.log" | grep -q -- '.json.sig'
sed -n '4p' "$TMP/upload.log" | grep -q -- '--write-once'
sed -n '4p' "$TMP/upload.log" | grep -q -- '.json '

: > "$TMP/upload.log"
if TEST_PUBLIC_KEY="$pub" UPLOAD_LOG="$TMP/upload.log" UPLOAD_FAIL_ON=4 GITHUB_ACTIONS=true GITHUB_REF=refs/heads/nightly-next RELEASE_ENVIRONMENT=release-next \
  R2_ENDPOINT=https://account.r2.cloudflarestorage.com AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test \
  python3 - "$SCRIPT" "$TMP" <<'PY'
import importlib.util
import os
import pathlib
import sys

script, tmp = sys.argv[1:]
spec = importlib.util.spec_from_file_location("nightly_notes_restore", script)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
module.CONTENT_PUBLIC_KEY = os.environ["TEST_PUBLIC_KEY"]
module.UPLOADER = pathlib.Path(tmp) / "fake-uploader"
module.verify_withdrawal_status = lambda build: None
module.verify_source_record = lambda provenance, notes, signature: None
sys.argv = [script, "--notes", f"{tmp}/notes.json", "--signature", f"{tmp}/notes.json.sig",
            "--provenance", f"{tmp}/provenance.json"]
raise SystemExit(module.main())
PY
then
  echo "partial upload failure was accepted" >&2
  exit 1
fi
[[ "$(wc -l < "$TMP/upload.log")" == 4 ]]

rm "$TMP/notes.json.sig"
if PATH="$TMP:$PATH" ARTIFACT_SHA="$artifact_sha" ARTIFACT_ZIP="$TMP/release-notes.zip" NIGHTLY_NEXT_PULLED_URL="file://$TMP/pulled.json" \
  python3 "$SCRIPT" --notes "$TMP/notes.json" --signature "$TMP/notes.json.sig" \
  --provenance "$TMP/provenance.json" --public-key "$pub" --dry-run 2>"$TMP/err"; then
  echo "unsigned notes were accepted" >&2
  exit 1
fi
grep -q 'unsigned records need release-owner signing' "$TMP/err"
echo "nightly-notes-restore: ok"
