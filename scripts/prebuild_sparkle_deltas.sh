#!/usr/bin/env bash
# Create generate_appcast's delta files concurrently, before it runs.
#
#   scripts/prebuild_sparkle_deltas.sh <BinaryDelta> <archives-dir> <new-archive.dmg> <max-deltas>
#
# generate_appcast creates each delta in turn (about two minutes apiece for a
# universal nightly) and reuses any delta file that already exists under its
# own name, "<app name><new version>-<old version>.delta" in <archives-dir>.
# This script builds those files in parallel with the same Sparkle release's
# BinaryDelta and the same parameters generate_appcast would pick: format 4
# (the default, which generate_appcast selects for old apps whose Sparkle
# framework version is at least 2041) and default compression. Like
# generate_appcast, it keeps a delta only after applying it to the old app
# succeeds; BinaryDelta apply checks the result against the new tree's hash.
#
# Best effort: it always exits 0. A delta it skips or fails to build is left
# to generate_appcast, which then creates it exactly as before.
set -uo pipefail

if [[ $# -ne 4 ]]; then
  sed -n '2,4p' "$0" >&2
  exit 2
fi
BINARY_DELTA="$1"
ARCHIVES_DIR="$2"
NEW_ARCHIVE="$3"
MAX_DELTAS="$4"

log() { echo "prebuild-deltas: $*"; }

if [[ ! -x "$BINARY_DELTA" ]]; then
  log "BinaryDelta not found at $BINARY_DELTA; generate_appcast will create deltas"
  exit 0
fi
if ! [[ "$MAX_DELTAS" =~ ^[0-9]+$ ]] || [[ "$MAX_DELTAS" -eq 0 ]]; then
  exit 0
fi

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/cmux-prebuild-deltas.XXXXXX")"
mounts=()
cleanup() {
  local mount
  for mount in ${mounts[@]+"${mounts[@]}"}; do
    hdiutil detach "$mount" -quiet >/dev/null 2>&1 || hdiutil detach "$mount" -force -quiet >/dev/null 2>&1 || true
  done
  rm -rf "$work_dir"
}
trap cleanup EXIT

# Copy the one .app at the root of <dmg> to local disk and set APP to the copy.
# generate_appcast diffs local copies too. BinaryDelta walks directories in
# file system order, and a mounted image orders entries differently from the
# runner's disk, so diffing the mount directly yields a different (equally
# valid) delta. Diffing copies reproduces generate_appcast's bytes exactly.
APP=""
copies=0
copy_app() {
  local dmg="$1" mountpoint mounted_app dest
  APP=""
  mountpoint="$(mktemp -d "$work_dir/mount.XXXXXX")"
  if ! hdiutil attach "$dmg" -nobrowse -readonly -noautoopen -mountpoint "$mountpoint" -quiet >/dev/null 2>&1; then
    log "could not mount $(basename "$dmg")"
    return 1
  fi
  mounts+=("$mountpoint")
  mounted_app="$(find "$mountpoint" -maxdepth 1 -name '*.app' -type d -print -quit)"
  if [[ -z "$mounted_app" ]]; then
    return 1
  fi
  copies=$((copies + 1))
  dest="$work_dir/apps/$copies/$(basename "$mounted_app")"
  mkdir -p "$(dirname "$dest")"
  if ! ditto "$mounted_app" "$dest"; then
    log "could not copy the app out of $(basename "$dmg")"
    return 1
  fi
  APP="$dest"
}

plist_value() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null; }

if ! copy_app "$NEW_ARCHIVE"; then
  log "new archive has no app; generate_appcast will create deltas"
  exit 0
fi
new_app="$APP"
new_version="$(plist_value "$new_app/Contents/Info.plist" CFBundleVersion)"
if ! [[ "$new_version" =~ ^[0-9]+$ ]]; then
  log "new build version '${new_version}' is not numeric; generate_appcast will create deltas"
  exit 0
fi
app_base_name="$(basename "$new_app" .app)"

# Older builds, newest first, exactly the ones generate_appcast will diff from.
candidates=()
for dmg in "$ARCHIVES_DIR"/*.dmg; do
  [[ -f "$dmg" && "$dmg" != "$NEW_ARCHIVE" ]] || continue
  [[ "$(basename "$dmg")" != "$(basename "$NEW_ARCHIVE")" ]] || continue
  copy_app "$dmg" || continue
  old_version="$(plist_value "$APP/Contents/Info.plist" CFBundleVersion)"
  if ! [[ "$old_version" =~ ^[0-9]+$ ]] || [[ "$old_version" -ge "$new_version" ]]; then
    continue
  fi
  candidates+=("$old_version $APP")
done
if [[ "${#candidates[@]}" -eq 0 ]]; then
  log "no older builds to diff from"
  exit 0
fi

pids=()
outputs=()
started="$(date +%s)"
while IFS= read -r entry; do
  old_version="${entry%% *}"
  old_app="${entry#* }"
  framework_version="$(plist_value "$old_app/Contents/Frameworks/Sparkle.framework/Resources/Info.plist" CFBundleVersion)"
  if ! [[ "$framework_version" =~ ^[0-9]+$ ]] || [[ "$framework_version" -lt 2041 ]]; then
    log "build $old_version ships Sparkle framework '${framework_version}'; leaving its delta to generate_appcast"
    continue
  fi
  delta="$ARCHIVES_DIR/${app_base_name}${new_version}-${old_version}.delta"
  if [[ -e "$delta" ]]; then
    continue
  fi
  (
    staging="$work_dir/${new_version}-${old_version}.delta"
    applied="$work_dir/applied-${old_version}/$(basename "$new_app")"
    mkdir -p "$(dirname "$applied")"
    "$BINARY_DELTA" create "$old_app" "$new_app" "$staging" || exit 1
    "$BINARY_DELTA" apply "$old_app" "$applied" "$staging" || exit 1
    rm -rf "$(dirname "$applied")"
    mv "$staging" "$delta"
  ) &
  pids+=("$!")
  outputs+=("$delta")
done < <(printf '%s\n' "${candidates[@]}" | sort -rn | awk '!seen[$1]++' | head -n "$MAX_DELTAS")

built=0
for index in ${pids[@]+"${!pids[@]}"}; do
  if wait "${pids[$index]}"; then
    built=$((built + 1))
    log "built $(basename "${outputs[$index]}")"
  else
    rm -f "${outputs[$index]}"
    log "failed to build $(basename "${outputs[$index]}"); generate_appcast will create it"
  fi
done
log "built ${built} delta(s) in $(( $(date +%s) - started ))s"
exit 0
