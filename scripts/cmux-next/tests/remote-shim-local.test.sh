#!/usr/bin/env bash
# The remote shim's local class (task p01-process-014b), with no build:
#  1. through the generator (gen-chromium-host-wire.py): --check-ops passes
#     (it refuses a function-pointer argument outside local/policy and a
#     local/policy export with no reason); the generated client, written fresh
#     into a temporary tree, mentions no local function-pointer export (no
#     marshaller); --list-missing names none of them (each is defined by hand
#     in ChromiumHost/client);
#  2. client/remote_shim_local.mm against a fake transport
#     (ChromiumHost/tests/remote_shim_local_test.cpp): one C++ compiler call.
# No CI job runs it (lead, 2026-10-23: no new CI tests); whoever changes the
# local class or a callback export runs it.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
gen="$root/scripts/cmux-next/gen-chromium-host-wire.py"
host="$root/Packages/macOS/CmuxNext/ChromiumHost"
shimh=Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/Shim/cmux_cef_shim.h
ops=plans/cmux-next/chromium-host-ops.json
client_inc=Packages/macOS/CmuxNext/ChromiumHost/client/generated/remote_shim.inc
fail() { echo "FAIL: $*" >&2; exit 1; }

work="$(mktemp -d "${TMPDIR:-/tmp}/remote-shim-local.XXXXXX")"
trap 'rm -rf "$work"' EXIT

python3 "$gen" --check-ops >/dev/null

# The local exports with a function-pointer argument (wire kind F), from the
# generator's own header parse and the ops JSON's classes.
python3 "$gen" --dump-header >"$work/header.json"
python3 -I - "$work/header.json" "$root/$ops" >"$work/local" <<'PY'
import json, sys
header = json.load(open(sys.argv[1]))
classes = {e["name"]: e["class"] for e in json.load(open(sys.argv[2]))["exports"]}
for e in header["exports"]:
    if "F" in e["wire"] and classes.get(e["name"]) == "local":
        print(e["name"])
PY
want="cmux_shim_browser_text_input_watch cmux_shim_initialize cmux_shim_password_reveal cmux_shim_post_user_input_task cmux_shim_set_drag_source_handler"
got="$(sort "$work/local" | tr '\n' ' ' | sed 's/ $//')"
[[ "$got" == "$want" ]] || fail "local function-pointer exports: '$got', expected '$want'"

# A fresh generated client: generated from the header and ops JSON alone, so
# it does not depend on a committed or stale remote_shim.inc.
mkdir -p "$work/tree/$(dirname "$shimh")" "$work/tree/$(dirname "$ops")"
cp "$root/$shimh" "$work/tree/$shimh"
cp "$root/$ops" "$work/tree/$ops"
python3 "$gen" --root "$work/tree" >/dev/null
[[ -s "$work/tree/$client_inc" ]] || fail "the generator wrote no $client_inc"
python3 "$gen" --list-missing >"$work/missing"
while read -r name; do
  ! grep -qE "\\b$name\\b" "$work/tree/$client_inc" || fail "$name: local but the generated client marshals it"
  ! grep -qE "^$name"$'\t' "$work/missing" || fail "$name: local but not defined by hand in ChromiumHost/client"
done <"$work/local"
echo "local function-pointer exports: $(wc -l <"$work/local" | tr -d ' '), hand-written, none in the generated client"

# shellcheck source=../lib/cxx.sh
source "$root/scripts/cmux-next/lib/cxx.sh"
"${cxx[@]}" -std=c++17 -Wall -Wextra -Werror -O1 -pthread -I"$root/$(dirname "$shimh")" \
  -o "$work/test" "$host/tests/remote_shim_local_test.cpp" -x c++ "$host/client/remote_shim_local.mm"
"$work/test"
