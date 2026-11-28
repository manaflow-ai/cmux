//! `cmux-layout-reducer`'s auto-archive ledger and sidebar listing rules over the JSON channel:
//! `auto_archive_ledger` (sights, prunes, archive or suggest, the card), `sidebar_item_order`
//! (the destinations in shown order and what Cmd-1...9 and Cmd-Ctrl-[ / ] select),
//! `sidebar_doc_listing` (where the document puts the list's rows) and `sidebar_row_index` (the
//! row index's rules). Each request is the rule's `Request`; each answer is its `respond`.

use cmux_layout_reducer::{
    auto_archive_ledger, sidebar_doc_listing, sidebar_item_order, sidebar_row_index,
};
use serde::Deserialize;

use crate::ERR_INVALID;

/// Whether `operation` is one of this module's.
pub(crate) fn handles(operation: &[u8]) -> bool {
    matches!(
        operation,
        b"auto_archive_ledger"
            | b"sidebar_item_order"
            | b"sidebar_doc_listing"
            | b"sidebar_row_index"
    )
}

fn read<'a, T: Deserialize<'a>>(request: &'a [u8]) -> Result<T, i32> {
    serde_json::from_slice(request).map_err(|_| ERR_INVALID)
}

pub(crate) fn respond(operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    let answer = match operation {
        b"auto_archive_ledger" => auto_archive_ledger::respond(read(request)?),
        b"sidebar_item_order" => sidebar_item_order::respond(read(request)?),
        b"sidebar_doc_listing" => sidebar_doc_listing::respond(read(request)?),
        b"sidebar_row_index" => sidebar_row_index::respond(read(request)?),
        _ => return Err(ERR_INVALID),
    };
    serde_json::to_vec(&answer).map_err(|_| ERR_INVALID)
}
