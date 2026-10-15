//! Stash members (`stash-v1`, bead cx-rws36): named by stable ids so a
//! request made from an older listing never hits the wrong page, restored
//! `here` into the pane the user acted from when their own pane is gone,
//! and only ever web pages (never app tabs).

use std::collections::HashSet;

use serde_json::json;

use super::tests::{error_code, mutate, pane_id, pane_tab_ids, read, send, tab_id};
use crate::mux::*;
use crate::state::prelude::*;
use crate::surface::SurfaceOptions;
use crate::workspace_registry::FrontendBrowserRecord;

fn browser_in(mux: &Arc<Mux>, pane: PaneId, url: &str) -> SurfaceId {
    let record = FrontendBrowserRecord {
        engine: "cef".into(),
        url: url.into(),
        title: None,
        favicon_url: None,
        profile_id: None,
        owner: None,
    };
    mux.new_frontend_browser_tab(Some(pane), record, None).unwrap().id
}

fn member_urls(group: &Value) -> Vec<String> {
    group["members"]
        .as_array()
        .unwrap()
        .iter()
        .map(|member| member["url"].as_str().unwrap().to_string())
        .collect()
}

fn surface_of(mux: &Arc<Mux>, tab: &str) -> SurfaceId {
    mux.with_state(|state| {
        state
            .resource_indexes
            .tab_ids
            .iter()
            .find(|(_, public)| public.to_string() == tab)
            .map(|(surface, _)| *surface)
    })
    .expect("a surface shows the tab")
}

fn import(mux: &Arc<Mux>, urls: &[&str], key: &str) -> String {
    let tabs = urls.iter().map(|url| json!({"url": url})).collect::<Vec<_>>();
    let imported =
        mutate(mux, "stash.import", json!({"source": "onetab", "groups": [{"tabs": tabs}]}), key);
    imported["stash_ids"][0].as_str().unwrap().to_string()
}

/// The page of group [a, b, c, d]: delete b, then (from the same listing)
/// c. The second delete drops c, not d, and a gone id changes nothing.
#[test]
fn stash_delete_by_member_id_after_another_member_left_deletes_that_member() {
    let mux = Mux::new_for_test("stash-member-ids", SurfaceOptions::default());
    let stash = import(
        &mux,
        &["https://a.example/", "https://b.example/", "https://c.example/", "https://d.example/"],
        "import",
    );
    let listed = read(&mux, "stash.list", json!({}));
    let ids = listed[0]["members"]
        .as_array()
        .unwrap()
        .iter()
        .map(|member| member["id"].as_str().expect("every member has an id").to_string())
        .collect::<Vec<_>>();
    assert_eq!(ids.iter().collect::<HashSet<_>>().len(), 4, "distinct ids: {listed}");

    mutate(&mux, "stash.delete", json!({"stash": stash, "members": [ids[1]]}), "delete-b");
    mutate(&mux, "stash.delete", json!({"stash": stash, "members": [ids[2]]}), "delete-c");
    let listed = read(&mux, "stash.list", json!({}));
    assert_eq!(member_urls(&listed[0]), ["https://a.example/", "https://d.example/"]);
    assert_eq!(listed[0]["members"][1]["id"], ids[3], "an id outlives other deletes");

    let gone = json!({"stash": stash, "members": [ids[0], ids[2]]});
    assert_eq!(
        error_code(send(&mux, "stash.delete", gone.clone(), Some("delete-gone"))),
        "resource.not_found"
    );
    assert_eq!(
        error_code(send(&mux, "stash.restore", gone, Some("restore-gone"))),
        "resource.not_found"
    );
    let listed = read(&mux, "stash.list", json!({}));
    assert_eq!(
        member_urls(&listed[0]),
        ["https://a.example/", "https://d.example/"],
        "nothing changed"
    );

    let restored =
        mutate(&mux, "stash.restore", json!({"stash": stash, "members": [ids[3]]}), "restore-d");
    assert_eq!(restored["remaining"], 1);
    assert_eq!(member_urls(&read(&mux, "stash.list", json!({}))[0]), ["https://a.example/"]);
    mux.shutdown();
}

/// `here` with a pane: a member with no live pane of its own (an imported
/// page has none) opens in that pane; an unknown pane changes nothing.
#[test]
fn stash_restore_here_opens_a_member_without_a_live_pane_in_the_named_pane() {
    let mux = Mux::new_for_test("stash-restore-pane", SurfaceOptions::default());
    let first = mux.new_workspace(Some("One".into()), None).unwrap().id;
    let second = mux.new_workspace(Some("Two".into()), None).unwrap().id;
    let stash = import(&mux, &["https://a.example/"], "import");
    let target = pane_id(&mux, first);
    assert_ne!(target, pane_id(&mux, second));

    let refused = send(
        &mux,
        "stash.restore",
        json!({"stash": stash, "pane": "pane_00000000000000000000000000000000"}),
        Some("restore-nowhere"),
    );
    assert_eq!(error_code(refused), "resource.not_found");
    assert_eq!(read(&mux, "stash.list", json!({})).as_array().unwrap().len(), 1);

    let here = mutate(&mux, "stash.restore", json!({"stash": stash, "pane": target}), "restore");
    let tab = here["tab_ids"][0].as_str().unwrap().to_string();
    assert_eq!(pane_id(&mux, surface_of(&mux, &tab)), target, "in the pane the user acted from");
    assert_eq!(pane_tab_ids(&mux, first).len(), 2);
    mux.shutdown();
}

/// App tabs are never stashed: named, they refuse the request; a
/// workspace stash leaves them open as `skipped`.
#[test]
fn stash_refuses_app_tabs() {
    let mux = Mux::new_for_test("stash-app-tabs", SurfaceOptions::default());
    let shell = mux.new_workspace(Some("Apps".into()), None).unwrap().id;
    let pane = mux.with_state(|state| state.pane_of(shell)).unwrap();
    let page = browser_in(&mux, pane, "https://example.com/page");
    let app = browser_in(&mux, pane, "https://example.com/app");
    let (page_id, app_id) = (tab_id(&mux, page), tab_id(&mux, app));
    mux.read_registry_state(|connection| {
        connection.execute(
            "INSERT INTO app_tabs(browser_id, app_id, route)
             SELECT content_id, 'cmux/demo', NULL FROM resource_tabs WHERE public_id = ?1",
            [&app_id],
        )?;
        Ok(())
    })
    .unwrap();

    let refused = send(&mux, "stash.create", json!({"tabs": [app_id]}), Some("stash-app"));
    assert_eq!(error_code(refused), "validation.invalid");
    let workspace = mux.with_state(|state| {
        let (workspace, _) = state.screen_of(pane).unwrap();
        state.workspaces[workspace].public_id.to_string()
    });
    let created = mutate(&mux, "stash.create", json!({"workspace": workspace}), "stash-ws");
    assert_eq!(created["tab_ids"], json!([page_id]));
    assert!(created["skipped"].as_array().unwrap().contains(&json!(app_id)), "{created}");
    assert!(pane_tab_ids(&mux, shell).contains(&app_id), "the app tab stays open");
    mux.shutdown();
}
