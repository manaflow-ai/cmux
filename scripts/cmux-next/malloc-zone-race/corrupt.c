// #23821: does the PartitionAlloc zone swap during a background dlopen of the CEF framework
// corrupt live heap blocks? Models cmux-next's launch: the delegating zone is installed first
// (CmuxNextApp.main), then a background thread dlopens the framework (CEFRuntime.loadLibrary)
// while the main thread allocates and frees 0x250-byte blocks (BrowserHostProvider's size) and
// small ones. Every live block carries a canary pattern, checked before each free and once at the
// end; a third of the frees go through the default zone cached before the swap
// (malloc_zone_free(cached, p)), as CoreFoundation's allocator does.
//
// argv[1] = framework binary; argv[2] = seconds of churn after the dlopen returns (default 1).
// Exit 0: no corruption seen; 2: a live block changed (prints the slot, offset and word);
// 3: dlopen failed. Run it with MallocCheckHeapStart / MallocCheckHeapEach / MallocScribble /
// MallocStackLogging (run.sh corrupt) so libmalloc also checks its own free lists.
#include <dlfcn.h>
#include <malloc/malloc.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "CmuxNextMallocZone.h"

enum { SLOTS = 8192 };
static atomic_int loaded;

static void* load(void* path) {
  void* handle = dlopen((const char*)path, RTLD_NOW | RTLD_LOCAL);
  if (!handle) fprintf(stderr, "dlopen: %s\n", dlerror());
  atomic_store(&loaded, handle ? 1 : 3);
  return NULL;
}

static uint64_t canary(unsigned slot, size_t word) { return 0xC0FFEE0000000000ull ^ ((uint64_t)slot << 20) ^ word; }

static int check(uint64_t* block, size_t size, unsigned slot) {
  for (size_t w = 0; w < size / 8; w++) {
    if (block[w] != canary(slot, w)) {
      printf("CORRUPT slot %u size %zu offset 0x%zx word 0x%016llx (expected 0x%016llx)\n", slot, size, w * 8,
             (unsigned long long)block[w], (unsigned long long)canary(slot, w));
      return 0;
    }
  }
  return 1;
}

static double now(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec + t.tv_nsec / 1e9;
}

int main(int argc, char** argv) {
  if (argc < 2) return 64;
  double tail = argc > 2 ? atof(argv[2]) : 1;
  cmux_early_malloc_zone_registration();
  malloc_zone_t* cached = malloc_default_zone();
  static uint64_t* blocks[SLOTS];
  static size_t sizes[SLOTS];
  pthread_t loader;
  pthread_create(&loader, NULL, load, argv[1]);
  double stop = 0;
  unsigned long i = 0, frees = 0;
  for (;;) {
    int state = atomic_load(&loaded);
    if (state == 3) return 3;
    if (state == 1 && stop == 0) stop = now() + tail;
    if (stop != 0 && now() >= stop) break;
    unsigned slot = (unsigned)((i * 2654435761u) % SLOTS);
    if (blocks[slot]) {
      if (!check(blocks[slot], sizes[slot], slot)) return 2;
      if (i % 3 == 0) malloc_zone_free(cached, blocks[slot]); else free(blocks[slot]);
      frees++;
    }
    size_t size = (i % 4 == 0) ? 0x250 : 16 * (1 + i % 32);
    uint64_t* block = malloc(size);
    for (size_t w = 0; w < size / 8; w++) block[w] = canary(slot, w);
    blocks[slot] = block;
    sizes[slot] = size;
    i++;
  }
  pthread_join(loader, NULL);
  for (unsigned slot = 0; slot < SLOTS; slot++) {
    if (blocks[slot] && !check(blocks[slot], sizes[slot], slot)) return 2;
  }
  printf("ok %lu allocations, %lu checked frees\n", i, frees);
  return 0;
}
