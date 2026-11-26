//! `cmux-import-suggest`'s rules over the JSON channel (ops `import_suggest_*`): Settings ›
//! Import's cards, dismissals, the Chief's cookie requests, the import jobs' transitions, what
//! the scan's file facts become, iTerm2's colors and the classic import prompt's lines.
//! Stateless: the app's saved state goes in with each call.

use crate::ERR_INVALID;
use cmux_import_suggest::ops;

pub(crate) fn handles(operation: &[u8]) -> bool {
    std::str::from_utf8(operation).is_ok_and(ops::serves)
}

pub(crate) fn respond(operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    let operation = std::str::from_utf8(operation).map_err(|_| ERR_INVALID)?;
    let request = if request.is_empty() {
        serde_json::Value::Null
    } else {
        serde_json::from_slice(request).map_err(|_| ERR_INVALID)?
    };
    let reply = ops::call(operation, request).map_err(|_| ERR_INVALID)?;
    serde_json::to_vec(&reply).map_err(|_| ERR_INVALID)
}
