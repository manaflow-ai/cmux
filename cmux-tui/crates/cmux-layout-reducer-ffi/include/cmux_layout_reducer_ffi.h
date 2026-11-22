#ifndef CMUX_LAYOUT_REDUCER_FFI_H
#define CMUX_LAYOUT_REDUCER_FFI_H

#include <stddef.h>
#include <stdint.h>

enum {
    CMUX_LAYOUT_REDUCER_OK = 0,
    CMUX_LAYOUT_REDUCER_ERR_NULL = -1,
    CMUX_LAYOUT_REDUCER_ERR_INVALID = -2,
    CMUX_LAYOUT_REDUCER_ERR_BUFFER = -3,
    CMUX_LAYOUT_REDUCER_ERR_PANIC = -4,
};

uint32_t cmux_layout_reducer_ffi_abi_version(void);
int32_t cmux_layout_reducer_json(
    const uint8_t *request,
    size_t request_len,
    const char *operation,
    uint8_t *output,
    size_t output_capacity,
    size_t *output_len);

#endif
