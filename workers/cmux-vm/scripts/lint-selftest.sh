#!/usr/bin/env bash
# Proves the lint boundaries are active: oxlint must reject the fixtures in
# lint-fixtures/ with each gdp-ts rule, the upstream import boundary and the
# fetch boundary. Run after `bun run lint:prepare`.
set -uo pipefail
cd "$(dirname "$0")/.."
output="$(bunx oxlint lint-fixtures 2>&1)"
status=$?
if [ "$status" -eq 0 ]; then
  echo "lint self-test: oxlint accepted forged proofs; the gdp-ts preset is not active" >&2
  echo "$output" >&2
  exit 1
fi
expected=(
  "gdp-ts(no-define-proof)"
  "gdp-ts(no-proof-assertion)"
  "gdp-ts(no-type-assertion)"
  "gdp-ts(no-any)"
  "eslint(no-restricted-imports)"
  "eslint(no-restricted-globals)"
)
for rule in "${expected[@]}"; do
  if ! grep -qF "$rule" <<<"$output"; then
    echo "lint self-test: $rule did not fire" >&2
    echo "$output" >&2
    exit 1
  fi
done
echo "lint self-test: all fired: ${expected[*]}"
