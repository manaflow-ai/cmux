#!/bin/sh
set -eu

base_url="${CODEROUTER_DOWNLOAD_BASE_URL:-https://github.com/manaflow-ai/coderouter-releases/releases/latest/download}"
install_root="${CODEROUTER_INSTALL:-$HOME/.coderouter}"
bin_dir="$install_root/bin"

os="$(uname -s)"
arch="$(uname -m)"

case "$os-$arch" in
  Darwin-arm64) artifact="coderouter-darwin-arm64" ;;
  Darwin-x86_64) artifact="coderouter-darwin-x64" ;;
  Linux-x86_64 | Linux-amd64) artifact="coderouter-linux-x64" ;;
  Linux-aarch64 | Linux-arm64) artifact="coderouter-linux-arm64" ;;
  *)
    echo "coderouter: unsupported platform $os-$arch" >&2
    exit 1
    ;;
esac

if ! command -v curl >/dev/null 2>&1; then
  echo "coderouter: curl is required" >&2
  exit 1
fi

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/coderouter-install.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM

curl --proto '=https' --tlsv1.2 -fsSL "$base_url/manifest.json" \
  -o "$tmp_dir/manifest.json"
checksum="$(
  sed -n "s/.*\"$artifact\"[[:space:]]*:[[:space:]]*\"\\([0-9a-f][0-9a-f]*\\)\".*/\\1/p" \
    "$tmp_dir/manifest.json"
)"
version="$(
  sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    "$tmp_dir/manifest.json"
)"
if [ "${#checksum}" -ne 64 ]; then
  echo "coderouter: $artifact is unavailable for this release" >&2
  exit 1
fi

curl --proto '=https' --tlsv1.2 -fsSL "$base_url/$artifact" \
  -o "$tmp_dir/coderouter"

if command -v shasum >/dev/null 2>&1; then
  actual="$(shasum -a 256 "$tmp_dir/coderouter" | awk '{print $1}')"
elif command -v sha256sum >/dev/null 2>&1; then
  actual="$(sha256sum "$tmp_dir/coderouter" | awk '{print $1}')"
else
  echo "coderouter: shasum or sha256sum is required" >&2
  exit 1
fi

if [ "$actual" != "$checksum" ]; then
  echo "coderouter: checksum verification failed" >&2
  exit 1
fi

mkdir -p "$bin_dir"
install -m 755 "$tmp_dir/coderouter" "$bin_dir/coderouter"
ln -sf coderouter "$bin_dir/cr"

case ":$PATH:" in
  *":$bin_dir:"*) ;;
  *)
    shell_name="$(basename "${SHELL:-sh}")"
    case "$shell_name" in
      zsh) profile="$HOME/.zshrc"; line="export PATH=\"$bin_dir:\$PATH\"" ;;
      bash) profile="$HOME/.bashrc"; line="export PATH=\"$bin_dir:\$PATH\"" ;;
      fish)
        profile="$HOME/.config/fish/config.fish"
        line="fish_add_path \"$bin_dir\""
        mkdir -p "$(dirname "$profile")"
        ;;
      *) profile=""; line="" ;;
    esac
    if [ -n "$profile" ] && ! grep -F "$bin_dir" "$profile" >/dev/null 2>&1; then
      printf '\n# coderouter\n%s\n' "$line" >>"$profile"
      echo "Added coderouter to PATH in $profile"
    else
      echo "Add $bin_dir to PATH to run coderouter from a new shell."
    fi
    ;;
esac

echo "Installed coderouter ${version:-unknown} to $bin_dir/coderouter"

curl --proto '=https' --tlsv1.2 -fsS --max-time 2 \
  -H 'content-type: application/json' \
  -d "{\"product\":\"coderouter\",\"platform\":\"$os-$arch\",\"method\":\"curl\",\"version\":\"${version:-unknown}\"}" \
  https://cmux.com/api/install-events >/dev/null 2>&1 || true
