#!/usr/bin/env bash
# Install AXe (the iOS simulator accessibility and HID CLI) on a macOS CI runner
# and put it on PATH for later steps (GITHUB_PATH). Prints the directory that
# holds `axe` on stdout, for a step that runs it at once:
#   PATH="$(scripts/install-axe-ci.sh):$PATH"
#
# Not `brew install cameroncooke/axe/axe`: the tap's formula uses a post-install
# DSL the runners' Homebrew refuses ("undefined method 'run' for an instance of
# Homebrew::InstallSteps::DSL", ios-e2e job 132861077367). This installs the
# formula's pinned archive the way the formula does: unpack, then sign the
# frameworks and the executable that loads them, since the archive ships
# unsigned.
set -euo pipefail

AXE_URL="${AXE_URL:-https://github.com/cameroncooke/AXe/releases/download/v2.0.4/AXe-macOS-homebrew-v2.0.4.tar.gz}"
AXE_SHA256="${AXE_SHA256:-4997a7305814d1bcbb925bf1f81667177e204fe58855d99c4896b85d749e181a}"

if existing="$(command -v axe)"; then
  axe --version >&2
  dirname "$existing"
  exit 0
fi

tmp="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
axe_dir="$(mktemp -d "$tmp/axe.XXXXXX")"
archive="$axe_dir/axe.tar.gz"
curl -fsSL --retry 3 -o "$archive" "$AXE_URL"
echo "$AXE_SHA256  $archive" | shasum -a 256 --check --strict >&2
tar -xzf "$archive" -C "$axe_dir"
axe_bin="$(find "$axe_dir" -maxdepth 2 -type f -name axe | head -n 1)"
if [ -z "$axe_bin" ]; then
  echo "::error::[infra-preflight] the AXe archive has no axe executable ($AXE_URL)" >&2
  exit 1
fi
axe_home="$(dirname "$axe_bin")"
codesign --force --sign - --timestamp=none \
  "$axe_home/Frameworks/FBControlCore.framework" \
  "$axe_home/Frameworks/FBSimulatorControl.framework" \
  "$axe_bin" >&2
"$axe_bin" --version >&2
if [ -n "${GITHUB_PATH:-}" ]; then
  echo "$axe_home" >> "$GITHUB_PATH"
fi
echo "$axe_home"
