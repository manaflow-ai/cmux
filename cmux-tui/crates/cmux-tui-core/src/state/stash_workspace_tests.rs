//! Whole workspaces in a stash (`stash-workspaces-v1`): `stash.create
//! {workspaces}` closes them with every tab, terminals included, into one
//! stash instead of Recently Closed; `stash.restore` reopens each as its own
//! workspace with its tabs, name and group. Driven through `cmux.protocol/2`.

use serde_json::json;

use super::tests::{Session, error_code, mutate, read, send};
use crate::mux::*;
use crate::state::commit::StateEffects;
use crate::state::prelude::*;
use crate::state::store::StateChanges;
use crate::workspace_registry::{FrontendBrowserRecord, WorkspaceMutation};

fn browser_in(mux: &Arc<Mux>, pane: PaneId, url: &str, title: &str) -> SurfaceId {
    let record = FrontendBrowserRecord {
        engine: "cef".into(),
        url: url.into(),
        title: Some(title.into()),
        favicon_url: None,
        profile_id: None,
        owner: None,
    };
    mux.new_frontend_browser_tab(Some(pane), record, None).unwrap().id
}

/// A workspace named `name` with its shell and one web page; its public id.
fn workspace_with_page(mux: &Arc<Mux>, name: &str, url: &str) -> String {
    let shell = mux.new_workspace(Some(name.into()), None).unwrap().id;
    let pane = mux.with_state(|state| state.pane_of(shell)).unwrap();
    browser_in(mux, pane, url, &format!("{name} page"));
    mux.with_state(|state| {
        let (workspace, _) = state.screen_of(pane).unwrap();
        state.workspaces[workspace].public_id.to_string()
    })
}

fn live_workspaces(mux: &Arc<Mux>) -> Vec<String> {
    mux.with_state(|state| {
        state.workspaces.iter().map(|workspace| workspace.public_id.to_string()).collect()
    })
}

/// The live workspace `id`: its name and its tabs' (kind, url).
fn workspace_tabs(mux: &Arc<Mux>, id: &str) -> (String, Vec<(String, Option<String>)>) {
    let name = mux.with_state(|state| {
        state.workspaces.iter().find(|item| item.public_id.as_str() == id).unwrap().name.clone()
    });
    let tabs = mux
        .read_registry_state(|connection| {
            let mut statement = connection.prepare(
                "SELECT t.content_kind, f.url FROM resource_tabs AS t
                 JOIN resource_panes AS p ON p.public_id = t.pane_id
                 JOIN resource_screens AS s ON s.public_id = p.screen_id
                 LEFT JOIN frontend_browser_tabs AS f ON f.browser_id = t.content_id
                 WHERE s.workspace_id = ?1 AND t.deleted_revision IS NULL
                 ORDER BY s.position, p.creation_ordinal, t.position",
            )?;
            Ok(statement
                .query_map([id], |row| Ok((row.get(0)?, row.get(1)?)))?
                .collect::<Result<Vec<_>, _>>()?)
        })
        .unwrap();
    (name, tabs)
}

/// The group of live workspace `id` in the personal sidebar order.
fn group_of(mux: &Arc<Mux>, id: &str) -> Option<String> {
    read(mux, "workspace.placement.list", json!({}))
        .as_array()
        .unwrap()
        .iter()
        .find(|placement| placement["workspace"]["workspace_id"] == id)
        .and_then(|placement| placement["group_id"].as_str().map(str::to_string))
}

fn stashes(mux: &Arc<Mux>) -> Vec<Value> {
    read(mux, "stash.list", json!({})).as_array().unwrap().clone()
}

#[test]
fn a_stashed_workspace_closes_whole_and_comes_back_with_its_tabs_name_and_group() {
    let session = Session::new("stash-whole-workspace");
    let mux = session.open();
    let kept = workspace_with_page(&mux, "Kept", "https://kept.example/");
    let build = workspace_with_page(&mux, "Build", "https://example.com/build");
    let group =
        mutate(&mux, "workspace_group.create", json!({"name": "Work"}), "group")["id"].clone();
    mutate(&mux, "workspace.place", json!({"workspace": build, "group": group}), "place");

    let created = mutate(&mux, "stash.create", json!({"workspaces": [build]}), "stash");
    assert_eq!(created["workspace_ids"], json!([build]));
    assert_eq!(created["tab_ids"].as_array().unwrap().len(), 2, "{created}");
    assert!(!live_workspaces(&mux).contains(&build), "the workspace closed whole");
    assert!(live_workspaces(&mux).contains(&kept));
    assert!(
        read(&mux, "closed.list", json!({})).as_array().unwrap().is_empty(),
        "a stashed workspace is not in Recently Closed"
    );

    let listed = stashes(&mux);
    assert_eq!(listed.len(), 1, "{listed:?}");
    assert_eq!(listed[0]["name"], "Build");
    let member = &listed[0]["members"][0];
    assert_eq!(member["kind"], "workspace", "{member}");
    assert_eq!(member["name"], "Build");
    assert_eq!(member["url"], Value::Null);
    assert_eq!(member["tab_count"], 2);
    assert_eq!(member["tabs"][0]["kind"], "terminal", "{member}");
    assert_eq!(member["tabs"][0]["url"], Value::Null);
    assert_eq!(member["tabs"][1]["kind"], "browser");
    assert_eq!(member["tabs"][1]["url"], "https://example.com/build");
    assert_eq!(member["tabs"][1]["title"], "Build page");
    assert!(!listed[0].to_string().contains("screens"), "no raw record: {}", listed[0]);

    let replay = send(&mux, "stash.create", json!({"workspaces": [build]}), Some("stash")).unwrap();
    assert_eq!(replay["replayed"], true);
    assert_eq!(stashes(&mux).len(), 1, "a replay stashes nothing twice");

    let restored = mutate(&mux, "stash.restore", json!({"stash": created["stash_id"]}), "restore");
    let reopened = restored["workspace_ids"].as_array().unwrap();
    assert_eq!(reopened.len(), 1, "{restored}");
    let id = reopened[0].as_str().unwrap().to_string();
    assert!(live_workspaces(&mux).contains(&id));
    let (name, tabs) = workspace_tabs(&mux, &id);
    assert_eq!(name, "Build");
    assert_eq!(
        tabs,
        [
            ("terminal".to_string(), None),
            ("browser".to_string(), Some("https://example.com/build".to_string()))
        ],
        "its terminal and its page came back"
    );
    assert_eq!(group_of(&mux, &id), group.as_str().map(str::to_string), "it is back in its group");
    assert!(stashes(&mux).is_empty());
    assert!(read(&mux, "closed.list", json!({})).as_array().unwrap().is_empty());
    mux.shutdown();
}

#[test]
fn several_workspaces_make_one_named_stash_and_members_restore_or_delete_one_at_a_time() {
    let session = Session::new("stash-workspaces-many");
    let mux = session.open();
    workspace_with_page(&mux, "Kept", "https://kept.example/");
    let one = workspace_with_page(&mux, "One", "https://one.example/");
    let two = workspace_with_page(&mux, "Two", "https://two.example/");

    let created = mutate(
        &mux,
        "stash.create",
        json!({"workspaces": [one, two, one], "name": "  Evening  "}),
        "stash",
    );
    assert_eq!(created["workspace_ids"], json!([one, two]), "each workspace once");
    let listed = stashes(&mux);
    assert_eq!(listed[0]["name"], "Evening", "the name is trimmed");
    let members = listed[0]["members"].as_array().unwrap();
    assert_eq!(
        members.iter().map(|member| member["name"].clone()).collect::<Vec<_>>(),
        [json!("One"), json!("Two")]
    );
    let stash = created["stash_id"].clone();

    mutate(&mux, "stash.delete", json!({"stash": stash, "members": [members[0]["id"]]}), "delete");
    let listed = stashes(&mux);
    assert_eq!(listed[0]["members"].as_array().unwrap().len(), 1);
    assert_eq!(listed[0]["members"][0]["name"], "Two");

    let before = live_workspaces(&mux).len();
    let restored = mutate(
        &mux,
        "stash.restore",
        json!({"stash": stash, "target": "new_workspace"}),
        "restore",
    );
    assert_eq!(restored["workspace_ids"].as_array().unwrap().len(), 1, "{restored}");
    assert_eq!(live_workspaces(&mux).len(), before + 1, "no extra workspace for no pages");
    let (name, _) = workspace_tabs(&mux, restored["workspace_ids"][0].as_str().unwrap());
    assert_eq!(name, "Two");
    assert!(stashes(&mux).is_empty());

    // Two unnamed workspaces leave the stash unnamed.
    let three = workspace_with_page(&mux, "Three", "https://three.example/");
    let four = workspace_with_page(&mux, "Four", "https://four.example/");
    mutate(&mux, "stash.create", json!({"workspaces": [three, four]}), "stash-2");
    assert_eq!(stashes(&mux)[0]["name"], Value::Null);
    mux.shutdown();
}

#[test]
fn a_whole_workspace_stash_refuses_bad_requests_and_closes_nothing() {
    let session = Session::new("stash-workspaces-refusals");
    let mux = session.open();
    let open = workspace_with_page(&mux, "Open", "https://open.example/");
    let private = mutate(
        &mux,
        "workspace.create",
        json!({"name": "incognito", "initial_content": "terminal", "ephemeral": true}),
        "create-ephemeral",
    )["workspace_id"]
        .as_str()
        .unwrap()
        .to_string();
    let cases = [
        (json!({"workspaces": [open, private]}), "incognito"),
        (json!({"workspaces": []}), "empty"),
        (json!({"workspaces": [open], "workspace": open}), "workspace too"),
        (json!({"workspaces": [open], "name": "   "}), "blank name"),
        (json!({"workspaces": [open], "name": "x".repeat(1025)}), "long name"),
        (json!({"workspace": open, "name": "n"}), "name without workspaces"),
    ];
    for (index, (params, why)) in cases.into_iter().enumerate() {
        let refused = send(&mux, "stash.create", params, Some(&format!("bad-{index}")));
        assert_eq!(error_code(refused), "validation.invalid", "{why}");
    }
    let unknown = send(
        &mux,
        "stash.create",
        json!({"workspaces": ["ws_00000000000000000000000000"]}),
        Some("unknown"),
    );
    assert!(unknown.is_err(), "an unknown workspace is refused");
    assert!(live_workspaces(&mux).contains(&open), "a refused stash closes nothing");
    assert!(live_workspaces(&mux).contains(&private));
    assert!(stashes(&mux).is_empty());
    mux.shutdown();
}

/// Make the page of member `index` of `stash` fail to reopen (a
/// conversation record it cannot parse), or reopen again with `broken` false.
fn set_broken(mux: &Arc<Mux>, stash: &str, index: usize, broken: bool, key: &str) {
    let path = format!("$.members[{index}].screens[0].tabs[1].conversation");
    let mutation = WorkspaceMutation::new(key, "test", crate::Actor::local_user()).unwrap();
    mux.commit_state(&mutation, "test.stash", &json!({"key": key}), None, StateEffects::EVENTS_ONLY, |transaction, _| {
        let sql = if broken {
            "UPDATE stashed_groups SET record_json = json_set(record_json, ?1, json('{\"bad\":1}')) WHERE stash_id = ?2"
        } else {
            "UPDATE stashed_groups SET record_json = json_remove(record_json, ?1) WHERE stash_id = ?2"
        };
        transaction.execute(sql, rusqlite::params![path, stash])?;
        Ok(StateChanges::new(json!({}), Vec::new()))
    })
    .unwrap();
}

fn counts(mux: &Arc<Mux>) -> (usize, usize) {
    mux.with_state(|state| (state.resource_indexes.tab_ids.len(), state.workspaces.len()))
}

#[test]
fn a_whole_workspace_restore_that_fails_partway_opens_nothing_and_keeps_every_member() {
    let session = Session::new("stash-workspaces-atomic");
    let mux = session.open();
    workspace_with_page(&mux, "Kept", "https://kept.example/");
    let one = workspace_with_page(&mux, "One", "https://one.example/");
    let two = workspace_with_page(&mux, "Two", "https://two.example/");
    let created = mutate(&mux, "stash.create", json!({"workspaces": [one, two]}), "stash");
    let stash = created["stash_id"].as_str().unwrap().to_string();
    set_broken(&mux, &stash, 1, true, "break");
    let before = counts(&mux);

    for (target, key) in [("here", "restore-here"), ("new_workspace", "restore-new")] {
        let failed =
            send(&mux, "stash.restore", json!({"stash": stash, "target": target}), Some(key));
        assert!(failed.is_err(), "{target}: the broken member fails the restore");
        assert_eq!(counts(&mux), before, "{target}: the workspaces it opened closed again");
        assert_eq!(stashes(&mux)[0]["members"].as_array().unwrap().len(), 2, "{target}");
    }
    assert!(
        read(&mux, "closed.list", json!({})).as_array().unwrap().is_empty(),
        "a rolled-back restore leaves nothing in Recently Closed"
    );

    set_broken(&mux, &stash, 1, false, "fix");
    let restored = mutate(&mux, "stash.restore", json!({"stash": stash}), "restore-again");
    assert_eq!(restored["workspace_ids"].as_array().unwrap().len(), 2, "{restored}");
    assert_eq!(counts(&mux), (before.0 + 4, before.1 + 2), "each workspace once, whole");
    assert!(stashes(&mux).is_empty());
    mux.shutdown();
}
