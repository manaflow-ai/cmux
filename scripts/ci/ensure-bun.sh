#!/usr/bin/env bash
# Puts bun VERSION on a step job's PATH: the `bun` tool of
# ci/steps.toml's [tools] table, which runs it when a routed step lists `bun` in `needs`. It stands in for
# oven-sh/setup-bun (pinned "1.4.4" by the workflows that moved into steps), which a step cannot call.
#
#   ensure-bun.sh VERSION BIN_DIR
#
# Exactly bun VERSION already on PATH: BIN_DIR gets a link to it and nothing is downloaded (any other bun a
# shared host has must not decide what `bun install --frozen-lockfile` or a bundle check sees). Otherwise it
# downloads the release zip from github.com/oven-sh/bun (bounded curl with retries and a low-speed abort),
# checks it against the release's SHASUMS256.txt, and unpacks it into BIN_DIR. A runner that keeps RUNNER_TOOL_CACHE between jobs keeps the
# download there (bun/VERSION/ARCH), so its next job downloads nothing. Needs bash, curl, python3 and
# sha256sum or shasum; no root.
set -euo pipefail

want="${1:?usage: ensure-bun.sh VERSION BIN_DIR}"
bin="${2:?usage: ensure-bun.sh VERSION BIN_DIR}"
mkdir -p "$bin"
# setup-bun puts `bunx` beside `bun` (bun acts as bunx when called by that name); playwright's webServer and
# package scripts call it, so every way out below links it too.
trap 'ln -sf bun "$bin/bunx" 2>/dev/null || true' EXIT

if have_bin="$(command -v bun 2>/dev/null)" && have="$(bun --version 2>/dev/null)" && [ "$have" = "$want" ]; then
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
trap 'rm -rf "$tmp"; ln -sf bun "$bin/bunx" 2>/dev/null || true' EXIT
# The machine's GitHub release and archive cache (cmux-git-cache, RFD 0155), when it listens:
# it answers with GitHub's own bytes or a redirect to GitHub, and any failure here retries GitHub
# directly. CMUX_TRANSPORT_REWRITE=0 turns it off.
cmux_cached_url() {
  case "$1" in https://github.com/*/releases/download/* | https://codeload.github.com/*) ;; *) return 1 ;; esac
  [ "${CMUX_TRANSPORT_REWRITE:-1}" != 0 ] && [ -r /run/cmux/git-cache/base ] || return 1
  local proxy
  proxy="$(cat /run/cmux/git-cache/base)" || return 1
  case "$proxy" in http://127.0.0.1:[0-9]*) ;; *) return 1 ;; esac
  printf '%s/%s\n' "$proxy" "${1#https://}"
}
get() {
  local via
  if via="$(cmux_cached_url "$1")"; then
    if curl -fsSL --connect-timeout 5 --max-time 120 --speed-limit 1024 --speed-time 30 -o "$2" "$via"; then
      echo "ensure-bun: $1 through the machine cache" >&2
      return 0
    fi
    echo "ensure-bun: machine cache failed for $1; GitHub directly" >&2
  fi
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
