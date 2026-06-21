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
PATH="$fake_bin:$PATH" CMUX_PROFILE_TOC_TIMEOUT_SECONDS=1 "$SCRIPT" \
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

submit_output="$("$ROOT_DIR/Resources/bin/submit-cmux-profile" --dry-run --profile "$timeout_out" --target-name "cmux DEV dog" --target-pid 303 --channel dev --bundle-id com.cmuxterm.app.debug.dog)"
if [[ "$submit_output" != *"Recipient: founders@manaflow.com"* ]] ||
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

CMUX_PROFILE_OSASCRIPT="$cancel_bin" CMUX_PROFILE_OPEN="$open_bin" CMUX_PROFILE_DITTO="$ditto_bin" "$ROOT_DIR/Resources/bin/submit-cmux-profile" \
  --profile "$timeout_out" \
  --target-name "cmux DEV dog" \
  --target-pid 303 \
  --channel dev \
  --bundle-id com.cmuxterm.app.debug.dog

capture_osascript="$TMP_DIR/capture-osascript"
captured_args="$TMP_DIR/captured-osascript-args"
cat > "$capture_osascript" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$captured_args"
exit 0
EOF
chmod +x "$capture_osascript"

CMUX_PROFILE_LOCALE=ja_JP CMUX_PROFILE_OSASCRIPT="$capture_osascript" CMUX_PROFILE_DITTO="$ditto_bin" "$ROOT_DIR/Resources/bin/submit-cmux-profile" \
  --profile "$timeout_out" \
  --target-name "cmux DEV dog" \
  --target-pid 303 \
  --channel dev \
  --bundle-id com.cmuxterm.app.debug.dog
if ! grep -Fq "cmuxプロファイルを送信" "$captured_args" ||
   ! grep -Fq "下書きを開く" "$captured_args" ||
   ! grep -Fq "cmuxプロファイリングキャプチャ" "$captured_args"; then
  echo "FAIL: submit helper did not pass localized Japanese dialog/body strings" >&2
  cat "$captured_args" >&2
  exit 1
fi

echo "PASS: start-cmux-profiling target selection and default templates"
