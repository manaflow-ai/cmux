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
BUILD=0
DEVICE_ONLY=0

usage() {
  cat <<'EOF'
usage: scripts/verify-ish-ios-artifacts.sh [--build] [--device-only]

Verify the generated IshKernel.xcframework and checked-in Alpine fakefs.
--build provisions Meson/Ninja and runs scripts/build-ish-ios.sh when the
xcframework is missing, malformed, or lacks a requested slice.
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

NEEDS_BUILD=0
if [[ ! -d "$XCFRAMEWORK" ]]; then
  NEEDS_BUILD=1
elif [[ -L "$XCFRAMEWORK" ]]; then
  echo "error: IshKernel.xcframework must not be a symlink: $XCFRAMEWORK" >&2
  exit 1
elif [[ "$BUILD" -eq 1 ]]; then
  # A device-only cache entry is a valid artifact, but it cannot satisfy a
  # simulator build. Validate the complete framework shape here as well, so a
  # stale archive produced by an older builder is rebuilt instead of reaching
  # SwiftPM with a duplicate or misplaced module map.
  if ! python3 - "$XCFRAMEWORK" "$DEVICE_ONLY" "$ROOTFS" \
      "$ROOT/vendor/ish" \
      "$ROOT/Packages/iOS/CmuxLocalLinux/ShimSource" \
      "${CMUX_ISH_IOS_DEPLOYMENT_TARGET:-18.0}" <<'PY' >/dev/null 2>&1
import hashlib
import json
import plistlib
import subprocess
import sys
from pathlib import Path

xcframework = Path(sys.argv[1])
device_only = sys.argv[2] == "1"
rootfs = Path(sys.argv[3])
ish_dir = Path(sys.argv[4])
shim_dir = Path(sys.argv[5])
deployment_target = sys.argv[6]
try:
    info = plistlib.loads((xcframework / "Info.plist").read_bytes())
    rootfs_sha = hashlib.sha256(rootfs.read_bytes()).hexdigest()
    ish_revision = subprocess.check_output(
        ["git", "-C", str(ish_dir), "rev-parse", "HEAD"],
        text=True,
        stderr=subprocess.DEVNULL,
    ).strip()
    shim_paths = sorted(shim_dir.glob("*.c")) + sorted(shim_dir.glob("*.h"))
    if not shim_paths:
        raise OSError("no shim sources")
    shim_lines = "".join(
        f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}\n"
        for path in shim_paths
    )
    shim_sha = hashlib.sha256(shim_lines.encode("utf-8")).hexdigest()
except (OSError, ValueError, TypeError, subprocess.CalledProcessError):
    raise SystemExit(1)

required = {"ios-arm64"}
if not device_only:
    required.add("ios-arm64-simulator")
entries = {
    item.get("LibraryIdentifier"): item
    for item in info.get("AvailableLibraries", [])
    if isinstance(item, dict)
}
if not required.issubset(entries):
    raise SystemExit(1)
for identifier in required:
    entry = entries[identifier]
    library_path = entry.get("LibraryPath")
    binary_path = entry.get("BinaryPath")
    if not isinstance(library_path, str) or not library_path.endswith(".framework"):
        raise SystemExit(1)
    if not isinstance(binary_path, str) or binary_path != f"{library_path}/IshKernel":
        raise SystemExit(1)
    framework = xcframework / identifier / library_path
    binary = xcframework / identifier / binary_path
    header = framework / "Headers" / "cmux_ish.h"
    module_map = framework / "Modules" / "module.modulemap"
    sidecar = framework / "cmux-ish-provenance.json"
    if framework.is_symlink() or any(
        path.is_symlink() or not path.is_file()
        for path in (binary, header, module_map, sidecar)
    ):
        raise SystemExit(1)
    try:
        sidecar_data = json.loads(sidecar.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        raise SystemExit(1)
    expected_sidecar = {
        "format": "cmux-ish-provenance-v1",
        "ishCommit": ish_revision,
        "rootfsSHA256": rootfs_sha,
        "shimSHA256": shim_sha,
        "deploymentTarget": deployment_target,
        "slice": "iphoneos" if identifier == "ios-arm64" else "iphonesimulator",
        "architecture": "arm64",
    }
    if not isinstance(sidecar_data, dict) or any(
        sidecar_data.get(key) != value for key, value in expected_sidecar.items()
    ):
        raise SystemExit(1)
    if binary.stat().st_size == 0:
        raise SystemExit(1)
    try:
        archs = subprocess.check_output(
            ["xcrun", "lipo", "-archs", str(binary)],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip().split()
    except (OSError, subprocess.CalledProcessError):
        raise SystemExit(1)
    if archs != ["arm64"]:
        raise SystemExit(1)
    try:
        symbols = subprocess.check_output(
            ["xcrun", "nm", "-gU", str(binary)],
            text=True,
            stderr=subprocess.DEVNULL,
        )
    except (OSError, subprocess.CalledProcessError):
        raise SystemExit(1)
    if "_cmux_ish_boot" not in symbols:
        raise SystemExit(1)
PY
  then
    NEEDS_BUILD=1
  fi
fi

if [[ "$BUILD" -eq 1 && "$NEEDS_BUILD" -eq 1 ]]; then
  [[ -f "$ROOT/scripts/build-ish-ios.sh" && -x "$ROOT/scripts/build-ish-ios.sh" ]] || {
    echo "error: scripts/build-ish-ios.sh is missing" >&2
    exit 1
  }
  [[ -f "$ROOT/scripts/ensure-ish-build-tools.sh" && -x "$ROOT/scripts/ensure-ish-build-tools.sh" ]] || {
    echo "error: scripts/ensure-ish-build-tools.sh is missing; install Meson and Ninja with 'brew install meson ninja'" >&2
    exit 1
  }
  echo "==> IshKernel.xcframework is missing or lacks the requested slice; building it"
  tool_bin="$("$ROOT"/scripts/ensure-ish-build-tools.sh --bin-dir)"
  build_args=()
  if [[ "$DEVICE_ONLY" -eq 1 ]]; then
    build_args+=(--device-only)
  fi
  # The command-line mode is authoritative. A caller can have inherited
  # CMUX_ISH_DEVICE_ONLY=1 from an earlier device archive, but that must not
  # silently turn a full (device + simulator) verification into a device-only
  # build. Set the environment explicitly for the child process and explain
  # the override so the resulting slice set is deterministic.
  requested_device_only="$DEVICE_ONLY"
  if [[ -n "${CMUX_ISH_DEVICE_ONLY+x}" && "$CMUX_ISH_DEVICE_ONLY" != "$requested_device_only" ]]; then
    echo "warning: ignoring conflicting CMUX_ISH_DEVICE_ONLY=$CMUX_ISH_DEVICE_ONLY; verifier mode requires CMUX_ISH_DEVICE_ONLY=$requested_device_only" >&2
  fi
  CMUX_ISH_DEVICE_ONLY="$requested_device_only" PATH="$tool_bin:$PATH" \
    "$ROOT/scripts/build-ish-ios.sh" "${build_args[@]}"
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

python3 - "$XCFRAMEWORK" "$ROOTFS" "$PROVENANCE" "$ROOT/vendor/ish" \
  "$DEVICE_ONLY" "$ROOT/Packages/iOS/CmuxLocalLinux/ShimSource" \
  "${CMUX_ISH_IOS_DEPLOYMENT_TARGET:-18.0}" <<'PY'
from __future__ import annotations

import hashlib
import json
import plistlib
import subprocess
import sys
import tarfile
from pathlib import Path

xcframework, rootfs, provenance, ish_dir = map(Path, sys.argv[1:5])
device_only_flag = sys.argv[5] == "1"
shim_dir = Path(sys.argv[6])
deployment_target = sys.argv[7]

try:
    actual_ish_revision = subprocess.check_output(
        ["git", "-C", str(ish_dir), "rev-parse", "HEAD"], text=True
    ).strip()
except (OSError, subprocess.CalledProcessError) as exc:
    raise SystemExit(f"error: cannot read vendor/ish revision: {exc}") from exc

shim_paths = sorted(shim_dir.glob("*.c")) + sorted(shim_dir.glob("*.h"))
if not shim_paths:
    raise SystemExit(f"error: no cmux iSH shim sources under {shim_dir}")
shim_lines = "".join(
    f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}\n"
    for path in shim_paths
)
actual_shim_hash = hashlib.sha256(shim_lines.encode("utf-8")).hexdigest()

if not rootfs.is_file():
    raise SystemExit(f"error: missing rootfs resource: {rootfs}")
actual_hash = hashlib.sha256(rootfs.read_bytes()).hexdigest()

info_path = xcframework / "Info.plist"
if not info_path.is_file():
    raise SystemExit(f"error: missing xcframework metadata: {info_path}")
try:
    info = plistlib.loads(info_path.read_bytes())
except Exception as exc:
    raise SystemExit(f"error: invalid xcframework Info.plist: {exc}") from exc

libraries = info.get("AvailableLibraries")
if not isinstance(libraries, list) or not libraries:
    raise SystemExit("error: IshKernel.xcframework has no AvailableLibraries")

identifiers = {
    entry.get("LibraryIdentifier")
    for entry in libraries
    if isinstance(entry, dict)
}
required = {"ios-arm64"}
if not device_only_flag:
    required.add("ios-arm64-simulator")
missing = sorted(required - identifiers)
if missing:
    raise SystemExit(
        "error: IshKernel.xcframework is missing slice(s): "
        + ", ".join(missing)
        + ". Rebuild with ./scripts/build-ish-ios.sh"
    )

for entry in libraries:
    if not isinstance(entry, dict):
        raise SystemExit("error: malformed AvailableLibraries entry")
    identifier = entry.get("LibraryIdentifier")
    if identifier not in required:
        continue
    # Require a static framework. Packaging a bare archive with `-headers`
    # places every binary target's module map at a shared include path during
    # ProcessXCFramework. That path also belongs to GhosttyKit, so Xcode reports
    # duplicate output files. The framework layout keeps each module map inside
    # its own slice and is the only supported artifact shape.
    library_path = entry.get("LibraryPath")
    binary_path = entry.get("BinaryPath")
    if not isinstance(library_path, str) or not library_path.endswith(".framework"):
        raise SystemExit(f"error: incomplete metadata for {identifier}")
    if not isinstance(binary_path, str) or binary_path != f"{library_path}/IshKernel":
        raise SystemExit(f"error: incomplete metadata for {identifier}")
    framework = xcframework / identifier / library_path
    binary = xcframework / identifier / binary_path
    headers = framework / "Headers"
    module_map = framework / "Modules" / "module.modulemap"
    sidecar = framework / "cmux-ish-provenance.json"

    archive_header = headers / "cmux_ish.h"
    if framework.is_symlink() or headers.is_symlink() or module_map.is_symlink():
        raise SystemExit(f"error: {identifier} contains symlinked framework paths")
    for path in (binary, archive_header, module_map, sidecar):
        if path.is_symlink() or not path.is_file():
            raise SystemExit(f"error: {identifier} is missing {path}")
    try:
        sidecar_data = json.loads(sidecar.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise SystemExit(f"error: invalid provenance sidecar for {identifier}: {exc}") from exc
    expected_sidecar = {
        "format": "cmux-ish-provenance-v1",
        "ishCommit": actual_ish_revision,
        "rootfsSHA256": actual_hash,
        "shimSHA256": actual_shim_hash,
        "deploymentTarget": deployment_target,
        "slice": "iphoneos" if identifier == "ios-arm64" else "iphonesimulator",
        "architecture": "arm64",
    }
    if not isinstance(sidecar_data, dict):
        raise SystemExit(f"error: provenance sidecar for {identifier} is not an object")
    for key, expected in expected_sidecar.items():
        if sidecar_data.get(key) != expected:
            raise SystemExit(
                f"error: stale provenance for {identifier}, field {key!r} "
                f"is {sidecar_data.get(key)!r}, expected {expected!r}; "
                "rebuild with ./scripts/build-ish-ios.sh"
            )
    if binary.stat().st_size == 0:
        raise SystemExit(f"error: empty IshKernel binary: {binary}")
    try:
        archs = subprocess.check_output(
            ["xcrun", "lipo", "-archs", str(binary)],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip().split()
    except (OSError, subprocess.CalledProcessError) as exc:
        raise SystemExit(f"error: cannot inspect IshKernel architecture {binary}: {exc}") from exc
    if archs != ["arm64"]:
        raise SystemExit(
            f"error: IshKernel binary {binary} must contain only arm64, got {' '.join(archs) or '<none>'}"
        )
    try:
        symbols = subprocess.check_output(
            ["xcrun", "nm", "-gU", str(binary)],
            text=True,
            stderr=subprocess.DEVNULL,
        )
    except (OSError, subprocess.CalledProcessError) as exc:
        raise SystemExit(f"error: cannot inspect IshKernel binary {binary}: {exc}") from exc
    if "_cmux_ish_boot" not in symbols:
        raise SystemExit(f"error: {binary} does not export cmux_ish_boot")

metadata = json.loads(provenance.read_text(encoding="utf-8"))
if metadata.get("archive") != rootfs.name:
    raise SystemExit("error: rootfs provenance archive name does not match resource")
if metadata.get("sha256") != actual_hash:
    raise SystemExit(
        "error: Alpine rootfs SHA-256 mismatch: "
        f"expected {metadata.get('sha256')}, got {actual_hash}"
    )

expected_packages = metadata.get("packages")
if not isinstance(expected_packages, list) or not expected_packages:
    raise SystemExit("error: rootfs provenance has no package manifest")
try:
    with tarfile.open(rootfs, "r:gz") as archive:
        installed_member = next(
            (
                member
                for member in archive.getmembers()
                if member.name.lstrip("./") == "lib/apk/db/installed"
            ),
            None,
        )
        if installed_member is None:
            raise SystemExit("error: rootfs has no Alpine package database")
        installed_stream = archive.extractfile(installed_member)
        if installed_stream is None:
            raise SystemExit("error: cannot read Alpine package database")
        records: dict[str, dict[str, str]] = {}
        record: dict[str, str] = {}
        for line in installed_stream.read().decode("utf-8").splitlines() + [""]:
            if not line:
                name = record.get("P")
                if name:
                    records[name] = record
                record = {}
                continue
            key, separator, value = line.partition(":")
            if separator:
                record[key] = value
except tarfile.TarError as exc:
    raise SystemExit(f"error: invalid Alpine rootfs archive: {exc}") from exc

for package in expected_packages:
    if not isinstance(package, dict):
        raise SystemExit("error: malformed rootfs package manifest entry")
    name = package.get("name")
    actual = records.get(name)
    if actual is None:
        raise SystemExit(f"error: rootfs package manifest names missing package {name!r}")
    for field, key in (("version", "V"), ("license", "L")):
        if package.get(field) != actual.get(key):
            raise SystemExit(
                f"error: rootfs package {name!r} {field} mismatch: "
                f"expected {package.get(field)!r}, got {actual.get(key)!r}"
            )

expected_ish_revision = metadata.get("ish_revision")
if not isinstance(expected_ish_revision, str) or not expected_ish_revision:
    raise SystemExit("error: rootfs provenance has no iSH revision")
if actual_ish_revision != expected_ish_revision:
    raise SystemExit(
        "error: rootfs was generated with iSH revision "
        f"{expected_ish_revision}, but vendor/ish is {actual_ish_revision}; "
        "regenerate the rootfs or update its provenance"
    )

print(
    "IshKernel artifacts OK: "
    + ", ".join(sorted(required))
    + f"; rootfs sha256={actual_hash}"
)
PY
