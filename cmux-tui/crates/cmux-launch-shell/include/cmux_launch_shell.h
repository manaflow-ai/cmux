#ifndef CMUX_LAUNCH_SHELL_H
#define CMUX_LAUNCH_SHELL_H
/* The stage-0 launch window's plan and the input it holds for the real window
 * (cmux-tui/crates/cmux-launch-shell, src/ffi.rs). cmux-app-ffi/tests/launch_shell_header.rs checks
 * the exports. */
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct CmuxLaunchShellDisplay {
    double x;
    double y;
    double width;
    double height;
    double scale;
} CmuxLaunchShellDisplay;

typedef struct CmuxLaunchShellNow {
    /* NUL-terminated UTF-8: the running app's build. */
    const char *build;
    /* 0 light, 1 dark: the system's appearance now. */
    uint8_t appearance;
    const CmuxLaunchShellDisplay *displays;
    size_t display_count;
    /* NUL-terminated UTF-8: the app's Application Support folder (launch-times.jsonl). */
    const char *support_dir;
    /* NUL-terminated UTF-8 or NULL: Library/Application Support and the daemon session name, for
     * the registry id this home last saw live. NULL: unknown, no session check. */
    const char *app_support;
    const char *daemon_session;
} CmuxLaunchShellNow;

typedef struct CmuxLaunchShellPlan {
    double frame_x;
    double frame_y;
    double frame_width;
    double frame_height;
    uint8_t background_rgba[4];
    uint8_t bar_rgba[4];
    uint8_t appearance;
    /* 0 image, 1 fresh install, 2 no windows, 3 build, 4 layout, 5 scale, 6 appearance,
     * 7 image unreadable, 8 image size, 9 full screen, 10 upgrade, 11 another session. */
    uint8_t reason;
    bool shows_window;
    /* Nothing of the record is restored: the app's default frame. */
    bool uses_default_frame;
    /* The bare launch's content (Home); otherwise the plain shell when there is no image. */
    bool shows_bare;
    char window_id[129];
    /* Absolute; empty unless reason is 0. */
    char image_path[1025];
} CmuxLaunchShellPlan;

/* Fills out with stage 0's plan from the launch record and the image store (image_dir
 * absolute). False only for a null or non-UTF-8 argument; out then makes no window. */
bool cmux_launch_shell_plan(const char *record_path, const char *image_dir,
                            const CmuxLaunchShellNow *now, CmuxLaunchShellPlan *out);

/* kind: 1 key down, 2 key up, 3 flags changed, 4 mouse down, 5 mouse up, 6 drag, 7 scroll,
 * 8 hover, 0 other. Returns 0 pass to AppKit, 1 hold, 2 hold and swap now. */
uint8_t cmux_launch_shell_input_disposition(uint8_t kind, size_t held);

/* Whether a held event of kind is replayed to the real window at the swap: keys always; buttons,
 * drags and scrolls only when stage 0 showed the saved image and there was no mismatch. */
bool cmux_launch_shell_replays(uint8_t kind, bool showed_image, bool mismatch);

#ifdef __cplusplus
}
#endif
#endif
