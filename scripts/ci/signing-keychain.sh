#!/usr/bin/env bash
# Owns the lifetime of the CI code-signing keychain.
#
# The signing keychain exists only while a step signs. Delete it before any
# step runs code from the bundle (smoke launches, the bundled CLI, the diff
# sidecar handshake); scripts that run bundle code call
# scripts/ci/lib/signing-runtime-guard.sh and fail while it exists.
#
# Usage:
#   signing-keychain.sh create [--keychain NAME]
#       Needs APPLE_CERTIFICATE_BASE64 and APPLE_CERTIFICATE_PASSWORD. Decodes
#       the certificate into a private temporary file, imports it with the
#       Developer ID intermediates, deletes the file, and leaves the keychain
#       unlocked with a short idle lock (CMUX_SIGNING_KEYCHAIN_TIMEOUT seconds,
#       default 600).
#   signing-keychain.sh unlock
#       Unlock every keychain this job created, after a long wait (Apple
#       notarization) let the idle lock close it. No-op when none exists.
#   signing-keychain.sh lock
#       Lock every keychain this job created.
#   signing-keychain.sh delete [--keychain NAME]
#       Lock and delete every keychain this job created, and the name given
#       with --keychain (for always() cleanup). No-op when none exists.
#   signing-keychain.sh is-present
#       Exit 0 when this job still holds a signing keychain, 1 otherwise.
#   signing-keychain.sh assert-deleted
#       Exit 1 when this job still holds a signing keychain.
#
# State lives in $RUNNER_TEMP/cmux-signing-keychain (or
# CMUX_SIGNING_KEYCHAIN_STATE_DIR). Outside CI there is no state, so unlock,
# lock, delete and is-present do nothing and local signing is unchanged.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
SECURITY_TOOL="${CMUX_SECURITY_TOOL:-security}"
TIMEOUT_SECONDS="${CMUX_SIGNING_KEYCHAIN_TIMEOUT:-600}"
KEYCHAIN_DIR="${CMUX_KEYCHAIN_DIR:-$HOME/Library/Keychains}"
# shellcheck source=lib/signing-runtime-guard.sh
source "$SCRIPT_DIR/lib/signing-runtime-guard.sh"

usage() {
  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

[ "$#" -ge 1 ] || usage
command="$1"
shift
keychain=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --keychain)
      [ "$#" -ge 2 ] || usage
      keychain="$2"
      shift 2
      ;;
    *) usage ;;
  esac
done

case "$TIMEOUT_SECONDS" in
  ''|*[!0-9]*)
    echo "error: CMUX_SIGNING_KEYCHAIN_TIMEOUT must be a number of seconds" >&2
    exit 2
    ;;
esac
if [ "$TIMEOUT_SECONDS" -gt 900 ]; then
  echo "error: CMUX_SIGNING_KEYCHAIN_TIMEOUT must be 900 seconds or less; unlock again after a long wait instead" >&2
  exit 2
fi

state_dir="$(cmux_signing_keychain_state_dir)"

password_file() {
  printf '%s/%s.password\n' "$state_dir" "$1"
}

# The user keychain search list from before the first create in this job. An
# owned Mac outlives the job, so delete puts the list back: the login keychain
# must stay in it for the jobs that run there next.
search_list_file() {
  printf '%s/search-list\n' "$state_dir"
}

save_search_list() {
  # The user search list before create replaces it: written whole (a temporary file moved into place) and only
  # after list-keychains succeeded. When the capture fails, a marker says so and delete falls back to the login
  # keychain, so an owned Mac never keeps a deleted signing keychain as its only search-list entry.
  local file
  file="$(search_list_file)"
  [ -e "$file" ] && return 0
  if "$SECURITY_TOOL" list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//' > "$file.tmp" \
      && [ -s "$file.tmp" ]; then
    mv -f "$file.tmp" "$file"
  else
    rm -f "$file.tmp"
    : > "$file.failed"
  fi
}

restore_search_list() {
  local file entry list=()
  file="$(search_list_file)"
  [ -n "$state_dir" ] || return 0
  if [ -s "$file" ]; then
    while IFS= read -r entry; do
      [ -n "$entry" ] && [ -e "$entry" ] && list+=("$entry")
    done < "$file"
  fi
  if [ "${#list[@]}" -eq 0 ] && { [ -e "$file" ] || [ -e "$file.failed" ]; }; then
    # create ran but nothing it saw is left (or it could not read the list): the login keychain, if there is one
    for entry in "$KEYCHAIN_DIR/login.keychain-db" "$KEYCHAIN_DIR/login.keychain"; do
      if [ -e "$entry" ]; then
        list=("$entry")
        break
      fi
    done
  fi
  if [ "${#list[@]}" -gt 0 ]; then
    "$SECURITY_TOOL" list-keychains -d user -s "${list[@]}" || true
  fi
  rm -f "$file" "$file.tmp" "$file.failed"
}

create_keychain() {
  local name="${keychain:-build.keychain}" password
  if [ -z "$state_dir" ]; then
    echo "error: signing-keychain.sh create runs only in CI (RUNNER_TEMP is not set)" >&2
    exit 2
  fi
  case "$name" in
    */*|.*|'')
      echo "error: --keychain takes a keychain name, not a path: $name" >&2
      exit 2
      ;;
  esac
  [ -n "${APPLE_CERTIFICATE_BASE64:-}" ] || { echo "Missing APPLE_CERTIFICATE_BASE64 secret" >&2; exit 1; }
  [ -n "${APPLE_CERTIFICATE_PASSWORD:-}" ] || { echo "Missing APPLE_CERTIFICATE_PASSWORD secret" >&2; exit 1; }

  umask 077
  mkdir -p "$state_dir"
  chmod 700 "$state_dir"
  # Global, not local: the EXIT trap runs after this function returns.
  # security import infers the format from the file name, so the file is a
  # .p12 in a private directory, and the import also names the format.
  certificate_dir="$(mktemp -d "$state_dir/certificate.XXXXXX")"
  certificate="$certificate_dir/certificate.p12"
  trap 'rm -rf "${certificate_dir:-}"' EXIT
  password="$(uuidgen)"
  save_search_list

  printf '%s\n' "$APPLE_CERTIFICATE_BASE64" | base64 --decode > "$certificate"
  "$SECURITY_TOOL" delete-keychain "$name" >/dev/null 2>&1 || true
  "$SECURITY_TOOL" create-keychain -p "$password" "$name"
  # Written before the import, so a failed import is still found and deleted.
  printf '%s' "$password" > "$(password_file "$name")"
  "$SECURITY_TOOL" set-keychain-settings -lut "$TIMEOUT_SECONDS" "$name"
  "$SECURITY_TOOL" unlock-keychain -p "$password" "$name"
  "$SECURITY_TOOL" import "$certificate" -k "$name" -f pkcs12 -P "$APPLE_CERTIFICATE_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security
  rm -rf "$certificate_dir"
  "$ROOT_DIR/scripts/import-apple-developer-id-intermediates.sh" "$name"
  "$SECURITY_TOOL" set-key-partition-list -S apple-tool:,apple: -s -k "$password" "$name" >/dev/null
  "$SECURITY_TOOL" list-keychains -d user -s "$name"
  refresh_trust_agent
  echo "Signing keychain $name is ready; it locks after ${TIMEOUT_SECONDS}s idle."
}

# codesign asks the user's trustd agent for the signer's chain, and that agent
# finds the Developer ID intermediate only in the keychains it reads. A trustd
# agent that has run since the Mac booted never sees a keychain added to the
# search list after its start: codesign then warns "unable to build chain to
# self-signed root" and fails with errSecInternalComponent (the unified log
# says "Trust evaluate failure: [leaf MissingIntermediate]"). Two owned minis
# failed every sign-nightly-identity-legacy job that way on 2026-10-31 while
# minis whose agent had restarted since boot (a trust store update restarts
# it) signed; a private three-level chain reproduced it on the same two minis
# and not on the others. So once the keychain is in the search
# list the agent restarts (launchd starts it again on the next request) and
# reads it. The signing job holds the whole Mac, so nothing else is
# mid-evaluation. Best effort: a refusal is reported and signing goes on.
refresh_trust_agent() {
  local launchctl="${CMUX_LAUNCHCTL_TOOL:-}" service pid
  if [ -z "$launchctl" ]; then
    [ "$(uname -s)" = Darwin ] || return 0
    launchctl=/bin/launchctl
  fi
  service="user/$(id -u)/com.apple.trustd.agent"
  if "$launchctl" kickstart -k "$service" >/dev/null 2>&1; then
    echo "Restarted the trustd agent ($service) so it reads the signing keychain."
    return 0
  fi
  # launchd's own record of the agent's pid, never a match by process name
  pid="$("$launchctl" print "$service" 2>/dev/null | sed -n 's/^[[:space:]]*pid = \([0-9][0-9]*\)$/\1/p' | head -n 1)" || pid=""
  if [ -n "$pid" ] && kill -TERM "$pid" 2>/dev/null; then
    echo "Stopped the trustd agent ($service, pid $pid); launchd starts it again reading the signing keychain."
    return 0
  fi
  echo "warning: could not restart the trustd agent ($service); a stale one fails codesign with errSecInternalComponent" >&2
  return 0
}

unlock_keychains() {
  local name
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    "$SECURITY_TOOL" unlock-keychain -p "$(cat "$(password_file "$name")")" "$name"
    "$SECURITY_TOOL" set-keychain-settings -lut "$TIMEOUT_SECONDS" "$name"
  done < <(cmux_signing_keychains_present)
}

lock_keychains() {
  local name
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    "$SECURITY_TOOL" lock-keychain "$name" || true
  done < <(cmux_signing_keychains_present)
}

delete_keychains() {
  local name names=() failed=0
  while IFS= read -r name; do
    [ -n "$name" ] && names+=("$name")
  done < <(cmux_signing_keychains_present)
  if [ -n "$keychain" ]; then
    names+=("$keychain")
  fi
  for name in ${names[@]+"${names[@]}"}; do
    "$SECURITY_TOOL" lock-keychain "$name" >/dev/null 2>&1 || true
    "$SECURITY_TOOL" delete-keychain "$name" >/dev/null 2>&1 || true
    if [ -e "$KEYCHAIN_DIR/$name-db" ] || [ -e "$KEYCHAIN_DIR/$name" ]; then
      echo "error: signing keychain $name still exists after delete" >&2
      failed=1
    fi
    if [ -n "$state_dir" ]; then
      rm -f "$(password_file "$name")"
    fi
  done
  if [ -n "$state_dir" ]; then
    rm -rf "$state_dir"/certificate.* 2>/dev/null || true
    restore_search_list
  fi
  if [ "${#names[@]}" -gt 0 ]; then
    echo "Deleted signing keychain(s): ${names[*]}"
  fi
  return "$failed"
}

case "$command" in
  create) create_keychain ;;
  unlock) unlock_keychains ;;
  lock) lock_keychains ;;
  delete) delete_keychains ;;
  is-present) [ -n "$(cmux_signing_keychains_present)" ] ;;
  assert-deleted)
    if [ -n "$(cmux_signing_keychains_present)" ]; then
      echo "error: a CI signing keychain is still present: $(cmux_signing_keychains_present | tr '\n' ' ')" >&2
      exit 1
    fi
    ;;
  *) usage ;;
esac
