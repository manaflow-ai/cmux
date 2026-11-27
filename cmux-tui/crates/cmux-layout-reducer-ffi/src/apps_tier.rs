//! `cmux-apps`'s Apps tier rules over the JSON channel (ops `apps_tier_*`, RFD 0003 step 4):
//! which browser page gets the Publish button, the Publish popover, a publish run's outcome and
//! the sidebar's Apps section (`cmux_apps::ui`). The app draws the answers; it decides none of it.

use crate::ERR_INVALID;

pub(crate) fn handles(operation: &[u8]) -> bool {
    operation.starts_with(b"apps_tier_")
}

pub(crate) fn respond(operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    let operation = std::str::from_utf8(operation).map_err(|_| ERR_INVALID)?;
    let request: serde_json::Value = if request.is_empty() {
        serde_json::Value::Null
    } else {
        serde_json::from_slice(request).map_err(|_| ERR_INVALID)?
    };
    let reply = cmux_apps::ui::respond(operation, &request).ok_or(ERR_INVALID)?;
    serde_json::to_vec(&reply).map_err(|_| ERR_INVALID)
}
