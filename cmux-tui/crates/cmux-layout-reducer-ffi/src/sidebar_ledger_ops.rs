//! The auto-archive ledger (`auto_archive_ledger`), Cmd-Ctrl-[ / ] select (`sidebar_item_order`),
//! the document listing (`sidebar_doc_listing`) and each workspace's row places
//! (`sidebar_row_index`) over the JSON channel. #57757 added these arms to lib.rs's match while
//! #60470 moved the match out, so they live in their own op module.

use crate::ERR_INVALID;
use cmux_layout_reducer::{
    auto_archive_ledger, sidebar_doc_listing, sidebar_item_order, sidebar_row_index,
};

const OPS: [&[u8]; 4] =
    [b"auto_archive_ledger", b"sidebar_item_order", b"sidebar_doc_listing", b"sidebar_row_index"];

pub(crate) fn handles(operation: &[u8]) -> bool {
    OPS.contains(&operation)
}

pub(crate) fn respond(operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    let reply = match operation {
        b"auto_archive_ledger" => {
            serde_json::to_vec(&auto_archive_ledger::respond(parse(request)?))
        }
        b"sidebar_item_order" => serde_json::to_vec(&sidebar_item_order::respond(parse(request)?)),
        b"sidebar_doc_listing" => {
            serde_json::to_vec(&sidebar_doc_listing::respond(parse(request)?))
        }
        b"sidebar_row_index" => serde_json::to_vec(&sidebar_row_index::respond(parse(request)?)),
        _ => return Err(ERR_INVALID),
    };
    reply.map_err(|_| ERR_INVALID)
}

fn parse<T: serde::de::DeserializeOwned>(request: &[u8]) -> Result<T, i32> {
    serde_json::from_slice(request).map_err(|_| ERR_INVALID)
}
