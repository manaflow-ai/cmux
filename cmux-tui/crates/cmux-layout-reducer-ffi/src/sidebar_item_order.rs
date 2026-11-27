//! Sidebar item ordering rules over the JSON channel: `sidebar_item_order`.

use cmux_layout_reducer::sidebar_item_order;

use crate::ERR_INVALID;

pub(crate) fn handles(operation: &[u8]) -> bool {
    operation == b"sidebar_item_order"
}

pub(crate) fn respond(_operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    let request: sidebar_item_order::Request =
        serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
    serde_json::to_vec(&sidebar_item_order::respond(request)).map_err(|_| ERR_INVALID)
}
