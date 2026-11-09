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

# The Linux release files (purpose cmux-linux-release) and the Cloud machine channel
# (cmux-cloud-machine-update) share the key: `verify --purpose` keeps each from standing in for the other.
release() { # OUT [FIELD=JSON]...: a Linux release payload, fields overridden
  python3 - "$@" <<'PY'
import json, sys, time
commit = "c" * 40
now = int(time.time())
files = lambda target: {name: {"url": f"https://files.cmux.com/cmux-tui/{commit}/{name}-{target}",
                               "sha256": "d" * 64, "size": 7} for name in ("cmux-tui", "cmux-tui-hook")}
value = {"schema": 1, "purpose": "cmux-linux-release", "channel": "feat-cmux-next",
         # 1794207612 is 2026-11-09 07:00:12 UTC.
         "version": f"1.0.0+20261109070012.{commit[:12]}", "commit": commit, "committed_at": 1794207612,
         "published_at": now, "expires_at": now + 30 * 86400,
         "targets": {t: files(t) for t in ("x86_64-unknown-linux-gnu", "aarch64-unknown-linux-gnu",
                                           "x86_64-unknown-linux-musl", "aarch64-unknown-linux-musl")}}
for change in sys.argv[2:]:
    field, _, raw = change.partition("=")
    node, *path = field.split(".")
    holder = value
    keys = [node, *path]
    for key in keys[:-1]:
        holder = holder[key]
    holder[keys[-1]] = json.loads(raw)
open(sys.argv[1], "wb").write(json.dumps(value, sort_keys=True, separators=(",", ":")).encode())
PY
}
signed() { # NAME [FIELD=JSON]...: $TMP/NAME.json, a signed Linux release file
  local name=$1; shift
  release "$TMP/$name.payload" "$@"
  python3 "$PTR" sign --payload "$TMP/$name.payload" --key "$TMP/a.pem" --keys "$TMP/keys-a.json" --out "$TMP/$name.json"
}
accepts() { # WHAT FILE VERIFY-ARGS...
  local what=$1 file=$2; shift 2
  python3 "$PTR" verify --pointer "$file" --keys "$TMP/keys-a.json" "$@" >/dev/null || fail "$what was refused"
}
refuses() { # WHAT FILE VERIFY-ARGS...
  local what=$1 file=$2; shift 2
  python3 "$PTR" verify --pointer "$file" --keys "$TMP/keys-a.json" "$@" 2>/dev/null >/dev/null && fail "$what verified"
  return 0
}
LR=(--purpose cmux-linux-release --channel feat-cmux-next)
signed rel
out=$(python3 "$PTR" verify --pointer "$TMP/rel.json" --keys "$TMP/keys-a.json" "${LR[@]}")
python3 -c '
import json, sys
v = json.loads(sys.argv[1])
assert v["purpose"] == "cmux-linux-release" and v["version"] == "1.0.0+20261109070012.cccccccccccc", v
assert v["targets"]["x86_64-unknown-linux-gnu"]["cmux-tui-hook"]["size"] == 7, v' "$out" \
  || fail "the verified Linux release payload lost a field"
refuses "a Linux release file for another channel" "$TMP/rel.json" --purpose cmux-linux-release --channel nightly
refuses "a Linux release file as a Cloud machine update" "$TMP/rel.json" --purpose cmux-cloud-machine-update
refuses "a Linux release file as the Cloud machine channel" "$TMP/rel.json" --channel cloud-machine
# A Cloud machine channel file, the same key, is not a Linux release file.
python3 - "$TMP/machine.payload" <<'PY'
import json, sys, time
c = "c" * 40
t = "x86_64-unknown-linux-musl"
now = int(time.time())
v = {"schema": 1, "purpose": "cmux-cloud-machine-update", "channel": "cloud-machine", "key": "e" * 64,
     "commit": c, "committed_at": 1794207612, "published_at": now, "expires_at": now + 86400,
     "targets": {t: {n: {"url": f"https://files.cmux.com/cmux-tui/{c}/{n}-{t}", "sha256": "d" * 64, "size": 7}
                     for n in ("cmux-tui", "cmux-tui-hook")}}}
open(sys.argv[1], "wb").write(json.dumps(v, sort_keys=True, separators=(",", ":")).encode())
PY
python3 "$PTR" sign --payload "$TMP/machine.payload" --key "$TMP/a.pem" --keys "$TMP/keys-a.json" --out "$TMP/machine.json"
accepts "the Cloud machine channel" "$TMP/machine.json" --purpose cmux-cloud-machine-update --channel cloud-machine
accepts "the Cloud machine channel without --purpose" "$TMP/machine.json" --channel cloud-machine
refuses "a Cloud machine channel file as a Linux release file" "$TMP/machine.json" --purpose cmux-linux-release
signed relmachine purpose='"cmux-cloud-machine-update"'
refuses "a Linux-shaped payload of the machine purpose" "$TMP/relmachine.json" --purpose cmux-linux-release
# A web pointer (no purpose) is neither.
refuses "a web pointer as a Linux release file" "$TMP/ptr1.json" --purpose cmux-linux-release

# Expiry: a channel pointer is held to expires_at; the per-commit file (--allow-expired) is not.
signed expired committed_at=1600000000 published_at=1600000100 expires_at=1602592100 'version="1.0.0+20200913122640.cccccccccccc"'
refuses "an expired Linux release pointer" "$TMP/expired.json" "${LR[@]}"
accepts "an expired per-commit release file" "$TMP/expired.json" "${LR[@]}" --allow-expired
python3 "$PTR" verify --pointer "$TMP/expired.json" --keys "$TMP/keys-a.json" --allow-expired 2>/dev/null \
  && fail "--allow-expired without --purpose was accepted"

# URLs stay under https://files.cmux.com/cmux-tui/<commit>/; binaries carry their own name.
signed offhost 'targets.x86_64-unknown-linux-gnu.cmux-tui.url="https://example.com/cmux-tui/cccccccccccccccccccccccccccccccccccccccc/cmux-tui-x86_64-unknown-linux-gnu"'
refuses "a URL on another host" "$TMP/offhost.json" "${LR[@]}"
signed othercommit "targets.x86_64-unknown-linux-gnu.cmux-tui.url=\"https://files.cmux.com/cmux-tui/$(printf 'f%.0s' {1..40})/cmux-tui-x86_64-unknown-linux-gnu\""
refuses "a URL under another commit" "$TMP/othercommit.json" "${LR[@]}"
signed traversal 'targets.x86_64-unknown-linux-gnu.cmux-tui.url="https://files.cmux.com/cmux-tui/cccccccccccccccccccccccccccccccccccccccc/../x/cmux-tui-x86_64-unknown-linux-gnu"'
refuses "a URL that leaves the commit prefix" "$TMP/traversal.json" "${LR[@]}"
signed swapped 'targets.x86_64-unknown-linux-gnu.cmux-tui.url="https://files.cmux.com/cmux-tui/cccccccccccccccccccccccccccccccccccccccc/cmux-tui-aarch64-unknown-linux-musl"'
refuses "another target's binary" "$TMP/swapped.json" "${LR[@]}"
signed extra 'targets.x86_64-unknown-linux-gnu.deb={"url":"https://files.cmux.com/cmux-tui/cccccccccccccccccccccccccccccccccccccccc/cmux_1.0.0_amd64.deb","sha256":"'"$(printf 'd%.0s' {1..64})"'","size":9}'
accepts "a package under the commit prefix" "$TMP/extra.json" "${LR[@]}"
signed badsha 'targets.x86_64-unknown-linux-gnu.cmux-tui.sha256="nothex"'
refuses "a bad sha256" "$TMP/badsha.json" "${LR[@]}"
# Every Linux target an installer may ask for, with both binaries (review of #39452, F1).
signed notarget 'targets.aarch64-unknown-linux-gnu=null'
refuses "a release file without one Linux target" "$TMP/notarget.json" "${LR[@]}"
signed nohook 'targets.x86_64-unknown-linux-musl={"cmux-tui":{"url":"https://files.cmux.com/cmux-tui/cccccccccccccccccccccccccccccccccccccccc/cmux-tui-x86_64-unknown-linux-musl","sha256":"'"$(printf 'd%.0s' {1..64})"'","size":7}}'
refuses "a release file whose target lacks cmux-tui-hook" "$TMP/nohook.json" "${LR[@]}"
signed badversion 'version="1.0.0+20261109070013.cccccccccccc"'
refuses "a version that is not the commit time" "$TMP/badversion.json" "${LR[@]}"

# same-build: the per-commit file is written once. A re-sign of the same build (another
# published_at and expires_at) is the same build; any other field is not.
signed resigned published_at=1794209999 expires_at=1796809999
python3 "$PTR" same-build --pointer "$TMP/rel.json" --current "$TMP/resigned.json" --keys "$TMP/keys-a.json" 2>/dev/null \
  || fail "a re-sign of the same build was not the same build"
python3 "$PTR" same-build --pointer "$TMP/rel.json" --current "$TMP/extra.json" --keys "$TMP/keys-a.json" 2>/dev/null \
  && fail "a file with other targets was the same build"
python3 "$PTR" same-build --pointer "$TMP/rel.json" --current "$TMP/machine.json" --keys "$TMP/keys-a.json" 2>/dev/null \
  && fail "a Cloud machine file was the same build as a Linux release file"
python3 "$PTR" same-build --pointer "$TMP/rel.json" --current "$TMP/tampered.json" --keys "$TMP/keys-a.json" 2>/dev/null \
  && fail "an unsigned file was the same build"

# newer orders Linux release pointers (no `key` field) by commit time.
signed later committed_at=1794207700 'version="1.0.0+20261109070140.cccccccccccc"'
python3 "$PTR" newer --pointer "$TMP/later.json" --keys "$TMP/keys-a.json" --current "$TMP/rel.json" \
  || fail "a later Linux release did not move the pointer"
rc=0; python3 "$PTR" newer --pointer "$TMP/rel.json" --keys "$TMP/keys-a.json" --current "$TMP/later.json" 2>/dev/null || rc=$?
[[ $rc == 3 ]] || fail "an older Linux release moved the pointer back (exit $rc)"
rc=0; python3 "$PTR" newer --pointer "$TMP/rel.json" --keys "$TMP/keys-a.json" --current "$TMP/resigned.json" 2>/dev/null || rc=$?
[[ $rc == 3 ]] || fail "a re-sign of the published Linux release moved the pointer (exit $rc)"
# A Cloud machine file where the Linux pointer should be is replaced, never kept as newer.
python3 "$PTR" newer --pointer "$TMP/rel.json" --keys "$TMP/keys-a.json" --current "$TMP/machine.json" 2>/dev/null \
  || fail "a Cloud machine file kept the Linux release pointer"
rc=0; python3 "$PTR" newer --pointer "$TMP/badversion.json" --keys "$TMP/keys-a.json" 2>/dev/null || rc=$?
[[ $rc == 1 ]] || fail "a malformed Linux release payload was taken (exit $rc)"

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
