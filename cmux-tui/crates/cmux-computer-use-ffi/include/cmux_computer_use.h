// SPDX-License-Identifier: MIT
// cmux Computer Use, C ABI v1 (libcmux_computer_use.dylib).
//
// The macOS Computer Use worker in cmux Remote loads this library and hands
// it the platform pieces that need AppKit or ScreenCaptureKit (capture, the
// agent cursor overlay, the approval panel, the person's takeover signal).
// Everything else (tools, policy, sessions, accessibility, input, frames)
// runs in Rust.
//
// All strings are UTF-8 JSON, not NUL-terminated (pointer + length). Every
// CmuxCuBuffer returned by the library is freed with cmux_cu_buffer_free.
// cmux_cu_engine_call blocks: call it off the main thread. Callbacks may be
// called from any thread.
#ifndef CMUX_COMPUTER_USE_H
#define CMUX_COMPUTER_USE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define CMUX_CU_ABI_VERSION 1

typedef struct CmuxCuBuffer {
    uint8_t *data;
    size_t len;
} CmuxCuBuffer;

// A frame the host captured: tightly packed RGBA8, width * height * 4 bytes.
// The host owns `rgba` until the library calls `release_frame`.
typedef struct CmuxCuFrame {
    uint32_t width;
    uint32_t height;
    const uint8_t *rgba;
    double scale;     // pixels per point
    double origin_x;  // top-left, global points
    double origin_y;
    void *host_token; // passed back to release_frame
} CmuxCuFrame;

// Answers to `ask`.
enum {
    CMUX_CU_ANSWER_UNAVAILABLE = 0,
    CMUX_CU_ANSWER_ALLOW_ONCE = 1,
    CMUX_CU_ANSWER_ALLOW_SESSION = 2,
    CMUX_CU_ANSWER_ALWAYS = 3,
    CMUX_CU_ANSWER_DENY = 4,
    CMUX_CU_ANSWER_NEVER = 5,
};

typedef struct CmuxCuHost {
    uint32_t struct_size;
    void *context;
    // target_json: {"window":"<CGWindowID>"} or {"display":null|"<id>"}.
    // Returns 0 and fills *frame, or nonzero and writes a UTF-8 message
    // (up to error_cap bytes) to error.
    int32_t (*capture)(void *context, const uint8_t *target_json, size_t target_len,
                       CmuxCuFrame *frame, uint8_t *error, size_t error_cap);
    void (*release_frame)(void *context, void *host_token);
    // A CursorEvent (cursor.rs) as JSON. Must not block.
    void (*cursor)(void *context, const uint8_t *event_json, size_t event_len);
    // A Question as JSON: {"session","agent","app":{"id","name"},"remember","from_machine"}.
    // Blocks until answered or timed out; returns a CMUX_CU_ANSWER_* value.
    int32_t (*ask)(void *context, const uint8_t *question_json, size_t question_len);
    // Blocks up to limit_ms while the person uses the mouse or keyboard;
    // true when they are idle.
    bool (*wait_idle)(void *context, uint64_t limit_ms);
    // Asks for an OS permission ("accessibility", "screen_capture"); 0 on success.
    int32_t (*request_permission)(void *context, const uint8_t *name, size_t name_len);
    // The apps the capture sees (every app with a window, at any window level), as JSON
    // [{"pid":N,"id":"<bundle id, or empty>","name":"..."}]. Writes up to cap bytes to out and the
    // full length to *len. Returns 0, 2 when cap was too small (call again with *len bytes), or
    // another nonzero value on failure. A display capture's "exclude_pids" are checked against
    // the same list: the capture fails rather than leave a requested, running app in it.
    int32_t (*capture_apps)(void *context, uint8_t *out, size_t cap, size_t *len);
    // How many deliberate inputs (keys, clicks, scrolls, drags) the person has made so far, as
    // the takeover tap counts them (never cmux's own), or -1 when nothing watches. The focus
    // guard compares two readings to know whether the person moved focus during a call.
    // Optional: read only when struct_size covers it.
    int64_t (*person_events)(void *context);
} CmuxCuHost;

typedef struct CmuxCuEngine CmuxCuEngine;

uint32_t cmux_cu_abi_version(void);

// config_json: PolicyConfig (policy.rs). state_dir: UTF-8 path (0700) for
// sessions, approvals and the audit log. host: copied; its context must
// outlive the engine. Returns NULL on bad input (error filled).
CmuxCuEngine *cmux_cu_engine_create(const uint8_t *config_json, size_t config_len,
                                    const uint8_t *state_dir, size_t state_dir_len,
                                    const uint8_t *machine_name, size_t machine_name_len,
                                    const CmuxCuHost *host, CmuxCuBuffer *error);
void cmux_cu_engine_destroy(CmuxCuEngine *engine);

// Replaces the policy at once. Returns 0, or nonzero with error filled.
int32_t cmux_cu_engine_set_config(CmuxCuEngine *engine, const uint8_t *config_json,
                                  size_t config_len, CmuxCuBuffer *error);

// request_json: {"name","arguments","session","label","call_id","origin"}
// (origin: {"kind":"local"} or {"kind":"remote","machine","same_account"}).
// Returns a ToolOutput as JSON ({"is_error","code","body","png"}).
CmuxCuBuffer cmux_cu_engine_call(CmuxCuEngine *engine, const uint8_t *request_json,
                                 size_t request_len);

void cmux_cu_engine_end_session(CmuxCuEngine *engine, const uint8_t *session, size_t session_len);

// Saved approvals: {"always":[...],"never":[...]}.
CmuxCuBuffer cmux_cu_engine_saved_approvals(CmuxCuEngine *engine);
// action: "forget" | "always" | "never" for app_id; "revoke_sessions" ignores app_id.
int32_t cmux_cu_engine_edit_approvals(CmuxCuEngine *engine, const uint8_t *action, size_t action_len,
                                      const uint8_t *app_id, size_t app_id_len);

typedef struct CmuxCuServer CmuxCuServer;

// Serves the engine on the agent socket (cmux-computer-use-v1, wire.rs): a
// Unix socket at socket_path, mode 0600 in a 0700 directory of this user's,
// admitting only this user's processes (getpeereid) that send secret_hex
// (hex, at least 16 bytes) as their first line. Calls run off the caller's
// threads, ordered per agent session. Returns NULL with error filled on
// failure. The server holds the engine; call cmux_cu_serve_stop before
// cmux_cu_engine_destroy and before the host context goes away.
CmuxCuServer *cmux_cu_serve(CmuxCuEngine *engine, const uint8_t *socket_path, size_t socket_path_len,
                            const uint8_t *secret_hex, size_t secret_hex_len, CmuxCuBuffer *error);
// Stops accepting, closes live connections, removes the socket file and
// frees server. It BLOCKS until every running call has finished, so after it
// returns no host callback runs. Answer any open `ask` first (a call waiting
// on the person would hold it), and call it from one thread of the host's
// own (never from inside a callback, never from the thread `ask` waits on).
void cmux_cu_serve_stop(CmuxCuServer *server);

// The MCP tools/list result and the server instructions.
CmuxCuBuffer cmux_cu_tools_list(void);

void cmux_cu_buffer_free(CmuxCuBuffer buffer);

#ifdef __cplusplus
}
#endif

#endif
