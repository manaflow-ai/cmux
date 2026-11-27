#!/usr/bin/env bash
# nightly.yml attest-nightly-remote-daemon: "Report a missing daemon attestation". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
#   SIGNED   the offline signing step's outcome (success: the bundle is in the run's provenance artifact)
if [[ "${SIGNED:-}" == success ]]; then
  echo "::warning title=SSH daemon attestation kept offline only::The attestations API refused the one store (usually the installation API rate limit). The signed bundle is the run's cmux-nightly-remote-daemon-provenance artifact; verify with gh attestation verify FILE --bundle cmuxd-remote.sigstore.json --repo manaflow-ai/cmux."
else
  echo "::warning title=SSH daemon assets shipped without provenance::Signing the provenance failed (OIDC, Fulcio or Rekor). The nightly continues; gh attestation verify will find no attestation for this build's cmuxd-remote assets."
fi
