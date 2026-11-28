//! The Mac app's device rules (`rd_devices_*`, cmux-rd-core's `rd_devices`): device setup runs, the hub
//! link's decisions, Settings > Devices and Your Devices, over the JSON channel.

use crate::ERR_INVALID;
use cmux_rd_core::rd_devices::ops::RdDevices;
use std::sync::{Mutex, PoisonError};

static RULES: Mutex<Option<RdDevices>> = Mutex::new(None);

pub(crate) fn handles(operation: &[u8]) -> bool {
    std::str::from_utf8(operation).is_ok_and(RdDevices::serves)
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
        .get_or_insert_with(RdDevices::new)
        .call(operation, request)
        .map_err(|_| ERR_INVALID)?;
    serde_json::to_vec(&reply).map_err(|_| ERR_INVALID)
}

#[cfg(test)]
#[path = "rd_devices_tests.rs"]
mod tests;
