// #23821: does the PartitionAlloc zone swap during a background dlopen of the CEF framework
// corrupt live heap blocks? Models cmux-next's launch: the delegating zone is installed first
// (CmuxNextApp.main), then a background thread dlopens the framework (CEFRuntime.loadLibrary)
// while the main thread allocates and frees 0x250-byte blocks (BrowserHostProvider's size) and
// small ones. Every live block carries a canary pattern, checked before each free and once at the
// end; a third of the frees go through malloc_default_zone() kept before the swap
// (malloc_zone_free(cached, p)), as CoreFoundation's allocator does. That is libmalloc's virtual
// zone, which follows zones[0], so those frees reach PartitionAlloc after the swap, never the
// delegating zone.
//
// Then the foreign-pointer check (the gap 3e23a9de69e closes): a caller that kept zones[0] of
// malloc_get_all_zones before the swap holds the delegating zone itself. After the swap it hands
// that zone a block PartitionAlloc made: realloc, then free_definite_size, through the zone's own
// function pointers (as Chromium's shim calls the zone it captured). A delegating zone that
// forwards them to the system zone without asking who owns the pointer fails here: the system
// zone reports "not allocated" (an abort) or returns NULL.
//
// argv[1] = framework binary; argv[2] = seconds of churn after the dlopen returns (default 1).
// Exit 0: no corruption seen; 2: a live block changed (prints the slot, offset and word);
// 3: dlopen failed; 4: a foreign realloc through the delegating zone failed (NULL or a changed
// block); 5: no verdict (the delegating zone was not zones[0], or the swap did not happen). Run it with MallocCheckHeapStart / MallocCheckHeapEach / MallocScribble /
// MallocStackLogging (run.sh corrupt) so libmalloc also checks its own free lists.
#include <dlfcn.h>
#include <mach/mach.h>
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

// The foreign-pointer check (see the top): 64 PartitionAlloc blocks, each reallocated and then freed
// with its size through the delegating zone's own function pointers. 0, 4 or 5 (main's exit codes).
static malloc_zone_t* zone_named(const char* wanted, char* names, size_t room) {
  vm_address_t* zones = NULL;
  unsigned count = 0;
  malloc_zone_t* found = NULL;
  if (names) names[0] = 0;
  if (malloc_get_all_zones(mach_task_self(), NULL, &zones, &count) != KERN_SUCCESS) return NULL;
  for (unsigned z = 0; z < count; z++) {
    malloc_zone_t* zone = (malloc_zone_t*)zones[z];
    const char* name = malloc_get_zone_name(zone);
    if (names) {
      strlcat(names, z ? ", " : "", room);
      strlcat(names, name ? name : "?", room);
    }
    if (!found && name && strcmp(name, wanted) == 0) found = zone;
  }
  return found;
}

static int foreign_check(malloc_zone_t* delegating) {
  if (!delegating) {
    printf("NO VERDICT: the delegating zone was not zones[0] after its registration\n");
    return 5;
  }
  // The blocks come from PartitionAlloc's zone itself (the framework's constructor registered it;
  // whether malloc() reaches it before CefInitialize does not matter here).
  char names[512];
  malloc_zone_t* partition = zone_named("PartitionAlloc", names, sizeof names);
  if (!partition) {
    printf("NO VERDICT: no PartitionAlloc zone after the dlopen (zones: %s)\n", names);
    return 5;
  }
  for (unsigned n = 0; n < 64; n++) {
    size_t size = 0x250;
    uint64_t* block = partition->malloc(partition, size);
    if (!block || malloc_zone_from_ptr(block) != partition) {
      printf("NO VERDICT: PartitionAlloc's zone gave a block it does not own (zones: %s)\n", names);
      return 5;
    }
    for (size_t w = 0; w < size / 8; w++) block[w] = canary(n, w);
    uint64_t* grown = delegating->realloc(delegating, block, 2 * size);
    if (!grown) {
      printf("FOREIGN realloc of a PartitionAlloc block through the delegating zone returned NULL\n");
      return 4;
    }
    if (!check(grown, size, n)) {
      printf("FOREIGN realloc through the delegating zone changed the block\n");
      return 4;
    }
    malloc_zone_t* grown_owner = malloc_zone_from_ptr(grown);
    if (!grown_owner) {
      printf("FOREIGN realloc through the delegating zone returned a block no zone owns\n");
      return 4;
    }
    delegating->free_definite_size(delegating, grown, malloc_size(grown));
  }
  return 0;
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
  vm_address_t* zones = NULL;
  unsigned zone_count = 0;
  malloc_zone_t* delegating = NULL;
  if (malloc_get_all_zones(mach_task_self(), NULL, &zones, &zone_count) == KERN_SUCCESS && zone_count > 0) {
    malloc_zone_t* first = (malloc_zone_t*)zones[0];
    const char* name = malloc_get_zone_name(first);
    if (name && strcmp(name, "DelegatingDefaultZoneForPartitionAlloc") == 0) delegating = first;
  }
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
  int foreign = foreign_check(delegating);
  if (foreign != 0) return foreign;
  printf("ok %lu allocations, %lu checked frees, 64 foreign reallocs\n", i, frees);
  return 0;
}
