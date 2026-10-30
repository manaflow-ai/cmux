#!/usr/bin/env bash
# Finds main-thread blocking in cmux-next (plans/cmux-next/threading-model.md): builds a tagged Debug (or
# --config=bench) app, loads scripts/measure/blocking-probe/probe.c into it with DYLD_INSERT_LIBRARIES, runs the
# every-action sweep (light and STRESS, every catalog action and interaction), and ranks every main-thread
# file, socket, process, lock and sleep wait by its first cmux frame, worst first by total time
# (artifacts/blocking-probe/blocking-probe.md and .json). A measurement only: the probe is never linked into
# or shipped with cmux, and it runs only on the fleet (a logged-in console host).
#   cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/blocking-probe.sh \
#     --ref <sha> --key <key> --artifact artifacts/blocking-probe.tar.gz [--arg=--config=bench] [--arg=--sessions=light]
#   nx-remote --needs gui -- scripts/measure/blocking-probe.sh [--config=bench] [sweep arguments]
# Every other argument goes to scripts/cmux-next/every-action-sweep.py.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
root="$(pwd)"
# A fleet step (cmux-ci sets CMUX_CI_STEP_KEY) or an nx-remote job (NX_JOB_ID) only: it builds and runs the
# app with an interposer inside it, which never belongs on a developer Mac.
if [[ -z "${CMUX_CI_STEP_KEY:-}" && -z "${NX_JOB_ID:-}" ]]; then
  echo "blocking-probe: runs only on the fleet (cmux-ci run or nx-remote); see the usage at the top of this file" >&2
  exit 2
fi
for sub in ghostty ghostty-next; do
  [ -e "$sub/.git" ] || git submodule update --init --depth 1 "$sub"
done
if [ ! -f GhosttyKit.xcframework/Info.plist ]; then
  rm -rf GhosttyKit.xcframework
  if [ -z "${GHOSTTYKIT_ARCHIVE_CACHE_DIR:-}" ] && [ -n "${CI_SHARED_CACHE_DIR:-}" ]; then
    export GHOSTTYKIT_ARCHIVE_CACHE_DIR="$CI_SHARED_CACHE_DIR/ghosttykit-archives"
  fi
  ./scripts/download-prebuilt-ghosttykit.sh
fi
tag="blocking-probe"
out="$root/artifacts/blocking-probe"
rm -rf "$out"
mkdir -p "$out/dumps"
reload_config=() sweep_args=()
for arg in "$@"; do
  case "$arg" in
    --config=*) reload_config=(--config "${arg#--config=}") ;;
    --keep|--app-env|--app-env=*)
      echo "blocking-probe: $arg is not allowed here (the probe owns the app's environment and quits the app)" >&2
      exit 2 ;;
    *) sweep_args+=("$arg") ;;
  esac
done
# On any exit: keep what exists, with the runner's home and user name taken out of the logs.
pack() {
  [[ -d "$out" ]] || return 0
  find "$out" -type f \( -name '*.log' -o -name '*.md' -o -name '*.json' -o -name '*.tsv' \) -print0 \
    | xargs -0 sed -i '' -e "s|$HOME|~|g" -e "s|/Users/$USER|/Users/<user>|g" 2>/dev/null || true
  tar -czf "$root/artifacts/blocking-probe.tar.gz" -C "$root/artifacts" blocking-probe 2>/dev/null || true
}
trap pack EXIT

# The probe (the host's architecture; the linker signs it ad hoc).
clang -dynamiclib -O2 -Wall -framework CoreFoundation -o "$out/blocking-probe.dylib" scripts/measure/blocking-probe/probe.c

# Preflight on this host, before any app: dyld refuses a library that interposes a name this host's system
# libraries lack (then the app would not start), so check the $NOCANCEL names, then load the probe into a
# small test program and require its self-test row in the final dump.
xcrun nm -u "$out/blocking-probe.dylib" | awk '/NOCANCEL/ { print $NF }' >"$out/preflight-needs.txt"
if dyld_info -exports /usr/lib/system/libsystem_kernel.dylib >"$out/preflight-exports.txt" 2>&1; then
  while read -r name; do
    if ! grep -qF -- "$name" "$out/preflight-exports.txt"; then
      echo "blocking-probe: this host's libsystem_kernel does not export $name; dyld would refuse the probe" >&2
      exit 1
    fi
  done <"$out/preflight-needs.txt"
else
  echo "blocking-probe: dyld_info is missing here; the test program below checks the names instead" >&2
fi
# The test program runs the main run loop (CFRunLoopRun keeps the main thread, unlike dispatch_main, which
# exits it), so the probe's self-test, queued on the main queue, runs on the main thread; a timer then exits.
cat >"$out/preflight.c" <<'C'
#include <CoreFoundation/CoreFoundation.h>
#include <stdlib.h>
static void done(CFRunLoopTimerRef timer, void *info) { (void)timer; (void)info; exit(0); }
int main(void) {
    CFRunLoopTimerRef timer = CFRunLoopTimerCreate(NULL, CFAbsoluteTimeGetCurrent() + 0.5, 0, 0, 0, done, NULL);
    CFRunLoopAddTimer(CFRunLoopGetMain(), timer, kCFRunLoopCommonModes);
    CFRunLoopRun();
    return 1;
}
C
clang -O0 -framework CoreFoundation -o "$out/preflight" "$out/preflight.c"
if ! DYLD_PRINT_INTERPOSING=1 DYLD_INSERT_LIBRARIES="$out/blocking-probe.dylib" \
     CMUX_BLOCKING_PROBE_OUT="$out/preflight.tsv" "$out/preflight" >>"$out/preflight.txt" 2>&1; then
  echo "blocking-probe: the probe does not load on this host (dyld refused it); see $out/preflight.txt" >&2
  tail -n 20 "$out/preflight.txt" >&2
  exit 1
fi
if ! grep -q '^selftest' "$out/preflight.tsv" 2>/dev/null || ! grep -q '^#final	1' "$out/preflight.tsv"; then
  echo "blocking-probe: the probe loaded but recorded no self-test row at exit; see $out/preflight.txt" >&2
  exit 1
fi
echo "blocking-probe: preflight ok ($(grep -c 'interpos' "$out/preflight.txt") dyld interposing lines)"

CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" ${reload_config[@]+"${reload_config[@]}"} 2>&1 \
  | tee "$out/reload.log" | tail -n 40
app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
if [[ -z "$app" || ! -d "$app" ]]; then
  echo "blocking-probe: the tagged reload printed no app path; its errors, then its last lines:" >&2
  grep -E "error:|BUILD FAILED" "$out/reload.log" | head -n 60 >&2 || true
  tail -n 40 "$out/reload.log" >&2
  exit 1
fi
image="$(basename "$app" .app)"
# A hardened-runtime app would ignore DYLD_INSERT_LIBRARIES (Debug builds have ENABLE_HARDENED_RUNTIME = NO).
if codesign -dv "$app" 2>&1 | grep -q 'flags=.*runtime'; then
  echo "blocking-probe: $app has the hardened runtime; DYLD_INSERT_LIBRARIES would be ignored" >&2
  exit 1
fi

# Smoke test of every launch: within 20 s (more than the probe's 10 s dump period) the launched pid's dump must exist and hold the probe's "selftest"
# row (the dylib loaded, interposed a main-thread call and dumped: the probe writes a dump right after its
# self-test, so the check does not wait for the 10 s periodic dump). Otherwise the sweep is stopped and the run
# fails: a report from a probe that does not work would prove nothing.
watch_launches() {
  local seen=0 pid deadline
  while sleep 1; do
    [[ -f "$out/sweep/sweep.log" ]] || continue
    while read -r pid; do
      deadline=$((SECONDS + 20))
      until grep -q '^selftest' "$out/dumps/probe-$pid.tsv" 2>/dev/null; do
        if (( SECONDS > deadline )); then
          echo "blocking-probe: FAIL: pid $pid has no probe self-test row 20 s after launch: the probe did not load or did not interpose" | tee "$out/selftest-failed"
          kill "$sweep_pid" 2>/dev/null
          return 1
        fi
        sleep 1
      done
      echo "blocking-probe: probe self-test ok in pid $pid"
      seen=$((seen + 1))
    done < <(grep -o 'every-action: launched pid [0-9]*' "$out/sweep/sweep.log" | awk '{ print $4 }' | tail -n +$((seen + 1)))
  done
}

status=0
mkdir -p "$out/sweep"
python3 scripts/cmux-next/every-action-sweep.py --tag "$tag" --app "$app" --out "$out/sweep" \
  --app-env "DYLD_INSERT_LIBRARIES=$out/blocking-probe.dylib" \
  --app-env "CMUX_BLOCKING_PROBE_OUT=$out/dumps/probe-%p.tsv" \
  ${sweep_args[@]+"${sweep_args[@]}"} >"$out/sweep/sweep.log" 2>&1 &
sweep_pid=$!
tail -n +1 -f "$out/sweep/sweep.log" &
tail_pid=$!
watch_launches &
watcher_pid=$!
wait "$sweep_pid" || status=$?
kill "$watcher_pid" "$tail_pid" 2>/dev/null || true
if [[ -f "$out/selftest-failed" ]]; then
  cat "$out/selftest-failed" >&2
  exit 1
fi
dumps=("$out"/dumps/probe-*.tsv)
if [[ ! -e "${dumps[0]}" ]]; then
  echo "blocking-probe: no probe dump: the probe did not load into the app (or the app never exited)" >&2
  exit 1
fi
launches="$(grep -c 'every-action: launched pid' "$out/sweep/sweep.log" || true)"
python3 scripts/measure/blocking-probe-report.py --app "$app" --launches "$launches" --out "$out" "${dumps[@]}"
echo "blocking-probe: sweep exited $status; report $out/blocking-probe.md"
