// C ABI between the remote browser host (Rust) and its CEF shim (C++).
// plans/cmux-next/remote-tab-r2.md section 1. The shim owns every CEF type;
// Rust sees plain C values. All callbacks run on the CEF UI thread (the
// process main thread); every rb_shim_* call except rb_shim_post must be made
// on that thread (Rust posts work there with rb_shim_post).
#ifndef CMUX_RB_SHIM_H_
#define CMUX_RB_SHIM_H_

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// The layout of cef_cmux.h's cmux_rp_frame_t (API 19).
typedef struct {
  int64_t lease;
  int coded_width;
  int coded_height;
  int visible_x;
  int visible_y;
  int visible_width;
  int visible_height;
  int has_update_rect;
  int update_x;
  int update_y;
  int update_width;
  int update_height;
  int has_capture_counter;
  int64_t capture_counter;
  int64_t timestamp_us;
  void* io_surface;
  const void* pixels;
  int stride;
} rb_frame_t;

typedef struct {
  void* context;
  // CEF is initialized; tabs may open.
  void (*on_ready)(void* context);
  // rb_shim_open_tab(request) created browser `browser_id`.
  void (*on_tab_created)(void* context, int request, int browser_id);
  void (*on_tab_closed)(void* context, int browser_id);
  void (*on_title)(void* context, int browser_id, const char* title_utf8);
  void (*on_url)(void* context, int browser_id, const char* url_utf8);
  // A captured frame; hand it back with rb_shim_frame_release(lease).
  void (*on_frame)(void* context, int browser_id, const rb_frame_t* frame);
  // A key the page did not handle (send it back to the viewer).
  void (*on_key_unhandled)(void* context, int browser_id, const char* code,
                           int modifiers);
  // A page context menu (token answered with rb_shim_context_menu_result) or
  // a <select> popup (answered with rb_shim_popup_menu_result).
  // `items_json` is the menu model (remote-tab-protocol.md MenuItem list).
  void (*on_context_menu)(void* context, int browser_id, int64_t token, int x,
                          int y, const char* items_json);
  void (*on_popup_menu)(void* context, int browser_id, int64_t token, int x,
                        int y, int width, int height, const char* items_json,
                        int selected, int multiple);
  // Viz needs begin frames for this browser (RP3) or not.
  void (*on_needs_begin_frames)(void* context, int browser_id, int needs);
} rb_shim_callbacks_t;

// Runs the process: helper processes return their exit code at once; the
// browser process initializes CEF with --cmux-remote-presentation, calls
// on_ready and runs the message loop until rb_shim_quit. `cache_dir` holds the
// profile. Returns the process exit code.
int rb_shim_run(int argc, char** argv, const char* cache_dir,
                int external_begin_frames,
                const rb_shim_callbacks_t* callbacks);
void rb_shim_quit(void);

// Runs fn(ctx) on the CEF UI thread (any thread may call this).
void rb_shim_post(void (*fn)(void*), void* ctx);
// Runs fn(ctx) on the CEF UI thread after `delay_ms` (bounded waits of the
// smoke mode; runtime code paces on frame and begin-frame signals).
void rb_shim_post_delayed(void (*fn)(void*), void* ctx, int64_t delay_ms);

// The headless screen (DIP and scale; cmux_rp_set_screen).
int rb_shim_set_screen(int width_dip, int height_dip, double scale);
// Opens a Chrome-style tab in a headless window; on_tab_created reports it.
int rb_shim_open_tab(int request, const char* url, int width_dip,
                     int height_dip);
void rb_shim_close_tab(int browser_id);

int rb_shim_capture(int browser_id, int on, int min_period_us);
int rb_shim_capture_refresh(int browser_id);
void rb_shim_frame_release(int64_t lease);
int rb_shim_begin_frame(int browser_id, int64_t interval_us);

// Input (the values of cmux_remote_browser::rp_input::RpCall).
int rb_shim_send_key(int browser_id, int down, const char* code,
                     const char* key, const char* text,
                     const char* unmodified_text, int modifiers,
                     const char* const* command_names,
                     const char* const* command_values, int command_count);
int rb_shim_send_mouse(int browser_id, int kind, double x, double y,
                       int button, int click_count, int modifiers);
int rb_shim_send_wheel(int browser_id, double x, double y, double dx,
                       double dy, int precise, int phase, int momentum_phase,
                       int modifiers);
int rb_shim_send_pinch(int browser_id, int phase, double scale, double x,
                       double y);
int rb_shim_ime_set_composition(int browser_id, const char* text_utf8,
                                int selection_start, int selection_end,
                                int replace_start, int replace_end);
int rb_shim_ime_commit(int browser_id, const char* text_utf8,
                       int replace_start, int replace_end);
int rb_shim_ime_finish(int browser_id, int keep_selection);
int rb_shim_ime_cancel(int browser_id);

// Menu answers: command id (-1 cancels) / option indices (count < 0 cancels).
int rb_shim_context_menu_result(int64_t token, int command_id);
int rb_shim_popup_menu_result(int64_t token, const int* indices, int count);

#ifdef __cplusplus
}
#endif

#endif  // CMUX_RB_SHIM_H_
