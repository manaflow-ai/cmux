#ifndef CMUX_MOTION_FFI_H
#define CMUX_MOTION_FFI_H

/* cmux-motion's C ABI (cmux-tui/crates/cmux-app-ffi/src/motion.rs): the
 * closed-form spring, the spec's motion tokens, the structural bounce rule
 * and the ui.animations.* switches, and the tab strip's tweens and geometry
 * (Chrome's strip motion), and the color transition's curves and color mix.
 * Pure functions; no globals. ABI version 3. */

#include <stdbool.h>
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

#endif
