#!/usr/bin/env bash
set -euo pipefail

ZIG_REQUIRED="${ZIG_REQUIRED:-0.15.2}"

if command -v zig >/dev/null 2>&1 && zig version 2>/dev/null | grep -q "^${ZIG_REQUIRED}$"; then
  echo "zig ${ZIG_REQUIRED} already installed"
  zig version
  exit 0
fi

case "$(uname -m)" in
  arm64) zig_arch="aarch64" ;;
  x86_64) zig_arch="x86_64" ;;
  *)
    echo "Unsupported macOS architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

echo "Installing zig ${ZIG_REQUIRED} from tarball"
zig_dir="zig-${zig_arch}-macos-${ZIG_REQUIRED}"
curl -fSL "https://ziglang.org/download/${ZIG_REQUIRED}/${zig_dir}.tar.xz" -o /tmp/zig.tar.xz
tar xf /tmp/zig.tar.xz -C /tmp
if [[ -n "${GITHUB_PATH:-}" ]]; then
  echo "/tmp/${zig_dir}" >> "$GITHUB_PATH"
fi
"/tmp/${zig_dir}/zig" version
