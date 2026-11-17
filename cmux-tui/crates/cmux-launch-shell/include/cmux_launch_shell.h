#ifndef CMUX_LAUNCH_SHELL_H
#define CMUX_LAUNCH_SHELL_H
/* The stage-0 launch window's decisions (cmux-tui/crates/cmux-launch-shell, src/ffi.rs): its plan
 * (saved image, plain shell, or no window) and which input it holds for the real window.
 * tests/header.rs checks this file against the Rust declarations. */
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct CmuxLaunchShellDisplay {
  double x, y, width, height;
  double scale;
} CmuxLaunchShellDisplay;

typedef struct CmuxLaunchShellNow {
  const char *build;
  uint8_t appearance; /* 0 light, 1 dark */
  const CmuxLaunchShellDisplay *displays;
  size_t display_count;
} CmuxLaunchShellNow;

typedef struct CmuxLaunchShellPlan {
  double frame_x, frame_y, frame_width, frame_height;
  uint8_t background_rgba[4];
  uint8_t bar_rgba[4];
  uint8_t appearance;
  /* 0 image, 1 no record, 2 no windows, 3 build, 4 layout, 5 scale, 6 appearance,
   * 7 image unreadable, 8 image size, 9 full screen, 10 old record */
  uint8_t reason;
  bool shows_window;
  bool uses_default_frame;
  char window_id[65];
  char image_path[1025];
} CmuxLaunchShellPlan;

/* False only for a null out or now, or a non-UTF-8 argument; a missing record is reason 1. */
bool cmux_launch_shell_plan(const char *record_path, const char *image_dir,
                            const CmuxLaunchShellNow *now, CmuxLaunchShellPlan *out);
/* 0 pass to AppKit, 1 hold, 2 hold and swap now. */
uint8_t cmux_launch_shell_input_disposition(uint8_t kind, size_t held);

#ifdef __cplusplus
}
#endif
#endif
