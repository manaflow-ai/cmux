#!/usr/bin/env bash
# Regression checks for the no-build Apple prebuilt route. These are source-level
# checks because the target is macOS-only; the fleet runs the actual Swift build.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
harness="$root/screen-stream-eval.sh"
apple="$root/screen-stream-eval/targets/apple.sh"
fail=0

if ! bash -n "$harness" "$apple"; then
  echo "FAIL: screen-stream-eval scripts do not parse"
  fail=1
fi

tools_block=$(sed -n '/^if \[\[ "$tools_only" == 1 \]\]; then$/,/^  exit 0$/p' "$harness")
if [[ "$tools_block" != *'screen-eval-window-id'* || "$tools_block" != *'window-id.swift'* ]]; then
  echo "FAIL: tools-only does not compile screen-eval-window-id"
  fail=1
fi

build_block=$(sed -n '/^  build)$/,/^    ;;$/p' "$apple")
prebuilt_branch=$(sed -n '/^    if \[\[ -n "${EVAL_PREBUILT:-}" \]\]; then$/,/^    else$/p' <<<"$build_block")
if [[ "$prebuilt_branch" != *'helper="$EVAL_PREBUILT/screen-eval-window-id"'* ||
      "$prebuilt_branch" != *'[[ -x "$helper" ]]'* ||
      "$prebuilt_branch" != *'cp "$helper" "$EVAL_BIN/screen-eval-window-id"'* ]]; then
  echo "FAIL: Apple prebuilt build does not validate and copy screen-eval-window-id"
  fail=1
fi
if [[ "$prebuilt_branch" == *swiftc* ]]; then
  echo "FAIL: Apple prebuilt branch invokes swiftc"
  fail=1
fi

if ! grep -q 'app="$home/Applications/CmuxScreenEvalLauncher.app"' "$harness" ||
   ! grep -q 'app=$(bash "$here/launcher/install.sh"' "$harness"; then
  echo "FAIL: launcher path does not distinguish prebuilt and build routes"
  fail=1
fi
launcher_install=$(grep -n 'app=$(bash "$here/launcher/install.sh"' "$harness" | head -1 | cut -d: -f1)
launcher_else=$(sed -n "1,${launcher_install}p" "$harness" | grep -n '^[[:space:]]*else$' | tail -1 | cut -d: -f1)
if [[ -z "$launcher_else" || "$launcher_else" -ge "$launcher_install" ]]; then
  echo "FAIL: launcher install is not behind the non-prebuilt branch"
  fail=1
fi

if [[ "$fail" -eq 0 ]]; then
  echo "screen-stream-eval prebuilt checks: ok"
fi
exit "$fail"
