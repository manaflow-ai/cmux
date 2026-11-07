#!/usr/bin/env bash
# scripts/ci/keep-job-zig-first.sh ZIG
#
# Keep the zig a job already chose first on its PATH after a step puts a home
# directory (~/.cargo/bin) on GITHUB_PATH. A GITHUB_PATH entry goes in front of
# everything the job had, so a leftover zig link in a runner's ~/.cargo/bin (a
# 0.16.0 one sits beside rustup's proxies on some Macs) shadowed the zig the
# job installed for ghostty-next, and the cmux-tui build failed with "Your Zig
# version v0.16.0 does not meet the required build version of v0.17.0".
#
# ZIG is `command -v zig` from before the step changed PATH; empty (the job had
# no zig) changes nothing. The zig is linked alone into $RUNNER_TEMP/cmux-job-zig,
# and that directory is appended to GITHUB_PATH after ~/.cargo/bin, so no other
# tool moves. Prints the directory (nothing when it did nothing), so a caller that
# also writes BASH_ENV can put it ahead there too.
#
# Windows is left alone: Git Bash's ln copies instead of linking, and a copied
# zig.exe cannot find its lib directory.
set -euo pipefail

zig="${1:-}"
[[ -n "$zig" && -x "$zig" && -n "${GITHUB_PATH:-}" ]] || exit 0
case "${RUNNER_OS:-$(uname -s)}" in
  Windows|MINGW*|MSYS*|CYGWIN*) exit 0 ;;
esac
case "$zig" in
  /*) ;;
  *) echo "keep-job-zig-first: not an absolute path: $zig" >&2; exit 2 ;;
esac

dir="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/cmux-job-zig"
# A second call in the same job sees its own link first; keep what it points at.
if [[ "$zig" == "$dir/zig" ]]; then
  zig="$(readlink "$dir/zig")"
fi
mkdir -p "$dir"
ln -sfn "$zig" "$dir/zig"
echo "$dir" >> "$GITHUB_PATH"
echo "keep-job-zig-first: zig stays $zig ($("$zig" version 2>/dev/null || echo 'version unknown'))" >&2
printf '%s\n' "$dir"
