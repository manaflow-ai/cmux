//! The marks a create's answer (`session/new`'s `_meta.acpmux`) carries beside the chat's summary:
//! what the caller asked for and kept, and how the chat got its agent.

use serde_json::Value;

use crate::no_panic::JsonExt;
use crate::store::SessionMeta;

/// Sets `summary`'s marks for `meta`, a created chat.
pub(crate) fn mark(meta: &SessionMeta, summary: &mut Value) {
    // The stop condition it keeps (`hub/stop_condition.rs`): a caller that asked for one
    // and does not see it here knows its agent can stop at any turn end.
    if meta.stop_condition.is_some() {
        summary.set(crate::hub::stop_condition::FIELD, Value::Bool(true));
    }
    // Read-only in a folder not trusted (`hub/restricted.rs`).
    if meta.restricted {
        summary.set(crate::hub::restricted::FIELD, Value::Bool(true));
    }
    // Whether its agent came warm from the pool (`SessionMeta::start_pool`).
    if let Some(pool) = meta.start_pool {
        summary.set("startPool", Value::String(pool.to_owned()));
    }
}
