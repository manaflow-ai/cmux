#!/usr/bin/env bash
# nightly.yml prepare-nightly-variant-primary: "Verify nightly binary architectures". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
set -euo pipefail
APP="build-universal/Build/Products/Release/cmux.app"
for binary in \
  "$APP/Contents/MacOS/cmux" \
  "$APP/Contents/Resources/bin/cmux" \
  "$APP/Contents/Resources/bin/ghostty" \
  "$APP/Contents/Resources/bin/cmux-diff-sidecar" \
  "$APP/Contents/Library/cmux Computer Use.app/Contents/MacOS/cmux-cua"
do
  archs="$(lipo -archs "$binary")"
  echo "$binary: $archs"
  if [ "$NIGHTLY_VARIANT" = "universal" ]; then
    [[ "$archs" == *arm64* && "$archs" == *x86_64* ]]
  else
    [ "$archs" = "$NIGHTLY_VARIANT" ]
  fi
done
# The cmux-next nightly carries the OptChat Chief with the app's slices.
if [[ "$CHANNEL_RELEASE_TAG" == "nightly-next" ]]; then
  for helper in optchat-chief cmux-mobile-host; do
    binary="$APP/Contents/Resources/bin/$helper"
    [ -x "$binary" ] || { echo "nightly-next is missing bin/$helper" >&2; exit 1; }
    archs="$(lipo -archs "$binary")"
    echo "$binary: $archs"
    if [ "$NIGHTLY_VARIANT" = "universal" ]; then
      [[ "$archs" == *arm64* && "$archs" == *x86_64* ]]
    else
      [ "$archs" = "$NIGHTLY_VARIANT" ]
    fi
  done
fi
# bin/cmux is the cmux-tui binary; cmux-tui and acpmux are symlinks to it.
for alias in cmux-tui acpmux; do
  [ "$(readlink "$APP/Contents/Resources/bin/$alias")" = cmux ] || {
    echo "bin/$alias is not a symlink to cmux" >&2; exit 1; }
done
if [ "$NIGHTLY_VARIANT" != "universal" ]; then
  # No fat Mach-O may survive thinning anywhere in the bundle.
  # Only files with a Mach-O or fat magic reach `file` (one process
  # each); the per-file scan of the whole bundle took 90 s. A missing or failing
  # `file` fails the check rather than reading as "no fat file".
  command -v file >/dev/null || { [ "$RUNNER_OS" = Linux ] && sudo apt-get install -y -qq file >/dev/null; } || true
  command -v file >/dev/null || { echo "file(1) is missing; cannot check for fat Mach-O" >&2; exit 1; }
  fat="$(find "$APP" -type f -print0 | python3 scripts/list-macho-candidates.py \
    | xargs -0 sh -c 'for f do k="$(file -b "$f")" || exit 255; case "$k" in *"Mach-O universal"*) echo "$f";; esac; done' sh)"
  if [ -n "$fat" ]; then
    echo "Fat Mach-O files remain after thinning:" >&2
    echo "$fat" >&2
    exit 1
  fi
fi
# The diff sidecar's static Mach-O checks and its
# handshake run on the signed app in verify-signed-nightly.
