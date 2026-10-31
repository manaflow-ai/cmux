#!/usr/bin/env bash
# After a DEV Release compile in host mode (compile-dev-release.sh's report says
# mode=host), write the holder record the next landing's placement reads
# (scripts/ci/dev_landing_place.py): OUT_DIR/holder.json, and print holder=<host>
# for $GITHUB_OUTPUT, the artifact name's suffix (cmux-next-dev-cas-holder-<host>).
# The record's commit is its run's head_sha (GitHub's, not this file's). Prints
# nothing for any other mode: only a host tree is warm for the next landing.
# Usage: dev-cas-holder.sh REPORT OUT_DIR
set -euo pipefail

report="${1:?usage: dev-cas-holder.sh REPORT OUT_DIR}"
out="${2:?usage: dev-cas-holder.sh REPORT OUT_DIR}"
[[ "$(sed -n 's/^mode=//p' "$report" 2>/dev/null)" == host ]] || exit 0
host="$(printf '%s' "${RUNNER_NAME:?}" | tr '[:upper:]' '[:lower:]')"
host="${host%-glaeda*}"
[[ "$host" =~ ^[a-z0-9._-]+$ ]] || exit 0
mkdir -p "$out"
printf '{"host": "%s", "sha": "%s", "runner": "%s"}\n' "$host" "${GITHUB_SHA:-}" "$RUNNER_NAME" > "$out/holder.json"
echo "holder=$host"
