//! Sidebar document listing rules over the JSON channel: `sidebar_doc_listing`.

use cmux_layout_reducer::sidebar_doc_listing;

use crate::ERR_INVALID;

pub(crate) fn handles(operation: &[u8]) -> bool {
    operation == b"sidebar_doc_listing"
}

pub(crate) fn respond(_operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    let request: sidebar_doc_listing::Request =
        serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
    serde_json::to_vec(&sidebar_doc_listing::respond(request)).map_err(|_| ERR_INVALID)
}
