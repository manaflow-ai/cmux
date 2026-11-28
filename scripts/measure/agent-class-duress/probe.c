// What acpmux's dynamic-class sampler reads (cmux-tui/crates/acpmux/src/cpu_class/pressure.rs),
// once a second for SECONDS: the p90 lateness of 20 10 ms sleeps on a user-interactive thread and
// the share of all CPUs busy. Prints one "probe busy=B late_p90_ms=L" line per second.
#include <mach/mach.h>
#include <pthread/qos.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>
static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec / 1e9; }
static int cmp(const void *a, const void *b) { double x = *(const double *)a, y = *(const double *)b; return (x > y) - (x < y); }
static int ticks(unsigned int out[4]) {
  host_cpu_load_info_data_t info; mach_msg_type_number_t n = HOST_CPU_LOAD_INFO_COUNT;
  if (host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, (host_info_t)&info, &n) != KERN_SUCCESS) return 0;
  for (int i = 0; i < 4; i++) out[i] = info.cpu_ticks[i];
  return 1;
}
int main(int argc, char **argv) {
  int seconds = argc > 1 ? atoi(argv[1]) : 10;
  pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
  unsigned int before[4], after[4];
  ticks(before);
  for (int s = 0; s < seconds; s++) {
    double start = now(), late[24]; int k = 0;
    while (now() - start < 0.2 && k < 24) { double t = now(); usleep(10000); late[k++] = (now() - t - 0.010) * 1000; }
    double rest = 1.0 - (now() - start);
    if (rest > 0) usleep((useconds_t)(rest * 1e6));
    ticks(after);
    unsigned long d[4], total = 0;
    for (int i = 0; i < 4; i++) { d[i] = after[i] - before[i]; total += d[i]; before[i] = after[i]; }
    qsort(late, k, sizeof(double), cmp);
    int r = (k * 9 + 9) / 10 - 1; if (r < 0) r = 0;
    printf("probe busy=%.3f late_p90_ms=%.3f\n", total ? (double)(total - d[2]) / total : 0, k ? late[r] : 0);
    fflush(stdout);
  }
  return 0;
}
