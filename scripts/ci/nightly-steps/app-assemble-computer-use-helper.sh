#!/usr/bin/env bash
# nightly.yml build-nightly-app: "Assemble the Computer Use helper". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
#
# The step's notes, moved from nightly.yml:
# The Computer Use helper that onboarding grants (cx-urd.6, D19). Only a
# com.cmuxterm.cua app at Contents/Library with the team's Developer ID
# signature is used, so it is assembled here for Codesign apps to sign and
# notarize-nightly-dmg.sh to notarize. It builds with the reviewed rustc
# that cmux-tui pins: the notices check (rust-std) needs a reviewed rustc.
set -euo pipefail
app="build-universal/Build/Products/Release/cmux.app"
toolchain="$(sed -n 's/^channel = "\(.*\)"$/\1/p' cmux-tui/rust-toolchain.toml)"
rustup toolchain install "$toolchain" --profile minimal
# Only the slices a variant ships: nightly-next and fast builds are arm64.
archs="${HELPER_ARCHS}"
RUSTUP_TOOLCHAIN="$toolchain" ./scripts/build-cmux-cua.sh \
  --output "$app/Contents/Resources/bin/cmux-cua" --helper-app --archs "$archs"
# The helper app is what ships; build-cmux-cua.sh's bin copy is scratch.
rm -f "$app/Contents/Resources/bin/cmux-cua" "$app/Contents/Resources/bin/cmux-cua-LICENSE.md"
./scripts/ci/verify-computer-use-helper.sh layout "$app"
