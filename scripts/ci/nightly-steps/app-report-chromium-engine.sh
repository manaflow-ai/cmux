#!/usr/bin/env bash
# nightly.yml build-nightly-app: "Report the embedded Chromium engine". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
set -euo pipefail
app="build-universal/Build/Products/Release/cmux.app"
# An app built for the fleet benches keeps the debug.* commands; it never ships.
./scripts/cmux-next/check-no-bench-hooks.sh "$app"
framework="$app/Contents/Frameworks/Chromium Embedded Framework.framework"
if [[ -d "$framework" ]]; then
  echo "Chromium engine embedded: $(lipo -archs "$framework/Versions/A/Chromium Embedded Framework")"
  # Chromium's license notices must ship with the engine (not CEF's sample page).
  ./scripts/cmux-next/check-cef-credits.sh "$app"
else
  echo "::warning title=No Chromium engine::The CEF artifact was not readable (secrets CMUX_CEF_R2_*); this build ships the browser as unavailable."
fi
