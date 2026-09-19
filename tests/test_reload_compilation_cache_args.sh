#!/usr/bin/env bash
# reload.sh --compilation-cache must pass the settings that let a second tag replay the
# first tag's compiles: caching on, a cache directory shared across tags, and prefix
# mappings for both the project and the tag's own DerivedData path. Without the
# DerivedData mapping every tag computes different cache keys and nothing is shared.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# Use the real function, not a copy.
eval "$(awk '/^append_compilation_cache_args\(\) \{/,/^}/' "$ROOT/scripts/reload.sh")"
declare -F append_compilation_cache_args >/dev/null || fail "append_compilation_cache_args not found in reload.sh"

has_arg() {
  local wanted="$1" arg
  for arg in "${XCODEBUILD_ARGS[@]}"; do [[ "$arg" == "$wanted" ]] && return 0; done
  return 1
}

_cmux_account_home="$TMP/home"
unset CMUX_COMPILATION_CACHE_DIR CMUX_COMPILATION_CACHE_LIMIT_SIZE

XCODEBUILD_ARGS=(-scheme cmux)
append_compilation_cache_args "$TMP/DerivedData/cmux-tag-one"
ONE=("${XCODEBUILD_ARGS[@]}")
has_arg "-scheme" || fail "existing arguments were dropped"
has_arg "COMPILATION_CACHE_ENABLE_CACHING=YES" || fail "caching not enabled"
has_arg "COMPILATION_CACHE_CAS_PATH=$TMP/home/Library/Caches/cmux/compilation-cache" || fail "default cache dir is wrong: ${XCODEBUILD_ARGS[*]}"
[[ -d "$TMP/home/Library/Caches/cmux/compilation-cache" ]] || fail "cache dir was not created"
for setting in SWIFT_ENABLE_PREFIX_MAPPING CLANG_ENABLE_PREFIX_MAPPING SWIFT_ENABLE_PROJECT_PREFIX_MAPPING CLANG_ENABLE_PROJECT_PREFIX_MAPPING; do
  has_arg "$setting=YES" || fail "$setting is not enabled"
done
has_arg "SWIFT_OTHER_PREFIX_MAPPINGS=$TMP/DerivedData/cmux-tag-one=/^derived" || fail "Swift DerivedData mapping missing"
has_arg "CLANG_OTHER_PREFIX_MAPPINGS=$TMP/DerivedData/cmux-tag-one=/^derived" || fail "Clang DerivedData mapping missing"

has_arg "COMPILATION_CACHE_ENABLE_DIAGNOSTIC_REMARKS=YES" && fail "diagnostic remarks must be off unless asked for"

# A second tag must share the cache directory and map its own DerivedData to the same token.
XCODEBUILD_ARGS=()
append_compilation_cache_args "$TMP/DerivedData/cmux-tag-two"
has_arg "COMPILATION_CACHE_CAS_PATH=$TMP/home/Library/Caches/cmux/compilation-cache" || fail "second tag does not share the cache dir"
has_arg "SWIFT_OTHER_PREFIX_MAPPINGS=$TMP/DerivedData/cmux-tag-two=/^derived" || fail "second tag maps the wrong DerivedData"

# Overrides, and a relative --derived-data made absolute (a relative prefix never matches).
XCODEBUILD_ARGS=()
CMUX_COMPILATION_CACHE_DIR="$TMP/custom cache" CMUX_COMPILATION_CACHE_LIMIT_SIZE=123 CMUX_COMPILATION_CACHE_DIAGNOSTICS=1 \
  append_compilation_cache_args "relative/dd"
has_arg "COMPILATION_CACHE_CAS_PATH=$TMP/custom cache" || fail "CMUX_COMPILATION_CACHE_DIR ignored"
has_arg "COMPILATION_CACHE_ENABLE_DIAGNOSTIC_REMARKS=YES" || fail "CMUX_COMPILATION_CACHE_DIAGNOSTICS ignored"
has_arg "COMPILATION_CACHE_LIMIT_SIZE=123" || fail "CMUX_COMPILATION_CACHE_LIMIT_SIZE ignored"
has_arg "SWIFT_OTHER_PREFIX_MAPPINGS=$PWD/relative/dd=/^derived" || fail "relative DerivedData was not made absolute"

# The option is opt-in: reload.sh only calls the function behind the flag or env var.
grep -q 'if \[\[ "\$COMPILATION_CACHE" -eq 1 || "\${CMUX_COMPILATION_CACHE:-}" == "1" \]\]; then' "$ROOT/scripts/reload.sh" \
  || fail "compilation cache is not gated behind --compilation-cache / CMUX_COMPILATION_CACHE=1"

echo "PASS: reload.sh compilation cache arguments"
