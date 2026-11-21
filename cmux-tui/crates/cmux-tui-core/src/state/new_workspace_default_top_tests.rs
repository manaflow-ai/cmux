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

fn group_of(mux: &Arc<Mux>, id: &str) -> Value {
    read(mux, "workspace.placement.list", json!({}))
        .as_array()
        .unwrap()
        .iter()
        .find(|row| row["workspace"]["workspace_id"] == id)
        .map(|row| row["group_id"].clone())
        .unwrap_or(Value::Null)
}

/// A new workspace made while the person is in a group stays in that group,
/// first in it, under the default (Leo 2026-11-16, workspace-420 in "Leads":
/// "I make a new space. Getting sent out of the group that I'm"). Each next
/// one, made from the new one, stays in the group too. An agent's create
/// from there still goes first in the section, outside the group.
#[test]
fn a_new_workspace_made_in_a_group_stays_in_that_group() {
    let session = Session::new("new-default-top-in-group");
    let mux = session.open();
    let home = home(&mux);
    let bottom = NewWorkspacePlacement::Bottom.set_for_test();
    let loose = empty_workspace(&mux, "loose");
    let a = empty_workspace(&mux, "a");
    let b = empty_workspace(&mux, "b");
    drop(bottom);
    let leads =
        mutate(&mux, "workspace_group.create", json!({"name": "Leads"}), "group-leads")["id"]
            .as_str()
            .unwrap()
            .to_string();
    mutate(&mux, "workspace.place", json!({"workspace": a, "group": leads}), "a-in-leads");
    mutate(&mux, "workspace.place", json!({"workspace": b, "group": leads}), "b-in-leads");
    mutate(&mux, "workspace.focus", json!({"workspace": b}), "focus-b");
    let c = empty_workspace(&mux, "c");
    assert_eq!(group_of(&mux, &c), json!(leads), "the new workspace left the group");
    mutate(&mux, "workspace.focus", json!({"workspace": c}), "focus-c");
    let d = empty_workspace(&mux, "d");
    assert_eq!(group_of(&mux, &d), json!(leads), "the next new workspace left the group");
    let x = created(&mux, "x", json!({"kind": "agent", "session": "s-1"}));
    assert_eq!(group_of(&mux, &x), Value::Null, "an agent's workspace went into the group");
    let ids = [&home, &loose, &a, &b, &c, &d, &x].map(String::as_str);
    let [home, loose, a, b, c, d, x] = ids;
    let order = listed(&mux, &ids);
    let at = |id: &str| order.iter().position(|listed| listed == id).unwrap();
    assert_eq!(at(home), 0, "Home stays first: {order:?}");
    assert!(at(x) < at(d), "the agent's workspace goes first in the section: {order:?}");
    // Each new one goes first in the group: d, c, then the group's older rows.
    assert_eq!(at(c), at(d) + 1, "{order:?}");
    assert!(at(c) < at(a) && at(c) < at(b), "{order:?}");
    assert!(
        at(loose) < at(d) || at(loose) > at(a).max(at(b)),
        "a loose row inside the group: {order:?}"
    );
    drop(mux);
    let mux = session.open();
    assert_eq!(group_of(&mux, c), json!(leads), "a reopened workspace keeps its group");
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
