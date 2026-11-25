#!/usr/bin/env bash
# Published NEXT DEV launch probe: does the signed cmux NEXT DEV release open the control socket the Cloud chat
# proof names, when launched the way scripts/cmux-next/cloud-chat-proof.py launches it?
#
# Leo, 2026-11-10: "you guys... didnt really get cloud working". Every Cloud chat proof since 11-17 fails at
# "launched app ready" (no app at /tmp/cmux-debug-ccp-<run>.sock after 240 s, runs 45205140444, 45430097795).
#
# Cases, each a fresh `open -W -g -n --env CMUX_NEXT_SOCKET_PATH=SOCK APP --args --cloud-backend staging`:
#   a: the caller's environment carries CMUX_SOCKET_PATH=SOCK (as the proof's ENV does);
#   b: the caller's environment carries no CMUX_* variable.
# For each: whether SOCK appears within 90 s, the app's pid, its listening unix sockets, any cmux socket it made
# elsewhere, and its os_log lines. No sign-in, no secret.
#
#   cmux-ci run --class exclusive --label measure --label gui-session-v1 \
#     --script scripts/measure/published-launch-probe.sh --ref SHA --artifact artifacts/published-launch-probe.tgz
# Output: PLP lines; exit 0 when it ran.
set -uo pipefail
root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
out="$root/artifacts/published-launch-probe"
rm -rf "$out" "$root/artifacts/published-launch-probe.tgz"
mkdir -p "$out"
work="$(mktemp -d /tmp/plp.XXXXXX)"
echo "PLP host=$(hostname -s) user=$(id -un) macos=$(sw_vers -productVersion) console=$(stat -f %Su /dev/console)"

url="https://github.com/manaflow-ai/cmux/releases/download/cmux-next-dev/cmux-NEXT-DEV.zip"
curl -fsSL --retry 3 -o "$work/app.zip" "$url" || { echo "PLP download failed"; exit 4; }
ditto -x -k "$work/app.zip" "$work"
app="$(find "$work" -maxdepth 2 -name '*.app' -type d | head -n 1)"
[ -n "$app" ] || { echo "PLP no app in zip"; exit 4; }
xattr -cr "$app"
exe="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")"
echo "PLP app=$app exe=$exe version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")"
/usr/libexec/PlistBuddy -c 'Print :LSEnvironment' "$app/Contents/Info.plist" 2>&1 | sed 's/^/PLP lsenv /'
codesign -dv "$app" 2>&1 | grep -E 'Identifier|TeamIdentifier' | sed 's/^/PLP sign /'

probe() {
  local case="$1" sock="/tmp/cmux-debug-plp-$1-$$.sock" since pid="" ready=no t=0
  rm -f "$sock"
  since="$(date '+%Y-%m-%d %H:%M:%S')"
  if [ "$case" = a ]; then
    env CMUX_SOCKET_PATH="$sock" CMUX_NEXT_SOCKET_PATH="$sock" /usr/bin/open -W -g -n --env "CMUX_NEXT_SOCKET_PATH=$sock" \
      "$app" --args --cloud-backend staging >"$out/open-$case.log" 2>&1 &
  else
    env -u CMUX_SOCKET_PATH -u CMUX_NEXT_SOCKET_PATH -u CMUX_BUNDLE_ID -u CMUX_TAG /usr/bin/open -W -g -n \
      --env "CMUX_NEXT_SOCKET_PATH=$sock" "$app" --args --cloud-backend staging >"$out/open-$case.log" 2>&1 &
  fi
  local opener=$!
  while [ "$t" -lt 90 ]; do
    [ -z "$pid" ] && pid="$(pgrep -n -f "$app/Contents/MacOS/$exe" || true)"
    if [ -S "$sock" ]; then ready=yes; break; fi
    sleep 1; t=$((t + 1))
  done
  echo "PLP case=$case socket_ready=$ready after=${t}s pid=${pid:-none} opener_alive=$(kill -0 $opener 2>/dev/null && echo yes || echo no)"
  if [ -n "$pid" ]; then
    ps -o pid,stat,etime,command -p "$pid" | sed "s/^/PLP $case ps /"
    lsof -nP -a -U -p "$pid" 2>/dev/null | awk '{print $NF}' | grep -v '^NAME$' | sort -u | head -20 | sed "s/^/PLP $case unix /"
    ps -o pid,ppid,command -A | awk -v p="$pid" '$2 == p' | cut -c1-200 | sed "s/^/PLP $case child /"
    sample "$pid" 3 -file "$out/sample-$case.txt" >/dev/null 2>&1 || true
  fi
  ls -la /tmp/cmux*.sock 2>/dev/null | sed "s/^/PLP $case tmpsock /"
  find "$HOME/Library/Application Support/cmux" -maxdepth 3 -type s 2>/dev/null | sed "s/^/PLP $case statesock /"
  log show --style compact --info --debug --start "$since" --predicate 'subsystem BEGINSWITH "com.cmuxterm"' \
    >"$out/log-$case.txt" 2>&1 || true
  echo "PLP $case log_lines=$(wc -l <"$out/log-$case.txt")"
  grep -iE 'error|fail|socket|control|launch|denied|refus' "$out/log-$case.txt" | tail -40 | cut -c1-300 | sed "s/^/PLP $case log /"
  ls -t "$HOME/Library/Logs/DiagnosticReports" 2>/dev/null | grep -i cmux | head -3 | sed "s/^/PLP $case crash /"
  [ -n "$pid" ] && kill "$pid" 2>/dev/null
  sleep 3
  [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null
  wait "$opener" 2>/dev/null
  rm -f "$sock"
}

probe a
probe b
tar -czf "$root/artifacts/published-launch-probe.tgz" -C "$root/artifacts" published-launch-probe
rm -rf "$work"
echo "PLP done"
