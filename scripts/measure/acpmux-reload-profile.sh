#!/usr/bin/env bash
# A one-line acpmux edit's rebuild in reload-build.yml's acpmux step, per Cargo profile, on one
# warm worker. Run alone on a worker:
#   cmux-ci run --class exclusive --script scripts/measure/acpmux-reload-profile.sh --ref SHA \
#     [--arg=n=3] [--arg=profiles=release,devbuild] --timeout 7200
# Each profile builds acpmux once through scripts/cmux-next/build-acpmux.sh (cold, timed), then n
# rounds append one line to an acpmux source file and rebuild with each profile in turn. Every
# build uses a fresh commit-addressed cache root, so build-acpmux.sh runs Cargo against the
# profile's own warm target dir, as a tagged reload on a warm fleet slot does.
# Profiles: release (the shipped profile) and devbuild (tools/devbuild's overrides, which
# reload-build.yml sets for a tagged reload).
# Output: RELOAD-PROFILE-SAMPLE lines per build, then RELOAD-PROFILE profile=P cold_s=C edit_p50_s=M
# edit_min_s=A edit_max_s=B n=N. Exit 1 when a build failed.
set -euo pipefail
n=3 profiles=release,devbuild
for kv in "$@"; do
  case "$kv" in
    n=*) n="${kv#*=}" ;;
    profiles=*) profiles="${kv#*=}" ;;
    *) echo "error: unknown argument $kv" >&2; exit 2 ;;
  esac
done
[[ "$n" =~ ^[1-9][0-9]?$ ]] || { echo "error: n is 1 to 99" >&2; exit 2; }
root="$(git rev-parse --show-toplevel)"
cd "$root"
export CI=1
git submodule update --init --depth 1 ghostty-next
work="$root/.build/acpmux-reload-profile"
rm -rf "$work"
mkdir -p "$work"
leaf="cmux-tui/crates/acpmux/src/harness_icon_set.rs"
[[ -f "$leaf" ]] || { echo "error: $leaf is missing at this ref" >&2; exit 2; }
cp "$leaf" "$work/leaf.orig"
trap 'cp "$work/leaf.orig" "$leaf"' EXIT
echo "RELOAD-PROFILE-MACHINE host=$(scutil --get ComputerName 2>/dev/null || hostname) cores=$(sysctl -n hw.ncpu) rev=$(git rev-parse HEAD) load=\"$(sysctl -n vm.loadavg)\""

# build PROFILE LABEL: one build-acpmux.sh run into a fresh cache root; prints its seconds.
build() {
  local profile="$1" label="$2" started rc=0
  local -a env_args=(env -u CARGO_PROFILE_RELEASE_LTO -u CARGO_PROFILE_RELEASE_CODEGEN_UNITS -u CARGO_PROFILE_RELEASE_INCREMENTAL)
  if [[ "$profile" == devbuild ]]; then
    env_args+=(CARGO_PROFILE_RELEASE_LTO=off CARGO_PROFILE_RELEASE_CODEGEN_UNITS=16 CARGO_PROFILE_RELEASE_INCREMENTAL=true)
  fi
  started=$(python3 -c 'import time; print(time.monotonic())')
  "${env_args[@]}" CMUX_NEXT_ACPMUX_CACHE="$work/cache-$profile-$label" \
    scripts/cmux-next/build-acpmux.sh --output "$work/out-$profile-$label/acpmux" >"$work/$profile-$label.log" 2>&1 || rc=$?
  python3 -c 'import sys, time; print(f"{time.monotonic() - float(sys.argv[1]):.1f}")' "$started"
  if (( rc != 0 )); then
    tail -n 30 "$work/$profile-$label.log" | sed "s/^/RELOAD-PROFILE-LOG $profile /" >&2
    return 1
  fi
}

IFS=, read -r -a profile_list <<<"$profiles"
for profile in "${profile_list[@]}"; do
  [[ "$profile" == release || "$profile" == devbuild ]] || { echo "error: profile $profile is release or devbuild" >&2; exit 2; }
done
status=0
declare -a cold=() edits=()
for i in "${!profile_list[@]}"; do
  profile="${profile_list[$i]}"
  s="$(build "$profile" cold)" || status=1
  cold[$i]="$s"
  edits[$i]=""
  echo "RELOAD-PROFILE-SAMPLE profile=$profile build=cold seconds=$s"
done
for round in $(seq 1 "$n"); do
  cp "$work/leaf.orig" "$leaf"
  printf 'const _RELOAD_PROFILE_MARKER: u32 = %d;\n' "$round" >>"$leaf"
  for i in "${!profile_list[@]}"; do
    profile="${profile_list[$i]}"
    s="$(build "$profile" "edit-$round")" || status=1
    edits[$i]="${edits[$i]} $s"
    echo "RELOAD-PROFILE-SAMPLE profile=$profile build=edit-$round seconds=$s"
  done
done
for i in "${!profile_list[@]}"; do
  python3 - "${profile_list[$i]}" "${cold[$i]}" ${edits[$i]} <<'PY'
import statistics, sys
profile, cold, *edits = sys.argv[1:]
xs = [float(x) for x in edits]
print(f"RELOAD-PROFILE profile={profile} cold_s={cold} edit_p50_s={statistics.median(xs):.1f} "
      f"edit_min_s={min(xs):.1f} edit_max_s={max(xs):.1f} n={len(xs)}")
PY
done
exit "$status"
