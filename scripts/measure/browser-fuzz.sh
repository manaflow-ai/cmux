#!/usr/bin/env bash
# Fleet entry for the browser fuzz (fuzz catalog row k, cmux-ad's order 2026-10-31): builds a tagged cmux-next app at
# this checkout, then runs scripts/fuzz/browser/browser_fuzz.py against it: seeded op sequences of URLs (valid,
# malformed, huge, file:/javascript:/data:, IDN), Back/Forward/Reload and redirects, tab open/close/move storms across
# panes, workspaces and windows, DevTools open and close, downloads and renderer crashes in Chromium tabs, with its
# oracles after every op (the app lives, a dead renderer shows the crashed-page view, no main-thread stall over 100 ms,
# unsafe schemes refused). It launches an app and kills that app's own renderers, so it runs alone:
#   cmux-ci run --class exclusive --label measure --label gui-session-v1 --pool perf-lead \
#     --script scripts/measure/browser-fuzz.sh --ref <sha> --artifact artifacts/browser-fuzz/findings.tar.gz \
#     [--arg=--minutes=20] [--arg=--seed=N] [--arg=--config=bench]
# Default configuration: Debug (the crashed-page and external-open oracles read DEBUG-only methods). --config=bench
# builds Release-optimized with the bench hooks, for stall evidence; those two oracles then give no verdict.
# The verdict is the fuzz's own last line, "BROWSER-FUZZ-VERDICT PASS|FAIL|NOVERDICT ..." (scripts/fuzz/browser/verdict.py).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
git submodule update --init --depth 1 ghostty ghostty-next >/dev/null
sha="$(git rev-parse HEAD)"
tag="bfuzz-${sha:0:8}"
out="$(mktemp -d)"
mkdir -p artifacts/browser-fuzz
# Fuzz catalog rule 8: Spotlight stays out of this job's own work dirs.
touch "$out/.metadata_never_index" artifacts/.metadata_never_index 2>/dev/null || true
reload_config=() fuzz_args=() config=debug
for arg in "$@"; do
  case "$arg" in
    --config=*) config="${arg#--config=}"; reload_config=(--config "$config") ;;
    *) fuzz_args+=("$arg") ;;
  esac
done
set -- ${fuzz_args[@]+"${fuzz_args[@]}"}
# Steps run with a per-step HOME; bun and node for the Debug build's web bundles live under the account's real home.
account_home="$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
for tool_dir in "$account_home/.bun/bin" "$account_home/.local/node/bin"; do
  [ -n "$account_home" ] && [ -d "$tool_dir" ] && export PATH="$tool_dir:$PATH"
done
# The bun webviews/package.json pins, first on PATH: a mini's shared ~/.bun can be older (bun 1.3.14 on cmux18
# failed job 910574114793e0a390089c19) or swapped by another job (#18124). As crash-gate.sh and tab-switch.sh.
RUNNER_TEMP="$out" GITHUB_PATH="$out/bun-path" ./scripts/cmux-next/private-bun.sh
PATH="$(tail -n 1 "$out/bun-path"):$PATH"
export PATH
CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" --no-global-cli-links ${reload_config[@]+"${reload_config[@]}"} 2>&1 | tee "$out/reload.log" || true  # a failed build falls to the app-path check below (NOVERDICT)
app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
if [[ -z "$app" || ! -d "$app" ]]; then
  echo "browser-fuzz: the tagged reload printed no app path" >&2
  grep -E "error:|BUILD FAILED" "$out/reload.log" | head -n 60 >&2 || true
  echo "BROWSER-FUZZ-VERDICT NOVERDICT the tagged build failed"
  exit 1
fi
echo "browser-fuzz: commit $sha app $app config $config"
# Other processes' CPU before and after (rule 8): a stall finding on a busy host says so.
echo "browser-fuzz: host CPU before:"; ps -Ao pid,pcpu,comm -r | awk 'NR == 1 || $2 > 5 || /mds|fleet-cas/' | head -n 15 || true
trap 'python3 scripts/cmux-next/tag_teardown.py "$app" || true' EXIT
status=0
CMUX_BENCH_LAUNCH=direct python3 scripts/fuzz/browser/browser_fuzz.py --app "$app" --build-config "$config" --out "$out/fuzz" "$@" || status=$?
echo "browser-fuzz: host CPU after:"; ps -Ao pid,pcpu,comm -r | awk 'NR == 1 || $2 > 5 || /mds|fleet-cas/' | head -n 15 || true
tar -czf artifacts/browser-fuzz/findings.tar.gz -C "$out" fuzz 2>/dev/null || true
exit "$status"
