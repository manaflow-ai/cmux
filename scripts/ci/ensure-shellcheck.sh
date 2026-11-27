#!/usr/bin/env bash
# Print the path of a shellcheck to run: the one on PATH, else a pinned release
# downloaded and verified into the runner's temp directory. The persistent
# cmux-linux pool's image has no shellcheck, and a guard that skips its lint
# when the tool is missing would pass without linting.
set -euo pipefail

if command -v shellcheck >/dev/null 2>&1; then
  command -v shellcheck
  exit 0
fi

version="0.10.0"
sha256="6c881ab0698e4e6ea235245f22832860544f17ba386442fe7e9d629f8cbedf87"
case "$(uname -s)-$(uname -m)" in
  Linux-x86_64) ;;
  *)
    echo "shellcheck is not installed and no pinned release is listed for $(uname -s)-$(uname -m)" >&2
    exit 2
    ;;
esac

root="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/cmux-shellcheck-${version}"
binary="$root/shellcheck-v${version}/shellcheck"
if [[ -x "$binary" ]]; then
  echo "$binary"
  exit 0
fi

mkdir -p "$root"
archive="$root/shellcheck.tar.xz"
curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location \
  --connect-timeout 10 --max-time 60 --retry 5 --retry-delay 2 --retry-all-errors \
  --output "$archive" \
  "https://github.com/koalaman/shellcheck/releases/download/v${version}/shellcheck-v${version}.linux.x86_64.tar.xz"
if ! echo "$sha256  $archive" | sha256sum --check --status; then
  echo "shellcheck download does not match its pinned SHA-256" >&2
  rm -f "$archive"
  exit 1
fi
tar -xJf "$archive" -C "$root"
rm -f "$archive"
echo "$binary"
