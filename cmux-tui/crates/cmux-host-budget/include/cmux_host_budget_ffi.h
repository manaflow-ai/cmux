#ifndef CMUX_HOST_BUDGET_FFI_H
#define CMUX_HOST_BUDGET_FFI_H

/* cmux-host-budget's C ABI (cmux-tui/crates/cmux-host-budget/src/ffi.rs),
 * linked into the app through cmux-app-ffi:
 * the host CPU/RAM budget (cmuxterm-hq#2995) that acpmux's daemon also uses.
 * Verdicts are UTF-8 JSON in acpmux's `host_pressure` shape: pointer and
 * length in, a NUL-terminated string out that the caller frees with
 * cmux_host_budget_string_free. Levels: 0 normal, 1 warning, 2 critical.
 * No call panics across the boundary. ABI version 1. */

#include <stddef.h>
#include <stdint.h>

typedef struct CmuxHostPressureTracker CmuxHostPressureTracker;

uint32_t cmux_host_budget_ffi_abi_version(void);

/* This Mac's verdict now, from the process's one meter. Blocking (sysctl,
 * host_statistics64, the override file): never on the main thread. NULL while
 * another read is in flight. */
char *cmux_host_budget_local_verdict_json(void);

/* `verdict` judged again with memory pressure `level` (1 normal, 2 warn,
 * 4 critical: DISPATCH_MEMORYPRESSURE_*). NULL when it is not a verdict. */
char *cmux_host_budget_with_pressure_json(const uint8_t *verdict, size_t verdict_len, uint32_t level);

/* The verdict for given numbers with the built-in formula:
 * {"host", "sample": {...}, "swap_mb_per_min"}. NULL for a bad input. */
char *cmux_host_budget_judge_json(const uint8_t *input, size_t input_len);

void cmux_host_budget_string_free(char *text);

/* The level `verdict` alone calls for while the app shows `holding`;
 * -2 when it is not a verdict or `holding` is not a level. */
int32_t cmux_host_pressure_level_for(const uint8_t *verdict, size_t verdict_len, int32_t holding);

/* A tracker at normal that falls after `calm_samples` (at least 1) calm
 * verdicts in a row. One thread at a time. */
CmuxHostPressureTracker *cmux_host_pressure_tracker_new(uint32_t calm_samples);
void cmux_host_pressure_tracker_free(CmuxHostPressureTracker *tracker);
/* -2 for NULL. */
int32_t cmux_host_pressure_tracker_level(const CmuxHostPressureTracker *tracker);
/* The new level when it changed, -1 when it did not, -2 when the input is
 * not a verdict (the tracker is unchanged). */
int32_t cmux_host_pressure_tracker_feed(CmuxHostPressureTracker *tracker, const uint8_t *verdict, size_t verdict_len);

#endif
