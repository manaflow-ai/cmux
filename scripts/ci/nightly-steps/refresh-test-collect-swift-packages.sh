#!/usr/bin/env bash
# nightly.yml refresh-test-compilation-cache: "Collect resolved Swift packages". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
#
# The step's notes, moved from nightly.yml:
# canonical-resolve copies the workspace to the canonical root and
# resolves there, so the workspace copy is still exactly what was
# restored. Save what the resolve wrote, or a fallback restore of an
# older layout is saved again under the current key.
set -euo pipefail
resolved="$CMUX_CI_CANONICAL_ROOT/src/.ci-source-packages"
test -d "$resolved/.package-cache"
rsync -a --delete "$resolved/" .ci-source-packages/
