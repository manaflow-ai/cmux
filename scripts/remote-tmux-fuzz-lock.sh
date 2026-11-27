#!/bin/bash
# Shared lock ownership for remote-tmux fuzz drivers. Callers source this file
# and register `cmux_fuzz_lock_release` from their existing EXIT cleanup.

cmux_fuzz_lock_acquire() {
  local tmp_root=$1 holder attempts=0
  CMUX_FUZZ_LOCK_DIR="${CMUX_FUZZ_LOCK_DIR:-${tmp_root%/}/cmux-fuzz-marathon.lock}"
  while ! mkdir "$CMUX_FUZZ_LOCK_DIR" 2>/dev/null; do
    if [ -L "$CMUX_FUZZ_LOCK_DIR" ] || [ ! -d "$CMUX_FUZZ_LOCK_DIR" ] \
       || [ ! -O "$CMUX_FUZZ_LOCK_DIR" ]; then
      echo "fuzz lock exists but is not an owned directory — refusing to start" >&2
      return 96
    fi
    holder="$(cat "$CMUX_FUZZ_LOCK_DIR/pid" 2>/dev/null)"
    case "$holder" in ''|*[!0-9]*) holder="" ;; esac
    if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
      echo "another fuzz driver (pid $holder) is running — refusing to start"
      return 96
    fi
    if [ "$attempts" -ge 1 ]; then
      echo "could not atomically acquire fuzz lock" >&2
      return 96
    fi
    # Stale takeover removes only this protocol's private entries. `rmdir`
    # refuses a caller-supplied directory containing anything else.
    rm -f -- "$CMUX_FUZZ_LOCK_DIR/pid" "$CMUX_FUZZ_LOCK_DIR/token"
    if ! rmdir -- "$CMUX_FUZZ_LOCK_DIR" 2>/dev/null; then
      echo "owned stale fuzz lock contains unexpected entries — refusing to remove it" >&2
      return 96
    fi
    attempts=$((attempts + 1))
  done

  CMUX_FUZZ_LOCK_TOKEN="$$.$RANDOM.$(date +%s)"
  if ! printf '%s\n' "$$" > "$CMUX_FUZZ_LOCK_DIR/pid" \
     || ! printf '%s\n' "$CMUX_FUZZ_LOCK_TOKEN" > "$CMUX_FUZZ_LOCK_DIR/token"; then
    rm -f -- "$CMUX_FUZZ_LOCK_DIR/pid" "$CMUX_FUZZ_LOCK_DIR/token"
    rmdir -- "$CMUX_FUZZ_LOCK_DIR" 2>/dev/null
    echo "could not initialize fuzz lock" >&2
    return 96
  fi
  CMUX_FUZZ_LOCK_OWNED=1
  export CMUX_FUZZ_LOCK_HELD=1 CMUX_FUZZ_LOCK_DIR CMUX_FUZZ_LOCK_TOKEN
}

cmux_fuzz_lock_validate_inherited() {
  local holder
  if [ -z "${CMUX_FUZZ_LOCK_DIR:-}" ] || [ -z "${CMUX_FUZZ_LOCK_TOKEN:-}" ]; then
    echo "inherited fuzz lock is missing or invalid — refusing to start" >&2
    return 96
  fi
  if [ -L "$CMUX_FUZZ_LOCK_DIR" ] || [ ! -d "$CMUX_FUZZ_LOCK_DIR" ] \
     || [ ! -O "$CMUX_FUZZ_LOCK_DIR" ] \
     || [ "$(cat "$CMUX_FUZZ_LOCK_DIR/token" 2>/dev/null)" != "$CMUX_FUZZ_LOCK_TOKEN" ]; then
    echo "inherited fuzz lock is missing or invalid — refusing to start" >&2
    return 96
  fi
  holder="$(cat "$CMUX_FUZZ_LOCK_DIR/pid" 2>/dev/null)"
  if [ "$holder" != "$PPID" ] || ! kill -0 "$holder" 2>/dev/null; then
    echo "inherited fuzz lock is missing or invalid — refusing to start" >&2
    return 96
  fi
}

cmux_fuzz_lock_release() {
  [ "${CMUX_FUZZ_LOCK_OWNED:-0}" = 1 ] || return 0
  if [ ! -L "$CMUX_FUZZ_LOCK_DIR" ] && [ -O "$CMUX_FUZZ_LOCK_DIR" ] \
     && [ "$(cat "$CMUX_FUZZ_LOCK_DIR/token" 2>/dev/null)" = "$CMUX_FUZZ_LOCK_TOKEN" ]; then
    rm -f -- "$CMUX_FUZZ_LOCK_DIR/pid" "$CMUX_FUZZ_LOCK_DIR/token"
    rmdir -- "$CMUX_FUZZ_LOCK_DIR" 2>/dev/null || true
  fi
  CMUX_FUZZ_LOCK_OWNED=0
}
