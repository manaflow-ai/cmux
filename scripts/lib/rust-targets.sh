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
# ensure_rust_toolchain TOOLCHAIN [rustup toolchain install flags...]
#
# The same for the toolchain itself. `rustup toolchain install` also syncs the
# channel manifest on every call, installed or not: the nightly's Chief step
# failed on exactly that (run 43180668014, 2026-11-12: "could not download file
# from 'https://static.rust-lang.org/dist/channel-rust-1.100.0.toml.sha256' ...
# Operation timed out" with 1.100.0 on disk). This reads `rustup toolchain list`
# (local) first and installs only a missing toolchain, with the same bounded
# retry. A toolchain that is listed but lacks a component asked for with
# --component is still installed (rustup adds the component).
#
# Source it; it defines two functions and changes no shell options.

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

ensure_rust_toolchain() {
  local toolchain="${1:-}"
  [[ -n "$toolchain" ]] || { echo "error: ensure_rust_toolchain: needs a toolchain" >&2; return 2; }
  shift
  local wants_component=0 arg
  for arg in "$@"; do [[ "$arg" == -c || "$arg" == --component* ]] && wants_component=1; done
  if [[ "$wants_component" -eq 0 ]] \
    && rustup toolchain list 2>/dev/null | awk '{print $1}' | grep -Eq -- "^${toolchain//./\\.}(-|$)"; then
    echo "Rust toolchain already installed: $toolchain"
    return 0
  fi
  local attempts="${RUST_TARGETS_ATTEMPTS:-3}" backoff="${RUST_TARGETS_BACKOFF:-2}" attempt status=0
  [[ "$attempts" =~ ^[1-9]$ ]] || attempts=3
  [[ "$backoff" =~ ^[0-9]{1,2}$ ]] || backoff=2
  for ((attempt = 1; attempt <= attempts; attempt++)); do
    status=0
    rustup toolchain install "$toolchain" "$@" || status=$?
    [[ "$status" -eq 0 ]] && return 0
    [[ "$attempt" -lt "$attempts" ]] || break
    echo "warning: rustup toolchain install $toolchain failed (exit $status), attempt $attempt of $attempts; retrying" >&2
    sleep $((backoff * attempt))
  done
  echo "error: rustup toolchain install $toolchain failed $attempts times (exit $status)" >&2
  return "$status"
}
