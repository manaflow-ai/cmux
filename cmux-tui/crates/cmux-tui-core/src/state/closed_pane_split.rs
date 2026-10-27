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
use crate::mux::tab_groups::{pane_by_public_id, pane_public_id};
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
    let (sibling, neighbor, direction, share) = if is_pane(first) {
        (second, edge_leaf(second, true)?, if down { "up" } else { "left" }, ratio)
    } else if is_pane(second) {
        (first, edge_leaf(first, false)?, if down { "down" } else { "right" }, 1.0 - ratio)
    } else {
        return placement_in(first, pane_id).or_else(|| placement_in(second, pane_id));
    };
    let mut placement = json!({"neighbor": neighbor, "direction": direction, "ratio": share});
    // A sibling that is itself a split: the reopened pane splits off all of
    // it again, so its share is of the whole parent, not of one leaf.
    if sibling["kind"] == "split"
        && let Some(around) = sibling["split"].as_str()
    {
        placement["around"] = json!(around);
    }
    Some(placement)
}

/// The first (or last) leaf of `node`; a stack's shown pane.
fn edge_leaf(node: &Value, first: bool) -> Option<String> {
    match node["kind"].as_str()? {
        "leaf" => node["pane"].as_str().map(str::to_string),
        "stack" => node["expanded"].as_str().map(str::to_string),
        _ => edge_leaf(&node[if first { "first" } else { "second" }], first),
    }
}

/// Live pane `pane` while it is in `record`'s workspace, and on `screen`
/// when one is named: a pane that moved elsewhere (another workspace,
/// maybe an incognito one) never takes a closed tab.
fn pane_in_place(
    state: &State,
    record: &Value,
    pane: &str,
    screen: Option<&str>,
) -> Option<PaneId> {
    let pane = pane_by_public_id(state, pane)?;
    let (workspace, index) = state.screen_of(pane)?;
    let workspace = &state.workspaces[workspace];
    let home = record["workspace_id"].as_str() == Some(workspace.public_id.as_str())
        && screen.is_none_or(|id| id == workspace.screens[index].public_id.as_str());
    home.then_some(pane)
}

/// The live pane closed tab member `record` left, or the pane a partial
/// reopen split again for it (`panes`), while it is where the member
/// names (its workspace; that pane's screen).
pub(super) fn home_pane(
    state: &State,
    record: &Value,
    panes: &HashMap<String, SplitPane>,
) -> Option<PaneId> {
    let closed = record["pane_id"].as_str()?;
    match panes.get(closed) {
        Some(split) => pane_in_place(state, record, &split.pane, Some(split.screen.as_str())),
        None => pane_in_place(state, record, closed, record["screen_id"].as_str()),
    }
}

/// The live neighbor closed tab member `record` was split off, while it
/// is still on the recorded screen in the member's workspace; or, when that
/// neighbor closed in the same gesture (Close Other Panes), the pane this
/// reopen split again for it (`panes`).
pub(super) fn split_neighbor(
    state: &State,
    record: &Value,
    panes: &HashMap<String, SplitPane>,
) -> Option<PaneId> {
    let split = &record["split"];
    let neighbor = split["neighbor"].as_str()?;
    match panes.get(neighbor) {
        Some(again) => pane_in_place(state, record, &again.pane, Some(again.screen.as_str())),
        None => pane_in_place(state, record, neighbor, split["screen"].as_str()),
    }
}

/// `members` in the order that reopens a closed pane's neighbor before the
/// pane split off it, when both closed in one gesture (Close Other Panes):
/// the pane then splits off its own neighbor again. Otherwise, and for two
/// sibling panes that are each other's neighbor, the recorded order; the
/// relative order of every pane's tabs stays as recorded.
pub(super) fn neighbors_first(members: Vec<Value>) -> Vec<Value> {
    let mut pending = members;
    let mut ordered = Vec::with_capacity(pending.len());
    while !pending.is_empty() {
        let ready = {
            let waiting = pending
                .iter()
                .filter_map(|member| member["pane_id"].as_str())
                .collect::<std::collections::HashSet<_>>();
            pending
                .iter()
                .position(|member| {
                    member["split"]["neighbor"].as_str().is_none_or(|neighbor| {
                        !waiting.contains(neighbor) || member["pane_id"].as_str() == Some(neighbor)
                    })
                })
                .unwrap_or(0)
        };
        ordered.push(pending.remove(ready));
    }
    ordered
}

/// The pane a reopen split off a closed pane's neighbor again, and its
/// screen (public ids).
pub(super) struct SplitPane {
    pub(super) pane: String,
    pub(super) screen: String,
}

impl SplitPane {
    pub(super) fn of(state: &State, pane: PaneId) -> Option<Self> {
        let (workspace, screen) = state.screen_of(pane)?;
        Some(Self {
            pane: pane_public_id(state, pane).ok()?,
            screen: state.workspaces[workspace].screens[screen].public_id.as_str().to_string(),
        })
    }
}

/// Point the kept tab members of a closed pane that a partial reopen split
/// again (`panes`, by closed pane id) at that new pane and its screen, so
/// a later reopen puts them there instead of splitting once more.
pub(super) fn follow_split_panes(members: &mut [Value], panes: &HashMap<String, SplitPane>) {
    for member in members {
        let Some(split) = member["pane_id"].as_str().and_then(|pane| panes.get(pane)) else {
            continue;
        };
        member["pane_id"] = json!(split.pane);
        member["screen_id"] = json!(split.screen);
        if let Some(fields) = member.as_object_mut() {
            fields.remove("split");
        }
    }
}

/// Point the members of every other closed group (all but `reopening`)
/// whose split neighbor is a closed pane that this reopen split again
/// (`panes`, by closed pane id) at that new pane and its screen: close A,
/// then its neighbor B, and two reopens put B back and then A beside it,
/// not into the focused pane. Only the groups whose record names such a
/// pane are read.
pub(super) fn retarget_split_neighbors(
    transaction: &rusqlite::Transaction<'_>,
    reopening: &str,
    panes: &HashMap<String, SplitPane>,
) -> anyhow::Result<()> {
    for closed in panes.keys() {
        let rows = {
            let mut statement = transaction.prepare(
                "SELECT closed_id, record_json FROM closed_groups
                 WHERE instr(record_json, ?1) > 0 AND closed_id != ?2",
            )?;
            statement
                .query_map(rusqlite::params![closed, reopening], |row| {
                    Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
                })?
                .collect::<Result<Vec<_>, _>>()?
        };
        for (closed_id, record) in rows {
            let mut record: Value = serde_json::from_str(&record)?;
            let changed = record
                .get_mut("members")
                .and_then(Value::as_array_mut)
                .is_some_and(|members| retarget_members(members, panes));
            if changed {
                transaction.execute(
                    "UPDATE closed_groups SET record_json = ?2 WHERE closed_id = ?1",
                    rusqlite::params![closed_id, serde_json::to_string(&record)?],
                )?;
            }
        }
    }
    Ok(())
}

/// Point each of `members` whose split neighbor is a closed pane in `panes`
/// at the pane it was split again as. Returns whether any changed.
pub(super) fn retarget_members(members: &mut [Value], panes: &HashMap<String, SplitPane>) -> bool {
    let mut changed = false;
    for member in members {
        let Some(placement) = member.get_mut("split") else { continue };
        let Some(split) = placement["neighbor"].as_str().and_then(|pane| panes.get(pane)) else {
            continue;
        };
        placement["neighbor"] = json!(split.pane);
        placement["screen"] = json!(split.screen);
        // The split it sat beside may be gone with that pane.
        if let Some(fields) = placement.as_object_mut() {
            fields.remove("around");
        }
        changed = true;
    }
    changed
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
        let around = split["around"].as_str().and_then(|around| {
            let around = crate::resource::SplitPublicId::parse(around.to_string()).ok()?;
            self.with_state(|state| state.resource_indexes.splits.get(&around).copied())
        });
        match self.move_tab_to_split_around_as(actor, surface, neighbor, edge, ratio, around) {
            Ok(outcome) => Some(outcome.pane),
            Err(error) => {
                eprintln!("cmux-tui: a reopened pane could not split again: {error:#}");
                None
            }
        }
    }
}
