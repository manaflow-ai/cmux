// The blocking probe's selection rules (probe.c): which threads it watches and which process records. Plain C
// with no system calls, so tests/test_blocking_probe_report.py compiles and checks them on any host.
#ifndef CMUX_BLOCKING_PROBE_MATCH_H
#define CMUX_BLOCKING_PROBE_MATCH_H

#include <stdio.h>
#include <string.h>

enum { PROBE_MAX_ARGS = 8 };

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

#endif
