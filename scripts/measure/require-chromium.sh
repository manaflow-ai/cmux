#!/usr/bin/env bash
# Sourced by a measure entry that builds its own tagged app (decision 2026-11-16: each measure says its engine).
#
# A tagged build embeds Chromium only when the engine's artifact is at hand (scripts/cmux-next/embed-cef.sh). With
# none it warned in a build log that no step prints, exited 0, and the app showed each page in WebKit: a time taken
# there read as a time of the default engine. CMUX_NEXT_REQUIRE_CEF=1 makes a missing engine a build failure
# (scripts/measure/devtools-calls.sh does the same). An entry requires the engine by default;
# `--allow-no-chromium` turns that off for a measure of WebKit.
#
#   measure_chromium_required "$@"     prints 1, or 0 when an argument is --allow-no-chromium: the value of
#                                      CMUX_NEXT_REQUIRE_CEF for the entry's reload.
#   measure_chromium_failure NAME LOG  LOG is the output of a reload that failed. When the engine's fetch
#                                      (scripts/cmux-next/ensure-cef.sh) is what failed: one line on stderr that
#                                      says so, with the argument for a measure of WebKit; returns 0. Else prints
#                                      nothing and returns 1.
# Tests: scripts/cmux-next/tests/test_bench_page_engine.py.

measure_chromium_required() {
  local arg
  for arg in "$@"; do
    if [[ "$arg" == "--allow-no-chromium" ]]; then
      echo 0
      return 0
    fi
  done
  echo 1
}

measure_chromium_failure() {
  local name="$1" log="$2" line
  # Each failure of ensure-cef.sh ends with this marker (its `fail`).
  line="$(grep -m 1 -E 'error: .*\(ensure-cef store parser\)' "$log" 2>/dev/null || true)"
  [[ -n "$line" ]] || return 1
  local webkit="For a measure of WebKit pass --allow-no-chromium (with cmux-ci: --arg=--allow-no-chromium)."
  if [[ "$line" == *"could not download a verified"* ]]; then
    echo "$name: the build requires the Chromium engine, and none of its 4 sources gave it: the host's cache, the fleet controller's artifact store, the private bucket, the private release. $webkit" >&2
  else
    line="${line#*error: }"
    echo "$name: the build requires the Chromium engine, and its fetch failed: ${line%%; see cmuxterm-hq*}. $webkit" >&2
  fi
}
