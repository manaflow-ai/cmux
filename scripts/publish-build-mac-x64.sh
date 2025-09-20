#!/usr/bin/env bash
set -euo pipefail

# CI macOS x64 build + sign + notarize for Electron app
# Mirrors the steps in .github/workflows/release-updates.yml (mac-x64 job) without reusing local scripts

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLIENT_DIR="$ROOT_DIR/apps/client"
ENTITLEMENTS="$CLIENT_DIR/build/entitlements.mac.plist"
DIST_DIR="$CLIENT_DIR/dist-electron"

ARCH_EXPECTED="x86_64"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--env-file path] [--skip-install]

Builds, signs, notarizes macOS x64 DMG/ZIP locally.

Required env vars for signing + notarization:
  MAC_CERT_BASE64        Base64-encoded .p12 certificate
  MAC_CERT_PASSWORD      Password for the .p12 certificate
  APPLE_API_KEY          Apple API key (path or content as supported by electron-builder)
  APPLE_API_KEY_ID       Apple API Key ID
  APPLE_API_ISSUER       Apple API Issuer ID (UUID)

Optional env vars:
  DEBUG                  Set to 'electron-osx-sign*,electron-notarize*' for verbose logs

Options:
  --env-file path        Source environment variables from a file before running
  --skip-install         Skip 'bun install --frozen-lockfile'

Notes:
  - This script publishes to GitHub Releases when repository credentials are available.
  - It mirrors workflow steps: generate icons, prepare entitlements, prebuild app,
    then package with electron-builder (sign + notarize), and staple/verify outputs.
EOF
}

ENV_FILE=""
SKIP_INSTALL=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --env-file)
      ENV_FILE="${2:-}"
      if [[ -z "$ENV_FILE" ]]; then
        echo "--env-file requires a path" >&2
        exit 1
      fi
      shift 2
      ;;
    --skip-install)
      SKIP_INSTALL=true
      shift
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

sanitize_id_like_env_var() {
  local var_name="$1"
  local value="${!var_name:-}"
  if [[ -n "$value" ]]; then
    value="$(printf '%s' "$value" | tr -d "[:space:]\"'")"
    export "$var_name"="$value"
  fi
}

prepare_apple_api_key_file() {
  if [[ -z "${APPLE_API_KEY:-}" ]]; then
    return
  fi

  if [[ -f "${APPLE_API_KEY}" ]]; then
    return
  fi

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  local key_path
  key_path="$tmp_dir/AuthKey_${APPLE_API_KEY_ID:-api}.p8"

  python3 - "$key_path" <<'PY'
import base64
import binascii
import os
import pathlib
import sys

raw = os.environ.get("APPLE_API_KEY", "")
dest = pathlib.Path(sys.argv[1])

if not raw:
    sys.exit("APPLE_API_KEY is empty; cannot prepare .p8 file")


def _convert_literal(value: str) -> str:
    if "\\n" in value and "\n" not in value:
        try:
            value = value.encode("utf-8").decode("unicode_escape")
        except UnicodeDecodeError:
            pass
    value = value.replace("\r\n", "\n").replace("\r", "\n")
    return value


literal = _convert_literal(raw)

if "-----BEGIN" in literal:
    normalized = literal
else:
    candidate = "".join(raw.split())
    try:
        decoded = base64.b64decode(candidate, validate=True)
    except binascii.Error:
        normalized = literal
    else:
        decoded_literal = _convert_literal(decoded.decode("utf-8", errors="ignore"))
        if "-----BEGIN" in decoded_literal:
            normalized = decoded_literal
        else:
            normalized = literal

normalized = normalized.replace("\r\n", "\n").replace("\r", "\n")
if not normalized.endswith("\n"):
    normalized = normalized + "\n"

dest.write_text(normalized, encoding="utf-8")
try:
    os.chmod(dest, 0o600)
except PermissionError:
    pass
PY

  export APPLE_API_KEY="$key_path"
}

# Preconditions
if [[ "$(uname)" != "Darwin" ]]; then
  echo "This script must run on macOS." >&2
  exit 1
fi

HOST_ARCH="$(uname -m)"
if [[ "$HOST_ARCH" != "$ARCH_EXPECTED" ]]; then
  echo "Warning: Host architecture is '$HOST_ARCH', expected '$ARCH_EXPECTED'." >&2
  echo "Continuing anyway..." >&2
fi

command -v bun >/dev/null 2>&1 || { echo "bun is required. Install from https://bun.sh" >&2; exit 1; }
command -v xcrun >/dev/null 2>&1 || { echo "xcrun is required (Xcode command line tools)." >&2; exit 1; }
command -v spctl >/dev/null 2>&1 || { echo "spctl is required (macOS)." >&2; exit 1; }

# Optional: source additional env vars
# If not provided, prefer .env.codesign automatically when present, otherwise fall back to .env
if [[ -n "$ENV_FILE" ]]; then
  if [[ ! -f "$ENV_FILE" ]]; then
    echo "Env file not found: $ENV_FILE" >&2
    exit 1
  fi
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
elif [[ -f "$ROOT_DIR/.env.codesign" ]]; then
  echo "==> Loading codesign env from .env.codesign"
  set -a
  # shellcheck disable=SC1090
  source "$ROOT_DIR/.env.codesign"
  set +a
elif [[ -f "$ROOT_DIR/.env" ]]; then
  echo "==> Loading codesign env from .env"
  set -a
  # shellcheck disable=SC1090
  source "$ROOT_DIR/.env"
  set +a
fi

sanitize_id_like_env_var APPLE_API_KEY_ID
sanitize_id_like_env_var APPLE_API_ISSUER

echo "==> Preparing macOS entitlements"
bash "$ROOT_DIR/scripts/publish-prepare-macos-entitlements.sh"

echo "==> Generating icons"
(cd "$CLIENT_DIR" && bun run ./scripts/generate-icons.mjs)

if [[ ! -f "$ENTITLEMENTS" ]]; then
  echo "Entitlements file missing at $ENTITLEMENTS" >&2
  exit 1
fi

if [[ "$SKIP_INSTALL" != "true" ]]; then
  echo "==> Installing dependencies (bun install --frozen-lockfile)"
  (cd "$ROOT_DIR" && bun install --frozen-lockfile)
else
  if [[ ! -d "$ROOT_DIR/node_modules" || ! -d "$CLIENT_DIR/node_modules" ]]; then
    echo "==> node_modules missing; installing dependencies despite --skip-install"
    (cd "$ROOT_DIR" && bun install --frozen-lockfile)
  fi
fi

echo "==> Prebuilding mac app via prod script (workaround)"
bash "$ROOT_DIR/scripts/publish-build-electron-prod.sh"

# The workaround script cleans the client's build directory; recreate entitlements after
echo "==> Re-preparing macOS entitlements (after prebuild)"
bash "$ROOT_DIR/scripts/publish-prepare-macos-entitlements.sh" || true

# Detect presence of signing + notarization secrets (mirror GH workflow)
echo "==> Detecting signing environment"
declare -a MISSING_SIGNING_VARS=()
for k in MAC_CERT_BASE64 MAC_CERT_PASSWORD APPLE_API_KEY APPLE_API_KEY_ID APPLE_API_ISSUER; do
  if [[ -z "${!k:-}" ]]; then MISSING_SIGNING_VARS+=("$k"); fi
done

if (( ${#MISSING_SIGNING_VARS[@]} > 0 )); then
  echo "Missing signing/notarization environment variables: ${MISSING_SIGNING_VARS[*]}" >&2
  echo "All signing inputs are required; aborting." >&2
  exit 1
fi

echo "==> Signing inputs detected; preparing certificate and Apple API key"
TMPDIR_CERT="$(mktemp -d)"
CERT_PATH="$TMPDIR_CERT/mac_signing_cert.p12"
node -e "process.stdout.write(Buffer.from(process.env.MAC_CERT_BASE64,'base64'))" > "$CERT_PATH"
export CSC_LINK="$CERT_PATH"
export CSC_KEY_PASSWORD="${CSC_KEY_PASSWORD:-$MAC_CERT_PASSWORD}"

# Prepare Apple API key for notarytool: ensure APPLE_API_KEY is a readable file path
prepare_apple_api_key_file

echo "==> Packaging (signed; built-in notarize disabled due to macOS 15 notarytool JSON issue)"
export DEBUG="${DEBUG:-electron-osx-sign*,electron-notarize*}"
# Ensure entitlements exist right before packaging
(cd "$CLIENT_DIR" && \
  bunx electron-builder \
    --config electron-builder.json \
    --mac dmg zip --x64 \
    --publish never \
    --config.mac.forceCodeSigning=true \
    --config.mac.entitlements="$ENTITLEMENTS" \
    --config.mac.entitlementsInherit="$ENTITLEMENTS" \
    --config.mac.notarize=false)
echo "==> Manually notarizing with xcrun notarytool (workaround)"
# Build authentication args for notarytool
NOTARY_ARGS=( )
if [[ -n "${APPLE_API_KEY:-}" || -n "${APPLE_API_KEY_ID:-}" || -n "${APPLE_API_ISSUER:-}" ]]; then
  # Ensure APPLE_API_KEY is a file path (prepared above)
  NOTARY_ARGS+=( "--key" "${APPLE_API_KEY}" "--key-id" "${APPLE_API_KEY_ID}" "--issuer" "${APPLE_API_ISSUER}" )
elif [[ -n "${APPLE_ID:-}" || -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" || -n "${APPLE_TEAM_ID:-}" ]]; then
  NOTARY_ARGS+=( "--apple-id" "${APPLE_ID}" "--password" "${APPLE_APP_SPECIFIC_PASSWORD}" "--team-id" "${APPLE_TEAM_ID}" )
elif [[ -n "${APPLE_KEYCHAIN_PROFILE:-}" ]]; then
  if [[ -n "${APPLE_KEYCHAIN:-}" ]]; then
    NOTARY_ARGS+=( "--keychain" "${APPLE_KEYCHAIN}" "--keychain-profile" "${APPLE_KEYCHAIN_PROFILE}" )
  else
    NOTARY_ARGS+=( "--keychain-profile" "${APPLE_KEYCHAIN_PROFILE}" )
  fi
else
  echo "No notarization credentials available; skipping manual notarization" >&2
  NOTARY_ARGS=( )
fi

if [[ ${#NOTARY_ARGS[@]} -gt 0 ]]; then
  echo "notarytool: $(xcrun notarytool --version 2>/dev/null || echo 'not found')"
  # Choose artifact to submit: prefer DMG, else zip the .app with ditto
  ARTIFACT=""
  if compgen -G "$DIST_DIR/*.dmg" > /dev/null; then
    ARTIFACT="$(ls -1 "$DIST_DIR"/*.dmg | head -n1)"
    echo "Submitting DMG to notary service: $ARTIFACT"
  else
    APP_PATH="$(find "$DIST_DIR" -maxdepth 4 -type d -name "*.app" | head -n1 || true)"
    if [[ -z "$APP_PATH" ]]; then
      echo "No artifact found to notarize under $DIST_DIR" >&2
    else
      ARTIFACT="$DIST_DIR/$(basename "${APP_PATH%.app}").zip"
      echo "Zipping .app for submission with ditto: $APP_PATH -> $ARTIFACT"
      (cd "$(dirname "$APP_PATH")" && ditto -c -k --sequesterRsrc --keepParent "$(basename "$APP_PATH")" "$ARTIFACT")
    fi
  fi

  if [[ -n "$ARTIFACT" && -e "$ARTIFACT" ]]; then
    # Submit and wait; tolerate extra non-JSON noise in macOS 15 by grepping for Accepted
    set +e
    SUBMIT_OUT=$(xcrun notarytool submit "$ARTIFACT" --wait --output-format json "${NOTARY_ARGS[@]}" 2>&1)
    SUBMIT_CODE=$?
    set -e
    echo "$SUBMIT_OUT" | sed -e 's/^/notarytool: /'

    # Determine success robustly
    if [[ $SUBMIT_CODE -eq 0 ]] && echo "$SUBMIT_OUT" | grep -qi '"status" *: *"Accepted"\|status: Accepted\|Accepted'; then
      echo "==> Notarization accepted"
    else
      echo "==> Notarization did not report Accepted; attempting to extract log for diagnostics" >&2
      # Try to extract an id field from JSON if present
      SUBMISSION_ID=$(echo "$SUBMIT_OUT" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]\+\)".*/\1/p' | head -n1)
      if [[ -n "$SUBMISSION_ID" ]]; then
        xcrun notarytool log "$SUBMISSION_ID" "${NOTARY_ARGS[@]}" --output-format text || true
      fi
      echo "Manual notarization appears to have failed. See output above." >&2
      exit 1
    fi
  fi
fi

echo "==> Stapling and verifying outputs"
if [[ -d "$DIST_DIR" ]]; then
  pushd "$DIST_DIR" >/dev/null
  APP="$(find "$PWD" -maxdepth 4 -type d -name "*.app" | head -n1 || true)"
  DMG="$(ls -1 *.dmg 2>/dev/null | head -n1 || true)"

  if [[ -n "$APP" && -d "$APP" ]]; then
    echo "Stapling app: $APP"
    xcrun stapler staple "$APP"
    echo "Validating app stapling:"
    xcrun stapler validate "$APP"
    echo "Gatekeeper assessment for app:"
    spctl -a -t exec -vv "$APP"
  else
    echo "No .app found under $DIST_DIR" >&2
  fi

  if [[ -n "$DMG" && -f "$DMG" ]]; then
    echo "Stapling DMG: $DMG"
    xcrun stapler staple "$DMG"
    # TODO: make gatekeeper happy, dmg insufficient context
    # echo "Validating DMG stapling:"
    # xcrun stapler validate "$DMG"
    # echo "Gatekeeper assessment for DMG:"
    # spctl -a -t open -vv --context context:primary-signature "$DMG"
  else
    echo "No .dmg found under $DIST_DIR" >&2
  fi

  popd >/dev/null
else
  echo "Distribution directory not found: $DIST_DIR" >&2
fi

echo "==> Done. Outputs in: $DIST_DIR"
