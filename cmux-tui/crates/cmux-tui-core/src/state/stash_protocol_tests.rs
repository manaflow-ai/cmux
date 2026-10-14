//! Stash (`stash-v1`, bead cx-rws36): a native OneTab. `stash.create`
//! closes browser tabs into one stashed group instead of the closed
//! history; `stash.restore` brings members back here or in a new
//! workspace; `stash.delete` drops a group or members; `stash.import` takes
//! OneTab groups. Driven through `cmux.protocol/2` requests.

use serde_json::json;

use super::tests::{Session, error_code, mutate, pane_tab_ids, read, send, tab_id, terminal_tabs};
use crate::mux::*;
use crate::state::prelude::*;
use crate::surface::SurfaceOptions;
use crate::workspace_registry::FrontendBrowserRecord;

const HISTORY: &str = r#"{"entries":[{"url":"https://example.com/b0","title":"B0","scrollY":640},{"url":"https://example.com/b","title":"B","scrollY":0}],"index":1}"#;

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

/// The page URL a live tab shows (its frontend browser record).
fn tab_url(mux: &Arc<Mux>, tab: &str) -> String {
    mux.read_registry_state(|connection| {
        Ok(connection.query_row(
            "SELECT f.url FROM resource_tabs AS t
             JOIN frontend_browser_tabs AS f ON f.browser_id = t.content_id
             WHERE t.public_id = ?1 AND t.deleted_revision IS NULL",
            [tab],
            |row| row.get::<_, String>(0),
        )?)
    })
    .unwrap()
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

fn workspace_of(mux: &Arc<Mux>, surface: SurfaceId) -> String {
    mux.with_state(|state| {
        let pane = state.pane_of(surface).unwrap();
        let (workspace, _) = state.screen_of(pane).unwrap();
        state.workspaces[workspace].public_id.to_string()
    })
}

fn member_urls(group: &Value) -> Vec<String> {
    group["members"]
        .as_array()
        .unwrap()
        .iter()
        .map(|member| member["url"].as_str().unwrap().to_string())
        .collect()
}

#[test]
fn stash_closes_browser_tabs_into_one_group_and_restores_here_then_in_a_new_workspace() {
    let mux = Mux::new_for_test("stash-roundtrip", SurfaceOptions::default());
    let shell = mux.new_workspace(Some("Research".into()), None).unwrap().id;
    let pane = mux.with_state(|state| state.pane_of(shell)).unwrap();
    let a = browser_in(&mux, pane, "https://example.com/a");
    let b = browser_in(&mux, pane, "https://example.com/b");
    mux.set_frontend_browser_history(b, Some(HISTORY.into())).unwrap();
    let workspace = workspace_of(&mux, shell);
    let (a_id, b_id) = (tab_id(&mux, a), tab_id(&mux, b));

    let created = mutate(&mux, "stash.create", json!({"tabs": [a_id, b_id]}), "stash-1");
    assert_eq!(created["tab_ids"], json!([a_id, b_id]));
    assert_eq!(pane_tab_ids(&mux, shell), [tab_id(&mux, shell)], "the stashed tabs close");

    let stashes = read(&mux, "stash.list", json!({}));
    assert_eq!(stashes.as_array().unwrap().len(), 1, "one stash, one group: {stashes}");
    assert_eq!(stashes[0]["id"], created["stash_id"]);
    assert_eq!(stashes[0]["name"], "Research");
    assert_eq!(member_urls(&stashes[0]), ["https://example.com/a", "https://example.com/b"]);
    assert!(!stashes.to_string().contains("scrollY"), "stash.list hides session history");
    assert!(
        read(&mux, "closed.list", json!({})).as_array().unwrap().is_empty(),
        "a stash is not a closed-history close"
    );

    let stash = created["stash_id"].as_str().unwrap().to_string();
    let first = stashes[0]["members"][0]["id"].clone();
    let here =
        mutate(&mux, "stash.restore", json!({"stash": stash, "members": [first]}), "restore-1");
    assert_eq!(here["remaining"], 1);
    let restored = here["tab_ids"][0].as_str().unwrap().to_string();
    assert_eq!(tab_url(&mux, &restored), "https://example.com/a");
    assert_eq!(pane_tab_ids(&mux, shell), [tab_id(&mux, shell), restored], "back at its index");
    let stashes = read(&mux, "stash.list", json!({}));
    assert_eq!(member_urls(&stashes[0]), ["https://example.com/b"]);

    let moved = mutate(
        &mux,
        "stash.restore",
        json!({"stash": stash, "target": "new_workspace"}),
        "restore-2",
    );
    assert_eq!(moved["remaining"], 0);
    assert_ne!(moved["workspace_id"], workspace, "the rest opens in a new workspace");
    let tab = moved["tab_ids"][0].as_str().unwrap().to_string();
    let surface = surface_of(&mux, &tab);
    assert_eq!(workspace_of(&mux, surface), moved["workspace_id"].as_str().unwrap());
    assert_eq!(tab_url(&mux, &tab), "https://example.com/b");
    assert_eq!(
        pane_tab_ids(&mux, surface),
        std::slice::from_ref(&tab),
        "only the stashed page, no shell"
    );
    assert_eq!(mux.frontend_browser_history(surface).unwrap().as_deref(), Some(HISTORY));
    assert!(read(&mux, "stash.list", json!({})).as_array().unwrap().is_empty());

    let replay = send(
        &mux,
        "stash.restore",
        json!({"stash": stash, "target": "new_workspace"}),
        Some("restore-2"),
    )
    .unwrap();
    assert_eq!(replay["replayed"], true);
    mux.shutdown();
}

#[test]
fn stash_refuses_terminals_and_incognito_tabs() {
    let mux = Mux::new_for_test("stash-refusals", SurfaceOptions::default());
    let terminal = terminal_tabs(&mux, 1)[0];
    let refused = send(&mux, "stash.create", json!({"tabs": [tab_id(&mux, terminal)]}), Some("t"));
    assert_eq!(error_code(refused), "validation.invalid");

    let created = mutate(
        &mux,
        "workspace.create",
        json!({"name": "incognito", "initial_content": "terminal", "ephemeral": true}),
        "create-ephemeral",
    );
    let workspace = created["workspace_id"].as_str().unwrap().to_string();
    let pane = mux
        .with_state(|state| {
            let workspace =
                state.workspaces.iter().find(|item| item.public_id.as_str() == workspace)?;
            workspace.active_screen_ref().map(|screen| screen.active_pane)
        })
        .unwrap();
    let private = browser_in(&mux, pane, "https://example.com/private");
    let refused = send(&mux, "stash.create", json!({"tabs": [tab_id(&mux, private)]}), Some("p"));
    assert_eq!(error_code(refused), "validation.invalid");
    assert!(read(&mux, "stash.list", json!({})).as_array().unwrap().is_empty());
    assert_eq!(pane_tab_ids(&mux, private).len(), 2, "a refused stash closes nothing");
    mux.shutdown();
}

#[test]
fn stash_import_delete_and_persistence_across_a_restart() {
    let session = Session::new("stash-import");
    let mux = session.open();
    let groups = json!({"source": "onetab", "groups": [
        {"name": "Reading", "created_ms": "1700000000000", "tabs": [
            {"url": "https://a.example/", "title": "A"},
            {"url": "https://b.example/"},
        ]},
        {"tabs": [{"url": "https://c.example/", "title": "C"}]},
    ]});
    let imported = mutate(&mux, "stash.import", groups.clone(), "import-1");
    assert_eq!(imported["stash_ids"].as_array().unwrap().len(), 2);
    let replay = send(&mux, "stash.import", groups, Some("import-1")).unwrap();
    assert_eq!(replay["replayed"], true);

    let stashes = read(&mux, "stash.list", json!({}));
    assert_eq!(stashes.as_array().unwrap().len(), 2, "a replay imports nothing twice");
    let reading = stashes
        .as_array()
        .unwrap()
        .iter()
        .find(|group| group["name"] == "Reading")
        .expect("the named OneTab group")
        .clone();
    assert_eq!(reading["created_at_ms"], "1700000000000");
    assert_eq!(member_urls(&reading), ["https://a.example/", "https://b.example/"]);
    assert_eq!(reading["members"][0]["title"], "A");

    let id = reading["id"].as_str().unwrap().to_string();
    let first = reading["members"][0]["id"].clone();
    mutate(&mux, "stash.delete", json!({"stash": id, "members": [first]}), "delete-1");
    let stashes = read(&mux, "stash.list", json!({}));
    let reading = stashes.as_array().unwrap().iter().find(|group| group["id"] == id).unwrap();
    assert_eq!(member_urls(reading), ["https://b.example/"]);
    mutate(&mux, "stash.delete", json!({"stash": id}), "delete-2");
    drop(mux);

    let mux = session.open();
    let stashes = read(&mux, "stash.list", json!({}));
    assert_eq!(stashes.as_array().unwrap().len(), 1, "stashes survive a restart: {stashes}");
    assert_eq!(member_urls(&stashes[0]), ["https://c.example/"]);
    assert_eq!(stashes[0]["members"][0]["title"], "C");
}

fn tab_kind(mux: &Arc<Mux>, tab: &str) -> String {
    mux.read_registry_state(|connection| {
        Ok(connection.query_row(
            "SELECT content_kind FROM resource_tabs WHERE public_id = ?1 AND deleted_revision IS NULL",
            [tab],
            |row| row.get::<_, String>(0),
        )?)
    })
    .unwrap()
}

/// Tabs named out of order go back to their own places: pane [X, A, B, Y],
/// stash [B, A], restore here: [X, A, B, Y].
#[test]
fn stash_restore_here_puts_tabs_named_out_of_order_back_in_place() {
    let mux = Mux::new_for_test("stash-order", SurfaceOptions::default());
    let x = mux.new_workspace(Some("Order".into()), None).unwrap().id;
    let pane = mux.with_state(|state| state.pane_of(x)).unwrap();
    let a = browser_in(&mux, pane, "https://example.com/a");
    let b = browser_in(&mux, pane, "https://example.com/b");
    let y = browser_in(&mux, pane, "https://example.com/y");
    let (a_id, b_id) = (tab_id(&mux, a), tab_id(&mux, b));

    let created = mutate(&mux, "stash.create", json!({"tabs": [b_id, a_id, b_id]}), "stash");
    assert_eq!(created["tab_ids"], json!([a_id, b_id]), "pane order, each tab once");
    mutate(&mux, "stash.restore", json!({"stash": created["stash_id"]}), "restore");
    let order = pane_tab_ids(&mux, x);
    assert_eq!(order.len(), 4, "{order:?}");
    assert_eq!(order[0], tab_id(&mux, x));
    assert_eq!(tab_url(&mux, &order[1]), "https://example.com/a");
    assert_eq!(tab_url(&mux, &order[2]), "https://example.com/b");
    assert_eq!(order[3], tab_id(&mux, y));
    mux.shutdown();
}

/// A stash that empties a workspace keeps the workspace in Recently Closed
/// (name, group, place, theme), without the stashed pages.
#[test]
fn stash_that_empties_a_workspace_keeps_the_workspace_reopenable_without_its_pages() {
    let mux = Mux::new_for_test("stash-workspace", SurfaceOptions::default());
    let shell = mux.new_workspace(Some("Reading".into()), None).unwrap().id;
    let pane = mux.with_state(|state| state.pane_of(shell)).unwrap();
    let a = browser_in(&mux, pane, "https://example.com/a");
    browser_in(&mux, pane, "https://example.com/b");
    let workspace = workspace_of(&mux, a);
    mutate(&mux, "tab.close", json!({"tab": tab_id(&mux, shell)}), "close-shell");

    let created = mutate(&mux, "stash.create", json!({"workspace": workspace}), "stash-ws");
    assert_eq!(created["tab_ids"].as_array().unwrap().len(), 2);
    let closed = read(&mux, "closed.list", json!({}));
    let group = closed
        .as_array()
        .unwrap()
        .iter()
        .find(|group| group["kind"] == "workspace")
        .unwrap_or_else(|| panic!("the emptied workspace is in Recently Closed: {closed}"))
        .clone();
    assert_eq!(group["name"], "Reading");
    assert!(!group.to_string().contains("example.com"), "no stashed page twice: {group}");

    let reopened = mutate(&mux, "closed.reopen", json!({"closed": group["id"]}), "reopen-ws");
    let tabs = reopened["tab_ids"].as_array().unwrap();
    assert_eq!(tabs.len(), 1, "only its fresh shell: {reopened}");
    assert_eq!(tab_kind(&mux, tabs[0].as_str().unwrap()), "terminal");
    let stashes = read(&mux, "stash.list", json!({}));
    assert_eq!(member_urls(&stashes[0]), ["https://example.com/a", "https://example.com/b"]);
    mux.shutdown();
}

/// Credentials never reach a stash: user info, and secret keys in the query
/// or the fragment, are stripped; import times are clamped or refused.
#[test]
fn stash_import_strips_credentials_and_checks_times() {
    let mux = Mux::new_for_test("stash-privacy", SurfaceOptions::default());
    let url = "https://user:pass@a.example/p?q=1&token=s#access_token=t&x=1";
    let imported = mutate(
        &mux,
        "stash.import",
        json!({"source": "onetab", "groups": [
            {"created_ms": "9999999999999", "tabs": [{"url": url}]},
        ]}),
        "import",
    );
    assert_eq!(imported["imported_tabs"], 1);
    let stashes = read(&mux, "stash.list", json!({}));
    assert_eq!(member_urls(&stashes[0]), ["https://a.example/p?q=1#x=1"]);
    let created: u64 = stashes[0]["created_at_ms"].as_str().unwrap().parse().unwrap();
    let now =
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_millis()
            as u64;
    assert!(created <= now, "a future time is clamped to now");
    let refused = send(
        &mux,
        "stash.import",
        json!({"source": "onetab", "groups": [
            {"created_ms": "soon", "tabs": [{"url": "https://a.example/"}]},
        ]}),
        Some("import-bad"),
    );
    assert_eq!(error_code(refused), "validation.invalid");
    mux.shutdown();
}
