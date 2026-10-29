#!/usr/bin/env bash
# Finds blocking in cmux-next (plans/cmux-next/threading-model.md): builds a tagged Debug (or --config=bench)
# app, loads scripts/measure/blocking-probe/probe.c into it with DYLD_INSERT_LIBRARIES (the main thread) and,
# through the app's spawn of cmux-tui, into the app session's owner (`cmux-tui --headless --session
# cmux-app-<tag>`: its request and echo threads, $daemon_threads below), runs the every-action sweep (light and
# STRESS, every catalog action and interaction), and ranks every file, socket, process, lock and sleep wait by its
# first cmux frame, worst first by total time, in four sections: app_main, app_chromium (the main thread's waits
# that Chromium's code makes), daemon_request and daemon_input_wait (a daemon thread's wait for its next input,
# listed apart) (artifacts/blocking-probe/blocking-probe.md and .json). Then it files them (task 301):
# blocking-probe-filing.json holds the MQ-11 tasks (app_main), the MQ-13 tasks (daemon_request), the app_chromium
# total for the CEF helper-app program (an open number) and RUN-2's verdict; perf-lead-rows.md the RUN-2 and MQ-13
# daemon rows for perf-lead.md section 5. A measurement only: the probe is never linked into or shipped with cmux,
# and it runs only on the fleet (a logged-in console host).
#   cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/blocking-probe.sh \
#     --ref <sha> --key <key> --artifact artifacts/blocking-probe.tar.gz [--arg=--config=bench] [--arg=--sessions=light]
#   nx-remote --needs gui -- scripts/measure/blocking-probe.sh [--config=bench] [--until-mark NAME] [sweep arguments]
# --until-mark NAME (or --until-mark=NAME) adds the launch section, listed first: each launch's main-thread calls
# made before the app sent the launch mark NAME (startup_complete, first_window_frame_committed: the names
# scripts/cmux-next/bench-startup.py waits on), the raw list of plans/cmux-next/chrome-parity/p08-startup.md Q5.
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
# The daemon threads that serve requests and echo output, whole names with `*` for a terminal id (the key echo
# path and request threads of plans/cmux-next/chrome-parity/p02-threads.md section C; cmux-tui-core unless
# named): server/listen.rs mux-conn, websocket_listener.rs mux-ws-conn, connection_scheduler.rs
# mux-control-dispatch, line_connection.rs mux-line-out, cmux-tui pty_input.rs mux-pty-input, cmd_attach.rs
# mux-attach-out and mux-render-attach-out, terminal_snapshot.rs mux-snapshot-attach-out, mux/terminal_work.rs
# mux-terminal-work, surface.rs surface-<id>-host, surface/hosted_reader.rs surface-<id>-host-frames,
# surface/spawn.rs surface-<id>-reader. Not surface-<id>-wait: it waits for the shell's exit, nothing else.
daemon_threads="mux-conn,mux-ws-conn,mux-control-dispatch,mux-line-out,mux-pty-input,mux-attach-out"
daemon_threads+=",mux-render-attach-out,mux-snapshot-attach-out,mux-terminal-work"
daemon_threads+=",surface-*-host,surface-*-host-frames,surface-*-reader"
# Only the app's own session owner records: both arguments are in its argv; its `server ensure` client (no
# --headless), the Chief conversation owner and a cloud link (other sessions) stay inert.
daemon_args="--headless,cmux-app-$tag"
# This run's dumps only: a daemon left from an earlier run (killed before its teardown) writes other names.
run_id="$(date +%s)-$$"
out="$root/artifacts/blocking-probe"
rm -rf "$out"
mkdir -p "$out/dumps"
report="$root/scripts/measure/blocking-probe-report.py"
reload_config=() sweep_args=() until_mark=""
while (( $# > 0 )); do
  arg="$1"
  shift
  case "$arg" in
    --config=*) reload_config=(--config "${arg#--config=}") ;;
    --until-mark=*) until_mark="${arg#--until-mark=}" ;;
    --until-mark)
      if (( $# == 0 )); then
        echo "blocking-probe: --until-mark takes a launch mark name" >&2
        exit 2
      fi
      until_mark="$1"
      shift ;;
    --keep|--app-env|--app-env=*)
      echo "blocking-probe: $arg is not allowed here (the probe owns the app's environment and quits the app)" >&2
      exit 2 ;;
    *) sweep_args+=("$arg") ;;
  esac
done
# A launch mark's name as LaunchMarkSink writes it (`<name> <ms>`): lowercase words, digits, `_` and `.`.
if [[ -n "$until_mark" && ! "$until_mark" =~ ^[a-z][a-z0-9_.]*$ ]]; then
  echo "blocking-probe: --until-mark $until_mark is not a launch mark name (lowercase, digits, _ and .)" >&2
  exit 2
fi
# With a launch window, the probe copies the main thread's entries when the app writes that mark's line
# (probe.c, CMUX_BLOCKING_PROBE_UNTIL_MARK) and writes the copy to <dump>.window; the preflight checks it with a
# mark of its own (empty: no window).
preflight_mark="" preflight_window=() app_window_env=() report_window=()
if [[ -n "$until_mark" ]]; then
  preflight_mark=preflight_mark
  preflight_window=(--until-mark "$preflight_mark")
  app_window_env=(--app-env "CMUX_BLOCKING_PROBE_UNTIL_MARK=$until_mark")
  report_window=(--until-mark "$until_mark")
fi
# Ends every daemon of the tag's bundle (the session owner, the Chief owner, acpmux, their hosts; by bundle path,
# never by name): an owner outlives its app and would keep the probe loaded, and the next run's `server ensure`
# would reuse it instead of starting one that loads this run's probe.
end_tag_daemons() {
  [[ -n "${app:-}" && -d "$app" ]] || return 0
  python3 "$root/scripts/cmux-next/tag_teardown.py" "$app" >>"$out/teardown.log" 2>&1 || true
}
# On any exit: end the tag's daemons, then keep what exists, with the runner's home and user name taken out of
# the logs.
pack() {
  [[ -d "$out" ]] || return 0
  end_tag_daemons
  find "$out" -type f \( -name '*.log' -o -name '*.md' -o -name '*.json' -o -name '*.tsv' \) -print0 \
    | xargs -0 sed -i '' -e "s|$HOME|~|g" -e "s|/Users/$USER|/Users/<user>|g" 2>/dev/null || true
  tar -czf "$root/artifacts/blocking-probe.tar.gz" -C "$root/artifacts" blocking-probe 2>/dev/null || true
}
trap pack EXIT

# The probe (the host's architecture; the linker signs it ad hoc). Without mach_msg2_internal in the SDK's
# libsystem_kernel (before macOS 13) it sees mach_msg only.
probe_flags=()
if ! grep -q '_mach_msg2_internal' "$(xcrun --show-sdk-path)/usr/lib/system/libsystem_kernel.tbd" 2>/dev/null; then
  probe_flags+=(-DPROBE_NO_MACH_MSG2)
  echo "blocking-probe: the SDK's libsystem_kernel has no mach_msg2_internal; the probe sees mach_msg receives only" >&2
fi
clang -dynamiclib -O2 -Wall ${probe_flags[@]+"${probe_flags[@]}"} -framework CoreFoundation -framework Security \
  -o "$out/blocking-probe.dylib" scripts/measure/blocking-probe/probe.c

# Preflight on this host, before any app: dyld refuses a library that interposes a name this host's system
# libraries lack (then the app would not start), so check the $NOCANCEL names and mach_msg2_internal, then load
# the probe into a small test program and require its self-test row in the final dump.
xcrun nm -u "$out/blocking-probe.dylib" | awk '/NOCANCEL|mach_msg2_internal/ { print $NF }' >"$out/preflight-needs.txt"
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
# The test program plays the three roles. "preflight" is the app: it runs the main run loop (CFRunLoopRun keeps
# the main thread, unlike dispatch_main, which exits it), so the probe's self-test, queued on the main queue,
# runs on the main thread. It spawns "preflight hop --probe-session", `cmux-tui server ensure`'s role: one of the
# two wanted arguments only, so the probe stays inert there and passes itself on. The hop first dlopens
# @loader_path/preflight-lib.dylib: the program and that library sit in preflight-bin/, away from the probe, so the
# dlopen fails if the probe resolves it from its own image (an inert probe must change nothing). That spawns "preflight work
# --probe-owner --probe-session", the session owner's role, with two threads: probe-test-1-host (watched by the
# pattern probe-test-*-host) stats a file and reads a pipe (an input wait), probe-test-1-wait (not watched) checks
# access to a file. Each waits for its child. With a launch window, the app then does what LaunchMarkSink does on
# CMUX_NEXT_LAUNCH_MARKS_FD (the probe's /dev/null): its fcntls, an earlier mark's line, then the launch mark's
# line, and checks access to a file, a call after the mark. The app then makes the cross-process and loader calls:
# a 5 ms mach receive that times out, a synchronous XPC send to a service that does not exist, the same
# @loader_path dlopen (recorded, and resolved from the program as without the probe), a
# getpwuid_r and a fork whose child exits at once. A timer then exits; until it fires the main run loop idles, a
# wait that is never a mach receive, as the receives inside the XPC send and getpwuid_r are not.
cat >"$out/preflight.c" <<'C'
#include <CoreFoundation/CoreFoundation.h>
#include <crt_externs.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <mach/mach.h>
#include <pthread.h>
#include <pwd.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#include <xpc/xpc.h>
static void done(CFRunLoopTimerRef timer, void *info) { (void)timer; (void)info; exit(0); }
static int run(char *const argv[]) {
    pid_t pid;
    int status;
    if (posix_spawn(&pid, argv[0], NULL, NULL, argv, *_NSGetEnviron()) != 0) return 1;
    return waitpid(pid, &status, 0) == pid && WIFEXITED(status) && WEXITSTATUS(status) == 0 ? 0 : 1;
}
static void *host(void *unused) {
    (void)unused;
    struct stat info;
    int ends[2];
    char byte = 0;
    pthread_setname_np("probe-test-1-host");
    (void)stat("/", &info);
    if (pipe(ends) == 0) {
        (void)write(ends[1], &byte, 1);
        (void)read(ends[0], &byte, 1);
        close(ends[0]);
        close(ends[1]);
    }
    return NULL;
}
static void *waiter(void *unused) {
    (void)unused;
    pthread_setname_np("probe-test-1-wait");
    (void)access("/", F_OK);
    return NULL;
}
// LaunchMarkSink's calls on the probe's mark descriptor, which the probe never records.
static int send_marks(int fd) {
    static const char early[] = "preflight_early 0.5\n", line[] = "preflight_mark 1.0\n";
    if (fcntl(fd, F_GETFD) == -1 || fcntl(fd, F_SETFD, FD_CLOEXEC) == -1
        || fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == -1) {
        return 1;
    }
    if (write(fd, early, sizeof early - 1) != (ssize_t)(sizeof early - 1)) return 1;
    return write(fd, line, sizeof line - 1) == (ssize_t)(sizeof line - 1) ? 0 : 1;
}
static int fail(const char *what) {
    fprintf(stderr, "preflight: %s\n", what);
    return 1;
}
// A library beside the program, by a name dyld resolves from the caller's image.
static int load_beside(void) {
    if (dlopen("@loader_path/preflight-lib.dylib", RTLD_NOW) != NULL) return 0;
    fprintf(stderr, "preflight: the @loader_path dlopen failed: %s\n", dlerror());
    return 1;
}
// One call of each cross-process and loader kind, on the main thread.
static int cross_process(void) {
    mach_port_t port = MACH_PORT_NULL;
    if (mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &port) != KERN_SUCCESS) return fail("no port");
    struct { mach_msg_header_t header; char body[256]; } message;
    memset(&message, 0, sizeof message);
    mach_msg_return_t received = mach_msg(&message.header, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof message, port,
                                          5, MACH_PORT_NULL);
    (void)mach_port_mod_refs(mach_task_self(), port, MACH_PORT_RIGHT_RECEIVE, -1);
    if (received != MACH_RCV_TIMED_OUT) return fail("the mach receive did not time out");
    xpc_connection_t connection = xpc_connection_create_mach_service("com.cmuxterm.blocking-probe.none", NULL, 0);
    xpc_connection_set_event_handler(connection, ^(xpc_object_t event) { (void)event; });
    xpc_connection_resume(connection);
    xpc_object_t request = xpc_dictionary_create(NULL, NULL, 0);
    xpc_object_t reply = xpc_connection_send_message_with_reply_sync(connection, request);
    int refused = xpc_get_type(reply) == XPC_TYPE_ERROR;
    xpc_release(reply);
    xpc_release(request);
    xpc_connection_cancel(connection);
    xpc_release(connection);
    if (!refused) return fail("a service that does not exist replied");
    if (load_beside() != 0) return 1;
    struct passwd entry, *found = NULL;
    char buffer[4096];
    if (getpwuid_r(getuid(), &entry, buffer, sizeof buffer, &found) != 0 || found == NULL) return fail("no user");
    int status;
    pid_t child = fork();
    if (child == 0) _exit(0);
    if (child < 0 || waitpid(child, &status, 0) != child || !WIFEXITED(status)) return fail("no fork");
    return 0;
}
static int join(void *(*body)(void *)) {
    pthread_t thread;
    return pthread_create(&thread, NULL, body, NULL) == 0 && pthread_join(thread, NULL) == 0 ? 0 : 1;
}
int main(int argc, char **argv) {
    if (argc > 1 && strcmp(argv[1], "hop") == 0) {
        if (load_beside() != 0) return 1;
        char *next[] = {argv[0], "work", "--probe-owner", "--probe-session", NULL};
        return run(next);
    }
    if (argc > 1 && strcmp(argv[1], "work") == 0) {
        if (join(host) != 0 || join(waiter) != 0) return 1;
    } else {
        char *next[] = {argv[0], "hop", "--probe-session", NULL};
        if (run(next) != 0) return 1;
        const char *marks = getenv("CMUX_NEXT_LAUNCH_MARKS_FD");
        if (marks != NULL) {
            if (send_marks(atoi(marks)) != 0) return 1;
            (void)access("/", F_OK);
        }
        if (cross_process() != 0) return 1;
    }
    CFRunLoopTimerRef timer = CFRunLoopTimerCreate(NULL, CFAbsoluteTimeGetCurrent() + 0.5, 0, 0, 0, done, NULL);
    CFRunLoopAddTimer(CFRunLoopGetMain(), timer, kCFRunLoopCommonModes);
    CFRunLoopRun();
    return 1;
}
C
mkdir -p "$out/preflight-bin" "$out/preflight-dumps"
printf 'int preflight_lib(void) { return 1; }\n' >"$out/preflight-lib.c"
clang -dynamiclib -O0 -o "$out/preflight-bin/preflight-lib.dylib" "$out/preflight-lib.c"
clang -O0 -framework CoreFoundation -o "$out/preflight-bin/preflight" "$out/preflight.c"
if ! CMUX_BLOCKING_PROBE_UNTIL_MARK="$preflight_mark" DYLD_PRINT_INTERPOSING=1 \
     DYLD_INSERT_LIBRARIES="$out/blocking-probe.dylib" CMUX_BLOCKING_PROBE_OUT="$out/preflight-dumps/probe-%p.tsv" \
     CMUX_BLOCKING_PROBE_CHILD="preflight:--probe-owner,--probe-session:probe-test-*-host" "$out/preflight-bin/preflight" \
     >>"$out/preflight.txt" 2>&1; then
  echo "blocking-probe: the preflight program failed: dyld refused the probe on this host, or a call it checks failed (its preflight: line); see $out/preflight.txt" >&2
  tail -n 20 "$out/preflight.txt" >&2
  exit 1
fi
# The report script checks the dumps (tests/test_blocking_probe_report.py checks its rules): the app's main-thread
# self-test at exit and its one call of each cross-process and loader kind (one mach receive: neither the run
# loop's idle wait nor a receive inside another call), none from the inert hop, the owner's self-test, its watched
# thread's stat and input wait, nothing from its unwatched thread; with a launch window, the app's window: its
# spawn, not its access after the mark, no write or fcntl on the probe's mark descriptor (a missing window file
# fails the check).
preflight_dumps=("$out"/preflight-dumps/probe-*.tsv)
for window in "$out"/preflight-dumps/probe-*.tsv.window; do
  if [[ -e "$window" ]]; then preflight_dumps+=("$window"); fi
done
if ! python3 "$report" --preflight ${preflight_window[@]+"${preflight_window[@]}"} "${preflight_dumps[@]}"; then
  echo "blocking-probe: see $out/preflight.txt and $out/preflight-dumps" >&2
  exit 1
fi
echo "blocking-probe: preflight ok ($(grep -c 'interpos' "$out/preflight.txt") dyld interposing lines; main thread, spawn chain, argument gate, thread patterns, input waits, cross-process kinds, caller-relative dlopen)"

CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" ${reload_config[@]+"${reload_config[@]}"} 2>&1 \
  | tee "$out/reload.log"
app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
if [[ -z "$app" || ! -d "$app" ]]; then
  echo "blocking-probe: the tagged reload printed no app path; its errors, then its last lines:" >&2
  grep -E "error:|BUILD FAILED" "$out/reload.log" | head -n 60 >&2 || true
  tail -n 40 "$out/reload.log" >&2
  exit 1
fi
image="$(basename "$app" .app)"
# A hardened-runtime binary would ignore DYLD_INSERT_LIBRARIES (Debug builds have ENABLE_HARDENED_RUNTIME = NO).
for binary in "$app" "$app/Contents/Resources/bin/cmux-tui"; do
  if [[ ! -e "$binary" ]]; then
    echo "blocking-probe: $binary is missing" >&2
    exit 1
  fi
  if codesign -dv "$binary" 2>&1 | grep -q 'flags=.*runtime'; then
    echo "blocking-probe: $binary has the hardened runtime; DYLD_INSERT_LIBRARIES would be ignored" >&2
    exit 1
  fi
done

# Smoke test of every launch: within 20 s (more than the probe's 10 s dump period) the launched pid's dump must exist and hold the probe's "selftest"
# row (the dylib loaded, interposed a main-thread call and dumped: the probe writes a dump right after its
# self-test, so the check does not wait for the 10 s periodic dump). Within 60 s of the first launch a daemon
# dump (its #threads header is not "main") must hold its self-test row too. Otherwise the sweep is stopped and
# the run fails: a report from a probe that does not work would prove nothing.
watch_launches() {
  local seen=0 pid deadline daemon_deadline=0 daemon_ok=0 daemon_dump
  while sleep 1; do
    if (( seen > 0 && ! daemon_ok )); then
      while read -r daemon_dump; do
        if [[ -n "$daemon_dump" ]] && grep -q '^selftest' "$daemon_dump"; then
          daemon_ok=1
          echo "blocking-probe: probe self-test ok in the daemon ($(basename "$daemon_dump"))"
        fi
      done < <(python3 "$report" --select daemon "$out"/dumps/probe-"$run_id"-*.tsv)
      if (( ! daemon_ok && SECONDS > daemon_deadline )); then
        echo "blocking-probe: FAIL: no daemon dump with a self-test row 60 s after the first launch: the app's spawn of cmux-tui did not carry the probe into its session owner (cmux-tui --headless --session cmux-app-$tag)" | tee "$out/selftest-failed"
        kill "$sweep_pid" 2>/dev/null
        return 1
      fi
    fi
    [[ -f "$out/sweep/sweep.log" ]] || continue
    while read -r pid; do
      deadline=$((SECONDS + 20))
      until grep -q '^selftest' "$out/dumps/probe-$run_id-$pid.tsv" 2>/dev/null; do
        if (( SECONDS > deadline )); then
          echo "blocking-probe: FAIL: pid $pid has no probe self-test row 20 s after launch: the probe did not load or did not interpose" | tee "$out/selftest-failed"
          kill "$sweep_pid" 2>/dev/null
          return 1
        fi
        sleep 1
      done
      echo "blocking-probe: probe self-test ok in pid $pid"
      if (( seen == 0 )); then daemon_deadline=$((SECONDS + 60)); fi
      seen=$((seen + 1))
    done < <(grep -o 'every-action: launched pid [0-9]*' "$out/sweep/sweep.log" | awk '{ print $4 }' | tail -n +$((seen + 1)))
  done
}

# A daemon of this tag still running (from an earlier run, or one the reload did not stop) would serve the first
# launch without the probe: end it before the sweep starts.
end_tag_daemons

status=0
mkdir -p "$out/sweep"
python3 scripts/cmux-next/every-action-sweep.py --tag "$tag" --app "$app" --out "$out/sweep" \
  --app-env "DYLD_INSERT_LIBRARIES=$out/blocking-probe.dylib" \
  --app-env "CMUX_BLOCKING_PROBE_OUT=$out/dumps/probe-$run_id-%p.tsv" \
  --app-env "CMUX_BLOCKING_PROBE_CHILD=cmux-tui:$daemon_args:$daemon_threads" \
  ${app_window_env[@]+"${app_window_env[@]}"} ${sweep_args[@]+"${sweep_args[@]}"} >"$out/sweep/sweep.log" 2>&1 &
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
dumps=("$out"/dumps/probe-"$run_id"-*.tsv)
if [[ ! -e "${dumps[0]}" ]]; then
  echo "blocking-probe: no probe dump: the probe did not load into the app (or the app never exited)" >&2
  exit 1
fi
launches="$(grep -c 'every-action: launched pid' "$out/sweep/sweep.log" || true)"
if [[ -n "$until_mark" ]]; then
  # One launch window per app launch that sent the mark; the report counts each launch without one as missing.
  for window in "$out"/dumps/probe-"$run_id"-*.tsv.window; do
    if [[ -e "$window" ]]; then dumps+=("$window"); fi
  done
fi
# The filing (p02-threads.md task 301): MQ-11 and MQ-13 tasks, the app_chromium hand-off and RUN-2, with the
# sweep's host, macOS, sha and exit status; an MQ-13 task at a (location, kind, thread) p02-threads-303's daemon
# sweep listed, its lines moved from the list's commit (results/p02-threads-303/README.md, "Head") to this one, is
# marked, not new.
filing_args=(--sweep-json "$out/sweep/every-action.json" --sweep-status "$status" --config "${reload_config[1]:-debug}")
known_sites="plans/cmux-next/chrome-parity/results/p02-threads-303/mq13-record-sites.json"
known_sites_sha="969603234252dcc9dca8564e5791f364f8739523"
if [[ -f "$known_sites" ]]; then filing_args+=(--known-sites "$known_sites" --known-sites-sha "$known_sites_sha"); fi
python3 "$report" --app "$app" --launches "$launches" ${report_window[@]+"${report_window[@]}"} --out "$out" \
  "${filing_args[@]}" "${dumps[@]}" | tee "$out/report.log"
echo "blocking-probe: sweep exited $status; report $out/blocking-probe.md, tasks $out/blocking-probe-filing.json," \
  "perf-lead.md section 5 rows $out/perf-lead-rows.md"
grep '^RUN-2 ' "$out/report.log" || true
