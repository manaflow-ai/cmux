#!/usr/bin/env bash
# Proves the gdp-ts preset is active: oxlint must reject the forged proofs in
# lint-fixtures/ with each gdp-ts rule. Run after `bun run lint:prepare`.
set -uo pipefail
cd "$(dirname "$0")/.."
output="$(bunx oxlint lint-fixtures 2>&1)"
status=$?
if [ "$status" -eq 0 ]; then
  echo "lint self-test: oxlint accepted forged proofs; the gdp-ts preset is not active" >&2
  echo "$output" >&2
  exit 1
fi
for rule in no-define-proof no-proof-assertion no-type-assertion no-any; do
  if ! grep -qF "gdp-ts($rule)" <<<"$output"; then
    echo "lint self-test: gdp-ts($rule) did not fire" >&2
    echo "$output" >&2
    exit 1
  fi
done
echo "lint self-test: gdp-ts rules no-define-proof, no-proof-assertion, no-type-assertion, no-any all fired"
