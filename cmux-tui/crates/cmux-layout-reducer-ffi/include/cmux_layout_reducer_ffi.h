#ifndef CMUX_LAYOUT_REDUCER_FFI_H
#define CMUX_LAYOUT_REDUCER_FFI_H

#include <stddef.h>
#include <stdint.h>

enum {
    CMUX_LAYOUT_REDUCER_OK = 0,
    CMUX_LAYOUT_REDUCER_ERR_NULL = -1,
    CMUX_LAYOUT_REDUCER_ERR_INVALID = -2,
    CMUX_LAYOUT_REDUCER_ERR_BUFFER = -3,
    CMUX_LAYOUT_REDUCER_ERR_PANIC = -4,
};

uint32_t cmux_layout_reducer_ffi_abi_version(void);
int32_t cmux_layout_reducer_json(
    const uint8_t *request,
    size_t request_len,
    const char *operation,
    uint8_t *output,
    size_t output_capacity,
    size_t *output_len);

/*
 * The sidebar document mirror (sidebar-doc-v1). One handle per client, used
 * from one thread. Every call takes UTF-8 JSON (`json`, `json_len`) and
 * returns a newly allocated NUL-terminated JSON string, which the caller
 * frees with cmux_sidebar_mirror_string_free; null only for a null handle or
 * a null input pointer with a non-zero length. A malformed input answers
 * {"error": "..."}.
 *
 *   load(doc)            the sidebar.get result -> {"ok":true,"revision":"N","dropped":[key]}
 *   apply_batch(batch)   {revision, previous_revision?, idempotency_key?, changes:[...]}
 *                        or {idempotency_key, rejected:true}
 *                        -> {"ok":true,...} | {"refetch":true}
 *   apply_intent(intent) {idempotency_key, ops:[op]} -> {"ok":true,"ops":[op],"inverse":[op]} | {"refusal":"code"}
 *                        (ops carry the ids the mirror minted for added items; send those)
 *   view(request)        {live, window, filter?, collapsed?} -> [row]
 *                        row = {key, kind, section, parent?, depth, item?, dimmed, ref?, collapsed?}
 *   drag_begin(items)    {items:[id]} -> {row_key:{before,into,after,refusal?}}
 */
typedef struct CmuxSidebarMirror CmuxSidebarMirror;

CmuxSidebarMirror *cmux_sidebar_mirror_new(void);
void cmux_sidebar_mirror_free(CmuxSidebarMirror *mirror);
void cmux_sidebar_mirror_string_free(char *text);
char *cmux_sidebar_mirror_load(CmuxSidebarMirror *mirror, const uint8_t *json, size_t json_len);
char *cmux_sidebar_mirror_apply_batch(CmuxSidebarMirror *mirror, const uint8_t *json, size_t json_len);
char *cmux_sidebar_mirror_apply_intent(CmuxSidebarMirror *mirror, const uint8_t *json, size_t json_len);
char *cmux_sidebar_mirror_view(CmuxSidebarMirror *mirror, const uint8_t *json, size_t json_len);
char *cmux_sidebar_mirror_drag_begin(CmuxSidebarMirror *mirror, const uint8_t *json, size_t json_len);

#endif
