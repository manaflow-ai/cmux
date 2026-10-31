#ifndef CMUX_CHATS_MIRROR_H
#define CMUX_CHATS_MIRROR_H

#include <stddef.h>
#include <stdint.h>

/* The app's one mirror of acpmux's chat index (cmux-tui/crates/cmux-chats-mirror).
 *
 * A host parses each `_acpmux/chats_watch` line off the main thread
 * (cmux_chats_line_parse), then applies a batch on its own thread
 * (cmux_chats_feed_apply). Every call on a feed is safe from any thread: the
 * feed is locked inside. Readers get owned snapshots (CmuxChatsRows,
 * CmuxChatsBytes) that stay valid until freed. */

enum {
    CMUX_CHATS_CHANGED = 1,       /* the mirror changed: publish once */
    CMUX_CHATS_LAGGED = 2,        /* a change was lost: list again */
    CMUX_CHATS_PAGE = 4,          /* a page landed: the connection is healthy */
    CMUX_CHATS_INDEX_CHANGED = 8, /* membership, order or the listed set changed */
};

enum {
    CMUX_CHATS_READY = 1,   /* acpmux finished its first scan */
    CMUX_CHATS_ENABLED = 2, /* the chat index is turned on */
};

typedef struct CmuxChatsFeed CmuxChatsFeed;
typedef struct CmuxChatsLine CmuxChatsLine;
typedef struct CmuxChatsRows CmuxChatsRows;
typedef struct CmuxChatsBytes CmuxChatsBytes;

/* UTF-8 text; `ptr` is NULL when the field is absent. */
typedef struct {
    const uint8_t *ptr;
    size_t len;
} CmuxChatsText;

typedef struct {
    CmuxChatsText key;
    CmuxChatsText session_id;
    CmuxChatsText harness;
    CmuxChatsText title;
    CmuxChatsText cwd;
    CmuxChatsText source_path;
    CmuxChatsText brand;
    CmuxChatsText attention;
    CmuxChatsText preview;
    CmuxChatsText parent;
    const CmuxChatsText *accounts;
    size_t accounts_len;
    const CmuxChatsText *roots;
    size_t roots_len;
    double created_ms;   /* valid when has_created */
    double updated_ms;
    int64_t message_count; /* valid when has_message_count */
    uint8_t has_created;
    uint8_t has_message_count;
} CmuxChatsRow;

uint32_t cmux_chats_mirror_abi_version(void);

CmuxChatsFeed *cmux_chats_feed_new(void);
void cmux_chats_feed_free(CmuxChatsFeed *feed);

/* Decodes one watch line; NULL when it is not a page, change or lag line. Any thread. */
CmuxChatsLine *cmux_chats_line_parse(const uint8_t *bytes, size_t len);
/* Frees a line that was never applied. NULL is ignored. */
void cmux_chats_line_free(CmuxChatsLine *line);

/* A new connection sent the watch request: its page is in flight. */
void cmux_chats_feed_connection_started(CmuxChatsFeed *feed);
/* Applies `count` lines in order and takes ownership of every one (NULL entries are skipped).
 * Returns CMUX_CHATS_* flags. */
uint32_t cmux_chats_feed_apply(CmuxChatsFeed *feed, CmuxChatsLine *const *lines, size_t count);
/* 1: send a list request now (its page is in flight); 0: one is in flight, another follows it. */
int32_t cmux_chats_feed_want_list(CmuxChatsFeed *feed);
/* Replaces the index with a `_acpmux/chats` result object (`{"chats":[...]}`). 0 on success. */
int32_t cmux_chats_feed_load(CmuxChatsFeed *feed, const uint8_t *json, size_t len);

uint32_t cmux_chats_feed_status(const CmuxChatsFeed *feed);
/* Every chat, children included. */
size_t cmux_chats_feed_count(const CmuxChatsFeed *feed);
/* Bumped when membership, order or the listed set changes (not by activity alone). */
uint64_t cmux_chats_feed_generation(const CmuxChatsFeed *feed);

/* The listed chats (no child chat), newest first, from `offset`, at most `limit`. */
CmuxChatsRows *cmux_chats_feed_listed(const CmuxChatsFeed *feed, size_t offset, size_t limit);
/* The chat with `key` (zero or one row). */
CmuxChatsRows *cmux_chats_feed_chat(const CmuxChatsFeed *feed, const uint8_t *key, size_t key_len);
/* The newest chat continuing acpmux session `session` (zero or one row). */
CmuxChatsRows *cmux_chats_feed_by_session(const CmuxChatsFeed *feed, const uint8_t *session, size_t session_len);
/* {"<harness>": {"<cwd>": <newest updated ms>}} over the listed chats with an absolute cwd. */
CmuxChatsBytes *cmux_chats_feed_projects(const CmuxChatsFeed *feed);

const CmuxChatsRow *cmux_chats_rows_items(const CmuxChatsRows *rows, size_t *count);
void cmux_chats_rows_free(CmuxChatsRows *rows);
const uint8_t *cmux_chats_bytes_data(const CmuxChatsBytes *bytes, size_t *len);
void cmux_chats_bytes_free(CmuxChatsBytes *bytes);

#endif
