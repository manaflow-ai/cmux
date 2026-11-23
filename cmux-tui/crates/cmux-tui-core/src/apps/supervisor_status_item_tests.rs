//! Supervisor tests of status items (`status_items.rs`): the daemon answers which
//! `cmux.status/1` items show and where; the Mac draws only what it lists.

use super::*;

fn spy_dir(f: &Fixture) -> PathBuf {
    f.state.join("apps/local/spy")
}

/// Gives the app in `dir` a status item with `title` at `placement` (none: the default) and,
/// when `version` is set, that version.
fn save_status(dir: &Path, title: &str, placement: Option<&str>, version: Option<&str>) {
    let path = dir.join("cmux-app.json");
    let mut manifest: Value =
        serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
    let mut entry = json!({ "export": "renderFail", "title": title, "symbol": "bolt" });
    if let Some(placement) = placement {
        entry["options"] = json!({ "placement": placement });
    }
    manifest["implements"]["cmux.status/1"] = entry;
    if let Some(version) = version {
        manifest["version"] = json!(version);
    }
    std::fs::write(&path, manifest.to_string()).unwrap();
}

fn items(f: &Fixture) -> Value {
    f.supervisor.store_call(CLIENT, "apps.status.list", json!({}), Origin::User).unwrap()["items"]
        .clone()
}

/// Nothing shows unless an installed, enabled and visible extension contributes an item; the
/// item says where it goes (the titlebar when the manifest names no placement).
#[test]
fn only_an_installed_visible_extensions_status_item_is_listed() {
    let f = fixture();
    save_status(&spy_dir(&f), "Spy", None, None);
    f.supervisor.reload_local_apps(&Default::default());
    assert_eq!(items(&f), json!([]), "not installed yet");

    f.install("local/spy");
    assert_eq!(
        items(&f),
        json!([{ "app": "local/spy", "extension": "Demo", "title": "Spy", "symbol": "bolt", "placement": "titlebar", "place": "titlebar" }])
    );

    f.set("hide", "local/spy", Origin::User, |o| o.hidden = Some(true)).unwrap();
    assert_eq!(items(&f), json!([]), "a hidden extension shows nothing");
}

/// A save of the installed extension's manifest moves its item with no restart: the local
/// reload swaps the catalog and says `apps-changed`, on which the Mac lists again.
#[test]
fn a_save_of_the_installed_extensions_status_item_updates_the_list_live() {
    let f = fixture();
    save_status(&spy_dir(&f), "Spy", Some("titlebar"), None);
    let prints = f.supervisor.reload_local_apps(&Default::default());
    f.install("local/spy");
    assert_eq!(items(&f)[0]["placement"], "titlebar");

    save_status(&spy_dir(&f), "Spy Health", Some("menuBar"), Some("1.0.1"));
    f.supervisor.reload_local_apps(&prints);
    f.wait("the reload's apps-changed", |e| {
        e["event"] == "apps-changed"
            && e["transaction"] == "local-reload"
            && e["app"] == "local/spy"
    });
    let listed = items(&f);
    assert_eq!(listed[0]["placement"], "menuBar");
    assert_eq!(listed[0]["place"], "menuBar");
    assert_eq!(listed[0]["title"], "Spy Health");
}

/// Safe mode turns every extension off: no status item shows.
#[test]
fn safe_mode_lists_no_status_items() {
    let root = temp_dir();
    write_app(&root.0.join("bundled"), "demo", "cmux/demo", json!({ "workspace:read": "r" }));
    let f = fixture_safe(&[], Duration::from_secs(60), root, true);
    f.install("cmux/demo");
    assert_eq!(items(&f), json!([]));
}
