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

/// The most reply text one answer carries, all replies together: it fits one mesh hub message
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

/// What each older reply keeps at least, when the newer ones are long.
const MIN_REPLY_BYTES: usize = 1024;

/// `replies` in about `budget` bytes of text, newest first: each reply keeps what the newer
/// ones left, less [`MIN_REPLY_BYTES`] for each older one, so the reply a reader came for is
/// whole whenever it fits and every older one still says how it began. A cut reply ends in "…",
/// and `true` says one was cut.
pub(crate) fn fit(mut replies: Vec<String>, budget: usize) -> (Vec<String>, bool) {
    let mut left = budget;
    let mut truncated = false;
    let n = replies.len();
    for (done, reply) in replies.iter_mut().rev().enumerate() {
        let older = n.saturating_sub(done + 1);
        let keep = left.saturating_sub(older.saturating_mul(MIN_REPLY_BYTES)).max(MIN_REPLY_BYTES);
        if reply.len() > keep {
            let cut = keep.saturating_sub("…".len());
            let end = (0..=cut).rev().find(|i| reply.is_char_boundary(*i)).unwrap_or(0);
            reply.truncate(end);
            reply.push('…');
            truncated = true;
        }
        left = left.saturating_sub(reply.len());
    }
    (replies, truncated)
}
