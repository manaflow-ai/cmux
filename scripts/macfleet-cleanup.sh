#!/usr/bin/env bash
set -euo pipefail

now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
min_free_gib="${CMUX_MACFLEET_MIN_FREE_GIB:-12}"
derived_max_age_minutes="${CMUX_MACFLEET_DERIVED_MAX_AGE_MINUTES:-360}"
tmp_max_age_minutes="${CMUX_MACFLEET_TMP_MAX_AGE_MINUTES:-180}"
postgres_max_age_minutes="${CMUX_MACFLEET_POSTGRES_MAX_AGE_MINUTES:-180}"
diag_max_age_days="${CMUX_MACFLEET_DIAG_MAX_AGE_DAYS:-3}"

log() {
  printf '[%s] %s\n' "$now" "$*"
}

free_gib() {
  df -g / | awk 'NR == 2 { print $4 }'
}

has_active_builds() {
  pgrep -f 'xcodebuild|swift-frontend|clang .*DerivedData|zig build' >/dev/null 2>&1
}

rm_old_children() {
  local dir="$1"
  local minutes="$2"
  [ -d "$dir" ] || return 0
  find "$dir" -mindepth 1 -maxdepth 1 -mmin +"$minutes" -print -exec rm -rf {} + 2>/dev/null || true
}

truncate_large_logs() {
  local pattern="$1"
  for f in $pattern; do
    [ -f "$f" ] || continue
    if [ "$(stat -f %z "$f" 2>/dev/null || echo 0)" -gt $((50 * 1024 * 1024)) ]; then
      : > "$f"
      log "truncated $f"
    fi
  done
}

log "cleanup start host=$(hostname) free_gib=$(free_gib)"

active=0
if has_active_builds; then
  active=1
  log "active build detected, skipping aggressive DerivedData cleanup"
fi

for home in /Users/cmuxvnc /Users/cmuxvnc[2-9]*; do
  [ -d "$home" ] || continue
  user="$(basename "$home")"

  rm_old_children "$home/actions-runner/_diag" "$((diag_max_age_days * 24 * 60))"
  rm_old_children "$home/actions-runner/_work/_temp" "$tmp_max_age_minutes"
  rm_old_children "$home/Library/Developer/Xcode/Archives" "$((7 * 24 * 60))"
  rm_old_children "$home/Library/Developer/Xcode/Products" "$((24 * 60))"

  if [ "$active" -eq 0 ]; then
    rm_old_children "$home/cmux-ci/DerivedData" "$derived_max_age_minutes"
    rm_old_children "$home/Library/Developer/Xcode/DerivedData" "$derived_max_age_minutes"
  fi

  # Keep the persistent checkout and SwiftPM package cache, but drop transient
  # build artifacts that grow per run.
  rm_old_children "$home/cmux-ci/tmp" "$tmp_max_age_minutes"
  find "$home/cmux-ci" -maxdepth 1 -type d -name 'postgres-*' -mmin +"$postgres_max_age_minutes" -print -exec rm -rf {} + 2>/dev/null || true
  log "checked $user"
done

if [ "$active" -eq 0 ] && [ "$(free_gib)" -lt "$min_free_gib" ]; then
  log "free space below ${min_free_gib}GiB, pruning all macfleet DerivedData"
  for home in /Users/cmuxvnc /Users/cmuxvnc[2-9]*; do
    [ -d "$home" ] || continue
    rm -rf "$home/cmux-ci/DerivedData"/* "$home/Library/Developer/Xcode/DerivedData"/* 2>/dev/null || true
  done
fi

find /tmp /private/tmp -maxdepth 1 \( -name 'cmux-*' -o -name 'macfleet-ci-*' -o -name 'sat15-*' -o -name 'smoke-*' \) -mmin +"$tmp_max_age_minutes" -print -exec rm -rf {} + 2>/dev/null || true
truncate_large_logs '/var/log/cmux-actions-runner-*.log'
truncate_large_logs '/var/log/cmux-actions-runner-*.err'

log "cleanup done free_gib=$(free_gib)"
