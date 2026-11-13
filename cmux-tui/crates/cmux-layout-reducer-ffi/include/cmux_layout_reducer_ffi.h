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

/* Tab drag rules (cmux NEXT TabMoveIndex and DropRevealPolicy).  Tab ids are
 * caller-owned UInt32 values; arrays are read for the duration of the call.
 * A non-zero boolean is true.  Index functions return -1 for a null pointer
 * paired with a non-zero count. */
int64_t cmux_tab_move_wire_index(
    int64_t final_index,
    uint8_t has_current_index,
    int64_t current_index);
int64_t cmux_tab_move_pane_final_index(
    const uint32_t *display,
    size_t display_len,
    uint32_t moving,
    int64_t display_index,
    const uint32_t *pane,
    size_t pane_len);
int64_t cmux_tab_move_group_index(
    const uint32_t *display,
    size_t display_len,
    const uint32_t *members,
    size_t members_len,
    uint32_t moving,
    int64_t display_index);

enum {
    CMUX_DROP_REVEAL_NONE = 0,
    CMUX_DROP_REVEAL_FOCUSES_TAB = 1,
    CMUX_DROP_REVEAL_SHOWS_WORKSPACE = 2,
    CMUX_DROP_REVEAL_MAKES_KEY = 4,
};
/* outcome values mirror TabDragOutcome: cancel 0, strip 1, newSplit 2,
 * newColumn 3, newDock 4, newWorkspace 5, workspace 6, tearOff 7,
 * moveWindow 8, moveWorkspaceToNewWindow 9, moveWorkspace 10. */
uint8_t cmux_drop_reveal_decide(
    uint8_t outcome,
    uint8_t landed,
    uint8_t user_initiated,
    uint8_t focus_requested,
    uint8_t files_away,
    uint8_t crosses_windows,
    uint8_t app_active,
    uint8_t no_activate,
    uint8_t landing_on_active_space);

/* Tab/pane edge mapping values mirror the public Swift enums.  The four
 * edges are stable codes 0...3; NONE (255) is returned for an optional
 * center edge or an invalid input.  PaneDropZone center is 4, and the split
 * axes are horizontal 0 and vertical 1. */
enum {
    CMUX_TAB_DROP_EDGE_LEFT = 0,
    CMUX_TAB_DROP_EDGE_RIGHT = 1,
    CMUX_TAB_DROP_EDGE_TOP = 2,
    CMUX_TAB_DROP_EDGE_BOTTOM = 3,
    CMUX_TAB_DROP_EDGE_NONE = 255,
    CMUX_PANE_DROP_ZONE_LEFT = 0,
    CMUX_PANE_DROP_ZONE_RIGHT = 1,
    CMUX_PANE_DROP_ZONE_TOP = 2,
    CMUX_PANE_DROP_ZONE_BOTTOM = 3,
    CMUX_PANE_DROP_ZONE_CENTER = 4,
    CMUX_PANE_DROP_ZONE_NONE = 255,
    CMUX_SPLIT_AXIS_HORIZONTAL = 0,
    CMUX_SPLIT_AXIS_VERTICAL = 1,
    CMUX_SPLIT_AXIS_NONE = 255,
};
uint8_t cmux_pane_drop_zone_edge(uint8_t zone);
uint8_t cmux_tab_drop_edge_pane_edge(uint8_t edge);
uint8_t cmux_pane_edge_opposite(uint8_t edge);
uint8_t cmux_pane_edge_drop_zone(uint8_t edge);
uint8_t cmux_pane_edge_split_axis(uint8_t edge);
/* The store's optimistic overlay rules, operation "optimistic" of
 * cmux_layout_reducer_json (cmux-layout-reducer optimistic.rs). One request
 * tagged by "op"; the answer is the view the pending intent shows, or null
 * when it shows nothing:
 *   split              {screen, target, dir, ratio, leaf, split_id, column?, row?} -> {layout, columns, pane_at}
 *   dock               {screen, leaf, column, dock} -> {layout, columns}
 *   remove_pane        {screen, pane} -> {layout, columns}
 *   move_tab           {same_pane, from, index, target_count} -> {final}
 *   place_workspace    {groups, from, kind, group?, index?} -> {index}
 *   row_heights        {rows, heights} -> {heights}
 *   daemon_move_index  {visible, moving, index, held} -> {final, current}
 * Layout nodes and columns use the daemon's wire shapes. Called per intent
 * apply and overlay restore, never per frame. */
/* The sidebar's launch order hold, operation "sidebar_launch_order" of
 * cmux_layout_reducer_json (cmux-layout-reducer sidebar_launch_order.rs): until
 * the home owner serves, rows keep the order drawn at launch.
 *   {hold, lists:[{key, reference?, next}]} -> {lists:[{key, order, reference, moved}]}
 * Called once per structural sidebar pass while the hold is on, once at its end. */
/* New > Kind > Placement, operation "new_placement" of cmux_layout_reducer_json
 * (cmux-layout-reducer new_placement.rs): open a terminal, browser, agent chat
 * or New Tab Page at one of the fork's ten places.
 *   {kind, placement, tabSplit?} -> {op, edge?, left?, make}
 * op is split (edge right|left|top|bottom), column (left), row, tab,
 * workspace or window; make is in_place or made_then_moved. Called once per
 * New action run. */
/* Focus operations of cmux_layout_reducer_json (cmux-focus-core wire.rs):
 *   focus_input_world   InputObservation -> {violations:[{invariant,window?,detail}], unsettled:[window]}
 *   focus_input_step    {old, event, new, window?} (FocusState read views, a FocusEvent) -> {violations}
 *   focus_debug_window  {resolved, childPage?, ghostty, ownTabs, isKey} -> {expectedResponder?, kind, ghosttyMismatch?}
 * (debug monitor, debug.focus and journal replay only; never per event). */

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
 *   project(request)     view's request -> {sections, machines, items, machine_sections, machine_order,
 *                        unplaced, band_groups, host_groups, archived, group_sorts, pinned_in_group,
 *                        group_row_limits?, group_revealed?}
 *                        (the rows regrouped as the list draws them; its rows are the last view's)
 *   plan(request)        {plan:"subgroup", parent, id, name, color?} | {plan:"host_group", session, on?, title?}
 *                        -> {"ok":true,"ops":[op]} | {"refusal":"unknown_group"|"too_deep"}
 */
/*
 * The sidebar's drop rules as a handle per drag (drag_handle.rs). The rows and
 * sections cross once, as JSON, when a drag's base layout is made; each drag
 * move crosses with numbers only. A move's reply is JSON, written only when it
 * differs from the handle's last reply to the same question: otherwise the
 * call answers CMUX_SIDEBAR_DRAG_SAME and leaves the output untouched. A reply
 * larger than the buffer answers ERR_BUFFER with its length, as
 * cmux_layout_reducer_json does. A handle is used on one thread.
 *
 *   cmux_sidebar_drag_new(request)      a sidebar_drop Request ({payload, rows, sections, ...}) -> handle | null
 *   cmux_sidebar_drag_resolve(...)      the card's points -> null | {target, probe}
 *   cmux_sidebar_tab_drag_new(request)  a TabRequest ({rows, sections, source_machine, ...}, y unused) -> handle | null
 *   cmux_sidebar_tab_drag_drop(y, w)    -> null | tab drop (w non-zero: a workspace row takes the tab over its whole height)
 *   cmux_sidebar_tab_drag_refusal(y)    -> null | {row, reason}
 *   cmux_sidebar_base_y(...)            1 and *base_y set, or 0 inside the open gap
 */
#define CMUX_SIDEBAR_DRAG_SAME 1
typedef struct CmuxSidebarDrag CmuxSidebarDrag;
typedef struct CmuxSidebarTabDrag CmuxSidebarTabDrag;

CmuxSidebarDrag *cmux_sidebar_drag_new(const uint8_t *request, size_t request_len);
void cmux_sidebar_drag_free(CmuxSidebarDrag *drag);
int32_t cmux_sidebar_drag_resolve(
    CmuxSidebarDrag *drag,
    double centre_y,
    double leading_y,
    uint8_t has_gap,
    double gap_y,
    double gap_height,
    uint8_t *output,
    size_t output_capacity,
    size_t *output_len);
CmuxSidebarTabDrag *cmux_sidebar_tab_drag_new(const uint8_t *request, size_t request_len);
void cmux_sidebar_tab_drag_free(CmuxSidebarTabDrag *drag);
int32_t cmux_sidebar_tab_drag_drop(
    CmuxSidebarTabDrag *drag,
    double y,
    uint8_t whole_rows,
    uint8_t *output,
    size_t output_capacity,
    size_t *output_len);
int32_t cmux_sidebar_tab_drag_refusal(
    CmuxSidebarTabDrag *drag,
    double y,
    uint8_t *output,
    size_t output_capacity,
    size_t *output_len);
uint8_t cmux_sidebar_base_y(double display_y, uint8_t has_gap, double gap_y, double gap_height, double *base_y);

typedef struct CmuxSidebarMirror CmuxSidebarMirror;

CmuxSidebarMirror *cmux_sidebar_mirror_new(void);
void cmux_sidebar_mirror_free(CmuxSidebarMirror *mirror);
void cmux_sidebar_mirror_string_free(char *text);
char *cmux_sidebar_mirror_load(CmuxSidebarMirror *mirror, const uint8_t *json, size_t json_len);
char *cmux_sidebar_mirror_apply_batch(CmuxSidebarMirror *mirror, const uint8_t *json, size_t json_len);
char *cmux_sidebar_mirror_apply_intent(CmuxSidebarMirror *mirror, const uint8_t *json, size_t json_len);
char *cmux_sidebar_mirror_view(CmuxSidebarMirror *mirror, const uint8_t *json, size_t json_len);
char *cmux_sidebar_mirror_drag_begin(CmuxSidebarMirror *mirror, const uint8_t *json, size_t json_len);
char *cmux_sidebar_mirror_project(CmuxSidebarMirror *mirror, const uint8_t *json, size_t json_len);
char *cmux_sidebar_mirror_plan(CmuxSidebarMirror *mirror, const uint8_t *json, size_t json_len);

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
    const CmuxFocusStr *column_siblings; /* NULL, or column_pane_count ids parallel to column_panes: each pane's close sibling (issue 38194); empty is none */
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
    uint8_t omnibar_return;     /* 1: queue focusTarget(addressBar, programmatic) after this event's effects */
    uint8_t returns_to_omnibar; /* 1: this event is that queued return: restore the edit, do not select all */
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
    CmuxFocusStr typing_tab; /* the tab a key typed now is for: an expected tab, else the focused terminal */
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

/*
 * The pane a Close Tab press is aimed at after a close emptied a pane
 * (PaneCloseAim), kept by the window's focus handle. Times are seconds of
 * system uptime (NSEvent.timestamp's clock); is_key 1 for a key-down,
 * is_repeat 1 for an auto-repeat.
 */
/* the focused pane moved from `from` (has_from 0: none) to the handle's focused pane; returns the move's serial */
uint64_t cmux_focus_pane_moved(CmuxFocus *focus, const uint8_t *from, size_t from_len, uint8_t has_from);
/* the frame that shows move `serial` was presented at `time` */
void cmux_focus_frame_presented(CmuxFocus *focus, uint64_t serial, double time);
/* the press closed the last tab of `pane` */
void cmux_focus_pane_emptied(CmuxFocus *focus, const uint8_t *pane, size_t pane_len, double time, uint8_t is_key, uint8_t is_repeat);
/* 1: the press is aimed at the emptied pane (it closes nothing; show why) */
uint8_t cmux_focus_aims_at_emptied_pane(CmuxFocus *focus, double time, uint8_t is_key, uint8_t is_repeat);

/*
 * The app's one input handle (R-INPUT stage S2): the input router of
 * cmux-focus-core, which owns every window's focus. Each cmux_input_focus_*
 * call is the cmux_focus_* call of the same name for the window `window`
 * (UTF-8 id bytes), with the same requests and the same reply bytes. A reply
 * is valid until the next cmux_input_* call for that window; never free it.
 * A call for a window that is not open returns null (0 for a number; CMUX_LAYOUT_REDUCER_ERR_INVALID
 * from cmux_input_focus_import_json, ERR_NULL for a null handle or bad id bytes).
 * memory: the machine's physical memory in bytes (it bounds the key lanes).
 */
typedef struct CmuxInput CmuxInput;
CmuxInput *cmux_input_new(uint64_t memory);
void cmux_input_free(CmuxInput *input);
/* opens a window (a second open changes nothing); its first reply, as cmux_focus_current's */
const CmuxFocusReply *cmux_input_window_open(CmuxInput *input, const uint8_t *window, size_t window_len);
void cmux_input_window_close(CmuxInput *input, const uint8_t *window, size_t window_len);
const CmuxFocusReply *cmux_input_focus_send(CmuxInput *input, const uint8_t *window, size_t window_len, const CmuxFocusEvent *event, const uint8_t *strings, size_t strings_len);
const CmuxFocusReply *cmux_input_focus_set_topology(CmuxInput *input, const uint8_t *window, size_t window_len, const CmuxFocusTopology *topology, const uint8_t *strings, size_t strings_len);
const CmuxFocusReply *cmux_input_focus_current(CmuxInput *input, const uint8_t *window, size_t window_len);
void cmux_input_focus_set_close_focus(CmuxInput *input, const uint8_t *window, size_t window_len, uint8_t policy); /* 0 previous neighbor, 1 most recent */
const CmuxFocusStrings *cmux_input_focus_recent_panes(CmuxInput *input, const uint8_t *window, size_t window_len, const uint8_t *workspace, size_t workspace_len, uint8_t has_workspace);
const CmuxFocusStrings *cmux_input_focus_remembered(CmuxInput *input, const uint8_t *window, size_t window_len);
/* Journal checkpoints and replay only, never per event; free the string with cmux_focus_string_free. */
char *cmux_input_focus_export_json(CmuxInput *input, const uint8_t *window, size_t window_len);
int32_t cmux_input_focus_import_json(CmuxInput *input, const uint8_t *window, size_t window_len, const uint8_t *json, size_t json_len);
uint64_t cmux_input_focus_pane_moved(CmuxInput *input, const uint8_t *window, size_t window_len, const uint8_t *from, size_t from_len, uint8_t has_from);
void cmux_input_focus_frame_presented(CmuxInput *input, const uint8_t *window, size_t window_len, uint64_t serial, double time);
void cmux_input_focus_pane_emptied(CmuxInput *input, const uint8_t *window, size_t window_len, const uint8_t *pane, size_t pane_len, double time, uint8_t is_key, uint8_t is_repeat);
uint8_t cmux_input_focus_aims_at_emptied_pane(CmuxInput *input, const uint8_t *window, size_t window_len, double time, uint8_t is_key, uint8_t is_repeat);

/*
 * The close successor rules (cmux-focus-core close_focus), one call per
 * close, no handle. Ids are the caller's own uint32_t numbering of its tab
 * or workspace ids; CMUX_FOCUS_NONE is none. A null array with a nonzero
 * count gives CMUX_FOCUS_NONE (live_openers: -1).
 */
/* 2026-11-08's rule, kept for the pinned app: the shown tab before `selected`, else after it; the opener arrays do not pick (null-checked only) */
uint32_t cmux_close_focus_tab(uint32_t selected, const uint32_t *old, size_t old_count,
                              const uint32_t *surviving, size_t surviving_count,
                              const uint32_t *shown, size_t shown_count,
                              const uint32_t *opener_children, const uint32_t *opener_parents, size_t opener_count);
/* Chrome's rule (DetermineNewSelectedIndex): a child, a sibling, the opener, the group's neighbor, else the shown tab after `selected`, else before it */
uint32_t cmux_close_focus_tab_chrome(uint32_t selected, const uint32_t *old, size_t old_count,
                                     const uint32_t *surviving, size_t surviving_count,
                                     const uint32_t *shown, size_t shown_count,
                                     const uint32_t *opener_children, const uint32_t *opener_parents, size_t opener_count,
                                     const uint32_t *group_tabs, const uint32_t *group_ids, size_t group_count);
/* the workspace a window shows after `shown` left; orders: order_count row orders flattened, order i holds order_lengths[i] ids */
uint32_t cmux_close_focus_workspace(uint32_t shown, const uint32_t *old, size_t old_count,
                                    const uint32_t *surviving, size_t surviving_count,
                                    const uint32_t *orders, const uint32_t *order_lengths, size_t order_count);
/* writes the live opener of order[i] (Chrome's FixOpeners) to parent_out[i], CMUX_FOCUS_NONE for none; 0 ok */
int32_t cmux_close_focus_live_openers(const uint32_t *children, const uint32_t *parents, size_t count,
                                      const uint32_t *order, size_t order_count, uint32_t *parent_out);

/*
 * The one close-selection rule (cmux-focus-core close_selection): the opener
 * relations of tabs or of workspaces and the item selected after a close.
 * One handle holds the relations of every strip of one kind (every pane's
 * tabs, or every window's workspaces); each call names its strip by its
 * items. Ids are the caller's own uint32_t numbering, stable for the
 * handle's life; CMUX_FOCUS_NONE is none. A handle is used by one thread; a
 * null handle is no relation. A null array with a nonzero count changes
 * nothing (a pick: CMUX_FOCUS_NONE; the slot: `opener`). An item that is
 * CMUX_FOCUS_NONE changes nothing.
 */
typedef struct CmuxCloseSelection CmuxCloseSelection;
enum {
    CMUX_CLOSE_SELECTION_QUICK = 0, /* a person's new item: forgotten when the selection leaves it */
    CMUX_CLOSE_SELECTION_TASK = 1,  /* a link's or a tab action's new tab */
};
CmuxCloseSelection *cmux_close_selection_new(void);
void cmux_close_selection_free(CmuxCloseSelection *handle);
/* `item` was made while `opener` was the strip's selected item; foreground: the new item is selected */
void cmux_close_selection_made(CmuxCloseSelection *handle, uint32_t item, uint32_t opener, uint8_t kind, uint8_t foreground,
                               const uint32_t *strip, size_t strip_count);
/* the strip's selection moved; gesture: a person chose it (not a close's own selection, not automation) */
void cmux_close_selection_selected(CmuxCloseSelection *handle, uint32_t old, uint32_t new_item, uint8_t gesture,
                                   const uint32_t *strip, size_t strip_count);
/* a typed navigation (not a link click) in `tab` */
void cmux_close_selection_typed_navigation(CmuxCloseSelection *handle, uint32_t tab, const uint32_t *strip, size_t strip_count);
/* any other navigation committed in `tab`: its next typed navigation is not a just-made tab's first */
void cmux_close_selection_navigated(CmuxCloseSelection *handle, uint32_t tab);
/* `item` left its strip (closed or moved); after the pick for a close, for every item that closes */
void cmux_close_selection_left(CmuxCloseSelection *handle, uint32_t item);
void cmux_close_selection_forget_all(CmuxCloseSelection *handle, const uint32_t *strip, size_t strip_count);
/* nonzero while a relation is held, in any strip; while zero, cmux_close_selection_selected changes nothing */
uint8_t cmux_close_selection_has_relations(CmuxCloseSelection *handle);
uint32_t cmux_close_selection_opener(CmuxCloseSelection *handle, uint32_t item);
/* the tab selected after `selected` closed: a child, a sibling, the opener, the group's neighbor, the next shown tab, else the previous */
uint32_t cmux_close_selection_tab(CmuxCloseSelection *handle, uint32_t selected, const uint32_t *old, size_t old_count,
                                  const uint32_t *surviving, size_t surviving_count,
                                  const uint32_t *shown, size_t shown_count,
                                  const uint32_t *group_tabs, const uint32_t *group_ids, size_t group_count);
/* the workspace shown after `shown` left, by the same ranks over the sidebar's row orders (order i holds order_lengths[i] ids) */
uint32_t cmux_close_selection_workspace(CmuxCloseSelection *handle, uint32_t shown, const uint32_t *old, size_t old_count,
                                        const uint32_t *surviving, size_t surviving_count,
                                        const uint32_t *orders, const uint32_t *order_lengths, size_t order_count,
                                        const uint32_t *group_rows, const uint32_t *group_ids, size_t group_count);
/* the item a background child of `opener` goes after */
uint32_t cmux_close_selection_slot(CmuxCloseSelection *handle, uint32_t opener, const uint32_t *order, size_t order_count,
                                   const uint32_t *pinned, size_t pinned_count);

/*
 * The close-selection state of every window's workspaces (cmux-focus-core
 * close_selection::windows::WindowCloseSelection): the creates a window
 * waits for, the window of each workspace with an opener relation, the
 * selection repairs that run, and the opener relations. Rust holds the state
 * and takes every decision; the caller reports facts and applies the pick.
 * One handle for the app, used by one thread. Workspace ids and window ids
 * are the caller's own uint32_t numberings (two separate ones), stable while
 * cmux_window_close_selection_holds_ids is nonzero; CMUX_FOCUS_NONE is none
 * and 0 is an id like any other. A null handle holds nothing: every pick is
 * by position. A null array with a nonzero count, a null struct, or a
 * workspace or window that is CMUX_FOCUS_NONE where one is needed changes
 * nothing (a pick: CMUX_FOCUS_NONE).
 *
 * Cost: while cmux_window_close_selection_holds_ids is zero, every call is
 * O(1), allocates nothing and reads no array, except the pick, which is the
 * positional rule over its arrays. With relations held, a call reads the
 * workspaces of those relations only, never a window's members (the pick
 * reads the arrays it is given).
 */
typedef struct CmuxWindowCloseSelection CmuxWindowCloseSelection;
enum {
    CMUX_WINDOW_CLOSE_RELATION_NONE = 0,  /* the create starts no relation */
    CMUX_WINDOW_CLOSE_RELATION_QUICK = 1, /* the quick look-up: ends when the window's selection leaves the new workspace */
    CMUX_WINDOW_CLOSE_RELATION_TASK = 2,  /* lasts as a link tab's: until the person selects an unrelated workspace */
};
/* One close: `shown` left the window. `previous`: its members before; `members`: its members now; `order_count` row
 * orders before the close, most preferred first (the rows as drawn, then the model's), flattened into `orders`
 * (order i holds order_lengths[i] ids). */
typedef struct {
    uint32_t shown;
    const uint32_t *previous;
    size_t previous_count;
    const uint32_t *members;
    size_t member_count;
    const uint32_t *orders;
    const uint32_t *order_lengths;
    size_t order_count;
} CmuxWindowClosePick;
/* One selection repair: the window showed `shown` (CMUX_FOCUS_NONE: nothing) and will show `pick`. `gesture`
 * nonzero: the caller says a person asked, in this turn, for the selection of a `preferred` workspace. `pressed`
 * nonzero: the repair runs at the press of a close that hid rows and that can still be cancelled or refused (the
 * app's InstantClose); zero for a daemon delta, a move, a room change and every other repair. `members`: the
 * window's members now; `preferred`: the workspaces just moved in. */
typedef struct {
    uint32_t shown;
    uint32_t pick;
    uint8_t gesture;
    uint8_t pressed;
    const uint32_t *members;
    size_t member_count;
    const uint32_t *preferred;
    size_t preferred_count;
} CmuxWindowCloseRepair;
/* The answers to cmux_window_close_selection_settle_questions for `window`: workspaces[i] is listed now by window
 * owners[i] (CMUX_FOCUS_NONE: by none) and claimed[i] is nonzero when it is a create its window waits for;
 * windows[j] is registered when exists[j] is nonzero. A question with no answer reads as: listed by none, not
 * claimed, not registered. */
typedef struct {
    uint32_t window;
    const uint32_t *workspaces;
    const uint32_t *owners;
    const uint8_t *claimed;
    size_t workspace_count;
    const uint32_t *windows;
    const uint8_t *exists;
    size_t window_count;
} CmuxWindowCloseSettle;
/* the relation a create into a window starts (no handle): CMUX_WINDOW_CLOSE_RELATION_NONE unless the create opens
 * the New Tab page in a run that is the person's action and may change the view; then TASK when the placement
 * setting puts the row after the current one, else QUICK. Each fact: nonzero is true. */
uint8_t cmux_window_close_selection_relation(uint8_t opens_new_tab_page, uint8_t persons_action, uint8_t may_change_view,
                                             uint8_t after_current);
CmuxWindowCloseSelection *cmux_window_close_selection_new(void);
void cmux_window_close_selection_free(CmuxWindowCloseSelection *handle);
/* nonzero while no opener relation is held (also for a null handle): every pick is by position */
uint8_t cmux_window_close_selection_is_empty(CmuxWindowCloseSelection *handle);
/* nonzero while the handle holds any workspace or window id (a create it waits for, a relation, a repair that
 * runs). While zero: cmux_window_close_selection_shown, _left, _renamed and _settle change nothing and may be left
 * out, and the caller may forget its numbering. Read it after a call, never inside a repair. */
uint8_t cmux_window_close_selection_holds_ids(CmuxWindowCloseSelection *handle);
/* a create of `workspace` into `window` starts `relation` (the result of cmux_window_close_selection_relation; NONE
 * changes nothing). Call it before the window can show the workspace: it gets its opener when the window shows it. */
void cmux_window_close_selection_expect(CmuxWindowCloseSelection *handle, uint32_t workspace, uint32_t window, uint8_t relation);
/* `window` now shows `new_workspace`; it showed `old` (CMUX_FOCUS_NONE: nothing) before. gesture: the code running
 * at the change is a person's own action (not the CLI, the socket, MCP or a script). Report every selection change
 * of a window. A change inside a repair is never a gesture, whatever `gesture` says. */
void cmux_window_close_selection_shown(CmuxWindowCloseSelection *handle, uint32_t new_workspace, uint32_t old, uint32_t window,
                                       uint8_t gesture);
/* `workspace` closed or left its window; after the pick for the close */
void cmux_window_close_selection_left(CmuxWindowCloseSelection *handle, uint32_t workspace);
/* window `old_window` took the identity `new_window`: its creates and relations follow it */
void cmux_window_close_selection_renamed(CmuxWindowCloseSelection *handle, uint32_t old_window, uint32_t new_window);
/* the selection that needs no pick (no handle): the first of `preferred` that is a member, else `current` when it
 * is a member, else CMUX_FOCUS_NONE: then build the row orders and call cmux_window_close_selection_pick */
uint32_t cmux_window_close_selection_kept(uint32_t current, const uint32_t *members, size_t member_count,
                                          const uint32_t *preferred, size_t preferred_count);
/* the workspace the window shows after close->shown left it: a workspace it opened, one its opener opened, its
 * opener (also one that is a member and that no order lists), else the next row below as drawn, the row above only
 * for the last row; `previous` is read as the last order. A close of several workspaces in one gesture (a
 * multi-selection, Close Others, a group close) is this same call: `members` holds the survivors, so an opener that
 * closes with it is no candidate. There is no batch flag. A `shown` that is a member stays; CMUX_FOCUS_NONE when
 * no member is left. Call it before cmux_window_close_selection_left for the closed workspaces. */
uint32_t cmux_window_close_selection_pick(CmuxWindowCloseSelection *handle, const CmuxWindowClosePick *close);
/* a selection repair starts: call it when repair->pick differs from repair->shown, select the pick (the window
 * reports it through cmux_window_close_selection_shown), then call cmux_window_close_selection_repair_end. The
 * selection is the close's, not a person's, unless `gesture` is set and `pick` is one of `preferred`. With
 * `pressed` set, a `shown` that is not in `members` (the press hid its row) keeps a QUICK relation through this
 * repair: the committed close (cmux_window_close_selection_left, or the settle) ends it, and so does the window's
 * next selection of any workspace but `shown`; a cancelled close shows the row again with its opener. Without
 * `pressed`, a QUICK relation ends when the selection leaves its workspace. Repairs may nest. A null `repair` or a
 * null array still starts a repair (with no member and no preferred workspace), so each begin has its end. */
void cmux_window_close_selection_repair_begin(CmuxWindowCloseSelection *handle, const CmuxWindowCloseRepair *repair);
void cmux_window_close_selection_repair_end(CmuxWindowCloseSelection *handle);
/* after the repair of `window`: the facts Rust needs to end the creates and relations of workspaces that closed,
 * moved, or whose window is gone. Writes up to `capacity` workspace ids to `workspaces` and up to `capacity` window
 * ids to `windows`, the number of window ids to *window_count, and returns the number of workspace ids. Both zero
 * (always, while nothing is held: O(1), no allocation, no walk of members): the settle is done, make no second
 * call. A number above `capacity`: call again with larger arrays. Else answer with cmux_window_close_selection_settle. */
size_t cmux_window_close_selection_settle_questions(CmuxWindowCloseSelection *handle, uint32_t window, uint32_t *workspaces,
                                                    uint32_t *windows, size_t capacity, size_t *window_count);
/* ends what the answers say is gone: a workspace of `window` that no window lists (and that is no waiting create)
 * or that another window lists, and every workspace of a window that is not registered */
void cmux_window_close_selection_settle(CmuxWindowCloseSelection *handle, const CmuxWindowCloseSettle *answers);

/*
 * Agent cursor visibility (cmux-focus-core agent_cursor_visibility), typed:
 * one call per agent input event and per frame of pane motion while a target
 * is tracked, no JSON, no handle, no allocation. Ids are the caller's own
 * uint32_t numbering (workspaces, panes, tabs, windows); CMUX_FOCUS_NONE is
 * none. Variable parts are ranges (offset, count) into the snapshot's flat
 * arrays. The answer equals the JSON operation agent_cursor_visibility's.
 * Returns CMUX_LAYOUT_REDUCER_OK and writes *out; ERR_NULL (a null pointer,
 * or a null array with a nonzero count), ERR_INVALID (a range outside its
 * array) or ERR_PANIC leave *out as it was.
 */
#define CMUX_CURSOR_WINDOW_MINIMIZED 1u
#define CMUX_CURSOR_WINDOW_ON_ACTIVE_SPACE 2u
#define CMUX_CURSOR_WINDOW_SIDEBAR_HIDDEN 4u
#define CMUX_CURSOR_PANE_HAS_FRAME 1u
#define CMUX_CURSOR_PANE_HAS_CLIP 2u
#define CMUX_CURSOR_PANE_HAS_STRIP 4u
#define CMUX_CURSOR_PANE_HAS_PAGE 8u
#define CMUX_CURSOR_PANE_HAS_SCALE 16u
#define CMUX_CURSOR_VISIBLE 0u
#define CMUX_CURSOR_HIDDEN 1u
#define CMUX_CURSOR_NOT_DRAWN 2u
/* CmuxCursorVisibility.anchor */
#define CMUX_CURSOR_ANCHOR_TAB_CHIP 0u
#define CMUX_CURSOR_ANCHOR_TAB_STRIP 1u
#define CMUX_CURSOR_ANCHOR_COLUMN_EDGE_LEADING 2u
#define CMUX_CURSOR_ANCHOR_COLUMN_EDGE_TRAILING 3u
#define CMUX_CURSOR_ANCHOR_COLUMN_EDGE_TOP 4u
#define CMUX_CURSOR_ANCHOR_COLUMN_EDGE_BOTTOM 5u
#define CMUX_CURSOR_ANCHOR_WORKSPACE_ROW 6u
#define CMUX_CURSOR_ANCHOR_WINDOW_EDGE 7u
/* CmuxCursorVisibility.reason */
#define CMUX_CURSOR_REASON_TAB_CLOSED 0u
#define CMUX_CURSOR_REASON_NOT_IN_ANY_WINDOW 1u
#define CMUX_CURSOR_REASON_MINIMIZED 2u
#define CMUX_CURSOR_REASON_OTHER_SPACE 3u

typedef struct {
    double x, y, w, h;
} CmuxCursorRect;

/* a sidebar row (key: its workspace) or a tab chip (key: its tab) */
typedef struct {
    uint32_t key;
    uint32_t reserved;
    CmuxCursorRect rect;
} CmuxCursorKeyedRect;

typedef struct {
    uint32_t id;
    uint32_t shown_workspace; /* CMUX_FOCUS_NONE: shows none */
    uint32_t flags;           /* CMUX_CURSOR_WINDOW_* */
    uint32_t listed_offset, listed_count; /* range of ids */
    uint32_t rows_offset, rows_count;     /* range of rows */
    uint32_t panes_offset, panes_count;   /* range of panes */
    uint32_t reserved;
    CmuxCursorRect overlay;
} CmuxCursorWindow;

typedef struct {
    uint32_t id;
    uint32_t selected_tab; /* CMUX_FOCUS_NONE: none */
    uint32_t flags;        /* CMUX_CURSOR_PANE_* */
    uint32_t chips_offset, chips_count; /* range of chips */
    uint32_t reserved;
    CmuxCursorRect frame, clip, strip, viewport;
    double zoom;
    double scale; /* without CMUX_CURSOR_PANE_HAS_SCALE: 1 */
} CmuxCursorPane;

typedef struct {
    uint32_t target;
    uint32_t tab_workspace; /* CMUX_FOCUS_NONE: no tab has the target id */
    uint32_t tab_pane;
    uint32_t reserved;
    const CmuxCursorWindow *windows; size_t windows_count; /* front to back */
    const uint32_t *ids; size_t ids_count;
    const CmuxCursorKeyedRect *rows; size_t rows_count;
    const CmuxCursorPane *panes; size_t panes_count;
    const CmuxCursorKeyedRect *chips; size_t chips_count;
} CmuxCursorSnapshot;

/* kind CMUX_CURSOR_VISIBLE: window, viewport, clip, zoom, scale.
 * CMUX_CURSOR_HIDDEN: window, anchor (CMUX_CURSOR_ANCHOR_*), rect.
 * CMUX_CURSOR_NOT_DRAWN: reason (CMUX_CURSOR_REASON_*). Non-finite rect
 * numbers pass through as they are. */
typedef struct {
    uint32_t kind;
    uint32_t window;
    uint32_t anchor;
    uint32_t reason;
    CmuxCursorRect viewport, clip, rect;
    double zoom;
    double scale;
} CmuxCursorVisibility;

int32_t cmux_agent_cursor_visibility(const CmuxCursorSnapshot *snapshot, CmuxCursorVisibility *out);

/* Column scroll reducer (cmux-layout-reducer scroll, src/scroll.rs): one
 * handle per scrolling strip (kind 0 a columns screen, 1 a column's rows,
 * 2 a scroll area). The spring stays in the caller's memory: every event
 * call reads it and writes it back. Request strings are CmuxScrollStr
 * ranges into the strip's bytes (offset CMUX_SCROLL_NONE: absent); reply
 * strings point into the handle and stay valid until its next call.
 * source: 0 keyboard 1 pointer 2 programmatic 3 scroll
 * mode: 0 never 1 always 2 on-overflow
 * axis: 0 horizontal 1 vertical
 * A rows strip lists one column per row (the row id) in window space, with
 * the stack's height as viewport_width and origin its min y; an area strip
 * lists one column per cell (its id is unused), origin the window's min x. */
#define CMUX_SCROLL_NONE 0xFFFFFFFFu

typedef struct CmuxScroll CmuxScroll;

typedef struct CmuxScrollStr {
    uint32_t offset;
    uint32_t len;
} CmuxScrollStr;

typedef struct CmuxScrollRect {
    double x;
    double y;
    double width;
    double height;
} CmuxScrollRect;

typedef struct CmuxScrollSpring {
    double value;
    double velocity;
    double target;
} CmuxScrollSpring;

typedef struct CmuxScrollPane {
    CmuxScrollStr id;
    CmuxScrollRect frame;
    uint8_t has_frame;
    uint8_t listed; /* in the column's pane list (layout order) */
    uint8_t reserved[6];
} CmuxScrollPane;

typedef struct CmuxScrollColumn {
    CmuxScrollStr id;
    CmuxScrollRect frame;
    uint32_t pane_start; /* index into panes */
    uint32_t pane_count;
} CmuxScrollColumn;

typedef struct CmuxScrollStrip {
    const uint8_t *bytes;
    const CmuxScrollColumn *columns;
    const CmuxScrollPane *panes;
    uint32_t bytes_len;
    uint32_t column_count;
    uint32_t pane_count;
    uint8_t axis;
    uint8_t reserved[3];
    double viewport_width;
    double content_width;
    double gap;
    double leading_cover;
    double trailing_cover;
    double origin;
} CmuxScrollStrip;

typedef struct CmuxScrollSync {
    CmuxScrollStr focused; /* ranges into the strip's bytes */
    CmuxScrollStr anchor;
    uint8_t source;
    uint8_t animated;
    uint8_t reveals;
    uint8_t reserved[5];
} CmuxScrollSync;

typedef struct CmuxScrollEffects {
    uint8_t ok;
    uint8_t needs_frames;
    uint8_t report_on_settle;
    uint8_t snapped;
    uint8_t has_focus;
    uint8_t reserved[3];
    const uint8_t *focus;
    size_t focus_len;
} CmuxScrollEffects;

typedef struct CmuxScrollStatus {
    uint8_t ok;
    uint8_t gesture_active;
    uint8_t reveal_deferred;
    uint8_t has_restore;
    uint8_t has_strip;
    uint8_t has_focused_pane;
    uint8_t mode;
    uint8_t reserved;
    double gesture_raw;
    const uint8_t *focused_pane;
    size_t focused_pane_len;
} CmuxScrollStatus;

CmuxScroll *cmux_scroll_new(uint8_t kind);
CmuxScroll *cmux_scroll_clone(const CmuxScroll *scroll); /* an independent copy */
void cmux_scroll_free(CmuxScroll *scroll);
void cmux_scroll_set_mode(CmuxScroll *scroll, uint8_t mode);
CmuxScrollEffects cmux_scroll_sync(CmuxScroll *scroll, CmuxScrollSpring *spring, const CmuxScrollStrip *strip, const CmuxScrollSync *sync);
CmuxScrollEffects cmux_scroll_center(CmuxScroll *scroll, CmuxScrollSpring *spring, const uint8_t *pane, size_t pane_len, uint8_t animated);
CmuxScrollEffects cmux_scroll_reveal(CmuxScroll *scroll, CmuxScrollSpring *spring, const uint8_t *pane, size_t pane_len, uint8_t animated);
CmuxScrollEffects cmux_scroll_gesture_began(CmuxScroll *scroll, CmuxScrollSpring *spring);
CmuxScrollEffects cmux_scroll_gesture_changed(CmuxScroll *scroll, CmuxScrollSpring *spring, double delta_x, double time);
CmuxScrollEffects cmux_scroll_gesture_ended(CmuxScroll *scroll, CmuxScrollSpring *spring, double time, uint8_t animated);
CmuxScrollEffects cmux_scroll_wheel(CmuxScroll *scroll, CmuxScrollSpring *spring, int32_t direction, uint8_t animated);
CmuxScrollEffects cmux_scroll_page(CmuxScroll *scroll, CmuxScrollSpring *spring, double to, uint8_t animated);
CmuxScrollStatus cmux_scroll_status(const CmuxScroll *scroll);
uint8_t cmux_scroll_gesture_active(const CmuxScroll *scroll); /* per frame: no focus lookup */

/*
 * The springing-close rules (cmux-layout-reducer closing_panes; FRAME OWNER
 * S3c/S3d): which panes border a closing pane and the gaps it keeps, the panes
 * nothing moves over, where every closing pane shows this frame (per display
 * frame during a close), the strip's carries and a row column's stop, and a
 * taken-back close. One handle per screen; panes, scroll areas and row columns
 * are numbers the caller hands out (0: none). No JSON; a call allocates
 * nothing once the handle's buffers have grown.
 *
 * Return codes: begin and remove return 1 when they answer and 0 when they do
 * not, with nothing written. 1 and 0 are answers, not
 * CMUX_LAYOUT_REDUCER_OK (also 0): check for 1. settle and rects return
 * CMUX_LAYOUT_REDUCER_OK and write a list that borrows the handle's buffer,
 * valid until the next call on the same handle. Any call returns ERR_NULL,
 * ERR_INVALID (an unknown handle kind) or ERR_PANIC with nothing written.
 * Each input array holds `count` elements; an `out` pointer must not overlap
 * an input array or the handle. One thread at a time per handle.
 */
typedef struct CmuxClosingPanes CmuxClosingPanes;

#define CMUX_CLOSING_HANDLE_SPLIT 0
#define CMUX_CLOSING_HANDLE_COLUMN_EDGE 1
#define CMUX_CLOSING_HANDLE_ROW_EDGE 2

typedef struct CmuxClosingEdges {
    double min_x;
    double max_x;
    double min_y;
    double max_y;
} CmuxClosingEdges;

typedef struct CmuxClosingRect {
    double x;
    double y;
    double width;
    double height;
} CmuxClosingRect;

typedef struct CmuxClosingPane {
    uint64_t id;
    uint64_t area;
    uint64_t row_column;
    CmuxClosingEdges edges;
    uint8_t scrolls;
    uint8_t reserved[7];
} CmuxClosingPane;

typedef struct CmuxClosingHandle {
    CmuxClosingEdges hit;
    double mid_x;
    double mid_y;
    uint64_t area;   /* a split's scroll area (0: none) */
    uint64_t column; /* a row edge's column */
    uint8_t kind;    /* CMUX_CLOSING_HANDLE_* */
    uint8_t horizontal;
    uint8_t kept;
    uint8_t fixed_split;
    uint8_t docked;
    uint8_t reserved[3];
} CmuxClosingHandle;

typedef struct CmuxClosingFrame {
    uint64_t id;
    CmuxClosingEdges now;
    CmuxClosingEdges target;
    double vx;
    double vy;
    double vw;
    double vh;
    uint8_t moving;
    uint8_t fixed; /* 1: it does not scroll with the strip (x in view coordinates) */
    uint8_t reserved[6];
} CmuxClosingFrame;

typedef struct CmuxClosingRow {
    uint64_t column;
    double now;
    double target;
} CmuxClosingRow;

typedef struct CmuxClosingPlaced {
    uint64_t pane;
    CmuxClosingRect rect;
} CmuxClosingPlaced;

typedef struct CmuxClosingTaken {
    CmuxClosingRect rect;
    double vx;
    double vw;
    double vy;
    double vh;
} CmuxClosingTaken;

typedef struct CmuxClosingIds {
    const uint64_t *ids;
    size_t count;
} CmuxClosingIds;

typedef struct CmuxClosingPlacedList {
    const CmuxClosingPlaced *placed;
    size_t count;
} CmuxClosingPlacedList;

CmuxClosingPanes *cmux_closing_panes_new(void);
void cmux_closing_panes_free(CmuxClosingPanes *closing);
int32_t cmux_closing_panes_begin(CmuxClosingPanes *closing, uint64_t pane, const CmuxClosingEdges *shown, const CmuxClosingPane *panes, size_t pane_count, const CmuxClosingHandle *handles, size_t handle_count, double max_gap, uint8_t has_view_shift, double view_shift, double strip_shift);
int32_t cmux_closing_panes_settle(CmuxClosingPanes *closing, const CmuxClosingFrame *frames, size_t frame_count, const CmuxClosingRow *rows, size_t row_count, CmuxClosingIds *out);
int32_t cmux_closing_panes_rects(CmuxClosingPanes *closing, const CmuxClosingFrame *frames, size_t frame_count, const CmuxClosingRow *rows, size_t row_count, double strip, double rest_strip, CmuxClosingPlacedList *out);
int32_t cmux_closing_panes_carry(CmuxClosingPanes *closing, double drift, uint8_t has_view_shift, double view_shift);
int32_t cmux_closing_panes_settle_carried(CmuxClosingPanes *closing, double strip_shift);
int32_t cmux_closing_panes_shift_y(CmuxClosingPanes *closing, uint64_t column, double delta);
int32_t cmux_closing_panes_remove(CmuxClosingPanes *closing, uint64_t pane, const CmuxClosingFrame *frames, size_t frame_count, double strip, CmuxClosingTaken *out);
int32_t cmux_closing_panes_drop(CmuxClosingPanes *closing, uint64_t pane);
uint8_t cmux_closing_panes_has_awaiting(const CmuxClosingPanes *closing);
uint64_t cmux_closing_panes_state_hash(const CmuxClosingPanes *closing); /* tests: the whole state, hashed */

/*
 * The sidebar row face (cmux-layout-reducer sidebar_face): which tab a
 * workspace's row stands for and is named for, its folder line and Group by
 * Folder bucket, its kinds, program, status line, unread mark, notice and
 * progress bar, and each listed tab's shortened title and folder. One handle
 * per thread; one call per frame maps every changed row (O(changed rows)).
 * No JSON: a CmuxSidebarFaceRange is a byte range into the call's `strings`
 * (in a reply, into reply->strings); offset CMUX_SIDEBAR_FACE_NONE means
 * absent. UTF-8, not NUL-terminated. A workspace's panes, tabs and entries
 * are runs of the request's arrays; its panes' tab_count values add up to
 * its tab_count. Each call returns a reply the handle owns, valid until the
 * next call on that handle; never free it. ok 0: the request did not decode
 * (a range out of bounds, bytes that are not UTF-8, an unknown code); no
 * faces then.
 *
 * Tab kind: 0 pty 1 browser 2 remoteTerminal 3 conversation 4 other
 * Tab agent: 0 none 1 working 2 blocked 3 other
 * Tab progress_state: 0 none 1 normal 2 error 3 indeterminate 4 paused
 *     (progress_value 0...100 as reported, CMUX_SIDEBAR_FACE_NO_VALUE for no value)
 * Face tab fields index the workspace's own tabs, entry fields its own
 * entries; CMUX_SIDEBAR_FACE_NONE for none.
 * Face kind: 0 terminal 1 browser 2 harness
 * Face row_kind: 0 terminal 1 browser 2 agent 3 mixed
 * Face unread: 0 none 1 dot 2 count (the workspace's unread_count)
 * Face notice: 0 none 1 notice_tab's attention reason 2 notice_tab's unread notification text
 * Face progress: 0 none 1 a bar (progress_value 0...1, NaN while indeterminate; progress_error)
 * Listed kind: 0 the record's kind 1 new tab 2 agent chat
 */
#define CMUX_SIDEBAR_FACE_NONE UINT32_MAX
#define CMUX_SIDEBAR_FACE_NO_VALUE INT32_MIN
#define CMUX_SIDEBAR_FACE_TAB_NAMED 1u
#define CMUX_SIDEBAR_FACE_TAB_CHAT 2u
#define CMUX_SIDEBAR_FACE_TAB_COMMAND_RUNNING 4u
#define CMUX_SIDEBAR_FACE_TAB_TITLE_ACTIVITY 8u
#define CMUX_SIDEBAR_FACE_TAB_PAGE 16u
#define CMUX_SIDEBAR_FACE_TAB_APP 32u
#define CMUX_SIDEBAR_FACE_TAB_NEW_TAB_PAGE 64u
#define CMUX_SIDEBAR_FACE_TAB_BRANDED 128u
#define CMUX_SIDEBAR_FACE_TAB_HAS_UNREAD 256u
#define CMUX_SIDEBAR_FACE_TAB_MARKED_UNREAD 512u
#define CMUX_SIDEBAR_FACE_TAB_ATTENTION 1024u
#define CMUX_SIDEBAR_FACE_WORKSPACE_LOCAL 1u
#define CMUX_SIDEBAR_FACE_WORKSPACE_MARKED_UNREAD 2u
#define CMUX_SIDEBAR_FACE_WORKSPACE_REPORTED_PROGRESS 4u
#define CMUX_SIDEBAR_FACE_LISTED_TITLE_CHANGED 1u /* else the tab keeps its list_title */
#define CMUX_SIDEBAR_FACE_LISTED_BLANK 2u         /* a titled New Tab page: no folder, idle, no host */

typedef struct CmuxSidebarFace CmuxSidebarFace;

typedef struct CmuxSidebarFaceRange {
    uint32_t offset;
    uint32_t len;
} CmuxSidebarFaceRange;

typedef struct CmuxSidebarFaceTab {
    CmuxSidebarFaceRange title;      /* the reported title (titleText) */
    CmuxSidebarFaceRange list_title; /* the title the tab list shows before shortening */
    CmuxSidebarFaceRange cwd;
    uint32_t flags;
    uint8_t kind;
    uint8_t agent;
    uint8_t progress_state;
    uint8_t reserved;
    int32_t progress_value;
    uint32_t reserved2;
    uint64_t notification;           /* its notification id, 0 for none */
    uint64_t attention_at_ms;        /* read only with ..._TAB_ATTENTION */
    uint64_t agent_updated_ms;
    uint64_t notification_created_ms;
} CmuxSidebarFaceTab;

typedef struct CmuxSidebarFacePane {
    uint64_t focused_at;
    int64_t default_tab;
    uint32_t tab_count;
    uint32_t selected; /* the window's selection among the pane's tabs; NONE: the daemon's default */
} CmuxSidebarFacePane;

typedef struct CmuxSidebarFaceEntry {
    CmuxSidebarFaceRange key;
    CmuxSidebarFaceRange text;
} CmuxSidebarFaceEntry;

typedef struct CmuxSidebarFaceWorkspace {
    uint32_t pane_start;
    uint32_t pane_count;
    uint32_t tab_start;
    uint32_t tab_count;
    uint32_t entry_start;
    uint32_t entry_count;
    uint32_t flags;
    uint32_t reserved;
    uint64_t unread_count;
    double reported_progress;    /* read only with ..._WORKSPACE_REPORTED_PROGRESS; NaN: indeterminate */
    CmuxSidebarFaceRange status; /* the hooks' status line */
} CmuxSidebarFaceWorkspace;

typedef struct CmuxSidebarFaceRequest {
    const CmuxSidebarFaceWorkspace *workspaces;
    const CmuxSidebarFacePane *panes;
    const CmuxSidebarFaceTab *tabs;
    const CmuxSidebarFaceEntry *entries;
    uint32_t workspace_count;
    uint32_t pane_count;
    uint32_t tab_count;
    uint32_t entry_count;
    CmuxSidebarFaceRange home; /* this Mac's home folder */
    uint8_t shows_unread;
    uint8_t new_tab_titled;
    uint8_t reserved[6];
} CmuxSidebarFaceRequest;

typedef struct CmuxSidebarFaceRow {
    uint32_t front;
    uint32_t label;
    uint32_t face;
    uint32_t chat;
    uint32_t folder_tab;
    uint32_t bucket_tab;
    uint32_t agent;
    uint32_t notice_tab;
    uint8_t kind;
    uint8_t row_kind;
    uint8_t unread;
    uint8_t notice;
    uint8_t progress;
    uint8_t progress_error;
    uint8_t reserved[2];
    uint32_t listed_start;     /* index into reply->listed: one per tab of the workspace */
    uint32_t kept_entry_start; /* index into reply->kept_entries: the status block's entries */
    uint32_t kept_entry_count;
    uint32_t ports;
    uint32_t pull_request;
    uint32_t work;             /* the work a browser front tab yields its name to (workTab) */
    CmuxSidebarFaceRange directory;
    CmuxSidebarFaceRange bucket;
    CmuxSidebarFaceRange process;
    CmuxSidebarFaceRange status_line;
    uint64_t last_activity_ms;
    double progress_value;
    uint32_t front_chat;       /* the chat Copy Agent Identifier copies: the front tab's, else the first chat */
    uint32_t reserved2;
} CmuxSidebarFaceRow;

typedef struct CmuxSidebarFaceListedTab {
    CmuxSidebarFaceRange title; /* read only with ..._LISTED_TITLE_CHANGED */
    CmuxSidebarFaceRange folder;
    uint64_t last_activity_ms;
    uint8_t kind;
    uint8_t flags;
    uint8_t reserved[6];
} CmuxSidebarFaceListedTab;

typedef struct CmuxSidebarFaceReply {
    uint8_t ok;
    uint8_t reserved[7];
    const CmuxSidebarFaceRow *faces;
    const CmuxSidebarFaceListedTab *listed;
    const uint32_t *kept_entries;
    const uint8_t *strings;
    uint32_t face_count;
    uint32_t listed_count;
    uint32_t kept_entry_count;
    uint32_t strings_len;
} CmuxSidebarFaceReply;

typedef struct CmuxSidebarFaceText {
    uint8_t ok;
    uint8_t reserved[7];
    const uint8_t *bytes;
    uint32_t len;
    uint32_t reserved2;
} CmuxSidebarFaceText;

CmuxSidebarFace *cmux_sidebar_face_new(void);
void cmux_sidebar_face_free(CmuxSidebarFace *faces);
const CmuxSidebarFaceReply *cmux_sidebar_face_rows(CmuxSidebarFace *faces, const CmuxSidebarFaceRequest *request, const uint8_t *strings, size_t strings_len);
/* The daemon's next default workspace name: names[0 ..< existing_count] are the
 * machine's listed names (its home left out), the rest the reserved ones. */
const CmuxSidebarFaceText *cmux_sidebar_face_default_name(CmuxSidebarFace *faces, const CmuxSidebarFaceRange *names, uint32_t count, uint32_t existing_count, const uint8_t *strings, size_t strings_len);

/*
 * The keyboard resize rules (cmux-layout-reducer shown_resize): which split
 * ratios, column widths and dock widths show as different layouts, the width
 * trade of a key press between two strip columns, and the row heights of a key
 * press on a row edge. One call per key press, no handle, no JSON, no
 * allocation. Each returns 1 and writes its answer, 0 when there is none (the
 * press moves nothing), or CMUX_LAYOUT_REDUCER_ERR_NULL / ERR_PANIC with
 * nothing written. Flags are 0 or 1.
 */
typedef struct CmuxShownResizeBounds {
    double lower;
    double upper;
} CmuxShownResizeBounds;

typedef struct CmuxShownResizeDock {
    double width;
    uint8_t is_target;
    uint8_t is_band;
    uint8_t is_docked;
    uint8_t reserved[5];
} CmuxShownResizeDock;

typedef struct CmuxShownResizeTrade {
    double strip_width;
    double gap;
    double scale;
    double delta;
    double left_min_x;
    double left_max_x;
    double left_width;
    double right_min_x;
    double right_max_x;
    double right_width;
    double left_minimum_width;
    double right_minimum_width;
    double left_fraction;
    double right_fraction;
    double strip_offset;
    double uncovered_min_x;
    double uncovered_max_x;
    double strip_min_x;
    uint8_t is_columns;
    uint8_t has_strip_offset;
    uint8_t reserved[6];
} CmuxShownResizeTrade;

typedef struct CmuxShownResizeTradeAnswer {
    double move_points;
    double first_left;
    double first_right;
    double second_left;
    double second_right;
} CmuxShownResizeTradeAnswer;

typedef struct CmuxShownResizeRows {
    const int64_t *heights;
    const double *minimum_heights;
    size_t count;
    size_t pane_row;
    double column_height;
    double gap;
    double scale;
    double delta;
    uint8_t rows_enabled;
    uint8_t reserved[7];
} CmuxShownResizeRows;

/* container and divider: the split's and the divider's extents along its axis */
int32_t cmux_shown_resize_ratio(double container, double divider, double minimum_a, double minimum_b,
                                CmuxShownResizeBounds *out);
int32_t cmux_shown_resize_column_width(uint8_t is_columns, uint8_t is_docked, double strip_width,
                                       double minimum_width, double gap, CmuxShownResizeBounds *out);
/* docks: every placed dock in the screen's order, one marked is_target */
int32_t cmux_shown_resize_dock_width(const CmuxShownResizeDock *docks, size_t count, double viewport_width,
                                     double gap, double minimum_width, CmuxShownResizeBounds *out);
/* the move and the two width pairs to try, first to second; the caller keeps the first that places right */
int32_t cmux_shown_resize_trade(const CmuxShownResizeTrade *input, CmuxShownResizeTradeAnswer *out);
/* writes every row's height (out_count == input->count) */
int32_t cmux_shown_resize_row_heights(const CmuxShownResizeRows *input, int64_t *out, size_t out_count);

/* Per-project caps and the "Needs you" section (cmux_layout_reducer::sidebar_caps, Leo 2026-11-10).
 * flags: PINNED 1, WAITING 2 (yellow), UNREAD 4 (blue), RUNNING 8, KEEP 16 (selected, renamed, dragged).
 * A project passes its member count and only its active members, ascending by index. */
enum {
    CMUX_SIDEBAR_ACTIVE_PINNED = 1,
    CMUX_SIDEBAR_ACTIVE_WAITING = 2,
    CMUX_SIDEBAR_ACTIVE_UNREAD = 4,
    CMUX_SIDEBAR_ACTIVE_RUNNING = 8,
    CMUX_SIDEBAR_ACTIVE_KEEP = 16,
    CMUX_SIDEBAR_TAIL_NONE = 0,
    CMUX_SIDEBAR_TAIL_SHOW_MORE = 1,
    CMUX_SIDEBAR_TAIL_SHOW_LESS = 2,
};

typedef struct CmuxSidebarActive {
    uint32_t index;
    uint8_t flags;
    uint8_t reserved[3];
} CmuxSidebarActive;

typedef struct CmuxSidebarCaps {
    uint32_t cap; /* 0: All */
    uint32_t revealed;
    uint8_t floats;
    uint8_t include_working;
    uint8_t reserved[2];
} CmuxSidebarCaps;

typedef struct CmuxSidebarProjectTail {
    uint8_t kind;
    uint8_t reserved[3];
    uint32_t hidden;
    uint32_t next;
    uint32_t floated;
    uint32_t rows; /* written, or needed on ERR_BUFFER */
    uint32_t revealed_after_press;
} CmuxSidebarProjectTail;

int32_t cmux_sidebar_project_rows(uint32_t count, const CmuxSidebarActive *active, size_t active_len,
                                  const CmuxSidebarCaps *caps, uint32_t *out, size_t out_capacity,
                                  CmuxSidebarProjectTail *tail);
/* rows: the sidebar's active rows in drawn order; limit 0 is three */
int32_t cmux_sidebar_needs_you(const CmuxSidebarActive *rows, size_t rows_len, uint8_t include_working, uint32_t limit,
                               uint32_t *out, size_t out_capacity, size_t *out_len, uint32_t *more);

#endif
