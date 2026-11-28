//! `cmux-window-rules` `handlers_agentmisc` over the JSON channel (ops `handlers_agentmisc_*`):
//! the decisions of the app's live, browser-history, terminal-comment, Chief and search handlers.
//! Its own prefix: `window_rules` answers every `window_` op.

use crate::ERR_INVALID;
use cmux_window_rules::handlers_agentmisc as rules;
use serde::Serialize;
use serde::de::DeserializeOwned;

const PREFIX: &[u8] = b"handlers_agentmisc_";

pub(crate) fn handles(operation: &[u8]) -> bool {
    operation.starts_with(PREFIX)
}

fn answer<Ask: DeserializeOwned, Reply: Serialize>(
    request: &[u8],
    rule: impl Fn(&Ask) -> Reply,
) -> Result<Vec<u8>, i32> {
    let ask: Ask = serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
    serde_json::to_vec(&rule(&ask)).map_err(|_| ERR_INVALID)
}

pub(crate) fn respond(operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    match &operation[PREFIX.len()..] {
        b"live_web" => answer(request, rules::live_web),
        b"live_swift" => answer(request, rules::live_swift),
        b"history_entry" => answer(request, rules::history_entry),
        b"comment_target" => answer(request, rules::comment_target),
        b"chief_toggle" => answer(request, rules::chief_toggle),
        b"chief_endpoint" => answer(
            request,
            |ask| serde_json::json!({ "usable": rules::chief_endpoint_usable(ask) }),
        ),
        b"search_text" => {
            answer(request, |ask| serde_json::json!({ "text": rules::search_text(ask) }))
        }
        _ => Err(ERR_INVALID),
    }
}
