//! The values that a workspace close states are the values that the rows give.
//!
//! A close with `end_terminals` states each workspace after the closed one again (its index
//! changed): in its journal record and in the public fold (`workspace_registry/public_fold.rs`),
//! which later commits compare their values with. For each such workspace both must hold the
//! value that `state::values::workspace_value` reads from the rows after the close, with the
//! state fields (`extra`) as they are THEN, not as they were when the workspace was made.
//!
//! NOT COVERED HERE, on purpose: a child workspace that sits BEFORE its creator. In this session
//! the creator is before its child, so the close of the creator states the child again. A close
//! does not state a workspace before the closed one, so such a child keeps
//! `created_by.workspace` = the closed id in the journal and in the fold until something states
//! it again. That is an older defect (since #37515) that gets its own red test and its own fix;
//! for that child the sentence above is false today.
//!
//! The session is made with the operations that a client sends:
//! - `workspace.create`, five times; one create has `created_by` (an agent in the workspace
//!   "creator"), so that workspace names its creator while the creator lives;
//! - after the creates, and after the fold is seeded: `workspace.rename` and `workspace.update`
//!   (a title and a color) on the workspace "changed", which is after the workspaces that close.
//!
//! The closes are `Mux::close_workspace_ending_terminals`: what the `close-workspace` command with
//! `end_terminals` runs (`server/cmd_workspaces.rs`). The fold is seeded with a full projection,
//! as the first terminal create of a live session seeds it.

use std::collections::BTreeMap;

use serde_json::json;

use super::tests::{empty_workspace, mutate, revision};
use crate::mux::*;
use crate::state::prelude::*;
use crate::surface::SurfaceOptions;

/// The public id and the key of each live workspace, in the session's order.
fn live(mux: &Mux) -> Vec<(String, String)> {
    mux.with_state(|state| {
        state
            .workspaces
            .iter()
            .map(|workspace| (workspace.public_id.to_string(), workspace.key.clone()))
            .collect()
    })
}

/// The value that the rows give a live workspace now.
fn rows_value(mux: &Mux, id: &str) -> Value {
    mux.read_registry_state(|connection| super::values::workspace_value(connection, id))
        .unwrap()
        .expect("a live workspace has a value")
}

/// One full projection: it states each resource and seeds the journal's public fold.
fn seed_the_fold(mux: &Arc<Mux>) {
    let (key, operation) = ("seed-public-fold", "test.seed_public_fold");
    let fingerprint = json!({"operation": operation, "fixture": key});
    mux.prepare_resource_effect(
        &WorkspaceMutation::daemon(key, "test").unwrap(),
        operation,
        &fingerprint,
        &json!({}),
        None,
        Some(revision(mux)),
    )
    .unwrap();
    mux.mark_resource_effect_executing(key, operation, &fingerprint).unwrap();
    mux.commit_full_resource_effect_projection(key, operation, &fingerprint, json!({})).unwrap();
    assert!(
        mux.workspace_registry.lock().unwrap().public_fold_seeded(),
        "the full projection did not seed the fold"
    );
}

/// Close the workspace `id` and compare what the close states with the rows after it:
/// - the journal records of the close delete only `id` and state each workspace after it again;
/// - each workspace value in those records is the value that the rows give;
/// - the fold holds each live workspace, and no other, with the value that the rows give.
///
/// Gives the workspace values of the close's journal records, by public id.
fn close_and_compare(mux: &Arc<Mux>, id: &str, what: &str) -> BTreeMap<String, Value> {
    let before = live(mux);
    let position = before.iter().position(|(public_id, _)| public_id == id).unwrap();
    let key = before[position].1.clone();
    let at = revision(mux);
    let mutation = WorkspaceMutation::daemon(format!("close-{key}"), "close-values-test").unwrap();
    mux.close_workspace_ending_terminals(None, Some(&key), None, None, &mutation).unwrap();

    let mut stated = BTreeMap::new();
    let mut deleted = Vec::new();
    for batch in mux.resource_events_after(at).unwrap().batches {
        for change in batch.changes.as_array().cloned().unwrap_or_default() {
            if change["resource"] != "workspace" {
                continue;
            }
            let changed = change["id"].as_str().unwrap().to_string();
            if change["kind"] == "upsert" {
                stated.insert(changed, change["value"].clone());
            } else if change["kind"] == "delete" {
                deleted.push(changed);
            }
        }
    }
    assert_eq!(deleted, [id.to_string()], "{what}: the workspaces that the journal deletes");
    for (later, _) in &before[position + 1..] {
        assert!(
            stated.contains_key(later),
            "{what}: the journal does not state the later workspace {later} again"
        );
    }

    let after = live(mux);
    for changed in stated.keys() {
        assert!(
            after.iter().any(|(public_id, _)| public_id == changed),
            "{what}: the journal states {changed}, which does not live"
        );
    }
    let mut registry = mux.workspace_registry.lock().unwrap();
    let (_, fold) = registry.stated_workspaces().expect("the fold is seeded and at the head");
    let connection = registry.connection.get();
    assert_eq!(fold.len(), after.len(), "{what}: the workspaces that the fold holds");
    for (public_id, _) in &after {
        let rows = super::values::workspace_value(&connection, public_id)
            .unwrap()
            .expect("a live workspace has a value");
        if let Some(journal) = stated.get(public_id) {
            assert_eq!(
                journal, &rows,
                "{what}: the journal's value of {public_id}, then the rows'"
            );
        }
        assert_eq!(
            fold.get(public_id),
            Some(&rows),
            "{what}: the fold's value of {public_id}, then the rows'"
        );
    }
    stated
}

/// What must be in a value of the workspace "changed" after its rename and its `workspace.update`.
fn assert_renamed_and_colored(value: &Value, what: &str) {
    assert_eq!(value["name"], "renamed", "{what}: the name");
    assert_eq!(value["extra"]["title"], "API server", "{what}: the title");
    assert_eq!(value["extra"]["color"], "#336699", "{what}: the color");
}

#[test]
fn a_close_states_each_later_workspace_as_its_rows_give_it_now() {
    let mux = Mux::new_for_test("close-values", SurfaceOptions::default());
    let first = empty_workspace(&mux, "first");
    let creator = empty_workspace(&mux, "creator");
    let by_the_creator = json!({"kind": "agent", "workspace": creator, "session": "s-1"});
    let child = mutate(
        &mux,
        "workspace.create",
        json!({"name": "child", "initial_content": "empty", "created_by": by_the_creator}),
        "create-child",
    )["workspace_id"]
        .as_str()
        .unwrap()
        .to_string();
    let changed = empty_workspace(&mux, "changed");
    let last = empty_workspace(&mux, "last");
    seed_the_fold(&mux);

    // After its create and after the seed: a new name, a title and a color.
    mutate(&mux, "workspace.rename", json!({"workspace": changed, "name": "renamed"}), "rename");
    let shown = json!({"workspace": changed, "title": "API server", "color": "#336699"});
    mutate(&mux, "workspace.update", shown, "show");

    let order = live(&mux).into_iter().map(|(public_id, _)| public_id).collect::<Vec<_>>();
    let place = |id: &String| order.iter().position(|item| item == id).unwrap();
    assert!(place(&first) < place(&creator), "the fixture: the first one is before the creator");
    assert!(place(&creator) < place(&child), "the fixture: the creator is before its child");
    assert!(
        place(&creator) < place(&changed),
        "the fixture: the creator is before the changed one"
    );
    assert!(place(&changed) < place(&last), "the fixture: the changed one is before the last one");
    assert_eq!(place(&last), order.len() - 1, "the fixture: the last one");
    assert_eq!(
        rows_value(&mux, &child)["extra"]["created_by"],
        json!({"kind": "agent", "workspace": creator, "session": "s-1"}),
        "the fixture: the child names its creator while that lives"
    );
    assert_renamed_and_colored(&rows_value(&mux, &changed), "the fixture");

    // The creator closes before its child and before the changed workspace.
    let stated = close_and_compare(&mux, &creator, "the creator");
    assert_eq!(
        stated[&child]["extra"]["created_by"],
        json!({"kind": "agent", "session": "s-1"}),
        "after the creator's close the child names no creator"
    );
    assert_renamed_and_colored(&stated[&changed], "after the creator's close");

    // The first of the five: the child, the changed one and the last one are after it.
    let stated = close_and_compare(&mux, &first, "the first workspace");
    assert_eq!(
        stated[&child]["extra"]["created_by"],
        json!({"kind": "agent", "session": "s-1"}),
        "after the first one's close the child names no creator"
    );
    assert_renamed_and_colored(&stated[&changed], "after the first one's close");

    // The last workspace: no workspace is after it.
    close_and_compare(&mux, &last, "the last workspace");
    assert_eq!(live(&mux).len(), order.len() - 3, "three workspaces closed");
}
