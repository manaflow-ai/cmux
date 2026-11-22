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

/// Stress: a save of one sidebar app among `apps` local apps (each a 256 KiB
/// bundle, the size of a small built extension) plus five malformed
/// manifests. The cost of the pass a save makes must not grow with the
/// number of apps that did not change (Leo: break sidebar customization with
/// 50+ sections, rapid `ext dev` save loops and malformed manifests).
/// Prints `apps | p50 ms | p95 ms` and the warn lines a pass repeats.
#[test]
fn local_reload_stress_one_save_among_many_apps() {
    let bundle = "x".repeat(256 * 1024);
    let mut rows = Vec::new();
    for apps in [1usize, 50, 200] {
        let f = fixture();
        let local = f.state.join("apps/local");
        for i in 0..apps {
            write_app(&local, &format!("s{i}"), &format!("local/s{i}"), json!({}));
            std::fs::write(local.join(format!("s{i}/dist/main.js")), &bundle).unwrap();
        }
        for i in 0..5 {
            let bad = local.join(format!("bad{i}"));
            std::fs::create_dir_all(&bad).unwrap();
            std::fs::write(
                bad.join("cmux-app.json"),
                ["{ not json", "{}", "[]", "{\"id\":5}", "\u{0}"][i],
            )
            .unwrap();
        }
        // The first pass reports the malformed folders: that is the once.
        let mut prints = f.supervisor.reload_local_apps(&Default::default());
        let _: Vec<Value> = f.events.try_iter().collect();
        // The pass a save makes: the watch and `cmux ext dev` name the folder.
        let mut samples = Vec::new();
        for save in 0..30 {
            save_version(&local.join("s0"), &format!("1.0.{}", save + 1));
            let start = Instant::now();
            prints = f.supervisor.reload_local_apps_saved(&prints, [local.join("s0")]);
            samples.push(start.elapsed());
        }
        // A pass over every folder (`cmux ext reload`, a lost event), for the table.
        let start = Instant::now();
        prints = f.supervisor.reload_local_apps(&prints);
        let full = start.elapsed();
        assert!(!prints.is_empty());
        let events: Vec<Value> = f.events.try_iter().collect();
        let changed = events.iter().filter(|e| e["event"] == "apps-changed").count();
        let logs = f.supervisor.logs(CLIENT, "cmux/supervisor", false);
        let warns = logs["lines"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|l| l["level"] == "warn" && l["message"].as_str().unwrap().contains("/bad"))
            .count();
        assert_eq!(changed, 30, "every save reached the app");
        assert_eq!(app_entry(&f.supervisor.list(), "local/s0")["version"], "1.0.30");
        samples.sort();
        let (p50, p95) = (samples[15], samples[28]);
        println!(
            "local reload: {apps} apps | p50 {:.2} ms | p95 {:.2} ms | {warns} warn lines over 30 saves | every folder {:.2} ms",
            p50.as_secs_f64() * 1e3,
            p95.as_secs_f64() * 1e3,
            full.as_secs_f64() * 1e3
        );
        rows.push((apps, p50, warns));
    }
    let (_, one, _) = rows[0];
    for (apps, p50, warns) in &rows {
        // A malformed folder is said once, not again on every other app's save.
        assert!(*warns <= 10, "{apps} apps: {warns} warn lines for 5 malformed folders");
        // One save costs about what it costs with one app; 3x room for noise.
        assert!(
            *p50 <= one * 3 + Duration::from_millis(2),
            "{apps} apps: one save took {p50:?} vs {one:?} with one app"
        );
    }
}

/// A pass reuses the read of each unchanged folder (`earlier_reads`); a
/// folder whose files change is read again, so a malformed manifest that is
/// fixed loads, and its unchanged neighbour keeps its package.
#[test]
fn a_fixed_manifest_loads_while_unchanged_folders_are_reused() {
    let f = fixture();
    let local = f.state.join("apps/local");
    write_app(&local, "late", "local/late", json!({}));
    let good = std::fs::read_to_string(local.join("late/cmux-app.json")).unwrap();
    std::fs::write(local.join("late/cmux-app.json"), "{ not json").unwrap();
    let prints = f.supervisor.reload_local_apps(&Default::default());
    assert_eq!(app_entry(&f.supervisor.list(), "local/late"), Value::Null);
    let prints = f.supervisor.reload_local_apps(&prints);
    assert_eq!(app_entry(&f.supervisor.list(), "local/late"), Value::Null, "still refused");
    std::fs::write(local.join("late/cmux-app.json"), good).unwrap();
    f.supervisor.reload_local_apps(&prints);
    assert_eq!(app_entry(&f.supervisor.list(), "local/late")["version"], "1.0.0");
    assert_eq!(app_entry(&f.supervisor.list(), "local/spy")["version"], "1.0.0");
}

/// The pass a save makes reads only the folders it names: among them a new
/// app folder loads and a folder whose manifest went is removed, while an
/// app the save did not name keeps what the last pass read. Every app's
/// change is read by the pass that names it or reads every folder.
#[test]
fn a_pass_for_named_folders_reads_those_folders_only() {
    let f = fixture();
    let local = f.state.join("apps/local");
    write_app(&local, "a", "local/a", json!({}));
    write_app(&local, "b", "local/b", json!({}));
    let prints = f.supervisor.reload_local_apps(&Default::default());
    write_app(&local, "c", "local/c", json!({}));
    std::fs::remove_file(local.join("b/cmux-app.json")).unwrap();
    save_version(&local.join("a"), "2.0.0");
    let prints = f.supervisor.reload_local_apps_saved(&prints, [local.join("b"), local.join("c")]);
    let list = f.supervisor.list();
    assert_eq!(app_entry(&list, "local/c")["version"], "1.0.0", "the new folder loads");
    assert_eq!(app_entry(&list, "local/b"), Value::Null, "the folder without a manifest goes");
    assert_eq!(app_entry(&list, "local/a")["version"], "1.0.0", "an unnamed folder is not read");
    f.supervisor.reload_local_apps_saved(&prints, [local.join("a")]);
    assert_eq!(app_entry(&f.supervisor.list(), "local/a")["version"], "2.0.0");
}

/// The person's customize folder app (`local/customize`): sidebar row
/// decorations, a sidebar section and a pane, from one script that draws
/// `word` (`customize_script`).
fn write_customize(dir: &Path, word: &str) {
    std::fs::write(dir.join("main.js"), customize_script(word)).unwrap();
    let manifest = json!({
        "manifestVersion": 2, "id": "local/customize", "name": "Mine", "version": "1.0.0",
        "description": "d", "engines": { "cmux": "^2.0" }, "runtime": { "main": "main.js" },
        "implements": {
            "cmux.sidebar.rows/1": { "export": "renderRows" },
            "cmux.section/1": { "export": "renderSection", "title": "Mine" },
            "cmux.pane/1": { "export": "renderPane", "title": "Mine", "symbol": "bolt" }
        }
    });
    std::fs::write(dir.join("cmux-app.json"), manifest.to_string()).unwrap();
}

/// A customize script whose every view draws `word` (the scripted host's
/// `SCENE_TEXT`).
fn customize_script(word: &str) -> String {
    format!("// SCENE_TEXT {word}\nvar __cmuxAppExports = {{}};\n")
}

/// Ten in-place saves of the customize folder's `main.js` (open, truncate,
/// write: `edit-repaint.py`'s save), each through the real file watch, each
/// redrawing the open `interface` view with the saved script. Returns each
/// save's ms to the new scene.
fn ten_saves_redraw_the_open_view(interface: &str) -> Vec<u128> {
    let f = fixture_customize();
    let dir = f.customize.clone().unwrap();
    write_customize(&dir, "save0");
    f.supervisor.reload_local_apps(&Default::default());
    let entry = app_entry(&f.supervisor.list(), "local/customize");
    assert_eq!(entry["installed"], true, "the customize app installs itself: {entry}");
    f.supervisor.mount(CLIENT, "v1", "local/customize", interface, json!({})).unwrap();
    let first = f.wait("the first scene", |e| e["event"] == "apps-scene" && e["mount_id"] == "v1");
    assert_eq!(first["ops"][0]["props"]["text"], "save0", "{first}");
    f.supervisor.start_local_watch_for_test();
    // The watch reads once as it starts; let that settle.
    std::thread::sleep(Duration::from_millis(500));
    while f.events.try_recv().is_ok() {}
    (1..=10)
        .map(|n| {
            let word = format!("save{n}");
            let start = Instant::now();
            std::fs::write(dir.join("main.js"), customize_script(&word)).unwrap();
            f.wait(&format!("save {n} redraws the open {interface} view"), |e| {
                e["event"] == "apps-scene"
                    && e["mount_id"] == "v1"
                    && e["ops"][0]["op"] == "create"
                    && e["ops"][0]["props"]["text"] == word.as_str()
            });
            start.elapsed().as_millis()
        })
        .collect()
}

/// A save of the customize folder's script redraws the sidebar's row
/// decorations (`cmux.sidebar.rows/1`), every time (capability matrix
/// item 17: no test saved a rows change).
#[test]
fn a_rows_save_redraws_the_sidebar_rows_each_time() {
    let ms = ten_saves_redraw_the_open_view("cmux.sidebar.rows/1");
    eprintln!("rows save to scene ms: {ms:?}");
}

/// A save redraws an extension pane that is open (`cmux.pane/1`), every
/// time, without closing it (capability matrix item 17: the DEV tour opened
/// the pane after a reload, but never reloaded it while open).
#[test]
fn a_save_redraws_an_open_pane() {
    let ms = ten_saves_redraw_the_open_view("cmux.pane/1");
    eprintln!("pane save to scene ms: {ms:?}");
}

/// `edit-repaint.py`'s extension case on the daemon alone: ten in-place
/// saves of the customize folder's `main.js` redraw its open sidebar
/// section, every time (the fleet run saw 0 of 10 by pixels).
#[test]
fn a_customize_section_save_redraws_each_time() {
    let ms = ten_saves_redraw_the_open_view("cmux.section/1");
    eprintln!("section save to scene ms: {ms:?}");
}
