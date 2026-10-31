//! Supervisor tests of the local apps reload (`local_reload.rs`).

use super::*;

/// Sets the version in `local/spy`'s manifest (`fixture` writes 1.0.0).
fn save_spy_version(state: &Path, version: &str) {
    let path = state.join("apps/local/spy/cmux-app.json");
    let mut manifest: Value =
        serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
    manifest["version"] = json!(version);
    std::fs::write(&path, manifest.to_string()).unwrap();
}

/// A save that lands while a reload reads the catalog: the read missed it,
/// so the event it made must read again (base red: the reload took the
/// fingerprints after its read, they already held the save, and the next
/// event saw no change, so the old version stayed until the next save).
#[test]
fn a_save_during_the_catalog_read_is_read_on_its_event() {
    let f = fixture();
    let prints = f.supervisor.reload_local_apps(&Default::default());
    assert_eq!(app_entry(&f.supervisor.list(), "local/spy")["version"], "1.0.0");
    let prints = f.supervisor.reload_local_apps_from(&prints, |sources| {
        let catalog = super::super::catalog::load(sources);
        save_spy_version(&f.state, "1.0.1");
        catalog
    });
    f.supervisor.reload_local_apps(&prints);
    let spy = app_entry(&f.supervisor.list(), "local/spy");
    assert_eq!(spy["version"], "1.0.1", "the save was read: {spy}");
}
