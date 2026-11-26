//! `cmux_layout_reducer::pane_close` over the JSON channel (ops `pane_close_*`): what a pane close
//! shows in the key's turn, the overlay of pending closes, the landed close sizes and the sizing
//! intents after a daemon tree. Each request is one JSON object; `schemas/pane-close/vectors.json`
//! has one of each with the answer the app's Swift rules gave.
//!
//! - `pane_close_remove` `{pane, layout}` -> `{layout}` (null: the close cannot show)
//! - `pane_close_successor` `{pane, layout}` -> `{successor}`
//! - `pane_close_show` `{pane, layout, sizing}` -> `{shown: {after, successor, splits, columns}}`
//! - `pane_close_overlay` `{layout, closes, landed, sizing}` -> `{layout}`
//! - `pane_close_note_landed` `{old, new, closes, landedPanes, landed, sizing}` -> `{landed}`
//! - `pane_close_flush` `{screens, closing, landed}` -> `{ratios, widths, landed}`
//! - `pane_close_sizing` `{old, new, landed, sizing}` -> `{ratios, widths}`
//!
//! `sizing` is `{even, fits}`; `landed` (sizes) is `{ratios: {split: r}, widths: {column: w}}`;
//! a screen is `{id, zoomed, layout}`; a layout is `crate::screen_layout`'s JSON.

use crate::ERR_INVALID;
use cmux_layout_reducer::pane_close::{
    Landed, Screen, Sizing, close_sizing, flush_landed_close_sizes, note_landed_closes,
    overlaying_pane_closes, removing_split_pane, show, successor,
};
use cmux_layout_reducer::screen_layout::Layout;
use serde::Deserialize;
use serde::de::DeserializeOwned;
use serde_json::{Value, json};
use std::collections::BTreeSet;

pub(crate) fn handles(operation: &[u8]) -> bool {
    operation.starts_with(b"pane_close_")
}

#[derive(Deserialize)]
struct PaneRequest {
    pane: String,
    layout: Layout,
    #[serde(default)]
    sizing: Sizing,
}

#[derive(Deserialize)]
struct OverlayRequest {
    layout: Layout,
    #[serde(default)]
    closes: Vec<String>,
    #[serde(default)]
    landed: Landed,
    #[serde(default)]
    sizing: Sizing,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct NoteLandedRequest {
    old: Vec<Screen>,
    new: Vec<Screen>,
    #[serde(default)]
    closes: Vec<String>,
    #[serde(default)]
    landed_panes: BTreeSet<String>,
    #[serde(default)]
    landed: Landed,
    #[serde(default)]
    sizing: Sizing,
}

#[derive(Deserialize)]
struct FlushRequest {
    screens: Vec<Layout>,
    #[serde(default)]
    closing: BTreeSet<String>,
    #[serde(default)]
    landed: Landed,
}

#[derive(Deserialize)]
struct SizingRequest {
    old: Vec<Screen>,
    new: Vec<Screen>,
    #[serde(default)]
    landed: BTreeSet<String>,
    #[serde(default)]
    sizing: Sizing,
}

fn parse<T: DeserializeOwned>(request: &[u8]) -> Result<T, i32> {
    serde_json::from_slice(request).map_err(|_| ERR_INVALID)
}

pub(crate) fn respond(operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    let reply: Value = match operation {
        b"pane_close_remove" => {
            let r: PaneRequest = parse(request)?;
            json!({ "layout": removing_split_pane(&r.pane, &r.layout) })
        }
        b"pane_close_successor" => {
            let r: PaneRequest = parse(request)?;
            json!({ "successor": successor(&r.pane, &r.layout) })
        }
        b"pane_close_show" => {
            let r: PaneRequest = parse(request)?;
            json!({ "shown": show(&r.pane, &r.layout, r.sizing) })
        }
        b"pane_close_overlay" => {
            let r: OverlayRequest = parse(request)?;
            json!({ "layout": overlaying_pane_closes(&r.layout, &r.closes, &r.landed, r.sizing) })
        }
        b"pane_close_note_landed" => {
            let mut r: NoteLandedRequest = parse(request)?;
            note_landed_closes(&r.old, &r.new, &r.closes, &r.landed_panes, &mut r.landed, r.sizing);
            json!({ "landed": r.landed })
        }
        b"pane_close_flush" => {
            let r: FlushRequest = parse(request)?;
            serde_json::to_value(flush_landed_close_sizes(&r.screens, &r.closing, &r.landed))
                .map_err(|_| ERR_INVALID)?
        }
        b"pane_close_sizing" => {
            let r: SizingRequest = parse(request)?;
            serde_json::to_value(close_sizing(&r.old, &r.new, &r.landed, r.sizing))
                .map_err(|_| ERR_INVALID)?
        }
        _ => return Err(ERR_INVALID),
    };
    serde_json::to_vec(&reply).map_err(|_| ERR_INVALID)
}
