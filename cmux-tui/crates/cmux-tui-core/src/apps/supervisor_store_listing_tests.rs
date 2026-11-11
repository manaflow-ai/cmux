//! Supervisor tests of what the App Store lists (`store_listing.rs`): Home
//! and the App Store ship as first-party packages, and the store's catalog
//! ops leave them out while `installed.list` marks them `listed: false`.

use super::*;

/// A first-party package `id` in `bundled/<dir>` with its own op family, so
/// it does not share the demo app's `demo.*` names.
fn write_first_party(bundled: &Path, dir: &str, id: &str, family: &str) {
    write_app(bundled, dir, id, json!({ "workspace:read": "r" }));
    let path = bundled.join(dir).join("catalog.json");
    let catalog = std::fs::read_to_string(&path).unwrap().replace("demo", family);
    std::fs::write(&path, catalog).unwrap();
}

fn listed_ids(f: &Fixture) -> Vec<String> {
    let list =
        f.supervisor.store_call(CLIENT, "apps.catalog.list", json!({}), Origin::Script).unwrap();
    let mut ids: Vec<String> = list["listings"]
        .as_array()
        .unwrap()
        .iter()
        .map(|row| row["app"].as_str().unwrap().to_string())
        .collect();
    ids.sort();
    ids
}

#[test]
fn the_store_lists_apps_and_never_home_or_itself() {
    let root = temp_dir();
    let bundled = root.0.join("bundled");
    write_first_party(&bundled, "home", "cmux/home", "home");
    write_first_party(&bundled, "app-store", "cmux/app-store", "appstore");
    let f = fixture_with(&[], Duration::from_secs(60), root);

    let ids = listed_ids(&f);
    assert!(ids.contains(&"cmux/demo".to_string()), "{ids:?}");
    assert!(!ids.iter().any(|id| id == "cmux/home" || id == "cmux/app-store"), "{ids:?}");
    for app in ["cmux/home", "cmux/app-store"] {
        let refused = f
            .supervisor
            .store_call(CLIENT, "apps.catalog.get", json!({ "app": app }), Origin::Script)
            .unwrap_err();
        assert_eq!(refused.code, "apps.unknown", "{app} has a store page");
    }
    let demo = f
        .supervisor
        .store_call(CLIENT, "apps.catalog.get", json!({ "app": "cmux/demo" }), Origin::Script)
        .unwrap();
    assert_eq!(demo["app"], "cmux/demo");

    for app in ["cmux/home", "cmux/app-store", "cmux/demo"] {
        f.install(app);
    }
    let installed =
        f.supervisor.store_call(CLIENT, "apps.installed.list", json!({}), Origin::Script).unwrap();
    let listed = |app: &str| {
        installed["apps"]
            .as_array()
            .unwrap()
            .iter()
            .find(|row| row["app"] == app)
            .unwrap_or_else(|| panic!("{app} is not installed: {installed}"))["listed"]
            .clone()
    };
    assert_eq!(listed("cmux/home"), json!(false));
    assert_eq!(listed("cmux/app-store"), json!(false));
    assert_eq!(listed("cmux/demo"), json!(true));
}
