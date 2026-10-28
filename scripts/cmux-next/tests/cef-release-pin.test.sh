#!/usr/bin/env bash
# The release pin of the fork's API 31 train (p01-process task 178):
# cef_release_pin.py pin writes a whole manifest (both arches, both debug
# assets, no staging object) only for a release at or above the app's fork API
# floor (the Chromium host's kMinForkAPI, read from the source) whose skipped
# API numbers are named exactly; publish-cef-r2.sh uploads the four assets to
# a local fake of the R2 S3 API and writes their keys; check and
# --verify-manifest then pass, and fail when an object or a field is wrong.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pin="$here/../cef_release_pin.py"
publish="$here/../publish-cef-r2.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/cef-release-pin.XXXXXX")"
server=""
cleanup() { [[ -z "$server" ]] || kill "$server" 2>/dev/null || true; rm -rf "$work"; }
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
tag=cef-154.0.28-cmux.35
ref=746f1220f6f61bde0a8e4f28337e57be720c43ca

# A release: four assets, SHA256SUMS, and the two source files pin reads.
mkdir -p "$work/release" "$work/src"
for name in macos-arm64 macos-arm64-debug macos-x86_64 macos-x86_64-debug; do
  printf 'asset %s\n' "$name" > "$work/release/$tag-$name.tar.xz"
done
(cd "$work/release" && shasum -a 256 ./*.tar.xz | sed 's# \./# #') > "$work/src/SHA256SUMS"
cat > "$work/src/CHROMIUM_BUILD_COMPATIBILITY.txt" <<'TXT'
{
  'chromium_checkout': 'refs/tags/154.0.8037.98',
}
TXT
header() { # <define> <history numbers...>
  local define=$1; shift
  { echo "// Version of this API."
    for n in "$@"; do printf '//  %2d entry %s\n//      wrapped line 99 of it\n' "$n" "$n"; done
    echo "#define CMUX_CEF_API_VERSION $define"; } > "$work/src/cef_cmux.h"
}
pin_it() { python3 -I "$pin" pin "$tag" --from "$work/src" --ref "$ref" --manifest "$work/m.json" "$@" 2>"$work/err"; }

# Below the app's floor (kMinForkAPI of chromium_host_wire.h): refused, nothing written.
floor="$(sed -n 's/^inline constexpr int kMinForkAPI = \([0-9]*\);$/\1/p' \
  "$here/../../../Packages/macOS/CmuxNext/ChromiumHost/src/chromium_host_wire.h")"
[[ "$floor" =~ ^[0-9]+$ && "$floor" -ge 30 && "$floor" -lt 31 ]] ||
  fail "this test pins API 31 with 28 and 29 skipped; it expects the app floor 30, the source says ${floor:-nothing}"
header 29 $(seq 1 27) 29
pin_it --accept-missing-api 28 && fail "an API 29 release was pinned below the app floor $floor"
grep -q "needs >= $floor" "$work/err" || fail "API 29: $(cat "$work/err")"
[[ ! -e "$work/m.json" ]] || fail "a refused pin wrote the manifest"
# --min-api raises the floor: API 30 refused at 31.
header 30 $(seq 1 27) 30
pin_it --accept-missing-api 28,29 --min-api 31 && fail "an API 30 release was pinned with --min-api 31"
grep -q "needs >= 31" "$work/err" || fail "API 30 at --min-api 31: $(cat "$work/err")"
[[ ! -e "$work/m.json" ]] || fail "a refused pin wrote the manifest"

# API 31 that skips 28 and 29: refused unless exactly those are named.
header 31 $(seq 1 27) 30 31
pin_it && fail "a release that skips 28 and 29 was pinned without --accept-missing-api"
grep -q "skips \[28, 29\]" "$work/err" || fail "skip message: $(cat "$work/err")"
pin_it --accept-missing-api 28 && fail "naming 28 alone was accepted"
pin_it --accept-missing-api 28,29 --fork-branch cp/p01-process-178 \
  --debug-symbols "Chromium Embedded Framework.dSYM.tar.xz" || fail "pin: $(cat "$work/err")"
python3 -I - "$work/m.json" "$tag" "$ref" <<'PY' || fail "manifest fields"
import json, sys
m, tag, ref = json.load(open(sys.argv[1])), sys.argv[2], sys.argv[3]
x = m["x86_64"]
assert m["version"] == m["tag"] == tag and m["cef"] == "154.0.28", m
assert m["chromium"] == "154.0.8037.98" and m["arch"] == "arm64", m
assert m["cmux_cef_api_version"] == 31 and m["missing_api"] == [28, 29], m
assert m["fork_ref"] == x["fork_ref"] == ref and m["fork_branch"] == "cp/p01-process-178", m
assert m["asset"] == f"{tag}-macos-arm64.tar.xz" and m["debug_asset"] == f"{tag}-macos-arm64-debug.tar.xz", m
assert x["asset"] == f"{tag}-macos-x86_64.tar.xz" and x["debug_asset"] == f"{tag}-macos-x86_64-debug.tar.xz", x
assert m["url"].endswith(f"/releases/download/{tag}/{tag}-macos-arm64.tar.xz"), m
assert m["require_dcheck_off"] is True and "staging" not in m and "r2_key" not in m, m
assert m["debug_symbols"] == x["debug_symbols"] == "Chromium Embedded Framework.dSYM.tar.xz", m
PY

# A release without a debug asset is refused.
grep -v x86_64-debug "$work/src/SHA256SUMS" > "$work/sums" && cp "$work/src/SHA256SUMS" "$work/sums.all"
cp "$work/sums" "$work/src/SHA256SUMS"
pin_it --accept-missing-api 28,29 && fail "a release without the x86_64 debug asset was pinned"
grep -q "macos-x86_64-debug.tar.xz" "$work/err" || fail "debug message: $(cat "$work/err")"
cp "$work/sums.all" "$work/src/SHA256SUMS"
pin_it --accept-missing-api 28,29 || fail "re-pin: $(cat "$work/err")"

# Before the upload the pin has no R2 keys: check fails.
python3 -I "$pin" check --manifest "$work/m.json" 2>"$work/err" && fail "a pin without R2 keys passed check"
grep -q "no r2_bucket" "$work/err" || fail "check message: $(cat "$work/err")"

# Upload to the fake R2, which writes the keys into the manifest.
mkdir -p "$work/s3"
python3 -I "$here/fake_s3.py" "$work/s3" "$work/port" & server=$!
for _ in $(seq 1 50); do [[ -s "$work/port" ]] && break; sleep 0.1; done
[[ -s "$work/port" ]] || fail "the fake S3 did not start"
port="$(cat "$work/port")"
export CMUX_CEF_R2_ENV_FILE="$work/none.env" CMUX_CEF_R2_ENDPOINT="http://127.0.0.1:$port"
export CMUX_CEF_R2_WRITE_ACCESS_KEY_ID=w CMUX_CEF_R2_WRITE_SECRET_ACCESS_KEY=ws
unset CMUX_CEF_R2_ACCESS_KEY_ID CMUX_CEF_R2_SECRET_ACCESS_KEY CMUX_CEF_R2_BUCKET || true
bash "$publish" "$tag" --dir "$work/release" --manifest "$work/m.json" >"$work/keys" 2>"$work/err" ||
  fail "publish: $(cat "$work/err")"
[[ "$(wc -l < "$work/keys")" -eq 4 ]] || fail "publish printed $(wc -l < "$work/keys") keys, want 4"
# A second run finds every key (write-once) and only re-verifies.
bash "$publish" "$tag" --dir "$work/release" >/dev/null 2>"$work/err" || fail "re-publish: $(cat "$work/err")"
[[ "$(grep -c 'already exists' "$work/err")" -eq 4 ]] || fail "re-publish uploaded again: $(cat "$work/err")"

python3 -I "$pin" check --manifest "$work/m.json" 2>"$work/err" || fail "check: $(cat "$work/err")"
# The read-only pair is enough to verify.
env -u CMUX_CEF_R2_WRITE_ACCESS_KEY_ID -u CMUX_CEF_R2_WRITE_SECRET_ACCESS_KEY \
  CMUX_CEF_R2_ACCESS_KEY_ID=r CMUX_CEF_R2_SECRET_ACCESS_KEY=rs \
  bash "$publish" --verify-manifest "$work/m.json" 2>"$work/err" || fail "verify: $(cat "$work/err")"
[[ "$(grep -c '==> verified cef/' "$work/err")" -eq 4 ]] || fail "verify read back: $(cat "$work/err")"

# An R2 object whose bytes changed fails verification.
x86_key="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["x86_64"]["debug_r2_key"])' "$work/m.json")"
printf 'other bytes\n' > "$work/s3/cmux-cef/$x86_key"
bash "$publish" --verify-manifest "$work/m.json" 2>"$work/err" && fail "a changed R2 object verified"
grep -q "read back as" "$work/err" || fail "changed object message: $(cat "$work/err")"
# A missing one too.
rm "$work/s3/cmux-cef/$x86_key"
bash "$publish" --verify-manifest "$work/m.json" 2>"$work/err" && fail "a missing R2 object verified"
grep -q "HTTP 404" "$work/err" || fail "missing object message: $(cat "$work/err")"

# check refuses a key that is not the content address, a staging object, a lost arch.
mutate() { # <python statement on m> <expected message>
  python3 -I - "$work/m.json" "$work/bad.json" "$1" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
exec(sys.argv[3])
json.dump(m, open(sys.argv[2], "w"))
PY
  python3 -I "$pin" check --manifest "$work/bad.json" 2>"$work/err" && fail "check passed after: $1"
  grep -q "$2" "$work/err" || fail "after $1: $(cat "$work/err")"
}
mutate 'm["x86_64"]["r2_key"] = "cef/0/x.tar.xz"' "x86_64 r2_key"
mutate 'm["staging"] = {"store_expires": "2026-11-09"}' "staging pin"
mutate 'del m["x86_64"]' "no x86_64 artifact"
mutate 'del m["debug_r2_key"]' "arm64 debug_r2_key"
mutate 'm["cmux_cef_api_version"] = 29' "needs >= $floor"
mutate 'm["x86_64"]["fork_ref"] = "0" * 40' "one fork commit"
mutate 'm["version"] = "cef-stage-x"' "release tag"

echo "cef-release-pin: ok"
