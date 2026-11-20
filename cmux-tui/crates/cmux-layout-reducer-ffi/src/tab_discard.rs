//! `cmux-tab-discard`'s rules over the JSON channel (ops `tab_discard_*`): which hidden browser
//! tabs freeze, which are discarded and which are kept (audio, unsaved form input, pinned,
//! capture). The app has one hibernation controller, so one set of rules (its probe history)
//! serves every call.

use crate::ERR_INVALID;
use cmux_tab_discard::ops::TabDiscard;
use std::sync::{Mutex, PoisonError};

static RULES: Mutex<Option<TabDiscard>> = Mutex::new(None);

pub(crate) fn handles(operation: &[u8]) -> bool {
    std::str::from_utf8(operation).is_ok_and(TabDiscard::serves)
}

pub(crate) fn respond(operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    let operation = std::str::from_utf8(operation).map_err(|_| ERR_INVALID)?;
    let request = if request.is_empty() {
        serde_json::Value::Null
    } else {
        serde_json::from_slice(request).map_err(|_| ERR_INVALID)?
    };
    let mut rules = RULES.lock().unwrap_or_else(PoisonError::into_inner);
    let reply = rules
        .get_or_insert_with(TabDiscard::new)
        .call(operation, request)
        .map_err(|_| ERR_INVALID)?;
    serde_json::to_vec(&reply).map_err(|_| ERR_INVALID)
}
