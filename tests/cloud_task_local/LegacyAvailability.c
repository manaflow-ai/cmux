#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdatomic.h>

// Linked ONLY into the standalone test executable. Select the TaskLocal
// back-deployment path on modern CI hosts without changing the installed OS,
// app, Swift runtime, or the task allocator that diagnoses the real defect.
static atomic_uint legacy_checks;

bool task_local_test_availability(uintptr_t major, uintptr_t minor, uintptr_t patch,
                                 uintptr_t variant_major, uintptr_t variant_minor,
                                 uintptr_t variant_patch)
    __asm__("_$ss042_stdlib_isOSVersionAtLeastOrVariantVersiondE0yBi1_Bw_BwBwBwBwBwtF")
    __attribute__((swiftcall));

bool task_local_test_availability(uintptr_t major, uintptr_t minor, uintptr_t patch,
                                 uintptr_t variant_major, uintptr_t variant_minor,
                                 uintptr_t variant_patch) {
    (void)minor; (void)patch;
    (void)variant_major; (void)variant_minor; (void)variant_patch;
    if (getenv("CMUX_TEST_LEGACY_TASK_LOCAL") && major == 15) {
        if (atomic_fetch_add(&legacy_checks, 1) == 0) {
            fputs("TaskLocal: selected macOS 14 fallback\n", stderr);
        }
        return false;
    }
    // The harness targets macOS 14, runs on macOS 15+, and uses no APIs newer
    // than 15. Reject future checks instead of claiming every API is available.
    return major <= 15;
}

unsigned task_local_test_legacy_checks(void) {
    return atomic_load(&legacy_checks);
}
