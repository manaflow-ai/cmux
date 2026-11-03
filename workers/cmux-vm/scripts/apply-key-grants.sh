#!/usr/bin/env bash
# Adds the scopes service-key-grants.json declares to the service key entries with those ids: reads the
# CMUX_VM_SERVICE_KEYS JSON array on stdin, prints it with the grants merged. A scope is not a secret, so a
# grant is a reviewed change to that file instead of a rewrite of a write-only key secret (ids and hashes stay
# as they are). Grants only add; an id with no entry here is a no-op. The admin scope and malformed grants are
# refused (the Worker would turn every service key off on an entry it can't parse).
set -euo pipefail
grants_file="${1:-$(dirname "$0")/../service-key-grants.json}"
if ! jq -e 'type == "object" and all(.[]; type == "array" and length > 0 and all(.[]; type == "string" and test("^[a-z]+:[a-z*]+$") and . != "admin"))' "$grants_file" >/dev/null 2>&1; then
  echo "::error::$grants_file must map service key ids to non-empty lists of scopes (never admin)" >&2
  exit 1
fi
jq -c --slurpfile grants "$grants_file" 'map(.id as $id | if $grants[0][$id] then .scopes = ((.scopes + $grants[0][$id]) | unique) else . end)'
