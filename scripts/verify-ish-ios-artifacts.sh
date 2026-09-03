#!/usr/bin/env bash
# Verify the generated iSH xcframework and the checked-in Alpine fakefs before
# SwiftPM resolves CmuxLocalLinux. The xcframework is deliberately generated
# locally, so a clean checkout must either run --build or report this command.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
XCFRAMEWORK="$ROOT/IshKernel.xcframework"
ROOTFS="$ROOT/Packages/iOS/CmuxLocalLinux/Sources/CmuxLocalLinux/Resources/alpine-rootfs.tar.gz"
PROVENANCE="$ROOT/Packages/iOS/CmuxLocalLinux/Sources/CmuxLocalLinux/Resources/alpine-rootfs.json"
VALIDATOR="$ROOT/scripts/verify-ish-ios-artifacts.py"
BUILD=0
DEVICE_ONLY=0

usage() {
  cat <<'EOF'
usage: scripts/verify-ish-ios-artifacts.sh [--build] [--device-only]

Verify the generated IshKernel.xcframework and checked-in Alpine fakefs.
--build provisions Meson/Ninja plus LLVM clang/lld and runs
scripts/build-ish-ios.sh when the xcframework is missing, malformed, or lacks
a requested slice.
--device-only accepts an xcframework without the simulator arm64 slice.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build) BUILD=1; shift ;;
    --device-only) DEVICE_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ ! -f "$VALIDATOR" ]]; then
  echo "error: missing $VALIDATOR" >&2
  exit 1
fi

VALIDATOR_ARGS=(
  --xcframework "$XCFRAMEWORK"
  --rootfs "$ROOTFS"
  --provenance "$PROVENANCE"
  --ish-dir "$ROOT/vendor/ish"
  --shim-dir "$ROOT/Packages/iOS/CmuxLocalLinux/ShimSource"
  --deployment-target "${CMUX_ISH_IOS_DEPLOYMENT_TARGET:-18.0}"
)
if [[ "$DEVICE_ONLY" -eq 1 ]]; then
  VALIDATOR_ARGS+=(--device-only)
fi

run_validator() {
  local quiet="$1"
  if [[ "$quiet" -eq 1 ]]; then
    python3 "$VALIDATOR" "${VALIDATOR_ARGS[@]}" --quiet
  else
    python3 "$VALIDATOR" "${VALIDATOR_ARGS[@]}"
  fi
}

NEEDS_BUILD=0
if [[ ! -d "$XCFRAMEWORK" ]]; then
  NEEDS_BUILD=1
elif [[ -L "$XCFRAMEWORK" ]]; then
  echo "error: IshKernel.xcframework must not be a symlink: $XCFRAMEWORK" >&2
  exit 1
elif [[ "$BUILD" -eq 1 ]]; then
  # A device-only cache entry is a valid artifact, but it cannot satisfy a
  # simulator build. Validate the complete library shape here as well, so a
  # stale archive produced by an older builder is rebuilt instead of reaching
  # SwiftPM with a duplicate or misplaced module map.
  if ! run_validator 1 >/dev/null 2>&1; then
    NEEDS_BUILD=1
  fi
fi

if [[ "$BUILD" -eq 1 && "$NEEDS_BUILD" -eq 1 ]]; then
  [[ -f "$ROOT/scripts/build-ish-ios.sh" && -x "$ROOT/scripts/build-ish-ios.sh" ]] || {
    echo "error: scripts/build-ish-ios.sh is missing" >&2
    exit 1
  }
  [[ -f "$ROOT/scripts/ensure-ish-build-tools.sh" && -x "$ROOT/scripts/ensure-ish-build-tools.sh" ]] || {
    echo "error: scripts/ensure-ish-build-tools.sh is missing; install Meson, Ninja, LLVM, and lld with 'brew install meson ninja llvm lld'" >&2
    exit 1
  }
  echo "==> IshKernel.xcframework is missing or lacks the requested slice; building it"
  tool_bin="$("$ROOT"/scripts/ensure-ish-build-tools.sh --bin-dir)"
  # The command-line mode is authoritative. A caller can have inherited
  # CMUX_ISH_DEVICE_ONLY=1 from an earlier device archive, but that must not
  # silently turn a full (device + simulator) verification into a device-only
  # build. Set the environment explicitly for the child process and explain
  # the override so the resulting slice set is deterministic.
  requested_device_only="$DEVICE_ONLY"
  if [[ -n "${CMUX_ISH_DEVICE_ONLY+x}" && "$CMUX_ISH_DEVICE_ONLY" != "$requested_device_only" ]]; then
    echo "warning: ignoring conflicting CMUX_ISH_DEVICE_ONLY=$CMUX_ISH_DEVICE_ONLY; verifier mode requires CMUX_ISH_DEVICE_ONLY=$requested_device_only" >&2
  fi
  if [[ "$DEVICE_ONLY" -eq 1 ]]; then
    CMUX_ISH_DEVICE_ONLY="$requested_device_only" PATH="$tool_bin:$PATH" \
      "$ROOT/scripts/build-ish-ios.sh" --device-only
  else
    # Keep the no-argument form explicit. Bash 3.2 with `set -u` can treat an
    # empty `${array[@]}` expansion as an unset value.
    CMUX_ISH_DEVICE_ONLY="$requested_device_only" PATH="$tool_bin:$PATH" \
      "$ROOT/scripts/build-ish-ios.sh"
  fi
fi

if [[ ! -d "$XCFRAMEWORK" ]]; then
  echo "error: missing $XCFRAMEWORK" >&2
  echo "Run: ./scripts/build-ish-ios.sh" >&2
  exit 1
fi

if [[ ! -d "$ROOT/vendor/ish" || ! -f "$ROOT/vendor/ish/meson.build" ]]; then
  echo "error: vendor/ish is not initialized" >&2
  echo "Run: git submodule update --init --recursive vendor/ish" >&2
  exit 1
fi

# The sidecars identify the iSH tree by commit. Reject a dirty submodule so a
# locally patched binary cannot be mistaken for the public commit named in its
# provenance. Developers can commit the patch on the in-org iSH fork first.
ISH_STATUS="$(git -C "$ROOT/vendor/ish" status --porcelain=v1 --untracked-files=all --ignore-submodules=none 2>/dev/null)" || {
  echo "error: cannot inspect vendor/ish working tree" >&2
  exit 1
}
if [[ -n "$ISH_STATUS" ]]; then
  echo "$ISH_STATUS" >&2
  echo "error: vendor/ish has local changes; commit them before using a provenance-tracked artifact" >&2
  exit 1
fi

if [[ -L "$ROOTFS" || -L "$PROVENANCE" ]]; then
  echo "error: CmuxLocalLinux rootfs resources must not be symlinks" >&2
  exit 1
fi
if [[ ! -f "$ROOTFS" || ! -f "$PROVENANCE" ]]; then
  echo "error: CmuxLocalLinux rootfs resource or provenance is missing" >&2
  echo "Expected: $ROOTFS" >&2
  exit 1
fi

run_validator 0
