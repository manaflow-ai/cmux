#!/usr/bin/env bash

set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <package-path>" >&2
  exit 2
fi

package_path="$1"
# Keep process-global test state inside one suite. Some packages otherwise
# finish every assertion but leave the aggregate Swift Testing runner waiting.
suite_list="$({
  swift test list --package-path "$package_path"
} | sed -nE 's/^[^.]+\.([^/]+)\/.*$/\1/p' | sort -u)"

if [ -z "$suite_list" ]; then
  echo "no test suites discovered for $package_path" >&2
  exit 1
fi

while IFS= read -r suite; do
  [ -n "$suite" ] || continue
  echo "swift test $package_path --filter $suite"
  swift test --package-path "$package_path" --filter "$suite" </dev/null
done < <(printf '%s\n' "$suite_list")
