#!/usr/bin/env bash
# ensure_rust_targets [--toolchain TOOLCHAIN] TARGET...
#
# Installs the Rust targets that are missing, and only those. `rustup target
# add` syncs the channel manifest from static.rust-lang.org on every call, even
# when the target is already installed, so one network blip used to fail a
# build whose toolchain and rust-std were all on disk. This reads
# `rustup target list --installed` (local, no network) first and calls
# `rustup target add` only for the targets it does not list.
#
# Run it in the directory whose rust-toolchain.toml applies, or pass
# --toolchain. The add gets a bounded retry: RUST_TARGETS_ATTEMPTS attempts
# (1-9, default 3), sleeping RUST_TARGETS_BACKOFF seconds times the attempt number
# between them (default 2: 2s, then 4s). It returns the add's status after the
# last attempt.
#
# Source it; it defines one function and changes no shell options.

ensure_rust_targets() {
  local toolchain_args=()
  if [[ "${1:-}" == --toolchain ]]; then
    [[ -n "${2:-}" ]] || { echo "error: ensure_rust_targets: --toolchain needs a value" >&2; return 2; }
    toolchain_args=(--toolchain "$2")
    shift 2
  fi
  [[ $# -gt 0 ]] || return 0

  local installed missing=() target
  # A failed listing (an unreadable toolchain, say) counts as nothing installed,
  # so every target goes to the add, which reports the real error.
  installed="$(rustup target list ${toolchain_args[@]+"${toolchain_args[@]}"} --installed 2>/dev/null || true)"
  for target in "$@"; do
    grep -Fxq -- "$target" <<<"$installed" || missing+=("$target")
  done
  if [[ ${#missing[@]} -eq 0 ]]; then
    echo "Rust targets already installed: $*"
    return 0
  fi

  local attempts="${RUST_TARGETS_ATTEMPTS:-3}" backoff="${RUST_TARGETS_BACKOFF:-2}" attempt status=0
  [[ "$attempts" =~ ^[1-9]$ ]] || attempts=3
  [[ "$backoff" =~ ^[0-9]{1,2}$ ]] || backoff=2
  for ((attempt = 1; attempt <= attempts; attempt++)); do
    status=0
    rustup target add ${toolchain_args[@]+"${toolchain_args[@]}"} "${missing[@]}" || status=$?
    [[ "$status" -eq 0 ]] && return 0
    [[ "$attempt" -lt "$attempts" ]] || break
    echo "warning: rustup target add ${missing[*]} failed (exit $status), attempt $attempt of $attempts; retrying" >&2
    sleep $((backoff * attempt))
  done
  echo "error: rustup target add ${missing[*]} failed $attempts times (exit $status)" >&2
  return "$status"
}
