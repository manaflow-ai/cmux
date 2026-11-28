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
/* Holds a JSON usage history (PaletteFrecency) for `revision`; a request whose
 * `historyRevision` is that revision may omit `frecency`. */
int32_t cmux_palette_ranker_install_history(
    CmuxPaletteRanker *ranker,
    int64_t revision,
    const uint8_t *history,
    size_t history_len);
/* Ranks one JSON request. On OK, `*response` is the ranked sections JSON; on an
 * error it is a message, except CMUX_PALETTE_RANKER_ERR_NULL, which leaves a null
 * response of length 0 (nothing is written when an out pointer is null). The
 * bytes stay valid until the next call on `ranker`. A handle is not thread-safe.
 * A request with "operation": "filter" answers the query's search filter
 * ({"rest", "include", "exclude", "applied"}) for its "sectionNames" instead. */
int32_t cmux_palette_ranker_rank(
    CmuxPaletteRanker *ranker,
    const uint8_t *request,
    size_t request_len,
    const uint8_t **response,
    size_t *response_len);

/* The palette's scope graph and navigation reducer (cmux-palette-ranker src/nav): one handle
 * holds the graph, the entry config and the navigation state. Requests are JSON objects with an
 * "op": "graph" {root, scopes, install} answers the registered graph and its problems; "config"
 * {config} answers it normalized; "reduce" {events, full} applies the events and answers
 * {effects, state}, whose levels carry "rows" only when they changed since the last answer (all
 * of them when "full"); "state" {full} answers the state; "tabSearchRows" {entries, style,
 * strings} answers Search Tabs rows (src/tab_search.rs) and leaves the state alone. Return codes are the ranker's; the
 * response bytes stay valid until the next call on `nav`. A handle is not thread-safe. */
typedef struct CmuxPaletteNav CmuxPaletteNav;

CmuxPaletteNav *cmux_palette_nav_new(void);
void cmux_palette_nav_free(CmuxPaletteNav *nav);
int32_t cmux_palette_nav_call(
    CmuxPaletteNav *nav,
    const uint8_t *request,
    size_t request_len,
    const uint8_t **response,
    size_t *response_len);

#endif
