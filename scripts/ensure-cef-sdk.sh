#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CEF_DIR="${PROJECT_DIR}/CEF"
FRAMEWORKS_DIR="${CEF_DIR}/Frameworks"
LOCKFILE="${CEF_DIR}/vendor/cef.lock.json"
STAMP_FILE="${FRAMEWORKS_DIR}/.cmux-cef-sdk.lock.sha256"
LOCK_SHA256="$(shasum -a 256 "${LOCKFILE}" | awk '{print $1}')"

if [[ -f "${FRAMEWORKS_DIR}/include/cef_app.h" \
  && -f "${FRAMEWORKS_DIR}/libcef_dll_wrapper.a" \
  && -d "${FRAMEWORKS_DIR}/Chromium Embedded Framework.framework" \
  && -f "${STAMP_FILE}" \
  && "$(cat "${STAMP_FILE}")" == "${LOCK_SHA256}" ]]; then
  echo "ensure-cef-sdk: CEF SDK already provisioned"
  exit 0
fi

if [[ -d "${FRAMEWORKS_DIR}" || -d "${CEF_DIR}/CEF" ]]; then
  echo "ensure-cef-sdk: CEF SDK missing current lock provenance; reprovisioning"
  rm -rf "${FRAMEWORKS_DIR}" "${CEF_DIR}/CEF"
fi

echo "ensure-cef-sdk: provisioning CEF SDK"
"${CEF_DIR}/vendor/fetch_cef.sh"
