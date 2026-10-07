#!/usr/bin/env bash
# Regression test for https://github.com/manaflow-ai/cmux/issues/5877.
# Homebrew now warns on comparison-string macOS requirements in casks.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

FILES=(
  "$ROOT_DIR/.github/workflows/update-homebrew.yml"
  "$ROOT_DIR/scripts/build-sign-upload.sh"
)

fail=0
# The cask installs the app, so its floor is the app target's deployment
# target (the target that produces the .app), not the project default or the
# CLI tool's.
deployment_targets="$(
  python3 - "$ROOT_DIR/cmux.xcodeproj/project.pbxproj" <<'PY'
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()
targets = set()
for target in re.finditer(r"\n\t\t\w+ /\* [^*]+ \*/ = \{\n\t\t\tisa = PBXNativeTarget;(.*?)\n\t\t\};", text, re.S):
    body = target.group(1)
    if '"com.apple.product-type.application"' not in body and "com.apple.product-type.application;" not in body:
        continue
    config_list = re.search(r"buildConfigurationList = (\w+)", body).group(1)
    listing = re.search(config_list + r" /\*[^*]*\*/ = \{(.*?)\n\t\t\};", text, re.S).group(1)
    for config in re.findall(r"(\w+) /\* \w+ \*/,", listing):
        block = re.search(r"\n\t\t" + config + r" /\*[^*]*\*/ = \{(.*?)\n\t\t\};", text, re.S).group(1)
        match = re.search(r"MACOSX_DEPLOYMENT_TARGET = ([0-9.]+);", block)
        if match:
            targets.add(match.group(1))
print("\n".join(sorted(targets)))
PY
)"
deployment_target_count="$(printf '%s\n' "$deployment_targets" | sed '/^$/d' | wc -l | tr -d ' ')"
required_symbol=""
if [ "$deployment_target_count" -ne 1 ]; then
  echo "FAIL: cmux app must have exactly one macOS deployment target, got ${deployment_targets:-<none>}" >&2
  fail=1
else
  case "$deployment_targets" in
    14.*)
      required_symbol=":sonoma"
      ;;
    26.*)
      required_symbol=":tahoe"
      ;;
    *)
      echo "FAIL: update Homebrew cask macOS symbol mapping for deployment target $deployment_targets" >&2
      fail=1
      ;;
  esac
fi

expected_symbol=""
for file in "${FILES[@]}"; do
  if grep -Eq 'depends_on macos:[[:space:]]*"[^"]*:[[:alpha:]_][[:alpha:]_0-9]*"' "$file"; then
    echo "FAIL: $file must not use the deprecated comparison-string macOS cask requirement" >&2
    fail=1
  fi

  symbols="$(
    awk '
      /^[[:space:]]*depends_on macos:[[:space:]]*:[[:alpha:]_][[:alpha:]_0-9]*[[:space:]]*$/ {
        sub(/.*depends_on macos:[[:space:]]*/, "")
        sub(/[[:space:]]*$/, "")
        print
      }
    ' "$file"
  )"
  symbol_count="$(printf '%s\n' "$symbols" | sed '/^$/d' | wc -l | tr -d ' ')"
  if [ "$symbol_count" -ne 1 ]; then
    echo "FAIL: $file must generate exactly one symbol-form macOS cask requirement" >&2
    fail=1
    continue
  fi

  if [ -z "$expected_symbol" ]; then
    expected_symbol="$symbols"
  elif [ "$symbols" != "$expected_symbol" ]; then
    echo "FAIL: cask generators disagree on macOS requirement ($expected_symbol vs $symbols)" >&2
    fail=1
  fi
done

if [ -n "$required_symbol" ] && [ "$expected_symbol" != "$required_symbol" ]; then
  echo "FAIL: expected Homebrew cask macOS requirement $required_symbol for deployment target $deployment_targets, got ${expected_symbol:-<none>}" >&2
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  exit 1
fi

echo "PASS: Homebrew cask macOS dependency uses the symbol requirement form ($expected_symbol)"
