//! `cmux-layout-reducer`'s layout geometry rules over the JSON channel (ops `layout_geometry_*`): drop
//! zones and targets, the dock strip's placement, divider bands and pane chrome rects (Swift
//! `CmuxNextLayout/Geometry`). Stateless: every call answers from its request alone.

use crate::ERR_INVALID;
use cmux_layout_reducer::geometry::wire;

pub(crate) fn handles(operation: &[u8]) -> bool {
    std::str::from_utf8(operation).is_ok_and(wire::serves)
}

pub(crate) fn respond(operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    let operation = std::str::from_utf8(operation).map_err(|_| ERR_INVALID)?;
    let request = if request.is_empty() {
        serde_json::Value::Null
    } else {
        serde_json::from_slice(request).map_err(|_| ERR_INVALID)?
    };
    let reply = wire::call(operation, request).map_err(|_| ERR_INVALID)?;
    serde_json::to_vec(&reply).map_err(|_| ERR_INVALID)
}
