#ifndef CMUX_ACTION_CATALOG_H
#define CMUX_ACTION_CATALOG_H

#include <stddef.h>
#include <stdint.h>

/* cmux NEXT's action catalog (cmux-tui/crates/cmux-action-catalog): every action
 * descriptor, the default key bindings and the palette tables, as one JSON text
 * per app language. */

enum {
    CMUX_ACTION_CATALOG_OK = 0,
    CMUX_ACTION_CATALOG_ERR_NULL = -1,
    CMUX_ACTION_CATALOG_ERR_PANIC = -4,
};

uint32_t cmux_action_catalog_abi_version(void);
/* The catalog JSON for `locale` (a BCP 47 tag, UTF-8, not NUL-terminated; empty for
 * English; an unknown language falls back to English). The bytes are owned by the
 * library and stay valid for the life of the process. */
int32_t cmux_action_catalog_json(
    const uint8_t *locale,
    size_t locale_len,
    const uint8_t **json,
    size_t *json_len);

#endif
