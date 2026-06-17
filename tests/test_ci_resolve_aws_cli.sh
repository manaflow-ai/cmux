#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/path-bin" "$TMP_DIR/candidate-bin"

cat >"$TMP_DIR/path-bin/aws" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$TMP_DIR/path-bin/aws"

resolved="$(PATH="$TMP_DIR/path-bin:/usr/bin:/bin" "$ROOT_DIR/scripts/ci/resolve-aws-cli.sh")"
if [ "$resolved" != "$TMP_DIR/path-bin/aws" ]; then
  echo "FAIL: expected PATH aws, got $resolved"
  exit 1
fi

cat >"$TMP_DIR/candidate-bin/aws" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$TMP_DIR/candidate-bin/aws"

resolved="$(PATH="/usr/bin:/bin" CMUX_AWS_CLI_CANDIDATES="$TMP_DIR/candidate-bin/aws" "$ROOT_DIR/scripts/ci/resolve-aws-cli.sh")"
if [ "$resolved" != "$TMP_DIR/candidate-bin/aws" ]; then
  echo "FAIL: expected candidate aws, got $resolved"
  exit 1
fi

set +e
PATH="/usr/bin:/bin" CMUX_AWS_CLI_CANDIDATES="$TMP_DIR/missing/aws" "$ROOT_DIR/scripts/ci/resolve-aws-cli.sh" >"$TMP_DIR/missing.out" 2>"$TMP_DIR/missing.err"
status=$?
set -e
if [ "$status" -ne 127 ]; then
  cat "$TMP_DIR/missing.out"
  cat "$TMP_DIR/missing.err" >&2
  echo "FAIL: expected missing aws exit 127, got $status"
  exit 1
fi
if ! grep -Fq "AWS CLI is required for R2 upload" "$TMP_DIR/missing.err"; then
  cat "$TMP_DIR/missing.err" >&2
  echo "FAIL: missing aws error was not actionable"
  exit 1
fi

echo "PASS: AWS CLI resolver finds PATH/common candidates and fails clearly"
