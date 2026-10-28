#!/usr/bin/env bash
# Runs the remote browser host's own smoke (`--smoke`, cmux-remote-browser-host
# src/smoke.rs) on a Mac with a window server session and prints its
# result.json. The smoke renders a local test page, captures it, and checks
# that every renderer and the GPU process of the host run in the macOS sandbox
# and may not read a file outside the profile (src/sandbox_status.rs).
#
#   scripts/cmux-next/rb-host-sandbox-smoke.sh HOST OUT
#
# HOST is a cmux app that embeds the host (Contents/MacOS/cmux-remote-browser-host),
# a standalone host app (bundle-remote-browser-host.sh), or the host executable.
# Exit: the smoke's (0 pass, 1 a check failed), 2 usage.
set -u
host="${1:?usage: rb-host-sandbox-smoke.sh HOST OUT}"
out="${2:?usage: rb-host-sandbox-smoke.sh HOST OUT}"
name=cmux-remote-browser-host
if [[ -d "$host" ]]; then
  bin="$host/Contents/MacOS/$name"
else
  bin="$host"
fi
[[ -x "$bin" ]] || { echo "error: no host executable at $bin" >&2; exit 2; }
rm -rf "$out"
mkdir -p "$out"
"$bin" --smoke "$out" > "$out/stdout.log" 2> "$out/stderr.log"
code=$?
cat "$out/result.json" 2>/dev/null || { echo "error: the smoke wrote no result.json" >&2; tail -n 20 "$out/stderr.log" >&2; }
echo "exit $code"
exit "$code"
