#!/usr/bin/env bash
# Carry one directory from a job to a later job of the same run through one artifact.
#
#   handoff-archive.sh pack   <dir> <out dir>   writes <out dir>/handoff.tar.zst (handoff.tar.gz without zstd)
#   handoff-archive.sh unpack <in dir> <dir>    replaces <dir> with what the archive in <in dir> holds
#
# Upload <out dir> with actions/upload-artifact (compression-level 0) and download it into
# <in dir>. upload-artifact itself zips files as mode 644 and follows symlinks, so a cache sent
# through it as a directory comes back changed; a tar keeps modes, symlinks and empty folders.
# nightly.yml's build-nightly-app, on the reused trusted mini, hands its compilation cache, Swift
# packages and dSYMs this way to short Linux jobs that hold the R2 keys and the Sentry token.
#
# COPYFILE_DISABLE stops macOS tar from adding ._ AppleDouble files, which a Linux tar would
# unpack as real files. zstd uses r2-cache.sh's settings; a plain `zstd -d` reads them.
set -euo pipefail

mode="${1:-}"
from="${2:-}"
to="${3:-}"
if [[ "$mode" != "pack" && "$mode" != "unpack" ]] || [[ -z "$from" || -z "$to" ]]; then
  echo "usage: handoff-archive.sh pack <dir> <out dir> | unpack <in dir> <dir>" >&2
  exit 2
fi

pack() {
  if [[ ! -d "$from" ]]; then
    echo "handoff-archive: $from is not a directory" >&2
    exit 1
  fi
  rm -rf "$to"
  mkdir -p "$to"
  local archive
  if command -v zstd >/dev/null 2>&1; then
    archive="$to/handoff.tar.zst"
    COPYFILE_DISABLE=1 tar -cf - -C "$from" . | zstd -T0 -3 --long=27 -q -o "$archive"
  else
    archive="$to/handoff.tar.gz"
    COPYFILE_DISABLE=1 tar -cf - -C "$from" . | gzip -1 > "$archive"
  fi
  echo "handoff-archive: $from ($(du -sk "$from" | cut -f1) KiB) packed into $(du -k "$archive" | cut -f1) KiB"
}

unpack() {
  local archives=() archive candidate status=0
  for candidate in "$from/handoff.tar.zst" "$from/handoff.tar.gz"; do
    if [[ -f "$candidate" ]]; then archives+=("$candidate"); fi
  done
  if [[ "${#archives[@]}" -ne 1 ]]; then
    echo "handoff-archive: expected one handoff archive in $from, found ${#archives[@]}" >&2
    exit 1
  fi
  archive="${archives[0]}"
  rm -rf "$to"
  mkdir -p "$to"
  if [[ "$archive" == *.zst ]]; then
    # Read through EOF so a tar that stops at its end marker never sends SIGPIPE to zstd.
    zstd -dc "$archive" | { tar -xf - -C "$to" && cat > /dev/null; } || status=$?
  else
    gzip -dc "$archive" | { tar -xf - -C "$to" && cat > /dev/null; } || status=$?
  fi
  if [[ "$status" -ne 0 ]]; then
    rm -rf "$to"
    echo "handoff-archive: could not unpack $archive (exit $status)" >&2
    exit 1
  fi
  echo "handoff-archive: $archive unpacked into $to ($(du -sk "$to" | cut -f1) KiB)"
}

"$mode"
