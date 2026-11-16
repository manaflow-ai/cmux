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
#   measure_engine_asked "$@"          prints 1 when the entry puts --page-engine=cef before its bench's
#                                      arguments, else 0: with --allow-no-chromium, and with an argument that
#                                      hands the run to another bench that has no --page-engine (--fork-open,
#                                      --bench=NAME; argparse ends such a run with exit 2 after the whole build).
#   measure_chromium_failure NAME LOG  LOG is the output of a reload that failed. When the engine's fetch
#                                      (a `fail` of scripts/cmux-next/ensure-cef.sh) or the engine's credits
#                                      (scripts/cmux-next/embed-cef.sh) is what failed: one line on stderr that
#                                      says so, with the argument for a measure of WebKit; returns 0. Else prints
#                                      nothing and returns 1. A failure of the engine's steps with no such text
#                                      (a full disk, the shim's build, the signing) gets no line: the build log
#                                      in the step's log has its cause.
#
# The requirement holds for arm64. The x86_64 engine is optional also with CMUX_NEXT_REQUIRE_CEF=1
# (embed-cef.sh), so a build of x86_64 alone can pass with no engine; each row is then refused by its bench.
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

measure_engine_asked() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --allow-no-chromium|--fork-open|--bench=*)
        echo 0
        return 0
        ;;
    esac
  done
  echo 1
}

measure_chromium_failure() {
  local name="$1" log="$2" line
  local webkit="For a measure of WebKit pass --allow-no-chromium (with cmux-ci: --arg=--allow-no-chromium)."
  # Each `fail` of ensure-cef.sh ends with this marker.
  line="$(grep -m 1 -E 'error: .*\(ensure-cef store parser\)' "$log" 2>/dev/null || true)"
  if [[ -z "$line" ]]; then
    # embed-cef.sh, only with the requirement on: the engine came with no credits file.
    line="$(grep -m 1 -E 'error: no Chromium CREDITS\.html' "$log" 2>/dev/null || true)"
    [[ -n "$line" ]] || return 1
    echo "$name: the build requires the Chromium engine, and its embed failed: ${line#*error: }. $webkit" >&2
    return 0
  fi
  if [[ "$line" == *"could not download a verified"* ]]; then
    echo "$name: the build requires the Chromium engine, and none of its 4 sources gave it: the host's cache, the fleet controller's artifact store, the private bucket, the private release. $webkit" >&2
  else
    line="${line#*error: }"
    echo "$name: the build requires the Chromium engine, and its fetch failed: ${line%%; see cmuxterm-hq*}. $webkit" >&2
  fi
}
