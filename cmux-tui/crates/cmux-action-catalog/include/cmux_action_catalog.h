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
    CMUX_ACTION_CATALOG_ERR_INVALID = -2,
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

/* cmux-next object links (cmux://tab/tab_<hex>, cmux://agent/<harness>/<session>, ...):
 * one JSON request (`{"op": "read", "url": ..., "scheme": ...}`, ops in
 * src/deep_link/json.rs) in, its JSON value out, links in the shape Swift's synthesized
 * Codable gives DeepLink. ERR_INVALID for a request that is not JSON or names an unknown
 * op. On OK `*reply` holds `*reply_len` UTF-8 bytes; free them with cmux_deep_link_free. */
int32_t cmux_deep_link_call(
    const uint8_t *request,
    size_t request_len,
    uint8_t **reply,
    size_t *reply_len);
/* Frees a reply of cmux_deep_link_call (null is a no-op). */
void cmux_deep_link_free(uint8_t *reply, size_t reply_len);

/* One JSON request, `{"op": ...}`, answered as JSON (src/ffi.rs `call`): the menu bar
 * menu's rows (`menu_bar_items` with `state`, `locale`, `bound`; `menu_bar_action_ids`),
 * the profile menu (`profile_menu` with `locale`), and `when` clauses (`when_parse` with
 * `text`, `when_text` with `clause`). The reply is the caller's to free with
 * cmux_action_catalog_reply_free. */
int32_t cmux_action_catalog_call(
    const uint8_t *request,
    size_t request_len,
    uint8_t **reply,
    size_t *reply_len);
void cmux_action_catalog_reply_free(uint8_t *reply, size_t reply_len);

#endif
