#!/usr/bin/env bash
# The signed web update pointer (scripts/cmux-next/web-ota-pointer.py, plans/cmux-next/web-ota.md):
# a pointer signed by a listed key verifies; a changed payload, an unlisted key, a key file entry
# whose id does not match and the wrong channel are refused; `newer` moves only forward and
# replaces a pointer no trusted key covers. Needs openssl 3 (ed25519 with pkeyutl -rawin).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PTR="$ROOT/scripts/cmux-next/web-ota-pointer.py"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$@" >&2; exit 1; }

keyfile() { # PEM OUT: a key list holding PEM's public key
  python3 - "$1" "$2" <<'PY'
import base64, hashlib, json, subprocess, sys
der = subprocess.run(["openssl", "pkey", "-in", sys.argv[1], "-pubout", "-outform", "DER"], capture_output=True, check=True).stdout
raw = der[-32:]
json.dump({"keys": [{"id": hashlib.sha256(raw).hexdigest()[:16], "ed25519": base64.b64encode(raw).decode()}]}, open(sys.argv[2], "w"))
PY
}
openssl genpkey -algorithm ed25519 -out "$TMP/a.pem" 2>/dev/null
openssl genpkey -algorithm ed25519 -out "$TMP/b.pem" 2>/dev/null
keyfile "$TMP/a.pem" "$TMP/keys-a.json"
keyfile "$TMP/b.pem" "$TMP/keys-b.json"

sha=$(printf 'x%.0s' {1..64} | tr x b)
key=$(printf 'x%.0s' {1..64} | tr x a)
cat >"$TMP/manifest.json" <<JSON
{"schema": 1, "key": "$key", "archive": "web-bundles-$sha.tar.gz", "sha256": "$sha", "size": 42,
 "outputs": "$key", "commit": "0000000000000000000000000000000000000000"}
JSON
printf '{"abi": 3}\n' >"$TMP/abi.json"
payload() { # COMMITTED_AT OUT
  python3 "$PTR" payload --manifest "$TMP/manifest.json" --abi-file "$TMP/abi.json" --channel every-merge \
    --commit 1111111111111111111111111111111111111111 --committed-at "$1" --out "$2"
}
payload 100 "$TMP/p1"
python3 "$PTR" sign --payload "$TMP/p1" --key "$TMP/a.pem" --keys "$TMP/keys-a.json" --out "$TMP/ptr1.json"
out=$(python3 "$PTR" verify --pointer "$TMP/ptr1.json" --keys "$TMP/keys-a.json" --channel every-merge)
python3 -c 'import json,sys; v=json.loads(sys.argv[1]); assert v["abi"]==3 and v["committed_at"]==100 and v["size"]==42, v' "$out" \
  || fail "the verified payload lost a field"

# The signer must be listed: an unlisted key never signs a pointer the app would refuse.
python3 "$PTR" sign --payload "$TMP/p1" --key "$TMP/b.pem" --keys "$TMP/keys-a.json" --out "$TMP/x.json" 2>/dev/null \
  && fail "signing with an unlisted key succeeded"
python3 "$PTR" verify --pointer "$TMP/ptr1.json" --keys "$TMP/keys-b.json" 2>/dev/null \
  && fail "a pointer verified against another key"
python3 "$PTR" verify --pointer "$TMP/ptr1.json" --keys "$TMP/keys-a.json" --channel nightly 2>/dev/null \
  && fail "an every-merge pointer verified as nightly"

# The promoted NEXT workflow publishes a distinct nightly pointer. Its payload
# and read-back verification use the same signed channel contract.
python3 "$PTR" payload --manifest "$TMP/manifest.json" --abi-file "$TMP/abi.json" --channel nightly \
  --commit 1111111111111111111111111111111111111111 --committed-at 100 --out "$TMP/nightly-payload"
python3 "$PTR" sign --payload "$TMP/nightly-payload" --key "$TMP/a.pem" --keys "$TMP/keys-a.json" --out "$TMP/nightly.json"
python3 "$PTR" verify --pointer "$TMP/nightly.json" --keys "$TMP/keys-a.json" --channel nightly >/dev/null \
  || fail "the nightly pointer did not verify"

# One changed payload byte (the size) breaks the signature.
python3 - "$TMP/ptr1.json" "$TMP/tampered.json" <<'PY'
import base64, json, sys
e = json.load(open(sys.argv[1]))
e["payload"] = base64.b64encode(base64.b64decode(e["payload"]).replace(b'"size":42', b'"size":43')).decode()
json.dump(e, open(sys.argv[2], "w"))
PY
python3 "$PTR" verify --pointer "$TMP/tampered.json" --keys "$TMP/keys-a.json" 2>/dev/null \
  && fail "a changed payload verified"

# A key entry whose id is not its key's digest is refused.
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["keys"][0]["id"]="0"*16; json.dump(d, open(sys.argv[2],"w"))' \
  "$TMP/keys-a.json" "$TMP/keys-bad.json"
python3 "$PTR" verify --pointer "$TMP/ptr1.json" --keys "$TMP/keys-bad.json" 2>/dev/null \
  && fail "a key list with a wrong id was accepted"

# newer: first publish, forward, same commit time, backward, unverifiable current.
python3 "$PTR" newer --pointer "$TMP/ptr1.json" --keys "$TMP/keys-a.json" --current "$TMP/none.json" \
  || fail "the first pointer was not taken"
sed -i.bak "s/$key/$(printf 'x%.0s' {1..64} | tr x c)/" "$TMP/manifest.json"
payload 200 "$TMP/p2"
python3 "$PTR" sign --payload "$TMP/p2" --key "$TMP/a.pem" --keys "$TMP/keys-a.json" --out "$TMP/ptr2.json"
python3 "$PTR" newer --pointer "$TMP/ptr2.json" --keys "$TMP/keys-a.json" --current "$TMP/ptr1.json" \
  || fail "a newer pointer did not move forward"
rc=0; python3 "$PTR" newer --pointer "$TMP/ptr1.json" --keys "$TMP/keys-a.json" --current "$TMP/ptr2.json" 2>/dev/null || rc=$?
[[ $rc == 3 ]] || fail "an older pointer was not kept back (exit $rc)"
rc=0; python3 "$PTR" newer --pointer "$TMP/ptr2.json" --keys "$TMP/keys-a.json" --current "$TMP/ptr2.json" 2>/dev/null || rc=$?
[[ $rc == 3 ]] || fail "the same pointer was not kept back (exit $rc)"
# A pointer that does not verify is an error, not "keep the published one".
rc=0; python3 "$PTR" newer --pointer "$TMP/tampered.json" --keys "$TMP/keys-a.json" --current "$TMP/ptr2.json" 2>/dev/null || rc=$?
[[ $rc == 1 ]] || fail "an unverifiable new pointer exited $rc"
python3 "$PTR" newer --pointer "$TMP/ptr1.json" --keys "$TMP/keys-a.json" --current "$TMP/tampered.json" 2>/dev/null \
  || fail "an unverifiable published pointer was kept"

# A published pointer with a malformed signature is replaced, not an error.
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["signatures"][0]["sig"]="not base64!"; json.dump(d, open(sys.argv[2],"w"))' \
  "$TMP/ptr1.json" "$TMP/badsig.json"
python3 "$PTR" newer --pointer "$TMP/ptr2.json" --keys "$TMP/keys-a.json" --current "$TMP/badsig.json" 2>/dev/null \
  || fail "a published pointer with a malformed signature was kept"

# A manifest from before manifests carried outputs is skipped, not an error.
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["outputs"]=None; json.dump(d, open(sys.argv[2],"w"))' \
  "$TMP/manifest.json" "$TMP/manifest-old.json"
rc=0; python3 "$PTR" payload --manifest "$TMP/manifest-old.json" --abi-file "$TMP/abi.json" --channel every-merge \
  --commit "$(printf '1%.0s' {1..40})" --committed-at 1 --out "$TMP/p-old" 2>/dev/null || rc=$?
[[ $rc == 3 ]] || fail "a manifest without outputs exited $rc"

# The committed key list is well formed.
python3 - "$ROOT/Packages/macOS/CmuxNext/Sources/CmuxNextUpdater/Resources/web-update-keys.json" <<'PY' || fail "the committed key list is malformed"
import base64, hashlib, json, sys
keys = json.load(open(sys.argv[1]))["keys"]
assert keys
for k in keys:
    raw = base64.b64decode(k["ed25519"])
    assert len(raw) == 32 and hashlib.sha256(raw).hexdigest()[:16] == k["id"], k
PY

echo "web-ota pointer: ok"
