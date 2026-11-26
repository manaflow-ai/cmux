//! `cmux-hang-report`'s rules over the JSON channel (ops `hang_report_*`): which frames are named,
//! how watchdog stalls are counted and kept, how a report is built, scanned for private data and
//! fitted, and when one may be sent. Stateless: the app keeps the aggregate and passes it in.

use crate::ERR_INVALID;

pub(crate) fn handles(operation: &[u8]) -> bool {
    std::str::from_utf8(operation).is_ok_and(cmux_hang_report::ops::serves)
}

pub(crate) fn respond(operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    let operation = std::str::from_utf8(operation).map_err(|_| ERR_INVALID)?;
    let request = if request.is_empty() {
        serde_json::Value::Null
    } else {
        serde_json::from_slice(request).map_err(|_| ERR_INVALID)?
    };
    let reply = cmux_hang_report::ops::call(operation, request).map_err(|_| ERR_INVALID)?;
    serde_json::to_vec(&reply).map_err(|_| ERR_INVALID)
}
