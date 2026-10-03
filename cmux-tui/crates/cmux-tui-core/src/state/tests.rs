//! Behavioral tests of the state resources (state-ownership.md steps A and
//! B), driven through `cmux.protocol/2` requests.

use std::path::PathBuf;

use serde_json::json;

use crate::mux::ProviderWorkspaceState;
use crate::mux::*;
use crate::resource_router::handle_resource_message;
use crate::state::prelude::*;
use crate::surface::SurfaceOptions;
use crate::workspace_registry::WorkspacePresentationUpdate;
use crate::workspace_registry::WorkspaceRegistry;

struct Session {
    root: PathBuf,
    name: &'static str,
}

impl Session {
    fn new(name: &'static str) -> Self {
        let root = std::env::temp_dir()
            .join(format!("cmux-state-{name}-{}", WorkspacePublicId::random().unwrap()));
        Self { root, name }
    }

    fn open(&self) -> Arc<Mux> {
        let registry = WorkspaceRegistry::open(&self.root, self.name).unwrap();
        Mux::from_workspace_registry(
            self.name.into(),
            SurfaceOptions::default(),
            registry,
            ProviderWorkspaceState::default(),
            true,
        )
        .unwrap()
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

fn send(
    mux: &Arc<Mux>,
    operation: &str,
    params: Value,
    key: Option<&str>,
) -> Result<Value, ResourceError> {
    let mut params = params;
    params["machine"] = json!("current");
    params["session"] = json!("current");
    let mut envelope = json!({
        "protocol": "cmux.protocol/2",
        "type": "request",
        "id": format!("{operation}-test"),
        "operation": operation,
        "params": params,
    });
    if let Some(key) = key {
        envelope["idempotency_key"] = json!(key);
    }
    let response = handle_resource_message(mux, &serde_json::to_string(&envelope).unwrap())?;
    if response["ok"] == true {
        Ok(response["result"].clone())
    } else {
        Err(serde_json::from_value(response["error"].clone()).unwrap())
    }
}

/// A committed mutation's value.
fn mutate(mux: &Arc<Mux>, operation: &str, params: Value, key: &str) -> Value {
    let result = send(mux, operation, params, Some(key))
        .unwrap_or_else(|error| panic!("{operation} failed: {error:?}"));
    assert_eq!(result["replayed"], false, "{operation} unexpectedly replayed");
    result["value"].clone()
}

fn read(mux: &Arc<Mux>, operation: &str, params: Value) -> Value {
    send(mux, operation, params, None)
        .unwrap_or_else(|error| panic!("{operation} failed: {error:?}"))
}

fn error_code(result: Result<Value, ResourceError>) -> String {
    result.expect_err("request unexpectedly succeeded").code
}

/// Every change of every resource batch after `revision`.
fn changes_after(mux: &Mux, revision: u64) -> Vec<Value> {
    mux.resource_events_after(revision)
        .unwrap()
        .batches
        .into_iter()
        .flat_map(|batch| batch.changes.as_array().cloned().unwrap_or_default())
        .collect()
}

fn revision(mux: &Mux) -> u64 {
    mux.with_state(|state| state.resource_revision)
}

fn snapshot(mux: &Mux) -> Value {
    crate::resource_api::public_session_snapshot(mux).unwrap()
}

fn empty_workspace(mux: &Arc<Mux>, name: &str) -> String {
    let created = mutate(
        mux,
        "workspace.create",
        json!({"name": name, "initial_content": "empty"}),
        &format!("create-{name}"),
    );
    created["workspace_id"].as_str().unwrap().to_string()
}

fn tab_id(mux: &Mux, surface: SurfaceId) -> String {
    mux.with_state(|state| state.resource_indexes.tab_ids[&surface].to_string())
}

fn pane_id(mux: &Mux, surface: SurfaceId) -> String {
    mux.with_state(|state| {
        let pane = state.pane_of(surface).unwrap();
        state.resource_indexes.pane_ids[&pane].to_string()
    })
}

fn pane_tab_ids(mux: &Mux, surface: SurfaceId) -> Vec<String> {
    mux.with_state(|state| {
        let pane = state.pane_of(surface).unwrap();
        state.panes[&pane]
            .tabs
            .iter()
            .map(|tab| state.resource_indexes.tab_ids[tab].to_string())
            .collect()
    })
}

/// One workspace with one pane holding `count` terminal tabs.
fn terminal_tabs(mux: &Arc<Mux>, count: usize) -> Vec<SurfaceId> {
    let first = mux.new_workspace(None, None).unwrap().id;
    let pane = mux.with_state(|state| state.pane_of(first)).unwrap();
    let mut tabs = vec![first];
    for _ in 1..count {
        tabs.push(mux.new_tab(Some(pane), None, None).unwrap().id);
    }
    tabs
}

#[test]
fn workspace_update_carries_identity_through_snapshot_events_and_replay() {
    let mux = Mux::new_for_test("state-identity", SurfaceOptions::default());
    let workspace = empty_workspace(&mux, "api");
    let before = revision(&mux);
    let params = json!({"workspace": workspace, "title": "API server", "color": "#336699", "icon": "server.rack"});
    let updated = mutate(&mux, "workspace.update", params.clone(), "identity-1");
    assert_eq!(updated["id"], workspace);
    assert_eq!(updated["extra"]["title"], "API server");
    assert_eq!(updated["extra"]["color"], "#336699");
    assert_eq!(updated["extra"]["icon"], "server.rack");

    let replay = send(&mux, "workspace.update", params, Some("identity-1")).unwrap();
    assert_eq!(replay["replayed"], true);
    assert_eq!(replay["value"], updated);
    let conflict = send(
        &mux,
        "workspace.update",
        json!({"workspace": workspace, "title": "Other"}),
        Some("identity-1"),
    );
    assert_eq!(error_code(conflict), "idempotency.conflict");

    let snapshot = snapshot(&mux);
    let listed = snapshot["workspaces"]
        .as_array()
        .unwrap()
        .iter()
        .find(|value| value["id"] == workspace)
        .unwrap();
    assert_eq!(listed["extra"]["title"], "API server");
    let events = changes_after(&mux, before);
    assert!(events.iter().any(|change| change["resource"] == "workspace"
        && change["value"]["extra"]["icon"] == "server.rack"));

    // A later rename restates the workspace without losing its identity.
    let renamed = mutate(
        &mux,
        "workspace.rename",
        json!({"workspace": workspace, "name": "api-2"}),
        "rename-1",
    );
    assert_eq!(renamed["extra"]["title"], "API server");
    let cleared = mutate(
        &mux,
        "workspace.update",
        json!({"workspace": workspace, "title": null}),
        "identity-2",
    );
    assert!(cleared["extra"].get("title").is_none());
    assert_eq!(cleared["extra"]["color"], "#336699");
    assert_eq!(
        error_code(send(
            &mux,
            "workspace.update",
            json!({"workspace": workspace}),
            Some("identity-3")
        )),
        "validation.invalid"
    );
    assert_eq!(
        error_code(send(
            &mux,
            "workspace.update",
            json!({"workspace": workspace, "color": "not a color!"}),
            Some("identity-4")
        )),
        "validation.invalid"
    );
}

#[test]
fn tab_pin_moves_the_tab_first_and_unpin_returns_it_behind_the_pinned_run() {
    let mux = Mux::new_for_test("state-pins", SurfaceOptions::default());
    let tabs = terminal_tabs(&mux, 3);
    let third = tab_id(&mux, tabs[2]);
    let before = revision(&mux);
    let pinned = mutate(&mux, "tab.pin", json!({"tab": third}), "pin-1");
    assert_eq!(pinned["id"], third);
    assert_eq!(pinned["index"], 0);
    assert_eq!(pinned["extra"]["pinned"], true);
    assert_eq!(pane_tab_ids(&mux, tabs[0])[0], third);
    assert!(
        changes_after(&mux, before)
            .iter()
            .any(|change| change["id"] == third && change["value"]["extra"]["pinned"] == true)
    );
    assert_eq!(
        send(&mux, "tab.pin", json!({"tab": third}), Some("pin-1")).unwrap()["replayed"],
        true
    );

    let second = tab_id(&mux, tabs[1]);
    let pinned = mutate(&mux, "tab.pin", json!({"tab": second}), "pin-2");
    assert_eq!(pinned["index"], 1);
    let unpinned = mutate(&mux, "tab.unpin", json!({"tab": third}), "unpin-1");
    assert_eq!(unpinned["index"], 1);
    assert!(unpinned["extra"].get("pinned").is_none());
    assert_eq!(pane_tab_ids(&mux, tabs[0]), vec![second.clone(), third, tab_id(&mux, tabs[0])]);
    let snapshot = snapshot(&mux);
    let listed =
        snapshot["tabs"].as_array().unwrap().iter().find(|tab| tab["id"] == second).unwrap();
    assert_eq!(listed["extra"]["pinned"], true);
}

#[test]
fn tab_update_stores_zoom_and_rejects_history_on_a_terminal_tab() {
    let mux = Mux::new_for_test("state-tab-update", SurfaceOptions::default());
    let tabs = terminal_tabs(&mux, 1);
    let tab = tab_id(&mux, tabs[0]);
    let zoomed = mutate(&mux, "tab.update", json!({"tab": tab, "zoom": 1.5}), "zoom-1");
    assert_eq!(zoomed["extra"]["zoom"], 1.5);
    let cleared = mutate(&mux, "tab.update", json!({"tab": tab, "zoom": null}), "zoom-2");
    assert!(cleared["extra"].get("zoom").is_none());
    assert_eq!(
        error_code(send(&mux, "tab.update", json!({"tab": tab, "zoom": 9.0}), Some("zoom-3"))),
        "validation.invalid"
    );
    assert_eq!(
        error_code(send(
            &mux,
            "tab.update",
            json!({"tab": tab, "back": ["https://example.com"]}),
            Some("zoom-4")
        )),
        "validation.invalid"
    );
}

#[test]
fn tab_groups_create_edit_move_ungroup_and_close_through_public_ids() {
    let mux = Mux::new_for_test("state-tab-groups", SurfaceOptions::default());
    let tabs = terminal_tabs(&mux, 4);
    let ids = tabs.iter().map(|tab| tab_id(&mux, *tab)).collect::<Vec<_>>();
    let before = revision(&mux);
    let group = mutate(
        &mux,
        "tab_group.create",
        json!({"tabs": [ids[3], ids[1]], "name": "Build", "color": "blue"}),
        "group-create",
    );
    let group_id = group["id"].as_str().unwrap().to_string();
    assert!(group_id.starts_with("tgrp_"));
    assert_eq!(group["tab_ids"], json!([ids[1], ids[3]]));
    assert_eq!(group["pane_id"], pane_id(&mux, tabs[0]));
    assert_eq!(
        pane_tab_ids(&mux, tabs[0]),
        vec![ids[0].clone(), ids[1].clone(), ids[3].clone(), ids[2].clone()]
    );
    let events = changes_after(&mux, before);
    assert!(events.iter().any(|change| change["kind"] == "state_upsert"
        && change["resource"] == "tab_group"
        && change["id"] == group_id));
    assert!(events.iter().any(|change| change["resource"] == "tab"
        && change["id"] == ids[3]
        && change["value"]["extra"]["tab_group_id"] == group_id));

    let updated = mutate(
        &mux,
        "tab_group.update",
        json!({"tab_group": group_id, "name": "CI", "collapsed": true}),
        "group-update",
    );
    assert_eq!(
        (updated["name"].as_str(), updated["collapsed"].as_bool()),
        (Some("CI"), Some(true))
    );
    let added = mutate(
        &mux,
        "tab_group.add_tabs",
        json!({"tab_group": group_id, "tabs": [ids[0]]}),
        "group-add",
    );
    assert_eq!(added["tab_ids"], json!([ids[1], ids[3], ids[0]]));
    let moved =
        mutate(&mux, "tab_group.move", json!({"tab_group": group_id, "index": 1}), "group-move");
    assert_eq!(moved["tab_ids"], json!([ids[1], ids[3], ids[0]]));
    assert_eq!(pane_tab_ids(&mux, tabs[0])[0], ids[2]);
    let removed = mutate(&mux, "tab_group.remove_tabs", json!({"tabs": [ids[0]]}), "group-remove");
    assert_eq!(removed[0]["tab_ids"], json!([ids[1], ids[3]]));

    let listed = read(&mux, "tab_group.list", json!({}));
    assert_eq!(listed.as_array().unwrap().len(), 1);
    assert_eq!(read(&mux, "tab_group.get", json!({"tab_group": group_id}))["name"], "CI");
    let snapshot = snapshot(&mux);
    assert_eq!(snapshot["extra"]["state"]["tab_groups"][0]["id"], group_id);

    let ungrouped =
        mutate(&mux, "tab_group.ungroup", json!({"tab_group": group_id}), "group-ungroup");
    assert_eq!(ungrouped["tab_ids"], json!([ids[1], ids[3]]));
    assert_eq!(
        error_code(send(&mux, "tab_group.get", json!({"tab_group": group_id}), None)),
        "resource.not_found"
    );

    let second = mutate(&mux, "tab_group.create", json!({"tabs": [ids[2]]}), "group-create-2");
    let second_id = second["id"].as_str().unwrap().to_string();
    assert_eq!(second["color"], "grey");
    let closed = mutate(&mux, "tab_group.close", json!({"tab_group": second_id}), "group-close");
    assert_eq!(closed["tab_ids"], json!([ids[2]]));
    assert!(mux.with_state(|state| {
        !state.resource_indexes.tab_ids.values().any(|id| id.as_str() == ids[2])
    }));
    let replay =
        send(&mux, "tab_group.close", json!({"tab_group": second_id}), Some("group-close"))
            .unwrap();
    assert_eq!(replay["replayed"], true);
    assert_eq!(replay["value"], closed);
}

#[test]
fn pinned_tabs_cannot_be_grouped() {
    let mux = Mux::new_for_test("state-pinned-groups", SurfaceOptions::default());
    let tabs = terminal_tabs(&mux, 2);
    let first = tab_id(&mux, tabs[0]);
    mutate(&mux, "tab.pin", json!({"tab": first}), "pin");
    assert_eq!(
        error_code(send(&mux, "tab_group.create", json!({"tabs": [first]}), Some("group"))),
        "validation.invalid"
    );
}

#[test]
fn personal_groups_placements_and_rooms_commit_personal_state_with_replay() {
    let mux = Mux::new_for_test("state-personal", SurfaceOptions::default());
    let a = empty_workspace(&mux, "a");
    let b = empty_workspace(&mux, "b");
    let personal_before = mux.personal_snapshot().unwrap().personal_revision;
    let before = revision(&mux);

    let work =
        mutate(&mux, "workspace_group.create", json!({"name": "Work", "color": "#225588"}), "wg-1");
    let work_id = work["id"].as_str().unwrap().to_string();
    assert_eq!(work["room_id"], "default");
    assert!(mux.personal_snapshot().unwrap().personal_revision > personal_before);
    assert_eq!(
        send(
            &mux,
            "workspace_group.create",
            json!({"name": "Work", "color": "#225588"}),
            Some("wg-1")
        )
        .unwrap()["replayed"],
        true
    );
    assert_eq!(
        mux.personal_snapshot().unwrap().groups.iter().filter(|group| group.name == "Work").count(),
        1
    );

    let play = mutate(&mux, "workspace_group.create", json!({"name": "Play", "index": 0}), "wg-2");
    assert_eq!(play["index"], 0);
    let moved = mutate(
        &mux,
        "workspace_group.move",
        json!({"workspace_group": work_id, "index": 0}),
        "wg-3",
    );
    assert_eq!(moved["index"], 0);
    let updated = mutate(
        &mux,
        "workspace_group.update",
        json!({"workspace_group": work_id, "collapsed": true, "color": null}),
        "wg-4",
    );
    assert_eq!((updated["collapsed"].as_bool(), updated["color"].is_null()), (Some(true), true));

    let placed = mutate(
        &mux,
        "workspace.place",
        json!({"workspace": b, "group": work_id, "index": 0}),
        "place-1",
    );
    assert_eq!(placed["workspace"]["workspace_id"], b);
    assert_eq!(placed["group_id"], work_id);
    assert_eq!(placed["index"], 0);
    let placements = read(&mux, "workspace.placement.list", json!({}));
    assert!(placements.as_array().unwrap().iter().any(|row| row["workspace"]["workspace_id"] == a));
    assert_eq!(
        error_code(send(
            &mux,
            "workspace.place",
            json!({"workspace": a, "group": "grp_missing"}),
            Some("place-2")
        )),
        "resource.not_found"
    );

    let room =
        mutate(&mux, "room.create", json!({"name": "Side project", "icon": "star"}), "room-1");
    let room_id = room["id"].as_str().unwrap().to_string();
    assert!(room_id.starts_with("prof_"));
    let pinned = mutate(&mux, "room.pin", json!({"room": room_id, "workspace": a}), "room-2");
    assert_eq!(pinned["pins"][0]["workspace_id"], a);
    let followed =
        mutate(&mux, "room.follow", json!({"room": room_id, "sessions": ["build-box"]}), "room-3");
    assert_eq!(followed["follows"], json!(["build-box"]));
    let renamed = mutate(
        &mux,
        "room.update",
        json!({"room": room_id, "name": "Side", "icon": null}),
        "room-4",
    );
    assert_eq!((renamed["name"].as_str(), renamed["icon"].is_null()), (Some("Side"), true));
    let moved_room = mutate(&mux, "room.move", json!({"room": room_id, "index": 0}), "room-5");
    assert_eq!(moved_room["index"], 0);
    let unpinned = mutate(&mux, "room.unpin", json!({"workspace": a}), "room-6");
    assert!(unpinned["room_id"].is_null());
    assert_eq!(
        error_code(send(&mux, "room.delete", json!({"room": "default"}), Some("room-7"))),
        "operation.failed"
    );
    let deleted = mutate(&mux, "room.delete", json!({"room": room_id}), "room-8");
    assert_eq!(deleted["id"], room_id);
    assert_eq!(read(&mux, "room.list", json!({})).as_array().unwrap().len(), 1);

    let removed =
        mutate(&mux, "workspace_group.delete", json!({"workspace_group": work_id}), "wg-5");
    assert_eq!(removed["ungrouped"][0]["workspace_id"], b);
    let groups = read(&mux, "workspace_group.list", json!({}));
    assert_eq!(groups.as_array().unwrap().len(), 1);
    assert_eq!(
        error_code(send(
            &mux,
            "workspace_group.delete",
            json!({"workspace_group": work_id}),
            Some("wg-6")
        )),
        "resource.not_found"
    );

    let events = changes_after(&mux, before);
    for resource in ["workspace_group", "workspace_placement", "room"] {
        assert!(
            events
                .iter()
                .any(|change| change["kind"] == "state_upsert" && change["resource"] == resource),
            "no {resource} change on session.events"
        );
    }
    assert!(
        events
            .iter()
            .any(|change| change["kind"] == "state_delete" && change["resource"] == "room")
    );
}

#[test]
fn saved_tab_groups_are_personal_and_reopen_after_their_live_group_closes() {
    let mux = Mux::new_for_test("state-saved-groups", SurfaceOptions::default());
    let tabs = terminal_tabs(&mux, 2);
    let ids = tabs.iter().map(|tab| tab_id(&mux, *tab)).collect::<Vec<_>>();
    let group = mutate(
        &mux,
        "tab_group.create",
        json!({"tabs": [ids[1]], "name": "Docs", "color": "green"}),
        "g",
    );
    let group_id = group["id"].as_str().unwrap().to_string();
    let saved = mutate(&mux, "saved_tab_group.save", json!({"tab_group": group_id}), "save");
    let saved_id = saved["id"].as_str().unwrap().to_string();
    assert!(saved_id.starts_with("saved_"));
    assert_eq!(saved["room_id"], "default");
    assert_eq!(saved["members"][0]["kind"], "terminal");
    assert_eq!(
        read(&mux, "tab_group.get", json!({"tab_group": group_id}))["saved_tab_group_id"],
        saved_id
    );
    assert_eq!(
        read(&mux, "saved_tab_group.list", json!({"room": "default"})).as_array().unwrap().len(),
        1
    );
    assert!(
        read(&mux, "saved_tab_group.list", json!({"room": "prof_none"}))
            .as_array()
            .unwrap()
            .is_empty()
    );

    mutate(&mux, "tab_group.close", json!({"tab_group": group_id}), "close");
    let reopened = mutate(
        &mux,
        "saved_tab_group.reopen",
        json!({"saved_tab_group": saved_id, "pane_id": pane_id(&mux, tabs[0])}),
        "reopen",
    );
    assert_eq!(reopened["saved_tab_group_id"], saved_id);
    assert_eq!(reopened["tab_group"]["name"], "Docs");
    assert_eq!(reopened["tab_group"]["saved_tab_group_id"], saved_id);
    let replay = send(
        &mux,
        "saved_tab_group.reopen",
        json!({"saved_tab_group": saved_id, "pane_id": pane_id(&mux, tabs[0])}),
        Some("reopen"),
    )
    .unwrap();
    assert_eq!(replay["replayed"], true);

    let deleted =
        mutate(&mux, "saved_tab_group.delete", json!({"saved_tab_group": saved_id}), "delete");
    assert_eq!(deleted, json!({"id": saved_id, "deleted": true}));
    assert!(read(&mux, "saved_tab_group.list", json!({})).as_array().unwrap().is_empty());
    let live = reopened["tab_group"]["id"].as_str().unwrap();
    assert!(
        read(&mux, "tab_group.get", json!({"tab_group": live}))["saved_tab_group_id"].is_null()
    );
}

#[test]
fn shared_saved_tab_groups_move_to_the_personal_table_once_at_open() {
    let session = Session::new("saved-migration");
    {
        let registry = WorkspaceRegistry::open(&session.root, session.name).unwrap();
        registry
            .read_state(|connection| {
                connection.execute("DELETE FROM meta WHERE key = 'personal_saved_tab_groups_v1'", [])?;
                connection.execute("DELETE FROM personal_saved_tab_groups", [])?;
                connection.execute(
                    "INSERT INTO saved_tab_groups(saved_id, name, color, members_json, position, updated_at_ms)
                     VALUES('saved_legacy', 'Legacy', 'red', '[]', 0, 7)",
                    [],
                )?;
                Ok(())
            })
            .unwrap();
    }
    let mux = session.open();
    let listed = read(&mux, "saved_tab_group.list", json!({}));
    assert_eq!(listed[0]["id"], "saved_legacy");
    assert_eq!(listed[0]["room_id"], "default");
    assert_eq!(listed[0]["updated_at_ms"], "7");
}

#[test]
fn screens_pin_first_move_and_group_contiguously() {
    let mux = Mux::new_for_test("state-screens", SurfaceOptions::default());
    let first = mux.new_workspace(None, None).unwrap().id;
    let workspace = mux.with_state(|state| state.workspaces[state.active_workspace].id);
    for _ in 0..3 {
        mux.new_screen(Some(workspace), None).unwrap();
    }
    let screens = || {
        mux.with_state(|state| {
            let index = state.workspace_index(workspace).unwrap();
            state.workspaces[index]
                .screens
                .iter()
                .map(|screen| screen.public_id.to_string())
                .collect::<Vec<_>>()
        })
    };
    let s = screens();
    assert_eq!(s.len(), 4);
    let _ = first;

    let pinned = mutate(
        &mux,
        "screen.update",
        json!({"screen": s[2], "pinned": true, "color": "red"}),
        "pin",
    );
    assert_eq!(
        (pinned["index"].as_u64(), pinned["extra"]["pinned"].as_bool()),
        (Some(0), Some(true))
    );
    assert_eq!(pinned["extra"]["color"], "red");
    assert_eq!(screens(), vec![s[2].clone(), s[0].clone(), s[1].clone(), s[3].clone()]);
    // An unpinned screen cannot move ahead of the pinned run.
    let moved = mutate(&mux, "screen.move", json!({"screen": s[3], "index": 0}), "move");
    assert_eq!(moved["index"], 1);

    let group = mutate(
        &mux,
        "screen_group.create",
        json!({"screens": [s[0], s[1]], "name": "Agents"}),
        "group",
    );
    let group_id = group["id"].as_str().unwrap().to_string();
    assert!(group_id.starts_with("sgrp_"));
    assert_eq!(group["screen_ids"], json!([s[0], s[1]]));
    assert_eq!(
        error_code(send(
            &mux,
            "screen_group.create",
            json!({"screens": [s[2]]}),
            Some("group-pinned")
        )),
        "validation.invalid"
    );
    let added = mutate(
        &mux,
        "screen_group.add_screens",
        json!({"screen_group": group_id, "screens": [s[3]]}),
        "add",
    );
    assert_eq!(added["screen_ids"], json!([s[0], s[1], s[3]]));
    assert_eq!(screens(), vec![s[2].clone(), s[0].clone(), s[1].clone(), s[3].clone()]);
    let updated = mutate(
        &mux,
        "screen_group.update",
        json!({"screen_group": group_id, "collapsed": true, "color": "cyan"}),
        "update",
    );
    assert_eq!(
        (updated["collapsed"].as_bool(), updated["color"].as_str()),
        (Some(true), Some("cyan"))
    );
    let removed = mutate(&mux, "screen_group.remove_screens", json!({"screens": [s[0]]}), "remove");
    assert_eq!(removed[0]["screen_ids"], json!([s[1], s[3]]));
    assert_eq!(read(&mux, "screen_group.list", json!({})).as_array().unwrap().len(), 1);
    let snapshot = snapshot(&mux);
    let screen =
        snapshot["screens"].as_array().unwrap().iter().find(|value| value["id"] == s[1]).unwrap();
    assert_eq!(screen["extra"]["screen_group_id"], group_id);
    let ungrouped =
        mutate(&mux, "screen_group.ungroup", json!({"screen_group": group_id}), "ungroup");
    assert_eq!(ungrouped["screen_ids"], json!([s[1], s[3]]));
    assert_eq!(
        error_code(send(&mux, "screen_group.get", json!({"screen_group": group_id}), None)),
        "resource.not_found"
    );
}

#[test]
fn raw_screen_commands_and_v2_operations_share_one_storage() {
    let mux = Mux::new_for_test("state-screens-shared", SurfaceOptions::default());
    mux.new_workspace(None, None).unwrap();
    let workspace = mux.with_state(|state| state.workspaces[state.active_workspace].id);
    mux.new_screen(Some(workspace), None).unwrap();
    let (ids, publics) = mux.with_state(|state| {
        let record = &state.workspaces[state.workspace_index(workspace).unwrap()];
        (
            record.screens.iter().map(|screen| screen.id).collect::<Vec<_>>(),
            record.screens.iter().map(|screen| screen.public_id.to_string()).collect::<Vec<_>>(),
        )
    });

    // A raw command publishes the state change v2 readers follow.
    let before = revision(&mux);
    let outcome = mux.create_screen_group(&ids, Some("Raw".into()), Some("blue".into())).unwrap();
    let group = outcome.group.unwrap().id;
    assert!(changes_after(&mux, before).iter().any(|change| {
        change["kind"] == "state_upsert"
            && change["resource"] == "screen_group"
            && change["id"] == group
            && change["value"]["screen_ids"] == json!(publics)
    }));
    assert_eq!(read(&mux, "screen_group.get", json!({"screen_group": group}))["name"], "Raw");

    // A v2 operation writes the rows the raw tree reads.
    mutate(&mux, "screen_group.update", json!({"screen_group": group, "name": "Both"}), "rename");
    mutate(&mux, "screen.update", json!({"screen": publics[1], "color": "red"}), "color");
    let presentation = mux.presentation_snapshot();
    assert_eq!(presentation.screens.groups[&group].name, "Both");
    assert_eq!(
        presentation.screens.screen(&publics[1]).and_then(|record| record.color.clone()),
        Some("red".to_string())
    );
    // A retry with the same key replays without a second commit.
    let replay =
        send(&mux, "screen.update", json!({"screen": publics[1], "color": "red"}), Some("color"))
            .unwrap();
    assert_eq!(replay["replayed"], true);
}

#[test]
fn closed_tabs_and_workspaces_are_recorded_and_reopen() {
    let mux = Mux::new_for_test("state-closed", SurfaceOptions::default());
    let tabs = terminal_tabs(&mux, 2);
    let pane = pane_id(&mux, tabs[0]);
    mux.rename_surface(tabs[1], "logs".into());
    let before = revision(&mux);
    assert!(mux.close_surface(tabs[1]).unwrap());
    let closed = read(&mux, "closed.list", json!({}));
    assert_eq!(closed[0]["kind"], "tab");
    assert_eq!(closed[0]["name"], "logs");
    assert_eq!(closed[0]["pane_id"], pane);
    assert_eq!(closed[0]["screens"][0]["tabs"][0]["kind"], "terminal");
    assert!(
        changes_after(&mux, before)
            .iter()
            .any(|change| change["kind"] == "state_upsert" && change["resource"] == "closed")
    );
    let closed_id = closed[0]["id"].as_str().unwrap().to_string();

    let reopened = mutate(&mux, "closed.reopen", json!({"closed": closed_id}), "reopen");
    assert_eq!(reopened["kind"], "tab");
    let tab = reopened["tab_ids"][0].as_str().unwrap().to_string();
    assert!(pane_tab_ids(&mux, tabs[0]).contains(&tab));
    assert!(read(&mux, "closed.list", json!({})).as_array().unwrap().is_empty());
    assert_eq!(
        send(&mux, "closed.reopen", json!({"closed": closed_id}), Some("reopen")).unwrap()["replayed"],
        true
    );
    assert_eq!(
        error_code(send(&mux, "closed.reopen", json!({"closed": closed_id}), Some("reopen-2"))),
        "resource.not_found"
    );

    let workspace = empty_workspace(&mux, "scratch");
    mutate(&mux, "workspace.close", json!({"workspace": workspace}), "close-scratch");
    let closed = read(&mux, "closed.list", json!({}));
    assert_eq!(closed[0]["kind"], "workspace");
    assert_eq!(closed[0]["name"], "scratch");
    let reopened =
        mutate(&mux, "closed.reopen", json!({"closed": closed[0]["id"]}), "reopen-workspace");
    assert_eq!(reopened["kind"], "workspace");
    let restored = reopened["workspace_id"].as_str().unwrap();
    assert!(
        snapshot(&mux)["workspaces"]
            .as_array()
            .unwrap()
            .iter()
            .any(|value| value["id"] == restored && value["name"] == "scratch")
    );
}

/// Closed history records what a user or client closed, not what ended on
/// its own: an explicit tab close leaves a record, a terminal whose process
/// exited (its tab detaches) leaves none. Follow-up with the host-death
/// branch: a lost host (`TerminalEnd::HostLost`, including signal exits
/// during owner shutdown) keeps its tab and must leave no record either.
#[cfg(unix)]
#[test]
fn closed_history_records_explicit_closes_but_not_process_exits() {
    const TERMINAL: &str = "0000000000004000800000000000c105";
    const INCARNATION: &str = "1000000000004000800000000000c105";
    let mux = Mux::new_for_test("state-closed-exit", SurfaceOptions::default());
    let workspace = mux
        .create_empty_workspace(
            Some("exits".into()),
            Some("018f6e21-7b70-7e70-8000-00000000c105".into()),
            None,
        )
        .unwrap();
    let exited = mux.seed_running_terminal_for_test(TERMINAL, INCARNATION, &workspace.key).unwrap();
    let pane = mux.with_state(|state| state.pane_of(exited).unwrap());
    let closed = mux.new_tab(Some(pane), None, Some((80, 24))).unwrap().id;
    let kept = mux.new_tab(Some(pane), None, Some((80, 24))).unwrap().id;
    let terminal =
        mux.workspace_registry.lock().unwrap().terminal_resource_id(TERMINAL).unwrap().unwrap();
    let exit = crate::terminal_host_protocol::TerminalExit {
        outcome: crate::terminal_host_protocol::TerminalExitOutcome::Exit { code: 0 },
        exited_at_ms: 1_000,
    };
    assert!(mux.persist_terminal_exit_for_test(&terminal, &exit).unwrap());
    mux.surface_exited(exited);
    mux.with_state(|state| assert!(!state.surfaces.contains_key(&exited)));
    assert_eq!(read(&mux, "closed.list", json!({})), json!([]), "a process exit is not a close");

    assert!(mux.close_surface(closed).unwrap());
    let records = read(&mux, "closed.list", json!({}));
    assert_eq!(records.as_array().unwrap().len(), 1, "{records}");
    assert_eq!(records[0]["kind"], "tab");
    mux.with_state(|state| assert!(state.surfaces.contains_key(&kept)));
    mux.shutdown();
}

#[test]
fn closed_history_keeps_the_newest_fifty_items() {
    let mux = Mux::new_for_test("state-closed-bound", SurfaceOptions::default());
    for index in 0..52 {
        let workspace = empty_workspace(&mux, &format!("w{index}"));
        mutate(&mux, "workspace.close", json!({"workspace": workspace}), &format!("close-{index}"));
    }
    let closed = read(&mux, "closed.list", json!({}));
    assert_eq!(closed.as_array().unwrap().len(), 50);
    assert_eq!(closed[0]["name"], "w51");
    assert_eq!(closed[49]["name"], "w2");
}

#[test]
fn ephemeral_workspaces_are_flagged_unrecorded_and_closed_at_the_next_start() {
    let session = Session::new("ephemeral");
    let mux = session.open();
    let kept = empty_workspace(&mux, "kept");
    let created = mutate(
        &mux,
        "workspace.create",
        json!({"name": "incognito", "initial_content": "empty", "ephemeral": true}),
        "create-ephemeral",
    );
    let ephemeral = created["workspace_id"].as_str().unwrap().to_string();
    let listed = snapshot(&mux)["workspaces"].as_array().unwrap().clone();
    let value = listed.iter().find(|value| value["id"] == ephemeral).unwrap();
    assert_eq!(value["extra"]["ephemeral"], true);
    assert!(
        listed.iter().find(|value| value["id"] == kept).unwrap()["extra"]
            .get("ephemeral")
            .is_none()
    );
    // A replay repeats the mark idempotently.
    let replay = send(
        &mux,
        "workspace.create",
        json!({"name": "incognito", "initial_content": "empty", "ephemeral": true}),
        Some("create-ephemeral"),
    )
    .unwrap();
    assert_eq!(replay["replayed"], true);
    drop(mux);

    let mux = session.open();
    let workspaces = snapshot(&mux)["workspaces"].as_array().unwrap().clone();
    assert!(workspaces.iter().any(|value| value["id"] == kept));
    assert!(!workspaces.iter().any(|value| value["id"] == ephemeral));
    // Incognito content leaves no closed-history record.
    assert!(read(&mux, "closed.list", json!({})).as_array().unwrap().is_empty());
}

/// `workspace.create {ephemeral: true}` commits the workspace and its flag
/// in one transaction on both creation paths: no committed read and no
/// `session.events` change ever shows the workspace without the flag.
#[test]
fn ephemeral_workspace_create_commits_the_flag_with_the_workspace() {
    let mux = Mux::new_for_test("state-ephemeral-atomic", SurfaceOptions::default());
    let done = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let reader = {
        let mux = Arc::clone(&mux);
        let done = Arc::clone(&done);
        std::thread::spawn(move || {
            let mut observed = 0usize;
            loop {
                let finished = done.load(std::sync::atomic::Ordering::Acquire);
                for value in snapshot(&mux)["workspaces"].as_array().unwrap() {
                    if value["name"].as_str().is_some_and(|name| name.starts_with("incognito-")) {
                        assert_eq!(
                            value["extra"]["ephemeral"], true,
                            "read without the flag: {value}"
                        );
                        observed += 1;
                    }
                }
                if finished {
                    return observed;
                }
            }
        })
    };
    let before = revision(&mux);
    let mut created = Vec::new();
    for index in 0..6 {
        let content = if index % 2 == 0 { "empty" } else { "terminal" };
        let value = mutate(
            &mux,
            "workspace.create",
            json!({"name": format!("incognito-{index}"), "initial_content": content, "ephemeral": true}),
            &format!("atomic-ephemeral-{index}"),
        );
        created.push(value["workspace_id"].as_str().unwrap().to_string());
    }
    done.store(true, std::sync::atomic::Ordering::Release);
    assert!(reader.join().unwrap() > 0, "the reader saw no created workspace");

    let changes = changes_after(&mux, before);
    for workspace in &created {
        let upserts = changes
            .iter()
            .filter(|change| {
                change["kind"] == "upsert"
                    && change["resource"] == "workspace"
                    && change["id"] == workspace.as_str()
            })
            .collect::<Vec<_>>();
        assert!(!upserts.is_empty(), "no upsert for {workspace}");
        for upsert in upserts {
            assert_eq!(
                upsert["value"]["extra"]["ephemeral"], true,
                "event without the flag: {upsert}"
            );
        }
    }
    // The flag is part of the request: the same key without it is a different request.
    let retried = send(
        &mux,
        "workspace.create",
        json!({"name": "incognito-0", "initial_content": "empty"}),
        Some("atomic-ephemeral-0"),
    );
    assert!(retried.is_err(), "a retry that drops the flag replayed: {retried:?}");
    mux.shutdown();
}

/// Window records have one writer each: puts and deletes compare the
/// record's own revision, publish `state_upsert`/`state_delete`, replay by
/// key, and never touch another window's record.
#[test]
fn window_records_compare_and_swap_per_record_and_publish_their_changes() {
    let mux = Mux::new_for_test("state-window-records", SurfaceOptions::default());
    let before = revision(&mux);
    let put = |key: &str, install: &str, window: &str, record: Value, expected: Option<&str>| {
        let mut params = json!({"install_id": install, "window_id": window, "record": record});
        if let Some(expected) = expected {
            params["expected_revision"] = json!(expected);
        }
        send(&mux, "window_record.put", params, Some(key))
    };
    let first =
        put("w-1", "install_a", "win_1", json!({"workspace_key": "k1"}), Some("0")).unwrap();
    assert_eq!(first["replayed"], false);
    assert_eq!(first["value"]["owner"], "install_a");
    assert_eq!(first["value"]["revision"], "1");
    assert_eq!(first["value"]["record"]["workspace_key"], "k1");
    // A second window of the same install and a window of another install
    // are independent records.
    put("w-2", "install_a", "win_2", json!({"workspace_key": "k2"}), None).unwrap();
    put("b-1", "install_b", "win_1", json!({"workspace_key": "k3"}), Some("0")).unwrap();
    // A stale revision is a conflict and writes nothing.
    let stale = put("w-3", "install_a", "win_1", json!({"workspace_key": "lost"}), Some("0"));
    assert_eq!(error_code(stale), "revision.conflict");
    let second =
        put("w-4", "install_a", "win_1", json!({"workspace_key": "k4"}), Some("1")).unwrap();
    assert_eq!(second["value"]["revision"], "2");
    // The same key replays without writing again.
    let replay =
        put("w-4", "install_a", "win_1", json!({"workspace_key": "k4"}), Some("1")).unwrap();
    assert_eq!(replay["replayed"], true);
    let listed = read(&mux, "window_record.list", json!({}));
    let ids = listed
        .as_array()
        .unwrap()
        .iter()
        .map(|record| record["id"].as_str().unwrap().to_string())
        .collect::<Vec<_>>();
    assert_eq!(ids, ["install_a/win_1", "install_a/win_2", "install_b/win_1"]);
    assert_eq!(listed[0]["record"]["workspace_key"], "k4");
    assert_eq!(listed[2]["record"]["workspace_key"], "k3");
    // The reserved placeholder install cannot write, and records must be objects.
    assert_eq!(
        error_code(put("p-1", "install_unadopted", "win_9", json!({}), None)),
        "validation.invalid"
    );
    assert_eq!(
        error_code(put("p-2", "install_a", "win_9", json!([1]), None)),
        "validation.invalid"
    );

    let delete = |key: &str, install: &str, window: &str, expected: &str| {
        send(
            &mux,
            "window_record.delete",
            json!({"install_id": install, "window_id": window, "expected_revision": expected}),
            Some(key),
        )
    };
    assert_eq!(error_code(delete("d-1", "install_a", "win_1", "1")), "revision.conflict");
    let deleted = delete("d-2", "install_a", "win_1", "2").unwrap();
    assert_eq!(deleted["value"]["id"], "install_a/win_1");
    assert_eq!(error_code(delete("d-3", "install_a", "win_1", "2")), "resource.not_found");
    assert_eq!(read(&mux, "window_record.list", json!({})).as_array().unwrap().len(), 2);

    let changes = changes_after(&mux, before)
        .into_iter()
        .filter(|change| change["resource"] == "window_record")
        .map(|change| {
            (
                change["kind"].as_str().unwrap().to_string(),
                change["id"].as_str().unwrap().to_string(),
            )
        })
        .collect::<Vec<_>>();
    assert_eq!(
        changes,
        [
            ("state_upsert".to_string(), "install_a/win_1".to_string()),
            ("state_upsert".to_string(), "install_a/win_2".to_string()),
            ("state_upsert".to_string(), "install_b/win_1".to_string()),
            ("state_upsert".to_string(), "install_a/win_1".to_string()),
            ("state_delete".to_string(), "install_a/win_1".to_string()),
        ]
    );
    assert_eq!(snapshot(&mux)["extra"]["state"]["window_records"].as_array().unwrap().len(), 2);
}

/// The `windows` frontend projection becomes unadopted records once; the
/// first put of a window adopts its record, and the projection keeps
/// working for older apps.
#[test]
fn window_projection_migrates_to_unadopted_records_that_the_app_adopts() {
    let session = Session::new("window-records-migration");
    let mux = session.open();
    let document = json!({
        "windows": [
            {"id": "w1", "workspace_key": "k1", "order": 0},
            {"id": "w2", "workspace_key": "k2", "order": 1},
            {"workspace_key": "no-id"},
        ],
        "collapsed_groups": {},
    });
    mux.put_frontend_projection(
        &WorkspaceMutation::new("seed-windows", "cmux-next").unwrap(),
        "cmux-next",
        "personal",
        "windows",
        1,
        None,
        &document,
    )
    .unwrap();
    // A registry from before window records: no migration flag yet.
    mux.read_registry_state(|connection| {
        connection.execute("DELETE FROM meta WHERE key = 'window_records_v1'", [])?;
        Ok(())
    })
    .unwrap();
    drop(mux);

    let mux = session.open();
    let listed = read(&mux, "window_record.list", json!({}));
    let listed = listed.as_array().unwrap();
    assert_eq!(listed.len(), 2);
    assert_eq!(listed[0]["id"], "install_unadopted/w1");
    assert_eq!(listed[0]["owner"], "install_unadopted");
    assert_eq!(listed[0]["revision"], "1");
    assert_eq!(listed[0]["record"]["workspace_key"], "k1");

    let before = revision(&mux);
    let adopted = send(
        &mux,
        "window_record.put",
        json!({"install_id": "install_mac", "window_id": "w1", "record": {"workspace_key": "k1b"}, "expected_revision": "1"}),
        Some("adopt-w1"),
    )
    .unwrap();
    assert_eq!(adopted["value"]["id"], "install_mac/w1");
    assert_eq!(adopted["value"]["owner"], "install_mac");
    assert_eq!(adopted["value"]["revision"], "2");
    let changes = changes_after(&mux, before)
        .into_iter()
        .map(|change| {
            (
                change["kind"].as_str().unwrap().to_string(),
                change["id"].as_str().unwrap().to_string(),
            )
        })
        .collect::<Vec<_>>();
    assert_eq!(
        changes,
        [
            ("state_delete".to_string(), "install_unadopted/w1".to_string()),
            ("state_upsert".to_string(), "install_mac/w1".to_string()),
        ]
    );
    // An unadopted record the app does not want is deleted.
    send(
        &mux,
        "window_record.delete",
        json!({"install_id": "install_unadopted", "window_id": "w2"}),
        Some("drop-w2"),
    )
    .unwrap();
    let ids = read(&mux, "window_record.list", json!({}))
        .as_array()
        .unwrap()
        .iter()
        .map(|record| record["id"].as_str().unwrap().to_string())
        .collect::<Vec<_>>();
    assert_eq!(ids, ["install_mac/w1"]);
    // Older apps still read and write the projection.
    let projection =
        mux.get_frontend_projection("cmux-next", "personal", "windows").unwrap().unwrap();
    assert_eq!(projection.projection, document);
    drop(mux);
    // The migration runs once: a reopen does not bring w2 back.
    let mux = session.open();
    assert_eq!(read(&mux, "window_record.list", json!({})).as_array().unwrap().len(), 1);
}

/// A frontend browser record carries the install id of the app that hosts
/// it: set at creation or by `tab.update {owner}`, shown as `extra.owner`
/// on the tab snapshot and its `session.events` restatement, and refused on
/// a tab that is not frontend-rendered.
#[test]
fn frontend_browser_owner_is_set_by_the_app_and_shown_on_the_tab() {
    let mux = Mux::new_for_test("state-browser-owner", SurfaceOptions::default());
    let terminal = mux.new_workspace(None, None).unwrap().id;
    let pane = mux.with_state(|state| state.pane_of(terminal)).unwrap();
    let browser = mux
        .new_frontend_browser_tab(
            Some(pane),
            crate::workspace_registry::FrontendBrowserRecord {
                engine: "cef".into(),
                url: "https://example.com/".into(),
                title: None,
                favicon_url: None,
                profile_id: None,
                owner: Some("install_mac_a".into()),
            },
            None,
        )
        .unwrap();
    let browser_tab = tab_id(&mux, browser.id);
    let terminal_tab = tab_id(&mux, terminal);
    let tab_extra = |tab: &str| {
        snapshot(&mux)["tabs"].as_array().unwrap().iter().find(|value| value["id"] == tab).unwrap()
            ["extra"]
            .clone()
    };
    assert_eq!(tab_extra(&browser_tab)["owner"], "install_mac_a");
    assert!(tab_extra(&terminal_tab).get("owner").is_none());

    let before = revision(&mux);
    let updated = mutate(
        &mux,
        "tab.update",
        json!({"tab": browser_tab, "owner": "install_mac_b"}),
        "owner-b",
    );
    assert_eq!(updated["id"], browser_tab);
    assert_eq!(tab_extra(&browser_tab)["owner"], "install_mac_b");
    assert!(changes_after(&mux, before).iter().any(|change| {
        change["kind"] == "upsert"
            && change["resource"] == "tab"
            && change["id"] == browser_tab.as_str()
            && change["value"]["extra"]["owner"] == "install_mac_b"
    }));
    assert_eq!(mux.frontend_browser(&browser).unwrap().owner.as_deref(), Some("install_mac_b"));
    // The app's raw record write restates the tab too (invariant 4).
    let before = revision(&mux);
    let (record, changed) = mux
        .update_frontend_browser_tab_with_owner(
            browser.id,
            None,
            None,
            None,
            Some("install_mac_c".into()),
        )
        .unwrap();
    assert!(changed);
    assert_eq!(record.owner.as_deref(), Some("install_mac_c"));
    assert_eq!(tab_extra(&browser_tab)["owner"], "install_mac_c");
    assert!(changes_after(&mux, before).iter().any(|change| {
        change["resource"] == "tab"
            && change["id"] == browser_tab.as_str()
            && change["value"]["extra"]["owner"] == "install_mac_c"
    }));
    assert_eq!(
        error_code(send(
            &mux,
            "tab.update",
            json!({"tab": terminal_tab, "owner": "install_mac_b"}),
            Some("owner-terminal")
        )),
        "validation.invalid"
    );
    assert_eq!(
        error_code(send(
            &mux,
            "tab.update",
            json!({"tab": browser_tab, "owner": "bad/owner"}),
            Some("owner-invalid")
        )),
        "validation.invalid"
    );
}

/// Keep-layout records commit on the state path: the tab snapshot's
/// `extra.relaunch` and the `session.events` restatement agree (invariant
/// 4), and forgetting a record restates the tab with `relaunch: null`.
#[test]
fn kept_tabs_restate_relaunch_on_the_snapshot_and_the_event_stream() {
    let mux = Mux::new_for_test("state-kept-tabs", SurfaceOptions::default());
    let tabs = terminal_tabs(&mux, 2);
    let kept = tab_id(&mux, tabs[0]);
    let other = tab_id(&mux, tabs[1]);
    let relaunch = |tab: &str| {
        snapshot(&mux)["tabs"].as_array().unwrap().iter().find(|value| value["id"] == tab).unwrap()
            ["extra"]["relaunch"]
            .clone()
    };
    assert_eq!(relaunch(&kept), Value::Null);

    let before = revision(&mux);
    mux.commit_kept_tabs(&[(kept.clone(), Some("/tmp/project".into()))]).unwrap();
    assert!(revision(&mux) > before, "a keep-layout record advances the resource revision");
    assert_eq!(relaunch(&kept), json!({"cwd": "/tmp/project"}));
    assert_eq!(relaunch(&other), Value::Null);
    let restated = changes_after(&mux, before)
        .into_iter()
        .filter(|change| change["kind"] == "upsert" && change["resource"] == "tab")
        .collect::<Vec<_>>();
    assert_eq!(restated.len(), 1, "{restated:?}");
    assert_eq!(restated[0]["id"], kept.as_str());
    assert_eq!(restated[0]["value"]["extra"]["relaunch"], json!({"cwd": "/tmp/project"}));

    let before = revision(&mux);
    mux.forget_kept_tabs(std::slice::from_ref(&kept)).unwrap();
    assert_eq!(relaunch(&kept), Value::Null);
    let restated = changes_after(&mux, before)
        .into_iter()
        .filter(|change| change["kind"] == "upsert" && change["resource"] == "tab")
        .collect::<Vec<_>>();
    assert_eq!(restated.len(), 1);
    assert!(restated[0]["value"]["extra"].get("relaunch").is_none());
    // Forgetting a tab with no record commits nothing.
    let before = revision(&mux);
    mux.forget_kept_tabs(std::slice::from_ref(&other)).unwrap();
    assert!(changes_after(&mux, before).iter().all(|change| change["resource"] != "tab"));
    mux.shutdown();
}

#[test]
fn workspace_status_progress_and_bounded_log() {
    let mux = Mux::new_for_test("state-status", SurfaceOptions::default());
    let workspace = empty_workspace(&mux, "status");
    let before = revision(&mux);
    let set = mutate(
        &mux,
        "workspace_status.set",
        json!({"workspace": workspace, "key": "build", "text": "compiling", "icon": "hammer"}),
        "s1",
    );
    assert_eq!(set["entries"][0]["key"], "build");
    assert_eq!(set["entries"][0]["icon"], "hammer");
    mutate(
        &mux,
        "workspace_status.set",
        json!({"workspace": workspace, "key": "tests", "text": "queued"}),
        "s2",
    );
    let replaced = mutate(
        &mux,
        "workspace_status.set",
        json!({"workspace": workspace, "key": "build", "text": "done"}),
        "s3",
    );
    assert_eq!(replaced["entries"][0]["text"], "done");
    assert_eq!(replaced["entries"][1]["key"], "tests");
    let progress = mutate(
        &mux,
        "workspace_progress.set",
        json!({"workspace": workspace, "value": 0.25, "label": "step 1"}),
        "p1",
    );
    assert_eq!(progress["progress"]["value"], 0.25);
    let indeterminate = mutate(
        &mux,
        "workspace_progress.set",
        json!({"workspace": workspace, "value": null}),
        "p2",
    );
    assert!(indeterminate["progress"]["value"].is_null());
    assert_eq!(
        error_code(send(
            &mux,
            "workspace_progress.set",
            json!({"workspace": workspace, "value": 1.5}),
            Some("p3")
        )),
        "validation.invalid"
    );

    for index in 0..201 {
        mutate(
            &mux,
            "workspace_log.append",
            json!({"workspace": workspace, "text": format!("line {index}")}),
            &format!("log-{index}"),
        );
    }
    let lines = read(&mux, "workspace_log.list", json!({"workspace": workspace}));
    assert_eq!(lines.as_array().unwrap().len(), 200);
    assert_eq!(lines[0]["text"], "line 1");
    assert_eq!(lines[199]["text"], "line 200");
    assert_eq!(
        read(&mux, "workspace_log.list", json!({"workspace": workspace, "limit": 2}))[1]["text"],
        "line 200"
    );
    let listed = read(&mux, "workspace_status.list", json!({}));
    assert_eq!(listed[0]["log_count"], 200);
    assert_eq!(listed[0]["last_log"]["level"], "info");
    assert!(
        changes_after(&mux, before)
            .iter()
            .any(|change| change["kind"] == "state_upsert"
                && change["resource"] == "workspace_status")
    );

    let cleared = mutate(
        &mux,
        "workspace_status.clear",
        json!({"workspace": workspace, "key": "build"}),
        "c1",
    );
    assert_eq!(cleared["entries"].as_array().unwrap().len(), 1);
    let cleared = mutate(&mux, "workspace_progress.clear", json!({"workspace": workspace}), "c2");
    assert!(cleared["progress"].is_null());
    let cleared = mutate(&mux, "workspace_log.clear", json!({"workspace": workspace}), "c3");
    assert_eq!(cleared["log_count"], 0);
    let cleared = mutate(&mux, "workspace_status.clear", json!({"workspace": workspace}), "c4");
    assert!(cleared["entries"].as_array().unwrap().is_empty());
    assert!(read(&mux, "workspace_status.list", json!({})).as_array().unwrap().is_empty());
}

#[test]
fn raw_metadata_and_pin_commands_publish_the_same_state_on_session_events() {
    let mux = Mux::new_for_test("state-raw-paths", SurfaceOptions::default());
    let workspace = empty_workspace(&mux, "raw");
    let slot = mux.with_state(|state| {
        state
            .workspaces
            .iter()
            .find(|candidate| candidate.public_id.as_str() == workspace)
            .unwrap()
            .id
    });
    let before = revision(&mux);
    mux.set_workspace_metadata(
        Some(slot),
        None,
        WorkspacePresentationUpdate {
            color: Some(Some("red".into())),
            ..WorkspacePresentationUpdate::default()
        },
        None,
        None,
        &WorkspaceMutation::local("state-test"),
    )
    .unwrap();
    assert!(changes_after(&mux, before).iter().any(|change| {
        change["resource"] == "workspace"
            && change["id"] == workspace
            && change["value"]["extra"]["color"] == "red"
    }));

    let tabs = terminal_tabs(&mux, 2);
    let second = tab_id(&mux, tabs[1]);
    let before = revision(&mux);
    let change = mux.set_tab_pinned(tabs[1], true).unwrap();
    assert_eq!(change, TabPinChange { changed: true, index: 0 });
    assert!(changes_after(&mux, before).iter().any(|change| {
        change["resource"] == "tab"
            && change["id"] == second
            && change["value"]["extra"]["pinned"] == true
    }));
}
