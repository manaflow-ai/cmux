#!/bin/bash
# The app=SHA proof inside a throwaway guest (macos-locked-screen-cu.sh copies it to ~/lsc with the
# tagged DEV app in ~/lsc/app, lockprobe, tcc-grant.sh and scripts/cmux-next's cua-helper-v2-live.py
# with its probe files and tag_teardown.py in ~/lsc/cmux-next).
#   guest-app.sh grant         over SSH: picks the python, then grants (tcc-grant.sh) Screen
#                              Recording, Accessibility and event posting to the helper's executable
#                              in "cmux Computer Use (dev).app" (by path, and by its bundle id),
#                              the app's own executable, /bin/bash and that python
#   guest-app.sh run PASS      as a LaunchAgent in the console user's session: one
#                              cua-helper-v2-live.py run, PASS locked (--while-locked --lock-with
#                              lockprobe: expect it to work on the locked screen) or refused
#                              (--lock-with lockprobe only: expect mac_locked)
# The python: /opt/homebrew/bin/python3 when the image has one that runs, else the image's
# /usr/bin/python3 (Command Line Tools; only when xcode-select names them, so the shim never asks to
# install them). python.txt in the output says which. Output in ~/lsc/out/PASS; ~/lsc/status-PASS
# holds the live script's exit code when it is done.
set -u
D=/Users/lume/lsc
TAG=$(cat "$D/tag" 2>/dev/null || echo lscproof)
APP=$(ls -d "$D"/app/*.app 2>/dev/null | head -1)
HELPER="$APP/Contents/Library/cmux Computer Use (dev).app"
plist_get() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null; }

pick_python() {
  local py
  for py in /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
    [[ -x "$py" ]] || continue
    if [[ "$py" == /usr/bin/python3 ]]; then
      xcode-select -p >/dev/null 2>&1 || continue
    fi
    "$py" -c 'import ctypes, json, sys; assert sys.version_info >= (3, 9)' >/dev/null 2>&1 && { echo "$py"; return 0; }
  done
  return 1
}

case "${1:-}" in
  grant)
    [[ -n "$APP" && -d "$HELPER" ]] || { echo "guest-app.sh: no app with cmux Computer Use (dev).app in $D/app" >&2; exit 1; }
    PY=$(pick_python) || { echo "guest-app.sh: no python3 3.9+ in the guest (no Homebrew python, no Command Line Tools)" >&2; exit 1; }
    echo "$PY" >"$D/python"
    # The binary that runs: a framework python execs Resources/Python.app; TCC asks about that one too.
    py_paths=$("$PY" -c 'import os, sys
print(os.path.realpath(sys.executable))
app = os.path.join(sys.base_prefix, "Resources/Python.app/Contents/MacOS/Python")
print(app if os.path.exists(app) else "")')
    py_real=$(sed -n 1p <<<"$py_paths") py_app=$(sed -n 2p <<<"$py_paths")
    printf 'python %s (%s) real %s app %s\n' "$PY" "$("$PY" --version 2>&1)" "$py_real" "${py_app:-none}" | tee "$D/python.txt"
    helper_exe="$HELPER/Contents/MacOS/$(plist_get "$HELPER" CFBundleExecutable)"
    app_exe="$APP/Contents/MacOS/$(plist_get "$APP" CFBundleExecutable)"
    grants=(/bin/bash "$helper_exe" "$app_exe" "$py_real")
    [[ -n "$py_app" ]] && grants+=("$py_app")
    bash "$D/tcc-grant.sh" "${grants[@]}"
    ;;
  run)
    PASS="${2:-}"
    case "$PASS" in
      locked) flags=(--while-locked --lock-with "$D/lockprobe") ;;
      refused) flags=(--lock-with "$D/lockprobe") ;;
      *) echo "guest-app.sh: run locked|refused" >&2; exit 2 ;;
    esac
    O="$D/out/$PASS"
    mkdir -p "$O"
    cp "$D/python.txt" "$O/" 2>/dev/null
    PY=$(cat "$D/python" 2>/dev/null)
    "$D/lockprobe" state >"$O/session-before.json" 2>&1
    rc=9
    if [[ -x "$PY" && -n "$APP" ]]; then
      "$PY" "$D/cmux-next/cua-helper-v2-live.py" --app "$APP" --tag "$TAG" --out "$O" --window-python "$PY" \
        "${flags[@]}" >"$O/live.stdout" 2>&1
      rc=$?
    else
      echo "guest-app.sh: no python ($PY) or no app ($APP)" >"$O/live.stdout"
    fi
    "$D/lockprobe" state >"$O/session-after.json" 2>&1
    echo "$rc" >"$D/status-$PASS"
    ;;
  *) echo "usage: guest-app.sh grant | run locked|refused" >&2; exit 2 ;;
esac
