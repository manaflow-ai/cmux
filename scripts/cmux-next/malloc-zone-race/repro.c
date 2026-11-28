// Frees system-zone pointers on one thread while another dlopens the CEF
// framework (whose PartitionAlloc constructor swaps the default zone).
// argv[1] = "early" to register a delegating default zone first (Chromium's
// EarlyMallocZoneRegistration), argv[2] = framework binary.
#include <dlfcn.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "CmuxNextMallocZone.h"

static atomic_int stop;
static void* churn(void* arg) {
  enum { N = 4096 };
  void* slots[N] = {0};
  unsigned i = 0;
  while (!atomic_load(&stop)) {
    unsigned k = (i * 2654435761u) % N;
    free(slots[k]);
    slots[k] = malloc(16 + (i % 512));
    i++;
  }
  for (int k = 0; k < N; k++) free(slots[k]);
  return NULL;
}

int main(int argc, char** argv) {
  if (argc > 1 && !strcmp(argv[1], "early")) cmux_early_malloc_zone_registration();
  pthread_t threads[4];
  for (int t = 0; t < 4; t++) pthread_create(&threads[t], NULL, churn, NULL);
  void* handle = dlopen(argv[2], RTLD_NOW | RTLD_LOCAL);
  if (!handle) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 3; }
  atomic_store(&stop, 1);
  for (int t = 0; t < 4; t++) pthread_join(threads[t], NULL);
  printf("ok\n");
  return 0;
}
