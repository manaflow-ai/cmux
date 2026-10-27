// First-hit function PCs for an order file (the trace-pc-guard fallback). Not instrumented itself.
#include <mach-o/dyld.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

static FILE *trace_out;

void __sanitizer_cov_trace_pc_guard_init(uint32_t *start, uint32_t *stop) {
  static uint32_t next;
  if (start == stop || *start) return;
  for (uint32_t *guard = start; guard < stop; guard++) *guard = ++next;
}

void __sanitizer_cov_trace_pc_guard(uint32_t *guard) {
  if (!*guard) return;
  *guard = 0;
  if (!trace_out) {
    const char *path = getenv("CMUX_PGO_TRACE_FILE");
    trace_out = fopen(path ? path : "/dev/null", "w");
    if (!trace_out) return;
  }
  uintptr_t pc = (uintptr_t)__builtin_return_address(0) - (uintptr_t)_dyld_get_image_vmaddr_slide(0);
  fprintf(trace_out, "0x%lx\n", (unsigned long)pc);
  fflush(trace_out);
}
