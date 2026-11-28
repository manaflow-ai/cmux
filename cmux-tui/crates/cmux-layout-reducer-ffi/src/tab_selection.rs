//! `cmux-window-rules` `tabs::selection` over the JSON channel: the tab
//! strip's multi-selection (ops `tab_selection`, `tab_selection_move`,
//! `tab_selection_next_step`). The selection goes in and comes back on each
//! call; the app keeps it in its `TabStripModel`.

use cmux_window_rules::tabs::selection::{self, Click, MultiSelection};
use serde::Deserialize;
use serde_json::json;
use std::collections::BTreeSet;

use crate::ERR_INVALID;

/// Whether `operation` is one of this module's.
pub(crate) fn handles(operation: &[u8]) -> bool {
    operation == b"tab_selection" || operation.starts_with(b"tab_selection_")
}

/// What a selection change is.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
enum Change {
    /// A click on `id` in `order` (display order) while `active` is the active tab.
    Click { id: String, click: Click, order: Vec<String>, active: Option<String> },
    /// The strip's tabs are now `order`.
    Follow { order: Vec<String> },
    /// `id` became the active tab.
    Activated { id: Option<String> },
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ChangeRequest {
    #[serde(default)]
    selection: MultiSelection,
    change: Change,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct MoveRequest {
    order: Vec<String>,
    #[serde(default)]
    pinned: BTreeSet<String>,
    #[serde(default)]
    selection: BTreeSet<String>,
    index: i64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct StepRequest {
    current: Vec<String>,
    target: Vec<String>,
}

pub(crate) fn respond(operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    let answer = match operation {
        // The selection after a change; `active` the tab a click makes active (null: keep it).
        b"tab_selection" => {
            let ChangeRequest { mut selection, change } =
                serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
            let active = match change {
                Change::Click { id, click, order, active } => {
                    selection.click(&id, click, &order, active.as_deref())
                }
                Change::Follow { order } => {
                    selection.follow(&order);
                    None
                }
                Change::Activated { id } => {
                    selection.activated(id.as_deref());
                    None
                }
            };
            json!({ "selection": selection, "active": active })
        }
        // The order after moving the selected tabs to `index` (counted without them).
        b"tab_selection_move" => {
            let r: MoveRequest = serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
            json!({ "order": selection::moving(&r.order, &r.pinned, &r.selection, r.index) })
        }
        // A multi-tab drop's next one-tab move; `step` null once the orders agree.
        b"tab_selection_next_step" => {
            let r: StepRequest = serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
            json!({ "step": selection::next_step(&r.current, &r.target) })
        }
        _ => return Err(ERR_INVALID),
    };
    serde_json::to_vec(&answer).map_err(|_| ERR_INVALID)
}
