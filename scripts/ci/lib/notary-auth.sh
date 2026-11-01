#!/usr/bin/env bash
# notarytool authentication with the team App Store Connect API key.
#
# Source this file, then call `notary_auth_init <private-dir>` once. The
# default Linux/Blacksmith path decodes ASC_API_KEY_P8_BASE64 into <private-dir>
# with mode 600. A native owned-Mac caller sets
# CMUX_NOTARY_USE_KEYCHAIN_PROFILE=true; that path imports the key through an
# inherited fd into notarytool's profile in the job's temporary default
# keychain, and never writes a P8 file.
# The caller owns <private-dir> and must delete it on exit (an EXIT trap), so
# the decoded key never outlives the script that used it.
#
# Required environment: ASC_API_KEY_ID, ASC_API_ISSUER_ID, ASC_API_KEY_P8_BASE64.

NOTARY_AUTH_ARGS=()
NOTARY_AUTH_MODE=file

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

  if [ "${CMUX_NOTARY_USE_KEYCHAIN_PROFILE:-false}" = true ]; then
    local profile="${CMUX_NATIVE_NOTARY_PROFILE:-cmux-notary-${ASC_API_KEY_ID}}"
    local keychain="${CMUX_NATIVE_SIGNING_KEYCHAIN:-}"
    local xcrun_tool="${CMUX_XCRUN_TOOL:-xcrun}"
    if [ -z "$keychain" ]; then
      echo "CMUX_NATIVE_SIGNING_KEYCHAIN is required for a native notary profile" >&2
      return 1
    fi
    case "$profile" in
      ''|*[!A-Za-z0-9._-]*)
        echo "CMUX_NATIVE_NOTARY_PROFILE must contain only letters, digits, dot, underscore or dash" >&2
        return 1
        ;;
    esac
    # notarytool accepts a path for --key; /dev/fd/3 is a seek-free stream and
    # the explicit keychain profile keeps the imported secret in the job's
    # temporary keychain instead of a raw P8 file on the runner.
    exec 3< <(printf '%s' "$ASC_API_KEY_P8_BASE64" | base64 --decode)
    if ! "$xcrun_tool" notarytool store-credentials "$profile" \
      --key /dev/fd/3 --key-id "$ASC_API_KEY_ID" --issuer "$ASC_API_ISSUER_ID" \
      --keychain "$keychain"; then
      exec 3<&-
      echo "notarytool could not store the API key in the temporary keychain profile" >&2
      return 1
    fi
    exec 3<&-
    NOTARY_AUTH_ARGS=(--keychain-profile "$profile" --keychain "$keychain")
    NOTARY_AUTH_MODE=keychain-profile
    return 0
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
  NOTARY_AUTH_MODE=file
}
