#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <recovery-artifact-root>" >&2
  exit 2
fi

RECOVERY_ROOT="$1"
XCRUN_TOOL="${CMUX_XCRUN_TOOL:-xcrun}"
WAIT_TIMEOUT="${CMUX_NOTARY_RECOVERY_WAIT_TIMEOUT:-30m}"
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

if [ ! -d "$RECOVERY_ROOT" ]; then
  echo "Recovery artifact root does not exist: $RECOVERY_ROOT" >&2
  exit 1
fi

# shellcheck source=lib/notary-auth.sh
source "$ROOT_DIR/scripts/ci/lib/notary-auth.sh"

NOTARY_DIR="$(mktemp -d)"
trap 'rm -rf "$NOTARY_DIR"' EXIT
chmod 700 "$NOTARY_DIR"
notary_auth_init "$NOTARY_DIR"

sha256_file() {
  python3 - "$1" <<'PY'
import hashlib
import sys

digest = hashlib.sha256()
with open(sys.argv[1], "rb") as source:
    for chunk in iter(lambda: source.read(1024 * 1024), b""):
        digest.update(chunk)
print(digest.hexdigest())
PY
}

state_value() {
  local state="$1" key="$2"
  awk -F= -v key="$key" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' "$state"
}

extract_json_value() {
  local output="$1" key="$2"
  python3 - "$output" "$key" <<'PY'
import json
import re
import sys

path, key = sys.argv[1:]
raw = open(path, encoding="utf-8").read()
decoder = json.JSONDecoder()
values = []
for match in re.finditer(r"\{", raw):
    try:
        value, _ = decoder.raw_decode(raw[match.start():])
    except json.JSONDecodeError:
        continue
    if isinstance(value, dict) and value.get(key) not in (None, ""):
        values.append(value[key])
if values:
    print(values[-1])
PY
}

STATES=()
while IFS= read -r state; do
  STATES+=("$state")
done < <(find "$RECOVERY_ROOT" -type f -name '*.notarization.state' -print | sort)
if [ "${#STATES[@]}" -eq 0 ]; then
  echo "No notarization recovery state files found under $RECOVERY_ROOT" >&2
  exit 1
fi

mkdir -p "$RECOVERY_ROOT/recovered"
recovered=0
for state in "${STATES[@]}"; do
  artifact_dir="$(dirname "$state")"
  dmg_name="$(basename "$(state_value "$state" dmg_path)")"
  expected_sha="$(state_value "$state" dmg_sha256)"
  submission_id="$(state_value "$state" submission_id)"
  if [[ ! "$dmg_name" =~ ^[A-Za-z0-9._-]+\.dmg$ ]]; then
    echo "Invalid DMG name in $state: $dmg_name" >&2
    exit 1
  fi
  if [[ ! "$expected_sha" =~ ^[0-9a-fA-F]{64}$ ]]; then
    echo "Missing or invalid DMG SHA-256 in $state" >&2
    exit 1
  fi
  if [ -z "$submission_id" ]; then
    echo "Missing notary submission ID in $state" >&2
    exit 1
  fi

  dmg="$(find "$artifact_dir" -type f -name "$dmg_name" -print -quit)"
  app="$(find "$artifact_dir" -type d -name '*.app' -print -quit)"
  if [ -z "$dmg" ] || [ -z "$app" ]; then
    echo "Recovery artifact for $state is missing the exact DMG or app" >&2
    exit 1
  fi
  actual_sha="$(sha256_file "$dmg")"
  actual_sha_lower="$(printf '%s' "$actual_sha" | tr '[:upper:]' '[:lower:]')"
  expected_sha_lower="$(printf '%s' "$expected_sha" | tr '[:upper:]' '[:lower:]')"
  if [ "$actual_sha_lower" != "$expected_sha_lower" ]; then
    echo "DMG SHA-256 mismatch for $dmg: expected $expected_sha, got $actual_sha" >&2
    exit 1
  fi

  wait_output="$artifact_dir/notarytool-wait.json"
  log_output="$artifact_dir/notarytool-log.json"
  set +e
  "$XCRUN_TOOL" notarytool wait "$submission_id" "${NOTARY_AUTH_ARGS[@]}" \
    --timeout "$WAIT_TIMEOUT" --output-format json >"$wait_output" 2>&1
  wait_exit=$?
  set -e
  "$XCRUN_TOOL" notarytool log "$submission_id" "${NOTARY_AUTH_ARGS[@]}" >"$log_output" 2>&1 || true
  if [ "$wait_exit" -ne 0 ]; then
    echo "notarytool wait failed for submission $submission_id; see $wait_output and $log_output" >&2
    exit 1
  fi
  status="$(extract_json_value "$wait_output" status || true)"
  if [ "$status" != "Accepted" ]; then
    echo "notarytool wait returned status ${status:-unknown} for submission $submission_id; see $log_output" >&2
    exit 1
  fi

  # Staple only after the exact-DMG hash and the notary wait/log both succeed.
  "$XCRUN_TOOL" stapler staple "$app"
  "$XCRUN_TOOL" stapler validate "$app"
  "$XCRUN_TOOL" stapler staple "$dmg"
  "$XCRUN_TOOL" stapler validate "$dmg"
  result_dir="$RECOVERY_ROOT/recovered/$(basename "$artifact_dir")"
  mkdir -p "$result_dir"
  cp "$dmg" "$result_dir/"
  cp "$wait_output" "$result_dir/"
  cp "$log_output" "$result_dir/"
  cp -R "$app" "$result_dir/"
  recovered=$((recovered + 1))
done

printf 'Recovered and stapled %d notarization artifact(s)\n' "$recovered"
