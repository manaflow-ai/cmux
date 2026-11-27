//! Exact-size idle New Tab frame preparation policy.
use crate::ERR_INVALID;

pub(crate) fn handles(operation: &[u8]) -> bool {
    operation == b"new_tab_prefetch"
}

pub(crate) fn respond(_operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    let request = serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
    serde_json::to_vec(&cmux_layout_reducer::new_tab_prefetch::plan(request))
        .map_err(|_| ERR_INVALID)
}
