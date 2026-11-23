// The default zone must report the size of a block it made while the delegating zone is
// zones[0]. SQLite's Apple allocator (mem1.c, the copy bundled in CCmuxAppFFI by rusqlite)
// allocates with malloc_zone_malloc(malloc_default_zone(), n) and sizes its hash tables with
// malloc_default_zone()->size(zone, p). malloc_default_zone() is libmalloc's virtual zone, which
// follows zones[0]. When the delegating zone answered 0, SQLite took 0 buckets, divided by zero
// (0 on arm64) and indexed by the raw hash: nightly 1.0.0-nightly.4294166855401 crashed at launch
// on the cmux-cookie-sync thread (sqlite3HashInsert from openDatabase -> sqlite3Fts3Init).
// Exit 0 when every size is right, 1 when one is wrong, 3 when the zone did not install.
#include <malloc/malloc.h>
#include <stdio.h>
#include <stdlib.h>
#include "CmuxNextMallocZone.h"

int main(void) {
  if (!cmux_early_malloc_zone_registration()) {
    fprintf(stderr, "the delegating zone is not zones[0]\n");
    return 3;
  }
  malloc_zone_t* zone = malloc_default_zone();
  int bad = 0;
  for (size_t n = 1; n <= (1u << 20); n *= 3) {
    void* p = malloc_zone_malloc(zone, n);
    size_t zone_size = zone->size(zone, p);
    size_t global_size = malloc_size(p);
    if (zone_size < n || global_size < n) {
      fprintf(stderr, "block of %zu bytes: malloc_default_zone()->size %zu, malloc_size %zu\n", n, zone_size,
              global_size);
      bad = 1;
    }
    malloc_zone_free(zone, p);
    void* q = malloc(n);
    if (zone->size(zone, q) < n) {
      fprintf(stderr, "malloc(%zu): malloc_default_zone()->size %zu\n", n, zone->size(zone, q));
      bad = 1;
    }
    free(q);
  }
  // A pointer no zone made is still nobody's.
  int stack_byte = 0;
  if (zone->size(zone, &stack_byte) != 0 || malloc_zone_from_ptr(&stack_byte) != NULL) {
    fprintf(stderr, "a stack address was claimed\n");
    bad = 1;
  }
  if (!bad) printf("ok\n");
  return bad;
}
