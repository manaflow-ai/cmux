#!/usr/bin/env bash
# A reload cannot authorize deletion of another session's build. Verify its
# printed reminder never offers a kill/delete recipe, including the current tag.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

# Execute the actual reminder and its helpers without starting a build.
for function_name in tagged_derived_data_path tag_build_cleanup_paths print_tag_cleanup_commands tagged_app_is_running print_tag_cleanup_reminder; do
  eval "$(awk -v name="$function_name" '$0 == name "() {" { on = 1 } on { print } on && /^}/ { exit }' "$ROOT/scripts/reload.sh")"
done
declare -F print_tag_cleanup_reminder >/dev/null || fail "cleanup reminder is missing"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fixture_home="$tmp/home with spaces"
derived="$fixture_home/Library/Developer/Xcode/DerivedData"
mkdir -p "$derived/cmux-current/Build/Products/Debug" \
  "$derived/cmux-live/Build/Products/Debug" "$derived/cmux-stopped/Build/Products/Debug"

# Keep discovery and process observations isolated to this test. Exit 2 models a
# process probe that failed, which must never become permission to delete.
find() {
  if [[ "$1" == "$derived" ]]; then
    printf '%s\0' "$derived/cmux-current" "$derived/cmux-live" "$derived/cmux-stopped"
  fi
}
pgrep() {
  [[ "$probe_status" != unknown ]] || return 2
  [[ "$*" == *"cmux DEV live.app/Contents/MacOS/cmux DEV"* ]]
}

for probe_status in known unknown; do
  output="$(HOME="$fixture_home" LC_ALL=C print_tag_cleanup_reminder current "$derived/cmux-current")"
  [[ "$output" == *current* ]] || fail "reminder lost the current tag"
  if [[ "$output" == *'pkill '* || "$output" == *'rm -rf '* || "$output" == *'rm -f '* ]]; then
    fail "$probe_status process state produced a destructive cleanup recipe: $output"
  fi
  [[ "$output" != *"stale tags:"* ]] || fail "a stopped app does not establish that its build is disposable"
done

# The new reminder text must be localized without needing an app binary.
output="$(HOME="$fixture_home" LC_ALL=ja_JP.UTF-8 print_tag_cleanup_reminder current "$derived/cmux-current")"
[[ "$output" == *"ビルド"* ]] || fail "Japanese cleanup reminder was not localized"
[[ "$output" != *'rm -rf '* && "$output" != *'pkill '* ]] || fail "Japanese reminder offered a destructive recipe"
echo "PASS: reload cleanup reminder preserves builds in every process state"
