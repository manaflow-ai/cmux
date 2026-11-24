#!/usr/bin/env bash
# Print the Zig that builds DIR's cmux-tui client set: the version its Ghostty
# source pins, installed by DIR's own install-zig-ci.sh under a per-runner
# cache (never over the Mac's zig). media_build_app.sh exports it as CMUX_ZIG,
# the zig ghostty-vt-sys's build.rs tries first.
#
#   media_pinned_zig.sh DIR
#
# Tour 45249031506 (2026-11-23): the before app at a644014 built its client
# here with the Mac's PATH zig 0.16 while its ghostty-next pins 0.17, so its
# libghostty-vt failed ("does not meet the required build version") and the
# What's New befores of warn-before-quit-shortcut and
# updates-download-in-the-background never recorded.
set -euo pipefail
dir="$(cd "$1" && pwd)"
installer="$dir/scripts/install-zig-ci.sh"
[ -x "$installer" ] || { echo "no $installer" >&2; exit 1; }
source=ghostty
git -C "$dir" rev-parse --verify -q HEAD:ghostty-next >/dev/null && source=ghostty-next
cache="${MEDIA_ZIG_CACHE:-$HOME/Library/Caches/cmux-ci-media/zig/${RUNNER_NAME:-local}}"
mkdir -p "$cache/tarballs"
env_file="$(mktemp)"
trap 'rm -f "$env_file"' EXIT
# Its own GITHUB_ENV, no GITHUB_PATH: the zig reaches only this build, not later steps.
(cd "$dir" && GHOSTTY_ZIG_SOURCE="$source" ZIG_FORCE_LOCAL_INSTALL=1 ZIG_PUBLISH_ENV=CMUX_ZIG \
  ZIG_INSTALL_ROOT="$cache" ZIG_TARBALL_CACHE_DIR="$cache/tarballs" GITHUB_ENV="$env_file" GITHUB_PATH="" \
  "$installer") >&2
zig="$(sed -n 's/^CMUX_ZIG=//p' "$env_file" | tail -n 1)"
if [ -z "$zig" ] || [ ! -x "$zig" ]; then echo "install-zig-ci.sh named no zig" >&2; exit 1; fi
echo "$zig"
