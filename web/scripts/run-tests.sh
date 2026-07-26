#!/usr/bin/env bash
set -euo pipefail

WEB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$WEB_ROOT"

arguments_include_test_filter() {
  local expects_value=0
  local positional_only=0
  local argument

  for argument in "$@"; do
    if (( positional_only )); then
      return 0
    fi
    if (( expects_value )); then
      expects_value=0
      continue
    fi

    # Unknown options with separate values fall through as explicit filters,
    # which delegates discovery to Bun instead of accidentally widening a run.
    case "$argument" in
      --)
        positional_only=1
        ;;
      -t|--test-name-pattern|--timeout|--rerun-each|--retry|--seed)
        expects_value=1
        ;;
      --coverage-reporter|--coverage-dir|--bail|--reporter|--reporter-outfile)
        expects_value=1
        ;;
      --max-concurrency|--path-ignore-patterns|--changed|--parallel|--parallel-delay|--shard)
        expects_value=1
        ;;
      -*)
        ;;
      *)
        return 0
        ;;
    esac
  done

  return 1
}

if arguments_include_test_filter "$@"; then
  exec bun test --isolate "$@"
fi

test_files=()
while IFS= read -r test_file; do
  test_files+=("$test_file")
done < <(
  find . \
    \( -type d \( -name node_modules -o -name '.*' \) ! -path . -prune \) -o \
    -type f -print |
    awk '/(\.test|_test|\.spec|_spec)\.(js|jsx|ts|tsx|mjs|cjs|mts|cts)$/' |
    LC_ALL=C sort
)

if (( ${#test_files[@]} == 0 )); then
  echo "No web test files found" >&2
  exit 1
fi

exec bun test --isolate "${test_files[@]}" "$@"
