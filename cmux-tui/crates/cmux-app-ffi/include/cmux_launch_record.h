#ifndef CMUX_LAUNCH_RECORD_H
#define CMUX_LAUNCH_RECORD_H
#include <stdbool.h>
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

typedef struct CmuxLaunchNow {
  const char *build;  // CFBundleVersion and commit, as in image keys
  uint8_t appearance;  // 0 light, 1 dark
  const CmuxLaunchDisplay *displays;
  uintptr_t n;
  // Directory holding prior-state markers (launch-times.jsonl); may be null.
  const char *support_dir;
} CmuxLaunchNow;

// reason, first failure wins in this order:
//  0 image ok, 1 no record, 2 no windows, 3 build differs (or a v1 record),
//  4 layout differs (display missing or its frame moved), 5 scale differs,
//  6 appearance differs (only when the window follows the system),
//  7 image missing or unreadable, 8 image pixels != frame x scale (+-1 px),
//  9 full screen, 10 no record but support_dir holds prior state.
// 1, 2 and 10 leave the rest zeroed. 3-9 fill frame, colors and appearance
// from the front window. image_path is absolute and non-empty only for 0.
typedef struct CmuxLaunchShellPlan {
  double frame_x, frame_y, frame_width, frame_height;
  uint8_t background_rgba[4];
  uint8_t bar_rgba[4];
  uint8_t appearance;
  uint8_t reason;
  char image_path[1024];
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
// True iff every saved window's display_id is in now with the same frame and
// backing scale. False for a missing or unreadable record.
bool cmux_launch_record_layout_matches(const char *path,
                                       const CmuxLaunchDisplay *now,
                                       uintptr_t n);
// Fills out and returns true; false (out zeroed) only for null or non-UTF-8
// arguments. image_dir must be absolute for an image to be usable.
bool cmux_launch_shell_plan(const char *record_path, const char *image_dir,
                            const CmuxLaunchNow *now,
                            CmuxLaunchShellPlan *out);
#ifdef __cplusplus
}
#endif
#endif
