//! Supervisor tests of the local apps reload (`local_reload.rs`).

use super::*;

/// Sets the version in `local/spy`'s manifest (`fixture` writes 1.0.0).
fn save_spy_version(state: &Path, version: &str) {
    save_version(&state.join("apps/local/spy"), version);
}

/// Sets the version in the manifest of the app in `dir`.
fn save_version(dir: &Path, version: &str) {
    let path = dir.join("cmux-app.json");
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

/// A local app folder made during the catalog read, then saved again before
/// the read ends: its fingerprint must not hold the second save, or that
/// save's event finds no change (base red: the fingerprint of a folder not
/// fingerprinted before the read was taken after it).
#[test]
fn a_folder_made_during_the_catalog_read_is_read_again_on_its_next_event() {
    let f = fixture();
    let prints = f.supervisor.reload_local_apps(&Default::default());
    let late = f.state.join("apps/local/late");
    let prints = f.supervisor.reload_local_apps_from(&prints, |sources| {
        write_app(&f.state.join("apps/local"), "late", "local/late", json!({}));
        let catalog = super::super::catalog::load(sources);
        save_version(&late, "1.0.1");
        catalog
    });
    assert_eq!(app_entry(&f.supervisor.list(), "local/late")["version"], "1.0.0");
    f.supervisor.reload_local_apps(&prints);
    let entry = app_entry(&f.supervisor.list(), "local/late");
    assert_eq!(entry["version"], "1.0.1", "the second save was read: {entry}");
}
