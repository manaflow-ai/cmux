#!/usr/bin/env bash
set -euo pipefail

now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
min_free_gib="${CMUX_MACFLEET_MIN_FREE_GIB:-12}"
tart_min_free_gib="${CMUX_MACFLEET_TART_MIN_FREE_GIB:-24}"
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

prune_stopped_orchard_tart_vms() {
  [ "$(id -u)" -eq 0 ] || return 0
  [ "$(free_gib)" -lt "$tart_min_free_gib" ] || return 0
  [ -d /Users/admin/.tart ] || return 0

  local tart_bin=""
  for candidate in /opt/homebrew/bin/tart /usr/local/bin/tart; do
    if [ -x "$candidate" ]; then
      tart_bin="$candidate"
      break
    fi
  done
  [ -n "$tart_bin" ] || return 0

  log "free space below ${tart_min_free_gib}GiB, pruning stopped orchard Tart VMs"
  { sudo -H -u admin "$tart_bin" list 2>/dev/null || true; } \
    | awk '$1 == "local" && $2 ~ /^orchard-user-/ && $NF == "stopped" { print $2 }' \
    | while IFS= read -r vm; do
        [ -n "$vm" ] || continue
        log "deleting Tart VM $vm"
        sudo -H -u admin "$tart_bin" delete "$vm" >/dev/null 2>&1 || true
      done
}

rm_old_children() {
  local dir="$1"
  local minutes="$2"
  [ -d "$dir" ] || return 0
  [ ! -L "$dir" ] || {
    log "skipping symlinked directory $dir"
    return 0
  }
  find "$dir" -mindepth 1 -maxdepth 1 -mmin +"$minutes" -print -exec rm -rf {} + 2>/dev/null || true
}

purge_children() {
  local dir="$1"
  [ -d "$dir" ] || return 0
  [ ! -L "$dir" ] || {
    log "skipping symlinked directory $dir"
    return 0
  }
  find "$dir" -mindepth 1 -maxdepth 1 -print -exec rm -rf {} + 2>/dev/null || true
}

truncate_large_logs() {
  local f
  for f in "$@"; do
    [ -f "$f" ] || continue
    if [ "$(stat -f %z "$f" 2>/dev/null || echo 0)" -gt $((50 * 1024 * 1024)) ]; then
      if { : > "$f"; } 2>/dev/null; then
        log "truncated $f"
      else
        log "could not truncate $f"
      fi
    fi
  done
}

log "cleanup start host=$(hostname) free_gib=$(free_gib)"

active=0
if has_active_builds; then
  active=1
  log "active build detected, skipping aggressive DerivedData cleanup"
fi

for home in /Users/cmuxvnc*; do
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
  for home in /Users/cmuxvnc*; do
    [ -d "$home" ] || continue
    purge_children "$home/cmux-ci/DerivedData"
    purge_children "$home/Library/Developer/Xcode/DerivedData"
  done
fi

prune_stopped_orchard_tart_vms

find /tmp /private/tmp -maxdepth 1 \( -name 'cmux-*' -o -name 'macfleet-ci-*' -o -name 'sat15-*' -o -name 'smoke-*' \) -mmin +"$tmp_max_age_minutes" -print -exec rm -rf {} + 2>/dev/null || true
(
  shopt -s nullglob
  truncate_large_logs /var/log/cmux-actions-runner-*.log /var/log/cmux-actions-runner-*.err
)

log "cleanup done free_gib=$(free_gib)"
