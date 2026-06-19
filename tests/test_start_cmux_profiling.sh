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

submit_output="$("$ROOT_DIR/Resources/bin/submit-cmux-profile" --dry-run --profile "$timeout_out" --target-name "cmux DEV dog" --target-pid 303 --channel dev --bundle-id com.cmuxterm.app.debug.dog)"
if [[ "$submit_output" != *"Recipient: founders@manaflow.com"* ]] ||
   [[ "$submit_output" != *"Subject: cmux profiling capture: cmux DEV dog"* ]]; then
  echo "FAIL: submit helper dry run did not describe the founders draft" >&2
  echo "$submit_output" >&2
  exit 1
fi

echo "PASS: start-cmux-profiling target selection and default templates"
