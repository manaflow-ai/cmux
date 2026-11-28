//! `new_tab_split_layout` {tree, split, ratio} -> predicted tree or null, for exact-size split prefetch.
use crate::ERR_INVALID;

pub(crate) fn handles(operation: &[u8]) -> bool {
    operation == b"new_tab_split_layout"
}

pub(crate) fn respond(_operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    let request = serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
    serde_json::to_vec(&cmux_layout_reducer::new_tab_split_layout::predict(request))
        .map_err(|_| ERR_INVALID)
}

#[cfg(test)]
#[path = "new_tab_split_layout_new_tab_split_layout_tests.rs"]
mod new_tab_split_layout_tests;
