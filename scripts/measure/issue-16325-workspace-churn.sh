#!/bin/bash
set -euo pipefail
# Diagnostic only: run on a controller-scheduled macOS GUI worker.
# Arguments: completed build job ID and its exact descriptive tag.
job_id=${1:?build job ID required}
tag=${2:?tag required}
[[ "$tag" == issue-16325-* ]] || exit 2
root=$(mktemp -d /tmp/cmux-16325-profile.XXXXXX)
trap 'echo "Diagnostic files: $root"' EXIT
client="$HOME/.local/bin/cmux-ci"
"$client" artifact "$job_id" "$root/app.zip"
/usr/bin/ditto -x -k "$root/app.zip" "$root/app"
app="$root/app/cmux DEV $tag.app"
[[ -d "$app" ]] || { echo 'Tagged bundle missing'; exit 1; }
/usr/bin/codesign --verify --deep --strict "$app"
python3 -u scripts/measure/issue_16325_workspace_churn.py "$app" "$root"
mkdir -p artifacts
tar -czf artifacts/issue-16325-workspace-churn.tar.gz -C "$root" results
