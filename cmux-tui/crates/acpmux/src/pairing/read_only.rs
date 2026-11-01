//! The read-only role, enforced by the daemon that serves the connection
//! (`server/chats.rs` checks every request before any other dispatcher):
//! a closed allow list of reads. Anything else, including every method
//! added later, is refused, and no notification from such a connection is
//! acted on (`server/mod.rs` `serve_connection_from` drops them).
//!
//! Allowed: the handshake, the session lists, watching and attaching
//! (always hidden, so the person's unread and seen state do not change),
//! a session's details, events, attachments, a queued prompt's text and turn history, waiting
//! for a session to settle, and resolving a name or link to a session
//! (`_acpmux/resolve`, answered from the same session list, without this
//! machine's or its peers' names: `hub/locate.rs`). Refused: prompts, new or forked sessions,
//! permission answers, policy, mode and model changes, kills, renames,
//! tags, drafts, mail, processes, harness and route admin, transfers.

use serde_json::Value;

use crate::rpc::method;

const ALLOWED: &[&str] = &[
    method::INITIALIZE,
    method::AUTHENTICATE,
    method::SESSION_LIST,
    method::MUX_SESSIONS,
    method::MUX_WATCH,
    method::MUX_ATTACH,
    method::MUX_DETACH,
    method::MUX_INFO,
    method::MUX_EVENTS,
    method::MUX_ATTACHMENT,
    method::MUX_QUEUE_TEXT,
    method::MUX_HISTORY,
    method::MUX_WAIT,
    method::MUX_SCHEMA,
    method::MUX_RESOLVE,
];

/// Whether a read-only connection may call `m`.
pub fn allows(m: &str) -> bool {
    ALLOWED.contains(&m)
}

/// The params a read-only request runs with: an attach never shows the
/// chat (it holds it hidden, `server/view.rs`).
pub fn scrub(m: &str, mut params: Value) -> Value {
    if m == method::MUX_ATTACH
        && let Some(obj) = params.as_object_mut()
    {
        obj.insert("visible".into(), Value::Bool(false));
    }
    params
}
