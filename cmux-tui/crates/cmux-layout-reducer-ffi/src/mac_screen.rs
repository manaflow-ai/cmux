//! `cmux-rd-core`'s Mac Screen rules over the JSON channel (ops `mac_screen_*`): each Mac Screen
//! tab's session reducer by id (its phase, failure, connect stage, held offer and candidates,
//! live stats) and the stateless rules (the offer, the cmux.rd/1 document, the failure words,
//! the path label, the connect stages). One set of sessions serves the app.

use crate::ERR_INVALID;
use cmux_rd_core::mac_screen::ops::MacScreen;
use std::sync::{Mutex, PoisonError};

static RULES: Mutex<Option<MacScreen>> = Mutex::new(None);

pub(crate) fn handles(operation: &[u8]) -> bool {
    std::str::from_utf8(operation).is_ok_and(MacScreen::serves)
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
        .get_or_insert_with(MacScreen::new)
        .call(operation, request)
        .map_err(|_| ERR_INVALID)?;
    serde_json::to_vec(&reply).map_err(|_| ERR_INVALID)
}
