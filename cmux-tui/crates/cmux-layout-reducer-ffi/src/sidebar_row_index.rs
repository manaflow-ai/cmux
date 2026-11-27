//! Sidebar row index rules over the JSON channel: `sidebar_row_index`.

use cmux_layout_reducer::sidebar_row_index;

use crate::ERR_INVALID;

pub(crate) fn handles(operation: &[u8]) -> bool {
    operation == b"sidebar_row_index"
}

pub(crate) fn respond(_operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    let request: sidebar_row_index::Request =
        serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
    serde_json::to_vec(&sidebar_row_index::respond(request)).map_err(|_| ERR_INVALID)
}
