//! `cmux-window-rules` `tabs::strip` over the JSON channel: the tab strip's
//! commands on its tabs (ops `tab_strip_*`). Each request carries the strip
//! (`tabs` in display order, `collapsed` groups) and the tab it acts on.

use cmux_window_rules::tabs::strip::{self, Strip};
use serde::Deserialize;
use serde_json::json;
use std::collections::BTreeSet;

use crate::ERR_INVALID;

/// Whether `operation` is one of this module's.
pub(crate) fn handles(operation: &[u8]) -> bool {
    operation.starts_with(b"tab_strip_")
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Request {
    #[serde(flatten)]
    strip: Strip,
    id: Option<String>,
    #[serde(default)]
    offset: i64,
    selected: Option<String>,
    #[serde(default)]
    kept: BTreeSet<String>,
}

pub(crate) fn respond(operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    let r: Request = serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
    let id = || r.id.as_deref().ok_or(ERR_INVALID);
    let answer = match operation {
        // What Cmd-W does to `id`: close it, select another tab, or nothing.
        b"tab_strip_keyboard_close" => json!(r.strip.keyboard_close(id()?)),
        // Close Other Tabs, Close Tabs to the Left and to the Right from `id`.
        b"tab_strip_closed_by" => json!(r.strip.closed_by(id()?)),
        // The tab one of those selects; `tab` null: the selection stays.
        b"tab_strip_selection_keeping" => {
            json!({ "tab": strip::selection_keeping(r.selected.as_deref(), id()?, &r.kept) })
        }
        // Move Tab Left or Right; `index` null at the edge of its section.
        b"tab_strip_move_index" => json!({ "index": r.strip.move_index(id()?, r.offset) }),
        // Next or Previous Tab; `tab` null when the strip shows none.
        b"tab_strip_adjacent" => json!({ "tab": r.strip.adjacent(r.id.as_deref(), r.offset) }),
        _ => return Err(ERR_INVALID),
    };
    serde_json::to_vec(&answer).map_err(|_| ERR_INVALID)
}
