#!/usr/bin/env bash
# Prints the path of a pinned shell build, made once per host and cached:
#   scripts/ci/pinned-shell.sh bash-5.3|bash-5.2.37|fish-4.9.3
# The shell-integration fork guard (cmux-tui-core shell_integration::fork_count_tests) runs its
# bash and fish from here on macOS, so every Mac that runs the guard runs the shells under test
# (the AWS Macs have no Homebrew bash or fish, and a missing shell used to skip the bash 5.3 check
# that is red at ghostty-next 5555f42). scripts/measure/shell-integration.sh takes its shells from
# here too.
#   bash  GNU's release tarball (sha256-pinned, two mirrors), configured and compiled here; only the
#         bash binary is kept.
#   fish  the fish project's macOS pkg (sha256-pinned, universal, macOS 11+, its data built into the
#         binary), unpacked with pkgutil: nothing is installed and no pkg script runs. macOS only.
# Cache: ~/Library/Caches/cmux/pinned-shells (macOS), ${XDG_CACHE_HOME:-~/.cache}/cmux/pinned-shells
# elsewhere; one directory per shell and checksum, renamed into place whole, so a killed build or a
# concurrent caller never leaves half a shell there.
# Exit 0: the absolute path on stdout. Exit 1: the reason on stderr (unknown name, download or
# checksum failed, build failed). Build output goes to stderr only on failure.
set -euo pipefail

name="${1:-}"
case "$name" in
  bash-5.3) sha=0d5cd86965f869a26cf64f4b71be7b96f90a3ba8b3d74e27e8e9d9d5550f31ba bin=bin/bash ;;
  bash-5.2.37) sha=9599b22ecd1d5787ad7d3b7bf0c59f312b3396d1e281175dd1f8a4014da621ff bin=bin/bash ;;
  fish-4.9.3) sha=fb489929e25e66b8c026a1da8935f68f828134e115a1706f360ed73149b843a9 bin=bin/fish ;;
  *) echo "pinned-shell: usage: pinned-shell.sh bash-5.3|bash-5.2.37|fish-4.9.3 (got '$name')" >&2; exit 1 ;;
esac

if [[ "$(uname -s)" == Darwin ]]; then
  cache="$HOME/Library/Caches/cmux/pinned-shells"
else
  cache="${XDG_CACHE_HOME:-$HOME/.cache}/cmux/pinned-shells"
fi
dest="$cache/$name-${sha:0:16}"
if [[ -x "$dest/$bin" ]]; then
  echo "$dest/$bin"
  exit 0
fi

mkdir -p "$cache"
work="$(mktemp -d "$cache/.work-$name.XXXXXX")"
trap 'rm -rf "$work"' EXIT
started=$SECONDS

sha256() {
  if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

fetch() {  # fetch FILE URL...: the first download whose sha256 is $sha
  local file="$1" got="" url
  shift
  for url in "$@"; do
    curl --proto '=https' -fsSL --retry 3 -o "$file" "$url" || continue
    got="$(sha256 "$file")"
    [[ "$got" == "$sha" ]] && return 0
  done
  echo "pinned-shell: $name: download failed or sha256 '$got' is not $sha ($*)" >&2
  return 1
}

case "$name" in
  bash-*)
    version="${name#bash-}"
    fetch "$work/bash.tar.gz" "https://mirrors.kernel.org/gnu/bash/bash-$version.tar.gz" \
      "https://ftp.gnu.org/gnu/bash/bash-$version.tar.gz"
    tar -xzf "$work/bash.tar.gz" -C "$work"
    jobs="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
    if ! (cd "$work/bash-$version" && ./configure --without-bash-malloc && make -j"$jobs") \
        > "$work/build.log" 2>&1; then
      tail -n 40 "$work/build.log" >&2
      echo "pinned-shell: $name: build failed" >&2
      exit 1
    fi
    mkdir -p "$work/shell/bin"
    cp "$work/bash-$version/bash" "$work/shell/bin/bash"
    ;;
  fish-*)
    if [[ "$(uname -s)" != Darwin ]]; then
      echo "pinned-shell: $name: the pinned fish is the macOS pkg" >&2
      exit 1
    fi
    version="${name#fish-}"
    fetch "$work/fish.pkg" "https://github.com/fish-shell/fish-shell/releases/download/$version/fish-$version.pkg"
    pkgutil --expand-full "$work/fish.pkg" "$work/pkg" >/dev/null
    mv "$work/pkg/fish.pkg/Payload/usr/local" "$work/shell"
    ;;
esac

[[ -x "$work/shell/$bin" ]] || { echo "pinned-shell: $name: no $bin in the build" >&2; exit 1; }
# rename(2) when $dest does not exist yet. A concurrent caller that won puts it there first: then
# mv moves this copy inside it, and that copy goes (the winner's $dest is whole).
mv "$work/shell" "$dest" 2>/dev/null || true
rm -rf "$dest/shell"
[[ -x "$dest/$bin" ]] || { echo "pinned-shell: $name: $dest/$bin missing after the move" >&2; exit 1; }
echo "pinned-shell: $name ready in $((SECONDS - started)) s at $dest" >&2
echo "$dest/$bin"
