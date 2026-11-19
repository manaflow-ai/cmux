#!/usr/bin/env bash
# Runs a build command. When it fails and its log has a stale explicit module failure
# (stale-pcm-retry-needed.sh), clears the DerivedData's build state
# (clear-stale-scheme-build-state.sh) and runs the command ONE more time.
#
# For a build in a DerivedData that is kept between builds: a header of a binary module (the app FFI)
# changes, the kept explicit module was built from the older header, and xcodebuild fails with
# "... has been modified since the module file ... was built" (exit 65). check-release-compile.sh and
# check-cmux-scheme-compile.sh do the same in their own build steps. reload.sh runs a measurement
# step's xcodebuild through this script, inside its xcodebuild lock, so both builds hold one lock.
#
# Usage: stale-module-second-build.sh DERIVED_DATA LOG COMMAND [ARG...]
#   LOG  the file that the command's output goes to. The caller sends the output there; this script
#        only reads it. Its own line goes to stdout, and to fd 4 when the caller keeps a terminal
#        there while stdout is a log (reload.sh does).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
usage="usage: stale-module-second-build.sh DERIVED_DATA LOG COMMAND [ARG...]"
[[ $# -ge 3 ]] || { echo "$usage" >&2; exit 2; }
derived_data="$1"; log="$2"
shift 2

status=0
"$@" || status=$?
if (( status )) && "$here/stale-pcm-retry-needed.sh" "$log"; then
  said="stale module: second build (the first build exited $status; clearing the build state of $derived_data)"
  echo "$said"
  if { true >&4; } 2>/dev/null; then echo "==> $said" >&4; fi
  "$here/clear-stale-scheme-build-state.sh" "$derived_data"
  status=0
  "$@" || status=$?
fi
exit "$status"
