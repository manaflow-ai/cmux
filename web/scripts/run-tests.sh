#!/usr/bin/env bash
set -euo pipefail

WEB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$WEB_ROOT"

MINIMUM_BUN_VERSION="1.3.14"

bun_version_is_supported() {
  awk -v actual="$1" -v required="$2" '
    BEGIN {
      split(actual, actual_parts, ".")
      split(required, required_parts, ".")
      for (part_index = 1; part_index <= 3; part_index++) {
        actual_part = actual_parts[part_index] + 0
        required_part = required_parts[part_index] + 0
        if (actual_part > required_part) {
          exit 0
        }
        if (actual_part < required_part) {
          exit 1
        }
      }
      exit 0
    }
  '
}

bun_version="$(bun --version)"
if ! bun_version_is_supported "$bun_version" "$MINIMUM_BUN_VERSION"; then
  echo "Web tests require Bun $MINIMUM_BUN_VERSION or newer; found $bun_version" >&2
  exit 1
fi

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

    # Optional-valued flags consume a value only in --flag=value form. A
    # following token is treated as a filter, and unknown flags delegate to
    # Bun, which avoids accidentally widening a scoped or future invocation.
    case "$argument" in
      --)
        positional_only=1
        ;;
      --watch|--hot|--config|--config=*|-c|-c=*|--path-ignore-patterns|--path-ignore-patterns=*|--changed|--changed=*|--pass-with-no-tests)
        return 0
        ;;
      -t|--test-name-pattern|--timeout|--rerun-each|--retry|--seed)
        expects_value=1
        ;;
      --coverage-reporter|--coverage-dir|--reporter|--reporter-outfile)
        expects_value=1
        ;;
      --max-concurrency|--parallel-delay|--shard)
        expects_value=1
        ;;
      -t=*|--test-name-pattern=*|--timeout=*|--rerun-each=*|--retry=*|--seed=*)
        ;;
      --coverage-reporter=*|--coverage-dir=*|--reporter=*|--reporter-outfile=*)
        ;;
      --max-concurrency=*|--parallel-delay=*|--shard=*)
        ;;
      -u|--update-snapshots|--todo|--only|--concurrent)
        ;;
      --randomize|--coverage|--dots|--only-failures|--no-orphans|--isolate)
        ;;
      --bail|--bail=*|--parallel|--parallel=*)
        ;;
      -*)
        return 0
        ;;
      *)
        return 0
        ;;
    esac
  done

  return 1
}

default_config_controls_discovery() {
  local config_file="$WEB_ROOT/bunfig.toml"
  [[ -f "$config_file" ]] || return 1

  awk '
    /^[[:space:]]*\[/ {
      in_test = ($0 ~ /^[[:space:]]*\[[[:space:]]*"?test"?[[:space:]]*\]/)
      next
    }
    in_test && /^[[:space:]]*"?(root|pathIgnorePatterns)"?[[:space:]]*=/ {
      found = 1
    }
    /^[[:space:]]*"?test"?[.]"?(root|pathIgnorePatterns)"?[[:space:]]*=/ {
      found = 1
    }
    /^[[:space:]]*"?test"?[[:space:]]*=/ &&
      /(root|pathIgnorePatterns)[[:space:]]*=/ {
      found = 1
    }
    END { exit !found }
  ' "$config_file"
}

if arguments_require_bun_discovery "$@" || default_config_controls_discovery; then
  exec bun test --isolate "$@"
fi

discovery_file="$(mktemp "${TMPDIR:-/tmp}/cmux-web-test-discovery.XXXXXX")"
cleanup_discovery_file() {
  rm -f "$discovery_file"
}
trap cleanup_discovery_file EXIT HUP INT TERM

if ! (
  find . \
    \( -type d \( -name node_modules -o -name '.*' \) ! -path . -prune \) -o \
    -type f -print |
    awk '/(\.test|_test|\.spec|_spec)\.(js|jsx|ts|tsx|mjs|cjs|mts|cts)$/' |
    LC_ALL=C sort
) > "$discovery_file"; then
  echo "Web test discovery failed" >&2
  exit 1
fi

test_files=()
while IFS= read -r test_file; do
  if [[ -n "$test_file" ]]; then
    test_files+=("$test_file")
  fi
done < "$discovery_file"
cleanup_discovery_file
trap - EXIT HUP INT TERM

if (( ${#test_files[@]} == 0 )); then
  echo "No web test files found" >&2
  exit 1
fi

exec bun test --isolate "${test_files[@]}" "$@"
