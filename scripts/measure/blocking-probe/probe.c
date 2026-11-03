// Main-thread blocking probe: a measurement tool, never linked into or shipped with cmux.
//
// Loaded with DYLD_INSERT_LIBRARIES into a tagged Debug or bench cmux-next app on the fleet
// (scripts/measure/blocking-probe.sh), it interposes the system calls and waits that block and records the
// calls made on the MAIN thread only: per call stack (a hash of its first STACK_KEY frames) a count, the total
// and longest time, and the longest call's stack. scripts/measure/blocking-probe-report.py then groups the entries by their
// first cmux frame, so each cmux call site is its own row however many wrappers sit above the system call.
//
// Self-test: at load the probe queues file system calls on the main queue, records them as kind "selftest" and
// writes a dump at once; the harness fails the run when that dump lacks them (the probe did not load, or
// interposing did not work).
//
// Output: $CMUX_BLOCKING_PROBE_OUT ("%p" becomes the pid), rewritten every DUMP_SECONDS by the probe's own
// thread (so a run the sweep kills, or a crash, keeps what it saw until the last dump) and at a clean exit,
// where the dump thread is stopped and joined first, so one writer at a time; each writer writes its own
// temporary file and renames it. The header says which ("#final 1" only at exit).
//
// Behavior is never changed: every interposer calls the real function on every path with the same arguments,
// returns its result and keeps its errno. The recording path allocates nothing (a fixed table, `backtrace` into
// a fixed array) and takes no lock. No signal disposition is touched. The constructor removes
// DYLD_INSERT_LIBRARIES and CMUX_BLOCKING_PROBE_OUT from the environment, so child processes (shells, the daemon,
// helpers) never load the probe; a fork without exec keeps a copy of the parent's table, and its dumps go to
// its own pid's file.
//
// Seen: open/openat (+$NOCANCEL), read/pread/write/pwrite (+$NOCANCEL), stat/lstat/fstat/fstatat/statfs/access,
// getattrlist/getattrlistbulk, fsync (+$NOCANCEL), fcntl (every command: F_FULLFSYNC, F_SETLKW), flock,
// mkdir/mkdirat, unlink/unlinkat, rename/renameat, readlink, close (only past WAIT_FLOOR_NS), recv/recvfrom/recvmsg, send/sendto/sendmsg, connect,
// select/poll, getaddrinfo, waitpid/wait4, dispatch_semaphore_wait, dispatch_group_wait, dispatch_sync(_f),
// pthread_cond_(timed)wait, pthread_mutex_lock, os_unfair_lock_lock, usleep, nanosleep. Waits count only past
// WAIT_FLOOR_NS; every file or socket call counts, however fast (Chrome's rule: no disk on the UI thread).
// dispatch_sync's time includes the block's own work.
// Not seen (known gaps): pthread_rwlock_*, os_unfair_lock_lock_with_options, semaphore_wait, mach_msg (sync XPC,
// and the main run loop's own idle wait), renamex_np/renameatx_np, ftruncate, getxattr/setxattr, readv/writev,
// getdirentries64, copyfile/clonefile, dispatch_async_and_wait, the $NOCANCEL forms of close, pwrite, connect,
// recvmsg, sendmsg, select, waitpid and wait4, and calls inside one system library to itself (dyld interposing
// sees calls across images only), so the probe under-counts and never over-counts.
#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
#include <limits.h>
#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <execinfo.h>
#include <fcntl.h>
#include <mach/mach_time.h>
#include <netdb.h>
#include <os/lock.h>
#include <poll.h>
#include <pthread.h>
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

enum { SLOTS = 8192, MAX_PROBES = 64, DEPTH = 24, STACK_KEY = 16, WAIT_FLOOR_NS = 1000000, DUMP_SECONDS = 10 };

typedef struct {
    const char *kind;  // published last (release): a dump reads only entries whose kind it sees
    uint64_t key;      // hash of the call's first STACK_KEY frames
    uint64_t count, total_ns, max_ns;
    int depth;
    void *stack[DEPTH];  // the longest call's stack
} Entry;

// Written only by the main thread; the dump thread reads it while it changes (counts may be one call behind,
// and a stack being replaced may mix two calls of the same entry, which share their first STACK_KEY frames).
static Entry table[SLOTS];
static uint64_t dropped;
static uint64_t calls;      // main-thread interposed calls timed (each costs two clock reads)
static uint64_t record_ns;  // time spent recording (the backtraces and hashes)
static mach_timebase_info_data_t timebase;
static int in_probe;                 // main thread only: the probe's own work is not recorded
static int selftest;                 // main thread only: the self-test's calls are recorded as kind "selftest"
static char out_pattern[1024];       // CMUX_BLOCKING_PROBE_OUT, copied at load
static uint64_t loaded_ns;
static const void *probe_base;       // the probe's own image, left out of the reported stacks

static inline uint64_t now_ns(void) {
    if (timebase.denom == 0) mach_timebase_info(&timebase);  // a call before the constructor ran
    return mach_absolute_time() * timebase.numer / timebase.denom;
}

static void record_entry(const char *kind, uint64_t ns) {
    void *stack[DEPTH];
    int depth = backtrace(stack, DEPTH);
    uint64_t key = 1469598103934665603ull ^ (uint64_t)(uintptr_t)kind;
    for (int f = 0; f < depth && f < STACK_KEY; f++) key = (key ^ (uint64_t)(uintptr_t)stack[f]) * 1099511628211ull;
    size_t slot = (size_t)(key % SLOTS);
    for (size_t probe = 0; probe < MAX_PROBES; probe++, slot = (slot + 1) % SLOTS) {
        Entry *e = &table[slot];
        const char *seen = __atomic_load_n(&e->kind, __ATOMIC_ACQUIRE);
        if (seen == NULL) {
            e->key = key;
            e->depth = depth;
            memcpy(e->stack, stack, sizeof(void *) * (size_t)depth);
            e->count = 1;
            e->total_ns = ns;
            e->max_ns = ns;
            __atomic_store_n(&e->kind, kind, __ATOMIC_RELEASE);
            return;
        }
        if (seen != kind || e->key != key) continue;
        e->count++;
        e->total_ns += ns;
        if (ns > e->max_ns) {
            e->max_ns = ns;
            memcpy(e->stack, stack, sizeof(void *) * (size_t)depth);
            e->depth = depth;
        }
        return;
    }
    dropped++;
}

static void record(const char *kind, uint64_t ns) {
    if (selftest) kind = "selftest";
    in_probe = 1;
    uint64_t start = now_ns();
    record_entry(kind, ns);
    record_ns += now_ns() - start;
    in_probe = 0;
}

#define TIMED(kind, floor, call)                                                                   \
    do {                                                                                          \
        if (!pthread_main_np() || in_probe) return call;                                          \
        uint64_t start_ = now_ns();                                                               \
        __typeof__(call) result_ = call;                                                          \
        int errno_ = errno;                                                                       \
        uint64_t ns_ = now_ns() - start_;                                                         \
        calls++;                                                                                  \
        if (ns_ >= (uint64_t)(floor)) record(kind, ns_);                                         \
        errno = errno_;                                                                           \
        return result_;                                                                           \
    } while (0)

#define TIMED_VOID(kind, floor, call)                                                              \
    do {                                                                                          \
        if (!pthread_main_np() || in_probe) { call; return; }                                     \
        uint64_t start_ = now_ns();                                                               \
        call;                                                                                     \
        int errno_ = errno;                                                                       \
        uint64_t ns_ = now_ns() - start_;                                                         \
        calls++;                                                                                  \
        if (ns_ >= (uint64_t)(floor)) record(kind, ns_);                                         \
        errno = errno_;                                                                           \
    } while (0)

// The optional third argument of open/openat/fcntl: read it only when the call takes one, then pass it on.
#define MODE_ARG(flags) ({ mode_t m_ = 0; if ((flags) & O_CREAT) { va_list ap; va_start(ap, flags); m_ = (mode_t)va_arg(ap, int); va_end(ap); } m_; })

// File system
static int p_open(const char *path, int flags, ...) { mode_t m = MODE_ARG(flags); TIMED("file-io:open", 0, open(path, flags, m)); }
static int p_open_nc(const char *path, int flags, ...) { mode_t m = MODE_ARG(flags); TIMED("file-io:open", 0, open_nocancel(path, flags, m)); }
static int p_openat(int fd, const char *path, int flags, ...) { mode_t m = MODE_ARG(flags); TIMED("file-io:openat", 0, openat(fd, path, flags, m)); }
static int p_openat_nc(int fd, const char *path, int flags, ...) { mode_t m = MODE_ARG(flags); TIMED("file-io:openat", 0, openat_nocancel(fd, path, flags, m)); }
static ssize_t p_read(int fd, void *b, size_t n) { TIMED("io:read", 0, read(fd, b, n)); }
static ssize_t p_read_nc(int fd, void *b, size_t n) { TIMED("io:read", 0, read_nocancel(fd, b, n)); }
static ssize_t p_pread(int fd, void *b, size_t n, off_t o) { TIMED("file-io:pread", 0, pread(fd, b, n, o)); }
static ssize_t p_pread_nc(int fd, void *b, size_t n, off_t o) { TIMED("file-io:pread", 0, pread_nocancel(fd, b, n, o)); }
static ssize_t p_write(int fd, const void *b, size_t n) { TIMED("io:write", 0, write(fd, b, n)); }
static ssize_t p_write_nc(int fd, const void *b, size_t n) { TIMED("io:write", 0, write_nocancel(fd, b, n)); }
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
    TIMED("file-io:fcntl", 0, fcntl(fd, cmd, arg));
}
static int p_fcntl_nc(int fd, int cmd, ...) {
    va_list ap; va_start(ap, cmd); void *arg = va_arg(ap, void *); va_end(ap);
    TIMED("file-io:fcntl", 0, fcntl_nocancel(fd, cmd, arg));
}
static int p_flock(int fd, int op) { TIMED("file-io:flock", 0, flock(fd, op)); }
static int p_mkdir(const char *p, mode_t m) { TIMED("file-io:mkdir", 0, mkdir(p, m)); }
static int p_unlink(const char *p) { TIMED("file-io:unlink", 0, unlink(p)); }
static int p_rename(const char *a, const char *b) { TIMED("file-io:rename", 0, rename(a, b)); }
static ssize_t p_readlink(const char *p, char *b, size_t n) { TIMED("file-io:readlink", 0, readlink(p, b, n)); }
static int p_close(int fd) { TIMED("io:close", WAIT_FLOOR_NS, close(fd)); }
// Sockets, polling and processes
static ssize_t p_recv(int s, void *b, size_t n, int f) { TIMED("socket-read:recv", 0, recv(s, b, n, f)); }
static ssize_t p_recvfrom(int s, void *b, size_t n, int f, struct sockaddr *a, socklen_t *l) {
    TIMED("socket-read:recvfrom", 0, recvfrom(s, b, n, f, a, l));
}
static ssize_t p_recvfrom_nc(int s, void *b, size_t n, int f, struct sockaddr *a, socklen_t *l) {
    TIMED("socket-read:recvfrom", 0, recvfrom_nocancel(s, b, n, f, a, l));
}
static ssize_t p_recvmsg(int s, struct msghdr *m, int f) { TIMED("socket-read:recvmsg", 0, recvmsg(s, m, f)); }
static ssize_t p_send(int s, const void *b, size_t n, int f) { TIMED("socket-write:send", 0, send(s, b, n, f)); }
static ssize_t p_sendto(int s, const void *b, size_t n, int f, const struct sockaddr *a, socklen_t l) {
    TIMED("socket-write:sendto", 0, sendto(s, b, n, f, a, l));
}
static ssize_t p_sendto_nc(int s, const void *b, size_t n, int f, const struct sockaddr *a, socklen_t l) {
    TIMED("socket-write:sendto", 0, sendto_nocancel(s, b, n, f, a, l));
}
static ssize_t p_sendmsg(int s, const struct msghdr *m, int f) { TIMED("socket-write:sendmsg", 0, sendmsg(s, m, f)); }
static int p_connect(int s, const struct sockaddr *a, socklen_t l) { TIMED("socket:connect", 0, connect(s, a, l)); }
static int p_select(int n, fd_set *r, fd_set *w, fd_set *e, struct timeval *t) { TIMED("socket:select", 0, select(n, r, w, e, t)); }
static int p_poll(struct pollfd *f, nfds_t n, int t) { TIMED("socket:poll", 0, poll(f, n, t)); }
static int p_poll_nc(struct pollfd *f, nfds_t n, int t) { TIMED("socket:poll", 0, poll_nocancel(f, n, t)); }
static int p_getaddrinfo(const char *h, const char *s, const struct addrinfo *i, struct addrinfo **r) {
    TIMED("socket:getaddrinfo", 0, getaddrinfo(h, s, i, r));
}
static pid_t p_waitpid(pid_t p, int *s, int o) { TIMED("process-wait:waitpid", 0, waitpid(p, s, o)); }
static pid_t p_wait4(pid_t p, int *s, int o, struct rusage *r) { TIMED("process-wait:wait4", 0, wait4(p, s, o, r)); }
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

// Writes the table: a header, then one line per entry: kind count total_ns max_ns frames, each frame
// image|offset|symbol (the probe's own frames left out). Written to a temporary file, then renamed, so a reader
// never sees half a dump. The main thread (atexit) marks its own I/O with in_probe; the dump thread is not the
// main thread, so the interposers never record its I/O.
static void dump(int final) {
    if (out_pattern[0] == 0) return;
    char path[1100], partial[1200];
    const char *pid = strstr(out_pattern, "%p");
    if (pid) {
        snprintf(path, sizeof path, "%.*s%d%s", (int)(pid - out_pattern), out_pattern, getpid(), pid + 2);
    } else {
        snprintf(path, sizeof path, "%s", out_pattern);
    }
    snprintf(partial, sizeof partial, "%s.%s.partial", path, final ? "final" : "periodic");
    int main = pthread_main_np();
    if (main) in_probe = 1;
    FILE *out = fopen(partial, "w");
    if (out != NULL) {
        fprintf(out, "#final\t%d\n#uptime_ms\t%llu\n#dropped\t%llu\n#calls\t%llu\n#record_ns\t%llu\n", final,
                (unsigned long long)((now_ns() - loaded_ns) / 1000000), (unsigned long long)dropped,
                (unsigned long long)calls, (unsigned long long)record_ns);
        for (size_t i = 0; i < SLOTS; i++) {
            Entry *e = &table[i];
            const char *kind = __atomic_load_n(&e->kind, __ATOMIC_ACQUIRE);
            if (kind == NULL) continue;
            int depth = e->depth < DEPTH ? e->depth : DEPTH;
            fprintf(out, "%s\t%llu\t%llu\t%llu\t", kind, (unsigned long long)e->count,
                    (unsigned long long)e->total_ns, (unsigned long long)e->max_ns);
            for (int f = 0; f < depth; f++) {
                Dl_info info;
                if (dladdr(e->stack[f], &info) && info.dli_fname) {
                    if (info.dli_fbase == probe_base) continue;
                    const char *image = strrchr(info.dli_fname, '/');
                    fprintf(out, "%s|0x%lx|%s;", image ? image + 1 : info.dli_fname,
                            (unsigned long)((uintptr_t)e->stack[f] - (uintptr_t)info.dli_fbase),
                            info.dli_sname ? info.dli_sname : "?");
                } else {
                    fprintf(out, "?|%p|?;", e->stack[f]);
                }
            }
            fputc('\n', out);
        }
        if (fclose(out) == 0) rename(partial, path);
    }
    if (main) in_probe = 0;
}

// The dump thread waits on a condition with a deadline (not a sleep), so the exit path can stop it at once.
static pthread_mutex_t dump_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t dump_wake = PTHREAD_COND_INITIALIZER;
static int dump_stop;
static pthread_t dump_thread;
static pid_t dump_thread_pid;  // a fork does not inherit the thread: only its creator joins it

static void *dump_loop(void *unused) {
    (void)unused;
    pthread_setname_np("cmux blocking-probe dump");
    pthread_mutex_lock(&dump_lock);
    while (!dump_stop) {
        struct timespec until;
        clock_gettime(CLOCK_REALTIME, &until);
        until.tv_sec += DUMP_SECONDS;
        while (!dump_stop && pthread_cond_timedwait(&dump_wake, &dump_lock, &until) != ETIMEDOUT) {}
        if (dump_stop) break;
        pthread_mutex_unlock(&dump_lock);
        dump(0);
        pthread_mutex_lock(&dump_lock);
    }
    pthread_mutex_unlock(&dump_lock);
    return NULL;
}

// At exit (main thread): stop and join the dump thread, then write the final dump, so only one writer runs.
static void dump_at_exit(void) {
    int main = pthread_main_np();
    if (main) in_probe = 1;
    if (dump_thread_pid == getpid()) {
        pthread_mutex_lock(&dump_lock);
        dump_stop = 1;
        pthread_cond_signal(&dump_wake);
        pthread_mutex_unlock(&dump_lock);
        pthread_join(dump_thread, NULL);
        dump_thread_pid = 0;
    }
    if (main) in_probe = 0;
    dump(1);
}

// Proves the probe works in this process: on the main thread, file system calls made from other images (libc,
// CoreFoundation, so dyld's interposing applies) must be recorded as kind "selftest", and the first periodic
// dump must show it. scripts/measure/blocking-probe.sh fails the run when it does not.
static void run_selftest(void *unused) {
    (void)unused;
    selftest = 1;
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
    selftest = 0;
    dump(0);  // at once, so the harness sees the self-test without waiting for the periodic dump
}

__attribute__((constructor)) static void start(void) {
    mach_timebase_info(&timebase);
    loaded_ns = now_ns();
    Dl_info self;
    if (dladdr((const void *)&start, &self)) probe_base = self.dli_fbase;
    const char *out = getenv("CMUX_BLOCKING_PROBE_OUT");
    if (out != NULL) snprintf(out_pattern, sizeof out_pattern, "%s", out);
    unsetenv("CMUX_BLOCKING_PROBE_OUT");
    unsetenv("DYLD_INSERT_LIBRARIES");
    atexit(dump_at_exit);
    if (out_pattern[0]) dispatch_async_f(dispatch_get_main_queue(), NULL, run_selftest);
    if (out_pattern[0] && pthread_create(&dump_thread, NULL, dump_loop, NULL) == 0) dump_thread_pid = getpid();
}
