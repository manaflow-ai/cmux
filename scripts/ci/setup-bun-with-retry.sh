#!/usr/bin/env bash
set -euo pipefail

version="${1:-}"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "usage: setup-bun-with-retry.sh <semver>" >&2
  exit 2
fi

case "$(uname -s):$(uname -m)" in
  Linux:x86_64|Linux:amd64)
    archive="bun-linux-x64.zip"
    ;;
  Linux:aarch64|Linux:arm64)
    archive="bun-linux-aarch64.zip"
    ;;
  Darwin:arm64)
    archive="bun-darwin-aarch64.zip"
    ;;
  Darwin:x86_64)
    archive="bun-darwin-x64.zip"
    ;;
  *)
    echo "unsupported platform for Bun: $(uname -s) $(uname -m)" >&2
    exit 2
    ;;
esac

install_root="${BUN_INSTALL:-$HOME/.bun}"
install_dir="$install_root/bin"
install_path="$install_dir/bun"
bunx_path="$install_dir/bunx"

if [[ -x "$install_path" ]] && [[ "$("$install_path" --version 2>/dev/null)" == "$version" ]]; then
  ln -sf bun "$bunx_path"
  echo "$install_dir" >> "${GITHUB_PATH:-/dev/null}"
  "$install_path" --version
  exit 0
fi

if command -v bun >/dev/null 2>&1 && [[ "$(bun --version 2>/dev/null)" == "$version" ]]; then
  bun_dir="$(dirname "$(command -v bun)")"
  if [[ -w "$bun_dir" && ! -e "$bun_dir/bunx" ]]; then
    ln -sf bun "$bun_dir/bunx"
  fi
  echo "$bun_dir" >> "${GITHUB_PATH:-/dev/null}"
  bun --version
  exit 0
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

url="https://github.com/oven-sh/bun/releases/download/bun-v${version}/${archive}"
zip_path="$tmp_dir/bun.zip"

for attempt in 1 2 3 4 5; do
  echo "Downloading Bun ${version} (${archive}), attempt ${attempt}"
  if curl -fL \
    --connect-timeout 20 \
    --max-time 180 \
    --retry 3 \
    --retry-delay 5 \
    --retry-max-time 240 \
    --retry-all-errors \
    "$url" \
    -o "$zip_path"; then
    break
  fi
  if [[ "$attempt" -eq 5 ]]; then
    echo "failed to download Bun ${version} after ${attempt} attempts" >&2
    exit 1
  fi
  sleep "$((attempt * 15))"
done

unzip -q "$zip_path" -d "$tmp_dir/extract"
bun_binary="$(find "$tmp_dir/extract" -type f -name bun -print -quit)"
if [[ -z "$bun_binary" ]]; then
  echo "downloaded Bun archive did not contain a bun binary" >&2
  exit 1
fi

mkdir -p "$install_dir"
cp "$bun_binary" "$install_path"
chmod +x "$install_path"
ln -sf bun "$bunx_path"

actual_version="$("$install_path" --version)"
if [[ "$actual_version" != "$version" ]]; then
  echo "installed Bun version mismatch: expected ${version}, got ${actual_version}" >&2
  exit 1
fi

echo "$install_dir" >> "${GITHUB_PATH:-/dev/null}"
"$install_path" --version
