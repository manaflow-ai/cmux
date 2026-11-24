#ifndef CMUX_LAYOUT_CACHE_H
#define CMUX_LAYOUT_CACHE_H
/* Every window's last computed layout, kept across restarts so a launch draws it already placed
 * (cmux-tui/crates/cmux-layout-cache, src/ffi.rs). Values cross as JSON; free every returned
 * string with cmux_layout_cache_string_free. cmux-app-ffi/tests/layout_cache_header.rs checks the
 * exports. */
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

/* The write coalescer: 250 ms trailing debounce, at most 2 s; one thread at a time. */
typedef struct CmuxLayoutCacheCoalescer CmuxLayoutCacheCoalescer;

void cmux_layout_cache_string_free(char *s);
/* <state_dir>/layout-cache/v1.json, or NULL. */
char *cmux_layout_cache_path(const char *state_dir);
/* The cache at path as JSON, or NULL (missing, over 512 KiB, another version, garbage). */
char *cmux_layout_cache_read(const char *path);
/* Atomic write of a LayoutCache JSON: 0 written, -1 bad input, -2 write failed (old file kept). */
int32_t cmux_layout_cache_write(const char *path, const char *json);
/* Usable JSON {windows, frames, content, reasons} for now_json {build_key, displays, now_ms}. */
char *cmux_layout_cache_usable(const char *cache_json, const char *now_json);
/* Applied JSON {node, transitions, moved} for a cached PaneNode and a LiveTree
 * {panes, root?, bounds?, divider}. */
char *cmux_layout_cache_reconcile(const char *cached_node_json, const char *live_json);
/* StripApplied JSON {tabs, changes} from [{id, x, width}] and the live ids ["id", ...]. */
char *cmux_layout_cache_reconcile_strip(const char *cached_json, const char *live_ids_json, double default_width);
/* RowsApplied JSON {rows, added, removed} from [{id, height}] and the live ids. */
char *cmux_layout_cache_reconcile_rows(const char *cached_json, const char *live_ids_json, double default_height);
/* Layout shift between [{id, x, y, width, height}] sets in viewport {x, y, width, height}: 0 when
 * nothing moved, -1 for bad input. */
double cmux_layout_cache_shift_score(const char *before_json, const char *after_json, const char *viewport_json);
/* Ms more the real launch window waits under stage 0; 0 swaps now. kind: 0 image (400 ms bound),
 * 1 plain (150 ms), 2 bare (1500 ms). Now when ready >= visible. */
uint64_t cmux_layout_cache_swap_wait_ms(uint8_t kind, uint32_t visible, uint32_t ready, uint64_t elapsed_ms);

CmuxLayoutCacheCoalescer *cmux_layout_cache_coalescer_new(void);
void cmux_layout_cache_coalescer_free(CmuxLayoutCacheCoalescer *c);
void cmux_layout_cache_coalescer_note(CmuxLayoutCacheCoalescer *c, uint64_t now_ms);
bool cmux_layout_cache_coalescer_due(CmuxLayoutCacheCoalescer *c, uint64_t now_ms);
/* When the pending change is due; -1 when nothing is pending. */
int64_t cmux_layout_cache_coalescer_next_due_ms(CmuxLayoutCacheCoalescer *c);
/* At quit: whether anything is pending. */
bool cmux_layout_cache_coalescer_flush_now(CmuxLayoutCacheCoalescer *c);
/* Writes unless the content equals the last write: 1 written, 0 unchanged, -1 bad input,
 * -2 write failed (still pending). */
int32_t cmux_layout_cache_coalescer_write(CmuxLayoutCacheCoalescer *c, const char *path, const char *json);
/* Records a write made through cmux_layout_cache_write; false for bad input. */
bool cmux_layout_cache_coalescer_wrote(CmuxLayoutCacheCoalescer *c, const char *json);

#ifdef __cplusplus
}
#endif
#endif
