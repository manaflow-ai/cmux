#!/usr/bin/env bash
# Download and verify the actionlint binary used by a guarded workflow.
set -euo pipefail

: "${ACTIONLINT_VERSION:?ACTIONLINT_VERSION must be set}"
: "${ACTIONLINT_SHA256:?ACTIONLINT_SHA256 must be set}"
: "${ACTIONLINT_ASSET_ID:?ACTIONLINT_ASSET_ID must be set}"
: "${RUNNER_TEMP:?RUNNER_TEMP must be set}"

if [[ ! "$ACTIONLINT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "invalid actionlint version: $ACTIONLINT_VERSION" >&2
  exit 2
fi
if [[ ! "$ACTIONLINT_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
  echo "invalid actionlint SHA-256: $ACTIONLINT_SHA256" >&2
  exit 2
fi
if [[ ! "$ACTIONLINT_ASSET_ID" =~ ^[0-9]+$ ]]; then
  echo "invalid actionlint release asset ID: $ACTIONLINT_ASSET_ID" >&2
  exit 2
fi

archive="$RUNNER_TEMP/actionlint.tar.gz"
binary="$RUNNER_TEMP/actionlint"
asset_name="actionlint_${ACTIONLINT_VERSION}_linux_amd64.tar.gz"
release_url="https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/${asset_name}"
# The asset ID is immutable for the lifetime of a GitHub release asset. This
# endpoint is a separate GitHub API path from the browser download redirect;
# the SHA-256 below still authenticates the bytes before they are extracted.
api_url="https://api.github.com/repos/rhysd/actionlint/releases/assets/${ACTIONLINT_ASSET_ID}"

download() {
  local url="$1"
  shift

  local -a curl_args=(
    --proto '=https'
    --tlsv1.2
    --fail
    --silent
    --show-error
    --location
    --connect-timeout 10
    --max-time 60
    --retry 5
    --retry-delay 2
    --retry-max-time 30
    --retry-all-errors
    --output "$archive"
  )
  curl_args+=("$@")
  curl "${curl_args[@]}" "$url"
}

rm -f "$archive" "$binary"
if ! download "$release_url"; then
  echo "actionlint release download failed; trying immutable asset API endpoint" >&2
  rm -f "$archive"
  if ! download "$api_url" --header 'Accept: application/octet-stream'; then
    echo "actionlint download failed from both pinned GitHub endpoints" >&2
    exit 1
  fi
fi

sha256sum_help="$(sha256sum --help 2>&1 || true)"
if [[ "$sha256sum_help" == *"--check"* ]]; then
  printf '%s  %s\n' "$ACTIONLINT_SHA256" "$archive" | sha256sum --check --strict
elif command -v shasum >/dev/null 2>&1; then
  actual_sha256="$(shasum -a 256 "$archive" | awk '{print $1}')"
  if [[ "$actual_sha256" != "$ACTIONLINT_SHA256" ]]; then
    echo "actionlint archive checksum mismatch" >&2
    echo "Expected: $ACTIONLINT_SHA256" >&2
    echo "Actual:   $actual_sha256" >&2
    exit 1
  fi
else
  echo "no SHA-256 verification tool is available" >&2
  exit 1
fi

tar -xzf "$archive" -C "$RUNNER_TEMP" actionlint
test -x "$binary"
printf '%s\n' "$binary"
