// Does malloc_zone_pressure_relief give back the free-but-dirty part of a fragmented default zone?
// cmuxterm-hq goals/ram-baseline.md: the idle app's DefaultMallocZone is 34.7 MB dirty, 45% fragmented
// (about 15 MB of freed blocks whose pages malloc keeps). This probe builds a default-zone heap of that
// shape (Swift/ObjC-sized blocks, 16 B to 4 KB, about 60 MB), frees a share of it, and then calls
// malloc_zone_pressure_relief(NULL, 0), and per zone with a goal, reading phys_footprint and the zone's
// statistics before and after each call.
//
// Free patterns: random (every block has the same chance) and runs (whole consecutive runs of 64 blocks,
// as launch-time temporaries freed together leave whole free pages behind).
//
// Build and run: clang -O2 -o /tmp/relief relief.c && /tmp/relief random 45 && /tmp/relief runs 45
// Compare with MallocSpaceEfficient=1 /tmp/relief random 45 (malloc reads it at exec).
// Prints one RELIEF line per step; exit 0 always (a measurement, not a test).
#include <mach/mach.h>
#include <malloc/malloc.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static double footprint_mb(void) {
  task_vm_info_data_t info;
  mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
  if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) return -1;
  return info.phys_footprint / 1048576.0;
}

static void report(const char* step, size_t released) {
  malloc_statistics_t st;
  malloc_zone_statistics(malloc_default_zone(), &st);
  printf("RELIEF step=%s footprint_mb=%.1f zone_in_use_mb=%.1f zone_allocated_mb=%.1f released_bytes=%zu\n", step,
         footprint_mb(), st.size_in_use / 1048576.0, st.size_allocated / 1048576.0, released);
  fflush(stdout);
}

static void vmmap_line(const char* step) {
  char cmd[160];
  snprintf(cmd, sizeof cmd, "vmmap --summary %d 2>/dev/null | grep -E 'DefaultMallocZone|TOTAL' | sed 's/^/VMMAP %s /'",
           getpid(), step);
  system(cmd);
}

int main(int argc, char** argv) {
  const char* pattern = argc > 1 ? argv[1] : "random";
  int percent = argc > 2 ? atoi(argv[2]) : 45;
  enum { COUNT = 400000 };
  void** blocks = calloc(COUNT, sizeof(void*));
  srand(571);
  report("start", 0);
  for (unsigned i = 0; i < COUNT; i++) {
    // Mostly tiny (Swift objects, strings, arrays), some small (buffers): mean about 150 B.
    unsigned r = (unsigned)rand() % 100;
    size_t size = r < 70 ? 16 + (rand() % 112) : r < 95 ? 128 + (rand() % 896) : 1024 + (rand() % 3072);
    blocks[i] = malloc(size);
    memset(blocks[i], 0xA5, size);
  }
  report("allocated", 0);
  for (unsigned i = 0; i < COUNT; i++) {
    int drop = strcmp(pattern, "runs") == 0 ? (int)((i / 64) * 2654435761u % 100) < percent : rand() % 100 < percent;
    if (drop) {
      free(blocks[i]);
      blocks[i] = NULL;
    }
  }
  sleep(1);
  report("freed", 0);
  vmmap_line("freed");
  size_t all = malloc_zone_pressure_relief(NULL, 0);
  sleep(2);
  report("relief_all", all);
  vmmap_line("relief_all");
  size_t one = malloc_zone_pressure_relief(malloc_default_zone(), 64u << 20);
  sleep(2);
  report("relief_default_goal64m", one);
  vmmap_line("relief_default_goal64m");
  vm_address_t* zones = NULL;
  unsigned zone_count = 0;
  size_t each = 0;
  if (malloc_get_all_zones(mach_task_self(), NULL, &zones, &zone_count) == KERN_SUCCESS)
    for (unsigned z = 0; z < zone_count; z++) each += malloc_zone_pressure_relief((malloc_zone_t*)zones[z], 0);
  sleep(2);
  report("relief_each_zone", each);
  vmmap_line("relief_each_zone");
  printf("RELIEF pattern=%s percent=%d zones=%u space_efficient=%s\n", pattern, percent, zone_count,
         getenv("MallocSpaceEfficient") ? getenv("MallocSpaceEfficient") : "unset");
  return 0;
}
