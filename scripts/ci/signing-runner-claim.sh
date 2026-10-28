#!/usr/bin/env bash
# The first step of every signing job that can run on an owned Mac.
#
# A signing job puts the Developer ID certificate in a per-job temporary
# keychain (scripts/ci/signing-keychain.sh). On an ephemeral runner (Blacksmith,
# GitHub-hosted) nothing else ever runs on the machine. On an owned Mac
# (a glaeda runner on a fleet mini) the job must hold the whole mini:
# glaeda's job-started hook gives the signing jobs the exclusive class (every
# capacity unit and both fast tokens) and writes GLAEDA_JOB_CLAIM=exclusive to
# $GITHUB_ENV. This step fails the job, before any secret is read, on an owned
# Mac without that claim (a hook from before the exclusive class), and removes
# a signing keychain a killed job on that Mac left behind.
#
# Usage: signing-runner-claim.sh   (no arguments; reads RUNNER_NAME,
# GLAEDA_JOB_CLAIM and CMUX_FLEET_DIR, default /Users/Shared/cmux-build-fleet)
set -euo pipefail

FLEET_DIR="${CMUX_FLEET_DIR:-/Users/Shared/cmux-build-fleet}"
SECURITY_TOOL="${CMUX_SECURITY_TOOL:-security}"
KEYCHAIN_DIR="${CMUX_KEYCHAIN_DIR:-$HOME/Library/Keychains}"
# The keychain names the workflows give signing-keychain.sh create.
STALE_KEYCHAINS=(build.keychain cmux-next-dev-daily.keychain)

owned=""
case "${RUNNER_NAME:-}" in
  *-glaeda|*-glaeda-*) owned="runner ${RUNNER_NAME} is a glaeda runner" ;;
esac
if [ -z "$owned" ] && [ -d "$FLEET_DIR" ]; then
  owned="$FLEET_DIR exists"
fi

if [ -z "$owned" ]; then
  echo "Signing runner: ${RUNNER_NAME:-this runner} is ephemeral; no claim needed."
  exit 0
fi

if [ "${GLAEDA_JOB_CLAIM:-}" != "exclusive" ]; then
  echo "::error title=Signing runner::This owned Mac ($owned) did not give the job the whole mini (GLAEDA_JOB_CLAIM='${GLAEDA_JOB_CLAIM:-}'). A signing job never runs beside another job; its re-run takes Blacksmith."
  exit 1
fi

for name in "${STALE_KEYCHAINS[@]}"; do
  if [ -e "$KEYCHAIN_DIR/$name-db" ] || [ -e "$KEYCHAIN_DIR/$name" ]; then
    "$SECURITY_TOOL" delete-keychain "$name" >/dev/null 2>&1 || rm -f "$KEYCHAIN_DIR/$name-db" "$KEYCHAIN_DIR/$name"
    echo "Signing runner: removed the signing keychain $name an earlier job left on this Mac."
  fi
done
echo "Signing runner: ${RUNNER_NAME:-this runner} holds the whole mini (GLAEDA_JOB_CLAIM=exclusive); no other job runs here until this one ends."
