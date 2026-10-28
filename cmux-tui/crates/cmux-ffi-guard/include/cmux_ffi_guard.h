#ifndef CMUX_FFI_GUARD_H
#define CMUX_FFI_GUARD_H

#include <stdbool.h>
#include <stdint.h>

/* The panic records of the in-app Rust C ABIs (cmux-tui/crates/cmux-ffi-guard).
 * Every export of CCmuxAppFFI catches a Rust panic, returns its documented
 * error value and stores the panic in a fixed ring of 16 records; the newest
 * overwrite the oldest. The app drains the ring and forwards each record to
 * crash reporting. Any thread may call these functions; they never block. */

#ifdef __cplusplus
extern "C" {
#endif

#define CMUX_FFI_PANIC_NAME_CAP 64
#define CMUX_FFI_PANIC_MESSAGE_CAP 256

/* One stored panic. `name` (the export) and `message` are UTF-8 of `name_len`
 * and `message_len` bytes, not NUL-terminated. `sequence` is 1 for the
 * process's first panic, then one more per panic: a gap between two records
 * counts the panics the ring lost. `truncated` when the message was cut. */
typedef struct CmuxFfiPanic {
    uint64_t sequence;
    uint32_t name_len;
    uint32_t message_len;
    bool truncated;
    uint8_t name[CMUX_FFI_PANIC_NAME_CAP];
    uint8_t message[CMUX_FFI_PANIC_MESSAGE_CAP];
} CmuxFfiPanic;

/* Moves the oldest stored panic into `*out`: 1 when filled, 0 when none is
 * stored, -1 for a NULL `out`. */
int32_t cmux_ffi_take_panic(CmuxFfiPanic *out);
/* Panics caught since the process started, lost ones included. */
uint64_t cmux_ffi_panic_count(void);

#ifdef __cplusplus
}
#endif

#endif
