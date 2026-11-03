#ifndef CMUX_MOTION_FFI_H
#define CMUX_MOTION_FFI_H

/* cmux-motion's C ABI (cmux-tui/crates/cmux-app-ffi/src/motion.rs): the
 * closed-form spring, the spec's motion tokens, the structural bounce rule
 * and the ui.animations.* switches, and the tab strip's tweens and geometry
 * (Chrome's strip motion), the color transition's curves and color mix, and
 * the hover rules (cmux-app-ffi/src/hover.rs, cmux-motion src/hover: the hover
 * card machine, tooltip hover intent, the safe triangle, the row card's
 * placement and the hover timing tokens). Pure functions; no globals.
 * ABI version 4. */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct {
    double response;
    double damping_fraction;
} CmuxMotionSpring;

typedef struct {
    double value;
    double velocity;
    double target;
} CmuxMotionState;

/* speed: 0 fast, 1 normal, 2 off. bounce: 0 none, 1 subtle. */
typedef struct {
    uint8_t speed;
    bool reduce_motion;
    uint8_t bounce;
    bool pane_animations;
    bool new_tab;
    bool new_workspace;
} CmuxMotionPolicy;

uint32_t cmux_motion_ffi_abi_version(void);
/* token: 0 move, 1 appear, 2 disappear, 3 settle, 4 scroll, 5 screen,
 * 6 track, 7 selection, 8 panel, 9 pinDrag, 10 zoom, 11 exit, 12 tabOpen
 * (the macOS MotionSpring declares its cases in this order). */
bool cmux_motion_spring_base(uint8_t token, CmuxMotionSpring *out);
bool cmux_motion_spring_is_structural(uint8_t token);
CmuxMotionSpring cmux_motion_resolve(CmuxMotionSpring base, bool structural, CmuxMotionPolicy policy);
bool cmux_motion_step(CmuxMotionState *state, double dt, CmuxMotionSpring spring, double epsilon);
/* kind: 0 paneAnimations, 1 newTab, 2 newWorkspace (newTab on by default, the others off). */
bool cmux_motion_animates(uint8_t kind, CmuxMotionPolicy policy);
double cmux_motion_fade_seconds(uint8_t fade, CmuxMotionPolicy policy);

/* A tween: seconds and curve (0 easeOutQuad = 1-(1-t)^2, 1 easeOut (Core
 * Animation), 2 easeInOut (Core Animation), 3 linear; an unknown curve id
 * falls back to easeOutQuad). */
typedef struct {
    double duration;
    uint8_t curve;
} CmuxMotionTween;

/* One scalar on a tween: a new target restarts the duration from value. */
typedef struct {
    double value;
    double from;
    double target;
    double elapsed;
    double duration;
} CmuxMotionTweenState;

/* design-tokens.json motion.tabStrip (pt; closing_mode_exit_delay in s). */
typedef struct {
    double max_width;
    double open_start_width;
    double close_end_width;
    double min_active_width;
    double min_inactive_width;
    double pinned_width;
    double reorder_threshold;
    double closing_mode_below_pad;
    double closing_mode_trailing_pad;
    double closing_mode_exit_delay;
} CmuxMotionTabStripGeometry;

/* token: 0 tabOpen, 1 tabClose, 2 tabMove. */
bool cmux_motion_tween_base(uint8_t token, CmuxMotionTween *out);
/* 0 under speed off, Reduce Motion, or tabOpen/tabClose with newTab off. */
double cmux_motion_tween_seconds(uint8_t token, CmuxMotionPolicy policy);
/* Same target: no change, false. New target: restart duration from value. */
bool cmux_motion_tween_retarget(CmuxMotionTweenState *state, double target, double duration);
bool cmux_motion_tween_step(CmuxMotionTweenState *state, double dt, uint8_t curve);
double cmux_motion_ease(uint8_t curve, double t);
/* CSS cubic-bezier(x1, y1, x2, y2) at t (0..1; x1, x2 clamped to 0..1). */
double cmux_motion_cubic_bezier(double x1, double y1, double x2, double y2, double t);
/* A spring from rest toward 1 at `time` s, no overshoot: held at its running
 * maximum, never decreasing (0..1). */
double cmux_motion_spring_progress_monotone(CmuxMotionSpring spring, double time);
/* Seconds until a spring from rest first comes within 0.5% of 1 (at most 5). */
double cmux_motion_spring_arrival(CmuxMotionSpring spring);
/* from mixed t of the way to to; space 0 OKLab, 1 sRGB. Inputs and output are
 * straight (unpremultiplied) sRGB RGBA in 0..1; the mix runs premultiplied and
 * unpremultiplies the result (alpha 0 gives 0,0,0,0). False on a null pointer. */
bool cmux_motion_mix_rgba(const double from[4], const double to[4], double t, uint8_t space, double out[4]);
/* density: 0 compact, 1 comfortable. */
bool cmux_motion_tab_strip_geometry(uint8_t density, CmuxMotionTabStripGeometry *out);

/* ---- Hover (cmux-motion src/hover; Swift keeps hit tests, timer and panel) ----
 * Durations are signed nanoseconds. The app keeps each machine as one of
 * these structs and passes it by pointer; unknown kinds read as idle or no
 * effect, never a crash. Field order matches the Rust #[repr(C)] structs in
 * cmux_motion::hover::c. */

/* A hover target: the host's 64-bit handle for its id, its window, its delay
 * (0 or less: none) and what leaving it does (leave 0 lingers, 1 hides; then
 * another target within `reshow` ns shows at once). */
typedef struct {
    uint64_t id;
    int64_t window;
    int64_t delay;
    int64_t reshow;
    uint8_t leave;
} CmuxHoverTarget;

/* The hover card machine. phase: 0 idle, 1 pending, 2 shown, 3 pinned,
 * 4 leaving, 5 grace (target and token as the phase carries them).
 * suppressions: bit 0 drag, 1 scroll, 2 sidebarHide. The windows may be set
 * between calls (tunables). */
typedef struct {
    CmuxHoverTarget target;
    CmuxHoverTarget last_hit;
    uint64_t token;
    uint64_t next_token;
    int64_t reshow_window;
    int64_t pin_lifetime;
    int64_t leave_window;
    int64_t aim_window;
    int64_t still_pointer_delay;
    uint8_t phase;
    uint8_t suppressions;
    bool has_last_hit;
    bool quiet;
    bool pointer_on_card;
    bool owned_card_shown;
    bool was_on_card;
} CmuxHoverCardMachine;

/* kind: 0 hit (flag: a target is under the pointer; target, moved, aiming,
 * bridging), 1 pointerOnCard (flag), 2 deadline (token), 3 dismiss,
 * 4 suppress / 5 unsuppress (suppression 0 drag, 1 scroll, 2 sidebarHide),
 * 6 targetRemoved (target.id), 7 pin (target), 8 owned (flag). */
typedef struct {
    CmuxHoverTarget target;
    uint64_t token;
    uint8_t kind;
    uint8_t suppression;
    bool flag;
    bool moved;
    bool aiming;
    bool bridging;
} CmuxHoverCardEvent;

/* kind: 0 schedule (token after `after` ns), 1 cancelTimer, 2 show (target,
 * sliding), 3 hide. */
typedef struct {
    CmuxHoverTarget target;
    uint64_t token;
    int64_t after;
    uint8_t kind;
    bool sliding;
} CmuxHoverCardEffect;

/* Every hover timing token, ns. */
typedef struct {
    int64_t card_show_delay;
    int64_t card_reshow_window;
    int64_t card_sweep_interval;
    int64_t card_pin_lifetime;
    int64_t card_still_pointer_delay;
    int64_t tooltip_delay;
    int64_t tooltip_warm;
    int64_t card_grace;
    int64_t card_aim;
} CmuxHoverTiming;

/* One warm group of tooltips. phase: 0 idle, 1 pending, 2 shown, 3 warm. */
typedef struct {
    uint64_t target;
    uint64_t token;
    uint64_t next_token;
    int64_t delay;
    int64_t warm_for;
    uint8_t phase;
} CmuxHoverIntent;

/* kind as CmuxHoverCardEffect's; show carries `target`. */
typedef struct {
    uint64_t target;
    uint64_t token;
    int64_t after;
    uint8_t kind;
} CmuxHoverIntentEffect;

/* Screen points, y up; rects as Core Graphics stores them. */
typedef struct {
    double x;
    double y;
} CmuxHoverPoint;

typedef struct {
    double x;
    double y;
    double width;
    double height;
} CmuxHoverRect;

typedef struct {
    CmuxHoverRect anchor;
    CmuxHoverRect card;
    CmuxHoverRect escape_slot;
    CmuxHoverRect gap_strip;
    bool is_leading;
} CmuxHoverEscapeGeometry;

bool cmux_hover_timing(CmuxHoverTiming *out);
int64_t cmux_hover_duration_from_seconds(double seconds);
bool cmux_hover_card_machine_init(CmuxHoverCardMachine *out);
/* Applies events in order; returns how many it applied (it stops while fewer
 * than 3 effect slots are left) and writes *effect_count. */
size_t cmux_hover_card_reduce(CmuxHoverCardMachine *machine, const CmuxHoverCardEvent *events, size_t event_count,
                              CmuxHoverCardEffect *effects, size_t effect_capacity, size_t *effect_count);
bool cmux_hover_intent_init(int64_t delay, int64_t warm_for, CmuxHoverIntent *out);
/* call: 0 hover (has_target, value = target), 1 deadline (value = token),
 * 2 dismiss. Needs capacity >= 2; returns the effect count. */
size_t cmux_hover_intent_call(CmuxHoverIntent *intent, uint8_t call, bool has_target, uint64_t value,
                              CmuxHoverIntentEffect *effects, size_t capacity);
bool cmux_hover_is_aimed_at(CmuxHoverRect card, bool has_from, CmuxHoverPoint from, bool has_to, CmuxHoverPoint to);
/* alignment: 0 top, 1 middle. */
bool cmux_hover_escape_geometry(CmuxHoverRect anchor, double width, double height, bool has_visible, CmuxHoverRect visible,
                                double scale, bool has_gap, double gap, uint8_t alignment, CmuxHoverEscapeGeometry *out);
/* 0 row, 1 card, 2 escape, 3 gap, 4 outside. */
uint8_t cmux_hover_escape_zone(const CmuxHoverEscapeGeometry *geometry, CmuxHoverPoint point);
CmuxHoverRect cmux_hover_card_room(CmuxHoverRect visible, bool has_window, CmuxHoverRect window, double margin);
CmuxHoverRect cmux_hover_row_band(CmuxHoverRect row, CmuxHoverRect column);
double cmux_hover_edge_gap(double scale);

#endif
