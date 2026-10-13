#ifndef CMUX_MOTION_FFI_H
#define CMUX_MOTION_FFI_H

/* cmux-motion's C ABI (cmux-tui/crates/cmux-app-ffi/src/motion.rs): the
 * closed-form spring, the spec's motion tokens, the structural bounce rule
 * and the ui.animations.* switches. Pure functions; no globals. */

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
    bool splits;
    bool new_tab;
    bool new_workspace;
} CmuxMotionPolicy;

uint32_t cmux_motion_ffi_abi_version(void);
/* token: 0 move, 1 appear, 2 disappear, 3 settle, 4 scroll, 5 screen,
 * 6 track, 7 selection, 8 panel, 9 pinDrag. */
bool cmux_motion_spring_base(uint8_t token, CmuxMotionSpring *out);
bool cmux_motion_spring_is_structural(uint8_t token);
CmuxMotionSpring cmux_motion_resolve(CmuxMotionSpring base, bool structural, CmuxMotionPolicy policy);
bool cmux_motion_step(CmuxMotionState *state, double dt, CmuxMotionSpring spring, double epsilon);
/* kind: 0 splits, 1 newTab, 2 newWorkspace. */
bool cmux_motion_animates(uint8_t kind, CmuxMotionPolicy policy);
double cmux_motion_fade_seconds(uint8_t fade, CmuxMotionPolicy policy);

#endif
