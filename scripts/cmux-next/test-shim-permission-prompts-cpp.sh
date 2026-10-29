#!/usr/bin/env bash
# Compiles which Chromium permission requests the host asks about
# (CEFShim/src/permission_prompt_policy.h, no CEF needed) and runs its cases.
# Small: one clang++ call.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/shim-permission-prompts.XXXXXX")"
trap 'rm -rf "$work"' EXIT
# shellcheck source=lib/cxx.sh
source "$root/scripts/cmux-next/lib/cxx.sh"
"${cxx[@]}" -std=c++17 -Wall -Werror -O1 \
  -o "$work/test" "$root/Packages/macOS/CmuxNext/CEFShim/tests/permission_prompt_policy_test.cpp"
"$work/test"
# The shim reads the feature by its Chromium name; the app passes the name its feature file declares.
if ! grep -q '"chromium_feature": "CmuxPermissionPromptsFromData"' \
  "$root/schemas/features/features.d/chromiumPermissionPromptsFromData.json"; then
  echo "FAIL: chromiumPermissionPromptsFromData.json does not declare CmuxPermissionPromptsFromData" >&2
  exit 1
fi
# Screen sharing keeps Chromium's desktop media path (DisplayMediaAccessHandler's picker):
# the shim answers no media access request, so no Allow can grant the whole desktop.
if grep -q 'OnRequestMediaAccessPermission' "$root/Packages/macOS/CmuxNext/CEFShim/src/shim_permissions.mm"; then
  echo "FAIL: shim_permissions.mm answers media access requests (screen sharing must keep Chromium's picker path)" >&2
  exit 1
fi
