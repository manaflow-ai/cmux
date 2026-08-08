#ifndef CMUX_TERMINAL_CLIENT_H
#define CMUX_TERMINAL_CLIENT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct CmuxTerminalClient CmuxTerminalClient;
typedef void (*CmuxTerminalClientUpdateCallback)(void *context);

// Both connect functions return an owned client, or NULL on failure. The caller
// transfers that ownership exactly once to cmux_terminal_client_disconnect and
// must not use the pointer after disconnect begins. invitation_uri and
// terminal_id must be non-null NUL-terminated UTF-8 strings. error_buffer may
// be NULL; when non-null with nonzero capacity it receives a truncated, valid
// UTF-8, NUL-terminated error.
CmuxTerminalClient *cmux_terminal_client_connect(
    const char *invitation_uri,
    const char *terminal_id,
    char *error_buffer,
    size_t error_capacity);
CmuxTerminalClient *cmux_terminal_client_connect_with_timeout(
    const char *invitation_uri,
    const char *terminal_id,
    char *error_buffer,
    size_t error_capacity,
    uint64_t timeout_milliseconds);
// Both attach functions attach the requested terminal on an existing client.
// Reattaching the same terminal is a no-op. Attaching a different terminal
// requires detach first. error_buffer follows the connect buffer contract.
bool cmux_terminal_client_attach(
    CmuxTerminalClient *client,
    const char *terminal_id,
    char *error_buffer,
    size_t error_capacity);
bool cmux_terminal_client_attach_with_timeout(
    CmuxTerminalClient *client,
    const char *terminal_id,
    char *error_buffer,
    size_t error_capacity,
    uint64_t timeout_milliseconds);
// Stops the terminal stream while retaining the enrolled transport.
void cmux_terminal_client_detach(CmuxTerminalClient *client);
// Passing NULL clears the callback synchronously. The callback may run during
// registration and later on internal worker threads; calls are serialized.
// macOS callers must hop to the main actor before touching UI state. An
// invocation already in progress may overlap the start of disconnect, which
// waits for it and clears the registration before returning. context must
// remain valid until that clearing call or disconnect returns. The callback
// must not call this API because registration is locked during invocation.
void cmux_terminal_client_set_update_callback(
    CmuxTerminalClient *client,
    CmuxTerminalClientUpdateCallback callback,
    void *context);
// Stops all work and frees client. The pointer must not be used afterward.
void cmux_terminal_client_disconnect(CmuxTerminalClient *client);

// Input functions copy their input before returning. A false result means the
// command was not accepted by the local client queue.
bool cmux_terminal_client_send(
    CmuxTerminalClient *client,
    const uint8_t *bytes,
    size_t length);
bool cmux_terminal_client_send_key(
    CmuxTerminalClient *client,
    const char *chord,
    bool repeat);
bool cmux_terminal_client_paste(
    CmuxTerminalClient *client,
    const uint8_t *bytes,
    size_t length);
// Resize requests are coalesced to the newest geometry and delivered when the
// transport is writable. A false result means no live terminal is attached.
bool cmux_terminal_client_resize(CmuxTerminalClient *client, uint16_t cols, uint16_t rows);
// The request-ID form has the same delivery semantics and writes the nonzero
// protocol request ID when it accepts the resize. request_id must be non-null.
bool cmux_terminal_client_resize_with_request_id(
    CmuxTerminalClient *client,
    uint16_t cols,
    uint16_t rows,
    uint64_t *request_id);
// Returns false until a resize is acknowledged. All output pointers must be
// non-null and writable. A newer call replaces the prior acknowledged values.
bool cmux_terminal_client_last_resize_ack(
    const CmuxTerminalClient *client,
    uint64_t *request_id,
    uint16_t *cols,
    uint16_t *rows,
    bool *canonical_changed);

// The producer owns the snapshot and may change it between calls. Callers must
// bound two-pass retries and treat a returned length >= capacity as a truncated
// snapshot. Returned pointers are never borrowed from client storage.
#define CMUX_TERMINAL_CLIENT_COPY_MAX_BYTES (16u * 1024u * 1024u)
size_t cmux_terminal_client_copy_frame(
    const CmuxTerminalClient *client,
    char *buffer,
    size_t capacity);
// Returns the number of changed viewport rows in the latest frame. Passing a
// null buffer or insufficient capacity returns the required entry count.
size_t cmux_terminal_client_copy_frame_dirty_rows(
    const CmuxTerminalClient *client,
    uint16_t *buffer,
    size_t capacity);
size_t cmux_terminal_client_frame_row_count(const CmuxTerminalClient *client);
// Copies one zero-based viewport row from the latest frame.
size_t cmux_terminal_client_copy_frame_row(
    const CmuxTerminalClient *client,
    uint16_t row,
    char *buffer,
    size_t capacity);
size_t cmux_terminal_client_copy_diagnostics(
    const CmuxTerminalClient *client,
    char *buffer,
    size_t capacity);
bool cmux_terminal_client_has_exited(const CmuxTerminalClient *client);

#ifdef __cplusplus
}
#endif

#endif
