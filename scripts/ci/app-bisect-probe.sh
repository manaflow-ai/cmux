#!/usr/bin/env bash
# One probe of app_build_bisect.py, run on a GUI Mac: does cmux NEXT at COMMIT chat?
#
#   app-bisect-probe.sh COMMIT [COPY_APP]
#
# It never touches the person's running app. COPY_APP (default: $APP_BISECT_COPY, else
# ~/Applications/cmux-bisect-copy.app) is a side-by-side copy of NIGHTLY with its own socket, made once with
# `cmux app try . --from "/Applications/cmux NIGHTLY.app"` (or any copy). `cmux app try COMMIT --app COPY_APP`
# moves the copy to COMMIT (a live build when CI published one, else that commit's nightly), then
# `cmux --app-socket SOCK app health --json` asks it whether a chat starts, the model picker has models and a
# terminal echoes (the post-update probe, cmux app health). APP_BISECT_HEALTH overrides that command (the words
# get the socket appended) for a CLI that has no `app health` yet.
#
# Exit codes are git bisect's: 0 good, 1 bad, 125 no build of COMMIT to try (skip), 3 the probe could not run.
set -uo pipefail

commit="${1:?usage: app-bisect-probe.sh COMMIT [COPY_APP]}"
copy="${2:-${APP_BISECT_COPY:-$HOME/Applications/cmux-bisect-copy.app}}"
cli="${APP_BISECT_CLI:-cmux}"
if [ ! -d "$copy" ]; then
  echo "app-bisect-probe: no copy app at $copy; make one: cmux app try . --from \"/Applications/cmux NIGHTLY.app\"" >&2
  exit 3
fi
case "$copy" in
  /Applications/cmux*.app) echo "app-bisect-probe: $copy is an installed app, not a copy" >&2; exit 3 ;;
esac

try_out="$("$cli" app try "$commit" --app "$copy" 2>&1)"
try_rc=$?
printf '%s\n' "$try_out"
if [ "$try_rc" -ne 0 ]; then
  # `cmux app try` never builds: no live build and no nightly of COMMIT means skip, anything else broke.
  if printf '%s' "$try_out" | grep -qiE 'no (live )?build|not in the (nightly )?feed|missing build|no nightly'; then
    exit 125
  fi
  exit 3
fi

sock="${APP_BISECT_SOCKET:-}"
if [ -z "$sock" ]; then
  sock="$(printf '%s\n' "$try_out" | grep -oE '/[^ ]*\.sock' | tail -1)"
fi
if [ -z "$sock" ]; then
  sock="$("$cli" app try status --json 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("socket") or d.get("app_socket") or "")' 2>/dev/null)"
fi
[ -n "$sock" ] || { echo "app-bisect-probe: no socket for $copy" >&2; exit 3; }

# Give the moved app its relaunch and its acpmux start before asking.
for _ in $(seq 1 30); do
  "$cli" --app-socket "$sock" ping >/dev/null 2>&1 && break
  sleep 2
done
if [ -n "${APP_BISECT_HEALTH:-}" ]; then
  # shellcheck disable=SC2086
  out="$($APP_BISECT_HEALTH "$sock" 2>&1)"; rc=$?
else
  out="$("$cli" --app-socket "$sock" app health --json 2>&1)"; rc=$?
fi
printf '%s\n' "$out"
case "$rc" in
  0) exit 0 ;;
  1) exit 1 ;;
  *) exit 3 ;;
esac
