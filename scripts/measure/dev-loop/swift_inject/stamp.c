// Timestamps a tool's run for scripts/measure/dev-loop/swift_inject.sh, with about a millisecond of
// its own cost (a bash or python wrapper would add tens).
//
// Two ways to run it:
//   - Linked as NAME (xcrun, codesign, mv) in a folder put first on PATH: runs the real
//     /usr/bin/NAME (or /bin/NAME) with the same arguments, and when DLC_STAMP_LOG is set appends
//     "START END STATUS NAME ARGS..." (seconds since the epoch) to it. inject.sh runs unchanged.
//   - stamp LOG LABEL CMD ARGS...: runs CMD and appends "START END STATUS LABEL" to LOG (a floor).
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <unistd.h>

static double now(void) {
  struct timeval tv;
  gettimeofday(&tv, NULL);
  return (double)tv.tv_sec + (double)tv.tv_usec / 1e6;
}

static int run(const char *path, char **argv, int search) {
  pid_t pid = fork();
  if (pid < 0) { perror("stamp: fork"); return 127; }
  if (pid == 0) {
    if (search) execvp(path, argv); else execv(path, argv);
    fprintf(stderr, "stamp: cannot run %s: %s\n", path, strerror(errno));
    _exit(127);
  }
  int status = 0;
  while (waitpid(pid, &status, 0) < 0) {
    if (errno != EINTR) { perror("stamp: waitpid"); return 127; }
  }
  return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
}

static void record(const char *log, double start, double end, int code, const char *label, int argc, char **argv) {
  if (!log || !*log) return;
  FILE *f = fopen(log, "a");
  if (!f) return;
  fprintf(f, "%.6f %.6f %d %s", start, end, code, label);
  for (int i = 0; i < argc; i++) fprintf(f, " %s", argv[i]);
  fputc('\n', f);
  fclose(f);
}

int main(int argc, char **argv) {
  const char *base = strrchr(argv[0], '/');
  base = base ? base + 1 : argv[0];
  if (strcmp(base, "stamp") == 0) {
    if (argc < 4) { fprintf(stderr, "usage: stamp LOG LABEL CMD ARGS...\n"); return 64; }
    double start = now();
    int code = run(argv[3], argv + 3, 1);
    record(argv[1], start, now(), code, argv[2], 0, NULL);
    return code;
  }
  char real[256];
  snprintf(real, sizeof real, "/usr/bin/%s", base);
  if (access(real, X_OK) != 0) snprintf(real, sizeof real, "/bin/%s", base);
  argv[0] = real;
  double start = now();
  int code = run(real, argv, 0);
  record(getenv("DLC_STAMP_LOG"), start, now(), code, base, argc - 1, argv + 1);
  return code;
}
