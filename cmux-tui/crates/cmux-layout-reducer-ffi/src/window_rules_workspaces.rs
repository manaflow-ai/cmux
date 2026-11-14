//! `window_target_*`, `window_workspace_*` and the closed history and undo
//! toast ops of `window_close_*`: target resolution, the workspace, screen,
//! space and group verbs, and the daemon's closed history as the app reads it.

use std::collections::BTreeMap;

use cmux_window_rules::closed::{
    self, ClosedItem, ExpectedTab, OwnerFacts, RecordedItem, UndoState,
};
use cmux_window_rules::targets::{self, Failure, Named, PastEnd, TargetRef};
use cmux_window_rules::workspaces::{
    self, ClearDefaultsFacts, CloseFacts, DefaultsArgument, DirectoryTab, FocusGroup,
    GroupedScreen, NotesVerb, ScreenClose, SpaceDeleteFacts,
};
use serde::Deserialize;
use serde_json::{Value, json};

use super::read;
use crate::ERR_INVALID;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Ordinal {
    number: i64,
    count: usize,
    #[serde(default)]
    past_end: PastEnd,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Step {
    index: usize,
    offset: i64,
    count: usize,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct NamedLookup {
    text: String,
    folded: String,
    #[serde(default)]
    candidates: Vec<Named>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Explicit {
    #[serde(default)]
    candidates: Vec<Option<TargetRef>>,
    #[serde(default)]
    kinds: Vec<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Survivor {
    active: Option<usize>,
    #[serde(default)]
    windows: Vec<Vec<String>>,
    #[serde(default)]
    closing: Vec<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SpaceDefaults {
    cwd: Option<DefaultsArgument>,
    env: Option<DefaultsArgument>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Directory {
    #[serde(default)]
    tabs: Vec<DirectoryTab>,
    selected: Option<String>,
    terminals_only: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct GroupChain {
    start: Option<String>,
    #[serde(default)]
    parents: BTreeMap<String, Option<String>>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ScreenCloseRequest {
    verb: ScreenClose,
    index: usize,
    #[serde(default)]
    pinned: Vec<bool>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ScreenGroupMove {
    group: String,
    forward: bool,
    #[serde(default)]
    screens: Vec<GroupedScreen>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct History {
    #[serde(default)]
    items: Vec<ClosedItem>,
    #[serde(default)]
    target: usize,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Newest {
    #[serde(default)]
    entries: Vec<OwnerFacts>,
    window: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Expect {
    #[serde(default)]
    state: UndoState,
    token: u64,
    #[serde(default)]
    tabs: Vec<ExpectedTab>,
    #[serde(default)]
    panes: Vec<String>,
    costly: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Record {
    #[serde(default)]
    state: UndoState,
    #[serde(default)]
    items: Vec<RecordedItem>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct UndoToast {
    tabs: usize,
    shown: Option<usize>,
    allowed: bool,
}

fn value<T: serde::Serialize>(answer: T) -> Result<Value, i32> {
    serde_json::to_value(answer).map_err(|_| ERR_INVALID)
}

pub(super) fn respond(operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    let answer = match operation {
        // The index Cmd-1..9 picks (9: the last); `index` null picks nothing.
        b"window_target_ordinal" => {
            let r: Ordinal = read(request)?;
            json!({ "index": targets::ordinal(r.number, r.count, r.past_end) })
        }
        // Next or previous, wrapping around.
        b"window_target_step" => {
            let r: Step = read(request)?;
            json!({ "index": targets::step(r.index, r.offset, r.count) })
        }
        // An id, then a folded name.
        b"window_target_named" => {
            let r: NamedLookup = read(request)?;
            json!({ "index": targets::named(&r.text, &r.folded, &r.candidates) })
        }
        b"window_target_explicit" => {
            let r: Explicit = read(request)?;
            json!({ "index": targets::explicit(&r.candidates, &r.kinds) })
        }
        b"window_target_tab_ids" => {
            let r: Value = read(request)?;
            json!({ "ids": targets::tab_ids(r["list"].as_str().unwrap_or("")) })
        }
        b"window_target_one_pane" => {
            let r: Value = read(request)?;
            let panes: Vec<String> =
                serde_json::from_value(r["panes"].clone()).map_err(|_| ERR_INVALID)?;
            json!({ "refusal": targets::one_pane(&panes).err() })
        }
        b"window_target_refusal" => {
            let r: Failure = read(request)?;
            json!({ "refusal": targets::refusal(r) })
        }
        b"window_workspace_bulk_close" => {
            let r: Value = read(request)?;
            json!({ "close": workspaces::bulk_close(r["id"].as_str().unwrap_or("")) })
        }
        b"window_workspace_bulk_close_ids" => {
            json!({ "ids": workspaces::BULK_CLOSES.iter().map(|close| close.id).collect::<Vec<_>>() })
        }
        // The window that keeps the undo toast; `window` null: every window closes.
        b"window_workspace_survivor" => {
            let r: Survivor = read(request)?;
            json!({ "window": workspaces::survivor(r.active, &r.windows, &r.closing) })
        }
        b"window_workspace_rows_window" => {
            let r: Value = read(request)?;
            let owners: Vec<Option<String>> =
                serde_json::from_value(r["owners"].clone()).map_err(|_| ERR_INVALID)?;
            match workspaces::rows_window(&owners) {
                Some(window) => json!({ "spans": false, "window": window }),
                None => json!({ "spans": true, "window": null }),
            }
        }
        b"window_workspace_close_prompt" => {
            let r: CloseFacts = read(request)?;
            json!({ "prompt": workspaces::close_prompt(&r) })
        }
        b"window_workspace_confirmation" => {
            let r: Value = read(request)?;
            let id = r["id"].as_str().ok_or(ERR_INVALID)?;
            json!({ "confirmation": workspaces::confirmation(id, r["stash"].as_bool().unwrap_or(false)) })
        }
        b"window_workspace_space_delete" => {
            value(workspaces::space_delete(&read::<SpaceDeleteFacts>(request)?))?
        }
        b"window_workspace_space_clear_defaults" => {
            let r: ClearDefaultsFacts = read(request)?;
            json!({ "clear": workspaces::space_clear_defaults(r) })
        }
        b"window_workspace_space_defaults" => {
            let r: SpaceDefaults = read(request)?;
            match workspaces::defaults_patch(r.cwd.as_ref(), r.env.as_ref()) {
                Ok(patch) => json!({ "patch": patch }),
                Err(refusal) => json!({ "refusal": refusal }),
            }
        }
        b"window_workspace_notes" => match workspaces::notes(&read::<NotesVerb>(request)?) {
            Ok(update) => json!({ "update": update }),
            Err(choices) => json!({ "choices": choices }),
        },
        b"window_workspace_directory" => {
            let r: Directory = read(request)?;
            json!({ "cwd": workspaces::directory(&r.tabs, r.selected.as_deref(), r.terminals_only) })
        }
        b"window_workspace_group_focus" => {
            value(workspaces::group_focus(&read::<FocusGroup>(request)?))?
        }
        b"window_workspace_group_chain" => {
            let r: GroupChain = read(request)?;
            json!({ "chain": workspaces::group_chain(r.start.as_deref(), &r.parents) })
        }
        b"window_workspace_screen_close" => {
            let r: ScreenCloseRequest = read(request)?;
            json!({ "close": workspaces::screen_close(r.verb, r.index, &r.pinned) })
        }
        b"window_workspace_screen_move" => {
            let r: Step = read(request)?;
            json!({ "index": workspaces::screen_move(r.index, r.offset, r.count) })
        }
        b"window_workspace_screen_group_move" => {
            let r: ScreenGroupMove = read(request)?;
            json!({ "index": workspaces::screen_group_move(&r.group, r.forward, &r.screens) })
        }
        // The rows a closed history list keeps (a page once, at its newest close).
        b"window_close_history_once" => {
            let r: History = read(request)?;
            json!({ "keep": closed::newest_once(&r.items) })
        }
        b"window_close_history_closes" => {
            let r: History = read(request)?;
            json!({ "closes": closed::closes(r.target, &r.items) })
        }
        b"window_close_history_newest" => {
            let r: Newest = read(request)?;
            json!({ "index": closed::newest(&r.entries, r.window.as_deref()) })
        }
        // The undo toast's reducer: the app sends its state and keeps the answer's.
        b"window_close_undo_expect" => {
            let mut r: Expect = read(request)?;
            let announced = closed::expect(&mut r.state, r.token, r.tabs, r.panes, r.costly);
            json!({ "state": r.state, "announced": announced })
        }
        b"window_close_undo_record" => {
            let mut r: Record = read(request)?;
            let recorded = closed::record(&mut r.state, &r.items);
            json!({ "state": r.state, "recorded": recorded })
        }
        b"window_close_undo_toast" => {
            let r: UndoToast = read(request)?;
            value(closed::toast_show(r.tabs, r.shown, r.allowed))?
        }
        _ => return Err(ERR_INVALID),
    };
    serde_json::to_vec(&answer).map_err(|_| ERR_INVALID)
}
