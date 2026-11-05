#!/usr/bin/env bash
# A measure script that puts the account's ~/.bun/bin first on PATH must then put the bun that
# webviews/package.json pins before it (scripts/cmux-next/private-bun.sh), before it builds the app.
# The worker puts <fleet>/tools/bun-<pin> first on PATH, but a later "$account_home/.bun/bin" prepend
# hides it. 2026-10-31 job 910574114793e0a390089c19 (browser-fuzz.sh, cmux18-perf): "webviews needs bun
# 1.4.4 or newer ...; /Users/cmux/.bun/bin/bun is bun 1.3.14", so the tagged build failed (no verdict).
# Builds nothing. Run: bash scripts/measure/tests/measure-pinned-bun.test.sh
set -euo pipefail
dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0
for script in "$dir"/*.sh; do
  # the line number of the first ~/.bun/bin prepend, of private-bun.sh, and of the first app build
  home_bun=$(grep -n 'account_home/\.bun/bin' "$script" | head -n 1 | cut -d: -f1 || true)
  [[ -n "$home_bun" ]] || continue
  build=$(grep -n -E '^[^#]*\./scripts/reload\.sh' "$script" | head -n 1 | cut -d: -f1 || true)
  [[ -n "$build" ]] || continue
  private=$(grep -n -E '^[^#]*scripts/cmux-next/private-bun\.sh' "$script" | head -n 1 | cut -d: -f1 || true)
  name="$(basename "$script")"
  if [[ -z "$private" ]]; then
    echo "FAIL: $name puts ~/.bun/bin first on PATH (line $home_bun) and builds the app (line $build) without scripts/cmux-next/private-bun.sh"
    fail=1
  elif (( private < home_bun || private > build )); then
    echo "FAIL: $name runs private-bun.sh at line $private, not between the ~/.bun/bin prepend (line $home_bun) and the build (line $build)"
    fail=1
  else
    # the private bun dir goes on PATH, and the web builders cd into webviews/ first, so it must be absolute:
    # "$out" from mktemp -d, or a path from "$PWD" or "$root" (perf-bench.sh's ".build/perf-bench" was relative)
    temp=$(sed -n "${private}p" "$script" | sed -n 's/.*RUNNER_TEMP="\([^"]*\)".*/\1/p')
    out_line=$(grep -n -E '^[^#]*out="\$\(mktemp -d' "$script" | head -n 1 | cut -d: -f1 || true)
    case "$temp" in
      '$PWD/'*|'$root/'*|'$ROOT/'*) ;;
      '$out') [[ -n "$out_line" ]] || { echo "FAIL: $name: RUNNER_TEMP=\$out, but \$out is not from mktemp -d"; fail=1; } ;;
      *) echo "FAIL: $name: RUNNER_TEMP=\"$temp\" at line $private is not an absolute path (\$out from mktemp -d, \$PWD/..., \$root/...)"; fail=1 ;;
    esac
  fi
done
[[ $fail -eq 0 ]] && echo "measure-pinned-bun tests: ok"
exit "$fail"
