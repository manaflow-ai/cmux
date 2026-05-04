#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
DIST_DIR="$ROOT_DIR/dist"
PACKAGE_NAME="cmux-linux-x86_64"
STAGING_DIR="$DIST_DIR/$PACKAGE_NAME"
PROJECT_FILE="$ROOT_DIR/GhosttyTabs.xcodeproj/project.pbxproj"
PYTHON_BIN="${CMUX_PYTHON:-python3}"
PACKAGE_PYCACHE_PREFIX="${CMUX_PYTHONPYCACHEPREFIX:-${PYTHONPYCACHEPREFIX:-$DIST_DIR/.pycache}}"

if [ -z "${CMUX_LINUX_SKIP_TARBALL:-}" ]; then
  bash "$ROOT_DIR/linux/package.sh"
fi

if ! command -v rpmbuild >/dev/null 2>&1; then
  echo "rpmbuild is required to build the cmux Linux rpm package" >&2
  exit 1
fi
if ! command -v rpm2cpio >/dev/null 2>&1; then
  echo "rpm2cpio is required to validate the cmux Linux rpm package" >&2
  exit 1
fi

VERSION="${CMUX_LINUX_VERSION:-}"
if [ -z "$VERSION" ] && [ -f "$PROJECT_FILE" ]; then
  VERSION=$(grep -m1 'MARKETING_VERSION = ' "$PROJECT_FILE" | sed -E 's/.*= ([^;]+);/\1/')
fi
VERSION="${VERSION:-0.0.0}"
RPM_VERSION="${CMUX_LINUX_RPM_VERSION:-$(printf '%s' "$VERSION" | sed -E 's/[^A-Za-z0-9._+~]/_/g')}"
RPM_RELEASE="${CMUX_LINUX_RPM_RELEASE:-1}"
RPMBUILD_DIR="$DIST_DIR/rpmbuild"
SPEC_PATH="$RPMBUILD_DIR/SPECS/cmux-linux.spec"
RPM_PATH="$DIST_DIR/cmux-linux-${RPM_VERSION}-${RPM_RELEASE}.x86_64.rpm"

REMOTE_DAEMON_FLAG=""
REMOTE_FILE_ENTRY=""
if [ -f "$STAGING_DIR/bin/cmuxd-remote" ]; then
  REMOTE_DAEMON_FLAG="--remote-daemon-included"
  REMOTE_FILE_ENTRY="%{_bindir}/cmuxd-remote"
fi

SWIFT_CLI_FLAG=""
if ! head -c 2 "$STAGING_DIR/bin/cmux" | grep -q '#!'; then
  SWIFT_CLI_FLAG="--swift-cli-included"
fi
VALIDATOR_FLAGS=()
if [ -n "$REMOTE_DAEMON_FLAG" ]; then
  VALIDATOR_FLAGS+=("--require-remote-daemon")
  VALIDATOR_FLAGS+=("--probe-remote-daemon")
fi
if [ -n "$SWIFT_CLI_FLAG" ]; then
  VALIDATOR_FLAGS+=("--require-swift-cli")
fi

rm -rf "$RPMBUILD_DIR" "$RPM_PATH"
mkdir -p "$RPMBUILD_DIR/BUILD" "$RPMBUILD_DIR/BUILDROOT" "$RPMBUILD_DIR/RPMS" "$RPMBUILD_DIR/SOURCES" "$RPMBUILD_DIR/SPECS" "$RPMBUILD_DIR/SRPMS"
tar -C "$DIST_DIR" -czf "$RPMBUILD_DIR/SOURCES/$PACKAGE_NAME.tar.gz" "$PACKAGE_NAME"

cat > "$SPEC_PATH" <<SPEC
Name: cmux-linux
Version: $RPM_VERSION
Release: $RPM_RELEASE%{?dist}
Summary: cmux Linux runtime
License: Proprietary
URL: https://cmuxterm.com
Source0: $PACKAGE_NAME.tar.gz
AutoReqProv: no
Requires: python3

%description
cmux Linux GTK runtime, CLI, Python libraries, desktop integration, and socket API bridge.

%prep
%setup -q -n $PACKAGE_NAME

%build

%install
rm -rf %{buildroot}
mkdir -p %{buildroot}%{_prefix} %{buildroot}%{_docdir}/cmux
cp -a bin lib share %{buildroot}%{_prefix}/
cp README.md %{buildroot}%{_docdir}/cmux/README.md
PYTHONPYCACHEPREFIX="$PACKAGE_PYCACHE_PREFIX" "$PYTHON_BIN" "$ROOT_DIR/linux/tools/write_package_manifest.py" "%{buildroot}%{_prefix}" --distribution rpm $REMOTE_DAEMON_FLAG $SWIFT_CLI_FLAG

%files
%{_bindir}/cmux-linux
%{_bindir}/cmux
$REMOTE_FILE_ENTRY
%{_prefix}/lib/cmux_linux
%{_datadir}/applications/com.cmuxterm.cmux.desktop
%{_datadir}/cmux/package-manifest.json
%{_docdir}/cmux/README.md
SPEC

rpmbuild -bb --define "_topdir $RPMBUILD_DIR" "$SPEC_PATH" >/dev/null
BUILT_RPM=$(find "$RPMBUILD_DIR/RPMS" -type f -name '*.rpm' -print -quit)
if [ -z "$BUILT_RPM" ]; then
  echo "rpmbuild did not produce an rpm artifact" >&2
  exit 1
fi
cp "$BUILT_RPM" "$RPM_PATH"
PYTHONPYCACHEPREFIX="$PACKAGE_PYCACHE_PREFIX" "$PYTHON_BIN" "$ROOT_DIR/linux/tools/validate_package.py" "$RPM_PATH" "${VALIDATOR_FLAGS[@]}"
printf 'Linux rpm package: %s\n' "$RPM_PATH"
