#ifndef CMUX_LAUNCH_RECORD_H
#define CMUX_LAUNCH_RECORD_H
#include <stdbool.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct CmuxLaunchWindow {
  double frame_x, frame_y, frame_width, frame_height;
  uint32_t display_id;
  uint8_t background_rgba[4];
  uint8_t bar_rgba[4];
  uint32_t image_pixel_width, image_pixel_height;
  char window_id[65];
  char image_path[1025];
} CmuxLaunchWindow;

typedef struct CmuxLaunchWindowInput {
  double frame_x, frame_y, frame_width, frame_height;
  uint32_t display_id;
  uint8_t background_rgba[4];
  uint8_t bar_rgba[4];
  uint32_t image_pixel_width, image_pixel_height;
  const char *window_id;
  const char *image_path;
  const char *visible_workspace_id;
  const char *const *visible_tab_ids;
  uintptr_t visible_tab_count;
} CmuxLaunchWindowInput;

typedef struct CmuxLaunchSidebarInput {
  const char *id;
  const char *title;
  const char *icon_key;
} CmuxLaunchSidebarInput;

// False leaves a non-null output zeroed. Success strings are NUL-terminated.
// IDs >=65 bytes, image paths >=1025 bytes and unusable frames return false.
bool cmux_launch_record_front_window(const char *path, CmuxLaunchWindow *out);
bool cmux_launch_record_write(const char *path,
                              const CmuxLaunchWindowInput *windows,
                              uintptr_t window_count,
                              const CmuxLaunchSidebarInput *sidebars,
                              uintptr_t sidebar_count,
                              const char *session_socket_path);
#ifdef __cplusplus
}
#endif
#endif
