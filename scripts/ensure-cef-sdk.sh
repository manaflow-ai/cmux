#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CEF_DIR="${PROJECT_DIR}/CEF"
FRAMEWORKS_DIR="${CEF_DIR}/Frameworks"

if [[ -f "${FRAMEWORKS_DIR}/include/cef_app.h" \
  && -f "${FRAMEWORKS_DIR}/libcef_dll_wrapper.a" \
  && -d "${FRAMEWORKS_DIR}/Chromium Embedded Framework.framework" ]]; then
  echo "ensure-cef-sdk: CEF SDK already provisioned"
  exit 0
fi

echo "ensure-cef-sdk: provisioning CEF SDK"
"${CEF_DIR}/vendor/fetch_cef.sh"
