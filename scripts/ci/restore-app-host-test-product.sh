#!/usr/bin/env bash
set -euo pipefail
archive="$RUNNER_TEMP/app-host-products/app-host-products.tar.gz"
echo "$EXPECTED_SHA256  $archive" | shasum -a 256 -c -
tar -xzf "$archive" -C "$CMUX_DERIVED_DATA_PATH"
products="$CMUX_DERIVED_DATA_PATH/Build/Products/Debug"
stable="$RUNNER_TEMP/cmux-app-host-package-frameworks"
stable_system="/private/tmp/cmux-app-host-package-frameworks"
mkdir -p "$stable"
framework_source="$(find "$products" -type d -name 'CmuxAgentJournal*_PackageProduct.framework' -print -quit 2>/dev/null || true)"
test -n "$framework_source"
rsync -aL "$(dirname "$framework_source")/" "$stable/"
mkdir -p "$stable_system"
rsync -aL "$(dirname "$framework_source")/" "$stable_system/"
if [ -L "$products/PackageFrameworks" ]; then
  rm "$products/PackageFrameworks"
fi
mkdir -p "$products/PackageFrameworks"
framework_source="$(find "$products" -type d -name 'CmuxAgentJournal*_PackageProduct.framework' -print -quit 2>/dev/null || true)"
test -n "$framework_source"
rsync -aL "$(dirname "$framework_source")/" "$products/PackageFrameworks/"
test -f "$products/PackageFrameworks/CmuxAgentJournal_27B6EF8727F6C277_PackageProduct.framework/Versions/A/CmuxAgentJournal_27B6EF8727F6C277_PackageProduct"
python3 scripts/ci/app_host_test_products.py restore "$CMUX_DERIVED_DATA_PATH"
