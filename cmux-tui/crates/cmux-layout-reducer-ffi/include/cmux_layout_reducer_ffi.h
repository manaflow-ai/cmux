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
#define CMUX_SIDEBAR_ROW_ARCHIVED 4u
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

/*
 * The window focus machine (cmux-focus-core). One handle per window, used
 * from one thread; it owns the focus state. Send small typed events, and a
 * topology only when it changed. Each call returns a reply the handle owns,
 * valid until the next cmux_focus_* call on that handle; never free it.
 * Strings: a CmuxFocusStr is a byte range into the call's `strings` (in a
 * reply, into reply->strings); offset CMUX_FOCUS_NONE means absent. UTF-8,
 * not NUL-terminated. A reply with ok 0: the request did not decode (the
 * state is unchanged), or the reduction failed part way (the fields show
 * the state as it is now, no effects). changed 0: the focus is as in the
 * previous reply and its fields still hold; read effects either way. The
 * focus history and remembered panes are not in the reply: read them with
 * cmux_focus_recent_panes / cmux_focus_remembered when needed.
 */
#define CMUX_FOCUS_NONE UINT32_MAX

/* CmuxFocusEvent.kind */
#define CMUX_FOCUS_EVENT_FOCUS_PANE 0u        /* a pane, c workspace?, source */
#define CMUX_FOCUS_EVENT_SELECT_TAB 1u        /* a pane, b tab, c workspace?, source */
#define CMUX_FOCUS_EVENT_FOCUS_TARGET 2u      /* target, target_keyboard, source */
#define CMUX_FOCUS_EVENT_RESPONDER 3u         /* value responder, a pane (pane kinds), source */
#define CMUX_FOCUS_EVENT_WINDOW_KEY 4u        /* value bool */
#define CMUX_FOCUS_EVENT_APP_ACTIVE 5u        /* value bool */
#define CMUX_FOCUS_EVENT_OVERLAY_OPENED 6u    /* value overlay */
#define CMUX_FOCUS_EVENT_OVERLAY_CLOSED 7u    /* value overlay */
#define CMUX_FOCUS_EVENT_BEGIN_INTENT 8u
#define CMUX_FOCUS_EVENT_EXPECT 9u            /* value 0 surface 1 tab, a id, target, b awayFrom?, generation */
#define CMUX_FOCUS_EVENT_DRAG_BEGAN 10u       /* list tabs, a pane */
#define CMUX_FOCUS_EVENT_DRAG_ENDED 11u       /* value 0 cancelled 1 dropped 2 moved away; dropped: list tabs, b awayFrom? */
#define CMUX_FOCUS_EVENT_CONTENT_PRESENTED 12u /* a pane */
#define CMUX_FOCUS_EVENT_TOGGLE_BROWSER_FOCUS_MODE 13u /* a tab? */
#define CMUX_FOCUS_EVENT_SIDEBAR_VISIBILITY 14u /* value hidden */
#define CMUX_FOCUS_EVENT_RESTORED_PANE 15u    /* a pane, c workspace */
/* source: 0 mouse 1 keyboard 2 cli 3 palette 4 programmatic
 * target: 0 content 1 addressBar 2 findBar 3 devTools 4 sidebar(target_keyboard) 5 sidebarField 6 textField 7 none
 * responder: 0 content 1 addressBar 2 findBar 3 devTools 4 sidebar 5 sidebarField 6 textField 7 windowOrNone
 * overlay: 0 palette 1 sheet 2 rename 3 groupEditor
 * tab kind: 0 terminal 1 browser 2 agent 3 page 4 conversation 5 other
 * resolved: 0 terminal 1 browserPage 2 addressBar 3 findBar 4 devTools 5 agentPage 6 page
 *           7 conversation 8 emptyPane 9 sidebar 10 sidebarField 11 textField 12 overlay 13 none
 * effect: 0 select(pane, tab) 1 revealPane(pane) 2 moveResponder(resolved)
 *         3 publishContext(context) 4 browserFocusMode(tab, active)
 * context bits: 1 terminal 2 browser 4 agent */

typedef struct CmuxFocus CmuxFocus;

typedef struct CmuxFocusStr {
    uint32_t offset;
    uint32_t len;
} CmuxFocusStr;

typedef struct CmuxFocusEvent {
    uint8_t kind;
    uint8_t source;
    uint8_t target;
    uint8_t target_keyboard;
    uint8_t value;
    uint8_t reserved[3];
    uint32_t list_count;
    uint32_t reserved2;
    uint64_t generation;
    CmuxFocusStr a;
    CmuxFocusStr b;
    CmuxFocusStr c;
    const CmuxFocusStr *list;
} CmuxFocusEvent;

typedef struct CmuxFocusTab {
    CmuxFocusStr id;
    CmuxFocusStr surface;
    uint32_t kind;
    uint32_t reserved;
} CmuxFocusTab;

typedef struct CmuxFocusPane {
    CmuxFocusStr id;
    CmuxFocusStr selected;
    uint32_t tab_start; /* index into tabs */
    uint32_t tab_count;
} CmuxFocusPane;

typedef struct CmuxFocusColumn {
    CmuxFocusStr id;
    uint32_t screen;     /* < screen_count; columns of a screen in visual order */
    uint32_t pane_start; /* index into column_panes */
    uint32_t pane_count;
    uint32_t reserved;
} CmuxFocusColumn;

typedef struct CmuxFocusTopology {
    CmuxFocusStr workspace;
    const CmuxFocusPane *panes;
    const CmuxFocusTab *tabs;
    const CmuxFocusColumn *columns;
    const CmuxFocusStr *column_panes;
    uint32_t pane_count;
    uint32_t tab_count;
    uint32_t column_count;
    uint32_t column_pane_count;
    uint32_t screen_count;
    uint32_t reserved;
} CmuxFocusTopology;

typedef struct CmuxFocusResolved {
    uint8_t kind;
    uint8_t overlay;
    uint8_t reserved[6];
    CmuxFocusStr pane;
    CmuxFocusStr tab;
} CmuxFocusResolved;

typedef struct CmuxFocusEffect {
    uint8_t kind;
    uint8_t context;
    uint8_t active;
    uint8_t reserved[5];
    CmuxFocusStr pane;
    CmuxFocusStr tab;
    CmuxFocusResolved resolved;
} CmuxFocusEffect;

typedef struct CmuxFocusReply {
    uint8_t ok;
    uint8_t changed;
    uint8_t window_key;
    uint8_t app_active;
    uint8_t sidebar_hidden;
    uint8_t target;
    uint8_t target_keyboard;
    uint8_t context;
    uint8_t browser_focus_mode_active;
    uint8_t dragging;
    uint8_t has_expectation;
    uint8_t expectation_key; /* 0 surface 1 tab */
    uint8_t expectation_target;
    uint8_t expectation_target_keyboard;
    uint8_t reserved[2];
    uint64_t generation;
    uint64_t expectation_generation;
    CmuxFocusStr pane;
    CmuxFocusStr workspace;
    CmuxFocusStr expectation_id;
    CmuxFocusStr expectation_away_from;
    CmuxFocusResolved resolved;
    CmuxFocusResolved underlying;
    const uint8_t *overlays; /* overlay codes, bottom first */
    const CmuxFocusEffect *effects;
    const uint8_t *strings;
    uint32_t overlay_count;
    uint32_t effect_count;
    uint32_t strings_len;
    uint32_t reserved2;
} CmuxFocusReply;

typedef struct CmuxFocusStrings {
    const CmuxFocusStr *items;
    const uint8_t *bytes;
    uint32_t count;
    uint32_t bytes_len;
} CmuxFocusStrings;

CmuxFocus *cmux_focus_new(void);
void cmux_focus_free(CmuxFocus *focus);
const CmuxFocusReply *cmux_focus_send(CmuxFocus *focus, const CmuxFocusEvent *event, const uint8_t *strings, size_t strings_len);
const CmuxFocusReply *cmux_focus_set_topology(CmuxFocus *focus, const CmuxFocusTopology *topology, const uint8_t *strings, size_t strings_len);
const CmuxFocusReply *cmux_focus_current(CmuxFocus *focus);
void cmux_focus_set_close_focus(CmuxFocus *focus, uint8_t policy); /* 0 previous neighbor, 1 most recent */
uint8_t cmux_focus_changes_view(const CmuxFocusEvent *event, const uint8_t *strings, size_t strings_len);
/* newest first; has_workspace 0: the shown workspace */
const CmuxFocusStrings *cmux_focus_recent_panes(CmuxFocus *focus, const uint8_t *workspace, size_t workspace_len, uint8_t has_workspace);
/* workspace, pane, workspace, pane, ...: the last focused pane per workspace */
const CmuxFocusStrings *cmux_focus_remembered(CmuxFocus *focus);
/* Journal checkpoints and replay only, never per event. */
char *cmux_focus_export_json(CmuxFocus *focus);
int32_t cmux_focus_import_json(CmuxFocus *focus, const uint8_t *json, size_t json_len);
void cmux_focus_string_free(char *text);

#endif
