//! The split a closed pane leaves (cx-gzh.32). A closing pane records, on
//! each of its tab members, the pane it was split off, the side of it it
//! took and its share of that split. Reopen puts the first of its tabs
//! back in a new pane split off that neighbor the same way, and the rest
//! after it; with the neighbor gone the tabs reopen as before.

use std::collections::HashMap;
use std::sync::Arc;

use rusqlite::{Connection, OptionalExtension};
use serde_json::{Value, json};

use crate::model::State;
use crate::mux::tab_groups::pane_by_public_id;
use crate::mux::*;
use crate::{Actor, PaneId, SurfaceId};

/// Where closing pane `pane_id` sits in the split tree of `screen_id`:
/// `neighbor` (the pane next to it in its split), `direction` (the side
/// of the neighbor it takes: left, right, up or down), `ratio` (its share
/// of the split) and `screen`. None when it is in no split (a screen's only
/// pane, or a stack member).
pub(super) fn pane_placement(
    connection: &Connection,
    screen_id: &str,
    pane_id: &str,
) -> anyhow::Result<Option<Value>> {
    let layout = connection
        .query_row(
            "SELECT layout_json FROM resource_screens WHERE public_id = ?1",
            [screen_id],
            |row| row.get::<_, String>(0),
        )
        .optional()?;
    let Some(layout) = layout else { return Ok(None) };
    let layout: Value = serde_json::from_str(&layout)?;
    Ok(placement_in(&layout, pane_id).map(|mut placement| {
        placement["screen"] = json!(screen_id);
        placement
    }))
}

fn placement_in(node: &Value, pane_id: &str) -> Option<Value> {
    if node["kind"] != "split" {
        return None;
    }
    let (first, second) = (&node["first"], &node["second"]);
    let ratio = node["ratio"].as_f64()?;
    let down = node["direction"] == "down";
    let is_pane = |child: &Value| child["kind"] == "leaf" && child["pane"] == pane_id;
    // The neighbor is the leaf of the other side that touches the pane.
    let (neighbor, direction, share) = if is_pane(first) {
        (edge_leaf(second, true)?, if down { "up" } else { "left" }, ratio)
    } else if is_pane(second) {
        (edge_leaf(first, false)?, if down { "down" } else { "right" }, 1.0 - ratio)
    } else {
        return placement_in(first, pane_id).or_else(|| placement_in(second, pane_id));
    };
    Some(json!({"neighbor": neighbor, "direction": direction, "ratio": share}))
}

/// The first (or last) leaf of `node`; a stack's shown pane.
fn edge_leaf(node: &Value, first: bool) -> Option<String> {
    match node["kind"].as_str()? {
        "leaf" => node["pane"].as_str().map(str::to_string),
        "stack" => node["expanded"].as_str().map(str::to_string),
        _ => edge_leaf(&node[if first { "first" } else { "second" }], first),
    }
}

/// The live neighbor closed tab member `record` was split off, while it
/// is still on the member's screen in the member's workspace: a neighbor
/// that moved elsewhere (another workspace, maybe an incognito one) never
/// takes the tab.
pub(super) fn split_neighbor(state: &State, record: &Value) -> Option<PaneId> {
    let split = &record["split"];
    let neighbor = pane_by_public_id(state, split["neighbor"].as_str()?)?;
    let (workspace, screen) = state.screen_of(neighbor)?;
    let workspace = &state.workspaces[workspace];
    let home = record["workspace_id"].as_str() == Some(workspace.public_id.as_str())
        && split["screen"]
            .as_str()
            .is_none_or(|id| id == workspace.screens[screen].public_id.as_str());
    home.then_some(neighbor)
}

/// Point the kept tab members of a closed pane that a partial reopen split
/// again (`panes`: closed pane id to new pane id) at that new pane, so a
/// later reopen puts them there instead of splitting once more.
pub(super) fn follow_split_panes(members: &mut [Value], panes: &HashMap<String, String>) {
    for member in members {
        let Some(pane) = member["pane_id"].as_str().and_then(|pane| panes.get(pane)) else {
            continue;
        };
        member["pane_id"] = json!(pane);
        if let Some(fields) = member.as_object_mut() {
            fields.remove("split");
        }
    }
}

impl Mux {
    /// Move the reopened tab `surface` from `neighbor` into a new pane
    /// split off it as its closed pane was (`split`, from
    /// [`pane_placement`]). Returns the new pane; None when the split
    /// fails, and the tab stays in `neighbor`.
    pub(super) fn split_closed_pane_again(
        self: &Arc<Self>,
        actor: &Actor,
        surface: SurfaceId,
        neighbor: PaneId,
        split: &Value,
    ) -> Option<PaneId> {
        let edge = TabDropEdge::parse(split["direction"].as_str()?).ok()?;
        let ratio = split["ratio"].as_f64().map(|ratio| (ratio as f32).clamp(0.05, 0.95));
        match self.move_tab_to_split_as(actor, surface, neighbor, edge, ratio, false, None) {
            Ok(outcome) => Some(outcome.pane),
            Err(error) => {
                eprintln!("cmux-tui: a reopened pane could not split again: {error:#}");
                None
            }
        }
    }
}
