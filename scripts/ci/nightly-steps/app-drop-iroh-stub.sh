#!/usr/bin/env bash
# nightly.yml build-nightly-app: "Drop the empty Iroh.framework stub (nightly-next)". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
set -euo pipefail
app="build-universal/Build/Products/Release/cmux.app"
fw="$app/Contents/Frameworks/Iroh.framework"
[ -d "$fw" ] || { echo "no Iroh.framework in $app"; exit 0; }
bin="$fw/Versions/A/Iroh"
[ -f "$bin" ] || { echo "::error::no $bin; not the known stub layout"; exit 1; }
if [ -n "$(nm -gU "$bin" 2>/dev/null || true)" ]; then
  echo "::error::Iroh.framework exports symbols; it is not the Release stub"
  exit 1
fi
loaders="$(find "$app" -type f -perm +111 ! -path "$fw/*" -print0 \
  | xargs -0 otool -L 2>/dev/null | grep -F "Iroh.framework" || true)"
if [ -n "$loaders" ]; then
  echo "::error::a binary in the app loads Iroh.framework"
  echo "$loaders"
  exit 1
fi
echo "Removing the Iroh.framework stub (install name $(otool -D "$bin" | tail -n 1))"
rm -rf "$fw"
