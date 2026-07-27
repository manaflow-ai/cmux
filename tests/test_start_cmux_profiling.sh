#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT_DIR/Resources/bin/start-cmux-profiling"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

make_app() {
  local path="$1"
  local bundle_id="$2"
  local display_name="$3"
  mkdir -p "$path/Contents/MacOS"
  cat > "$path/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>$bundle_id</string>
  <key>CFBundleDisplayName</key>
  <string>$display_name</string>
</dict>
</plist>
EOF
  : > "$path/Contents/MacOS/cmux"
}

stable_app="$TMP_DIR/cmux.app"
nightly_app="$TMP_DIR/cmux NIGHTLY.app"
dev_app="$TMP_DIR/cmux DEV dog.app"
make_app "$stable_app" "com.cmuxterm.app" "cmux"
make_app "$nightly_app" "com.cmuxterm.app.nightly" "cmux NIGHTLY"
make_app "$dev_app" "com.cmuxterm.app.debug.dog" "cmux DEV dog"

plist_buddy="$TMP_DIR/plistbuddy"
cat > "$plist_buddy" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

command="${2:-}"
plist="${3:-}"
key="${command#Print :}"
python3 - "$key" "$plist" <<'PY'
import plistlib
import sys

key = sys.argv[1]
path = sys.argv[2]
with open(path, "rb") as handle:
    value = plistlib.load(handle).get(key, "")
if value:
    print(value)
PY
EOF
chmod +x "$plist_buddy"
export CMUX_PROFILE_PLIST_BUDDY="$plist_buddy"

defaults_bin="$TMP_DIR/defaults"
cat > "$defaults_bin" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "read" ] && [ "${2:-}" = "com.apple.HIToolbox" ] && [ "${3:-}" = "AppleSelectedInputSources" ]; then
  cat <<'PLIST'
(
    {
        "InputSourceKind" = "Keyboard Layout";
        "KeyboardLayout ID" = 0;
        "KeyboardLayout Name" = "U.S.";
    }
)
PLIST
  exit 0
fi
exit 1
EOF
chmod +x "$defaults_bin"
export CMUX_PROFILE_DEFAULTS="$defaults_bin"

system_profiler_bin="$TMP_DIR/system_profiler"
cat > "$system_profiler_bin" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cat <<'PROFILE'
Graphics/Displays:

    Apple M3 Max:

      Chipset Model: Apple M3 Max
      Metal Support: Metal 3

        Color LCD:

          Resolution: 3456 x 2234 Retina
          Main Display: Yes
          Online: Yes
PROFILE
EOF
chmod +x "$system_profiler_bin"
export CMUX_PROFILE_SYSTEM_PROFILER="$system_profiler_bin"

ps_file="$TMP_DIR/ps.txt"
cat > "$ps_file" <<EOF
101 $stable_app/Contents/MacOS/cmux
202 $nightly_app/Contents/MacOS/cmux
303 $dev_app/Contents/MacOS/cmux
EOF

dry_run="$("$SCRIPT" --dry-run --test-ps-file "$ps_file" --channel dev --tag dog --duration 7 --out "$TMP_DIR/out")"
if [[ "$dry_run" != *"Target: pid=303 channel=dev bundle=com.cmuxterm.app.debug.dog name=cmux DEV dog"* ]]; then
  echo "FAIL: dev tag selector did not choose the tagged dev process" >&2
  echo "$dry_run" >&2
  exit 1
fi
if [[ "$dry_run" != *'--template "Time Profiler" --attach "303" --time-limit 7s'* ]]; then
  echo "FAIL: dry run did not include Time Profiler for the selected process" >&2
  echo "$dry_run" >&2
  exit 1
fi
if [[ "$dry_run" != *'--template "SwiftUI" --attach "303" --time-limit 7s'* ]]; then
  echo "FAIL: dry run did not include SwiftUI for the selected process" >&2
  echo "$dry_run" >&2
  exit 1
fi
if [[ "$dry_run" != *'--template "Allocations" --attach "303" --time-limit 7s'* ]]; then
  echo "FAIL: dry run did not include Allocations for the selected process" >&2
  echo "$dry_run" >&2
  exit 1
fi
if [[ "$dry_run" != *'--template "System Trace" --attach "303" --time-limit 7s'* ]]; then
  echo "FAIL: dry run did not include System Trace for the selected process" >&2
  echo "$dry_run" >&2
  exit 1
fi
if [ -e "$TMP_DIR/out" ]; then
  echo "FAIL: dry run created the output directory" >&2
  find "$TMP_DIR/out" -maxdepth 2 -type f -print >&2
  exit 1
fi

if "$SCRIPT" --dry-run --test-ps-file "$ps_file" --out "$TMP_DIR/ambiguous" >/tmp/cmux-profile-ambiguous.log 2>&1; then
  echo "FAIL: unqualified selection should reject multiple cmux processes" >&2
  exit 1
fi
if ! grep -Fq "multiple cmux processes are running" /tmp/cmux-profile-ambiguous.log; then
  echo "FAIL: ambiguous selection did not explain how to discriminate instances" >&2
  cat /tmp/cmux-profile-ambiguous.log >&2
  exit 1
fi

list_output="$("$SCRIPT" --list-targets --test-ps-file "$ps_file")"
if [[ "$list_output" != *"pid=101 channel=stable bundle=com.cmuxterm.app"* ]] ||
   [[ "$list_output" != *"pid=202 channel=nightly bundle=com.cmuxterm.app.nightly"* ]] ||
   [[ "$list_output" != *"pid=303 channel=dev bundle=com.cmuxterm.app.debug.dog"* ]]; then
  echo "FAIL: --list-targets did not show stable/nightly/dev discrimination" >&2
  echo "$list_output" >&2
  exit 1
fi

fake_bin="$TMP_DIR/fake-bin"
mkdir -p "$fake_bin"
cat > "$fake_bin/xcrun" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "-f" ]; then
  echo "$0"
  exit 0
fi

if [ "${1:-}" = "xctrace" ] && [ "${2:-}" = "record" ]; then
  output=""
  while [ "$#" -gt 0 ]; do
    if [ "$1" = "--output" ]; then
      output="$2"
      break
    fi
    shift
  done
  mkdir -p "$output"
  exit 0
fi

if [ "${1:-}" = "xctrace" ] && [ "${2:-}" = "export" ]; then
  sleep 5
  exit 0
fi

exit 1
EOF
chmod +x "$fake_bin/xcrun"

timeout_out="$TMP_DIR/timeout-out"
HOME="$TMP_DIR" PATH="$fake_bin:$PATH" CMUX_PROFILE_TOC_TIMEOUT_SECONDS=1 "$SCRIPT" \
  --test-ps-file "$ps_file" \
  --channel dev \
  --tag dog \
  --duration 1 \
  --template "Time Profiler" \
  --no-submit \
  --out "$timeout_out" >/dev/null
if ! grep -Fq "Timed out after 1s" "$timeout_out/time-profiler-toc.log"; then
  echo "FAIL: hung TOC export did not time out" >&2
  cat "$timeout_out/time-profiler-toc.log" >&2
  exit 1
fi
if ! grep -Fq "Completed:" "$timeout_out/summary.md"; then
  echo "FAIL: script did not complete after TOC export timeout" >&2
  cat "$timeout_out/summary.md" >&2
  exit 1
fi
if ! grep -Fq "Successful traces: 1" "$timeout_out/summary.md"; then
  echo "FAIL: script did not count the successful trace" >&2
  cat "$timeout_out/summary.md" >&2
  exit 1
fi
if [ ! -f "$timeout_out/system-info.txt" ] ||
   ! grep -Fq "KeyboardLayout Name" "$timeout_out/system-info.txt" ||
   ! grep -Fq "Apple M3 Max" "$timeout_out/system-info.txt" ||
   ! grep -Fq "Excludes serial numbers" "$timeout_out/system-info.txt"; then
  echo "FAIL: script did not write non-sensitive system info" >&2
  cat "$timeout_out/system-info.txt" >&2
  exit 1
fi
if ! grep -Fq "System:" "$timeout_out/summary.md" ||
   ! grep -Fq "App: ~/cmux DEV dog.app" "$timeout_out/summary.md" ||
   ! grep -Fq "Keyboard/input source: U.S." "$timeout_out/summary.md" ||
   ! grep -Fq "More details: system-info.txt" "$timeout_out/summary.md"; then
  echo "FAIL: summary did not preview system info" >&2
  cat "$timeout_out/summary.md" >&2
  exit 1
fi
if grep -Fq "$TMP_DIR/cmux DEV dog.app" "$timeout_out/summary.md" ||
   grep -Fq "$TMP_DIR/cmux DEV dog.app" "$timeout_out/system-info.txt"; then
  echo "FAIL: system info leaked an unredacted home path" >&2
  cat "$timeout_out/summary.md" >&2
  cat "$timeout_out/system-info.txt" >&2
  exit 1
fi

failing_system_profiler="$TMP_DIR/failing-system-profiler"
cat > "$failing_system_profiler" <<'EOF'
#!/usr/bin/env bash
exit 9
EOF
chmod +x "$failing_system_profiler"
display_failed_out="$TMP_DIR/display-failed-out"
PATH="$fake_bin:$PATH" CMUX_PROFILE_SYSTEM_PROFILER="$failing_system_profiler" "$SCRIPT" \
  --test-ps-file "$ps_file" \
  --channel dev \
  --tag dog \
  --duration 1 \
  --template "Time Profiler" \
  --no-submit \
  --out "$display_failed_out" >/dev/null
if ! grep -Fq "Completed:" "$display_failed_out/summary.md" ||
   ! grep -Fq "Displays: unknown" "$display_failed_out/summary.md"; then
  echo "FAIL: optional display probing failure should not abort profiling" >&2
  cat "$display_failed_out/summary.md" >&2
  exit 1
fi

sleep_system_profiler="$TMP_DIR/sleep-system-profiler"
cat > "$sleep_system_profiler" <<'EOF'
#!/usr/bin/env bash
sleep 30
EOF
chmod +x "$sleep_system_profiler"
display_hung_out="$TMP_DIR/display-hung-out"
PATH="$fake_bin:$PATH" CMUX_PROFILE_SYSTEM_PROFILER="$sleep_system_profiler" CMUX_PROFILE_SYSTEM_PROFILER_TIMEOUT_SECONDS=1 "$SCRIPT" \
  --test-ps-file "$ps_file" \
  --channel dev \
  --tag dog \
  --duration 1 \
  --template "Time Profiler" \
  --no-submit \
  --out "$display_hung_out" >/dev/null
if ! grep -Fq "Completed:" "$display_hung_out/summary.md" ||
   ! grep -Fq "Displays: unknown" "$display_hung_out/summary.md"; then
  echo "FAIL: hung optional display probe should time out and not abort profiling" >&2
  cat "$display_hung_out/summary.md" >&2
  exit 1
fi

fail_bin="$TMP_DIR/fail-bin"
mkdir -p "$fail_bin"
cat > "$fail_bin/xcrun" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "-f" ]; then
  echo "$0"
  exit 0
fi

if [ "${1:-}" = "xctrace" ] && [ "${2:-}" = "record" ]; then
  echo "record failed" >&2
  exit 2
fi

exit 1
EOF
chmod +x "$fail_bin/xcrun"

all_failed_out="$TMP_DIR/all-failed-out"
if PATH="$fail_bin:$PATH" "$SCRIPT" \
  --test-ps-file "$ps_file" \
  --channel dev \
  --tag dog \
  --duration 1 \
  --template "Time Profiler" \
  --no-submit \
  --out "$all_failed_out" >/tmp/cmux-profile-all-failed.log 2>&1; then
  echo "FAIL: all-failed profiling run should exit nonzero" >&2
  exit 1
fi
if ! grep -Fq "all profiling templates failed" /tmp/cmux-profile-all-failed.log ||
   ! grep -Fq "Successful traces: 0" "$all_failed_out/summary.md" ||
   grep -Fq "Completed:" "$all_failed_out/summary.md"; then
  echo "FAIL: all-failed profiling run did not surface failure correctly" >&2
  cat /tmp/cmux-profile-all-failed.log >&2
  cat "$all_failed_out/summary.md" >&2
  exit 1
fi

submit_output="$("$ROOT_DIR/Resources/bin/submit-cmux-profile" --dry-run --profile "$timeout_out" --target-name "cmux DEV dog" --target-pid 303 --channel dev --bundle-id com.cmuxterm.app.debug.dog --reply-to "user@example.com")"
if [[ "$submit_output" != *"Recipient: founders@manaflow.com"* ]] ||
   [[ "$submit_output" != *"Reply-to: user@example.com"* ]] ||
   [[ "$submit_output" != *"Subject: cmux profiling capture: cmux DEV dog"* ]]; then
  echo "FAIL: submit helper dry run did not describe the founders draft" >&2
  echo "$submit_output" >&2
  exit 1
fi

archive_path="$(printf '%s\n' "$submit_output" | sed -n 's/^Archive: //p')"
mkdir -p "$(dirname "$archive_path")"
printf 'keep me' > "$archive_path"
"$ROOT_DIR/Resources/bin/submit-cmux-profile" --dry-run --profile "$timeout_out" --target-name "cmux DEV dog" >/dev/null
if [ "$(cat "$archive_path")" != "keep me" ]; then
  echo "FAIL: submit helper dry run modified an existing archive" >&2
  exit 1
fi

cancel_bin="$TMP_DIR/cancel-osascript"
cat > "$cancel_bin" <<'EOF'
#!/usr/bin/env bash
echo "execution error: User canceled. (-128)" >&2
exit 1
EOF
chmod +x "$cancel_bin"

open_bin="$TMP_DIR/open-should-not-run"
cat > "$open_bin" <<'EOF'
#!/usr/bin/env bash
echo "fallback open should not run" >&2
exit 42
EOF
chmod +x "$open_bin"

ditto_bin="$TMP_DIR/ditto"
cat > "$ditto_bin" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
dest="${@: -1}"
mkdir -p "$(dirname "$dest")"
printf 'zip' > "$dest"
EOF
chmod +x "$ditto_bin"

sleep_ditto="$TMP_DIR/sleep-ditto"
sleep_ditto_pid="$TMP_DIR/sleep-ditto.pid"
sleep_ditto_term="$TMP_DIR/sleep-ditto.term"
cat > "$sleep_ditto" <<EOF
#!/usr/bin/env bash
echo "\$\$" > "$sleep_ditto_pid"
trap 'echo term > "$sleep_ditto_term"; exit 143' TERM
while true; do sleep 1; done
EOF
chmod +x "$sleep_ditto"
CMUX_PROFILE_DITTO="$sleep_ditto" "$ROOT_DIR/Resources/bin/submit-cmux-profile" \
  --profile "$timeout_out" \
  --package-only &
sleep_ditto_helper_pid="$!"
for _ in $(seq 1 50); do
  [ -s "$sleep_ditto_pid" ] && break
  sleep 0.1
done
if [ ! -s "$sleep_ditto_pid" ]; then
  echo "FAIL: fake ditto did not start" >&2
  kill "$sleep_ditto_helper_pid" >/dev/null 2>&1 || true
  wait "$sleep_ditto_helper_pid" >/dev/null 2>&1 || true
  exit 1
fi
sleep_ditto_child_pid="$(cat "$sleep_ditto_pid")"
kill "$sleep_ditto_helper_pid"
set +e
wait "$sleep_ditto_helper_pid"
sleep_ditto_helper_status="$?"
set -e
for _ in $(seq 1 50); do
  if ! kill -0 "$sleep_ditto_child_pid" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done
if [ "$sleep_ditto_helper_status" -eq 0 ] ||
   [ ! -f "$sleep_ditto_term" ] ||
   kill -0 "$sleep_ditto_child_pid" >/dev/null 2>&1; then
  echo "FAIL: terminating submit helper did not stop ditto child" >&2
  kill "$sleep_ditto_child_pid" >/dev/null 2>&1 || true
  exit 1
fi

package_output="$(CMUX_PROFILE_DITTO="$ditto_bin" "$ROOT_DIR/Resources/bin/submit-cmux-profile" --profile "$timeout_out" --package-only)"
package_archive="$(printf '%s\n' "$package_output" | sed -n 's/^Archive: //p')"
if [ ! -f "$package_archive" ] || [ "$(cat "$package_archive")" != "zip" ]; then
  echo "FAIL: submit helper package-only did not create the preview archive" >&2
  echo "$package_output" >&2
  exit 1
fi

CMUX_PROFILE_OSASCRIPT="$cancel_bin" CMUX_PROFILE_OPEN="$open_bin" CMUX_PROFILE_DITTO="$ditto_bin" "$ROOT_DIR/Resources/bin/submit-cmux-profile" \
  --profile "$timeout_out" \
  --target-name "cmux DEV dog" \
  --target-pid 303 \
  --channel dev \
  --bundle-id com.cmuxterm.app.debug.dog

sleep_osascript="$TMP_DIR/sleep-osascript"
sleep_osascript_pid="$TMP_DIR/sleep-osascript.pid"
sleep_osascript_term="$TMP_DIR/sleep-osascript.term"
cat > "$sleep_osascript" <<EOF
#!/usr/bin/env bash
echo "\$\$" > "$sleep_osascript_pid"
trap 'echo term > "$sleep_osascript_term"; exit 143' TERM
while true; do sleep 1; done
EOF
chmod +x "$sleep_osascript"
CMUX_PROFILE_OSASCRIPT="$sleep_osascript" CMUX_PROFILE_DITTO="$ditto_bin" "$ROOT_DIR/Resources/bin/submit-cmux-profile" \
  --profile "$timeout_out" \
  --target-name "cmux DEV dog" \
  --target-pid 303 \
  --channel dev \
  --bundle-id com.cmuxterm.app.debug.dog \
  --send &
sleep_helper_pid="$!"
for _ in $(seq 1 50); do
  [ -s "$sleep_osascript_pid" ] && break
  sleep 0.1
done
if [ ! -s "$sleep_osascript_pid" ]; then
  echo "FAIL: fake osascript did not start" >&2
  kill "$sleep_helper_pid" >/dev/null 2>&1 || true
  wait "$sleep_helper_pid" >/dev/null 2>&1 || true
  exit 1
fi
sleep_child_pid="$(cat "$sleep_osascript_pid")"
kill "$sleep_helper_pid"
set +e
wait "$sleep_helper_pid"
sleep_helper_status="$?"
set -e
for _ in $(seq 1 50); do
  if ! kill -0 "$sleep_child_pid" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done
if [ "$sleep_helper_status" -eq 0 ] ||
   [ ! -f "$sleep_osascript_term" ] ||
   kill -0 "$sleep_child_pid" >/dev/null 2>&1; then
  echo "FAIL: terminating submit helper did not stop osascript child" >&2
  kill "$sleep_child_pid" >/dev/null 2>&1 || true
  exit 1
fi

if CMUX_PROFILE_OSASCRIPT="$cancel_bin" CMUX_PROFILE_OPEN="$open_bin" CMUX_PROFILE_DITTO="$ditto_bin" "$ROOT_DIR/Resources/bin/submit-cmux-profile" \
  --profile "$timeout_out" \
  --target-name "cmux DEV dog" \
  --target-pid 303 \
  --channel dev \
  --bundle-id com.cmuxterm.app.debug.dog \
  --send >/tmp/cmux-profile-send-cancel.log 2>&1; then
  echo "FAIL: submit helper send mode should fail when Mail send is canceled" >&2
  exit 1
fi
if ! grep -Fq "User canceled" /tmp/cmux-profile-send-cancel.log; then
  echo "FAIL: submit helper send cancellation did not preserve the AppleScript error" >&2
  cat /tmp/cmux-profile-send-cancel.log >&2
  exit 1
fi

capture_osascript="$TMP_DIR/capture-osascript"
captured_args="$TMP_DIR/captured-osascript-args"
cat > "$capture_osascript" <<EOF
#!/usr/bin/env bash
{
  printf '%s\n' "\$@"
  printf 'BODY:\\n'
  cat "\${5}"
  printf '\\nNOTE:\\n'
  cat "\${10}"
} > "$captured_args"
exit 0
EOF
chmod +x "$capture_osascript"
reply_to_file="$TMP_DIR/reply-to.txt"
note_file="$TMP_DIR/note.txt"
printf '%s' "user@example.com" > "$reply_to_file"
printf '%s' "profile note" > "$note_file"

HOME="$TMP_DIR" CMUX_PROFILE_FEEDBACK_EMAIL=wrong@example.com CMUX_PROFILE_LOCALE=ja_JP CMUX_PROFILE_OSASCRIPT="$capture_osascript" CMUX_PROFILE_DITTO="$ditto_bin" "$ROOT_DIR/Resources/bin/submit-cmux-profile" \
  --profile "$timeout_out" \
  --target-name "cmux DEV dog" \
  --target-pid 303 \
  --channel dev \
  --bundle-id com.cmuxterm.app.debug.dog \
  --recipient founders@manaflow.com \
  --reply-to-file "$reply_to_file" \
  --note-file "$note_file" \
  --send
if ! grep -Fq "cmuxプロファイルを送信" "$captured_args" ||
   ! grep -Fq "下書きを開く" "$captured_args" ||
   ! grep -Fq "cmuxプロファイリングキャプチャ" "$captured_args" ||
   ! grep -Fq "founders@manaflow.com" "$captured_args" ||
   grep -Fq "wrong@example.com" "$captured_args" ||
   ! grep -Fq "user@example.com" "$captured_args" ||
   ! grep -Fq "profile note" "$captured_args" ||
   ! grep -Fq "true" "$captured_args" ||
   grep -Fq "$TMP_DIR/timeout-out" "$captured_args" ||
   ! grep -Fq "~/timeout-out" "$captured_args"; then
  echo "FAIL: submit helper did not pass localized Japanese send strings" >&2
  cat "$captured_args" >&2
  exit 1
fi

echo "PASS: start-cmux-profiling target selection and default templates"
