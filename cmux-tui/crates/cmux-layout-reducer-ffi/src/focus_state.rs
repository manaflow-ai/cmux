//! `cmux-focus-core`'s focus read view rules over the JSON channel (ops `focus_state_*`): what a
//! resolved focus types into, whether keys typed ahead still wait, a topology without a pane,
//! who chose an event, a responder's `debug.focus` name and the machine's re-apply on a wait
//! change. Shapes: cmux-focus-core/src/state_rules.rs.

use crate::ERR_INVALID;
use cmux_focus_core::state_rules;

pub(crate) fn handles(operation: &[u8]) -> bool {
    std::str::from_utf8(operation).is_ok_and(|op| state_rules::OPERATIONS.contains(&op))
}

pub(crate) fn respond(operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    let operation = std::str::from_utf8(operation).map_err(|_| ERR_INVALID)?;
    let reply = state_rules::call(operation, request).ok_or(ERR_INVALID)?;
    serde_json::to_vec(&reply).map_err(|_| ERR_INVALID)
}
