//! `cmux-phone-core`'s phone tab rules over the JSON channel (op `phone`): simctl, devicectl
//! and adb output, phone ids, keyboard usages, touches, the screen mapping, the log tail and
//! the UI Automator tree; the request's own `op` field picks one.

use crate::ERR_INVALID;

pub(crate) fn handles(operation: &[u8]) -> bool {
    operation == b"phone"
}

pub(crate) fn respond(_operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    cmux_phone_core::respond(request).map_err(|_| ERR_INVALID)
}
