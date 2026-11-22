// The fs_event floor of the daemon_restart loop: the raw latency from a file write to the
// kernel's file event, in one process (one clock), N times. macOS: FSEvents with per-file events
// and no coalescing latency (kFSEventStreamCreateFlagFileEvents | NoDefer, latency 0). Linux:
// inotify. Prints one line per sample: the milliseconds from the write's return to the event.
//   cc -O2 -o fs_event_latency fs_event_latency.c [-framework CoreServices]   (macOS)
//   fs_event_latency DIR N
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static double now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6;
}

static int write_file(const char *path, int i) {
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return -1;
    char buf[64];
    int n = snprintf(buf, sizeof buf, "fn edit() -> u32 { %d }\n", i);
    int rc = write(fd, buf, (size_t)n) == n ? 0 : -1;
    close(fd);
    return rc;
}

#ifdef __APPLE__
#include <CoreServices/CoreServices.h>
#include <dispatch/dispatch.h>

static dispatch_semaphore_t seen;
static volatile double event_at;
static const char *watched_name;

static void callback(ConstFSEventStreamRef stream, void *info, size_t n, void *paths,
                     const FSEventStreamEventFlags flags[], const FSEventStreamEventId ids[]) {
    (void)stream; (void)info; (void)flags; (void)ids;
    double t = now_ms();
    char **names = (char **)paths;
    for (size_t i = 0; i < n; i++) {
        if (strstr(names[i], watched_name)) {
            event_at = t;
            dispatch_semaphore_signal(seen);
            return;
        }
    }
}

int main(int argc, char **argv) {
    if (argc != 3) { fprintf(stderr, "usage: %s DIR N\n", argv[0]); return 2; }
    char real[PATH_MAX];
    if (!realpath(argv[1], real)) { perror("realpath"); return 2; }
    int n = atoi(argv[2]);
    char path[PATH_MAX];
    snprintf(path, sizeof path, "%s/edited.rs", real);
    watched_name = "/edited.rs";
    seen = dispatch_semaphore_create(0);
    CFStringRef dir = CFStringCreateWithCString(NULL, real, kCFStringEncodingUTF8);
    CFArrayRef dirs = CFArrayCreate(NULL, (const void **)&dir, 1, &kCFTypeArrayCallBacks);
    FSEventStreamRef stream = FSEventStreamCreate(
        NULL, callback, NULL, dirs, kFSEventStreamEventIdSinceNow, 0.0,
        kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer);
    dispatch_queue_t queue = dispatch_queue_create("fs-event-latency", DISPATCH_QUEUE_SERIAL);
    FSEventStreamSetDispatchQueue(stream, queue);
    if (!FSEventStreamStart(stream)) { fprintf(stderr, "FSEventStreamStart failed\n"); return 1; }
    usleep(300 * 1000);  // the stream's first events (its own setup) settle
    int failed = 0;
    for (int i = 0; i < n + 1; i++) {
        while (dispatch_semaphore_wait(seen, DISPATCH_TIME_NOW) == 0) {}  // drop stale signals
        usleep(150 * 1000);
        double t0 = now_ms();
        if (write_file(path, i) != 0) { perror("write"); return 1; }
        if (dispatch_semaphore_wait(seen, dispatch_time(DISPATCH_TIME_NOW, 5LL * NSEC_PER_SEC)) != 0) {
            fprintf(stderr, "no event in 5 s for write %d\n", i);
            failed = 1;
            continue;
        }
        if (i > 0) printf("%.3f\n", event_at - t0);  // the first write warms the stream: not a sample
        fflush(stdout);
    }
    FSEventStreamStop(stream);
    FSEventStreamInvalidate(stream);
    FSEventStreamRelease(stream);
    return failed;
}
#else
#include <poll.h>
#include <sys/inotify.h>

int main(int argc, char **argv) {
    if (argc != 3) { fprintf(stderr, "usage: %s DIR N\n", argv[0]); return 2; }
    int n = atoi(argv[2]);
    char path[4096];
    snprintf(path, sizeof path, "%s/edited.rs", argv[1]);
    int fd = inotify_init1(IN_NONBLOCK);
    if (fd < 0 || inotify_add_watch(fd, argv[1], IN_CLOSE_WRITE) < 0) { perror("inotify"); return 1; }
    char buf[4096];
    int failed = 0;
    for (int i = 0; i < n + 1; i++) {
        while (read(fd, buf, sizeof buf) > 0) {}  // drop stale events
        usleep(150 * 1000);
        double t0 = now_ms();
        if (write_file(path, i) != 0) { perror("write"); return 1; }
        struct pollfd p = {.fd = fd, .events = POLLIN};
        if (poll(&p, 1, 5000) != 1) { fprintf(stderr, "no event in 5 s for write %d\n", i); failed = 1; continue; }
        double t1 = now_ms();
        if (i > 0) printf("%.3f\n", t1 - t0);
        fflush(stdout);
    }
    return failed;
}
#endif
