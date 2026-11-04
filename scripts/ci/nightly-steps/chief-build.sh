#!/usr/bin/env bash
# nightly.yml build-nightly-app: "Build the OptChat Chief (cmux-next)". Moved out of the workflow to keep
# nightly.yml under GitHub's workflow file size limit; the step's env: still sets every input.
# The Home Chief's brain host (Native/OptChat/optchat-chief) ships in the
# cmux-next nightly only: this step builds it for the "Bundle
# optchat-chief" phase script, which copies it to Resources/bin, and
# build-sign-notarize-nightly signs it with the app's Developer ID and
# hardened runtime (sign-cmux-bundle-helpers.sh signs every Mach-O
# there). Main's nightly, RC and stable never set the variable, so they
# bundle nothing, and the app starts the bundled Chief only on DEV and
# NIGHTLY bundle ids (HomeBrainHost.bundledChiefAllowed).
set -euo pipefail
chief_bin="$RUNNER_TEMP/cmux-next-optchat-chief/optchat-chief"
# A trusted NEXT worker keeps Chief binaries keyed by their inputs
# (optchat-chief-input-key.py: the path-dependency closure, the
# committed inspector page, toolchain, SDK and cargo settings), so
# a push that changes none of them skips cargo. The step took 90-114 s
# on every build (runs 39349353760 to 39374887542); about 6 in 10
# consecutive promotions on 2026-10-19/20 left these inputs unchanged.
export CMUX_NEXT_OPTCHAT_CHIEF_INPUT_KEYED=1
if [[ -z "${CMUX_NEXT_OPTCHAT_CHIEF_CACHE:-}" ]]; then
  case "${RUNNER_NAME:-}" in
    *-glaeda|*-glaeda-[0-9]*)
      export CMUX_NEXT_OPTCHAT_CHIEF_CACHE="$HOME/Library/Caches/cmux-nightly-next/$RUNNER_NAME/caches/optchat-chief"
      ;;
  esac
fi
# It builds in the background, beside the Release build (it took 90 to
# 176 s of this job's serial path): "Bundle the OptChat Chief and the
# iPhone host" joins it after xcodebuild and copies it in with the
# Xcode phase's own script. Install its toolchain and targets, and the
# iPhone host's, here first, so no two background builds install into
# one toolchain at once (both scripts then find them in place).
toolchain="$(sed -n 's/^channel *= *"\(.*\)"/\1/p' cmux-tui/rust-toolchain.toml)"
rustup toolchain install "$toolchain" --profile minimal >/dev/null
# shellcheck source=scripts/lib/rust-targets.sh
source scripts/lib/rust-targets.sh
ensure_rust_targets --toolchain "$toolchain" aarch64-apple-darwin x86_64-apple-darwin >/dev/null
(cd cmux-next-ios/rust && ensure_rust_targets aarch64-apple-darwin x86_64-apple-darwin >/dev/null)
python3 scripts/ci/background_build.py start --state "$RUNNER_TEMP/nightly-helper-builds" optchat-chief -- \
  nice -n 10 env CMUX_NEXT_OPTCHAT_CHIEF_ARCHS="$NIGHTLY_COMPILE_ARCHS" scripts/cmux-next/build-optchat-chief.sh --output "$chief_bin"
echo "CMUX_NEXT_OPTCHAT_CHIEF_PENDING_BIN=$chief_bin" >> "$GITHUB_ENV"
# The built-in full uBlock Origin must be in every nightly-next build (bundle-ublock.sh).
echo "CMUX_NEXT_REQUIRE_UBLOCK=1" >> "$GITHUB_ENV"
