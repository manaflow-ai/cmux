// Blocking probe: a measurement tool, never linked into or shipped with cmux.
//
// Loaded with DYLD_INSERT_LIBRARIES into a tagged Debug or bench cmux-next app on the fleet
// (scripts/measure/blocking-probe.sh), it interposes the system calls and waits that block and records the
// calls made on the threads it watches: per call stack (a hash of its first STACK_KEY frames) and thread a count,
// the total and longest time, and the longest call's stack. scripts/measure/blocking-probe-report.py then groups
// the entries by their first cmux frame, so each cmux call site is its own row however many wrappers sit above
// the system call.
//
// Threads: the main thread only, or CMUX_PROBE_THREADS, a comma-separated list of thread-name patterns, each
// matched against the whole name with `*` for any run of characters (the word "main" stands for the main
// thread), as Chrome names a thread by its role (base::PlatformThread::SetName, base/threading/platform_thread.h)
// and its ScopedBlockingCall checks only the threads that must not block (base/threading/thread_restrictions.h).
// So `surface-*-host` watches each terminal's host thread and not its `surface-<id>-wait` thread. Each entry
// keeps the pattern its thread matched.
//
// Into the daemon: CMUX_BLOCKING_PROBE_CHILD=<program>:<args>:<patterns> makes this process's posix_spawn(p) of
// <program> (by file name) add the probe to the child's environment, with CMUX_PROBE_THREADS=<patterns> and
// CMUX_BLOCKING_PROBE_ARG=<args>, a comma-separated list. A process with CMUX_BLOCKING_PROBE_ARG records only when
// its argv holds every one of those arguments; otherwise the probe stays inert and leaves its variables in the
// environment, so they reach the process's own children. `--headless,cmux-app-<tag>` selects the app's session
// owner only: its `server ensure` client (no --headless), the Chief conversation owner and a cloud link's
// `remote connect --headless` (other sessions) stay inert.
//
// Self-test: at load the probe makes file system calls on a watched thread (the main queue when the main
// thread is watched, else the probe's own thread), records them as kind "selftest" and writes a dump at once;
// the harness fails the run when that dump lacks them (the probe did not load, or interposing did not work).
//
// Output: $CMUX_BLOCKING_PROBE_OUT ("%p" becomes the pid), rewritten every DUMP_SECONDS by the probe's own
// thread (so a run the sweep kills, or a crash, keeps what it saw until the last dump) and at a clean exit,
// where the dump thread is stopped and joined first, so one writer at a time; each writer writes its own
// temporary file and renames it. The header says which ("#final 1" only at exit), the watched threads
// ("#threads") and the program ("#process").
//
// Launch window: CMUX_BLOCKING_PROBE_UNTIL_MARK=<name> (main thread watched) copies the main thread's entries
// the first time the app sends the launch mark <name>, its `<name> <ms>\n` line written to the descriptor in
// CMUX_NEXT_LAUNCH_MARKS_FD (CmuxNextLaunch/LaunchMarkSink.swift), and the dump thread writes that copy once to
// <out>.window ("#window" header): the main thread's calls before the mark, as Chrome's startup metrics cut the
// launch at a named milestone (components/startup_metric_utils/browser/startup_metric_utils.cc). Without a
// launcher's descriptor the probe opens /dev/null as one and names it in CMUX_NEXT_LAUNCH_MARKS_FD.
//
// Behavior is never changed, except that a CMUX_BLOCKING_PROBE_CHILD spawn gets the probe's variables (and a
// launch window adds a CMUX_NEXT_LAUNCH_MARKS_FD to /dev/null when the launcher gave none, and a watched main
// thread's run loop gets two observers that only set the probe's idle flag; the probe links Security and XPC, which
// a process without them then loads): every
// interposer calls the real function on every path with the same arguments, returns its result and keeps its
// errno. The recording path allocates nothing (a fixed table claimed and updated with atomics, `backtrace`
// into a fixed array) and takes no lock (only the launch mark's one copy takes the dump thread's lock, to wake
// it). No signal disposition is touched. A recording process removes
// DYLD_INSERT_LIBRARIES and the probe's variables from its environment, so its child processes (shells, the
// daemon's terminal hosts, helpers) never load the probe; a fork without exec keeps a copy of the parent's
// table, and its dumps go to its own pid's file.
//
// Seen: open/openat (+$NOCANCEL), read/pread/write/pwrite (+$NOCANCEL), stat/lstat/fstat/fstatat/statfs/access,
// getattrlist/getattrlistbulk, fsync (+$NOCANCEL), fcntl (every command: F_FULLFSYNC, F_SETLKW), flock,
// mkdir/mkdirat, unlink/unlinkat, rename/renameat, readlink, close (only past WAIT_FLOOR_NS), recv/recvfrom/recvmsg, send/sendto/sendmsg, connect,
// select/poll, getaddrinfo, waitpid/wait4, posix_spawn/posix_spawnp, dispatch_semaphore_wait, dispatch_group_wait, dispatch_sync(_f),
// pthread_cond_(timed)wait, pthread_mutex_lock, os_unfair_lock_lock, usleep, nanosleep. Waits count only past
// WAIT_FLOOR_NS; every file or socket call counts, however fast (Chrome's rule: no disk on the UI thread).
// Cross-process and loader calls: xpc_connection_send_message_with_reply_sync ("xpc-reply", BlockingKind.xpcReply),
// mach_msg and mach_msg2_internal with a receive ("mach-receive", a wait past WAIT_FLOOR_NS), fork
// ("process-spawn"), dlopen ("library-load"), getpwuid/getpwuid_r ("system-query"), SecItemCopyMatching/SecItemAdd
// ("system-call"): every call counts but a mach receive's. An XPC reply, SecItem, getpwuid or dlopen call is one
// entry with its whole time: the XPC replies and mach receives it makes inside are not recorded again (its file
// calls still are), as Chrome's ScopedBlockingCall nested in another adds no second blocking scope
// (base/threading/scoped_blocking_call_internal.cc). The main run loop's own wait for its next event, from its
// last BeforeWaiting observer to its first AfterWaiting one (the probe's two observers, in the common modes), is
// not a mach receive; a nested run loop in another mode waiting on main is. Every dlopen, in an inert process and
// before the constructor too, goes through dyld's dlopen_from with the caller's address, so @rpath and
// @loader_path resolve from the caller as without the probe (a dyld without dlopen_from is named on stderr).
// dispatch_sync's time includes the block's own work. On a watched thread other than main, a wait for the next
// input has its own kind, "input-wait:<call>": a read of a socket, pipe or PTY (not of a regular file), recv*,
// poll, select, waitpid and wait4. Chrome's message pump waits for work outside any ScopedBlockingCall the same
// way; the report lists these apart from blocking work.
// Not seen (known gaps): pthread_rwlock_*, os_unfair_lock_lock_with_options, semaphore_wait, mach_msg_overwrite,
// __ulock_wait/os_sync_wait_on_address, kevent, renamex_np/renameatx_np, ftruncate, getxattr/setxattr,
// readv/writev, getdirentries64, copyfile/clonefile, dispatch_async_and_wait, vfork, dlopen_preflight, the other
// getpw*/getgr* lookups, the $NOCANCEL forms of close, pwrite, connect, recvmsg, sendmsg, select, waitpid and
// wait4, and calls inside one system library to itself (dyld interposing sees calls across images only), so the
// probe under-counts and never over-counts.
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <dispatch/dispatch.h>
#include <limits.h>
#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <execinfo.h>
#include <fcntl.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <netdb.h>
#include <os/lock.h>
#include <poll.h>
#include <pthread.h>
#include <pwd.h>
#include <spawn.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/attr.h>
#include <sys/file.h>
#include <sys/mount.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#include <xpc/xpc.h>

#include "probe_match.h"

_Static_assert(PROBE_MACH_SEND_MSG == MACH_SEND_MSG && PROBE_MACH_RCV_MSG == MACH_RCV_MSG,
               "probe_match.h's mach options are the SDK's");

#define DYLD_INTERPOSE(_replacement, _replacee)                                                    \
    __attribute__((used)) static struct {                                                         \
        const void *replacement;                                                                  \
        const void *replacee;                                                                     \
    } _interpose_##_replacement __attribute__((section("__DATA,__interpose"))) = {                 \
        (const void *)(unsigned long)&_replacement, (const void *)(unsigned long)&_replacee};

// The libc entry points libc's own non-cancelable paths and Foundation use.
extern int open_nocancel(const char *, int, ...) __asm("_open$NOCANCEL");
extern int openat_nocancel(int, const char *, int, ...) __asm("_openat$NOCANCEL");
extern ssize_t read_nocancel(int, void *, size_t) __asm("_read$NOCANCEL");
extern ssize_t pread_nocancel(int, void *, size_t, off_t) __asm("_pread$NOCANCEL");
extern ssize_t write_nocancel(int, const void *, size_t) __asm("_write$NOCANCEL");
extern int fcntl_nocancel(int, int, ...) __asm("_fcntl$NOCANCEL");
extern int fsync_nocancel(int) __asm("_fsync$NOCANCEL");
extern int poll_nocancel(struct pollfd *, nfds_t, int) __asm("_poll$NOCANCEL");
extern ssize_t recvfrom_nocancel(int, void *, size_t, int, struct sockaddr *, socklen_t *) __asm("_recvfrom$NOCANCEL");
extern ssize_t sendto_nocancel(int, const void *, size_t, int, const struct sockaddr *, socklen_t) __asm("_sendto$NOCANCEL");
// libsystem_kernel's mach_msg2 entry (macOS 13+), which the SDK's inline mach_msg2 and libdispatch call: the message,
// the 64-bit options (MACH64_RCV_MSG in the low bits), then the header and sizes packed in pairs. Named apart from
// the SDK's own declaration, if it has one. blocking-probe.sh builds without it (PROBE_NO_MACH_MSG2) when the SDK
// does not export it.
#ifndef PROBE_NO_MACH_MSG2
extern mach_msg_return_t probe_mach_msg2_internal(void *, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t,
                                                  uint64_t) __asm("_mach_msg2_internal");
#endif

enum {
    SLOTS = 8192, MAX_PROBES = 64, DEPTH = 24, STACK_KEY = 16, WAIT_FLOOR_NS = 1000000, DUMP_SECONDS = 10,
    MAX_PATTERNS = 16, CARRIED = 4,
};

typedef struct {
    const char *kind;    // published last (release): a dump reads only entries whose kind it sees
    const char *thread;  // "main", "probe" (the self-test on the probe's thread) or the matched pattern
    uint64_t key;        // hash of the kind, the thread and the call's first STACK_KEY frames
    uint64_t count, total_ns, max_ns;
    int depth;
    void *stack[DEPTH];  // the longest call's stack
    // The launch window's copy (CMUX_BLOCKING_PROBE_UNTIL_MARK), made once when the mark arrives; 0 calls after.
    uint64_t window_count, window_total_ns, window_max_ns;
    int window_depth;
    void *window_stack[DEPTH];
} Entry;

// A slot being filled: other threads skip it (a second entry for the same key is fine, the report adds them).
static const char claiming[] = "claiming";

// Written by every watched thread with atomics; the dump thread reads it while it changes (counts may be one call
// behind, and a stack being replaced may mix two calls of the same entry, which share their first STACK_KEY frames).
static Entry table[SLOTS];
static uint64_t dropped;
static uint64_t calls;      // interposed calls timed on watched threads (each costs two clock reads)
static uint64_t record_ns;  // time spent recording (the backtraces and hashes)
static mach_timebase_info_data_t timebase;
static int ready;                    // set once the constructor has read the configuration of a recording process
static pthread_key_t state_key;      // per thread: STATE_BUSY (the probe's own work) or STATE_SELFTEST
static pthread_key_t outer_key;      // per thread: non-NULL inside a recorded XPC reply, SecItem, getpwuid or dlopen
static int run_loop_idle;            // the main run loop waits for its next event (main thread only)
typedef void *(*dlopen_from_t)(const char *, int, void *);
enum { STATE_NONE = 0, STATE_BUSY = 1, STATE_SELFTEST = 2 };
static int watch_main = 1;           // the main thread is watched
static char thread_list[512] = "main";  // the watched threads as given (the dump header)
static char pattern_store[512];
static const char *patterns[MAX_PATTERNS];
static int pattern_count;
static const char main_thread[] = "main", probe_thread[] = "probe";
// The launch window: the mark's name and the descriptor its line is written to (-1: no window).
static char window_mark[128];
static size_t window_mark_length;
static int window_fd = -1;
static int window_fd_ours;  // the probe opened window_fd: without the probe the app would make no call on it
enum { WINDOW_OPEN = 0, WINDOW_COPYING = 1, WINDOW_CLOSED = 2 };
static int window_state = WINDOW_OPEN;
static uint64_t window_ms;  // the probe's uptime when the mark arrived
static int window_written;  // the dump thread (or the exit path) wrote <out>.window
static char out_pattern[1024];       // CMUX_BLOCKING_PROBE_OUT, copied at load
static uint64_t loaded_ns;
static const void *probe_base;       // the probe's own image, left out of the reported stacks
static char child_program[256];      // CMUX_BLOCKING_PROBE_CHILD's program name, empty when unset
static char carried_env[CARRIED][1200];  // the NAME=value entries a child_program spawn gets
static const char *const carried_names[CARRIED] = {
    "DYLD_INSERT_LIBRARIES=", "CMUX_BLOCKING_PROBE_OUT=", "CMUX_PROBE_THREADS=", "CMUX_BLOCKING_PROBE_ARG=",
};

static inline uint64_t now_ns(void) {
    return mach_absolute_time() * timebase.numer / timebase.denom;
}

static inline uintptr_t thread_state(void) { return (uintptr_t)pthread_getspecific(state_key); }
static inline void set_thread_state(uintptr_t state) { pthread_setspecific(state_key, (const void *)state); }

// The watched thread the current call runs on ("main", "probe" or a pattern), or NULL when it is not recorded.
static const char *recording_thread(void) {
    if (!__atomic_load_n(&ready, __ATOMIC_ACQUIRE)) return NULL;
    uintptr_t state = thread_state();
    if (state == STATE_BUSY) return NULL;
    int main = pthread_main_np();
    if (state == STATE_SELFTEST) return main ? main_thread : probe_thread;
    if (main) return watch_main ? main_thread : NULL;
    if (pattern_count == 0) return NULL;
    char name[64];
    if (pthread_getname_np(pthread_self(), name, sizeof name) != 0 || name[0] == 0) return NULL;
    for (int i = 0; i < pattern_count; i++) {
        if (probe_name_matches(patterns[i], name)) return patterns[i];
    }
    return NULL;
}

// A call that may be a wait for the next input: `waiting` on a watched worker thread when fd < 0 (the call always
// waits for input there) or fd is not a regular file, else `blocking` (always on the main thread). The probe's own
// fstat is not interposed (dyld interposes calls from other images only).
static const char *input_kind(const char *thread, int fd, const char *blocking, const char *waiting) {
    if (thread == main_thread || thread == probe_thread) return blocking;
    if (fd < 0) return waiting;
    struct stat info;
    return fstat(fd, &info) == 0 && S_ISREG(info.st_mode) ? blocking : waiting;
}

static void record_entry(const char *kind, const char *thread, uint64_t ns) {
    void *stack[DEPTH];
    int depth = backtrace(stack, DEPTH);
    uint64_t key = (1469598103934665603ull ^ (uint64_t)(uintptr_t)kind) * 1099511628211ull;
    key = (key ^ (uint64_t)(uintptr_t)thread) * 1099511628211ull;
    for (int f = 0; f < depth && f < STACK_KEY; f++) key = (key ^ (uint64_t)(uintptr_t)stack[f]) * 1099511628211ull;
    size_t slot = (size_t)(key % SLOTS);
    for (size_t probe = 0; probe < MAX_PROBES; probe++, slot = (slot + 1) % SLOTS) {
        Entry *e = &table[slot];
        const char *seen = __atomic_load_n(&e->kind, __ATOMIC_ACQUIRE);
        if (seen == NULL) {
            const char *expected = NULL;
            if (__atomic_compare_exchange_n(&e->kind, &expected, claiming, 0, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE)) {
                e->key = key;
                e->thread = thread;
                e->depth = depth;
                memcpy(e->stack, stack, sizeof(void *) * (size_t)depth);
                e->count = 1;
                e->total_ns = ns;
                e->max_ns = ns;
                __atomic_store_n(&e->kind, kind, __ATOMIC_RELEASE);
                return;
            }
            seen = expected;  // another thread claimed it first
        }
        if (seen == claiming || seen != kind || e->key != key || e->thread != thread) continue;
        __atomic_fetch_add(&e->count, 1, __ATOMIC_RELAXED);
        __atomic_fetch_add(&e->total_ns, ns, __ATOMIC_RELAXED);
        uint64_t longest = __atomic_load_n(&e->max_ns, __ATOMIC_RELAXED);
        while (ns > longest) {
            if (__atomic_compare_exchange_n(&e->max_ns, &longest, ns, 1, __ATOMIC_RELAXED, __ATOMIC_RELAXED)) {
                memcpy(e->stack, stack, sizeof(void *) * (size_t)depth);
                __atomic_store_n(&e->depth, depth, __ATOMIC_RELAXED);
                break;
            }
        }
        return;
    }
    __atomic_fetch_add(&dropped, 1, __ATOMIC_RELAXED);
}

static void record(const char *kind, const char *thread, uint64_t ns) {
    uintptr_t state = thread_state();
    if (state == STATE_SELFTEST) kind = "selftest";
    set_thread_state(STATE_BUSY);
    uint64_t start = now_ns();
    record_entry(kind, thread, ns);
    __atomic_fetch_add(&record_ns, now_ns() - start, __ATOMIC_RELAXED);
    set_thread_state(state);
}

#define TIMED(kind, floor, call)                                                                   \
    do {                                                                                          \
        const char *thread_ = recording_thread();                                                 \
        if (thread_ == NULL) return call;                                                         \
        uint64_t start_ = now_ns();                                                               \
        __typeof__(call) result_ = call;                                                          \
        int errno_ = errno;                                                                       \
        uint64_t ns_ = now_ns() - start_;                                                         \
        __atomic_fetch_add(&calls, 1, __ATOMIC_RELAXED);                                          \
        if (ns_ >= (uint64_t)(floor)) record(kind, thread_, ns_);                                 \
        errno = errno_;                                                                           \
        return result_;                                                                           \
    } while (0)

#define TIMED_VOID(kind, floor, call)                                                              \
    do {                                                                                          \
        const char *thread_ = recording_thread();                                                 \
        if (thread_ == NULL) { call; return; }                                                    \
        uint64_t start_ = now_ns();                                                               \
        call;                                                                                     \
        int errno_ = errno;                                                                       \
        uint64_t ns_ = now_ns() - start_;                                                         \
        __atomic_fetch_add(&calls, 1, __ATOMIC_RELAXED);                                          \
        if (ns_ >= (uint64_t)(floor)) record(kind, thread_, ns_);                                 \
        errno = errno_;                                                                           \
    } while (0)

// TIMED with the kind input_kind gives; fd < 0 for a call that always waits for input on a worker thread.
#define TIMED_INPUT(blocking, waiting, fd, call)                                                   \
    do {                                                                                          \
        const char *thread_ = recording_thread();                                                 \
        if (thread_ == NULL) return call;                                                         \
        const char *kind_ = input_kind(thread_, (fd), (blocking), (waiting));                     \
        uint64_t start_ = now_ns();                                                               \
        __typeof__(call) result_ = call;                                                          \
        int errno_ = errno;                                                                       \
        uint64_t ns_ = now_ns() - start_;                                                         \
        __atomic_fetch_add(&calls, 1, __ATOMIC_RELAXED);                                          \
        record(kind_, thread_, ns_);                                                              \
        errno = errno_;                                                                           \
        return result_;                                                                           \
    } while (0)

// The optional third argument of open/openat/fcntl: read it only when the call takes one, then pass it on.
#define MODE_ARG(flags) ({ mode_t m_ = 0; if ((flags) & O_CREAT) { va_list ap; va_start(ap, flags); m_ = (mode_t)va_arg(ap, int); va_end(ap); } m_; })

// File system
static int p_open(const char *path, int flags, ...) { mode_t m = MODE_ARG(flags); TIMED("file-io:open", 0, open(path, flags, m)); }
static int p_open_nc(const char *path, int flags, ...) { mode_t m = MODE_ARG(flags); TIMED("file-io:open", 0, open_nocancel(path, flags, m)); }
static int p_openat(int fd, const char *path, int flags, ...) { mode_t m = MODE_ARG(flags); TIMED("file-io:openat", 0, openat(fd, path, flags, m)); }
static int p_openat_nc(int fd, const char *path, int flags, ...) { mode_t m = MODE_ARG(flags); TIMED("file-io:openat", 0, openat_nocancel(fd, path, flags, m)); }
static ssize_t p_read(int fd, void *b, size_t n) { TIMED_INPUT("io:read", "input-wait:read", fd, read(fd, b, n)); }
static ssize_t p_read_nc(int fd, void *b, size_t n) {
    TIMED_INPUT("io:read", "input-wait:read", fd, read_nocancel(fd, b, n));
}
static ssize_t p_pread(int fd, void *b, size_t n, off_t o) { TIMED("file-io:pread", 0, pread(fd, b, n, o)); }
static ssize_t p_pread_nc(int fd, void *b, size_t n, off_t o) { TIMED("file-io:pread", 0, pread_nocancel(fd, b, n, o)); }
static void window_check(int fd, const void *b, size_t n);
// The probe's own mark descriptor: its writes and fcntls happen only because the probe set
// CMUX_NEXT_LAUNCH_MARKS_FD (a normal launch has no LaunchMarkSink), so they are never recorded.
static inline int probe_own_fd(int fd) { return window_fd_ours && fd == window_fd; }
static ssize_t p_write(int fd, const void *b, size_t n) {
    window_check(fd, b, n);
    if (probe_own_fd(fd)) return write(fd, b, n);
    TIMED("io:write", 0, write(fd, b, n));
}
static ssize_t p_write_nc(int fd, const void *b, size_t n) {
    window_check(fd, b, n);
    if (probe_own_fd(fd)) return write_nocancel(fd, b, n);
    TIMED("io:write", 0, write_nocancel(fd, b, n));
}
static ssize_t p_pwrite(int fd, const void *b, size_t n, off_t o) { TIMED("file-io:pwrite", 0, pwrite(fd, b, n, o)); }
static int p_stat(const char *p, struct stat *s) { TIMED("file-io:stat", 0, stat(p, s)); }
static int p_lstat(const char *p, struct stat *s) { TIMED("file-io:lstat", 0, lstat(p, s)); }
static int p_fstatat(int fd, const char *p, struct stat *s, int f) { TIMED("file-io:fstatat", 0, fstatat(fd, p, s, f)); }
static int p_statfs(const char *p, struct statfs *s) { TIMED("file-io:statfs", 0, statfs(p, s)); }
static int p_access(const char *p, int m) { TIMED("file-io:access", 0, access(p, m)); }
static int p_getattrlist(const char *p, void *a, void *b, size_t n, unsigned int o) {
    TIMED("file-io:getattrlist", 0, getattrlist(p, a, b, n, o));
}
static int p_getattrlistbulk(int fd, void *a, void *b, size_t n, uint64_t o) {
    TIMED("file-io:getattrlistbulk", 0, getattrlistbulk(fd, a, b, n, o));
}
static int p_fsync(int fd) { TIMED("file-io:fsync", 0, fsync(fd)); }
static int p_fsync_nc(int fd) { TIMED("file-io:fsync", 0, fsync_nocancel(fd)); }
static int p_fstat(int fd, struct stat *s) { TIMED("file-io:fstat", 0, fstat(fd, s)); }
static int p_unlinkat(int fd, const char *p, int f) { TIMED("file-io:unlinkat", 0, unlinkat(fd, p, f)); }
static int p_renameat(int a, const char *b, int c, const char *d) { TIMED("file-io:renameat", 0, renameat(a, b, c, d)); }
static int p_mkdirat(int fd, const char *p, mode_t m) { TIMED("file-io:mkdirat", 0, mkdirat(fd, p, m)); }
// fcntl's optional third argument is an int or a pointer. Each variadic argument fills one 8-byte slot on both
// Darwin ABIs (arm64: the stack; x86_64: a register or the stack), so reading the slot as a pointer and passing
// it on gives fcntl the same slot, which it reads back as an int or a pointer for its command.
static int p_fcntl(int fd, int cmd, ...) {
    va_list ap; va_start(ap, cmd); void *arg = va_arg(ap, void *); va_end(ap);
    if (probe_own_fd(fd)) return fcntl(fd, cmd, arg);
    TIMED("file-io:fcntl", 0, fcntl(fd, cmd, arg));
}
static int p_fcntl_nc(int fd, int cmd, ...) {
    va_list ap; va_start(ap, cmd); void *arg = va_arg(ap, void *); va_end(ap);
    if (probe_own_fd(fd)) return fcntl_nocancel(fd, cmd, arg);
    TIMED("file-io:fcntl", 0, fcntl_nocancel(fd, cmd, arg));
}
static int p_flock(int fd, int op) { TIMED("file-io:flock", 0, flock(fd, op)); }
static int p_mkdir(const char *p, mode_t m) { TIMED("file-io:mkdir", 0, mkdir(p, m)); }
static int p_unlink(const char *p) { TIMED("file-io:unlink", 0, unlink(p)); }
static int p_rename(const char *a, const char *b) { TIMED("file-io:rename", 0, rename(a, b)); }
static ssize_t p_readlink(const char *p, char *b, size_t n) { TIMED("file-io:readlink", 0, readlink(p, b, n)); }
static int p_close(int fd) { TIMED("io:close", WAIT_FLOOR_NS, close(fd)); }
// Sockets, polling and processes
static ssize_t p_recv(int s, void *b, size_t n, int f) {
    TIMED_INPUT("socket-read:recv", "input-wait:recv", -1, recv(s, b, n, f));
}
static ssize_t p_recvfrom(int s, void *b, size_t n, int f, struct sockaddr *a, socklen_t *l) {
    TIMED_INPUT("socket-read:recvfrom", "input-wait:recvfrom", -1, recvfrom(s, b, n, f, a, l));
}
static ssize_t p_recvfrom_nc(int s, void *b, size_t n, int f, struct sockaddr *a, socklen_t *l) {
    TIMED_INPUT("socket-read:recvfrom", "input-wait:recvfrom", -1, recvfrom_nocancel(s, b, n, f, a, l));
}
static ssize_t p_recvmsg(int s, struct msghdr *m, int f) {
    TIMED_INPUT("socket-read:recvmsg", "input-wait:recvmsg", -1, recvmsg(s, m, f));
}
static ssize_t p_send(int s, const void *b, size_t n, int f) { TIMED("socket-write:send", 0, send(s, b, n, f)); }
static ssize_t p_sendto(int s, const void *b, size_t n, int f, const struct sockaddr *a, socklen_t l) {
    TIMED("socket-write:sendto", 0, sendto(s, b, n, f, a, l));
}
static ssize_t p_sendto_nc(int s, const void *b, size_t n, int f, const struct sockaddr *a, socklen_t l) {
    TIMED("socket-write:sendto", 0, sendto_nocancel(s, b, n, f, a, l));
}
static ssize_t p_sendmsg(int s, const struct msghdr *m, int f) { TIMED("socket-write:sendmsg", 0, sendmsg(s, m, f)); }
static int p_connect(int s, const struct sockaddr *a, socklen_t l) { TIMED("socket:connect", 0, connect(s, a, l)); }
static int p_select(int n, fd_set *r, fd_set *w, fd_set *e, struct timeval *t) {
    TIMED_INPUT("socket:select", "input-wait:select", -1, select(n, r, w, e, t));
}
static int p_poll(struct pollfd *f, nfds_t n, int t) { TIMED_INPUT("socket:poll", "input-wait:poll", -1, poll(f, n, t)); }
static int p_poll_nc(struct pollfd *f, nfds_t n, int t) {
    TIMED_INPUT("socket:poll", "input-wait:poll", -1, poll_nocancel(f, n, t));
}
static int p_getaddrinfo(const char *h, const char *s, const struct addrinfo *i, struct addrinfo **r) {
    TIMED("socket:getaddrinfo", 0, getaddrinfo(h, s, i, r));
}
static pid_t p_waitpid(pid_t p, int *s, int o) {
    TIMED_INPUT("process-wait:waitpid", "input-wait:waitpid", -1, waitpid(p, s, o));
}
static pid_t p_wait4(pid_t p, int *s, int o, struct rusage *r) {
    TIMED_INPUT("process-wait:wait4", "input-wait:wait4", -1, wait4(p, s, o, r));
}
// A CMUX_BLOCKING_PROBE_CHILD spawn: the caller's environment without the probe's own names, then the carried
// entries. NULL (spawn with envp unchanged) for any other program.
static int carried_name(const char *entry) {
    for (int c = 0; c < CARRIED; c++) {
        if (strncmp(entry, carried_names[c], strlen(carried_names[c])) == 0) return 1;
    }
    return 0;
}
static char **carry_env(const char *path, char *const envp[]) {
    if (child_program[0] == 0 || path == NULL) return NULL;
    const char *name = strrchr(path, '/');
    if (strcmp(name != NULL ? name + 1 : path, child_program) != 0) return NULL;
    size_t n = 0;
    while (envp != NULL && envp[n] != NULL) n++;
    char **env = malloc(sizeof(char *) * (n + CARRIED + 1));
    if (env == NULL) return NULL;
    size_t k = 0;
    for (size_t i = 0; i < n; i++) {
        if (!carried_name(envp[i])) env[k++] = envp[i];
    }
    for (int c = 0; c < CARRIED; c++) env[k++] = carried_env[c];
    env[k] = NULL;
    return env;
}
static int spawn(int search, pid_t *pid, const char *path, const posix_spawn_file_actions_t *actions,
                 const posix_spawnattr_t *attr, char *const argv[], char *const envp[]) {
    char **carried = carry_env(path, envp);
    char *const *env = carried != NULL ? carried : envp;
    const char *thread = recording_thread();
    uint64_t start = thread != NULL ? now_ns() : 0;
    int result = search ? posix_spawnp(pid, path, actions, attr, argv, env) : posix_spawn(pid, path, actions, attr, argv, env);
    int saved = errno;
    if (thread != NULL) {
        uint64_t ns = now_ns() - start;
        __atomic_fetch_add(&calls, 1, __ATOMIC_RELAXED);
        record(search ? "process-spawn:posix_spawnp" : "process-spawn:posix_spawn", thread, ns);
    }
    free(carried);
    errno = saved;
    return result;
}
static int p_posix_spawn(pid_t *pid, const char *path, const posix_spawn_file_actions_t *actions,
                         const posix_spawnattr_t *attr, char *const argv[], char *const envp[]) {
    return spawn(0, pid, path, actions, attr, argv, envp);
}
static int p_posix_spawnp(pid_t *pid, const char *file, const posix_spawn_file_actions_t *actions,
                          const posix_spawnattr_t *attr, char *const argv[], char *const envp[]) {
    return spawn(1, pid, file, actions, attr, argv, envp);
}
static pid_t p_fork(void) {
    const char *thread = recording_thread();
    if (thread == NULL) return fork();
    uint64_t start = now_ns();
    pid_t pid = fork();
    int saved = errno;
    if (pid != 0) {  // the parent, or a failed fork: the child records nothing of its own start
        uint64_t ns = now_ns() - start;
        __atomic_fetch_add(&calls, 1, __ATOMIC_RELAXED);
        record("process-spawn:fork", thread, ns);
    }
    errno = saved;
    return pid;
}
// Cross-process calls and the loader
static inline int inside_outer(void) { return pthread_getspecific(outer_key) != NULL; }
// TIMED for a call that is one entry with its whole time: the XPC replies and mach receives it makes inside are
// not recorded again. Inside another such call it is not recorded either.
#define TIMED_OUTER(kind, call)                                                                    \
    do {                                                                                          \
        const char *thread_ = recording_thread();                                                 \
        if (thread_ == NULL || inside_outer()) return call;                                       \
        pthread_setspecific(outer_key, (const void *)1);                                          \
        uint64_t start_ = now_ns();                                                               \
        __typeof__(call) result_ = call;                                                          \
        int errno_ = errno;                                                                       \
        uint64_t ns_ = now_ns() - start_;                                                         \
        pthread_setspecific(outer_key, NULL);                                                     \
        __atomic_fetch_add(&calls, 1, __ATOMIC_RELAXED);                                          \
        record(kind, thread_, ns_);                                                               \
        errno = errno_;                                                                           \
        return result_;                                                                           \
    } while (0)

// A mach receive past WAIT_FLOOR_NS, of the kind probe_mach_kind gives; none for a send only, the main run loop's
// idle wait or a receive inside an outer call.
#define TIMED_MACH(receive, input_wait, options, call)                                             \
    do {                                                                                          \
        const char *thread_ = recording_thread();                                                 \
        if (thread_ == NULL || inside_outer()) return call;                                       \
        int main_ = thread_ == main_thread;                                                       \
        const char *kind_ = probe_mach_kind((options), main_ || thread_ == probe_thread,          \
                                            main_ && run_loop_idle, (receive), (input_wait));     \
        if (kind_ == NULL) return call;                                                           \
        uint64_t start_ = now_ns();                                                               \
        mach_msg_return_t result_ = call;                                                         \
        int errno_ = errno;                                                                       \
        uint64_t ns_ = now_ns() - start_;                                                         \
        __atomic_fetch_add(&calls, 1, __ATOMIC_RELAXED);                                          \
        if (ns_ >= WAIT_FLOOR_NS) record(kind_, thread_, ns_);                                    \
        errno = errno_;                                                                           \
        return result_;                                                                           \
    } while (0)

static xpc_object_t p_xpc_reply_sync(xpc_connection_t connection, xpc_object_t message) {
    TIMED_OUTER("xpc-reply:xpc_connection_send_message_with_reply_sync",
                xpc_connection_send_message_with_reply_sync(connection, message));
}
static mach_msg_return_t p_mach_msg(mach_msg_header_t *m, mach_msg_option_t o, mach_msg_size_t send,
                                    mach_msg_size_t receive, mach_port_name_t name, mach_msg_timeout_t t,
                                    mach_port_name_t notify) {
    TIMED_MACH("mach-receive:mach_msg", "input-wait:mach_msg", (uint64_t)o,
               mach_msg(m, o, send, receive, name, t, notify));
}
#ifndef PROBE_NO_MACH_MSG2
static mach_msg_return_t p_mach_msg2(void *data, uint64_t o, uint64_t a, uint64_t b, uint64_t c, uint64_t d,
                                     uint64_t e, uint64_t t) {
    TIMED_MACH("mach-receive:mach_msg2", "input-wait:mach_msg2", o,
               probe_mach_msg2_internal(data, o, a, b, c, d, e, t));
}
#endif
// dyld's dlopen_from(path, mode, address in the caller), looked up at the first dlopen of any process that loads
// the probe (an inert one too, and before the constructor runs), so every dlopen resolves from its caller.
static dlopen_from_t dlopen_from_resolved(void) {
    static dlopen_from_t resolved;
    static int looked_up;
    if (__atomic_load_n(&looked_up, __ATOMIC_ACQUIRE)) return __atomic_load_n(&resolved, __ATOMIC_RELAXED);
    int errno_ = errno;
    dlopen_from_t found = (dlopen_from_t)dlsym(RTLD_DEFAULT, "dlopen_from");
    errno = errno_;
    __atomic_store_n(&resolved, found, __ATOMIC_RELAXED);
    if (__atomic_exchange_n(&looked_up, 1, __ATOMIC_ACQ_REL) == 0 && found == NULL) {
        fprintf(stderr, "blocking-probe: pid %d: this dyld has no dlopen_from, so a dlopen of an @rpath, "
                        "@loader_path or relative name resolves from the probe, not its caller\n", getpid());
    }
    return found;
}
static void *dlopen_from_caller(const char *path, int mode, void *caller) {
    dlopen_from_t from = dlopen_from_resolved();
    return from != NULL ? from(path, mode, caller) : dlopen(path, mode);
}
static void *p_dlopen(const char *path, int mode) {
    void *caller = __builtin_return_address(0);
    TIMED_OUTER("library-load:dlopen", dlopen_from_caller(path, mode, caller));
}
static struct passwd *p_getpwuid(uid_t uid) { TIMED_OUTER("system-query:getpwuid", getpwuid(uid)); }
static int p_getpwuid_r(uid_t uid, struct passwd *pw, char *buffer, size_t size, struct passwd **result) {
    TIMED_OUTER("system-query:getpwuid_r", getpwuid_r(uid, pw, buffer, size, result));
}
static OSStatus p_SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    TIMED_OUTER("system-call:SecItemCopyMatching", SecItemCopyMatching(query, result));
}
static OSStatus p_SecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
    TIMED_OUTER("system-call:SecItemAdd", SecItemAdd(attributes, result));
}
// Waits
static long p_dispatch_semaphore_wait(dispatch_semaphore_t s, dispatch_time_t t) {
    TIMED("sync-wait:dispatch_semaphore_wait", WAIT_FLOOR_NS, dispatch_semaphore_wait(s, t));
}
static long p_dispatch_group_wait(dispatch_group_t g, dispatch_time_t t) {
    TIMED("sync-wait:dispatch_group_wait", WAIT_FLOOR_NS, dispatch_group_wait(g, t));
}
static void p_dispatch_sync(dispatch_queue_t q, dispatch_block_t b) {
    TIMED_VOID("sync-wait:dispatch_sync (includes the block)", WAIT_FLOOR_NS, dispatch_sync(q, b));
}
static void p_dispatch_sync_f(dispatch_queue_t q, void *c, dispatch_function_t f) {
    TIMED_VOID("sync-wait:dispatch_sync_f (includes the block)", WAIT_FLOOR_NS, dispatch_sync_f(q, c, f));
}
static int p_pthread_cond_wait(pthread_cond_t *c, pthread_mutex_t *m) {
    TIMED("sync-wait:pthread_cond_wait", WAIT_FLOOR_NS, pthread_cond_wait(c, m));
}
static int p_pthread_cond_timedwait(pthread_cond_t *c, pthread_mutex_t *m, const struct timespec *t) {
    TIMED("sync-wait:pthread_cond_timedwait", WAIT_FLOOR_NS, pthread_cond_timedwait(c, m, t));
}
static int p_pthread_mutex_lock(pthread_mutex_t *m) { TIMED("lock-wait:pthread_mutex_lock", WAIT_FLOOR_NS, pthread_mutex_lock(m)); }
static void p_os_unfair_lock_lock(os_unfair_lock_t l) { TIMED_VOID("lock-wait:os_unfair_lock", WAIT_FLOOR_NS, os_unfair_lock_lock(l)); }
static int p_usleep(useconds_t u) { TIMED("sleep:usleep", 0, usleep(u)); }
static int p_nanosleep(const struct timespec *a, struct timespec *b) { TIMED("sleep:nanosleep", 0, nanosleep(a, b)); }

DYLD_INTERPOSE(p_open, open)
DYLD_INTERPOSE(p_open_nc, open_nocancel)
DYLD_INTERPOSE(p_openat, openat)
DYLD_INTERPOSE(p_openat_nc, openat_nocancel)
DYLD_INTERPOSE(p_read, read)
DYLD_INTERPOSE(p_read_nc, read_nocancel)
DYLD_INTERPOSE(p_pread, pread)
DYLD_INTERPOSE(p_pread_nc, pread_nocancel)
DYLD_INTERPOSE(p_write, write)
DYLD_INTERPOSE(p_write_nc, write_nocancel)
DYLD_INTERPOSE(p_pwrite, pwrite)
DYLD_INTERPOSE(p_stat, stat)
DYLD_INTERPOSE(p_lstat, lstat)
DYLD_INTERPOSE(p_fstatat, fstatat)
DYLD_INTERPOSE(p_statfs, statfs)
DYLD_INTERPOSE(p_access, access)
DYLD_INTERPOSE(p_getattrlist, getattrlist)
DYLD_INTERPOSE(p_getattrlistbulk, getattrlistbulk)
DYLD_INTERPOSE(p_fsync, fsync)
DYLD_INTERPOSE(p_fsync_nc, fsync_nocancel)
DYLD_INTERPOSE(p_fstat, fstat)
DYLD_INTERPOSE(p_unlinkat, unlinkat)
DYLD_INTERPOSE(p_renameat, renameat)
DYLD_INTERPOSE(p_mkdirat, mkdirat)
DYLD_INTERPOSE(p_fcntl, fcntl)
DYLD_INTERPOSE(p_fcntl_nc, fcntl_nocancel)
DYLD_INTERPOSE(p_flock, flock)
DYLD_INTERPOSE(p_mkdir, mkdir)
DYLD_INTERPOSE(p_unlink, unlink)
DYLD_INTERPOSE(p_rename, rename)
DYLD_INTERPOSE(p_readlink, readlink)
DYLD_INTERPOSE(p_close, close)
DYLD_INTERPOSE(p_recv, recv)
DYLD_INTERPOSE(p_recvfrom, recvfrom)
DYLD_INTERPOSE(p_recvfrom_nc, recvfrom_nocancel)
DYLD_INTERPOSE(p_recvmsg, recvmsg)
DYLD_INTERPOSE(p_send, send)
DYLD_INTERPOSE(p_sendto, sendto)
DYLD_INTERPOSE(p_sendto_nc, sendto_nocancel)
DYLD_INTERPOSE(p_sendmsg, sendmsg)
DYLD_INTERPOSE(p_connect, connect)
DYLD_INTERPOSE(p_select, select)
DYLD_INTERPOSE(p_poll, poll)
DYLD_INTERPOSE(p_poll_nc, poll_nocancel)
DYLD_INTERPOSE(p_getaddrinfo, getaddrinfo)
DYLD_INTERPOSE(p_waitpid, waitpid)
DYLD_INTERPOSE(p_wait4, wait4)
DYLD_INTERPOSE(p_posix_spawn, posix_spawn)
DYLD_INTERPOSE(p_posix_spawnp, posix_spawnp)
DYLD_INTERPOSE(p_fork, fork)
DYLD_INTERPOSE(p_xpc_reply_sync, xpc_connection_send_message_with_reply_sync)
DYLD_INTERPOSE(p_mach_msg, mach_msg)
#ifndef PROBE_NO_MACH_MSG2
DYLD_INTERPOSE(p_mach_msg2, probe_mach_msg2_internal)
#endif
DYLD_INTERPOSE(p_dlopen, dlopen)
DYLD_INTERPOSE(p_getpwuid, getpwuid)
DYLD_INTERPOSE(p_getpwuid_r, getpwuid_r)
DYLD_INTERPOSE(p_SecItemCopyMatching, SecItemCopyMatching)
DYLD_INTERPOSE(p_SecItemAdd, SecItemAdd)
DYLD_INTERPOSE(p_dispatch_semaphore_wait, dispatch_semaphore_wait)
DYLD_INTERPOSE(p_dispatch_group_wait, dispatch_group_wait)
DYLD_INTERPOSE(p_dispatch_sync, dispatch_sync)
DYLD_INTERPOSE(p_dispatch_sync_f, dispatch_sync_f)
DYLD_INTERPOSE(p_pthread_cond_wait, pthread_cond_wait)
DYLD_INTERPOSE(p_pthread_cond_timedwait, pthread_cond_timedwait)
DYLD_INTERPOSE(p_pthread_mutex_lock, pthread_mutex_lock)
DYLD_INTERPOSE(p_os_unfair_lock_lock, os_unfair_lock_lock)
DYLD_INTERPOSE(p_usleep, usleep)
DYLD_INTERPOSE(p_nanosleep, nanosleep)


// One frame per stack address, image|offset|symbol, the probe's own frames left out; then the line's end.
static void write_frames(FILE *out, void *const *stack, int depth) {
    for (int f = 0; f < depth; f++) {
        Dl_info info;
        if (dladdr(stack[f], &info) && info.dli_fname) {
            if (info.dli_fbase == probe_base) continue;
            const char *image = strrchr(info.dli_fname, '/');
            fprintf(out, "%s|0x%lx|%s;", image ? image + 1 : info.dli_fname,
                    (unsigned long)((uintptr_t)stack[f] - (uintptr_t)info.dli_fbase),
                    info.dli_sname ? info.dli_sname : "?");
        } else {
            fprintf(out, "?|%p|?;", stack[f]);
        }
    }
    fputc('\n', out);
}

// Writes the table: a header, then one line per entry: kind thread count total_ns max_ns frames, each frame
// image|offset|symbol (the probe's own frames left out). `window` writes the launch window's copy instead, to
// <path>.window. Written to a temporary file, then renamed, so a reader never sees half a dump. The writing
// thread is marked busy, so the interposers never record its I/O.
static void dump_table(int final, int window) {
    if (out_pattern[0] == 0) return;
    char path[1100], partial[1200];
    const char *suffix = window ? ".window" : "";
    const char *pid = strstr(out_pattern, "%p");
    if (pid) {
        snprintf(path, sizeof path, "%.*s%d%s%s", (int)(pid - out_pattern), out_pattern, getpid(), pid + 2, suffix);
    } else {
        snprintf(path, sizeof path, "%s%s", out_pattern, suffix);
    }
    snprintf(partial, sizeof partial, "%s.%s.partial", path, window ? "window" : final ? "final" : "periodic");
    uintptr_t state = thread_state();
    set_thread_state(STATE_BUSY);
    FILE *out = fopen(partial, "w");
    if (out != NULL) {
        const char *program = getprogname();
        if (window) {
            fprintf(out, "#window\t%s\n#window_ms\t%llu\n#threads\tmain\n#process\t%s\n", window_mark,
                    (unsigned long long)window_ms, program != NULL ? program : "?");
        } else {
            fprintf(out, "#final\t%d\n#threads\t%s\n#process\t%s\n#uptime_ms\t%llu\n#dropped\t%llu\n#calls\t%llu\n#record_ns\t%llu\n",
                    final, thread_list, program != NULL ? program : "?",
                    (unsigned long long)((now_ns() - loaded_ns) / 1000000),
                    (unsigned long long)__atomic_load_n(&dropped, __ATOMIC_RELAXED),
                    (unsigned long long)__atomic_load_n(&calls, __ATOMIC_RELAXED),
                    (unsigned long long)__atomic_load_n(&record_ns, __ATOMIC_RELAXED));
        }
        for (size_t i = 0; i < SLOTS; i++) {
            Entry *e = &table[i];
            const char *kind = __atomic_load_n(&e->kind, __ATOMIC_ACQUIRE);
            if (kind == NULL || kind == claiming) continue;
            if (window) {
                if (e->window_count == 0) continue;
                fprintf(out, "%s\t%s\t%llu\t%llu\t%llu\t", kind, e->thread, (unsigned long long)e->window_count,
                        (unsigned long long)e->window_total_ns, (unsigned long long)e->window_max_ns);
                write_frames(out, e->window_stack, e->window_depth);
                continue;
            }
            int depth = __atomic_load_n(&e->depth, __ATOMIC_RELAXED);
            if (depth > DEPTH) depth = DEPTH;
            fprintf(out, "%s\t%s\t%llu\t%llu\t%llu\t", kind, e->thread,
                    (unsigned long long)__atomic_load_n(&e->count, __ATOMIC_RELAXED),
                    (unsigned long long)__atomic_load_n(&e->total_ns, __ATOMIC_RELAXED),
                    (unsigned long long)__atomic_load_n(&e->max_ns, __ATOMIC_RELAXED));
            write_frames(out, e->stack, depth);
        }
        if (fclose(out) == 0) rename(partial, path);
    }
    set_thread_state(state);
}

static void dump(int final) { dump_table(final, 0); }

// Proves the probe works in this process: on a watched thread, file system calls made from other images (libc,
// CoreFoundation, so dyld's interposing applies) must be recorded as kind "selftest", and the dump written right
// after must show it. scripts/measure/blocking-probe.sh fails the run when it does not.
static void run_selftest(void *unused) {
    (void)unused;
    uintptr_t state = thread_state();
    set_thread_state(STATE_SELFTEST);
    // Three ways into the kernel from other images (libc, CoreFoundation), so the check does not depend on
    // which internal entry point one of them uses on this macOS.
    DIR *dir = opendir("/");
    if (dir != NULL) closedir(dir);
    char resolved[PATH_MAX];
    (void)realpath("/tmp", resolved);
    CFURLRef url = CFURLCreateWithFileSystemPath(NULL, CFSTR("/"), kCFURLPOSIXPathStyle, true);
    if (url != NULL) {
        (void)CFURLResourceIsReachable(url, NULL);
        CFRelease(url);
    }
    set_thread_state(state);
    dump(0);  // at once, so the harness sees the self-test without waiting for the periodic dump
}

// The dump thread waits on a condition with a deadline (not a sleep), so the exit path can stop it at once.
static pthread_mutex_t dump_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t dump_wake = PTHREAD_COND_INITIALIZER;
static int dump_stop;
static pthread_t dump_thread;
static pid_t dump_thread_pid;  // a fork does not inherit the thread: only its creator joins it

// The launch window's copy is made and not yet written. Only the dump thread, or the exit path after joining
// it, writes the copy, so one writer at a time.
static int window_due(void) {
    return __atomic_load_n(&window_state, __ATOMIC_ACQUIRE) == WINDOW_CLOSED && !window_written;
}
static void dump_window(void) {
    dump_table(0, 1);
    window_written = 1;
}

// A write's bytes, on any thread: the launch mark's line on the mark descriptor copies the main thread's entries
// once (one pass over the table: no allocation, no I/O), then wakes the dump thread. A main-thread call that
// races a mark sent from another thread may or may not be in the copy.
static void window_check(int fd, const void *bytes, size_t n) {
    if (window_fd < 0 || fd != window_fd || __atomic_load_n(&window_state, __ATOMIC_ACQUIRE) != WINDOW_OPEN) return;
    if (bytes == NULL || n <= window_mark_length || memcmp(bytes, window_mark, window_mark_length) != 0
        || ((const char *)bytes)[window_mark_length] != ' ') {
        return;
    }
    int expected = WINDOW_OPEN;
    if (!__atomic_compare_exchange_n(&window_state, &expected, WINDOW_COPYING, 0, __ATOMIC_ACQ_REL,
                                     __ATOMIC_ACQUIRE)) {
        return;
    }
    uintptr_t state = thread_state();
    set_thread_state(STATE_BUSY);
    window_ms = (now_ns() - loaded_ns) / 1000000;
    for (size_t i = 0; i < SLOTS; i++) {
        Entry *e = &table[i];
        const char *kind = __atomic_load_n(&e->kind, __ATOMIC_ACQUIRE);
        if (kind == NULL || kind == claiming || e->thread != main_thread) continue;
        int depth = __atomic_load_n(&e->depth, __ATOMIC_RELAXED);
        if (depth > DEPTH) depth = DEPTH;
        e->window_total_ns = __atomic_load_n(&e->total_ns, __ATOMIC_RELAXED);
        e->window_max_ns = __atomic_load_n(&e->max_ns, __ATOMIC_RELAXED);
        e->window_depth = depth;
        memcpy(e->window_stack, e->stack, sizeof(void *) * (size_t)depth);
        e->window_count = __atomic_load_n(&e->count, __ATOMIC_RELAXED);
    }
    __atomic_store_n(&window_state, WINDOW_CLOSED, __ATOMIC_RELEASE);
    pthread_mutex_lock(&dump_lock);
    pthread_cond_signal(&dump_wake);
    pthread_mutex_unlock(&dump_lock);
    set_thread_state(state);
}

// `selftest_here` is non-NULL when the main thread is not watched: the self-test then runs on this thread.
static void *dump_loop(void *selftest_here) {
    pthread_setname_np("cmux blocking-probe dump");
    if (selftest_here != NULL) run_selftest(NULL);
    set_thread_state(STATE_BUSY);  // the probe's own thread is never recorded, whatever CMUX_PROBE_THREADS says
    pthread_mutex_lock(&dump_lock);
    while (!dump_stop) {
        struct timespec until;
        clock_gettime(CLOCK_REALTIME, &until);
        until.tv_sec += DUMP_SECONDS;
        while (!dump_stop && !window_due() && pthread_cond_timedwait(&dump_wake, &dump_lock, &until) != ETIMEDOUT) {}
        if (dump_stop) break;
        pthread_mutex_unlock(&dump_lock);
        if (window_due()) {
            dump_window();
        } else {
            dump(0);
        }
        pthread_mutex_lock(&dump_lock);
    }
    pthread_mutex_unlock(&dump_lock);
    return NULL;
}

// At exit: stop and join the dump thread, then write the final dump, so only one writer runs.
static void dump_at_exit(void) {
    uintptr_t state = thread_state();
    set_thread_state(STATE_BUSY);
    if (dump_thread_pid == getpid()) {
        pthread_mutex_lock(&dump_lock);
        dump_stop = 1;
        pthread_cond_signal(&dump_wake);
        pthread_mutex_unlock(&dump_lock);
        pthread_join(dump_thread, NULL);
        dump_thread_pid = 0;
    }
    set_thread_state(state);
    if (window_due()) dump_window();
    dump(1);
}

// CMUX_PROBE_THREADS: comma-separated thread-name patterns; "main" is the main thread.
static void parse_threads(const char *list) {
    snprintf(thread_list, sizeof thread_list, "%s", list);
    snprintf(pattern_store, sizeof pattern_store, "%s", list);
    watch_main = 0;
    char *cursor = pattern_store;
    while (cursor != NULL && pattern_count < MAX_PATTERNS) {
        char *comma = strchr(cursor, ',');
        if (comma != NULL) *comma = 0;
        if (strcmp(cursor, "main") == 0) {
            watch_main = 1;
        } else if (cursor[0] != 0) {
            patterns[pattern_count++] = cursor;
        }
        cursor = comma != NULL ? comma + 1 : NULL;
    }
}

// CMUX_BLOCKING_PROBE_CHILD=<program>:<args>:<patterns>: the entries a spawn of <program> gets.
static void parse_child(const char *spec, const char *dylib) {
    const char *first = strchr(spec, ':');
    const char *second = first != NULL ? strchr(first + 1, ':') : NULL;
    if (second == NULL || first == spec || (size_t)(first - spec) >= sizeof child_program || second[1] == 0) {
        fprintf(stderr, "blocking-probe: CMUX_BLOCKING_PROBE_CHILD is <program>:<args>:<thread patterns>; got %s\n", spec);
        return;
    }
    snprintf(child_program, sizeof child_program, "%.*s", (int)(first - spec), spec);
    snprintf(carried_env[0], sizeof carried_env[0], "%s%s", carried_names[0], dylib);
    snprintf(carried_env[1], sizeof carried_env[1], "%s%s", carried_names[1], out_pattern);
    snprintf(carried_env[2], sizeof carried_env[2], "%s%s", carried_names[2], second + 1);
    snprintf(carried_env[3], sizeof carried_env[3], "%s%.*s", carried_names[3], (int)(second - first - 1), first + 1);
}

// CMUX_BLOCKING_PROBE_UNTIL_MARK=<name>: watch the launcher's mark descriptor, or open /dev/null as one (close on
// exec, above 2 as LaunchMarkSink requires) and name it, so the app sends its marks where the probe sees them.
static void open_window(const char *mark) {
    if (strlen(mark) >= sizeof window_mark) {
        fprintf(stderr, "blocking-probe: CMUX_BLOCKING_PROBE_UNTIL_MARK is too long: %s\n", mark);
        return;
    }
    int ours = 0;
    const char *given = getenv("CMUX_NEXT_LAUNCH_MARKS_FD");
    char *end = NULL;
    long fd = given != NULL ? strtol(given, &end, 10) : -1;
    if (given == NULL || end == given || *end != 0 || fd <= 2 || fd > INT_MAX || fcntl((int)fd, F_GETFD) == -1) {
        int null = open("/dev/null", O_WRONLY | O_CLOEXEC);
        fd = null >= 0 ? fcntl(null, F_DUPFD_CLOEXEC, 3) : -1;
        if (null >= 0) close(null);
        if (fd < 0) {
            fprintf(stderr, "blocking-probe: no descriptor for the launch marks, so no launch window\n");
            return;
        }
        char text[24];
        snprintf(text, sizeof text, "%ld", fd);
        setenv("CMUX_NEXT_LAUNCH_MARKS_FD", text, 1);
        ours = 1;
    }
    snprintf(window_mark, sizeof window_mark, "%s", mark);
    window_mark_length = strlen(window_mark);
    window_fd = (int)fd;
    window_fd_ours = ours;
}

// The main run loop's wait for its next event: idle from the last BeforeWaiting observer (order LONG_MAX, after Core
// Animation's commit and every other one) to the first AfterWaiting one (order LONG_MIN), in the common modes, so a
// nested run loop in a private mode (a synchronous reply's) still records its receive.
static void run_loop_will_wait(CFRunLoopObserverRef observer, CFRunLoopActivity activity, void *info) {
    (void)observer; (void)activity; (void)info;
    run_loop_idle = 1;
}
static void run_loop_woke(CFRunLoopObserverRef observer, CFRunLoopActivity activity, void *info) {
    (void)observer; (void)activity; (void)info;
    run_loop_idle = 0;
}
static void observe_main_run_loop(void) {
    CFRunLoopObserverRef last = CFRunLoopObserverCreate(NULL, kCFRunLoopBeforeWaiting, true, LONG_MAX,
                                                        run_loop_will_wait, NULL);
    CFRunLoopObserverRef first = CFRunLoopObserverCreate(NULL, kCFRunLoopAfterWaiting | kCFRunLoopExit, true, LONG_MIN,
                                                         run_loop_woke, NULL);
    if (last != NULL && first != NULL) {
        CFRunLoopAddObserver(CFRunLoopGetMain(), last, kCFRunLoopCommonModes);
        CFRunLoopAddObserver(CFRunLoopGetMain(), first, kCFRunLoopCommonModes);
    }
    if (last != NULL) CFRelease(last);
    if (first != NULL) CFRelease(first);
}

// dyld calls an image's initializers with the process's argc and argv.
__attribute__((constructor)) static void start(int argc, const char **argv) {
    mach_timebase_info(&timebase);
    loaded_ns = now_ns();
    if (pthread_key_create(&state_key, NULL) != 0 || pthread_key_create(&outer_key, NULL) != 0) return;
    const char *only = getenv("CMUX_BLOCKING_PROBE_ARG");
    // Inert unless argv holds every wanted argument: the variables stay in the environment for its children.
    if (only != NULL && only[0] != 0 && !probe_argv_holds_all(argc, argv, only)) return;
    Dl_info self;
    memset(&self, 0, sizeof self);
    if (dladdr((const void *)&start, &self)) probe_base = self.dli_fbase;
    const char *out = getenv("CMUX_BLOCKING_PROBE_OUT");
    if (out != NULL) snprintf(out_pattern, sizeof out_pattern, "%s", out);
    const char *threads = getenv("CMUX_PROBE_THREADS");
    if (threads != NULL && threads[0] != 0) parse_threads(threads);
    const char *child = getenv("CMUX_BLOCKING_PROBE_CHILD");
    if (child != NULL && child[0] != 0 && self.dli_fname != NULL) parse_child(child, self.dli_fname);
    const char *mark = getenv("CMUX_BLOCKING_PROBE_UNTIL_MARK");
    if (mark != NULL && mark[0] != 0 && watch_main && out_pattern[0] != 0) open_window(mark);
    unsetenv("CMUX_BLOCKING_PROBE_UNTIL_MARK");
    unsetenv("CMUX_BLOCKING_PROBE_OUT");
    unsetenv("CMUX_PROBE_THREADS");
    unsetenv("CMUX_BLOCKING_PROBE_ARG");
    unsetenv("CMUX_BLOCKING_PROBE_CHILD");
    unsetenv("DYLD_INSERT_LIBRARIES");
    (void)dlopen_from_resolved();
    if (watch_main) observe_main_run_loop();
    atexit(dump_at_exit);
    __atomic_store_n(&ready, 1, __ATOMIC_RELEASE);
    if (out_pattern[0] == 0) return;
    if (watch_main) dispatch_async_f(dispatch_get_main_queue(), NULL, run_selftest);
    if (pthread_create(&dump_thread, NULL, dump_loop, watch_main ? NULL : (void *)1) == 0) dump_thread_pid = getpid();
}
