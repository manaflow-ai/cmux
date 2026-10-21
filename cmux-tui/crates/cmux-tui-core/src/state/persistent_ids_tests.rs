//! Persistent ids (plans/cmux-next/persistent-ids-DESIGN.md): every public
//! id a session shows (workspaces, screens, panes, tabs, terminals,
//! browsers, splits, tab, screen and workspace groups, spaces) is the same
//! after the daemon restarts, twice. The CI guard for "ids never change".

use std::collections::BTreeSet;
use std::sync::Arc;

use serde_json::{Value, json};

use super::tests::{Session, mutate, read};
use crate::mux::Mux;

/// The id prefixes this guard reads; each must show at least once.
const KINDS: &[&str] =
    &["ws_", "screen_", "pane_", "tab_", "term_", "grp_", "sgrp_", "tgrp_", "prof_"];

/// Every string in `value` that looks like a public id (`<kind>_<suffix>`
/// with a known prefix).
fn collect_ids(value: &Value, out: &mut BTreeSet<String>) {
    match value {
        Value::String(text)
            if KINDS.iter().chain(["browser_", "split_"].iter()).any(|kind| is_id(text, kind)) =>
        {
            out.insert(text.clone());
        }
        Value::Array(items) => items.iter().for_each(|item| collect_ids(item, out)),
        Value::Object(map) => map.values().for_each(|item| collect_ids(item, out)),
        _ => {}
    }
}

fn is_id(text: &str, kind: &str) -> bool {
    text.strip_prefix(kind)
        .is_some_and(|rest| !rest.is_empty() && rest.chars().all(|c| c.is_ascii_alphanumeric()))
}

/// Every public id the session shows: its snapshot and every group list.
fn public_ids(mux: &Arc<Mux>) -> BTreeSet<String> {
    let mut ids = BTreeSet::new();
    collect_ids(&crate::resource_api::public_session_snapshot(mux).unwrap(), &mut ids);
    for list in ["workspace_group.list", "tab_group.list", "screen_group.list", "room.list"] {
        collect_ids(&read(mux, list, json!({})), &mut ids);
    }
    ids
}

/// One of everything: a workspace of two screens (grouped), a pane of
/// three tabs (two grouped), a workspace group and a space.
fn seed(mux: &Arc<Mux>) {
    let first = mux.new_workspace(None, None).unwrap().id;
    let workspace = mux.with_state(|state| state.workspaces[state.active_workspace].id);
    mux.new_screen(Some(workspace), None).unwrap();
    let pane = mux.with_state(|state| state.pane_of(first)).unwrap();
    let mut surfaces = vec![first];
    for _ in 0..2 {
        surfaces.push(mux.new_tab(Some(pane), None, None).unwrap().id);
    }
    let tabs = mux.with_state(|state| {
        surfaces
            .iter()
            .map(|surface| state.resource_indexes.tab_ids[surface].to_string())
            .collect::<Vec<_>>()
    });
    mutate(mux, "tab_group.create", json!({"tabs": [tabs[1], tabs[2]]}), "ids-tab-group");
    let screens = mux.with_state(|state| {
        let index = state.workspace_index(workspace).unwrap();
        state.workspaces[index]
            .screens
            .iter()
            .map(|screen| screen.public_id.to_string())
            .collect::<Vec<_>>()
    });
    mutate(
        mux,
        "screen_group.create",
        json!({"screens": [screens[0], screens[1]], "name": "Agents"}),
        "ids-screen-group",
    );
    mutate(mux, "workspace_group.create", json!({"name": "Work"}), "ids-workspace-group");
    mutate(mux, "room.create", json!({"name": "Side"}), "ids-room");
}

#[test]
fn persistent_ids_every_public_id_is_the_same_after_two_restarts() {
    let session = Session::new("persistent-ids");
    let mux = session.open();
    seed(&mux);
    let before = public_ids(&mux);
    for kind in KINDS {
        assert!(
            before.iter().any(|id| id.starts_with(kind)),
            "the guard sees no {kind} id: {before:?}"
        );
    }
    mux.shutdown();
    drop(mux);

    for restart in 1..=2 {
        let mux = session.open();
        let after = public_ids(&mux);
        let lost: Vec<_> = before.difference(&after).collect();
        let minted: Vec<_> = after.difference(&before).collect();
        assert!(
            lost.is_empty() && minted.is_empty(),
            "restart {restart} changed ids: lost {lost:?}, minted {minted:?}"
        );
        mux.shutdown();
        drop(mux);
    }
}
