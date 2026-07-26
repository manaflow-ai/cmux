#!/usr/bin/env bash
set -euo pipefail

WEB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$WEB_ROOT"

arguments_require_bun_discovery() {
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

    # Optional-valued and unknown flags consume a value only in --flag=value
    # form. A following token is treated as a filter and delegated to Bun,
    # which avoids accidentally widening a scoped run.
    case "$argument" in
      --)
        positional_only=1
        ;;
      --watch|--hot)
        return 0
        ;;
      -t|--test-name-pattern|--timeout|--rerun-each|--retry|--seed)
        expects_value=1
        ;;
      --coverage-reporter|--coverage-dir|--reporter|--reporter-outfile)
        expects_value=1
        ;;
      --max-concurrency|--path-ignore-patterns|--parallel-delay|--shard)
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

if arguments_require_bun_discovery "$@"; then
  exec bun test --isolate "$@"
fi

discovered_test_files=""
if ! discovered_test_files="$(
  find . \
    \( -type d \( -name node_modules -o -name '.*' \) ! -path . -prune \) -o \
    -type f -print |
    awk '/(\.test|_test|\.spec|_spec)\.(js|jsx|ts|tsx|mjs|cjs|mts|cts)$/' |
    LC_ALL=C sort
)"; then
  echo "Web test discovery failed" >&2
  exit 1
fi

test_files=()
if [[ -n "$discovered_test_files" ]]; then
  while IFS= read -r test_file; do
    test_files+=("$test_file")
  done <<< "$discovered_test_files"
fi

if (( ${#test_files[@]} == 0 )); then
  echo "No web test files found" >&2
  exit 1
fi

exec bun test --isolate "${test_files[@]}" "$@"
