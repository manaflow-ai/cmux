// C interface to the cmux remote client, for Swift on iOS.
//
// Kept by hand rather than generated: the surface is six functions, and a
// hand-written header can say what the contract is. See src/lib.rs.
//
// Threading: one handle, one thread at a time. Every call blocks, so drive
// them from a background queue and never from the main thread.
// Ownership: every char* this returns must be released with
// cmux_mobile_string_free.

#ifndef CMUX_REMOTE_MOBILE_H
#define CMUX_REMOTE_MOBILE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define CMUX_MOBILE_OK 0
#define CMUX_MOBILE_ERROR (-1)
#define CMUX_MOBILE_INVALID_ARGUMENT (-2)
#define CMUX_MOBILE_TIMED_OUT (-3)
#define CMUX_MOBILE_CLOSED (-4)

/// Allowed network paths. Auto lets iroh pick and upgrade; the constrained
/// modes fail closed when their required route hint is absent.
#define CMUX_MOBILE_PATH_AUTO 0u
#define CMUX_MOBILE_PATH_DIRECT_ONLY 1u
#define CMUX_MOBILE_PATH_RELAY_ONLY 2u

typedef struct CmuxMobileClient CmuxMobileClient;

/// Dial the daemon named by a `cmux://enroll/...` invitation and authenticate.
///
/// Blocks through the Noise handshake, which on a first enrollment waits for
/// the owner to approve this device. Returns NULL on failure and, when
/// error_out is non-NULL, stores a message the caller must free.
CmuxMobileClient *cmux_mobile_connect(const char *invite_uri,
                                      const char *device_name,
                                      uint32_t path_mode,
                                      char **error_out);

/// Open `root` on the daemon's host and start a login shell on a PTY.
int32_t cmux_mobile_open_terminal(CmuxMobileClient *client,
                                  const char *root,
                                  uint16_t cols,
                                  uint16_t rows);

/// Copy up to `capacity` bytes of terminal output, waiting up to timeout_ms for
/// the first byte. CMUX_MOBILE_TIMED_OUT means nothing arrived, which is normal
/// for an idle shell and is not an error.
int32_t cmux_mobile_read(CmuxMobileClient *client,
                         uint8_t *buffer,
                         size_t capacity,
                         size_t *out_len,
                         uint32_t timeout_ms);

/// Send keyboard input to the shell.
int32_t cmux_mobile_write(CmuxMobileClient *client, const uint8_t *bytes, size_t length);

/// Resize the remote PTY. Call on rotation and on keyboard show/hide.
int32_t cmux_mobile_resize(CmuxMobileClient *client, uint16_t cols, uint16_t rows);

/// Credential-free connection snapshot as JSON: generation, state, provider,
/// route, and whether the selected iroh path is direct or relayed. Safe to log.
char *cmux_mobile_snapshot_json(CmuxMobileClient *client);

/// The rendered terminal as JSON: size, styled rows, cursor, default colors,
/// and the output sequence the model is current through. The daemon keeps the
/// terminal model, so the phone renders styled runs rather than carrying a VT
/// parser. NULL when no terminal is open.
char *cmux_mobile_terminal_json(CmuxMobileClient *client);

/// The message behind the last failing call on this handle, or NULL.
char *cmux_mobile_last_error(CmuxMobileClient *client);

/// Close the session and release the handle. Safe with NULL.
void cmux_mobile_free(CmuxMobileClient *client);

/// Release a string returned by this library. Safe with NULL.
void cmux_mobile_string_free(char *text);

#ifdef __cplusplus
}
#endif

#endif // CMUX_REMOTE_MOBILE_H
