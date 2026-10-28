#!/usr/bin/env bash
# Compiles the Chromium Host's dispatcher (ChromiumHost/src/host_dispatch.mm,
# host_mirror.mm and host_text_input.mm, no AppKit in them, so as C++) against
# the generated cases gen-chromium-host-wire.py writes for this header and ops
# JSON (into a scratch root, never the checkout), and runs:
#   host_dispatch_test.cpp  the dispatcher alone, frame by frame, the App
#                           Nap activity it holds while a page shows
#                           (host_page_activity.h) and
#                           the helper ends it forwards (host_helper_exits.h)
#   host_text_input_test.cpp  the text input pushes, alone and through the
#                           dispatcher
#   host_resize_test.cpp    a page's resize and its fence (host_resize.h),
#                           alone and through the dispatcher
#   host_wheel_ack_test.cpp the wheel acks, alone and through the dispatcher
#   host_provider_link_test.cpp  agent CDP straight from the browser host:
#                           the relays alone, through the dispatcher, and the
#                           link's transport against a fake browser host
#                           (host_provider_link.{h,mm})
#   host_mirror_test.cpp    the dispatcher and the real remote shim
#                           (ChromiumHost/client, built as a shared library
#                           from the committed client/generated/remote_shim.inc)
#                           on a socket pair: what cmux's shim reads
#   host_choosers_test.cpp  the chooser payloads (host_choosers.h), then the
#                           dispatcher and the real remote shim on a socket
#                           pair: the color, device and screen-share handlers
#                           end to end
#   host_page_resource_test.cpp  the same pair: cmux-page:// schemes as preinit
#                           ops with their verdicts, PAGE_RESOURCE and a 10 MB
#                           answer in shared memory
# Every test links a fake of the shim: the test's own functions, and a weak
# zero stub for each other export of cmux_cef_shim.h (the generated cases call
# them all). First, the sources compile alone with -Werror against the same
# generated file, as build-chromium-host.sh compiles them. No CEF; runs on
# Linux and macOS.
#
# Not in CI (lead, 2026-10-23: no new CI tests); run it when you change
# host_dispatch.{h,mm}, host_mirror.{h,mm}, host_text_input.{h,mm}, host_resize.h, host_wheel_ack.h,
# host_page_activity.h, host_choosers.h, host_helper_exits.{h,cc}, the generator's host output or the ops JSON.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/chromium-host-dispatch.XXXXXX")"
trap 'rm -rf "$work"' EXIT
# shellcheck source=../lib/cxx.sh
source "$root/scripts/cmux-next/lib/cxx.sh"
host="$root/Packages/macOS/CmuxNext/ChromiumHost"
header="$root/Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/Shim/cmux_cef_shim.h"
ops="$root/plans/cmux-next/chromium-host-ops.json"
shim_header="$(dirname "$header")"

# host_mirror.h's kExtActionIconPixels is CEFExtensionAction.iconPixels
# (OmnibarStyle.buttonSize * 2), the only icon_px cmux reads ext_actions at.
grep -q 'iconPixels: Int32 { Int32((OmnibarStyle.buttonSize \* 2).rounded()) }' \
  "$root/Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/CEFExtensionAction.swift" ||
  { echo "FAIL: CEFExtensionAction.iconPixels is no longer OmnibarStyle.buttonSize * 2" >&2; exit 1; }
button="$(sed -n 's/.*static var buttonSize: CGFloat { \([0-9.]*\) }.*/\1/p' \
  "$root/Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/UI/OmnibarStyle.swift")"
pixels="$(python3 -c 'import sys; print(round(float(sys.argv[1]) * 2))' "$button")"
grep -q "kExtActionIconPixels = $pixels;" "$host/src/host_mirror.h" ||
  { echo "FAIL: kExtActionIconPixels is not CEFExtensionAction.iconPixels ($pixels)" >&2; exit 1; }

# The generator's output for this header and ops, in a scratch root.
gen="$work/root"
mkdir -p "$gen/$(dirname "${header#"$root/"}")" "$gen/$(dirname "${ops#"$root/"}")"
cp "$header" "$gen/${header#"$root/"}"
cp "$ops" "$gen/${ops#"$root/"}"
python3 "$root/scripts/cmux-next/gen-chromium-host-wire.py" --root "$gen" >/dev/null
# The dispatcher includes generated/host_dispatch.inc next to itself.
mkdir -p "$work/src/generated"
cp "$host"/src/*.h "$host"/src/*.mm "$host"/src/*.cc "$work/src/"
cp "$gen/Packages/macOS/CmuxNext/ChromiumHost/src/generated/host_dispatch.inc" "$work/src/generated/"

# host_provider_link.h reads DevTools ids with the shim's scanner (CEFShim/src/devtools_message_id.h).
flags=(-std=c++20 -Wall -Wextra -Werror -pthread -I"$work/src" -I"$shim_header" -I"$root/Packages/macOS/CmuxNext/CEFShim/src")
for src in host_dispatch.mm host_mirror.mm host_text_input.mm host_helper_exits.cc; do
  "${cxx[@]}" "${flags[@]}" -fsyntax-only -x c++ "$work/src/$src"
done

# A weak stub for every export: a test's own definition replaces it.
python3 "$root/scripts/cmux-next/gen-chromium-host-wire.py" --root "$gen" --dump-header > "$work/header.json"
python3 -I - "$work/header.json" > "$work/shim_stubs.cpp" <<'PY'
import json, sys
exports = json.load(open(sys.argv[1]))["exports"]
print('#include "cmux_cef_shim.h"')
print('extern "C" {')
for e in exports:
    args = ", ".join(a["type"] for a in e["args"]) or "void"
    body = "" if e["returns"] == "void" else " return {};"
    print(f'__attribute__((weak)) {e["returns"]} {e["name"]}({args}) {{{body} }}')
print("}")
PY

sources=("$work/src/host_dispatch.mm" "$work/src/host_mirror.mm" "$work/src/host_text_input.mm"
  "$work/src/host_helper_exits.cc" "$work/shim_stubs.cpp")
"${cxx[@]}" "${flags[@]}" -O1 -o "$work/host_dispatch_test" "$host/tests/host_dispatch_test.cpp" \
  -x c++ "${sources[@]}" -x none "$work/src/chromium_host_control.cc"
"$work/host_dispatch_test"
"${cxx[@]}" "${flags[@]}" -O1 -o "$work/host_text_input_test" "$host/tests/host_text_input_test.cpp" \
  -x c++ "${sources[@]}" -x none "$work/src/chromium_host_control.cc"
"$work/host_text_input_test"
"${cxx[@]}" "${flags[@]}" -O1 -o "$work/host_resize_test" "$host/tests/host_resize_test.cpp" \
  -x c++ "${sources[@]}" -x none "$work/src/chromium_host_control.cc"
"$work/host_resize_test"
"${cxx[@]}" "${flags[@]}" -O1 -o "$work/host_wheel_ack_test" "$host/tests/host_wheel_ack_test.cpp" \
  -x c++ "${sources[@]}" -x none "$work/src/chromium_host_control.cc"
"$work/host_wheel_ack_test"
"${cxx[@]}" "${flags[@]}" -O1 -o "$work/host_provider_link_test" "$host/tests/host_provider_link_test.cpp" \
  -x c++ "${sources[@]}" "$work/src/host_provider_link.mm" -x none "$work/src/chromium_host_control.cc"
"$work/host_provider_link_test"

# The remote shim, as remote-shim-abi.test.sh builds it (from the committed generated client).
client_flags=(-std=c++20 -Wall -Wextra -Werror -O1 -pthread -I"$shim_header" -I"$root/Packages/macOS/CmuxNext/CEFShim/src"
  -I"$host/src" -I"$host/client")
test_libs=()
if [[ "$(uname)" == Darwin ]]; then
  client="$work/libcmux_cef_shim_remote.dylib"
  "${cxx[@]}" "${client_flags[@]}" -fvisibility=hidden -dynamiclib -install_name @rpath/libcmux_cef_shim_remote.dylib \
    -o "$client" "$host"/client/*.mm "$host/src/chromium_host_control.cc" -lobjc
else
  client="$work/libcmux_cef_shim_remote.so"
  "${cxx[@]}" "${client_flags[@]}" -fvisibility=hidden -fPIC -shared -o "$client" \
    -x c++ "$host"/client/*.mm -x none "$host/src/chromium_host_control.cc"
  test_libs+=(-ldl)
fi
"${cxx[@]}" "${flags[@]}" -I"$host/client" -O1 -DCMUX_REMOTE_SHIM_PATH="\"$client\"" -o "$work/host_mirror_test" \
  "$host/tests/host_mirror_test.cpp" -x c++ "${sources[@]}" -x none "$work/src/chromium_host_control.cc" \
  ${test_libs[@]+"${test_libs[@]}"}
"$work/host_mirror_test"
"${cxx[@]}" "${flags[@]}" -I"$host/client" -O1 -DCMUX_REMOTE_SHIM_PATH="\"$client\"" -o "$work/host_choosers_test" \
  "$host/tests/host_choosers_test.cpp" -x c++ "${sources[@]}" -x none "$work/src/chromium_host_control.cc" \
  ${test_libs[@]+"${test_libs[@]}"}
"$work/host_choosers_test"
"${cxx[@]}" "${flags[@]}" -I"$host/client" -O1 -DCMUX_REMOTE_SHIM_PATH="\"$client\"" -o "$work/host_page_resource_test" \
  "$host/tests/host_page_resource_test.cpp" -x c++ "${sources[@]}" -x none "$work/src/chromium_host_control.cc" \
  ${test_libs[@]+"${test_libs[@]}"}
"$work/host_page_resource_test"
