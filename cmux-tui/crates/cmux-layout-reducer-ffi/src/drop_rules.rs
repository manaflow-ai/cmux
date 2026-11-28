//! `cmux-layout-reducer::drop_rules` over the JSON channel (ops `drop_*`):
//! what a drop means. The app keeps the drag session, the pasteboard and the
//! hit test, sends the facts and applies the answer.

use cmux_layout_reducer::drop_rules::{self, Slot};
use serde::Deserialize;
use serde_json::{Value, json};

use crate::ERR_INVALID;

/// Whether `operation` is one of this module's.
pub(crate) fn handles(operation: &[u8]) -> bool {
    // `drop_overlay_*` is `tab_drag_rules`' (the tab drag's overlay geometry).
    operation.starts_with(b"drop_") && !operation.starts_with(b"drop_overlay_")
}

fn read<'a, T: Deserialize<'a>>(request: &'a [u8]) -> Result<T, i32> {
    serde_json::from_slice(request).map_err(|_| ERR_INVALID)
}

fn to_value<T: serde::Serialize>(value: T) -> Result<Value, i32> {
    serde_json::to_value(value).map_err(|_| ERR_INVALID)
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Insertion {
    dragged_min_x: f64,
    #[serde(default)]
    group_start: f64,
    #[serde(default)]
    other_widths: Vec<f64>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct TabOverGroups {
    #[serde(default)]
    entries: Vec<Slot>,
    #[serde(default)]
    start: f64,
    dragged_min_x: f64,
    #[serde(default)]
    current_group: Option<String>,
    #[serde(default)]
    hysteresis: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LinkDrop {
    target: drop_rules::LayoutTarget,
    #[serde(default)]
    takes_tabs: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Transfer {
    #[serde(default)]
    sources: Vec<Option<i64>>,
    #[serde(default)]
    destination: Option<i64>,
    #[serde(default)]
    option: bool,
    #[serde(default)]
    command: bool,
}

pub(crate) fn respond(operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    let answer = match operation {
        // Where a dragged tab lands among its group's tabs.
        b"drop_tab_insertion" => {
            let request: Insertion = read(request)?;
            json!({ "index": drop_rules::insertion_index(request.dragged_min_x, request.group_start, &request.other_widths) })
        }
        // A tab over a strip with groups: index and membership.
        b"drop_tab_over_groups" => {
            let request: TabOverGroups = read(request)?;
            to_value(drop_rules::resolve_tab(
                &request.entries,
                request.start,
                request.dragged_min_x,
                request.current_group.as_deref(),
                request.hysteresis,
            ))?
        }
        // A whole group over a strip: its unit index and tab index.
        b"drop_group_over_groups" => {
            let request: TabOverGroups = read(request)?;
            to_value(drop_rules::resolve_group(
                &request.entries,
                request.start,
                request.dragged_min_x,
            ))?
        }
        // How a sidebar workspace drag ends.
        b"drop_workspace_outcome" => {
            to_value(drop_rules::workspace_outcome(&read::<drop_rules::WorkspaceDrag>(request)?))?
        }
        // What a link dropped on a layout target does.
        b"drop_link_plan" => {
            let request: LinkDrop = read(request)?;
            to_value(drop_rules::link_plan(request.target, request.takes_tabs))?
        }
        // Finder's copy-or-move rule for a file drop.
        b"drop_transfer_mode" => {
            let request: Transfer = read(request)?;
            json!({ "mode": drop_rules::transfer_mode(&request.sources, request.destination, request.option, request.command) })
        }
        _ => return Err(ERR_INVALID),
    };
    serde_json::to_vec(&answer).map_err(|_| ERR_INVALID)
}
