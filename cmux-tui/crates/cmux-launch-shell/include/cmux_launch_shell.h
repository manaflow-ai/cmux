#ifndef CMUX_LAUNCH_SHELL_H
#define CMUX_LAUNCH_SHELL_H
/* Which input the stage-0 launch window holds for the real window (cmux-tui/crates/cmux-launch-shell,
 * src/ffi.rs). cmux-app-ffi/tests/launch_shell_header.rs checks the exports. */
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

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
