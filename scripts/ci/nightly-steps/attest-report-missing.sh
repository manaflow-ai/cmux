#!/usr/bin/env bash
# nightly.yml attest-nightly-remote-daemon: "Report a missing daemon attestation". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
echo "::warning title=SSH daemon assets shipped without provenance::actions/attest-build-provenance failed twice (usually the installation API rate limit). The nightly continues; gh attestation verify will find no attestation for this build's cmuxd-remote assets."
