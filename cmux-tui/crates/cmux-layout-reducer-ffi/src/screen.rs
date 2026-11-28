//! `cmux-rd-screen`'s screen stream rules over the JSON channel (`screen_*`).
//! The dispatcher lives in `cmux_rd_screen::json`, which cmux-mobile-ffi's
//! `screen_json` also calls, so the Mac and iOS answer every op the same way.

use crate::ERR_INVALID;

/// Whether `operation` is one of this module's.
pub(crate) fn handles(operation: &[u8]) -> bool {
    operation.starts_with(cmux_rd_screen::json::OPERATION_PREFIX.as_bytes())
}

pub(crate) fn respond(operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    let operation = std::str::from_utf8(operation).map_err(|_| ERR_INVALID)?;
    let answer = cmux_rd_screen::json::respond(operation, request).map_err(|_| ERR_INVALID)?;
    serde_json::to_vec(&answer).map_err(|_| ERR_INVALID)
}

#[cfg(test)]
#[path = "screen_tests.rs"]
mod tests;
