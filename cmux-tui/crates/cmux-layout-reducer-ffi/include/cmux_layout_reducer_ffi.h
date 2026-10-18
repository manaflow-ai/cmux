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

/*
 * Typed replies (bead cx-x5jpp): the same calls, read with no JSON decode.
 * Each returns a pointer to a reply the mirror owns. It stays valid until the
 * next *_typed call on the same mirror or cmux_sidebar_mirror_free; never free
 * it. Null for a null handle, a null input pointer with a non-zero length, or
 * a panic. String fields are indexes into the reply's string table
 * (CMUX_SIDEBAR_NONE for an absent field); string i is UTF-8 bytes
 * bytes[offsets[i] ..< offsets[i + 1]], not NUL-terminated.
 */
#define CMUX_SIDEBAR_NONE UINT32_MAX
#define CMUX_SIDEBAR_ROW_DIMMED 1u
#define CMUX_SIDEBAR_ROW_COLLAPSED 2u
#define CMUX_SIDEBAR_ACCEPT_BEFORE 1u
#define CMUX_SIDEBAR_ACCEPT_INTO 2u
#define CMUX_SIDEBAR_ACCEPT_AFTER 4u

typedef struct CmuxSidebarStrings {
    const uint8_t *bytes;
    const uint32_t *offsets; /* count + 1 entries */
    uint32_t count;
} CmuxSidebarStrings;

typedef struct CmuxSidebarRow {
    uint32_t key;
    uint32_t kind;
    uint32_t section;
    uint32_t parent;
    uint32_t item;
    uint32_t ref_session;
    uint32_t ref_workspace;
    uint8_t depth;
    uint8_t flags; /* CMUX_SIDEBAR_ROW_* */
    uint16_t reserved;
} CmuxSidebarRow;

typedef struct CmuxSidebarRows {
    uint8_t ok; /* 0: the request could not be read */
    const CmuxSidebarRow *rows;
    uint32_t row_count;
    CmuxSidebarStrings strings;
} CmuxSidebarRows;

typedef struct CmuxSidebarAcceptance {
    uint32_t key;
    uint32_t refusal;
    uint8_t flags; /* CMUX_SIDEBAR_ACCEPT_* */
    uint8_t reserved[3];
} CmuxSidebarAcceptance;

typedef struct CmuxSidebarAcceptanceTable {
    uint8_t ok;
    const CmuxSidebarAcceptance *entries;
    uint32_t count;
    CmuxSidebarStrings strings;
} CmuxSidebarAcceptanceTable;

/* The JSON reply's ok, stale, refetch, revision and refusal (or "error");
 * ops = apply_intent's stamped ops as a JSON array (bytes to send on). */
typedef struct CmuxSidebarReply {
    uint8_t ok;
    uint8_t stale;
    uint8_t refetch;
    uint8_t has_revision;
    uint64_t revision;
    const uint8_t *refusal;
    size_t refusal_len;
    const uint8_t *ops;
    size_t ops_len;
} CmuxSidebarReply;

const CmuxSidebarReply *cmux_sidebar_mirror_load_typed(CmuxSidebarMirror *mirror, const uint8_t *json, size_t json_len);
const CmuxSidebarReply *cmux_sidebar_mirror_apply_batch_typed(CmuxSidebarMirror *mirror, const uint8_t *json, size_t json_len);
const CmuxSidebarReply *cmux_sidebar_mirror_apply_intent_typed(CmuxSidebarMirror *mirror, const uint8_t *json, size_t json_len);
const CmuxSidebarRows *cmux_sidebar_mirror_view_typed(CmuxSidebarMirror *mirror, const uint8_t *json, size_t json_len);
const CmuxSidebarAcceptanceTable *cmux_sidebar_mirror_drag_begin_typed(CmuxSidebarMirror *mirror, const uint8_t *json, size_t json_len);

#endif
