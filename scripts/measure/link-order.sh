#!/usr/bin/env bash
# The cmux NEXT cold launch linker order file, made on a fleet Mac with a console session: builds a link order probe
# app (CMUX_LINK_ORDER_PROBE=1 scripts/reload.sh: every Swift, C and ObjC function of the app records its first call),
# launches it to its first window, and maps the calls into the CmuxNextApp framework onto symbols
# (scripts/cmux-next/link-order.py). The Release link of the framework reads the result,
# Packages/macOS/CmuxNext/LinkOrder/CmuxNextApp.order, with -order_file, so the code a launch runs sits together
# and the launch pages in fewer pages. Commit the order file the artifact holds; a stale one is harmless (ld only
# warns about a symbol it no longer has), it just orders less.
#   cmux-ci run --class isolated --display --script scripts/measure/link-order.sh --ref <sha> \
#     [--arg=config=bench|Release] [--arg=dump_ms=8000] --artifact .build/link-order/report.tgz --timeout 2400
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 2
config=bench
dump_ms=8000
for arg in "$@"; do
  case "$arg" in
    config=*) config="${arg#config=}" ;;
    dump_ms=*) dump_ms="${arg#dump_ms=}" ;;
    *) echo "link-order: unknown argument $arg" >&2; exit 2 ;;
  esac
done
case "$config" in
  bench) configuration=(--config bench) ;;
  Release) configuration=(--release) ;;
  *) echo "link-order: config=$config: bench or Release (the order file is a Release link's)" >&2; exit 2 ;;
esac
[[ "$dump_ms" =~ ^[0-9]+$ ]] || { echo "link-order: dump_ms=$dump_ms is not a number" >&2; exit 2; }
out="$PWD/.build/link-order"
mkdir -p "$out"
echo "LINK-ORDER build $(git rev-parse HEAD) config $config"
for sub in ghostty ghostty-next; do
  [ -e "$sub/.git" ] || git submodule update --init --depth 1 "$sub" || exit 3
done
if [ ! -f GhosttyKit.xcframework/Info.plist ]; then
  rm -rf GhosttyKit.xcframework
  if [ -z "${GHOSTTYKIT_ARCHIVE_CACHE_DIR:-}" ] && [ -n "${CI_SHARED_CACHE_DIR:-}" ]; then
    export GHOSTTYKIT_ARCHIVE_CACHE_DIR="$CI_SHARED_CACHE_DIR/ghosttykit-archives"
  fi
  ./scripts/download-prebuilt-ghosttykit.sh || exit 3
fi
pack() { tar -C "$out/.." -czf "$out/report.tgz" --exclude report.tgz link-order 2>/dev/null || true; }
trap pack EXIT
CMUX_LINK_ORDER_PROBE=1 CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag linkorder --no-global-cli-links \
  "${configuration[@]}" >"$out/reload.log" 2>&1
app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
if [[ -z "$app" || ! -d "$app" ]]; then
  echo "LINK-ORDER build failed: the probe build printed no app path" >&2
  grep -E "error:|BUILD FAILED" "$out/reload.log" | head -n 60 >&2
  tail -n 40 "$out/reload.log" >&2
  exit 3
fi
trap 'python3 scripts/cmux-next/tag_teardown.py "$app" >/dev/null 2>&1; pack' EXIT
exe="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")"
framework="$(find "$app/Contents/Frameworks" -path '*CmuxNextApp.framework*' -type f -name CmuxNextApp | head -n 1)"
[[ -n "$framework" ]] || { echo "LINK-ORDER the app has no CmuxNextApp framework (a live code build links it in)" >&2; exit 3; }
nm -m "$framework" | grep -q '___sanitizer_cov_trace_pc_guard$' \
  || { echo "LINK-ORDER the framework has no coverage guards: not a probe build" >&2; exit 3; }
calls="$out/first-calls.tsv"
rm -f -- "$calls"
# console-session.sh passes only its own variables into the GUI session, so the probe's go in the command.
scripts/ci/frame-pacing/console-session.sh /usr/bin/env CMUX_LINK_ORDER_OUT="$calls" CMUX_LINK_ORDER_DUMP_MS="$dump_ms" \
  "$app/Contents/MacOS/$exe" >"$out/app.log" 2>&1 &
launcher=$!
deadline=$((SECONDS + dump_ms / 1000 + 90))
until [[ -s "$calls" ]] || (( SECONDS > deadline )); do sleep 1; done
sleep 2
python3 scripts/cmux-next/tag_teardown.py "$app" >/dev/null 2>&1
wait "$launcher" 2>/dev/null
[[ -s "$calls" ]] || { echo "LINK-ORDER the probe wrote no first calls" >&2; tail -n 40 "$out/app.log" >&2; exit 4; }
echo "LINK-ORDER first calls $(wc -l <"$calls" | tr -d ' ')"
python3 -I scripts/cmux-next/link-order.py --calls "$calls" --binary "$framework" --out "$out/CmuxNextApp.order" || exit 4
echo "LINK-ORDER symbols $(grep -vc '^#' "$out/CmuxNextApp.order")"
echo "LINK-ORDER order file .build/link-order/CmuxNextApp.order (commit it as Packages/macOS/CmuxNext/LinkOrder/CmuxNextApp.order)"
