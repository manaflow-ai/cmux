#!/usr/bin/env bash
# Puts bun VERSION (or a newer release of its major) on a step job's PATH: the `bun` tool of
# ci/steps.toml's [tools] table, which runs it when a routed step lists `bun` in `needs`. It stands in for
# oven-sh/setup-bun (pinned "1.4.4" by the workflows that moved into steps), which a step cannot call.
#
#   ensure-bun.sh VERSION BIN_DIR
#
# bun VERSION or newer of the same major (the rule scripts/check-webviews-bun-version.sh holds) already on
# PATH: BIN_DIR gets a link to it and nothing is downloaded. Otherwise it downloads the release zip from
# github.com/oven-sh/bun (bounded curl with retries and a low-speed abort), checks it against the release's
# SHASUMS256.txt, and unpacks it into BIN_DIR. A runner that keeps RUNNER_TOOL_CACHE between jobs keeps the
# download there (bun/VERSION/ARCH), so its next job downloads nothing. Needs bash, curl, python3 and
# sha256sum or shasum; no root.
set -euo pipefail

want="${1:?usage: ensure-bun.sh VERSION BIN_DIR}"
bin="${2:?usage: ensure-bun.sh VERSION BIN_DIR}"
mkdir -p "$bin"

# Whether HAVE is a release of WANT's major at or above WANT (no prerelease, no build suffix).
acceptable() {
  local have="$1"
  [[ "$have" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  [ "${have%%.*}" = "${want%%.*}" ] || return 1
  [ "$(printf '%s\n%s\n' "$want" "$have" | sort -V | head -n1)" = "$want" ]
}

if have_bin="$(command -v bun 2>/dev/null)" && have="$(bun --version 2>/dev/null)" && acceptable "$have"; then
  ln -sf "$have_bin" "$bin/bun"
  echo "bun $have is on PATH ($have_bin)"
  exit 0
fi

case "$(uname -s)" in Linux) os=linux ;; Darwin) os=darwin ;; *) echo "::error::ensure-bun: unsupported OS $(uname -s)"; exit 1 ;; esac
case "$(uname -m)" in arm64 | aarch64) arch=aarch64 ;; x86_64) arch=x64 ;; *) echo "::error::ensure-bun: unsupported arch $(uname -m)"; exit 1 ;; esac
name="bun-$os-$arch"
cache="${RUNNER_TOOL_CACHE:+$RUNNER_TOOL_CACHE/bun/$want/$arch}"
if [ -n "$cache" ] && [ -x "$cache/bun" ] && [ "$("$cache/bun" --version 2>/dev/null)" = "$want" ]; then
  ln -sf "$cache/bun" "$bin/bun"
  echo "bun $want from $cache"
  exit 0
fi
base="${ENSURE_BUN_DIST:-https://github.com/oven-sh/bun/releases/download}/bun-v$want"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
get() {
  curl -fsSL --retry 3 --retry-all-errors --connect-timeout 20 --max-time 120 \
    --speed-limit 1024 --speed-time 30 -o "$2" "$1"
}
get "$base/$name.zip" "$tmp/$name.zip"
get "$base/SHASUMS256.txt" "$tmp/SHASUMS256.txt"
expected="$(awk -v f="$name.zip" '$2 == f || $2 == "*" f { print $1 }' "$tmp/SHASUMS256.txt")"
if command -v sha256sum >/dev/null 2>&1; then actual="$(sha256sum "$tmp/$name.zip" | awk '{ print $1 }')"
else actual="$(shasum -a 256 "$tmp/$name.zip" | awk '{ print $1 }')"; fi
if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
  echo "::error::ensure-bun: $name.zip does not match SHASUMS256.txt (${expected:-no entry} vs $actual)"
  exit 1
fi
python3 - "$tmp/$name.zip" "$tmp/x" <<'PY'
import sys, zipfile
zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])
PY
chmod +x "$tmp/x/$name/bun"
got="$("$tmp/x/$name/bun" --version)"
if [ "$got" != "$want" ]; then
  echo "::error::ensure-bun: the downloaded bun reports '${got:-nothing}', not $want"
  exit 1
fi
if [ -n "$cache" ] && mkdir -p "$cache" 2>/dev/null; then
  cp "$tmp/x/$name/bun" "$cache/bun.$$" && mv -f "$cache/bun.$$" "$cache/bun" && ln -sf "$cache/bun" "$bin/bun" || cp "$tmp/x/$name/bun" "$bin/bun"
else
  cp "$tmp/x/$name/bun" "$bin/bun"
fi
echo "bun $want from $base"
