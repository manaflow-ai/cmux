#ifndef CMUX_URL_INPUT_H
#define CMUX_URL_INPUT_H

#include <stddef.h>
#include <stdint.h>

/* The typed address-bar policy (cmux-tui/crates/cmux-url-input, src/typed.rs):
 * what a person types into the omnibox, the New Tab field or newTab.submit
 * becomes a URL to load or a search. Called on every key: every function is
 * pure and thread-safe, the caller owns the output buffer, and nothing needs
 * a free. Text is UTF-8 bytes and a length (a null pointer only with length 0).
 * On CMUX_URL_INPUT_ERR_SHORT, `*out_len` is the length needed: call again with
 * a buffer that large. */

enum {
    CMUX_URL_INPUT_FOUND = 1,
    CMUX_URL_INPUT_NONE = 0,
    CMUX_URL_INPUT_ERR_NULL = -1,
    CMUX_URL_INPUT_ERR_UTF8 = -2,
    CMUX_URL_INPUT_ERR_SHORT = -3,
    CMUX_URL_INPUT_ERR_PANIC = -4,
};

/* `flags` of cmux_url_input_resolve_typed: the tab is a Chromium tab. */
enum { CMUX_URL_INPUT_FLAG_ALLOWS_CHROMIUM = 1 };

/* Kinds of cmux_url_input_chromium_page_route. */
enum {
    CMUX_URL_INPUT_ROUTE_NONE = 0,
    CMUX_URL_INPUT_ROUTE_CMUX_PAGE = 1,
    CMUX_URL_INPUT_ROUTE_BROWSER_SETTINGS = 2,
    CMUX_URL_INPUT_ROUTE_PASSWORDS_PAGE = 3,
    CMUX_URL_INPUT_ROUTE_CHROMIUM = 4,
};

uint32_t cmux_url_input_abi_version(void);

/* FOUND: the URL to load is in out[0..*out_len]. NONE: the text is a search.
 * `home` is the person's home folder as a path (`~` and `~/path`). */
int32_t cmux_url_input_resolve_typed(
    const uint8_t *input,
    size_t input_len,
    const uint8_t *home,
    size_t home_len,
    uint32_t flags,
    uint8_t *out,
    size_t out_cap,
    size_t *out_len);

/* FOUND when the text holds an old Mac Screen pairing link (cmux-vnc:pair...). */
int32_t cmux_url_input_contains_pairing_link(const uint8_t *text, size_t len);

/* FOUND when `host` (lowercased, IPv6 brackets stripped) is a loopback host. */
int32_t cmux_url_input_is_loopback_host(const uint8_t *host, size_t len);

/* FOUND: the canonical chrome:// or chrome-extension:// page of typed text is
 * in out[0..*out_len]. NONE: the text names no Chromium internal page. */
int32_t cmux_url_input_chromium_internal_url(
    const uint8_t *input,
    size_t input_len,
    uint8_t *out,
    size_t out_cap,
    size_t *out_len);

/* A CMUX_URL_INPUT_ROUTE_* kind, or a negative error. CMUX_PAGE writes the cmux
 * page URL and CHROMIUM the canonical page URL; other kinds write nothing. */
int32_t cmux_url_input_chromium_page_route(
    const uint8_t *url,
    size_t url_len,
    uint8_t *out,
    size_t out_cap,
    size_t *out_len);

#endif
