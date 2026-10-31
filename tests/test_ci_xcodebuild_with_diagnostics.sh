#!/usr/bin/env bash
# Exercise the xcodebuild diagnostic wrapper with deterministic fake commands.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WRAPPER="$ROOT_DIR/scripts/ci/run-xcodebuild-with-diagnostics.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
# The wrapper keeps a failed build's output under TMPDIR when RUNNER_TEMP is unset.
export TMPDIR="$TMP_DIR"
unset RUNNER_TEMP

cat >"$TMP_DIR/fake-xcodebuild.sh" <<'EOF'
#!/usr/bin/env bash
printf 'fake xcodebuild args: %s\n' "$*"
if [[ -n "${FAKE_XCODEBUILD_ERRORS:-}" ]]; then
  if [[ -n "${FAKE_XCODEBUILD_MANY_ERRORS:-}" ]]; then
    for i in {1..60}; do echo "/src/App/Thing$i.swift:21:42: error: synthetic failure $i"; done
  else
    echo "/src/App/Thing.swift:21:42: error: generic parameter 'T' could not be inferred"
    echo "   |   \`- error: generic parameter 'T' could not be inferred"
    echo "<unknown>:0: error: deinit is marked isolated, but containing class 'TerminalSession' is not isolated to an actor"
  fi
  for _ in {1..200}; do echo "noise line"; done
  echo "/src/App/Thing.swift:21:42: error: generic parameter 'T' could not be inferred"
  echo "** BUILD FAILED **"
  echo "The following build commands failed:"
  echo "	SwiftCompile normal arm64 Thing.swift (in target 'App' from project 'App')"
  echo "(1 failure)"
fi
if [[ -n "${FAKE_XCODEBUILD_PHASE_FAIL:-}" ]]; then
  # An earlier run of the same Embed CEF header (an incremental retry): only the
  # last block under a repeated header is its failure.
  echo "PhaseScriptExecution Embed\\ CEF /build/Script-2.sh (in target 'App' from project 'App')"
  echo "stale-cef-attempt"
  echo ""
  echo "PhaseScriptExecution Bundle\\ acpmux /build/Script-1.sh (in target 'App' from project 'App')"
  echo "    cd /src"
  echo "    export ACTION\\=build"
  echo "bundled acpmux"
  echo ""
  echo "CpResource /build/a.txt /src/a.txt (in target 'App' from project 'App')"
  echo "    builtin-copy /src/a.txt /build"
  echo ""
  echo "PhaseScriptExecution Embed\\ CEF /build/Script-2.sh (in target 'App' from project 'App')"
  echo "    cd /src"
  for i in {1..50}; do echo "    export VAR_$i\\=x"; done
  echo "    /bin/sh -c /build/Script-2.sh"
  for i in {1..35}; do echo "cef-line-$i"; done
  echo "cmux Helper (Renderer).app: replacing existing signature"
  echo ""
  # Another phase between the failed phase and its failure line: the report
  # must still pin the failure on Embed CEF, from the failed-commands list.
  echo "PhaseScriptExecution Copy\\ licenses /build/Script-4.sh (in target 'App' from project 'App')"
  echo "    cd /src"
  echo "licenses copied"
  echo "Command PhaseScriptExecution failed with a nonzero exit code"
  echo ""
  echo "PhaseScriptExecution Bundle\\ cmux-tui /build/Script-3.sh (in target 'App' from project 'App')"
  echo "    cd /src"
  echo "tui: missing tree"
  echo "Command PhaseScriptExecution failed with a nonzero exit code"
  echo ""
  echo "** BUILD FAILED **"
  echo "The following build commands failed:"
  echo "	PhaseScriptExecution Embed\\ CEF /build/Script-2.sh (in target 'App' from project 'App')"
  echo "	PhaseScriptExecution Bundle\\ cmux-tui /build/Script-3.sh (in target 'App' from project 'App')"
  echo "(2 failures)"
fi
if [[ -n "${FAKE_XCODEBUILD_DELAY:-}" ]]; then
  python3 -c 'import os, time; time.sleep(float(os.environ["FAKE_XCODEBUILD_DELAY"]))'
fi
exit "${FAKE_XCODEBUILD_STATUS:-0}"
EOF
chmod +x "$TMP_DIR/fake-xcodebuild.sh"

if ! "$WRAPPER" -- "$TMP_DIR/fake-xcodebuild.sh" -scheme cmux >"$TMP_DIR/success.log" 2>&1; then
  echo "FAIL: wrapper must preserve a successful xcodebuild exit" >&2
  exit 1
fi
grep -Fq 'xcodebuild exit status: 0' "$TMP_DIR/success.log"
grep -Fq 'fake xcodebuild args: -scheme cmux' "$TMP_DIR/success.log"

set +e
FAKE_XCODEBUILD_STATUS=137 "$WRAPPER" -- "$TMP_DIR/fake-xcodebuild.sh" -scheme cmux >"$TMP_DIR/failure.log" 2>&1
status=$?
set -e
if [[ "$status" -ne 137 ]]; then
  echo "FAIL: wrapper must return the xcodebuild status, got $status" >&2
  exit 1
fi
grep -Fq 'xcodebuild exit status: 137' "$TMP_DIR/failure.log"
grep -Fq 'xcodebuild termination: signal=9' "$TMP_DIR/failure.log"
grep -Fq 'resource diagnostics follow' "$TMP_DIR/failure.log"
grep -Fq -- '--- top processes by resident memory ---' "$TMP_DIR/failure.log"

set +e
FAKE_XCODEBUILD_ERRORS=1 FAKE_XCODEBUILD_STATUS=65 \
  "$WRAPPER" -- "$TMP_DIR/fake-xcodebuild.sh" -scheme cmux >"$TMP_DIR/errors.log" 2>&1
status=$?
set -e
if [[ "$status" -ne 65 ]]; then
  echo "FAIL: wrapper must return xcodebuild's exit 65, got $status" >&2
  exit 1
fi
# Each distinct error becomes one annotation, with file and line when present.
if [[ "$(grep -c '^::error file=/src/App/Thing.swift,line=21,col=42::generic parameter' "$TMP_DIR/errors.log")" -ne 1 ]]; then
  echo "FAIL: a located compiler error must become exactly one file annotation" >&2
  cat "$TMP_DIR/errors.log" >&2
  exit 1
fi
grep -Fq "::error::<unknown>:0: error: deinit is marked isolated" "$TMP_DIR/errors.log"
set +e
FAKE_XCODEBUILD_ERRORS=1 FAKE_XCODEBUILD_MANY_ERRORS=1 FAKE_XCODEBUILD_STATUS=65 \
  "$WRAPPER" -- "$TMP_DIR/fake-xcodebuild.sh" -scheme cmux >"$TMP_DIR/many-errors.log" 2>&1
status=$?
set -e
if [[ "$status" -ne 65 ]]; then
  echo "FAIL: many-error fixture must preserve xcodebuild's exit 65, got $status" >&2
  exit 1
fi
grep -Fq -- '--- first 50 xcodebuild error lines' "$TMP_DIR/many-errors.log"
first_error_section_count="$(awk '
  /--- first 50 xcodebuild error lines/ { section++; next }
  section == 1 && /^--- / { exit }
  section == 1 && /^\/src\/App\/Thing[0-9][0-9]*\.swift:21:42: error: synthetic failure/ { count++ }
  END { print count + 0 }
' "$TMP_DIR/many-errors.log")"
if [[ "$first_error_section_count" -ne 50 ]]; then
  echo "FAIL: the wrapper must print the first 50 distinct error lines" >&2
  exit 1
fi
if grep -q '^::error.*`- error' "$TMP_DIR/errors.log"; then
  echo "FAIL: the pretty-printed diagnostic gutter must not become an annotation" >&2
  exit 1
fi
# The log ends with the errors, after the resource diagnostics.
tail -n 12 "$TMP_DIR/errors.log" | grep -Fq "<unknown>:0: error: deinit is marked isolated"
tail -n 12 "$TMP_DIR/errors.log" | grep -Fq "The following build commands failed:"
grep -Fq 'noise line' "$TMP_DIR/errors.log"

for invalid_interval in 0 0.0 00; do
  if CMUX_XCODEBUILD_HEARTBEAT_SECONDS="$invalid_interval" \
    "$WRAPPER" -- "$TMP_DIR/fake-xcodebuild.sh" -scheme cmux >"$TMP_DIR/invalid.log" 2>&1; then
    echo "FAIL: heartbeat interval $invalid_interval must be rejected" >&2
    exit 1
  fi
done

: >"$TMP_DIR/heartbeat.log"
FAKE_XCODEBUILD_DELAY=0.3 \
  CMUX_XCODEBUILD_HEARTBEAT_SECONDS=0.05 \
  "$WRAPPER" -- "$TMP_DIR/fake-xcodebuild.sh" -scheme cmux >"$TMP_DIR/heartbeat.log" 2>&1 &
wrapper_pid=$!
for _ in {1..500}; do
  if grep -Fq 'xcodebuild heartbeat:' "$TMP_DIR/heartbeat.log"; then
    break
  fi
  sleep 0.02
done
if ! grep -Fq 'xcodebuild heartbeat:' "$TMP_DIR/heartbeat.log"; then
  kill "$wrapper_pid" 2>/dev/null || true
  wait "$wrapper_pid" 2>/dev/null || true
  echo "FAIL: wrapper must emit a heartbeat while xcodebuild is quiet" >&2
  exit 1
fi
if ! wait "$wrapper_pid"; then
  echo "FAIL: heartbeat test command should complete successfully" >&2
  exit 1
fi

cat >"$TMP_DIR/fake-descendant.sh" <<'EOF'
#!/usr/bin/env bash
descendant_marker="${FAKE_DESCENDANT_MARKER:?}"
(
  trap '' INT TERM
  while :; do sleep 1; done
) &
printf '%s\n' "$!" >"$descendant_marker"
trap 'exit 0' INT TERM
while :; do sleep 1; done
EOF
chmod +x "$TMP_DIR/fake-descendant.sh"
: >"$TMP_DIR/descendant.log"
FAKE_DESCENDANT_MARKER="$TMP_DIR/descendant.pid" \
  CMUX_XCODEBUILD_HEARTBEAT_SECONDS=0.05 \
  "$WRAPPER" -- "$TMP_DIR/fake-descendant.sh" >"$TMP_DIR/descendant.log" 2>&1 &
wrapper_pid=$!
for _ in {1..500}; do
  if [[ -s "$TMP_DIR/descendant.pid" ]]; then
    break
  fi
  sleep 0.02
done
if [[ ! -s "$TMP_DIR/descendant.pid" ]]; then
  kill -TERM "$wrapper_pid" 2>/dev/null || true
  wait "$wrapper_pid" 2>/dev/null || true
  echo "FAIL: cancellation fixture did not start its descendant" >&2
  exit 1
fi
descendant_pid="$(cat "$TMP_DIR/descendant.pid")"
kill -TERM "$wrapper_pid"
wait "$wrapper_pid" 2>/dev/null || true
if kill -0 "$descendant_pid" 2>/dev/null \
  && ! ps -p "$descendant_pid" -o state= 2>/dev/null | grep -q 'Z'; then
  kill -KILL "$descendant_pid" 2>/dev/null || true
  echo "FAIL: cancellation must reap descendants that ignore SIGTERM" >&2
  exit 1
fi

set +e
FAKE_XCODEBUILD_PHASE_FAIL=1 FAKE_XCODEBUILD_STATUS=65 \
  "$WRAPPER" -- "$TMP_DIR/fake-xcodebuild.sh" -scheme cmux >"$TMP_DIR/phase.log" 2>&1
status=$?
set -e
if [[ "$status" -ne 65 ]]; then
  echo "FAIL: phase-failure fixture must preserve xcodebuild's exit 65, got $status" >&2
  exit 1
fi
# One section per failed phase: header line through its annotation.
phase_report() {
  # ENVIRON, not -v: awk -v reads escapes, so gawk and BSD awk turn the "\ " of
  # an escaped phase name into a plain space.
  WANT="$1" awk '/^--- failed run script phase:/ { show = index($0, ENVIRON["WANT"]) > 0 } show { print } /^::error::run script phase failed:/ { show = 0 }' "$TMP_DIR/phase.log"
}
cef_section="$(phase_report 'Embed\ CEF')"
tui_section="$(phase_report 'Bundle\ cmux-tui')"
grep -Fxq 'cef-line-35' <<<"$cef_section"
grep -Fxq 'cef-line-7' <<<"$cef_section"
grep -Fxq 'cmux Helper (Renderer).app: replacing existing signature' <<<"$cef_section"
grep -Fxq '::error::run script phase failed: Embed CEF' <<<"$cef_section"
if grep -Eq '^cef-line-6$|export VAR_|bundled acpmux|builtin-copy|/bin/sh -c|stale-cef-attempt' <<<"$cef_section"; then
  echo "FAIL: a failed phase report holds only that phase's last 30 output lines" >&2
  exit 1
fi
grep -Fxq 'tui: missing tree' <<<"$tui_section"
grep -Fxq '::error::run script phase failed: Bundle cmux-tui' <<<"$tui_section"
if grep -Fq 'licenses copied' <<<"$cef_section" || grep -Fq 'Copy\ licenses' "$TMP_DIR/phase.log" \
  && grep -Fq -- '--- failed run script phase: PhaseScriptExecution Copy' "$TMP_DIR/phase.log"; then
  echo "FAIL: a phase that did not fail never gets a failure report or another phase's lines" >&2
  exit 1
fi
if grep -Fq 'cef-line' <<<"$tui_section"; then
  echo "FAIL: each failed phase reports only its own output" >&2
  exit 1
fi

echo "PASS: xcodebuild failures retain diagnostics and quiet builds emit heartbeats"
