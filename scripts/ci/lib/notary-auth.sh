#!/usr/bin/env bash
# notarytool authentication with the team App Store Connect API key.
#
# Source this file, then call `notary_auth_init <private-dir>` once. It decodes
# ASC_API_KEY_P8_BASE64 into <private-dir> with mode 600 and sets the
# NOTARY_AUTH_ARGS array for `xcrun notarytool submit|wait|log|history`.
# The caller owns <private-dir> and must delete it on exit (an EXIT trap), so
# the decoded key never outlives the script that used it.
#
# Required environment: ASC_API_KEY_ID, ASC_API_ISSUER_ID, ASC_API_KEY_P8_BASE64.

NOTARY_AUTH_ARGS=()

notary_auth_init() {
  local key_dir="${1:-}" key_path
  if [ -z "$key_dir" ] || [ ! -d "$key_dir" ]; then
    echo "notary_auth_init needs an existing private directory" >&2
    return 1
  fi
  if [ -z "${ASC_API_KEY_ID:-}" ] \
    || [ -z "${ASC_API_ISSUER_ID:-}" ] \
    || [ -z "${ASC_API_KEY_P8_BASE64:-}" ]; then
    echo "Missing notarization secrets (ASC_API_KEY_ID, ASC_API_ISSUER_ID, ASC_API_KEY_P8_BASE64)" >&2
    return 1
  fi

  key_path="$key_dir/notary-key/AuthKey_${ASC_API_KEY_ID}.p8"
  (
    umask 077
    mkdir -p "$(dirname "$key_path")"
    printf '%s' "$ASC_API_KEY_P8_BASE64" | base64 --decode > "$key_path"
  )
  chmod 600 "$key_path"
  if [ ! -s "$key_path" ]; then
    echo "ASC_API_KEY_P8_BASE64 did not decode to a key" >&2
    return 1
  fi

  NOTARY_AUTH_ARGS=(--key "$key_path" --key-id "$ASC_API_KEY_ID" --issuer "$ASC_API_ISSUER_ID")
}

# Delete the decoded key before a script runs code from the bundle: the app
# runs as the same user and could read the file. Call it after the last
# notarytool command.
notary_auth_forget() {
  local key_dir="${1:-}"
  if [ -n "$key_dir" ]; then
    rm -rf "$key_dir/notary-key"
  fi
  NOTARY_AUTH_ARGS=()
}
