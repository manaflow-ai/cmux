//! Supervisor tests of the toolbar band's app items (`toolbar.rs`):
//! `contributes.toolbarItems`, answered by the daemon from the catalog.

use super::*;

/// Gives the app in `dir` the toolbar items `items` and, when `version` is
/// set, that version.
fn save_items(dir: &Path, items: Value, version: Option<&str>) {
    let path = dir.join("cmux-app.json");
    let mut manifest: Value =
        serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
    manifest["contributes"] = json!({ "toolbarItems": items });
    if let Some(version) = version {
        manifest["version"] = json!(version);
    }
    std::fs::write(&path, manifest.to_string()).unwrap();
}

fn spy_dir(f: &Fixture) -> PathBuf {
    f.state.join("apps/local/spy")
}

fn list(f: &Fixture) -> Value {
    f.supervisor.store_call(CLIENT, "apps.toolbar.list", json!({}), Origin::User).unwrap()
}

/// `[(app, id)]` of the listed items, in order.
fn ids(f: &Fixture) -> Vec<(String, String)> {
    list(f)["items"]
        .as_array()
        .unwrap()
        .iter()
        .map(|i| (i["app"].as_str().unwrap().into(), i["id"].as_str().unwrap().into()))
        .collect()
}

fn button(id: &str, op: &str) -> Value {
    json!({ "id": id, "kind": "button", "title": id, "icon": { "symbol": "star" }, "action": { "op": op } })
}

/// An installed extension's button and menu button are listed with the op a
/// click runs; an item the shell must not draw (an alternative for a built-in
/// item, or an action that is not one of the app's own ops) is not; a
/// hidden or uninstalled extension lists none.
#[test]
fn an_installed_extensions_toolbar_button_is_listed_with_its_op() {
    let f = fixture();
    save_items(
        &spy_dir(&f),
        json!([
            {
                "id": "sync", "kind": "button", "title": "Sync", "icon": { "symbol": "arrow.triangle.2.circlepath" },
                "action": { "op": "local.spy.go", "args": { "all": true } }, "order": 20
            },
            {
                "id": "more", "kind": "menu", "title": { "en": "More" }, "order": 10,
                "items": [
                    { "title": "Focus", "action": { "op": "local.spy.focus" } },
                    { "title": "New workspace", "action": { "op": "workspace.new" } }
                ]
            },
            { "id": "back", "kind": "button", "title": "Back", "action": { "op": "local.spy.go" }, "overrides": "nav.back" },
            { "id": "new", "kind": "button", "title": "New", "action": { "op": "workspace.new" } }
        ]),
        None,
    );
    f.supervisor.reload_local_apps(&Default::default());
    assert_eq!(list(&f)["items"], json!([]), "not installed yet");

    f.install("local/spy");
    assert_eq!(
        list(&f)["items"],
        json!([
            {
                "app": "local/spy", "extension": "Demo", "id": "more", "kind": "menu", "title": { "en": "More" },
                "entries": [{ "title": "Focus", "op": "local.spy.focus" }], "order": 10
            },
            {
                "app": "local/spy", "extension": "Demo", "id": "sync", "kind": "button", "title": "Sync",
                "symbol": "arrow.triangle.2.circlepath", "op": "local.spy.go", "args": { "all": true }, "order": 20
            }
        ])
    );

    f.set("hide", "local/spy", Origin::User, |o| o.hidden = Some(true)).unwrap();
    assert_eq!(list(&f)["items"], json!([]), "a hidden extension adds nothing");
}

/// Saving the installed extension's manifest updates the list with no
/// restart: the local reload swaps the catalog and says `apps-changed`, on
/// which the Mac lists again and redraws the band.
#[test]
fn a_save_of_the_installed_extensions_toolbar_items_updates_the_list_live() {
    let f = fixture();
    save_items(&spy_dir(&f), json!([button("sync", "local.spy.go")]), None);
    let prints = f.supervisor.reload_local_apps(&Default::default());
    f.install("local/spy");
    assert_eq!(ids(&f), [("local/spy".to_string(), "sync".to_string())]);

    save_items(
        &spy_dir(&f),
        json!([button("sync", "local.spy.go"), button("focus", "local.spy.focus")]),
        Some("1.0.1"),
    );
    let prints = f.supervisor.reload_local_apps(&prints);
    f.wait("the reload's apps-changed", |e| {
        e["event"] == "apps-changed"
            && e["transaction"] == "local-reload"
            && e["app"] == "local/spy"
    });
    assert_eq!(
        ids(&f),
        [
            ("local/spy".to_string(), "sync".to_string()),
            ("local/spy".to_string(), "focus".to_string())
        ]
    );

    save_items(&spy_dir(&f), json!([]), Some("1.0.2"));
    f.supervisor.reload_local_apps(&prints);
    assert_eq!(list(&f)["items"], json!([]), "a save that drops them clears the band");
}

/// App items sort by `order`, then app id: the order is the daemon's, so
/// every window draws the same band.
#[test]
fn toolbar_items_of_two_extensions_sort_by_order_then_app() {
    let root = temp_dir();
    write_app(&root.0.join("bundled"), "demo", "cmux/demo", json!({ "workspace:read": "r" }));
    save_items(&root.0.join("bundled/demo"), json!([button("a", "demo.go")]), None);
    let local = root.0.join("state/apps/local");
    write_app(&local, "spy", "local/spy", json!({ "workspace:read": "r" }));
    let mut first = button("b", "local.spy.go");
    first["order"] = json!(1);
    save_items(&local.join("spy"), json!([first, button("c", "local.spy.focus")]), None);
    let f = fixture_with(&[], Duration::from_secs(60), root);
    f.install("cmux/demo");
    f.install("local/spy");
    assert_eq!(
        ids(&f),
        [
            ("local/spy".to_string(), "b".to_string()),
            ("cmux/demo".to_string(), "a".to_string()),
            ("local/spy".to_string(), "c".to_string())
        ]
    );
}

/// Safe mode turns every extension off: the band gets none.
#[test]
fn safe_mode_lists_no_toolbar_items() {
    let root = temp_dir();
    write_app(&root.0.join("bundled"), "demo", "cmux/demo", json!({ "workspace:read": "r" }));
    save_items(&root.0.join("bundled/demo"), json!([button("a", "demo.go")]), None);
    let f = fixture_safe(&[], Duration::from_secs(60), root, true);
    f.install("cmux/demo");
    assert_eq!(list(&f)["items"], json!([]));
}
