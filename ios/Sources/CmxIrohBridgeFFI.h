#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef enum CmxIrohClientEventKind : uint32_t {
    CmxIrohClientEventKindConnected = 1,
    CmxIrohClientEventKindMessage = 2,
    CmxIrohClientEventKindClosed = 3,
    CmxIrohClientEventKindError = 4,
} CmxIrohClientEventKind;

typedef struct CmxIrohClientHandle CmxIrohClientHandle;

typedef void (*CmxIrohClientCallback)(
    void *_Nullable user_data,
    CmxIrohClientEventKind kind,
    const uint8_t *_Nullable data,
    size_t len
);

CmxIrohClientHandle *_Nullable cmux_iroh_client_connect(
    const char *_Nonnull ticket,
    const char *_Nullable pairing_secret,
    uint32_t relay_mode,
    CmxIrohClientCallback _Nonnull callback,
    void *_Nullable user_data
);

bool cmux_iroh_client_send(
    CmxIrohClientHandle *_Nonnull handle,
    const uint8_t *_Nullable data,
    size_t len
);

void cmux_iroh_client_disconnect(CmxIrohClientHandle *_Nullable handle);
