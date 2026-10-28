#!/usr/bin/env bash
# The remote shim (Packages/macOS/CmuxNext/ChromiumHost/client) has the
# in-process shim's ABI: it exports every cmux_shim_ function of cmux_cef_shim.h and no other,
# with the header's cmux_shim_abi_id, and its generated exports never wait. Then
# tests/remote_shim_test.cpp drives it against a fake host on a socket pair.
#
# Builds the client the way build-chromium-host.sh does (no CEF needed), as a .dylib on a Mac
# and a .so elsewhere. With CMUX_REAL_SHIM=<libcmux_cef_shim.dylib>, also compares its
# cmux_shim_ symbols with the real shim's (nm -gU).
#
# The `local` exports with a function-pointer argument that no client file defines yet (each
# waits for its task's hand-written client code) are the only ones allowed to be missing; the
# test names them.
#
# Not a CI test (p01-process section 4, rule 4): agents that change the client, the header or
# the ops run it themselves.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
header="$root/Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/Shim/cmux_cef_shim.h"
host="$root/Packages/macOS/CmuxNext/ChromiumHost"
ops="$root/plans/cmux-next/chromium-host-ops.json"
work="$(mktemp -d "${TMPDIR:-/tmp}/remote-shim-abi.XXXXXX")"
trap 'rm -rf "$work"' EXIT
# shellcheck source=../lib/cxx.sh
source "$root/scripts/cmux-next/lib/cxx.sh"
fail() {
  echo "remote-shim-abi: $*" >&2
  exit 1
}

inc="$host/client/generated/remote_shim.inc"
[[ -f "$inc" ]] || fail "no $inc: run python3 scripts/cmux-next/gen-chromium-host-wire.py"
if command -v shasum >/dev/null 2>&1; then
  abi="$(shasum -a 256 "$header" | awk '{print $1}')"
else
  abi="$(sha256sum "$header" | awk '{print $1}')"
fi
# Current: the generator, run on this header and ops into a scratch root, writes the same file.
fresh="$work/generated"
mkdir -p "$fresh/$(dirname "${header#"$root/"}")" "$fresh/$(dirname "${ops#"$root/"}")"
cp "$header" "$fresh/${header#"$root/"}"
cp "$ops" "$fresh/${ops#"$root/"}"
python3 "$root/scripts/cmux-next/gen-chromium-host-wire.py" --root "$fresh" >/dev/null
cmp -s "$fresh/${inc#"$root/"}" "$inc" || fail "$inc is stale: run python3 scripts/cmux-next/gen-chromium-host-wire.py"
# No blocking primitive in the generated client: the acceptance's pattern, as written.
if grep -rnE 'wait|cond_|semaphore' "$host/client/generated"; then
  fail "the generated client waits"
fi

sources=("$host"/client/*.mm)
flags=(-std=c++20 -Wall -Wextra -Werror -O1 -pthread -I"$(dirname "$header")" -I"$root/Packages/macOS/CmuxNext/CEFShim/src"
  -I"$host/src" -I"$host/client")
if [[ "$(uname)" == Darwin ]]; then
  lib="$work/libcmux_cef_shim_remote.dylib"
  "${cxx[@]}" "${flags[@]}" -fvisibility=hidden -dynamiclib -install_name @rpath/libcmux_cef_shim_remote.dylib \
    -o "$lib" "${sources[@]}" "$host/src/chromium_host_control.cc" -lobjc
  symbols() { nm -gU "$1" | awk '{print $3}' | sed 's/^_//'; }
else
  lib="$work/libcmux_cef_shim_remote.so"
  "${cxx[@]}" "${flags[@]}" -fvisibility=hidden -fPIC -shared -o "$lib" \
    -x c++ "${sources[@]}" -x none "$host/src/chromium_host_control.cc"
  symbols() { nm -D --defined-only "$1" | awk '{print $3}'; }
fi

symbols "$lib" | grep '^cmux_shim_' | sort -u > "$work/remote"
# Every CMUX_SHIM_EXPORT declaration, comments and #define lines removed first.
python3 -I - "$header" > "$work/header" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
text = re.sub(r"/\*.*?\*/|//[^\n]*", "", text, flags=re.S)
text = "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("#"))
names = re.findall(r"CMUX_SHIM_EXPORT[^;{]*?\b(cmux_shim_\w+)\s*\(", text)
print("\n".join(sorted(set(names))))
PY
expected="$(wc -l < "$work/header" | tr -d ' ')"
(( expected > 0 )) || fail "no exports parsed from $header"
# The optional exports (fork API 29, not in the header yet) may be present; a local
# function-pointer export no client file defines may be absent.
python3 -I - "$ops" "$host"/client/*.mm > "$work/allowed" <<'PY'
import json, re, sys
ops = json.load(open(sys.argv[1]))
defined = set()
for path in sys.argv[2:]:
    defined.update(re.findall(r"CMUX_SHIM_EXPORT[^;{]*?\b(cmux_shim_\w+)\s*\(", open(path).read()))
for e in ops.get("optional_exports", []):
    print("extra", e["name"])
for e in ops["exports"]:
    if e["class"] == "local" and any(a.get("function_pointer") for a in e["args"]) and e["name"] not in defined:
        print("missing", e["name"])
PY
missing="$(comm -23 "$work/header" "$work/remote")"
extra="$(comm -13 "$work/header" "$work/remote")"
pending=()
while IFS= read -r name; do
  [[ -n "$name" ]] || continue
  grep -qx "missing $name" "$work/allowed" || fail "missing export $name"
  pending+=("$name")
done <<< "$missing"
while IFS= read -r name; do
  [[ -n "$name" ]] || continue
  grep -qx "extra $name" "$work/allowed" || fail "export $name is not in cmux_cef_shim.h"
done <<< "$extra"
have="$(comm -12 "$work/header" "$work/remote" | wc -l | tr -d ' ')"
optional="$(comm -13 "$work/header" "$work/remote" | wc -l | tr -d ' ')"
echo "remote-shim-abi: $have of the header's $expected cmux_shim_ exports, plus $optional optional_exports"
if (( ${#pending[@]} )); then
  echo "remote-shim-abi: ${#pending[@]} local exports wait for their hand-written client code: ${pending[*]}"
fi

if [[ -n "${CMUX_REAL_SHIM:-}" ]]; then
  symbols "$CMUX_REAL_SHIM" | grep '^cmux_shim_' | sort -u > "$work/real"
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    grep -qx "missing $name" "$work/allowed" || fail "the real shim exports $name and the remote shim does not"
  done <<< "$(comm -23 "$work/real" "$work/remote")"
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    grep -qx "extra $name" "$work/allowed" || fail "the remote shim exports $name and the real shim does not"
  done <<< "$(comm -13 "$work/real" "$work/remote")"
  echo "remote-shim-abi: the same cmux_shim_ exports as $CMUX_REAL_SHIM"
fi

test_libs=(-pthread)
# remote_shim.mm hands the chooser pushes to remote_shim_choosers.mm (task 228).
"${cxx[@]}" "${flags[@]}" -DCMUX_TEST_ABI_ID="\"$abi\"" -o "$work/remote-shim-test" \
  "$host/tests/remote_shim_test.cpp" -x c++ "$host/client/remote_shim_choosers.mm" -x none \
  "$host/src/chromium_host_control.cc" "${test_libs[@]}"
"$work/remote-shim-test"
