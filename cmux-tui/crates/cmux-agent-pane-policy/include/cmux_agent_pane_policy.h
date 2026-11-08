#ifndef CMUX_AGENT_PANE_POLICY_H
#define CMUX_AGENT_PANE_POLICY_H

/* The agent pane's relay policy (cmux-tui/crates/cmux-agent-pane-policy,
 * src/ffi.rs): what a cmux host lets the agent pane page send to acpmux.
 * One handle per pane connection holds the pane's session scope and the
 * permission options the daemon sent. The host feeds it every daemon frame
 * it parsed (cmux_agent_pane_policy_observe) and what the pane sent (op
 * "sent"), and checks every page frame with one call
 * (cmux_agent_pane_policy_check). Default deny: a frame the policy does not
 * allow is refused. Every function may run on any thread at once. ABI
 * version 1.
 *
 * Return codes: 0 OK, 1 NO_SHAPE (filter_reply only), -1 a null pointer,
 * -2 invalid input (not UTF-8, not the JSON the op takes), -3 an unknown op,
 * -4 a panic inside (caught). On any code but 0 nothing is written to *out.
 * A host refuses the page frame on any error from the check. */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct CmuxAgentPanePolicy CmuxAgentPanePolicy;

/* A reply buffer owned by the caller: free it with
 * cmux_agent_pane_policy_bytes_free. ptr is NULL when len is 0. */
typedef struct {
    uint8_t *ptr;
    size_t len;
} CmuxAgentPaneBytes;

uint32_t cmux_agent_pane_policy_abi_version(void);

CmuxAgentPanePolicy *cmux_agent_pane_policy_new(void);
/* NULL is ignored. No call may use the handle afterwards. */
void cmux_agent_pane_policy_free(CmuxAgentPanePolicy *pane);
void cmux_agent_pane_policy_bytes_free(CmuxAgentPaneBytes bytes);

/* The full check of one page frame (text, UTF-8). token: the LocalApp token
 * for the first frame (NULL: none). mode_fields: a JSON array of the
 * daemon's mode field names (NULL: not known). *out gets one JSON object:
 *   {"refuse": "<code>", "method": m|null, "id": raw|null, "spend": ticket|null}
 *   {"frame": {the checked object}, "facts": {...}}
 * Send a fresh serialization of "frame", never the page's bytes. */
int32_t cmux_agent_pane_policy_check(const CmuxAgentPanePolicy *pane,
                                     const uint8_t *text, size_t text_len,
                                     bool first, bool remote_wire,
                                     const uint8_t *token, size_t token_len,
                                     const uint8_t *mode_fields, size_t mode_fields_len,
                                     CmuxAgentPaneBytes *out);

/* One daemon frame the host parsed (text, UTF-8, its id already the
 * page's; only after the host's duplicate-key check passed). reply_to: the
 * request a reply answers (NULL: none). */
int32_t cmux_agent_pane_policy_observe(const CmuxAgentPanePolicy *pane,
                                       const uint8_t *text, size_t text_len,
                                       const uint8_t *reply_to, size_t reply_to_len,
                                       bool remote_wire);

/* A daemon reply to method cut to its reply shape, with the page's id
 * (page_id, raw JSON): 0 and the reply text in *out, or 1 NO_SHAPE (the
 * method has none, or the reply is not one JSON object). */
int32_t cmux_agent_pane_policy_filter_reply(const uint8_t *method, size_t method_len,
                                            const uint8_t *reply, size_t reply_len,
                                            const uint8_t *page_id, size_t page_id_len,
                                            CmuxAgentPaneBytes *out);

/* One JSON op; request is a JSON object (or empty for {}); *out gets the
 * reply object. pane may be NULL for "policy", "refusal_frame" and
 * "raw_id"; the others need it.
 *   add {session} -> {}               sent {method, id?, handoff?, owned?} -> {}
 *   contains {session} -> {contains}  is_unstarted -> {unstarted}
 *   question_keys {permission} -> {keys: [..]|null}
 *   is_deny {permission, option} -> {deny}
 *   policy -> {initialize, maximum_frame_bytes, gesture_ticket_key,
 *              reply_shape_methods, question_answers, starting, handoff_records}
 *   refusal_frame {id, code, method?, root_requested?} -> {frame}
 *   raw_id {value} -> {id: raw|null} */
int32_t cmux_agent_pane_policy_call(const CmuxAgentPanePolicy *pane, const char *op,
                                    const uint8_t *request, size_t request_len,
                                    CmuxAgentPaneBytes *out);

#endif
