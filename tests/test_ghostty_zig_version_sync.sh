#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION_HELPER="$ROOT_DIR/scripts/ghostty-zig-version.sh"

if [[ ! -f "$VERSION_HELPER" ]]; then
  echo "missing shared Ghostty Zig version helper: $VERSION_HELPER" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "$VERSION_HELPER"

expected="$(
  sed -nE 's/^[[:space:]]*\.minimum_zig_version[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' \
    "$ROOT_DIR/ghostty/build.zig.zon" | head -1
)"
actual="$(ghostty_minimum_zig_version "$ROOT_DIR")"

if [[ -z "$expected" || "$actual" != "$expected" ]]; then
  echo "Ghostty Zig version mismatch: expected '$expected', helper returned '$actual'" >&2
  exit 1
fi

for compatible_version in \
  "$actual" \
  "${actual%.*}.$((10#${actual##*.} + 1))" \
  "${actual}-dev.1+test"; do
  if ! ghostty_zig_version_is_compatible "$compatible_version" "$actual"; then
    echo "Ghostty-compatible Zig version rejected: $compatible_version >= $actual" >&2
    exit 1
  fi
done

IFS=. read -r actual_major actual_minor actual_patch <<< "$actual"
incompatible_versions=(
  "$((10#$actual_major + 1)).${actual_minor}.${actual_patch}"
  "${actual_major}.$((10#$actual_minor + 1)).${actual_patch}"
)
if (( 10#$actual_patch > 0 )); then
  incompatible_versions+=("${actual_major}.${actual_minor}.$((10#$actual_patch - 1))")
fi
incompatible_versions+=("invalid")
for incompatible_version in "${incompatible_versions[@]}"; do
  if ghostty_zig_version_is_compatible "$incompatible_version" "$actual"; then
    echo "Incompatible Zig version accepted: $incompatible_version for $actual" >&2
    exit 1
  fi
done

for consumer in \
  "$ROOT_DIR/scripts/install-zig-ci.sh" \
  "$ROOT_DIR/scripts/build-ghostty-cli-helper.sh"; do
  if ! grep -Eq 'ghostty_minimum_zig_version[[:space:]]+' "$consumer"; then
    echo "$(basename "$consumer") does not use the shared Ghostty Zig version" >&2
    exit 1
  fi
done

# Every workflow command that reads Ghostty's Zig manifest must initialize the
# submodule earlier in the same job. Scan all workflows so a new consumer is
# covered automatically instead of maintaining a list of job names.
python3 "$ROOT_DIR/tests/test_check_ghostty_zig_workflows.py"
python3 \
  "$ROOT_DIR/tests/check_ghostty_zig_workflows.py" \
  "$ROOT_DIR/.github/workflows"

if ! grep -Fq 'source "$SCRIPT_DIR/ghostty-zig-version.sh"' "$ROOT_DIR/scripts/setup.sh" ||
   ! grep -Fq 'ghostty_minimum_zig_version "$PROJECT_DIR"' "$ROOT_DIR/scripts/setup.sh" ||
   ! grep -Fq 'ZIG_ACTUAL="$(zig version)"' "$ROOT_DIR/scripts/setup.sh" ||
   ! grep -Fq 'ghostty_zig_version_is_compatible "$ZIG_ACTUAL" "$ZIG_REQUIRED"' "$ROOT_DIR/scripts/setup.sh"; then
  echo "setup.sh does not validate the manifest-derived Ghostty Zig version" >&2
  exit 1
fi

if ! awk '
  /^  workflow-guard-tests:$/ { in_job = 1; next }
  in_job && /^  [[:alnum:]_-]+:$/ { exit }
  in_job && index($0, "git submodule update --init --depth 1 ghostty") { found = 1 }
  END { exit !found }
' "$ROOT_DIR/.github/workflows/ci.yml"; then
  echo "workflow-guard-tests does not initialize Ghostty before reading its Zig manifest" >&2
  exit 1
fi

tui_workflows=(
  "$ROOT_DIR/.github/workflows/cmux-tui-build-package.yml"
  "$ROOT_DIR/.github/workflows/cmux-tui.yml"
)

validate_setup_zig_jobs() {
  local workflow="$1"
  awk '
    function reset_job() {
      init_count = 0
      init_line = 0
      resolver_count = 0
      resolver_line = 0
      helper_count = 0
      helper_line = 0
      setup_count = 0
      setup_line = 0
      setup_step_open = 0
      version_count = 0
      version_line = 0
    }
    function fail(message) {
      printf "%s: job %s: %s\n", FILENAME, job, message > "/dev/stderr"
      failed = 1
    }
    function validate_job() {
      if (job == "" || setup_count == 0) return
      validated_jobs++
      if (init_count != 1) fail("expected exactly one Ghostty submodule initialization")
      if (resolver_count != 1) fail("expected exactly one Ghostty Zig resolver step")
      if (helper_count != 1) fail("resolver must call scripts/ghostty-zig-version.sh exactly once")
      if (setup_count != 1) fail("expected exactly one setup-zig action")
      if (version_count != 1) fail("setup-zig must use the resolver output in its own step")
      if (!(init_line < resolver_line &&
            resolver_line < helper_line &&
            helper_line < setup_line &&
            setup_line < version_line)) {
        fail("expected ordered Ghostty init -> resolver -> setup-zig wiring")
      }
    }
    BEGIN {
      in_jobs = 0
      job = ""
      reset_job()
    }
    /^jobs:[[:space:]]*$/ {
      in_jobs = 1
      next
    }
    in_jobs && /^  [[:alnum:]_-]+:[[:space:]]*$/ {
      validate_job()
      job = $1
      sub(/:$/, "", job)
      reset_job()
      next
    }
    in_jobs && job != "" {
      if ($0 ~ /^      - /) setup_step_open = 0
      if (index($0, "git submodule update --init --depth 1 ghostty")) {
        init_count++
        if (init_line == 0) init_line = NR
      }
      if (index($0, "id: ghostty-zig-version")) {
        resolver_count++
        if (resolver_line == 0) resolver_line = NR
      }
      if (index($0, "bash ./scripts/ghostty-zig-version.sh")) {
        helper_count++
        if (helper_line == 0) helper_line = NR
      }
      if (index($0, "uses: mlugg/setup-zig@")) {
        setup_count++
        if (setup_line == 0) setup_line = NR
        setup_step_open = 1
      }
      if (setup_step_open &&
          index($0, "version: ${{ steps.ghostty-zig-version.outputs.version }}")) {
        version_count++
        if (version_line == 0) version_line = NR
      }
    }
    END {
      validate_job()
      if (!failed) print validated_jobs + 0
      exit failed
    }
  ' "$workflow"
}

validated_setup_jobs=0
for workflow in "${tui_workflows[@]}"; do
  job_count="$(validate_setup_zig_jobs "$workflow")"
  validated_setup_jobs=$((validated_setup_jobs + job_count))
done
if [[ "$validated_setup_jobs" -eq 0 ]]; then
  echo "No TUI setup-zig jobs were validated" >&2
  exit 1
fi

if grep -Fq 'run: echo "version=$(bash ./scripts/ghostty-zig-version.sh)"' \
  "${tui_workflows[@]}"; then
  echo "TUI workflow hides Ghostty Zig resolver failures inside echo" >&2
  exit 1
fi

echo "PASS: cmux build scripts use Ghostty's declared Zig version ($actual)"
