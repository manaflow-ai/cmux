#!/usr/bin/env bash
# rustc wrapper for scripts/ci/cargo-groups.sh (GIANTS_ONE_AT_A_TIME): cargo runs `RUSTC_WRAPPER rustc ARGS`.
# A crate named in CARGO_GROUPS_GIANTS (crate names, space separated) compiles only while it holds an flock on
# CARGO_GROUPS_GIANT_LOCK, so two giants never compile at once; every other crate runs at once as before.
# CARGO_GROUPS_INNER_WRAPPER, when set, is a wrapper the caller had in RUSTC_WRAPPER: it still runs.
set -uo pipefail

inner=()
[[ -n "${CARGO_GROUPS_INNER_WRAPPER:-}" ]] && inner=("$CARGO_GROUPS_INNER_WRAPPER")

crate="" prev=""
for a in "$@"; do
  [[ "$prev" == --crate-name ]] && { crate=$a; break; }
  prev=$a
done

if [[ -n "$crate" && -n "${CARGO_GROUPS_GIANT_LOCK:-}" && " ${CARGO_GROUPS_GIANTS:-} " == *" $crate "* ]]; then
  exec 9>>"$CARGO_GROUPS_GIANT_LOCK"
  start=$(date +%s)
  flock 9
  waited=$(($(date +%s) - start))
  ((waited < 1)) || echo "cargo groups: $crate waited ${waited} s for the other giant (GIANTS_ONE_AT_A_TIME)" >&2
  # The lock is released when this process, the one rustc runs in, exits.
  exec ${inner[@]+"${inner[@]}"} "$@"
fi
exec ${inner[@]+"${inner[@]}"} "$@"
