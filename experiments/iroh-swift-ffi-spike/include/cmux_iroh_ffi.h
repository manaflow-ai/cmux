// Minimal C FFI over iroh for the cmux mobile transport spike.
// See rust/src/lib.rs for semantics. All blocking; call off the main thread.

#ifndef CMUX_IROH_FFI_H
#define CMUX_IROH_FFI_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct CmuxIrohEndpoint CmuxIrohEndpoint;
typedef struct CmuxIrohConnection CmuxIrohConnection;

CmuxIrohEndpoint *cmux_iroh_endpoint_bind(
    bool enable_relay,
    bool accept_connections,
    char *err_buf,
    size_t err_cap);

char *cmux_iroh_endpoint_id(const CmuxIrohEndpoint *endpoint);

char *cmux_iroh_endpoint_route_json(const CmuxIrohEndpoint *endpoint);

int cmux_iroh_endpoint_online(
    CmuxIrohEndpoint *endpoint,
    uint64_t timeout_ms,
    char *err_buf,
    size_t err_cap);

CmuxIrohConnection *cmux_iroh_endpoint_accept(
    CmuxIrohEndpoint *endpoint,
    uint64_t timeout_ms,
    char *err_buf,
    size_t err_cap);

CmuxIrohConnection *cmux_iroh_endpoint_connect(
    CmuxIrohEndpoint *endpoint,
    const char *endpoint_id,
    const char *relay_url,
    const char *const *direct_addrs,
    size_t direct_addr_count,
    uint64_t timeout_ms,
    char *err_buf,
    size_t err_cap);

intptr_t cmux_iroh_connection_recv(
    CmuxIrohConnection *connection,
    uint8_t *buf,
    size_t cap,
    char *err_buf,
    size_t err_cap);

int cmux_iroh_connection_send(
    CmuxIrohConnection *connection,
    const uint8_t *bytes,
    size_t len,
    char *err_buf,
    size_t err_cap);

void cmux_iroh_connection_close(CmuxIrohConnection *connection);

void cmux_iroh_endpoint_close(CmuxIrohEndpoint *endpoint);

void cmux_iroh_string_free(char *string);

#ifdef __cplusplus
}
#endif

#endif // CMUX_IROH_FFI_H
