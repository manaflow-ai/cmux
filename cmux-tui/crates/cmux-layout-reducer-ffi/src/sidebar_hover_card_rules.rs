//! `cmux-layout-reducer`'s workspace hover card rules over the JSON channel:
//! `sidebar_hover_card_rules` (the hover card's choice and order).

use cmux_layout_reducer::sidebar_hover_card_rules;

use crate::ERR_INVALID;

/// Whether `operation` is one of this module's.
pub(crate) fn handles(operation: &[u8]) -> bool {
    operation == b"sidebar_hover_card_rules"
}

/// Answers `operation` for `request`.
pub(crate) fn respond(operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    debug_assert!(handles(operation));
    let request: sidebar_hover_card_rules::Request =
        serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
    serde_json::to_vec(&sidebar_hover_card_rules::respond(&request)).map_err(|_| ERR_INVALID)
}
