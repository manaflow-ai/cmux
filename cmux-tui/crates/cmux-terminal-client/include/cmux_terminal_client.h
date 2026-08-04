#ifndef CMUX_TERMINAL_CLIENT_H
#define CMUX_TERMINAL_CLIENT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct CmuxTerminalClient CmuxTerminalClient;
typedef struct CmuxFrontendClient CmuxFrontendClient;
typedef struct CmuxFrontendTerminal CmuxFrontendTerminal;
typedef void (*CmuxTerminalClientUpdateCallback)(void *context);

typedef enum {
    CMUX_FRONTEND_RENDER_RESET = 1,
    CMUX_FRONTEND_RENDER_BYTES = 2,
    CMUX_FRONTEND_RENDER_RESIZE = 3,
    CMUX_FRONTEND_RENDER_READY = 4,
    CMUX_FRONTEND_RENDER_EXIT = 5,
} CmuxFrontendRenderEventKind;

typedef struct {
    uint32_t kind;
    uint16_t cols;
    uint16_t rows;
    size_t payload_length;
} CmuxFrontendRenderEvent;

// Native frontend API. One enrolled client owns resource control plus any
// number of terminal renderer attachments. Disconnect every terminal before
// disconnecting its client.
CmuxFrontendClient *cmux_frontend_client_connect_with_timeout(
    const char *invitation_uri,
    char *error_buffer,
    size_t error_capacity,
    uint64_t timeout_milliseconds);
void cmux_frontend_client_set_update_callback(
    const CmuxFrontendClient *client,
    CmuxTerminalClientUpdateCallback callback,
    void *context);
char *cmux_frontend_client_request(
    CmuxFrontendClient *client,
    const char *operation,
    const char *params_json,
    bool mutation,
    char *error_buffer,
    size_t error_capacity);
void cmux_frontend_string_free(char *value);
CmuxFrontendTerminal *cmux_frontend_client_attach_terminal(
    CmuxFrontendClient *client,
    const char *terminal_id,
    char *error_buffer,
    size_t error_capacity,
    uint64_t timeout_milliseconds);
size_t cmux_frontend_client_copy_diagnostics(
    const CmuxFrontendClient *client,
    char *buffer,
    size_t capacity);
void cmux_frontend_client_disconnect(CmuxFrontendClient *client);

void cmux_frontend_terminal_set_update_callback(
    const CmuxFrontendTerminal *terminal,
    CmuxTerminalClientUpdateCallback callback,
    void *context);
bool cmux_frontend_terminal_send(
    CmuxFrontendTerminal *terminal,
    const uint8_t *bytes,
    size_t length);
bool cmux_frontend_terminal_send_key(
    CmuxFrontendTerminal *terminal,
    const char *chord,
    bool repeat);
bool cmux_frontend_terminal_paste(
    CmuxFrontendTerminal *terminal,
    const uint8_t *bytes,
    size_t length);
bool cmux_frontend_terminal_resize(
    CmuxFrontendTerminal *terminal,
    uint16_t cols,
    uint16_t rows);
bool cmux_frontend_terminal_copy_next_render_event(
    const CmuxFrontendTerminal *terminal,
    CmuxFrontendRenderEvent *event,
    uint8_t *buffer,
    size_t capacity);
size_t cmux_frontend_terminal_copy_frame(
    const CmuxFrontendTerminal *terminal,
    char *buffer,
    size_t capacity);
size_t cmux_frontend_terminal_copy_diagnostics(
    const CmuxFrontendTerminal *terminal,
    char *buffer,
    size_t capacity);
bool cmux_frontend_terminal_has_exited(const CmuxFrontendTerminal *terminal);
void cmux_frontend_terminal_disconnect(CmuxFrontendTerminal *terminal);

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
void cmux_terminal_client_detach(CmuxTerminalClient *client);
void cmux_terminal_client_set_update_callback(
    const CmuxTerminalClient *client,
    CmuxTerminalClientUpdateCallback callback,
    void *context);
void cmux_terminal_client_disconnect(CmuxTerminalClient *client);

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
bool cmux_terminal_client_resize(CmuxTerminalClient *client, uint16_t cols, uint16_t rows);

// Returns the complete UTF-8 byte count. A non-null buffer is always NUL
// terminated when capacity is nonzero, so callers can use a two-pass copy.
size_t cmux_terminal_client_copy_frame(
    const CmuxTerminalClient *client,
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
