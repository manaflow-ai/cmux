//! `workspace.create {created_by}` (ask-48544d7525): a workspace an agent or
//! a script makes goes next to the workspace that made it, below it and its
//! earlier children, in its group; with no creator, at the end. Never next to
//! the person's selection, and the selection stays. The creator is stored,
//! shown as `extra.created_by`, and kept across a restart.

use serde_json::json;

use super::tests::{Session, empty_workspace, mutate, read};
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

fn workspace(mux: &Arc<Mux>, id: &str) -> Value {
    read(mux, "workspace.list", json!({}))
        .as_array()
        .unwrap()
        .iter()
        .find(|workspace| workspace["id"] == id)
        .cloned()
        .unwrap()
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

fn focus(mux: &Arc<Mux>, id: &str) {
    mutate(mux, "workspace.focus", json!({"workspace": id}), &format!("focus-{id}"));
}

/// Leo has c selected while an agent in a makes workspaces: they go below a
/// (each after the earlier ones, a grandchild right below its own creator),
/// not below c, and c stays selected. A creator named by its key (what a
/// terminal's `CMUX_WORKSPACE_ID` holds) works the same.
#[test]
fn an_agent_workspace_goes_below_its_creator_not_the_selection() {
    let session = Session::new("created-by-beside");
    let mux = session.open();
    // a, b, c in that order whatever a create does to the selection.
    let bottom = NewWorkspacePlacement::Bottom.set_for_test();
    let a = empty_workspace(&mux, "a");
    let b = empty_workspace(&mux, "b");
    let c = empty_workspace(&mux, "c");
    drop(bottom);
    let _after = NewWorkspacePlacement::AfterCurrent.set_for_test();
    focus(&mux, &c);
    let x = created(&mux, "x", json!({"kind": "agent", "workspace": a, "session": "s-1"}));
    let y = created(&mux, "y", json!({"kind": "agent", "workspace": a}));
    let x_key = workspace(&mux, &x)["extra"]["key"].as_str().unwrap().to_string();
    // As a terminal's `CMUX_WORKSPACE_ID` may hold it: undashed, uppercase.
    let env_form = x_key.replace('-', "").to_uppercase();
    let z = created(&mux, "z", json!({"kind": "script", "workspace": env_form}));
    let ids = [&a, &b, &c, &x, &y, &z].map(String::as_str);
    let [a, b, c, x, y, z] = ids;
    assert_eq!(listed(&mux, &ids), [a, x, z, y, b, c].map(str::to_string).to_vec());
    assert_eq!(workspace(&mux, c)["focused"], true, "an agent create moved the selection");
    assert_eq!(
        workspace(&mux, x)["extra"]["created_by"],
        json!({"kind": "agent", "workspace": a, "session": "s-1"})
    );
    assert_eq!(
        workspace(&mux, z)["extra"]["created_by"],
        json!({"kind": "script", "workspace": x})
    );
    assert!(workspace(&mux, b)["extra"].get("created_by").is_none());
    // A person's create keeps the setting's place: below the selection.
    let p = created(&mux, "p", json!({"kind": "person"}));
    assert_eq!(listed(&mux, &[c, &p]), [c.to_string(), p.clone()]);
    drop(mux);
    let mux = session.open();
    assert_eq!(listed(&mux, &ids), [a, x, z, y, b, c].map(str::to_string).to_vec());
    assert_eq!(
        workspace(&mux, x)["extra"]["created_by"]["workspace"],
        a,
        "not kept across restart"
    );
    mux.shutdown();
}

/// A creator in a group: its children join the group, right below it.
#[test]
fn an_agent_workspace_joins_its_creators_group() {
    let _after = NewWorkspacePlacement::AfterCurrent.set_for_test();
    let session = Session::new("created-by-group");
    let mux = session.open();
    let a = empty_workspace(&mux, "a");
    let b = empty_workspace(&mux, "b");
    let loose = empty_workspace(&mux, "loose");
    let work = mutate(&mux, "workspace_group.create", json!({"name": "Work"}), "group-Work")["id"]
        .as_str()
        .unwrap()
        .to_string();
    mutate(&mux, "workspace.place", json!({"workspace": a, "group": work}), "a-in-work");
    mutate(&mux, "workspace.place", json!({"workspace": b, "group": work}), "b-in-work");
    focus(&mux, &loose);
    let x = created(&mux, "x", json!({"kind": "agent", "workspace": a}));
    let ids = [&a, &b, &x].map(String::as_str);
    let [a, b, x] = ids;
    assert_eq!(listed(&mux, &ids), [a, x, b].map(str::to_string).to_vec());
    let placements = read(&mux, "workspace.placement.list", json!({}));
    let group_of = placements
        .as_array()
        .unwrap()
        .iter()
        .find(|row| row["workspace"]["workspace_id"] == x)
        .map(|row| row["group_id"].clone())
        .unwrap();
    assert_eq!(group_of, json!(work));
    assert_eq!(workspace(&mux, &loose)["focused"], true);
    mux.shutdown();
}

/// A workspace with a terminal (what a plain `cmux workspace create` makes)
/// commits through the effect journal, possibly on its writer thread: it
/// still goes below its creator and keeps `extra.created_by`.
#[test]
fn an_agent_terminal_workspace_goes_below_its_creator() {
    let session = Session::new("created-by-terminal");
    let mux = session.open();
    let bottom = NewWorkspacePlacement::Bottom.set_for_test();
    let a = empty_workspace(&mux, "a");
    let b = empty_workspace(&mux, "b");
    drop(bottom);
    let _after = NewWorkspacePlacement::AfterCurrent.set_for_test();
    focus(&mux, &b);
    let x = mutate(
        &mux,
        "workspace.create",
        json!({"name": "x", "initial_content": "terminal",
            "created_by": {"kind": "script", "workspace": a}}),
        "create-x",
    )["workspace_id"]
        .as_str()
        .unwrap()
        .to_string();
    let ids = [&a, &b, &x].map(String::as_str);
    let [a, b, x] = ids;
    assert_eq!(listed(&mux, &ids), [a, x, b].map(str::to_string).to_vec());
    assert_eq!(
        workspace(&mux, x)["extra"]["created_by"],
        json!({"kind": "script", "workspace": a})
    );
    mux.shutdown();
}

/// An agent or script create with no creator workspace (none named, or one
/// that is gone) goes at the end, never below the selection.
#[test]
fn an_agent_workspace_with_no_creator_goes_last() {
    let _after = NewWorkspacePlacement::AfterCurrent.set_for_test();
    let session = Session::new("created-by-none");
    let mux = session.open();
    let a = empty_workspace(&mux, "a");
    let b = empty_workspace(&mux, "b");
    focus(&mux, &a);
    let x = created(&mux, "x", json!({"kind": "agent", "session": "s-2"}));
    let y = created(&mux, "y", json!({"kind": "script", "workspace": "no-such-workspace"}));
    let ids = [&a, &b, &x, &y].map(String::as_str);
    let [a, b, x, y] = ids;
    assert_eq!(listed(&mux, &ids), [a, b, x, y].map(str::to_string).to_vec());
    assert_eq!(workspace(&mux, a)["focused"], true);
    assert_eq!(
        workspace(&mux, x)["extra"]["created_by"],
        json!({"kind": "agent", "session": "s-2"})
    );
    mux.shutdown();
}

/// An unknown kind is refused.
#[test]
fn created_by_needs_a_known_kind() {
    let session = Session::new("created-by-kind");
    let mux = session.open();
    let refused = super::tests::send(
        &mux,
        "workspace.create",
        json!({"initial_content": "empty", "created_by": {"kind": "robot"}}),
        Some("bad-kind"),
    );
    assert_eq!(super::tests::error_code(refused), "validation.invalid");
    mux.shutdown();
}

/// How the creator closes: `workspace.close` (a full projection), or the socket's
/// `close-workspace` with `end_terminals` (a scoped projection of the closed workspace and the
/// workspaces after it).
#[derive(Clone, Copy, Debug)]
enum Close {
    Operation,
    EndingTerminals,
}

/// A workspace keeps `extra.created_by.workspace` only while its creator lives
/// ([`super::created_by::snapshot`]). `workspace.list` reads the rows and drops it at once; the
/// session's events must say the same, or a client that builds its model from them keeps a
/// creator that is closed. `before` picks the child to check: x, which sits BEFORE its creator a
/// (the close changes none of its projected fields), or y, which sits after a (its index moves).
fn check_child_after_its_creator_closes(name: &'static str, close: Close, before: bool) {
    let session = Session::new(name);
    let mux = session.open();
    let start = super::tests::revision(&mux);
    let other = empty_workspace(&mux, "other");
    let a = empty_workspace(&mux, "a");
    let by_a = json!({"kind": "agent", "workspace": a, "session": "s-1"});
    let x = created(&mux, "x", by_a.clone());
    let y = created(&mux, "y", by_a.clone());
    mutate(&mux, "workspace.move", json!({"workspace": x, "index": 0}), "x-first");
    // The person's selection is none of the three: the close moves no focus onto a child.
    focus(&mux, &other);
    let ids = [&x, &a, &y].map(String::as_str);
    assert_eq!(listed(&mux, &ids), ids.map(str::to_string).to_vec(), "the scene: x, a, y");
    assert_eq!(workspace(&mux, &other)["focused"], true, "the scene: other is selected");
    seed_public_fold(&mux);
    let child = if before { &x } else { &y };
    assert_eq!(folded_created_by(&mux, start, child), by_a, "the scene: the events name a");
    let a_key = workspace(&mux, &a)["extra"]["key"].as_str().unwrap().to_string();

    match close {
        Close::Operation => {
            mutate(&mux, "workspace.close", json!({"workspace": a}), "close-a");
        }
        Close::EndingTerminals => {
            let mutation = WorkspaceMutation::daemon("close-a", "created-by-test").unwrap();
            mux.close_workspace_ending_terminals(None, Some(a_key.as_str()), None, None, &mutation)
                .unwrap();
        }
    }

    let wanted = json!({"kind": "agent", "session": "s-1"});
    let mut problems = Vec::new();
    let from_rows = workspace(&mux, child)["extra"]["created_by"].clone();
    if from_rows != wanted {
        problems.push(format!("workspace.list gives {from_rows}"));
    }
    let folded = folded_created_by(&mux, start, child);
    if folded != wanted {
        problems.push(format!("the session's events state {folded}"));
    }
    let stated = stated_created_by(&mux, child);
    if stated != wanted {
        problems.push(format!("the public fold states {stated}"));
    }
    assert!(
        problems.is_empty(),
        "{close:?}: after its creator {a} closed, the child's created_by must be {wanted}:\n{}",
        problems.join("\n")
    );
    mux.shutdown();
}

/// One full resource effect projection, as a session's first terminal create runs: it states
/// every workspace and seeds the journal's public fold, so the next commits state only what
/// they change (the state of a live session).
fn seed_public_fold(mux: &Arc<Mux>) {
    let (key, operation) = ("seed-public-fold", "test.seed_public_fold");
    let fingerprint = json!({"operation": operation, "fixture": key});
    let expected_revision = super::tests::revision(mux);
    mux.prepare_resource_effect(
        &WorkspaceMutation::daemon(key, "test").unwrap(),
        operation,
        &fingerprint,
        &json!({}),
        None,
        Some(expected_revision),
    )
    .unwrap();
    mux.mark_resource_effect_executing(key, operation, &fingerprint).unwrap();
    mux.commit_full_resource_effect_projection(key, operation, &fingerprint, json!({})).unwrap();
    assert!(
        mux.workspace_registry.lock().unwrap().public_fold_seeded(),
        "the full projection did not seed the fold"
    );
}

/// `extra.created_by` of the workspace `id` as a client holds it that folds the session's
/// events from `start`: the one of its last upsert.
fn folded_created_by(mux: &Arc<Mux>, start: u64, id: &str) -> Value {
    super::tests::changes_after(mux, start)
        .iter()
        .rev()
        .find(|change| {
            change["kind"] == "upsert" && change["resource"] == "workspace" && change["id"] == id
        })
        .map_or(Value::Null, |change| change["value"]["extra"]["created_by"].clone())
}

/// `extra.created_by` of the workspace `id` in the registry's public fold (what the journal
/// states, and what the next commits prune their upserts against).
fn stated_created_by(mux: &Arc<Mux>, id: &str) -> Value {
    let mut registry = mux.workspace_registry.lock().unwrap();
    registry
        .stated_topology_value_for_test("workspace", id)
        .flatten()
        .map_or(Value::Null, |value| value["extra"]["created_by"].clone())
}

#[test]
fn a_child_before_its_closed_creator_drops_the_creator_in_the_events() {
    check_child_after_its_creator_closes("created-by-close-before", Close::Operation, true);
}

#[test]
fn a_child_before_its_creator_closed_with_its_terminals_drops_the_creator_in_the_events() {
    check_child_after_its_creator_closes("created-by-end-before", Close::EndingTerminals, true);
}

/// The control: a child AFTER its creator moves one index down, so the close states it again
/// with the rows as they are after the close.
#[test]
fn a_child_after_its_closed_creator_drops_the_creator_in_the_events() {
    check_child_after_its_creator_closes("created-by-close-after", Close::Operation, false);
    check_child_after_its_creator_closes("created-by-end-after", Close::EndingTerminals, false);
}
