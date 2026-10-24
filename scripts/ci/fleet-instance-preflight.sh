#!/usr/bin/env bash
# Verify the GCE caller can read the instance used by a fleet gateway.
# Non-GCE runners have no metadata endpoint and continue without this check.
set -uo pipefail

metadata_root="${GCE_METADATA_ROOT:-http://metadata.google.internal/computeMetadata/v1}"
metadata_get() {
  curl -fsS --max-time "${CMUX_CI_METADATA_TIMEOUT_SECONDS:-2}" \
    -H 'Metadata-Flavor: Google' "$metadata_root/$1"
}

instance="${CMUX_CI_FLEET_INSTANCE:-}"
zone="${CMUX_CI_FLEET_ZONE:-}"
project="${CMUX_CI_FLEET_PROJECT:-}"
explicit=false
if [[ -n "$instance$zone$project" ]]; then
  explicit=true
fi

# A normal GitHub-hosted or Mac runner is not a GCE VM. Do not turn the lack of
# metadata there into a false fleet failure; an explicit target must be checked.
if [[ -z "$instance" ]]; then
  instance="$(metadata_get instance/name 2>/dev/null || true)"
fi
if [[ -z "$instance" ]]; then
  if [[ "$explicit" == true ]]; then
    echo "::error title=Fleet instance preflight unavailable::Could not discover the selected GCP instance before dispatch; no CI job was dispatched."
    exit 69
  fi
  exit 0
fi
if [[ -z "$zone" ]]; then
  zone="$(metadata_get instance/zone 2>/dev/null || true)"
fi
if [[ -z "$project" ]]; then
  project="$(metadata_get project/project-id 2>/dev/null || true)"
fi
zone="${zone##*/}"
if [[ -z "$zone" || -z "$project" ]]; then
  echo "::error title=Fleet instance preflight unavailable::Could not resolve the selected GCP instance location before dispatch; no CI job was dispatched."
  exit 69
fi
if ! command -v gcloud >/dev/null 2>&1; then
  echo "::error title=Fleet instance preflight unavailable::gcloud is not installed, so the selected GCP instance could not be inspected; no CI job was dispatched."
  exit 69
fi

error_file="$(mktemp "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/fleet-instance-preflight.XXXXXX")"
trap 'rm -f "$error_file"' EXIT
if ! gcloud compute instances describe "$instance" --zone "$zone" --project "$project" \
    --format='value(name)' > /dev/null 2>"$error_file"; then
  if grep -Fq "compute.instances.get" "$error_file"; then
    echo "::error title=Fleet IAM preflight failed::Caller lacks compute.instances.get for the selected GCP instance. No CI job was dispatched; grant the permission and rerun."
  else
    echo "::error title=Fleet instance preflight failed::Could not inspect the selected GCP instance before dispatch. No CI job was dispatched; investigate the cloud preflight failure and rerun."
  fi
  exit 69
fi
