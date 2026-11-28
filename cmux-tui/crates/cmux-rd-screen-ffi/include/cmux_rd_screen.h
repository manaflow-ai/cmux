// SPDX-License-Identifier: GPL-3.0-or-later
// C ABI v1 of libcmux_rd_screen.dylib (cmux-tui/crates/cmux-rd-screen-ffi): the
// screen stream's rules, the `screen_*` JSON ops of cmux-rd-screen, and the RFB
// client's, the `vnc_*` ops of cmux-vnc (CmuxVNC's VNCRules). Opened with
// dlopen by processes that run a screen stream host outside the app (cmux
// Remote's Screen Sharing worker, cmux-vnc-host); Packages/Shared/CmuxVNCWebRTC's
// ScreenRules.library(at:) binds these two symbols by name.
#ifndef CMUX_RD_SCREEN_H
#define CMUX_RD_SCREEN_H

#include <stddef.h>
#include <stdint.h>

#define CMUX_RD_SCREEN_OK 0
#define CMUX_RD_SCREEN_ERR_NULL (-1)
#define CMUX_RD_SCREEN_ERR_INVALID (-2)
#define CMUX_RD_SCREEN_ERR_BUFFER (-3)
#define CMUX_RD_SCREEN_ERR_PANIC (-4)
#define CMUX_RD_SCREEN_ERR_UNKNOWN (-5)

uint32_t cmux_rd_screen_abi_version(void);

// Answers one op. request: request_len bytes of JSON (null with length 0 is an
// empty request); operation: NUL-terminated. The answer's length is written to
// *output_len; on CMUX_RD_SCREEN_ERR_BUFFER it is the capacity to retry with.
int32_t cmux_rd_screen_json(const uint8_t *request, size_t request_len, const char *operation,
                            uint8_t *output, size_t output_capacity, size_t *output_len);

#endif
