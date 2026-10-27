// The blocking probe's selection rules (probe.c): which threads it watches, which process records and which
// mach calls count. Plain C with no system calls, so tests/test_blocking_probe_report.py compiles and checks them
// on any host.
#ifndef CMUX_BLOCKING_PROBE_MATCH_H
#define CMUX_BLOCKING_PROBE_MATCH_H

#include <stdint.h>
#include <stdio.h>
#include <string.h>

enum { PROBE_MAX_ARGS = 8 };

// <mach/message.h>'s MACH_SEND_MSG and MACH_RCV_MSG, which mach_msg2's 64-bit options keep in their low bits
// (MACH64_SEND_MSG, MACH64_RCV_MSG); probe.c checks they match the SDK's.
enum { PROBE_MACH_SEND_MSG = 0x1, PROBE_MACH_RCV_MSG = 0x2 };

// The whole of `name` matches `pattern`, where `*` matches any run of characters (backtracking to the last `*`):
// `surface-*-host` matches `surface-12-host` and neither `surface-12-host-frames` nor `surface-12-wait`.
static int probe_name_matches(const char *pattern, const char *name) {
    const char *star = NULL, *mark = NULL;
    while (*name != 0) {
        if (*pattern == '*') {
            star = pattern++;
            mark = name;
        } else if (*pattern == *name) {
            pattern++;
            name++;
        } else if (star != NULL) {
            pattern = star + 1;
            name = ++mark;
        } else {
            return 0;
        }
    }
    while (*pattern == '*') pattern++;
    return *pattern == 0;
}

// argv (argv[0], the program, not included) holds every argument of `wanted`, a comma-separated list of at most
// PROBE_MAX_ARGS; any further ones are not checked.
static int probe_argv_holds_all(int argc, const char *const *argv, const char *wanted) {
    char store[512];
    snprintf(store, sizeof store, "%s", wanted);
    char *cursor = store;
    for (int seen = 0; cursor != NULL && seen < PROBE_MAX_ARGS; seen++) {
        char *comma = strchr(cursor, ',');
        if (comma != NULL) *comma = 0;
        int found = cursor[0] == 0;
        for (int i = 1; i < argc && argv != NULL && !found; i++) {
            found = argv[i] != NULL && strcmp(argv[i], cursor) == 0;
        }
        if (!found) return 0;
        cursor = comma != NULL ? comma + 1 : NULL;
    }
    return 1;
}

// The kind of a mach_msg or mach_msg2 call, or NULL when it is not recorded: a call without a receive (a send
// only), or the main run loop's own wait for its next event (`run_loop_idle`: between its last BeforeWaiting and
// first AfterWaiting observer), which Chrome's message pump also waits outside any ScopedBlockingCall
// (base/message_loop/message_pump_apple.mm). On the main or the probe's thread every other receive is `receive`;
// on a watched worker a receive without a send is that thread's wait for its next input (`input_wait`), and a
// send that waits for its reply in the same call (MACH_SEND_MSG | MACH_RCV_MSG) is `receive`: a request blocked
// on another process.
static const char *probe_mach_kind(uint64_t options, int blocking_thread, int run_loop_idle, const char *receive,
                                   const char *input_wait) {
    if ((options & PROBE_MACH_RCV_MSG) == 0) return NULL;
    if (blocking_thread) return run_loop_idle ? NULL : receive;
    return (options & PROBE_MACH_SEND_MSG) != 0 ? receive : input_wait;
}

#endif
