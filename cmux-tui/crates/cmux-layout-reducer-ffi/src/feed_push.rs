//! `cmux-feed-push-core`'s feed push rules over the JSON channel (ops `feed_push_<op>`, such as
//! `feed_push_shown_text` and `feed_push_push_response`): the approve proof's signed bytes, the
//! banner categories and actions, the answer each action sends, and the `/v1/ops` bodies and
//! replies. The phones answer the same ops through cmux-mobile-ffi's `feed_push_json`.

use crate::ERR_INVALID;

const PREFIX: &[u8] = b"feed_push_";

pub(crate) fn handles(operation: &[u8]) -> bool {
    operation.starts_with(PREFIX)
}

pub(crate) fn respond(operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    let op = std::str::from_utf8(&operation[PREFIX.len()..]).map_err(|_| ERR_INVALID)?;
    let request: serde_json::Value = serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
    let answer = cmux_feed_push_core::ops::call(op, &request).map_err(|_| ERR_INVALID)?;
    serde_json::to_vec(&answer).map_err(|_| ERR_INVALID)
}
