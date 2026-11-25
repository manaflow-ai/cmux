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

/// A save that renames a view's export (the customize templates each name
/// their own) remounts the open view with the new name (base red: the
/// restarted host was sent the export read at the first mount, so the view
/// showed "the app does not export a function named ..." until it was
/// closed and opened again).
#[test]
fn a_save_that_renames_the_export_remounts_with_the_new_name() {
    let f = fixture();
    let prints = f.supervisor.reload_local_apps(&Default::default());
    f.install("local/spy");
    f.mount("m1", "local/spy", "cmux.section/1", json!({}));
    let path = f.state.join("apps/local/spy/cmux-app.json");
    let mut manifest: Value =
        serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
    manifest["version"] = json!("1.0.1");
    manifest["implements"]["cmux.section/1"]["export"] = json!("renderAgain");
    std::fs::write(&path, manifest.to_string()).unwrap();
    f.supervisor.reload_local_apps(&prints);
    let scene = f.wait("the remount's scene", |e| {
        e["event"] == "apps-scene" && e["mount_id"] == "m1" && e["ops"][0]["op"] == "create"
    });
    assert_eq!(scene["ops"][0]["props"]["text"], "renderAgain", "{scene}");
}

/// A save that drops the interface an open view renders fails that view the
/// way `mount` refuses it (base red: the restarted host was sent the old
/// export, so the view kept rendering an interface the app no longer has).
#[test]
fn a_save_that_drops_the_interface_fails_the_open_view() {
    let f = fixture();
    let prints = f.supervisor.reload_local_apps(&Default::default());
    f.install("local/spy");
    f.mount("m1", "local/spy", "cmux.section/1", json!({}));
    let path = f.state.join("apps/local/spy/cmux-app.json");
    let mut manifest: Value =
        serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
    manifest["version"] = json!("1.0.1");
    manifest["implements"].as_object_mut().unwrap().remove("cmux.section/1");
    std::fs::write(&path, manifest.to_string()).unwrap();
    f.supervisor.reload_local_apps(&prints);
    let failed =
        f.wait("the view fails", |e| e["event"] == "apps-mount-failed" && e["mount_id"] == "m1");
    assert!(failed["reason"].as_str().unwrap().contains("cmux.section/1"), "{failed}");
}

/// Writes `text` as `local/spy`'s script.
fn save_spy_script(state: &Path, text: &str) {
    std::fs::write(state.join("apps/local/spy/dist/main.js"), text).unwrap();
}

/// A save whose script does not load keeps the open view on the last script
/// that loaded, and says why the save was not taken; the next good save
/// draws it (base red: the old host was stopped before the new script ran,
/// so its init failure failed every mount and a section or chat widget lost
/// its view to an error card).
#[test]
fn a_save_that_does_not_load_keeps_the_last_good_mount() {
    let f = fixture();
    let prints = f.supervisor.reload_local_apps(&Default::default());
    f.install("local/spy");
    f.mount("m1", "local/spy", "cmux.section/1", json!({}));
    save_spy_script(&f.state, "const a b = 2 // THROW_AT_INIT");
    let prints = f.supervisor.reload_local_apps(&prints);
    let event = f.wait("the bad save's answer", |e| {
        e["event"] == "apps-reload-failed"
            || (e["event"] == "apps-mount-failed" && e["mount_id"] == "m1")
    });
    assert_eq!(event["event"], "apps-reload-failed", "the open view was failed: {event}");
    assert_eq!(event["app"], "local/spy", "{event}");
    assert!(event["reason"].as_str().unwrap().contains("main.js:2:12"), "{event}");
    save_spy_script(&f.state, "var __cmuxAppExports = {};");
    f.supervisor.reload_local_apps(&prints);
    let scene = f.wait("the good save's scene", |e| {
        e["mount_id"] == "m1" && (e["event"] == "apps-scene" || e["event"] == "apps-mount-failed")
    });
    assert_eq!(scene["event"], "apps-scene", "{scene}");
    assert_eq!(scene["ops"][0]["op"], "create", "{scene}");
}

/// Mounting an open view again under its id (Reload, Reload Custom Views)
/// marks its first scene `reset`, so a client that keeps drawing the old
/// scene until then replaces it instead of adding the new nodes to it.
#[test]
fn mounting_an_open_view_again_resets_its_scene() {
    let f = fixture();
    f.supervisor.reload_local_apps(&Default::default());
    f.install("local/spy");
    f.mount("m1", "local/spy", "cmux.section/1", json!({}));
    f.supervisor.mount(CLIENT, "m1", "local/spy", "cmux.section/1", json!({})).unwrap();
    let scene = f.wait("the second scene", |e| e["event"] == "apps-scene" && e["mount_id"] == "m1");
    assert_eq!(scene["reset"], true, "{scene}");
}

/// `apps-list` names the local folder this daemon watches, where
/// `cmux ext dev` copies an extension so this daemon reloads it.
#[test]
fn apps_list_names_the_watched_local_folder() {
    let f = fixture();
    let local = f.state.join("apps/local");
    assert_eq!(f.supervisor.list()["local_dir"], json!(local.to_string_lossy()));
}

/// An app in a `CMUX_APPS_DIRS` folder (`Sources::extra`: a person's own
/// checkout of an extension, or a fork of a first-party app) reloads on a
/// save like a local app, and its open view is mounted again with the saved
/// manifest (base red: only the customize and local folders had
/// fingerprints, so a save there changed nothing until cmux restarted).
#[test]
fn a_save_in_an_apps_dirs_folder_reloads_the_app_and_its_open_view() {
    let f = fixture();
    let extra = f.state.parent().unwrap().join("extra");
    write_app(&extra, "ext", "acme/ext", json!({}));
    // A publisher must own its repository (`publisher.mismatch`).
    let path = extra.join("ext/cmux-app.json");
    let mut manifest: Value =
        serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
    manifest["repository"] = json!("https://github.com/acme/ext");
    std::fs::write(&path, manifest.to_string()).unwrap();
    let prints = f.supervisor.reload_local_apps(&Default::default());
    assert_eq!(app_entry(&f.supervisor.list(), "acme/ext")["version"], "1.0.0");
    f.install("acme/ext");
    f.mount("m1", "acme/ext", "cmux.section/1", json!({}));
    manifest["version"] = json!("1.0.1");
    manifest["implements"]["cmux.section/1"]["export"] = json!("renderAgain");
    std::fs::write(&path, manifest.to_string()).unwrap();
    f.supervisor.reload_local_apps(&prints);
    let entry = app_entry(&f.supervisor.list(), "acme/ext");
    assert_eq!(entry["version"], "1.0.1", "the save was read: {entry}");
    let scene = f.wait("the remount's scene", |e| {
        e["event"] == "apps-scene" && e["mount_id"] == "m1" && e["ops"][0]["op"] == "create"
    });
    assert_eq!(scene["ops"][0]["props"]["text"], "renderAgain", "{scene}");
}

/// `apps-reload APP` (`cmux ext reload`): a save the watch never reported
/// (a missed event, a folder on a network volume) is read now, and the open
/// view draws it (base red: there was no way to reload but a new save or a
/// restart of cmux).
#[test]
fn a_forced_reload_reads_a_save_the_watch_did_not_report() {
    let f = fixture();
    f.supervisor.reload_local_apps(&Default::default());
    f.install("local/spy");
    f.mount("m1", "local/spy", "cmux.section/1", json!({}));
    let path = f.state.join("apps/local/spy/cmux-app.json");
    let mut manifest: Value =
        serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
    manifest["implements"]["cmux.section/1"]["export"] = json!("renderAgain");
    std::fs::write(&path, manifest.to_string()).unwrap();
    let answer = f.supervisor.reload_local_now(Some("local/spy")).unwrap();
    assert_eq!(answer["reloaded"], json!(["local/spy"]), "{answer}");
    assert_eq!(answer["refused"], json!([]), "{answer}");
    let scene = f.wait("the reloaded view's scene", |e| {
        e["event"] == "apps-scene" && e["mount_id"] == "m1" && e["ops"][0]["op"] == "create"
    });
    assert_eq!(scene["ops"][0]["props"]["text"], "renderAgain", "{scene}");
}

/// `apps-reload` with no app (`cmux reload-config`) reruns every local app,
/// changed or not: an unchanged one starts over and its open view draws
/// again.
#[test]
fn reloading_every_local_app_reruns_an_unchanged_one() {
    let f = fixture();
    f.supervisor.reload_local_apps(&Default::default());
    f.install("local/spy");
    f.mount("m1", "local/spy", "cmux.section/1", json!({}));
    let answer = f.supervisor.reload_local_now(None).unwrap();
    let reloaded = answer["reloaded"].as_array().unwrap();
    assert!(reloaded.contains(&json!("local/spy")), "{answer}");
    f.wait("the view's scene after the reload", |e| {
        e["event"] == "apps-scene" && e["mount_id"] == "m1" && e["ops"][0]["op"] == "create"
    });
}

/// A forced reload of a script that does not load keeps the last good view
/// and answers why, with file and line, so `cmux ext reload` can print it.
#[test]
fn a_forced_reload_of_a_broken_script_keeps_the_view_and_names_the_error() {
    let f = fixture();
    f.supervisor.reload_local_apps(&Default::default());
    f.install("local/spy");
    f.mount("m1", "local/spy", "cmux.section/1", json!({}));
    save_spy_script(&f.state, "const a b = 2 // THROW_AT_INIT");
    let answer = f.supervisor.reload_local_now(Some("local/spy")).unwrap();
    assert_eq!(answer["reloaded"], json!([]), "{answer}");
    assert_eq!(answer["refused"][0]["app"], "local/spy", "{answer}");
    assert!(answer["refused"][0]["reason"].as_str().unwrap().contains("main.js:2:12"), "{answer}");
    let event = f.wait("the refusal", |e| {
        e["event"] == "apps-reload-failed"
            || (e["event"] == "apps-mount-failed" && e["mount_id"] == "m1")
    });
    assert_eq!(event["event"], "apps-reload-failed", "the open view was failed: {event}");
}

/// A name that is no local app is refused with the local apps listed, and
/// nothing reloads.
#[test]
fn a_forced_reload_of_an_unknown_app_names_the_local_apps() {
    let f = fixture();
    f.supervisor.reload_local_apps(&Default::default());
    let error = f.supervisor.reload_local_now(Some("local/nope")).unwrap_err();
    assert_eq!(error.code, "apps.local.unknown");
    assert!(error.message.contains("local/spy"), "{}", error.message);
}

/// A folder the watch never reported (written as cmux started, or on a
/// volume with no events) loads when it is named.
#[test]
fn naming_a_folder_the_watch_never_reported_loads_it() {
    let f = fixture();
    f.supervisor.reload_local_apps(&Default::default());
    write_app(&f.state.join("apps/local"), "unseen", "local/unseen", json!({}));
    let answer = f.supervisor.reload_local_now(Some("local/unseen")).unwrap();
    assert_eq!(answer["reloaded"], json!(["local/unseen"]), "{answer}");
    assert_eq!(app_entry(&f.supervisor.list(), "local/unseen")["version"], "1.0.0");
}

/// A folder deleted where the watch did not see it: a forced reload, of
/// every app or of that one by name, reads it as removed and stops it.
#[test]
fn a_forced_reload_reads_a_folder_deleted_unseen_as_removed() {
    for named in [false, true] {
        let f = fixture();
        f.supervisor.reload_local_apps(&Default::default());
        assert_eq!(app_entry(&f.supervisor.list(), "local/spy")["version"], "1.0.0");
        std::fs::remove_dir_all(f.state.join("apps/local/spy")).unwrap();
        let answer = f.supervisor.reload_local_now(named.then_some("local/spy")).unwrap();
        assert_eq!(answer["removed"], json!(["local/spy"]), "named {named}: {answer}");
        assert_eq!(app_entry(&f.supervisor.list(), "local/spy"), Value::Null, "named {named}");
    }
}

/// An asked pass (`apps-reload-local`, `reload_local_apps_now`) applies a
/// save with no file event, from the prints of the last pass whoever ran it;
/// a second pass with nothing new announces and restarts nothing, so the
/// watch's late event after an asked pass costs no second restart
/// (ask-7fc19bd861).
#[test]
fn an_asked_pass_applies_a_save_once() {
    let f = fixture();
    f.supervisor.reload_local_apps_now();
    while f.events.try_recv().is_ok() {}
    save_spy_version(&f.state, "1.0.2");
    f.supervisor.reload_local_apps_now();
    let changed: Vec<Value> =
        f.events.try_iter().filter(|e| e["event"] == "apps-changed").collect();
    assert_eq!(changed.len(), 1, "{changed:?}");
    assert_eq!(changed[0]["app"], "local/spy");
    assert_eq!(changed[0]["transaction"], "local-reload");
    assert_eq!(app_entry(&f.supervisor.list(), "local/spy")["version"], "1.0.2");
    f.supervisor.reload_local_apps_now();
    let again: Vec<Value> = f.events.try_iter().filter(|e| e["event"] == "apps-changed").collect();
    assert!(again.is_empty(), "{again:?}");
}

/// An asked pass says what its events cannot: a new folder the catalog
/// refuses makes no event (it never had a print), so the answer names it
/// with why; a pass held by safe mode says so (review of cmux#44062: an `ok`
/// with nothing applied read as "reloaded").
#[test]
fn an_asked_pass_names_a_refused_folder() {
    let f = fixture();
    f.supervisor.reload_local_apps_now();
    let bad = f.state.join("apps/local/bad");
    std::fs::create_dir_all(&bad).unwrap();
    std::fs::write(bad.join("cmux-app.json"), "{ not json").unwrap();
    let answer = f.supervisor.reload_local_apps_now();
    assert_eq!(answer["safeMode"], false, "{answer}");
    let rejected = answer["rejected"].as_array().unwrap();
    assert!(
        rejected.iter().any(|r| r["dir"] == bad.display().to_string() && r["issue"].is_string()),
        "{answer}"
    );
}
