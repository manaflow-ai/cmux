#!/usr/bin/env bash
# Report unused files, exports, types and dependencies in this repo's TypeScript packages
# with knip. Report-only: exits 0 once knip ran (findings or not); nonzero only if bun is
# missing or knip crashed on every package.
# Usage: bash scripts/static-analysis/knip.sh [PKG_DIR...]   (default: every package with a lockfile)
# Env: SA_KNIP_NO_INSTALL=1 skips installing each package's node_modules (faster, less exact).
# Each package except a workspace root gets a generated config (entries from HTML pages,
# Vite inputs and build scripts: scripts/static-analysis/knip/gen-config.mjs, extra globs in knip/<pkg>.entries); a
# package's own knip.json wins. Verify every "unused file" by hand before deleting: entries
# built from shell variables or loaded by Swift are invisible to knip.
set -uo pipefail

KNIP_VERSION="6.45.1"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "knip.sh: not in a git repo" >&2; exit 2; }
cd "$ROOT" || exit 2
# Helpers live beside this script, so it can also scan another repo: run it from there.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/knip"
OUT_DIR="${FAST_CHECKS_OUT:-${TMPDIR:-/tmp}/static-analysis-out}"
mkdir -p "$OUT_DIR/knip" || exit 2
START=$(date +%s)
command -v bun >/dev/null || { echo "knip.sh: bun is required (https://bun.sh)" >&2; exit 2; }

# Classic web/ is frozen: it is reported, but nothing there should change.
FROZEN_RE='^web$'
if [ "$#" -gt 0 ]; then
  PKGS=("$@")
else
  # Every tracked package with its own lockfile; the repo root (a loose tool package that
  # would scan the whole tree), vendored code and fixtures are skipped. Bun workspaces
  # (backend/) are one package: knip walks their members itself.
  mapfile -t PKGS < <(git ls-files '*bun.lock' '*package-lock.json' \
    | grep -vE '(^|/)(node_modules|vendor|fixtures?|ghostty[^/]*)/' | xargs -n1 dirname | grep -v '^\.$' | sort -u \
    | while read -r d; do [ -f "$d/package.json" ] && echo "$d"; done)
fi

REPORTS=()
RAN=0
for pkg in "${PKGS[@]}"; do
  pkg="${pkg%/}"
  label="$pkg"; [[ "$pkg" =~ $FROZEN_RE ]] && label="$pkg (classic, frozen: report only)"
  safe="${pkg//\//__}"
  json="$OUT_DIR/knip/$safe.json"
  log="$OUT_DIR/knip/$safe.log"
  echo "knip: $pkg" >&2
  if [ -z "${SA_KNIP_NO_INSTALL:-}" ]; then
    if [ -f "$pkg/bun.lock" ]; then
      (cd "$pkg" && bun install --frozen-lockfile --ignore-scripts) >"$log" 2>&1 \
        || echo "knip.sh: $pkg: bun install failed (see $log); knip runs anyway" >&2
    elif [ -f "$pkg/package-lock.json" ]; then
      (cd "$pkg" && npm ci --ignore-scripts --no-audit --no-fund) >"$log" 2>&1 \
        || echo "knip.sh: $pkg: npm ci failed (see $log); knip runs anyway" >&2
    fi
  fi
  args=(--reporter json --no-exit-code --no-progress)
  if ! ls "$pkg"/knip.json "$pkg"/knip.jsonc "$pkg"/.knip.json "$pkg"/knip.config.ts >/dev/null 2>&1 \
     && ! grep -q '"workspaces"' "$pkg/package.json"; then
    # Workspace roots (backend/) keep knip's defaults, which cover every member.
    cfg="$OUT_DIR/knip/$safe.config.json"
    bun "$HERE/gen-config.mjs" "$pkg" >"$cfg" || { echo "knip.sh: $pkg: config generation failed" >&2; continue; }
    args+=(--config "$cfg")
  fi
  (cd "$pkg" && bunx "knip@$KNIP_VERSION" "${args[@]}") >"$json" 2>>"$log"
  rc=$?
  # A tool config knip cannot load (vitest.config.ts that needs a build step, an oxlint
  # config importing a generated file) stops the whole run: turn that plugin off and retry.
  bad="$(sed -n 's/^ERROR: Error loading \([A-Za-z0-9_-]*\)\.config\..*/\1/p' "$log" | head -n 1)"
  if [ "$rc" -ne 0 ] && [ -n "$bad" ]; then
    cfg="$OUT_DIR/knip/$safe.config.json"
    if [[ " ${args[*]} " == *" --config "* ]]; then
      bun "$HERE/gen-config.mjs" "$pkg" "$bad" >"$cfg" || continue
    else
      printf '{ "%s": false }\n' "$bad" >"$cfg"; args+=(--config "$cfg")
    fi
    echo "knip.sh: $pkg: $bad.config failed to load; retrying with the $bad plugin off" >&2
    (cd "$pkg" && bunx "knip@$KNIP_VERSION" "${args[@]}") >"$json" 2>>"$log"
    rc=$?
  fi
  if [ "$rc" -ne 0 ] || [ ! -s "$json" ]; then
    echo "knip.sh: $pkg: knip failed (exit $rc, see $log)" >&2
    continue
  fi
  RAN=$((RAN + 1))
  REPORTS+=("$label=$json")
done

if [ "$RAN" -eq 0 ]; then echo "knip.sh: knip did not run on any package" >&2; exit 2; fi
SUMMARY="$(bun "$HERE/summarize.mjs" "$OUT_DIR/knip.txt" "${REPORTS[@]}")" || { echo "knip.sh: summarize failed" >&2; exit 2; }
FINDINGS="$(printf '%s\n' "$SUMMARY" | sed -n 's/^TOTAL //p')"
printf '%s\n' "$SUMMARY" | grep -v '^TOTAL '
echo "Full report: $OUT_DIR/knip.txt (per-package JSON in $OUT_DIR/knip/)"
echo "SA_SUMMARY tool=knip findings=${FINDINGS:-0} seconds=$(( $(date +%s) - START ))"
exit 0
