#ifndef CMUX_TERMINAL_CLIENT_H
#define CMUX_TERMINAL_CLIENT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct CmuxTerminalClient CmuxTerminalClient;
typedef struct CmuxWireGuardNet CmuxWireGuardNet;
typedef void (*CmuxTerminalClientUpdateCallback)(void *context);
// Raw terminal output for an embedding renderer. kind is one of the
// CMUX_TERMINAL_OUTPUT_* values below. For SNAPSHOT, bytes are the replay to
// feed a fresh parser sized cols x rows. For OUTPUT, bytes are live VT output.
// RESIZED carries cols and rows only. EXIT carries nothing. bytes is valid
// only for the duration of the call.
typedef void (*CmuxTerminalClientOutputCallback)(
    void *context,
    uint32_t kind,
    const uint8_t *bytes,
    size_t length,
    uint16_t cols,
    uint16_t rows);
#define CMUX_TERMINAL_OUTPUT_SNAPSHOT 1u
#define CMUX_TERMINAL_OUTPUT_OUTPUT 2u
#define CMUX_TERMINAL_OUTPUT_RESIZED 3u
#define CMUX_TERMINAL_OUTPUT_EXIT 4u

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
// Connects by route with a persistent device identity and no terminal
// attached. route is ws://, wss://, or iroh://. state_dir holds this device's
// key and its enrolled daemons (created 0700 when missing). invitation_uri
// enrolls on first contact and may be NULL afterwards, when the enrolled key is
// used; a NULL invitation with no enrolled daemon for the route fails.
// wireguard may be NULL; when set, addresses inside that tunnel's routes are
// dialed through it. timeout_milliseconds of 0 means no deadline. Install an
// output callback, then attach a terminal.
CmuxTerminalClient *cmux_terminal_client_connect_route(
    const char *route,
    const char *state_dir,
    const char *device_name,
    const char *invitation_uri,
    const CmuxWireGuardNet *wireguard,
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
// Installs the raw output callback, or clears it with NULL. Install it before
// attaching: the delivery mode is fixed when an attach begins, and a client
// attached without a callback keeps decoding text frames locally until it is
// detached and attached again. While a callback is installed the frame copy
// functions below return empty frames. The callback runs on internal worker
// threads with no client lock held, so it may call this API. context must
// remain valid until the callback is cleared or the client is disconnected.
void cmux_terminal_client_set_output_callback(
    CmuxTerminalClient *client,
    CmuxTerminalClientOutputCallback callback,
    void *context);
// Stops all work and frees client. The pointer must not be used afterward.
void cmux_terminal_client_disconnect(CmuxTerminalClient *client);

// Starts an in-process WireGuard tunnel from wg-quick config text that carries
// PrivateKey. Keys stay in memory. The tunnel may back any number of clients
// and stays up until cmux_wireguard_net_free, which must run only after every
// client that used it has been disconnected. Returns NULL on failure with the
// error written to error_buffer.
CmuxWireGuardNet *cmux_wireguard_net_start(
    const char *config,
    char *error_buffer,
    size_t error_capacity);
void cmux_wireguard_net_free(CmuxWireGuardNet *net);

// Terminal catalog over the daemon's mux control service. Both return an owned
// NUL-terminated UTF-8 JSON string to release with
// cmux_terminal_client_string_free, or NULL with the error written.
// list returns the terminal.list result array. create runs workspace.create
// with initial_content "terminal" and returns the mutation result
// (MutationResult<CreatedPath>), whose value.terminal_id is the id to attach. name may be NULL. A timeout of 0 means
// no deadline.
char *cmux_terminal_client_list_terminals(
    CmuxTerminalClient *client,
    char *error_buffer,
    size_t error_capacity,
    uint64_t timeout_milliseconds);
char *cmux_terminal_client_create_terminal(
    CmuxTerminalClient *client,
    const char *name,
    char *error_buffer,
    size_t error_capacity,
    uint64_t timeout_milliseconds);
void cmux_terminal_client_string_free(char *text);

// Input functions copy their input before returning. A false result means the
// command was not accepted by the local client queue. send_key needs the local
// parser and returns false while an output callback is installed; encode keys
// in the embedding renderer and use send instead.
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
