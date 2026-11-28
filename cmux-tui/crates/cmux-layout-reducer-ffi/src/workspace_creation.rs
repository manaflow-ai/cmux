//! `cmux-app-workspace-creation`'s rules over the JSON channel (ops `workspace_creation_*`): a new
//! workspace's name, folder, environment and slot, the request it sends, and what a half-created
//! one does. Every op is pure.

use crate::ERR_INVALID;

pub(crate) fn handles(operation: &[u8]) -> bool {
    std::str::from_utf8(operation).is_ok_and(cmux_app_workspace_creation::ops::serves)
}

pub(crate) fn respond(operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    let operation = std::str::from_utf8(operation).map_err(|_| ERR_INVALID)?;
    let request = if request.is_empty() {
        serde_json::Value::Null
    } else {
        serde_json::from_slice(request).map_err(|_| ERR_INVALID)?
    };
    let reply =
        cmux_app_workspace_creation::ops::call(operation, request).map_err(|_| ERR_INVALID)?;
    serde_json::to_vec(&reply).map_err(|_| ERR_INVALID)
}
