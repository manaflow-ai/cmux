//! `_acpmux/last`: a session's last replies, read where its log is, in one reply.
//!
//! The pages `acpmux last` read one by one (`cli/last_reply.rs`) are read here, off the
//! runtime's workers, the same way and by the same rule, so a reader on another machine pays one
//! round trip whatever the turn's length. Through the mesh hub each page was its own round trip
//! of at most 40 KiB, and a coordinator's long turn ran past the 50 s a read waits
//! (cmuxterm-hq#15806).

use super::*;

/// The most replies one answer holds.
const MAX_COUNT: u64 = 50;

/// The most serialized reply array one answer carries: it fits one mesh hub message
/// (64 KiB) with the JSON around it and the `peer`/`via` the reader adds.
pub(crate) const REPLY_TEXT_BYTES: usize = 48 * 1024;

pub(super) fn last(
    hub: &Arc<Hub>,
    params: &Value,
    caller: Option<&str>,
) -> Result<Value, RpcError> {
    let s = hub.resolve(session_key(params)?)?;
    let count = params.get("count").and_then(Value::as_u64).unwrap_or(1).clamp(1, MAX_COUNT);
    let mut pages = crate::cli::last_reply::Pages::new(usize::try_from(count).unwrap_or(1));
    while let Some(query) = pages.next_query(&s.id) {
        pages.take(&super::events::handle(hub, method::MUX_EVENTS, &query, caller)?);
    }
    let (replies, truncated) = fit(pages.replies(), REPLY_TEXT_BYTES);
    Ok(json!({"sessionId": s.id, "replies": replies, "truncated": truncated}))
}

/// What each older reply reserves, in serialized bytes, when the newer ones are long.
const MIN_REPLY_BYTES: usize = 1024;

/// Fit the serialized array, including JSON escaping, quotes and separators. Reserve a
/// preview for every older reply without letting those reservations exceed the total budget
/// (50 replies cannot each reserve 1024 bytes inside 48 KiB). Newest replies get the rest.
/// A cut reply ends in "…", and `true` says one was cut.
pub(crate) fn fit(mut replies: Vec<String>, budget: usize) -> (Vec<String>, bool) {
    let n = replies.len();
    let mut left = budget.saturating_sub(2 + n.saturating_sub(1));
    let preview = MIN_REPLY_BYTES.min(left.checked_div(n).unwrap_or(0));
    let mut truncated = false;
    for (done, reply) in replies.iter_mut().rev().enumerate() {
        let older = n.saturating_sub(done + 1);
        let keep = left.saturating_sub(older.saturating_mul(preview));
        let bytes = serde_json::to_string(reply).expect("strings serialize").len();
        let used = if bytes > keep {
            let available = keep.saturating_sub(2 + "…".len());
            let mut encoded = 0;
            let mut end = 0;
            for (at, ch) in reply.char_indices() {
                let size = match ch {
                    '"' | '\\' | '\u{8}' | '\u{c}' | '\n' | '\r' | '\t' => 2,
                    '\u{0}'..='\u{1f}' => 6,
                    _ => ch.len_utf8(),
                };
                if encoded + size > available {
                    break;
                }
                encoded += size;
                end = at + ch.len_utf8();
            }
            reply.truncate(end);
            reply.push('…');
            truncated = true;
            encoded + 2 + "…".len()
        } else {
            bytes
        };
        left = left.saturating_sub(used);
    }
    (replies, truncated)
}
