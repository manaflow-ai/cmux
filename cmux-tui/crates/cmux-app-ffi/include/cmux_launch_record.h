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

bool cmux_launch_record_front_window(const char *path, CmuxLaunchWindow *out);
#ifdef __cplusplus
}
#endif
#endif
