// malloc-zones PID: the malloc zones of another process, in registration order, as one JSON line
// {"pid": N, "zones": ["DefaultMallocZone", ...]}. zones[0] is the default zone: the one malloc()
// uses. vm.sh --diag compiles it on the Tart host and runs it in the guest (diag.py) to prove a
// Chromium-off run never had PartitionAlloc's zone. Errors: {"pid": N, "error": "..."}, exit 1.
//
// The remote read is the one heap(1) and vmmap(1) use: malloc_get_all_zones with a memory reader
// over the target's task port. libmalloc reads its zone table at the address it has in this
// process, which is the target's too (the shared cache maps at one address per boot).
// task_for_pid needs root: diag.py runs it with sudo -n first.
#include <mach/mach.h>
#include <mach/mach_error.h>
#include <mach/mach_vm.h>
#include <malloc/malloc.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static kern_return_t read_remote(task_t task, vm_address_t address, vm_size_t size, void** local) {
  void* buffer = malloc(size ? size : 1);
  if (!buffer) return KERN_RESOURCE_SHORTAGE;
  mach_vm_size_t got = 0;
  kern_return_t kr = mach_vm_read_overwrite(task, address, size, (mach_vm_address_t)buffer, &got);
  if (kr != KERN_SUCCESS || got != size) {
    free(buffer);
    return kr != KERN_SUCCESS ? kr : KERN_FAILURE;
  }
  *local = buffer;  // one short run: never freed
  return KERN_SUCCESS;
}

// The NUL-terminated string at `address` in `task`, at most `cap - 1` bytes, read a page at a time
// so a name near the end of a mapping does not fail the read.
static int read_string(task_t task, vm_address_t address, char* out, size_t cap) {
  size_t n = 0;
  while (n + 1 < cap) {
    vm_address_t at = address + n;
    size_t page_left = vm_page_size - (at % vm_page_size);
    size_t want = page_left < cap - 1 - n ? page_left : cap - 1 - n;
    void* chunk = NULL;
    if (read_remote(task, at, want, &chunk) != KERN_SUCCESS) return 0;
    char* end = memchr(chunk, 0, want);
    size_t take = end ? (size_t)(end - (char*)chunk) : want;
    memcpy(out + n, chunk, take);
    n += take;
    if (end) break;
  }
  out[n] = 0;
  return 1;
}

static void print_json_string(const char* s) {
  putchar('"');
  for (; *s; s++) {
    unsigned char c = (unsigned char)*s;
    if (c == '"' || c == '\\') printf("\\%c", c);
    else if (c < 0x20 || c > 0x7e) printf("\\u%04x", c);  // names are ASCII; anything else escaped
    else putchar(c);
  }
  putchar('"');
}

int main(int argc, char** argv) {
  if (argc != 2) {
    fprintf(stderr, "usage: malloc-zones PID\n");
    return 2;
  }
  int pid = atoi(argv[1]);
  task_t task = MACH_PORT_NULL;
  kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
  if (kr != KERN_SUCCESS) {
    printf("{\"pid\": %d, \"error\": \"task_for_pid: %s\"}\n", pid, mach_error_string(kr));
    return 1;
  }
  vm_address_t* zones = NULL;
  unsigned count = 0;
  kr = malloc_get_all_zones(task, read_remote, &zones, &count);
  if (kr != KERN_SUCCESS) {
    printf("{\"pid\": %d, \"error\": \"malloc_get_all_zones: %s\"}\n", pid, mach_error_string(kr));
    return 1;
  }
  printf("{\"pid\": %d, \"zones\": [", pid);
  for (unsigned i = 0; i < count; i++) {
    char name[256] = "?";
    void* zone = NULL;
    // Only up to the name: an older zone version is a shorter struct.
    vm_size_t prefix = offsetof(malloc_zone_t, zone_name) + sizeof(const char*);
    if (read_remote(task, zones[i], prefix, &zone) == KERN_SUCCESS) {
      const char* remote_name = ((malloc_zone_t*)zone)->zone_name;
      if (!remote_name) strcpy(name, "");
      else if (!read_string(task, (vm_address_t)remote_name, name, sizeof name)) strcpy(name, "?");
    }
    if (i) printf(", ");
    print_json_string(name);
  }
  printf("]}\n");
  return 0;
}
