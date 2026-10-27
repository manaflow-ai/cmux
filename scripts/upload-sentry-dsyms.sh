#!/usr/bin/env bash
# Uploads dSYMs (and their sources) under PATH... to Sentry for the nightly.
#
# Symbolication is useful but never worth a nightly: runs 37531729976 and
# 37535932538 failed on `curl: (28)` from sentry-cli after a 40-minute build.
# Each attempt that fails is retried after the next delay in
# SENTRY_UPLOAD_RETRY_DELAYS (seconds, default "30 90"); when every attempt
# fails, a ::warning:: is left and the script still exits 0. No token skips.
#
# A PATH that does not exist is skipped with a note (a build that made no dSYM
# for that binary); with none left there is nothing to upload.
#
# SENTRY_CLI names an installed sentry-cli; otherwise ensure-sentry-cli.sh
# installs the pinned one (its download failing is a warning too).
set -uo pipefail

if [ -z "${SENTRY_AUTH_TOKEN:-}" ]; then
  echo "SENTRY_AUTH_TOKEN not set, skipping dSYM upload"
  exit 0
fi

paths=()
for path in "$@"; do
  if [ -e "$path" ]; then paths+=("$path"); else echo "no dSYMs at $path; skipped"; fi
done
if [ "${#paths[@]}" -eq 0 ]; then
  echo "no dSYM paths exist; nothing to upload"
  exit 0
fi

cli="${SENTRY_CLI:-}"
if [ -z "$cli" ] && ! cli="$("$(dirname "$0")/ensure-sentry-cli.sh")"; then
  echo "::warning title=Sentry dSYM upload skipped::sentry-cli could not be installed; this nightly's crashes will not symbolicate."
  exit 0
fi

read -r -a delays <<< "${SENTRY_UPLOAD_RETRY_DELAYS:-30 90}"
attempts=$(( ${#delays[@]} + 1 ))
for (( attempt = 1; attempt <= attempts; attempt++ )); do
  if "$cli" debug-files upload --include-sources "${paths[@]}"; then
    exit 0
  fi
  if (( attempt < attempts )); then
    delay="${delays[attempt - 1]}"
    echo "dSYM upload attempt $attempt of $attempts failed; retrying in ${delay}s" >&2
    sleep "$delay"
  fi
done

echo "::warning title=Sentry dSYM upload failed::$attempts attempts failed; this nightly's crashes will not symbolicate."
exit 0
