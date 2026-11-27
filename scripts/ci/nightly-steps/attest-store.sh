#!/usr/bin/env bash
# nightly.yml attest-nightly-remote-daemon: "Store the daemon attestation". One POST of the offline-signed
# bundle (scripts/ci/attest-offline/sign.mjs) to the attestations API, the write actions/attest-build-provenance
# makes, with no budget wait and no retry: a refusal leaves the bundle in the run's provenance artifact, where
# `gh attestation verify FILE --bundle BUNDLE` still verifies it. Waiting for the shared installation budget
# held this job 17.6 minutes (run 45562645699).
#
#   attest-store.sh BUNDLE        (GH_TOKEN, GITHUB_REPOSITORY)
set -euo pipefail
bundle="${1:?usage: attest-store.sh BUNDLE}"
[[ -s "$bundle" ]] || { echo "attest-store: no bundle at $bundle" >&2; exit 1; }
python3 -c 'import json, sys; print(json.dumps({"bundle": json.load(open(sys.argv[1]))}))' "$bundle" \
  | gh api --method POST "repos/${GITHUB_REPOSITORY:?}/attestations" --input - --jq '"Attestation stored: id \(.id)"'
