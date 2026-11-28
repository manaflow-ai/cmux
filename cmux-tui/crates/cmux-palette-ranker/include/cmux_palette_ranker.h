#ifndef CMUX_PALETTE_RANKER_H
#define CMUX_PALETTE_RANKER_H

#include <stddef.h>
#include <stdint.h>

/* The shared command-palette ranker (cmux-tui/crates/cmux-palette-ranker).
 * Requests and responses are the JSON shapes of PaletteRankRequest and
 * PaletteRankedSection[]. One handle per caller; calls on one handle are
 * serialized by the caller. */

enum {
    CMUX_PALETTE_RANKER_OK = 0,
    CMUX_PALETTE_RANKER_ERR_NULL = -1,
    CMUX_PALETTE_RANKER_ERR_INVALID = -2,
    CMUX_PALETTE_RANKER_ERR_NOT_INSTALLED = -3,
    CMUX_PALETTE_RANKER_ERR_PANIC = -4,
};

typedef struct CmuxPaletteRanker CmuxPaletteRanker;

uint32_t cmux_palette_ranker_abi_version(void);
CmuxPaletteRanker *cmux_palette_ranker_new(void);
void cmux_palette_ranker_free(CmuxPaletteRanker *ranker);
/* Holds a JSON array of entries for `version`; a request for that version may omit `entries`. */
int32_t cmux_palette_ranker_install(
    CmuxPaletteRanker *ranker,
    int64_t version,
    const uint8_t *entries,
    size_t entries_len);
/* Ranks one JSON request. On OK, `*response` is the ranked sections JSON; on an
 * error it is a message, except CMUX_PALETTE_RANKER_ERR_NULL, which leaves a null
 * response of length 0 (nothing is written when an out pointer is null). The
 * bytes stay valid until the next call on `ranker`. A handle is not thread-safe. */
int32_t cmux_palette_ranker_rank(
    CmuxPaletteRanker *ranker,
    const uint8_t *request,
    size_t request_len,
    const uint8_t **response,
    size_t *response_len);

#endif
