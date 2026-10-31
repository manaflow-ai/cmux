//! `personal-mixed-order-v1` over `cmux.protocol/2`: a group's slot among
//! the loose workspaces (`workspace_group.update {top_index}`), the personal
//! row a new workspace gets at create, and `workspace.list {order:
//! "personal"}`, the sidebar order every client reads.

use serde_json::json;

use super::tests::{
    Session, changes_after, empty_workspace, error_code, mutate, placements_by_id, read,
    replayed_placements, revision, send,
};
use crate::mux::*;
use crate::state::prelude::*;

/// The workspace ids of `workspace.list {order}` restricted to `ids`.
fn listed(mux: &Arc<Mux>, order: Option<&str>, ids: &[&str]) -> Vec<String> {
    let params = order.map_or_else(|| json!({}), |order| json!({"order": order}));
    read(mux, "workspace.list", params)
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|workspace| workspace["id"].as_str())
        .filter(|id| ids.contains(id))
        .map(str::to_string)
        .collect()
}

fn group(mux: &Arc<Mux>, name: &str) -> String {
    mutate(mux, "workspace_group.create", json!({"name": name}), &format!("group-{name}"))["id"]
        .as_str()
        .unwrap()
        .to_string()
}

/// A group moves between loose rows, its members show at its slot in the
/// personal order, and null puts it back after every loose workspace.
#[test]
fn a_group_slot_between_loose_rows_orders_the_personal_workspace_list() {
    let session = Session::new("mixed-slot");
    let mux = session.open();
    // Made in sidebar order (workspaces.newPlacement bottom).
    let _bottom = crate::user_settings::NewWorkspacePlacement::Bottom.set_for_test();
    let a = empty_workspace(&mux, "a");
    let b = empty_workspace(&mux, "b");
    let c = empty_workspace(&mux, "c");
    let d = empty_workspace(&mux, "d");
    let work = group(&mux, "Work");
    mutate(&mux, "workspace.place", json!({"workspace": d, "group": work}), "d-in-work");
    let ids = [a.as_str(), b.as_str(), c.as_str(), d.as_str()];
    let [a, b, c, d] = ids;
    assert_eq!(listed(&mux, Some("personal"), &ids), [a, b, c, d], "no slot: group last");

    // top_index alone is a valid update: the personal workspace index of
    // the row the group shows before (b).
    let moved = mutate(
        &mux,
        "workspace_group.update",
        json!({"workspace_group": work, "top_index": 1}),
        "work-before-b",
    );
    assert_eq!(moved["top_index"], 1);
    let groups = read(&mux, "workspace_group.list", json!({}));
    assert_eq!(groups[0]["top_index"], 1);
    assert_eq!(listed(&mux, Some("personal"), &ids), [a, d, b, c]);
    // The default order is the sidebar order (one order with the sidebar
    // document); `session` keeps the session order.
    assert_eq!(listed(&mux, None, &ids), [a, d, b, c]);
    assert_eq!(listed(&mux, Some("session"), &ids), [a, b, c, d]);

    // c moves to the front: the group keeps its slot before b.
    mutate(&mux, "workspace.place", json!({"workspace": c, "index": 0}), "c-first");
    assert_eq!(listed(&mux, Some("personal"), &ids), [c, a, d, b]);

    let back = mutate(
        &mux,
        "workspace_group.update",
        json!({"workspace_group": work, "top_index": null}),
        "work-last",
    );
    assert!(back["top_index"].is_null());
    assert_eq!(listed(&mux, Some("personal"), &ids), [c, a, b, d]);
    assert_eq!(
        error_code(send(&mux, "workspace.list", json!({"order": "random"}), None)),
        "validation.invalid"
    );
    mux.shutdown();
}

fn personal_rows(mux: &Arc<Mux>) -> usize {
    mux.personal_snapshot().unwrap().workspaces.len()
}

/// A new workspace gets its personal row in the commit that creates it,
/// so a group slot counts it from the start.
#[test]
fn a_new_workspace_gets_a_personal_row_at_create() {
    let session = Session::new("mixed-create");
    let mux = session.open();
    let before = personal_rows(&mux);
    let a = empty_workspace(&mux, "a");
    assert_eq!(personal_rows(&mux), before + 1, "workspace.create wrote no personal row");
    let b = empty_workspace(&mux, "b");
    assert_eq!(personal_rows(&mux), before + 2);
    let placements = read(&mux, "workspace.placement.list", json!({}));
    let index = |id: &String| {
        placements
            .as_array()
            .unwrap()
            .iter()
            .find(|row| row["workspace"]["workspace_id"] == id.as_str())
            .and_then(|row| row["index"].as_u64())
            .unwrap()
    };
    assert_eq!(index(&b) + 1, index(&a), "a new row goes first (workspaces.newPlacement top)");
    // The row survives a restart (it is in the store, not synthesized).
    drop(mux);
    let mux = session.open();
    assert_eq!(personal_rows(&mux), before + 2);
    mux.shutdown();
}

/// Mixed order keeps Home first: no group slot at or before Home.
#[test]
fn a_group_slot_before_home_is_refused() {
    let session = Session::new("mixed-home");
    let mux = session.open();
    send(&mux, "workspace.ensure_home", json!({}), Some("connect")).unwrap();
    let a = empty_workspace(&mux, "a");
    let work = group(&mux, "Work");
    mutate(&mux, "workspace.place", json!({"workspace": a, "group": work}), "a-in-work");
    assert_eq!(
        error_code(send(
            &mux,
            "workspace_group.update",
            json!({"workspace_group": work, "top_index": 0}),
            Some("work-first"),
        )),
        "home.pinned_first"
    );
    let after_home = mutate(
        &mux,
        "workspace_group.update",
        json!({"workspace_group": work, "top_index": 1}),
        "work-second",
    );
    assert_eq!(after_home["top_index"], 1);
    mux.shutdown();
}

/// `workspaces.newPlacement` defaults to `top` for every client: a workspace
/// made by a plain `workspace.create` (what the TUI, the CLI, iOS and agents
/// send; no app places it afterwards) gets the first row below Home in the
/// commit that creates it, before a group placed right below Home, and keeps
/// it across a restart.
#[test]
fn a_new_workspace_from_any_client_lands_at_the_top_by_default() {
    let session = Session::new("new-top");
    let mux = session.open();
    let home = send(&mux, "workspace.ensure_home", json!({}), Some("connect")).unwrap()["value"]
        ["workspace_id"]
        .as_str()
        .unwrap()
        .to_string();
    let a = empty_workspace(&mux, "a");
    let work = group(&mux, "Work");
    mutate(&mux, "workspace.place", json!({"workspace": a, "group": work}), "a-in-work");
    mutate(
        &mux,
        "workspace_group.update",
        json!({"workspace_group": work, "top_index": 1}),
        "work-below-home",
    );
    let (start, before) = (placements_by_id(&mux), revision(&mux));
    let b = empty_workspace(&mux, "b");
    let c = empty_workspace(&mux, "c");
    assert_eq!(
        replayed_placements(&mux, start, before),
        placements_by_id(&mux),
        "session.events does not carry every moved placement"
    );
    let ids = [home.as_str(), a.as_str(), b.as_str(), c.as_str()];
    let expected = [home.as_str(), c.as_str(), b.as_str(), a.as_str()];
    assert_eq!(listed(&mux, Some("personal"), &ids), expected, "new workspaces not on top");
    let placements = read(&mux, "workspace.placement.list", json!({}));
    let index = |id: &str| {
        placements
            .as_array()
            .unwrap()
            .iter()
            .find(|row| row["workspace"]["workspace_id"] == id)
            .and_then(|row| row["index"].as_u64())
            .unwrap()
    };
    assert_eq!((index(&home), index(&c), index(&b)), (0, 1, 2));
    // The group stays after the new loose rows, at its place before `a`'s row.
    let groups = read(&mux, "workspace_group.list", json!({}));
    assert_eq!(groups[0]["top_index"], 3, "the group slot did not move past the new rows");
    drop(mux);
    let mux = session.open();
    assert_eq!(listed(&mux, Some("personal"), &ids), expected, "the top place is not stored");
    mux.shutdown();
}

/// `afterCurrent`: right after the session's active workspace, inside its
/// group; Home (or no current workspace) falls back to top. `bottom`: last.
#[test]
fn a_new_workspace_follows_the_after_current_and_bottom_settings() {
    use crate::user_settings::NewWorkspacePlacement;
    let session = Session::new("new-after-current");
    let mux = session.open();
    let home = send(&mux, "workspace.ensure_home", json!({}), Some("connect")).unwrap()["value"]
        ["workspace_id"]
        .as_str()
        .unwrap()
        .to_string();
    let a = empty_workspace(&mux, "a");
    let b = empty_workspace(&mux, "b");
    // An explicit index: a group made with none forms below Home under top.
    let work = mutate(
        &mux,
        "workspace_group.create",
        json!({"name": "Work", "index": 0}),
        "group-Work",
    )["id"]
        .as_str()
        .unwrap()
        .to_string();
    mutate(&mux, "workspace.place", json!({"workspace": a, "group": work}), "a-in-work");
    // Personal order now: home, b, then Work [a] after every loose row.
    let after = NewWorkspacePlacement::AfterCurrent.set_for_test();
    mutate(&mux, "workspace.focus", json!({"workspace": b}), "focus-b");
    let c = empty_workspace(&mux, "c");
    mutate(&mux, "workspace.focus", json!({"workspace": a}), "focus-a");
    let d = empty_workspace(&mux, "d");
    mutate(&mux, "workspace.focus", json!({"workspace": home}), "focus-home");
    let e = empty_workspace(&mux, "e");
    drop(after);
    let bottom = NewWorkspacePlacement::Bottom.set_for_test();
    let f = empty_workspace(&mux, "f");
    drop(bottom);
    let ids = [&home, &a, &b, &c, &d, &e, &f].map(String::as_str);
    let [home, a, b, c, d, e, f] = ids;
    assert_eq!(listed(&mux, Some("personal"), &ids), [home, e, b, c, f, a, d]);
    let placements = read(&mux, "workspace.placement.list", json!({}));
    let group_of = |id: &str| {
        placements
            .as_array()
            .unwrap()
            .iter()
            .find(|row| row["workspace"]["workspace_id"] == id)
            .map(|row| row["group_id"].clone())
            .unwrap()
    };
    assert_eq!(group_of(d), json!(work), "after a grouped workspace: in its group");
    assert!(group_of(c).is_null() && group_of(e).is_null() && group_of(f).is_null());
    mux.shutdown();
}

/// `beforeCurrent`: right before the session's active workspace, inside its
/// group; Home (or no current workspace) falls back to top.
#[test]
fn a_new_workspace_follows_the_before_current_setting() {
    use crate::user_settings::NewWorkspacePlacement;
    let session = Session::new("new-before-current");
    let mux = session.open();
    let home = send(&mux, "workspace.ensure_home", json!({}), Some("connect")).unwrap()["value"]
        ["workspace_id"]
        .as_str()
        .unwrap()
        .to_string();
    let a = empty_workspace(&mux, "a");
    let b = empty_workspace(&mux, "b");
    let work = group(&mux, "Work");
    mutate(&mux, "workspace.place", json!({"workspace": a, "group": work}), "a-in-work");
    // Personal order now: home, b, then Work [a] after every loose row.
    let before = NewWorkspacePlacement::BeforeCurrent.set_for_test();
    mutate(&mux, "workspace.focus", json!({"workspace": b}), "focus-b");
    let c = empty_workspace(&mux, "c");
    mutate(&mux, "workspace.focus", json!({"workspace": a}), "focus-a");
    let d = empty_workspace(&mux, "d");
    mutate(&mux, "workspace.focus", json!({"workspace": home}), "focus-home");
    let e = empty_workspace(&mux, "e");
    drop(before);
    let ids = [&home, &a, &b, &c, &d, &e].map(String::as_str);
    let [home, a, b, c, d, e] = ids;
    assert_eq!(listed(&mux, Some("personal"), &ids), [home, e, c, b, d, a]);
    let placements = read(&mux, "workspace.placement.list", json!({}));
    let group_of = |id: &str| {
        placements
            .as_array()
            .unwrap()
            .iter()
            .find(|row| row["workspace"]["workspace_id"] == id)
            .map(|row| row["group_id"].clone())
            .unwrap()
    };
    assert_eq!(group_of(d), json!(work), "before a grouped workspace: in its group");
    assert!(group_of(c).is_null() && group_of(e).is_null());
    mux.shutdown();
}

/// `create-workspace {current}`: the workspace the creating client shows
/// places the new one, not the session's active workspace (a legacy default
/// the app's windows never move). `afterCurrent` goes right after it; `top`
/// and `bottom` keep the new row in its group (first, last), as the
/// app places it, so the app's own placement after the create moves nothing.
#[test]
fn a_new_workspace_follows_the_creating_clients_current_workspace() {
    use crate::user_settings::NewWorkspacePlacement;
    let session = Session::new("new-client-current");
    let mux = session.open();
    // `client`: None, a create that names no current workspace; Some(current), the client's
    // current workspace (None: the window shows a top page).
    let create = |name: &str, client: Option<Option<&str>>| {
        let client = client.map(|current| crate::state::personal_order::ClientCurrent {
            current: current.map(str::to_string),
            placement: None,
        });
        let key = crate::state::personal_order::with_client_current(client, || {
            mux.create_empty_workspace(Some(name.to_string()), None, None)
        })
        .unwrap()
        .key;
        let id = mux
            .personal_state_read(|connection| {
                crate::state::values::workspace_public_id_for_key(connection, &key)
            })
            .unwrap()
            .unwrap();
        (key, id)
    };
    let bottom = NewWorkspacePlacement::Bottom.set_for_test();
    let (_, a) = create("a", None);
    let (b_key, b) = create("b", None);
    let (g_key, g) = create("g", None);
    let (_, h) = create("h", None);
    drop(bottom);
    let work = group(&mux, "Work");
    mutate(&mux, "workspace.place", json!({"workspace": a, "group": work}), "a-in-work");
    mutate(&mux, "workspace.place", json!({"workspace": g, "group": work}), "g-in-work");
    mutate(&mux, "workspace.place", json!({"workspace": h, "group": work}), "h-in-work");
    // Personal order now: b, then Work [a, g, h]. The client shows the middle member g.
    mutate(&mux, "workspace.focus", json!({"workspace": a}), "focus-a");
    let after = NewWorkspacePlacement::AfterCurrent.set_for_test();
    let (_, c) = create("c", Some(Some(&b_key)));
    drop(after);
    let top = NewWorkspacePlacement::Top.set_for_test();
    let (_, d) = create("d", Some(Some(&g_key)));
    drop(top);
    let bottom = NewWorkspacePlacement::Bottom.set_for_test();
    let (_, e) = create("e", Some(Some(&g_key)));
    drop(bottom);
    // A window on a top page names no current workspace: the top, not beside the active one.
    mutate(&mux, "workspace.focus", json!({"workspace": a}), "focus-a-again");
    let after = NewWorkspacePlacement::AfterCurrent.set_for_test();
    let (_, f) = create("f", Some(None));
    drop(after);
    let ids = [&a, &b, &c, &d, &e, &f, &g, &h].map(String::as_str);
    assert_eq!(
        listed(&mux, Some("personal"), &ids),
        [
            f.as_str(),
            b.as_str(),
            c.as_str(),
            d.as_str(),
            a.as_str(),
            g.as_str(),
            h.as_str(),
            e.as_str()
        ]
    );
    let placements = read(&mux, "workspace.placement.list", json!({}));
    let group_of = |id: &str| {
        placements
            .as_array()
            .unwrap()
            .iter()
            .find(|row| row["workspace"]["workspace_id"] == id)
            .map(|row| row["group_id"].clone())
            .unwrap()
    };
    assert!(
        group_of(&c).is_null(),
        "after the client's loose current workspace, not the active grouped one"
    );
    assert!(group_of(&f).is_null(), "no current workspace: the top, not the active one's group");
    assert_eq!(group_of(&d), json!(work), "top from a grouped workspace: in its group");
    assert_eq!(group_of(&e), json!(work), "bottom from a grouped workspace: last in its group");
    mux.shutdown();
}

/// A pinned current keeps a legacy personal row, but it cannot anchor a new machine row.
#[test]
fn a_new_workspace_ignores_a_pinned_current_workspace() {
    use crate::user_settings::NewWorkspacePlacement;
    for placement in [NewWorkspacePlacement::BeforeCurrent, NewWorkspacePlacement::AfterCurrent] {
        let session = Session::new("new-pinned-current");
        let mux = session.open();
        let bottom = NewWorkspacePlacement::Bottom.set_for_test();
        let a = empty_workspace(&mux, "a");
        let current = mux.create_empty_workspace(Some("b".into()), None, None).unwrap();
        let b = mux
            .personal_state_read(|connection| {
                crate::state::values::workspace_public_id_for_key(connection, &current.key)
            })
            .unwrap()
            .unwrap();
        let c = empty_workspace(&mux, "c");
        drop(bottom);
        let doc = read(&mux, "sidebar.get", json!({}));
        let item = doc["items"]
            .as_array()
            .unwrap()
            .iter()
            .find(|item| item["body"]["ref"]["workspace_id"] == b)
            .unwrap()["id"]
            .clone();
        mutate(&mux, "sidebar.pin", json!({"items": [item]}), "pin-current");
        let placed = crate::state::personal_order::with_client_current(
            Some(crate::state::personal_order::ClientCurrent {
                current: Some(current.key),
                placement: Some(placement),
            }),
            || mux.create_empty_workspace(Some("d".into()), None, None),
        )
        .unwrap();
        let d = mux
            .personal_state_read(|connection| {
                crate::state::values::workspace_public_id_for_key(connection, &placed.key)
            })
            .unwrap()
            .unwrap();
        let ids = [&a, &b, &c, &d].map(String::as_str);
        assert_eq!(listed(&mux, Some("personal"), &ids), [b, d, a, c]);
        mux.shutdown();
    }
}

/// A place across a group changes the group's `top_index` (its place stays
/// among the other rows); the same commit's `session.events` batch carries
/// the group's new snapshot, so mirrors never keep a stale `top_index`.
#[test]
fn a_place_across_a_group_publishes_the_group_change() {
    let session = Session::new("mixed-events");
    let mux = session.open();
    // New rows go last, so the order is a, b, c (the default puts them on top).
    let _bottom = crate::user_settings::NewWorkspacePlacement::Bottom.set_for_test();
    let a = empty_workspace(&mux, "a");
    let b = empty_workspace(&mux, "b");
    let c = empty_workspace(&mux, "c");
    let work = group(&mux, "Work");
    mutate(
        &mux,
        "workspace_group.update",
        json!({"workspace_group": work, "top_index": 1}),
        "work-before-b",
    );
    let index = |name: &str| {
        read(&mux, "workspace.placement.list", json!({}))
            .as_array()
            .unwrap()
            .iter()
            .find(|row| row["workspace"]["workspace_id"] == name)
            .and_then(|row| row["index"].as_u64())
            .unwrap()
    };
    let groups = read(&mux, "workspace_group.list", json!({}));
    assert_eq!(groups[0]["top_index"].as_u64(), Some(index(b.as_str())), "the group is before b");
    let top_of_b = index(b.as_str());
    let before = revision(&mux);
    // c moves to the front, across the group: the group stays before b,
    // whose index grows by one.
    mutate(&mux, "workspace.place", json!({"workspace": c, "index": 0}), "c-first");
    let listed = read(&mux, "workspace_group.list", json!({}));
    let top = listed[0]["top_index"].as_u64().unwrap();
    assert_eq!(top, top_of_b + 1, "the group's index moved with b");
    let published = changes_after(&mux, before);
    assert!(
        published.iter().any(|change| change["kind"] == "state_upsert"
            && change["resource"] == "workspace_group"
            && change["id"] == work.as_str()
            && change["value"]["top_index"] == top),
        "no workspace_group change with top_index {top}: {published:?}"
    );
    // A place that does not cross the group publishes no group change.
    let before = revision(&mux);
    mutate(&mux, "workspace.place", json!({"workspace": a, "index": 0}), "a-first");
    assert!(
        !changes_after(&mux, before).iter().any(|change| change["resource"] == "workspace_group"),
        "an unchanged group was published"
    );
    mux.shutdown();
}
