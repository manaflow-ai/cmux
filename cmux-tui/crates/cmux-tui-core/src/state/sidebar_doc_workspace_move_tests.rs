//! `workspace.move {index}` moves the workspace in the sidebar order the
//! person sees (the sidebar document, `workspace.list`), not only in the
//! session order (#29875): `cmux workspace <ws> move --index 0` from the
//! Chief or any CLI puts it first below Home. `workspace.create {placement}`
//! names a new workspace's place whatever `workspaces.newPlacement` says.

use serde_json::json;

use super::tests::{Session, empty_workspace, mutate, read, send};
use crate::mux::*;
use crate::state::prelude::*;

/// The workspace ids of `workspace.list` (the sidebar document order)
/// restricted to `ids`.
fn shown(mux: &Arc<Mux>, ids: &[&str]) -> Vec<String> {
    read(mux, "workspace.list", json!({}))
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

fn group_of(mux: &Arc<Mux>, id: &str) -> Value {
    read(mux, "workspace.placement.list", json!({}))
        .as_array()
        .unwrap()
        .iter()
        .find(|row| row["workspace"]["workspace_id"] == id)
        .map(|row| row["group_id"].clone())
        .unwrap()
}

#[test]
fn a_move_to_index_zero_shows_the_workspace_first_below_home() {
    let session = Session::new("move-doc-top");
    let mux = session.open();
    let _bottom = crate::user_settings::NewWorkspacePlacement::Bottom.set_for_test();
    let home = home(&mux);
    let a = empty_workspace(&mux, "a");
    let b = empty_workspace(&mux, "b");
    let c = empty_workspace(&mux, "c");
    let ids = [home.as_str(), a.as_str(), b.as_str(), c.as_str()];
    assert_eq!(shown(&mux, &ids), ids, "made in sidebar order");

    mutate(&mux, "workspace.move", json!({"workspace": c, "index": 0}), "c-top");
    assert_eq!(
        shown(&mux, &ids),
        [home.as_str(), c.as_str(), a.as_str(), b.as_str()],
        "move --index 0 did not put the workspace first below Home in the sidebar"
    );

    // Past the end: last.
    mutate(&mux, "workspace.move", json!({"workspace": a, "index": 99}), "a-last");
    assert_eq!(shown(&mux, &ids), [home.as_str(), c.as_str(), b.as_str(), a.as_str()]);

    // A retried request replays; a later move is not undone by it.
    let again =
        send(&mux, "workspace.move", json!({"workspace": c, "index": 0}), Some("c-top")).unwrap();
    assert_eq!(again["replayed"], true);
    assert_eq!(shown(&mux, &ids), [home.as_str(), c.as_str(), b.as_str(), a.as_str()]);

    // Home itself stays first.
    mutate(&mux, "workspace.move", json!({"workspace": home, "index": 2}), "home-moved");
    assert_eq!(shown(&mux, &ids)[0], home, "home left the first slot");
    mux.shutdown();
}

#[test]
fn a_move_keeps_a_grouped_workspace_in_its_group() {
    let session = Session::new("move-doc-group");
    let mux = session.open();
    let _bottom = crate::user_settings::NewWorkspacePlacement::Bottom.set_for_test();
    let a = empty_workspace(&mux, "a");
    let b = empty_workspace(&mux, "b");
    let c = empty_workspace(&mux, "c");
    let work = mutate(&mux, "workspace_group.create", json!({"name": "Work"}), "group-work")["id"]
        .as_str()
        .unwrap()
        .to_string();
    mutate(&mux, "workspace.place", json!({"workspace": b, "group": work}), "b-in-work");
    mutate(&mux, "workspace.place", json!({"workspace": c, "group": work}), "c-in-work");
    let ids = [a.as_str(), b.as_str(), c.as_str()];
    let before = shown(&mux, &ids);
    let at_b = before.iter().position(|id| *id == b).unwrap();
    assert_eq!(before[at_b + 1], c, "the group lists b, c");

    mutate(&mux, "workspace.move", json!({"workspace": c, "index": 0}), "c-top");
    let after = shown(&mux, &ids);
    let at_c = after.iter().position(|id| *id == c).unwrap();
    assert_eq!(after[at_c + 1], b, "c is not first in its group: {after:?}");
    assert_eq!(group_of(&mux, &c), json!(work), "the move took c out of its group");
    mux.shutdown();
}

/// A workspace's sidebar item: its id, section and parent group item.
fn item_of(mux: &Arc<Mux>, workspace: &str) -> (String, String, Option<String>) {
    mux.read_registry_state(|connection| {
        let local = crate::state::values::local_registry_id(connection)?;
        crate::state::sidebar_doc_store::with_doc(connection, |doc| {
            let item = doc
                .workspace_item(&cmux_layout_reducer::sidebar_doc::WorkspaceRef::new(
                    &local, workspace,
                ))
                .expect("the workspace has a sidebar item");
            Ok((item.id.clone(), item.section.clone(), item.parent.clone()))
        })
    })
    .unwrap()
}

/// A workspace in a group inside a group moves among that inner group's
/// members, and stays there.
#[test]
fn a_move_reorders_a_nested_group_member() {
    let session = Session::new("move-doc-nested");
    let mux = session.open();
    let _bottom = crate::user_settings::NewWorkspacePlacement::Bottom.set_for_test();
    let a = empty_workspace(&mux, "a");
    let b = empty_workspace(&mux, "b");
    let c = empty_workspace(&mux, "c");
    let work = mutate(&mux, "workspace_group.create", json!({"name": "Work"}), "group-work")["id"]
        .as_str()
        .unwrap()
        .to_string();
    for (workspace, key) in [(&b, "b-in-work"), (&c, "c-in-work")] {
        mutate(&mux, "workspace.place", json!({"workspace": workspace, "group": work}), key);
    }
    let (b_item, section, outer) = item_of(&mux, &b);
    let (c_item, _, _) = item_of(&mux, &c);
    let outer = outer.expect("b is in Work");
    // Inner holds c before b, the reverse of the session order, so only a
    // walk of the nested group lists them as the sidebar shows them.
    send(
        &mux,
        "sidebar.group.create",
        json!({"name": "Inner", "items": [c_item, b_item],
               "to": {"section": section, "parent": outer}}),
        Some("inner"),
    )
    .unwrap();
    let inner = item_of(&mux, &c).2.expect("c is in Inner");
    assert_ne!(inner, outer, "c is not in the nested group");
    let ids = [a.as_str(), b.as_str(), c.as_str()];
    assert_eq!(
        shown(&mux, &ids),
        [a.as_str(), c.as_str(), b.as_str()],
        "the nested members list in their group's order"
    );

    mutate(&mux, "workspace.move", json!({"workspace": b, "index": 0}), "b-top");
    assert_eq!(shown(&mux, &ids), ids, "b is not first in its nested group");
    assert_eq!(item_of(&mux, &b).2, Some(inner), "the move took b out of its nested group");
    mux.shutdown();
}

#[test]
fn a_create_with_placement_top_shows_first_under_a_bottom_setting() {
    let session = Session::new("create-placement-top");
    let mux = session.open();
    let _bottom = crate::user_settings::NewWorkspacePlacement::Bottom.set_for_test();
    let home = home(&mux);
    let a = empty_workspace(&mux, "a");
    let b = mutate(
        &mux,
        "workspace.create",
        json!({"name": "agent", "initial_content": "empty", "placement": "top"}),
        "create-agent",
    )["workspace_id"]
        .as_str()
        .unwrap()
        .to_string();
    let c = empty_workspace(&mux, "c");
    let ids = [home.as_str(), a.as_str(), b.as_str(), c.as_str()];
    assert_eq!(
        shown(&mux, &ids),
        [home.as_str(), b.as_str(), a.as_str(), c.as_str()],
        "placement top did not put the new workspace first below Home"
    );
    mux.shutdown();
}

/// Closing the last workspace removes only its item, including through the
/// persisted daemon path that publishes changes to the app's pinned FFI mirror.
#[test]
fn closing_last_workspace_keeps_nested_groups_and_reopen_returns_to_them() {
    let session = Session::new("close-keeps-groups");
    let mux = session.open();
    let last = empty_workspace(&mux, "last");
    let work = mutate(&mux, "workspace_group.create", json!({"name": "Work"}), "group-work")["id"]
        .as_str()
        .unwrap()
        .to_string();
    mutate(&mux, "workspace.place", json!({"workspace": last, "group": work}), "last-in-work");
    let (member, section, outer) = item_of(&mux, &last);
    let outer = outer.unwrap();
    send(
        &mux,
        "sidebar.group.create",
        json!({"name": "Inner", "items": [member],
               "to": {"section": section, "parent": outer}}),
        Some("inner"),
    )
    .unwrap();
    let inner = item_of(&mux, &last).2.unwrap();
    let groups = |mux: &Arc<Mux>| {
        mux.read_registry_state(|connection| {
            super::sidebar_doc_store::with_doc(connection, |doc| {
                Ok([&outer, &inner].map(|id| doc.item(id).cloned()))
            })
        })
        .unwrap()
    };
    let before = groups(&mux);
    assert!(before.iter().all(Option::is_some));
    mutate(&mux, "workspace.close", json!({"workspace": last}), "close-last");
    assert!(shown(&mux, &[last.as_str()]).is_empty());
    assert_eq!(groups(&mux), before, "both headers keep their identity, order and fold");
    mux.shutdown();
    drop(mux);

    let mux = session.open();
    assert_eq!(groups(&mux), before, "the empty groups persist across restart");
    let reopened = mutate(&mux, "closed.reopen", json!({}), "reopen-last");
    let restored = reopened["workspace_id"].as_str().unwrap();
    assert_eq!(item_of(&mux, restored).2.as_deref(), Some(inner.as_str()));
    assert_eq!(groups(&mux), before, "reopen reuses the existing groups");
    mux.shutdown();
}
