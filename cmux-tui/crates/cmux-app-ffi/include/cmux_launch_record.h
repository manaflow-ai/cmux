#ifndef CMUX_LAUNCH_RECORD_H
#define CMUX_LAUNCH_RECORD_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

// Lifetimes: no call allocates or retains anything. Every string a call
// returns is copied into an inline, NUL-terminated buffer of the caller's
// struct, so there is nothing to free. Input pointers are borrowed only for
// the duration of the call.

// Format v2 fields follow the v1 fields, so v1 offsets are unchanged.
// A v1 record reads with an empty image_key, backing_scale 0 (unknown),
// light appearance, flags 0 and a zero screen frame.
typedef struct CmuxLaunchWindow {
  double frame_x, frame_y, frame_width, frame_height;
  uint32_t display_id;
  uint8_t background_rgba[4];
  uint8_t bar_rgba[4];
  uint32_t image_pixel_width, image_pixel_height;
  char window_id[65];
  char image_key[1025];  // "<build>/<window_id>/<generation>"
  double backing_scale;
  // The window's display frame when the record was written.
  double screen_frame_x, screen_frame_y, screen_frame_width, screen_frame_height;
  uint8_t appearance;  // 0 light, 1 dark
  uint8_t appearance_follows_system;
  uint8_t fullscreen;
  // 1 when the saved image may be drawn now; set only by
  // cmux_launch_record_windows_now, else 0.
  uint8_t image_ok;
} CmuxLaunchWindow;

typedef struct CmuxLaunchWindowInput {
  double frame_x, frame_y, frame_width, frame_height;
  uint32_t display_id;
  uint8_t background_rgba[4];
  uint8_t bar_rgba[4];
  uint32_t image_pixel_width, image_pixel_height;
  const char *window_id;
  const char *image_key;  // "<build>/<window_id>/<generation>"
  const char *visible_workspace_id;
  const char *const *visible_tab_ids;
  uintptr_t visible_tab_count;
  double backing_scale;
  double screen_frame_x, screen_frame_y, screen_frame_width, screen_frame_height;
  uint8_t appearance;  // 0 light, 1 dark
  uint8_t appearance_follows_system;
  uint8_t fullscreen;
} CmuxLaunchWindowInput;

typedef struct CmuxLaunchSidebarInput {
  const char *id;
  const char *title;
  const char *icon_key;
} CmuxLaunchSidebarInput;

typedef struct CmuxLaunchDisplay {
  uint32_t display_id;
  double frame_x, frame_y, frame_width, frame_height;
  double backing_scale;
} CmuxLaunchDisplay;

// The stage-0 launch window's plan (src/shell.rs, ported from cmux-launch-shell):
// the saved image, the plain shell (saved frame and colors, no image), or no
// window. Displays match by frame.
typedef struct CmuxLaunchShellDisplay {
  double x, y, width, height;
  double scale;
} CmuxLaunchShellDisplay;

typedef struct CmuxLaunchShellNow {
  const char *build;
  uint8_t appearance; /* 0 light, 1 dark */
  const CmuxLaunchShellDisplay *displays;
  size_t display_count;
  // Null, or the directory holding launch-times.jsonl (prior state).
  const char *support_dir;
} CmuxLaunchShellNow;

typedef struct CmuxLaunchShellPlan {
  double frame_x, frame_y, frame_width, frame_height;
  uint8_t background_rgba[4];
  uint8_t bar_rgba[4];
  uint8_t appearance;
  /* 0 image, 1 no record, 2 no windows, 3 build (or a v1 record), 4 layout,
   * 5 scale, 6 appearance, 7 image unreadable, 8 image size, 9 full screen,
   * 10 no record but launch-times.jsonl in support_dir.
   * No window for 4, 9 and 10; the default frame for 1 and 2; the saved
   * frame with no image for 3 and 5-8; the image for 0. */
  uint8_t reason;
  bool shows_window;
  bool uses_default_frame;
  char window_id[65];
  char image_path[1025];
} CmuxLaunchShellPlan;

// False leaves a non-null output zeroed. Success strings are NUL-terminated.
// IDs >=65 bytes, image keys >=1025 bytes and unusable frames return false.
bool cmux_launch_record_front_window(const char *path, CmuxLaunchWindow *out);
// windows[0] is the front window; the reader keeps that order.
bool cmux_launch_record_write(const char *path,
                              const CmuxLaunchWindowInput *windows,
                              uintptr_t window_count,
                              const CmuxLaunchSidebarInput *sidebars,
                              uintptr_t sidebar_count,
                              const char *session_socket_path);
// Returns the record's window count and fills the first min(count, cap)
// entries, front window first; out may be null when cap is 0. Returns 0 when
// the record or any window is unusable, zeroing the entries it wrote.
uintptr_t cmux_launch_record_windows(const char *path, CmuxLaunchWindow *out,
                                     uintptr_t cap);
// As cmux_launch_record_windows, with each entry's image_ok set for now.
// now->support_dir is not read. 0 for a null now or a non-UTF-8 string.
uintptr_t cmux_launch_record_windows_now(const char *path,
                                         const char *image_dir,
                                         const CmuxLaunchShellNow *now,
                                         CmuxLaunchWindow *out, uintptr_t cap);
// True iff every saved window's display_id is in now with the same frame and
// backing scale. False for a missing or unreadable record.
bool cmux_launch_record_layout_matches(const char *path,
                                       const CmuxLaunchDisplay *now,
                                       uintptr_t n);
/* False only for a null out or now, or a non-UTF-8 argument; a missing record is reason 1. */
bool cmux_launch_shell_plan(const char *record_path, const char *image_dir,
                            const CmuxLaunchShellNow *now, CmuxLaunchShellPlan *out);
#ifdef __cplusplus
}
#endif
#endif
