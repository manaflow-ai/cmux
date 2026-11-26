//! `cmux-window-rules`' tab strip geometry over the JSON channel (ops `tab_layout_*`): the
//! strip's layout and resize, closing mode, drop gaps and reorder, scrolling with the pinned
//! band, each tab's icon, title and x, and the vertical tab list's rows and drop slots. The
//! requests and replies are `cmux_window_rules::tabs::layout::wire`'s.

use cmux_window_rules::tabs::layout::wire;

use crate::ERR_INVALID;

/// Whether `operation` is one of this module's.
pub(crate) fn handles(operation: &[u8]) -> bool {
    std::str::from_utf8(operation).is_ok_and(wire::handles)
}

pub(crate) fn respond(operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    let operation = std::str::from_utf8(operation).map_err(|_| ERR_INVALID)?;
    let reply = wire::respond(operation, request).ok_or(ERR_INVALID)?;
    serde_json::to_vec(&reply).map_err(|_| ERR_INVALID)
}
