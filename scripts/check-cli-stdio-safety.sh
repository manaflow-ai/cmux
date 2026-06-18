#!/usr/bin/env bash
set -euo pipefail

target="${1:-CLI}"

if [[ ! -e "$target" ]]; then
  echo "Missing target: $target" >&2
  exit 1
fi

patterns=(
  'FileHandle\.standardOutput\.write'
  'FileHandle\.standardError\.write'
  'fileHandleForWriting\.write'
  '\bSwift\.print\('
  '\bFoundation\.print\('
  '\bputs\('
  '\bfputs\('
)

violations=0
for pattern in "${patterns[@]}"; do
  if rg -n --glob '*.swift' "$pattern" "$target"; then
    violations=1
  fi
done

if [[ "$violations" -ne 0 ]]; then
  echo "Unsafe CLI stdio usage detected in $target" >&2
  exit 1
fi

echo "CLI stdio audit passed for $target"
echo "safe print shim definitions: $(rg -c '^func print\(' CLI || true)"
echo "cliPrint callsites: $(rg -c '\bcliPrint\(' "$target" || true)"
echo "cliWriteStdout callsites: $(rg -c '\bcliWriteStdout\(' "$target" || true)"
echo "cliWriteStderr callsites: $(rg -c '\bcliWriteStderr\(' "$target" || true)"
