//! `cmux-app-closed-tabs`' closed tabs feed rules over the JSON channel (ops `closed_tabs_*`):
//! the closed history's listing, Cmd-Shift-T's pick, History's and the New Tab page's closed
//! rows, the reopen, delete and clear steps, and the close undo toast's glue. Every op is pure.

use crate::ERR_INVALID;

pub(crate) fn handles(operation: &[u8]) -> bool {
    std::str::from_utf8(operation).is_ok_and(cmux_app_closed_tabs::ops::serves)
}

pub(crate) fn respond(operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    let operation = std::str::from_utf8(operation).map_err(|_| ERR_INVALID)?;
    let request = if request.is_empty() {
        serde_json::Value::Null
    } else {
        serde_json::from_slice(request).map_err(|_| ERR_INVALID)?
    };
    let reply = cmux_app_closed_tabs::ops::call(operation, request).map_err(|_| ERR_INVALID)?;
    serde_json::to_vec(&reply).map_err(|_| ERR_INVALID)
}
