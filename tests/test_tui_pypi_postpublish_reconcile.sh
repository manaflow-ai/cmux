#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$ROOT_DIR/cmux-tui/scripts/verify-pypi-tui-upload.sh"
[[ -x "$HELPER" ]] || {
  echo "missing executable PyPI reconciliation helper: $HELPER" >&2
  exit 1
}

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/cmux-tui-pypi-reconcile.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

wheel_directory="$tmp_dir/dist"
stub_directory="$tmp_dir/bin"
calls="$tmp_dir/calls"
artifacts="$tmp_dir/artifacts"
counter="$tmp_dir/counter"
expected_wheels=()
mkdir -p "$wheel_directory" "$stub_directory"

for wheel in \
  cmux-1.2.3-py3-none-macosx_11_0_arm64.whl \
  cmux-1.2.3-py3-none-macosx_10_12_x86_64.whl \
  cmux-1.2.3-py3-none-manylinux_2_17_x86_64.whl \
  cmux-1.2.3-py3-none-musllinux_1_2_x86_64.whl \
  cmux-1.2.3-py3-none-manylinux_2_17_aarch64.whl \
  cmux-1.2.3-py3-none-musllinux_1_2_aarch64.whl; do
  : >"$wheel_directory/$wheel"
  expected_wheels+=("$wheel_directory/$wheel")
done

cat >"$stub_directory/python3" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

: "${CALL_LOG:?}"
: "${ARTIFACT_LOG:?}"
printf '%s\n' "$*" >>"$CALL_LOG"

previous=""
artifact=""
for argument in "$@"; do
  if [[ "$previous" == "--artifact" ]]; then
    artifact="$argument"
  fi
  if [[ "$argument" == "publish" ]]; then
    echo "the check helper must never invoke publish mode" >&2
    exit 9
  fi
  previous="$argument"
done
printf '%s\n' "$artifact" >>"$ARTIFACT_LOG"

if [[ -n "${FAIL_AT:-}" ]]; then
  : "${CALL_COUNT:?}"
  count=0
  if [[ -f "$CALL_COUNT" ]]; then
    count="$(<"$CALL_COUNT")"
  fi
  count=$((count + 1))
  printf '%s\n' "$count" >"$CALL_COUNT"
  if [[ "$count" -eq "$FAIL_AT" ]]; then
    exit 7
  fi
fi
EOF
chmod +x "$stub_directory/python3"

CALL_LOG="$calls" \
ARTIFACT_LOG="$artifacts" \
PATH="$stub_directory:$PATH" \
  "$HELPER" "$wheel_directory" 1.2.3

[[ "$(wc -l <"$calls" | tr -d '[:space:]')" == 6 ]] || {
  echo "expected one reconciliation call per wheel" >&2
  exit 1
}
while IFS= read -r invocation; do
  for wheel in "${expected_wheels[@]}"; do
    [[ "$invocation" == *"$(basename "$wheel")"* ]] || {
      echo "reconciliation omitted wheel $(basename "$wheel")" >&2
      exit 1
    }
  done
  [[ "$invocation" == *"--registry pypi"* ]] || exit 1
  [[ "$invocation" == *"--package cmux"* ]] || exit 1
  [[ "$invocation" == *"--version 1.2.3"* ]] || exit 1
  [[ "$invocation" == *"--wait-seconds 120"* ]] || exit 1
  [[ "$invocation" == *"--require-match"* ]] || exit 1
  [[ "$(grep -o -- '--allowed-artifact' <<<"$invocation" | wc -l | tr -d '[:space:]')" == 6 ]] || exit 1
done <"$calls"
for wheel in "$wheel_directory"/*.whl; do
  grep -Fxq "$wheel" "$artifacts" || {
    echo "wheel was not reconciled: $wheel" >&2
    exit 1
  }
done

missing_wheel="$wheel_directory/cmux-1.2.3-py3-none-musllinux_1_2_aarch64.whl"
rm "$missing_wheel"
: >"$calls"
: >"$artifacts"
if CALL_LOG="$calls" \
  ARTIFACT_LOG="$artifacts" \
  PATH="$stub_directory:$PATH" \
  "$HELPER" "$wheel_directory" 1.2.3 \
  >"$tmp_dir/missing.stdout" 2>"$tmp_dir/missing.stderr"; then
  echo "helper accepted a release with fewer than six wheels" >&2
  exit 1
fi
[[ ! -s "$calls" ]] || {
  echo "helper invoked the reconciler before rejecting the wheel count" >&2
  exit 1
}
grep -Fq "expected six immutable PyPI wheels" "$tmp_dir/missing.stderr"

: >"$missing_wheel"
: >"$calls"
: >"$artifacts"
: >"$counter"
if CALL_LOG="$calls" \
  ARTIFACT_LOG="$artifacts" \
  CALL_COUNT="$counter" \
  FAIL_AT=3 \
  PATH="$stub_directory:$PATH" \
  "$HELPER" "$wheel_directory" 1.2.3 \
  >"$tmp_dir/failure.stdout" 2>"$tmp_dir/failure.stderr"; then
  echo "helper ignored a failed reconciliation" >&2
  exit 1
fi
[[ "$(wc -l <"$artifacts" | tr -d '[:space:]')" == 3 ]] || {
  echo "helper did not stop after a failed reconciliation" >&2
  exit 1
}

echo "PASS: PyPI post-upload helper reconciles every wheel and fails closed"
