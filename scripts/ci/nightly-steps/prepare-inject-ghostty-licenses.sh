#!/usr/bin/env bash
# nightly.yml prepare-nightly-variant-primary: "Inject the Ghostty dependency licenses (cmux-next)". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
#
# The step's notes, moved from nightly.yml:
# The Ghostty dependency license tree (collect-ghostty-licenses.py, checked
# by verify-ghostty-license-bundle.py) ships in the app, with the MPL-2.0
# source offer that names this release's cmux-next source archive and tag.
set -euo pipefail
APP_DIR="build-universal/Build/Products/Release/cmux.app"
tree="nightly-inputs/license-trees/ghostty-licenses"
python3 cmux-tui/build-support/notices/ghostty/verify-ghostty-license-bundle.py \
  --root "$tree" --revision "$(git rev-parse HEAD:ghostty)"
rm -rf "$APP_DIR/Contents/Resources/ghostty-licenses"
cp -R "$tree" "$APP_DIR/Contents/Resources/ghostty-licenses"
# bin/cmux's libghostty-vt: the submodule ghostty-vt-sys's build.rs
# selects, at this commit's gitlink (the resolved cmux-tui client
# commit has the same cmux-tui tree and gitlinks: pin-cmux-tui.sh key).
# Today: Contents/Resources/ghostty-next-licenses.
vt="$(python3 scripts/cmux-next/notices/check_ghostty_vt_notices.py --print-source | sed -n 's/^libghostty-vt source: //p')"
vt_name="${vt%% *}" vt_revision="${vt##* }"
if [[ "$vt_name" != ghostty ]]; then
  next_tree="nightly-inputs/license-trees/$vt_name-licenses"
  python3 cmux-tui/build-support/notices/ghostty/verify-ghostty-license-bundle.py \
    --root "$next_tree" --revision "$vt_revision"
  rm -rf "$APP_DIR/Contents/Resources/$vt_name-licenses"
  cp -R "$next_tree" "$APP_DIR/Contents/Resources/$vt_name-licenses"
fi
