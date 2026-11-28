//! `cmux-app-feed`'s rules over the JSON channel (ops `app_feed_*`): what the Feed posts for an
//! agent's prompt, whether a phone's answer reaches the agent (its presence-key proof), the agent
//! dialogs the control socket lists and answers, the phone's Needs You list, GitHub card actions
//! and the update card's posting step. Stateless: the app keeps what it posted.

use crate::ERR_INVALID;
use cmux_app_feed::AppFeed;

pub(crate) fn handles(operation: &[u8]) -> bool {
    std::str::from_utf8(operation).is_ok_and(AppFeed::serves)
}

pub(crate) fn respond(operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    let operation = std::str::from_utf8(operation).map_err(|_| ERR_INVALID)?;
    let request = if request.is_empty() {
        serde_json::Value::Null
    } else {
        serde_json::from_slice(request).map_err(|_| ERR_INVALID)?
    };
    let reply = AppFeed::new().call(operation, request).map_err(|_| ERR_INVALID)?;
    serde_json::to_vec(&reply).map_err(|_| ERR_INVALID)
}
