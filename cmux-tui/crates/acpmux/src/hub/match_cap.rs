//! The cap on a watch's `match` text (moved from `hub/mod.rs` as is).

/// The longest `match` a durable watch takes (`_acpmux/watch_add`): a stubbed reply chunk keeps
/// that much of its text's end (`paging.rs` `stub_msg`), so a match across chunks is never lost.
pub const MAX_MATCH_BYTES: usize = 2 * 1024;

/// Every `match` a request brings (`_acpmux/events`, `_acpmux/watch_add`) passes here: one past
/// [`MAX_MATCH_BYTES`] would make each stub keep that much of both its text's ends, past any page's
/// bound.
pub fn validate_match(pattern: Option<&str>) -> Result<(), crate::rpc::RpcError> {
    match pattern {
        Some(p) if p.len() > MAX_MATCH_BYTES => Err(crate::rpc::RpcError::invalid_params(format!(
            "match is at most {MAX_MATCH_BYTES} bytes: a watch on a peer chat keeps that much of each long reply's end to find a match across replies"
        ))),
        _ => Ok(()),
    }
}

/// A `match` saved before the cap, cut to [`MAX_MATCH_BYTES`] at a char boundary. Returns whether
/// it was cut.
pub(crate) fn cap_match(pattern: &mut Option<String>) -> bool {
    let Some(p) = pattern else { return false };
    if p.len() <= MAX_MATCH_BYTES {
        return false;
    }
    let mut end = MAX_MATCH_BYTES;
    while !p.is_char_boundary(end) {
        end -= 1;
    }
    p.truncate(end);
    true
}
