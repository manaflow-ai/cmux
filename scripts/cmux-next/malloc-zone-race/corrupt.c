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
// that zone a block another zone owns (a stand-in for PartitionAlloc after CefInitialize, see
// register_owner_zone): realloc, then free_definite_size, through the zone's own function pointers
// (as Chromium's shim calls the zone it captured). A delegating zone that forwards them to the
// system zone without asking who owns the pointer fails here: the system zone reports "not
// allocated" (an abort) or returns NULL.
//
// argv[1] = framework binary; argv[2] = seconds of churn after the dlopen returns (default 1).
// Exit 0: no corruption seen; 2: a live block changed (prints the slot, offset and word);
// 3: dlopen failed; 4: a foreign realloc through the delegating zone failed (NULL or a changed
// block); 5: no verdict (the delegating zone was not zones[0], or the stand-in zone does not own
// its block). Run it with MallocCheckHeapStart / MallocCheckHeapEach / MallocScribble /
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

// The foreign owner: a zone that owns its own blocks (a bump arena), registered after the swap. It
// stands in for PartitionAlloc after CefInitialize: before CefInitialize PartitionAlloc's zone hands
// out the system zone's blocks (fleet run of 49aaddf7aee: every "PartitionAlloc" block was
// DefaultMallocZone's), and this probe cannot initialize CEF.
enum { ARENA = 1 << 20 };
static unsigned char arena[ARENA] __attribute__((aligned(16)));
static size_t arena_used;
static malloc_zone_t owner_zone;
static malloc_introspection_t owner_introspect;
static int in_arena(const void* p) { return (const unsigned char*)p >= arena + 16 && (const unsigned char*)p < arena + ARENA; }
static size_t o_size(malloc_zone_t* z, const void* p) { return in_arena(p) ? *(const size_t*)((const unsigned char*)p - 16) : 0; }
static void* o_malloc(malloc_zone_t* z, size_t size) {
  size_t need = 16 + ((size + 15) & ~(size_t)15);
  if (arena_used + need > ARENA) return NULL;
  unsigned char* block = arena + arena_used + 16;
  *(size_t*)(block - 16) = size;
  arena_used += need;
  return block;
}
static void o_free(malloc_zone_t* z, void* p) {}
static void o_free_definite_size(malloc_zone_t* z, void* p, size_t size) {}
static void* o_realloc(malloc_zone_t* z, void* p, size_t size) {
  void* grown = o_malloc(z, size);
  if (grown && p) memcpy(grown, p, o_size(z, p) < size ? o_size(z, p) : size);
  return grown;
}
static kern_return_t o_enumerator(task_t t, void* c, unsigned m, vm_address_t a, memory_reader_t r, vm_range_recorder_t rec) {
  return KERN_SUCCESS;
}
static size_t o_good_size(malloc_zone_t* z, size_t size) { return (size + 15) & ~(size_t)15; }
static boolean_t o_check(malloc_zone_t* z) { return 1; }
static void o_print(malloc_zone_t* z, boolean_t verbose) {}
static void o_log(malloc_zone_t* z, void* address) {}
static void o_lock(malloc_zone_t* z) {}
static void o_statistics(malloc_zone_t* z, malloc_statistics_t* stats) { memset(stats, 0, sizeof *stats); }

static malloc_zone_t* register_owner_zone(void) {
  owner_zone.size = o_size;
  owner_zone.malloc = o_malloc;
  owner_zone.free = o_free;
  owner_zone.free_definite_size = o_free_definite_size;
  owner_zone.realloc = o_realloc;
  owner_introspect.enumerator = o_enumerator;
  owner_introspect.good_size = o_good_size;
  owner_introspect.check = o_check;
  owner_introspect.print = o_print;
  owner_introspect.log = o_log;
  owner_introspect.force_lock = o_lock;
  owner_introspect.force_unlock = o_lock;
  owner_introspect.statistics = o_statistics;
  owner_zone.introspect = &owner_introspect;
  owner_zone.version = 8;
  owner_zone.zone_name = "CmuxProbeForeignOwner";
  malloc_zone_register(&owner_zone);
  return &owner_zone;
}

// The foreign-pointer check (see the top): 64 blocks of the foreign owner, each reallocated and then
// freed with its size through the delegating zone's own function pointers. 0, 4 or 5 (main's exit codes).
static int foreign_check(malloc_zone_t* delegating) {
  if (!delegating) {
    printf("NO VERDICT: the delegating zone was not zones[0] after its registration\n");
    return 5;
  }
  malloc_zone_t* owner = register_owner_zone();
  for (unsigned n = 0; n < 64; n++) {
    size_t size = 0x250;
    uint64_t* block = owner->malloc(owner, size);
    if (!block || malloc_zone_from_ptr(block) != owner) {
      printf("NO VERDICT: the foreign owner zone does not own its block\n");
      return 5;
    }
    for (size_t w = 0; w < size / 8; w++) block[w] = canary(n, w);
    uint64_t* grown = delegating->realloc(delegating, block, 2 * size);
    if (!grown) {
      printf("FOREIGN realloc of another zone's block through the delegating zone returned NULL\n");
      return 4;
    }
    if (!check(grown, size, n)) {
      printf("FOREIGN realloc through the delegating zone changed the block\n");
      return 4;
    }
    if (malloc_zone_from_ptr(grown) != owner) {
      printf("FOREIGN realloc through the delegating zone moved the block out of its owner\n");
      return 4;
    }
    delegating->free_definite_size(delegating, grown, o_size(owner, grown));
  }
  malloc_zone_unregister(owner);
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
  printf("ok %lu allocations, %lu checked frees, 64 foreign reallocs through the delegating zone\n", i, frees);
  return 0;
}
