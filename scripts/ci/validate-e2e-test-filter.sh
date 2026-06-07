#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_DIR="${CMUX_E2E_TEST_DIR:-$ROOT_DIR/cmuxUITests}"

usage() {
  cat >&2 <<'EOF'
Usage: validate-e2e-test-filter.sh <ClassName[/testMethod]>

The macOS E2E workflow runs the cmuxUITests target. For iOS UI tests, use
.github/workflows/test-ios.yml with a selector such as:
  cmuxUITests/cmuxUITests/testWorkspaceToolbarCreatesWorkspaceAndTerminal
EOF
}

fail() {
  echo "error: $*" >&2
  usage
  exit 1
}

if [ "$#" -ne 1 ]; then
  fail "expected exactly one test filter"
fi

filter="$1"
if [ -z "$filter" ]; then
  fail "test filter must not be empty"
fi

if [ ! -d "$TEST_DIR" ]; then
  fail "macOS UI test directory not found: $TEST_DIR"
fi

normalized="$filter"
case "$normalized" in
  cmuxUITests/*)
    normalized="${normalized#cmuxUITests/}"
    ;;
esac

IFS='/' read -r class method extra <<<"$normalized"

if [ -n "${extra:-}" ]; then
  fail "macOS E2E filters must be ClassName or ClassName/testMethod, got '$filter'"
fi

if [[ ! "$class" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
  fail "invalid UI test class name '$class' in '$filter'"
fi

if [ -n "${method:-}" ] && [[ ! "$method" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
  fail "invalid UI test method name '$method' in '$filter'"
fi

class_file="$(
  find "$TEST_DIR" -maxdepth 1 -name '*.swift' -print0 |
    xargs -0 grep -E -l "^[[:space:]]*(final[[:space:]]+)?class[[:space:]]+$class[[:space:]]*:" 2>/dev/null |
    head -n 1 || true
)"

if [ -z "$class_file" ]; then
  fail "macOS UI test class '$class' was not found under cmuxUITests. If this is an iOS UI test, dispatch .github/workflows/test-ios.yml instead."
fi

if [ -n "${method:-}" ]; then
  if ! awk -v class="$class" -v method="$method" '
    /^[[:space:]]*(final[[:space:]]+)?class[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*:/ {
      in_class = ($0 ~ "class[[:space:]]+" class "[[:space:]]*:")
    }
    in_class && $0 ~ "^[[:space:]]*(override[[:space:]]+)?func[[:space:]]+" method "[[:space:]]*\\(" {
      found = 1
    }
    END { exit(found ? 0 : 1) }
  ' "$class_file"; then
    echo "error: macOS UI test method '$method' was not found on '$class' in ${class_file#$ROOT_DIR/}" >&2
    echo "available test methods:" >&2
    awk -v class="$class" '
      /^[[:space:]]*(final[[:space:]]+)?class[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*:/ {
        in_class = ($0 ~ "class[[:space:]]+" class "[[:space:]]*:")
      }
      in_class && /^[[:space:]]*(override[[:space:]]+)?func[[:space:]]+test[A-Za-z0-9_]+[[:space:]]*\(/ {
        print
      }
    ' "$class_file" | sed -E 's/^[[:space:]]*(override[[:space:]]+)?func[[:space:]]+([A-Za-z0-9_]+).*/  \2/' >&2
    usage
    exit 1
  fi
fi

printf '%s\n' "$normalized"
