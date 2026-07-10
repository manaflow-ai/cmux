#ifndef CMUX_IROH_FFI_H
#define CMUX_IROH_FFI_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define CMUX_IROH_SECRET_KEY_LEN 32

typedef struct CmuxIrohEndpoint CmuxIrohEndpoint;
typedef struct CmuxIrohConnection CmuxIrohConnection;

typedef enum CmuxIrohErrorKind {
    CMUX_IROH_ERROR_NONE = 0,
    CMUX_IROH_ERROR_INVALID_ARGUMENT = 1,
    CMUX_IROH_ERROR_TIMED_OUT = 2,
    CMUX_IROH_ERROR_CONNECTION_REFUSED = 3,
    CMUX_IROH_ERROR_HOST_UNREACHABLE = 4,
    CMUX_IROH_ERROR_PERMISSION_DENIED = 5,
    CMUX_IROH_ERROR_DNS_FAILED = 6,
    CMUX_IROH_ERROR_SECURE_CHANNEL_FAILED = 7,
    CMUX_IROH_ERROR_ENDPOINT_CLOSED = 8,
    CMUX_IROH_ERROR_NOT_CONNECTED = 9,
    CMUX_IROH_ERROR_IO = 10,
    CMUX_IROH_ERROR_INTERNAL = 11,
} CmuxIrohErrorKind;

typedef struct CmuxIrohError {
    uint32_t kind;
    char *message;
    size_t message_cap;
} CmuxIrohError;

int cmux_iroh_secret_key_generate(uint8_t *out_secret_key,
                                  size_t out_secret_key_len,
                                  CmuxIrohError *error);

CmuxIrohEndpoint *cmux_iroh_endpoint_bind(const uint8_t *secret_key,
                                          size_t secret_key_len,
                                          bool enable_relay,
                                          bool accept_connections,
                                          CmuxIrohError *error);

char *cmux_iroh_endpoint_id(const CmuxIrohEndpoint *endpoint);

char *cmux_iroh_endpoint_route_json(const CmuxIrohEndpoint *endpoint);

int cmux_iroh_endpoint_online(CmuxIrohEndpoint *endpoint,
                              uint64_t timeout_ms,
                              CmuxIrohError *error);

CmuxIrohConnection *cmux_iroh_endpoint_accept(CmuxIrohEndpoint *endpoint,
                                              uint64_t timeout_ms,
                                              CmuxIrohError *error);

CmuxIrohConnection *cmux_iroh_endpoint_connect(CmuxIrohEndpoint *endpoint,
                                               const char *endpoint_id,
                                               const char *relay_url,
                                               const char *const *direct_addrs,
                                               size_t direct_addr_count,
                                               uint64_t timeout_ms,
                                               CmuxIrohError *error);

intptr_t cmux_iroh_connection_recv(CmuxIrohConnection *connection,
                                   uint8_t *buf,
                                   size_t cap,
                                   CmuxIrohError *error);

int cmux_iroh_connection_send(CmuxIrohConnection *connection,
                              const uint8_t *bytes,
                              size_t len,
                              CmuxIrohError *error);

void cmux_iroh_connection_close(CmuxIrohConnection *connection);

void cmux_iroh_endpoint_close(CmuxIrohEndpoint *endpoint);

void cmux_iroh_string_free(char *string);

#ifdef __cplusplus
}
#endif

#endif
