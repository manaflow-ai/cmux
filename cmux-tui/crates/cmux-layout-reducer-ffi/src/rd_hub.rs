//! `cmux-rd-core`'s device hub rules over the JSON channel (ops `rd_hub_*`): this Mac's host
//! reducer, each Mac Screen tab's viewer reducer by id, and the stateless rules (end reasons,
//! refusals, approval buttons, access levels, default sharing). One set serves every call.

use crate::ERR_INVALID;
use cmux_rd_core::rd_hub::ops::RdHub;
use std::sync::{Mutex, PoisonError};

static RULES: Mutex<Option<RdHub>> = Mutex::new(None);

pub(crate) fn handles(operation: &[u8]) -> bool {
    std::str::from_utf8(operation).is_ok_and(RdHub::serves)
}

pub(crate) fn respond(operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    let operation = std::str::from_utf8(operation).map_err(|_| ERR_INVALID)?;
    let request = if request.is_empty() {
        serde_json::Value::Null
    } else {
        serde_json::from_slice(request).map_err(|_| ERR_INVALID)?
    };
    let mut rules = RULES.lock().unwrap_or_else(PoisonError::into_inner);
    let reply =
        rules.get_or_insert_with(RdHub::new).call(operation, request).map_err(|_| ERR_INVALID)?;
    serde_json::to_vec(&reply).map_err(|_| ERR_INVALID)
}
