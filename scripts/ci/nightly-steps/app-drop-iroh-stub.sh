#!/usr/bin/env bash
# nightly.yml build-nightly-app: "Drop the empty Iroh.framework stub (nightly-next)". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
#
# The step's notes, moved from nightly.yml:
# In Release Xcode merges iroh-ffi's static code into Contents/MacOS/cmux
# and still embeds Iroh.framework: a 35 KB stub (only __TEXT and
# __LINKEDIT, no exported symbol) that no binary of the app loads (otool
# -L of build 3939848657701), and whose LC_ID_DYLIB is a random
# swbuild.tmp folder, so its bytes differ in every build. The app
# launched without it (nx-remote job 1020-050356-5d14cf). Drop it; the
# hosted sign job signs the app afterwards. The checks refuse a
# framework that exports code or that something loads.
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
