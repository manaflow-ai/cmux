#!/usr/bin/env bash
# The cmux NEXT nightly from an owned Mac while GitHub Actions starts no runs: build, sign, notarize, verify and
# publish the arm64 Nightly-ring feed (appcast-arm64.xml) straight from the git mirror, running nightly.yml's own
# steps (the same scripts, in the same order, with the same env names) at SHA. Everything is in
# scripts/ci/nightly_next_fleet_fallback.py (its docstring is the manual); docs/ci/nightly-next-train.md,
# "When Actions starts no runs", says when it runs and what stays pending.
#
#   nightly-next-fleet-fallback.sh --sha SHA --build N|auto [--workdir D] [--git-dir G] [--vars FILE] [--dry-run]
#
# --build: a fallback build number, <live run id><50+k> (scripts/ci/nightly_version.py fallback-build), or auto.
# --git-dir: the mirror, default /Users/Shared/cmux-build-fleet/git/cmux.git. --vars: the repository variables
# snapshot (NIGHTLY_NEXT_WRITER and the rest), default $NIGHTLY_FALLBACK_VARS or ~/.cache/actions-stall/cmux-vars.json.
#
# Credentials: the environment only, under the workflow's secret names; run it under
# `op run --env-file <refs> -- scripts/ci/nightly-next-fleet-fallback.sh ...` with the signing host's 1Password
# service account. A missing one exits 78 before anything is built, naming it (never its value).
#
# Exit: 0 published (or --dry-run planned), 3 stood down or superseded, 78 no credentials, other: failure.
# Last stdout line: NIGHTLY_FALLBACK_RESULT=<json>. It never cancels anything.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$here/nightly_next_fleet_fallback.py" run "$@"
