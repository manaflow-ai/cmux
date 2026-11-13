//! Every new workspace goes to the top of the sidebar by default (Lawrence
//! 2026-11-12: "by default all new workspaces should go to the top"; a user
//! saw new workspaces "still spawn at bottom" after earlier fixes). With no
//! `workspaces.newPlacement` set, a `workspace.create` from any client (the
//! app's Cmd-N, the CLI, the socket, iOS) and an agent's or script's create
//! (`created_by`) get the first row below Home, never the end; `bottom` is
//! the only setting that puts one last. A reopened workspace keeps its place.

use serde_json::json;

use super::tests::{Session, empty_workspace, mutate, read, send};
use crate::mux::*;
use crate::state::prelude::*;
use crate::user_settings::NewWorkspacePlacement;

fn listed(mux: &Arc<Mux>, ids: &[&str]) -> Vec<String> {
    read(mux, "workspace.list", json!({"order": "personal"}))
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|workspace| workspace["id"].as_str())
        .filter(|id| ids.contains(id))
        .map(str::to_string)
        .collect()
}

fn home(mux: &Arc<Mux>) -> String {
    send(mux, "workspace.ensure_home", json!({}), Some("connect")).unwrap()["value"]["workspace_id"]
        .as_str()
        .unwrap()
        .to_string()
}

fn created(mux: &Arc<Mux>, name: &str, created_by: Value) -> String {
    mutate(
        mux,
        "workspace.create",
        json!({"name": name, "initial_content": "empty", "created_by": created_by}),
        &format!("create-{name}"),
    )["workspace_id"]
        .as_str()
        .unwrap()
        .to_string()
}

/// The default, with no settings file: what every install gets.
#[test]
fn the_default_placement_is_top() {
    assert_eq!(NewWorkspacePlacement::default(), NewWorkspacePlacement::Top);
    assert_eq!(NewWorkspacePlacement::current(), NewWorkspacePlacement::Top);
    assert_eq!(NewWorkspacePlacement::from_config_text("{}"), NewWorkspacePlacement::Top);
}

/// A plain `workspace.create` (Cmd-N's daemon create, `cmux workspace new`,
/// a socket client) with the selection on an older row: first below Home,
/// not below the selection and not last.
#[test]
fn a_plain_create_goes_first_below_home_by_default() {
    let session = Session::new("new-default-top");
    let mux = session.open();
    let home = home(&mux);
    let bottom = NewWorkspacePlacement::Bottom.set_for_test();
    let a = empty_workspace(&mux, "a");
    let b = empty_workspace(&mux, "b");
    drop(bottom);
    mutate(&mux, "workspace.focus", json!({"workspace": a}), "focus-a");
    let c = empty_workspace(&mux, "c");
    let d = mutate(
        &mux,
        "workspace.create",
        json!({"name": "d", "initial_content": "terminal"}),
        "create-d",
    )["workspace_id"]
        .as_str()
        .unwrap()
        .to_string();
    let ids = [&home, &a, &b, &c, &d].map(String::as_str);
    let [home, a, b, c, d] = ids;
    assert_eq!(listed(&mux, &ids), [home, d, c, a, b].map(str::to_string).to_vec());
    drop(mux);
    let mux = session.open();
    assert_eq!(
        listed(&mux, &ids),
        [home, d, c, a, b].map(str::to_string).to_vec(),
        "a reopened workspace keeps its place"
    );
    mux.shutdown();
}

/// An agent's or a script's create (a Chief subagent, `cmux workspace new`
/// from an agent's terminal) follows the same default: first, not below its
/// creator and not last, with or without a live creator.
#[test]
fn an_agent_or_script_create_goes_first_by_default() {
    let session = Session::new("new-default-top-agent");
    let mux = session.open();
    let home = home(&mux);
    let bottom = NewWorkspacePlacement::Bottom.set_for_test();
    let a = empty_workspace(&mux, "a");
    let b = empty_workspace(&mux, "b");
    drop(bottom);
    mutate(&mux, "workspace.focus", json!({"workspace": b}), "focus-b");
    let x = created(&mux, "x", json!({"kind": "agent", "workspace": a, "session": "s-1"}));
    let y = created(&mux, "y", json!({"kind": "agent", "session": "s-2"}));
    let z = created(&mux, "z", json!({"kind": "script", "workspace": "no-such-workspace"}));
    let ids = [&home, &a, &b, &x, &y, &z].map(String::as_str);
    let [home, a, b, x, y, z] = ids;
    assert_eq!(listed(&mux, &ids), [home, z, y, x, a, b].map(str::to_string).to_vec());
    mux.shutdown();
}

/// Under `afterCurrent` an agent's create with no live creator has no row to
/// follow: it goes first, never the sidebar's end.
#[test]
fn an_agent_create_with_no_creator_never_goes_last() {
    let _after = NewWorkspacePlacement::AfterCurrent.set_for_test();
    let session = Session::new("new-agent-no-creator");
    let mux = session.open();
    let a = empty_workspace(&mux, "a");
    let b = empty_workspace(&mux, "b");
    mutate(&mux, "workspace.focus", json!({"workspace": a}), "focus-a");
    let x = created(&mux, "x", json!({"kind": "agent", "session": "s-2"}));
    let ids = [&a, &b, &x].map(String::as_str);
    let listed = listed(&mux, &ids);
    assert_ne!(listed.last().map(String::as_str), Some(ids[2]), "an agent's workspace went last");
    mux.shutdown();
}
