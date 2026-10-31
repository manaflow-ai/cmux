#!/bin/bash
# The identity a tagged dev app is re-signed with.
#
# CMUX_DEV_SIGN_IDENTITY names a code signing identity (its name or SHA-1, as
# `codesign --sign` takes it). Unset, empty or "-" signs ad hoc, as before. The
# signing sites pass `--sign "${CMUX_DEV_SIGN_IDENTITY:--}"`.
#
# cmux_dev_sign_identity_ready
#   Returns 0 when the app can be signed: ad hoc, or a set identity that
#   `security find-identity -v -p codesigning` lists. Otherwise prints why and
#   returns 1, so a set identity never falls back to an ad hoc signature.
#
# The re-sign passes no --entitlements and no --preserve-metadata, so the app's
# new signature carries no entitlements and needs no provisioning profile.
cmux_dev_sign_identity_ready() {
  local identity="${CMUX_DEV_SIGN_IDENTITY:-}"
  if [[ -z "$identity" || "$identity" == "-" ]]; then
    return 0
  fi
  local identities=""
  if ! identities="$(security find-identity -v -p codesigning 2>&1)"; then
    echo "error: CMUX_DEV_SIGN_IDENTITY is set to '$identity', but 'security find-identity -v -p codesigning' failed: $identities" >&2
    echo "error: unset CMUX_DEV_SIGN_IDENTITY to sign ad hoc" >&2
    return 1
  fi
  # Only the numbered identity rows, not the "N valid identities found" summary.
  if ! printf '%s\n' "$identities" | grep -E '^[[:space:]]*[0-9]+\)' | grep -F -- "$identity" >/dev/null; then
    echo "error: CMUX_DEV_SIGN_IDENTITY is set to '$identity', but no valid code signing identity matches it (security find-identity -v -p codesigning)" >&2
    echo "error: unset CMUX_DEV_SIGN_IDENTITY to sign ad hoc" >&2
    return 1
  fi
}
