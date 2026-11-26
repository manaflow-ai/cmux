#!/usr/bin/env bash
# Behavioral guard for resumable, mirror-isolated Zig downloads.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/install-zig-ci.sh"
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

case "$(uname -s)" in
  Darwin) ZIG_OS="macos" ;;
  Linux) ZIG_OS="linux" ;;
  *)
    echo "Unsupported test operating system: $(uname -s)" >&2
    exit 1
    ;;
esac

case "$(uname -m)" in
  arm64 | aarch64) ZIG_ARCH="aarch64" ;;
  x86_64) ZIG_ARCH="x86_64" ;;
  *)
    echo "Unsupported test architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

ZIG_REQUIRED="99.99.99"
ZIG_NAME="zig-${ZIG_ARCH}-${ZIG_OS}-${ZIG_REQUIRED}"
FIXTURE_ROOT="$TMP_DIR/fixture"
ARCHIVE="$TMP_DIR/${ZIG_NAME}.tar.xz"
BIN_DIR="$TMP_DIR/bin"
RUNNER_TEMP="$TMP_DIR/runner-temp"
OUTPUT_FILE="$TMP_DIR/output"
CURL_LOG="$TMP_DIR/curl.log"
RESUME_RUNNER_TEMP="$TMP_DIR/resume-runner-temp"
RESUME_OUTPUT_FILE="$TMP_DIR/resume-output"
RESUME_CURL_LOG="$TMP_DIR/resume-curl.log"
RANGE_RUNNER_TEMP="$TMP_DIR/range-runner-temp"
RANGE_OUTPUT_FILE="$TMP_DIR/range-output"
RANGE_CURL_LOG="$TMP_DIR/range-curl.log"
BUDGET_RUNNER_TEMP="$TMP_DIR/budget-runner-temp"
BUDGET_OUTPUT_FILE="$TMP_DIR/budget-output"
BUDGET_CURL_LOG="$TMP_DIR/budget-curl.log"
BUDGET_CLOCK_FILE="$TMP_DIR/budget-clock"
MINISIGN_BIN_DIR="$TMP_DIR/minisign-bin"

mkdir -p "$FIXTURE_ROOT/$ZIG_NAME/lib/compiler" "$BIN_DIR" "$MINISIGN_BIN_DIR"
cat > "$FIXTURE_ROOT/$ZIG_NAME/zig" <<EOF
#!/usr/bin/env bash
set -euo pipefail
self="\$0"
if [ -L "\$self" ]; then
  target="\$(readlink "\$self")"
  case "\$target" in
    /*) self="\$target" ;;
    *) self="\$(cd "\$(dirname "\$self")" && pwd -P)/\$target" ;;
  esac
fi
case "\${1:-}" in
  version) echo "$ZIG_REQUIRED" ;;
  env)
    zig_dir="\$(cd "\$(dirname "\$self")" && pwd -P)"
    printf '.{\\n    .lib_dir = "%s/lib",\\n}\\n' "\$zig_dir"
    ;;
  *) echo "$ZIG_REQUIRED" ;;
esac
EOF
chmod +x "$FIXTURE_ROOT/$ZIG_NAME/zig"
printf 'build runner fixture\n' > "$FIXTURE_ROOT/$ZIG_NAME/lib/compiler/build_runner.zig"
printf 'large fixture payload\n' > "$FIXTURE_ROOT/$ZIG_NAME/lib/std"
(cd "$FIXTURE_ROOT" && tar -cf "$ARCHIVE" "$ZIG_NAME")

if command -v shasum >/dev/null 2>&1; then
  ARCHIVE_SHA256="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
else
  ARCHIVE_SHA256="$(sha256sum "$ARCHIVE" | awk '{print $1}')"
fi

cat > "$BIN_DIR/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

url=""
output=""
continue_at=""
max_time=""
state_file="${CURL_LOG:?}.state"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --continue-at)
      continue_at="$2"
      shift 2
      ;;
    --max-time)
      max_time="$2"
      shift 2
      ;;
    --output)
      output="$2"
      shift 2
      ;;
    http://primary.invalid/*|https://primary.invalid/*|http://secondary.invalid/*|https://secondary.invalid/*|http://tertiary.invalid/*|https://tertiary.invalid/*|http://official.invalid/*|https://official.invalid/*)
      url="$1"
      shift
      ;;
    *)
      shift
      ;;
  esac
done

[ "$continue_at" = "-" ] || {
  echo "curl did not request resumable transfer" >&2
  exit 2
}
[ -n "$url" ] || {
  echo "curl stub did not receive a mirror URL" >&2
  exit 2
}
[ -n "$output" ] || {
  echo "curl stub did not receive an output path" >&2
  exit 2
}
[ -n "$max_time" ] || {
  echo "curl stub did not receive --max-time" >&2
  exit 2
}

resume_offset=0
if [ -f "$output" ]; then
  resume_offset="$(wc -c < "$output" | tr -d ' ')"
fi
  printf '%s\t%s\tcontinue-at=%s\tresume-offset=%s\tmax-time=%s\n' "$url" "$output" "$continue_at" "$resume_offset" "$max_time" >> "${CURL_LOG:?}"

  if [ -n "${FAKE_CURL_CLOCK_FILE:-}" ]; then
    elapsed=6
    if [ "$max_time" -lt "$elapsed" ]; then
      elapsed="$max_time"
    fi
    now="$(cat "$FAKE_CURL_CLOCK_FILE")"
    printf '%s\n' "$((now + elapsed))" > "$FAKE_CURL_CLOCK_FILE"
  fi

case "$url" in
  *primary.invalid*)
    if [ "${FAKE_CURL_MODE:?}" = "resume" ] && [ ! -e "$state_file" ]; then
      : > "$state_file"
      head -c 32 "${FAKE_ZIG_ARCHIVE:?}" > "$output"
      exit 28
    fi
    if [ "${FAKE_CURL_MODE:?}" = "range-reset" ] && [ ! -e "$state_file" ]; then
      : > "$state_file"
      printf 'stale bytes that cannot be resumed\n' > "$output"
      exit 33
    fi
    if [ "${FAKE_CURL_MODE:?}" = "fallback" ]; then
      printf 'partial bytes from primary\n' > "$output"
      exit 1
    fi
    ;;
esac

  cp "${FAKE_ZIG_ARCHIVE:?}" "$output"
EOF
chmod +x "$BIN_DIR/curl"

cat > "$BIN_DIR/sudo" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$BIN_DIR/sudo"

cat > "$MINISIGN_BIN_DIR/minisign" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$MINISIGN_BIN_DIR/minisign"

run_install() {
  local mode="$1"
  local runner_temp="$2"
  local output_file="$3"
  local curl_log="$4"
  local budget_seconds="${5:-480}"
  local clock_file="${6:-}"
  local include_minisign="${7:-0}"
  local path_prefix="$BIN_DIR"
  if [ "$include_minisign" = "1" ]; then
    path_prefix="$MINISIGN_BIN_DIR:$path_prefix"
  fi
  PATH="$path_prefix:/usr/bin:/bin" \
    RUNNER_TEMP="$runner_temp" \
    FAKE_CURL_MODE="$mode" \
    ZIG_DOWNLOAD_BUDGET_SECONDS="$budget_seconds" \
    ZIG_DOWNLOAD_RETRY_DELAY=0 \
    FAKE_ZIG_ARCHIVE="$ARCHIVE" \
    CURL_LOG="$curl_log" \
    FAKE_CURL_CLOCK_FILE="$clock_file" \
    ZIG_DOWNLOAD_TEST_CLOCK_FILE="$clock_file" \
    ZIG_REQUIRED="$ZIG_REQUIRED" \
    ZIG_EXPECTED_SHA256="$ARCHIVE_SHA256" \
    ZIG_MIRROR_URL="https://primary.invalid/$ZIG_NAME.tar.xz" \
    ZIG_SECONDARY_MIRROR_URL="https://secondary.invalid/$ZIG_NAME.tar.xz" \
    ZIG_TERTIARY_MIRROR_URL="https://tertiary.invalid/$ZIG_NAME.tar.xz" \
    ZIG_OFFICIAL_URL="https://official.invalid/$ZIG_NAME.tar.xz" \
    "$SCRIPT" > "$output_file" 2>&1
}

if ! grep -Fq 'zig-mirror.tsimnet.eu/zig/' "$SCRIPT"; then
  echo "FAIL: installer does not use the verified Tsimnet mirror by default" >&2
  exit 1
fi

printf '0\n' > "$BUDGET_CLOCK_FILE"
run_install resume "$BUDGET_RUNNER_TEMP" "$BUDGET_OUTPUT_FILE" "$BUDGET_CURL_LOG" 42 "$BUDGET_CLOCK_FILE" 1
if [ "$(cat "$BUDGET_CLOCK_FILE")" -ne 18 ]; then
  cat "$BUDGET_OUTPUT_FILE"
  cat "$BUDGET_CURL_LOG"
  echo "FAIL: resumable download exceeded its virtual invocation deadline" >&2
  exit 1
fi
if ! awk -F '\t' '{ split($5, timeout, "="); if (timeout[2] > 42) { invalid = 1 } } END { exit(invalid ? 1 : 0) }' "$BUDGET_CURL_LOG"; then
  cat "$BUDGET_OUTPUT_FILE"
  cat "$BUDGET_CURL_LOG"
  echo "FAIL: curl attempt timeouts exceeded the invocation budget" >&2
  exit 1
fi
if ! awk -F '\t' '$1 ~ /primary\.invalid/ && $2 !~ /\.minisig/ && $5 == "max-time=42" { found = 1 } END { exit(found ? 0 : 1) }' "$BUDGET_CURL_LOG"; then
  cat "$BUDGET_OUTPUT_FILE"
  cat "$BUDGET_CURL_LOG"
  echo "FAIL: first curl process was not clamped to the remaining budget" >&2
  exit 1
fi
if ! awk -F '\t' '$1 ~ /primary\.invalid/ && $2 !~ /\.minisig/ && $4 == "resume-offset=32" && $5 == "max-time=36" { found = 1 } END { exit(found ? 0 : 1) }' "$BUDGET_CURL_LOG"; then
  cat "$BUDGET_OUTPUT_FILE"
  cat "$BUDGET_CURL_LOG"
  echo "FAIL: retry did not resume with the deadline-clamped timeout" >&2
  exit 1
fi
if ! awk -F '\t' '$1 ~ /primary\.invalid/ && $2 ~ /\.minisig\.primary\.part/ && $5 == "max-time=30" { found = 1 } END { exit(found ? 0 : 1) }' "$BUDGET_CURL_LOG"; then
  cat "$BUDGET_OUTPUT_FILE"
  cat "$BUDGET_CURL_LOG"
  echo "FAIL: signature download did not receive its remaining invocation budget" >&2
  exit 1
fi
if [ ! -x "$BUDGET_RUNNER_TEMP/$ZIG_NAME/zig" ]; then
  cat "$BUDGET_OUTPUT_FILE"
  echo "FAIL: budgeted resumable transfer did not install Zig" >&2
  exit 1
fi

run_install resume "$RESUME_RUNNER_TEMP" "$RESUME_OUTPUT_FILE" "$RESUME_CURL_LOG"
if [ ! -x "$RESUME_RUNNER_TEMP/$ZIG_NAME/zig" ]; then
  cat "$RESUME_OUTPUT_FILE"
  echo "FAIL: resumable primary transfer did not install Zig" >&2
  exit 1
fi
if grep -Fq 'secondary.invalid' "$RESUME_CURL_LOG"; then
  cat "$RESUME_OUTPUT_FILE"
  cat "$RESUME_CURL_LOG"
  echo "FAIL: resumable primary transfer fell back despite completing on retry" >&2
  exit 1
fi
if ! awk -F '\t' '$1 ~ /primary\.invalid/ && $4 == "resume-offset=32" { found = 1 } END { exit(found ? 0 : 1) }' "$RESUME_CURL_LOG"; then
  cat "$RESUME_OUTPUT_FILE"
  cat "$RESUME_CURL_LOG"
  echo "FAIL: later curl process did not resume the primary partial file" >&2
  exit 1
fi

run_install range-reset "$RANGE_RUNNER_TEMP" "$RANGE_OUTPUT_FILE" "$RANGE_CURL_LOG"
if [ ! -x "$RANGE_RUNNER_TEMP/$ZIG_NAME/zig" ]; then
  cat "$RANGE_OUTPUT_FILE"
  echo "FAIL: range-unsupported retry did not install Zig" >&2
  exit 1
fi
if ! awk -F '\t' '$1 ~ /primary\.invalid/ && $4 == "resume-offset=0" { count += 1 } END { exit(count >= 2 ? 0 : 1) }' "$RANGE_CURL_LOG"; then
  cat "$RANGE_OUTPUT_FILE"
  cat "$RANGE_CURL_LOG"
  echo "FAIL: range-unsupported retry did not reset only the affected partial file" >&2
  exit 1
fi

run_install fallback "$RUNNER_TEMP" "$OUTPUT_FILE" "$CURL_LOG"

if ! grep -Fq -- 'continue-at=-' "$CURL_LOG"; then
  cat "$OUTPUT_FILE"
  echo "FAIL: fake curl did not observe a resumable download" >&2
  exit 1
fi

primary_output="$(awk -F '\t' '$1 ~ /primary\.invalid/ { print $2; exit }' "$CURL_LOG")"
secondary_output="$(awk -F '\t' '$1 ~ /secondary\.invalid/ { print $2; exit }' "$CURL_LOG")"
if [ -z "$primary_output" ] || [ -z "$secondary_output" ]; then
  cat "$OUTPUT_FILE"
  cat "$CURL_LOG"
  echo "FAIL: installer did not attempt both mirrors after the primary transfer failed" >&2
  exit 1
fi

if [ "$primary_output" = "$secondary_output" ]; then
  cat "$OUTPUT_FILE"
  cat "$CURL_LOG"
  echo "FAIL: mirror fallback reused the primary partial file" >&2
  exit 1
fi

case "$primary_output" in
  *.primary.part) ;;
  *)
    cat "$CURL_LOG"
    echo "FAIL: primary download did not use a mirror-specific partial path" >&2
    exit 1
    ;;
esac
case "$secondary_output" in
  *.secondary.part) ;;
  *)
    cat "$CURL_LOG"
    echo "FAIL: secondary download did not use a mirror-specific partial path" >&2
    exit 1
    ;;
esac

if [ ! -x "$RUNNER_TEMP/$ZIG_NAME/zig" ]; then
  cat "$OUTPUT_FILE"
  echo "FAIL: mirror fallback did not install the verified Zig archive" >&2
  exit 1
fi

echo "PASS: Zig downloads honor the invocation budget, resume on one mirror, and use isolated partial files for fallback mirrors"
