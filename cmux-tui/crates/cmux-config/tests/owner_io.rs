//! The owner with IO: atomic publish (mode kept, symlinks written through),
//! write-time refresh, the cold-start cache, the config path and the watcher.

mod common;

use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::sync::mpsc::channel;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use cmux_config::location::{cache_path, config_path_from};
use cmux_config::managed::FixedManagedReader;
use cmux_config::{ConfigStore, Origin, watch_store};
use common::{forced, set};
use serde_json::{Value, json};

fn open(config: &Path, state_dir: &Path, managed: cmux_config::ManagedPreferences) -> ConfigStore {
    ConfigStore::open(
        config.to_path_buf(),
        Some(state_dir.to_path_buf()),
        Box::new(FixedManagedReader(managed)),
    )
}

fn cache(state_dir: &Path) -> Value {
    serde_json::from_str(&std::fs::read_to_string(cache_path(state_dir)).unwrap()).unwrap()
}

#[test]
fn writes_create_the_file_and_keep_its_mode() {
    let dir = tempfile::tempdir().unwrap();
    let config = dir.path().join("nested/cmux.json");
    let mut store = open(&config, dir.path(), Default::default());
    let result = store.apply(set("ui.animationSpeed", json!("off")));
    assert_eq!(result.result.unwrap().revision, 1);
    assert_eq!(result.changes.len(), 1);
    assert!(std::fs::read_to_string(&config).unwrap().contains("\"animationSpeed\": \"off\""));
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&config, std::fs::Permissions::from_mode(0o600)).unwrap();
        store.apply(set("ui.animationSpeed", json!("fast"))).result.unwrap();
        assert_eq!(std::fs::metadata(&config).unwrap().permissions().mode() & 0o777, 0o600);
    }
    let names: Vec<String> = std::fs::read_dir(config.parent().unwrap())
        .unwrap()
        .filter_map(Result::ok)
        .map(|entry| entry.file_name().to_string_lossy().into_owned())
        .collect();
    assert!(names.iter().all(|name| !name.ends_with(".tmp")), "no temp files remain: {names:?}");
    assert!(names.contains(&".cmux.json.lock".to_string()), "writes take the advisory lock");
}

#[cfg(unix)]
#[test]
fn a_symlinked_file_is_written_through() {
    let dir = tempfile::tempdir().unwrap();
    let real = dir.path().join("dotfiles/cmux.json");
    std::fs::create_dir_all(real.parent().unwrap()).unwrap();
    std::fs::write(&real, "{\n  // mine\n}\n").unwrap();
    let link = dir.path().join("cmux.json");
    std::os::unix::fs::symlink(&real, &link).unwrap();
    let mut store = open(&link, dir.path(), Default::default());
    store.apply(set("layout.panePadding", json!(8))).result.unwrap();
    assert!(std::fs::symlink_metadata(&link).unwrap().file_type().is_symlink());
    let text = std::fs::read_to_string(&real).unwrap();
    assert!(text.contains("// mine") && text.contains("\"panePadding\": 8"));
    assert!(store.watch_paths().contains(&real));
}

#[test]
fn a_hand_edit_is_refreshed_before_a_write() {
    let dir = tempfile::tempdir().unwrap();
    let config = dir.path().join("cmux.json");
    std::fs::write(&config, "{}").unwrap();
    let mut store = open(&config, dir.path(), Default::default());
    std::fs::write(&config, "{\n  // hand edit\n  \"actions\": {\"x\": 1}\n}\n").unwrap();
    let result = store.apply(set("ui.animationSpeed", json!("off")));
    assert_eq!(result.changes.len(), 2);
    assert_eq!(result.changes[0].origin, Origin::File);
    assert_eq!(result.changes[1].revision, result.changes[0].revision + 1);
    let text = std::fs::read_to_string(&config).unwrap();
    assert!(
        text.contains("// hand edit")
            && text.contains("\"actions\"")
            && text.contains("animationSpeed")
    );
    // A refused op still reports the refresh it caused.
    std::fs::write(&config, "{\"actions\": {\"x\": 2}}").unwrap();
    let refused = store.apply(set("ui.animationSpeed", json!("warp")));
    assert_eq!(refused.result.unwrap_err().code(), "invalid_params");
    assert_eq!(refused.changes.len(), 1);
}

#[test]
fn the_cache_follows_every_change_and_hides_secrets() {
    let dir = tempfile::tempdir().unwrap();
    let config = dir.path().join("cmux.json");
    let managed = forced(&[
        ("EnrollmentToken", json!("cmxe_secret")),
        ("appearance.density", json!("compact")),
    ]);
    let mut store = open(&config, dir.path(), managed.clone());
    let first = cache(dir.path());
    assert_eq!(first["revision"], json!(0));
    assert_eq!(first["managed"]["appearance.density"]["source"], json!("mdm"));
    assert_eq!(first["policy"]["EnrollmentToken"], json!("<set>"));
    assert!(!std::fs::read_to_string(cache_path(dir.path())).unwrap().contains("cmxe_secret"));
    assert_eq!(first["schema_hash"], json!(store.state().schema().schema_hash));
    store.apply(set("ui.animationSpeed", json!("off"))).result.unwrap();
    assert_eq!(cache(dir.path())["revision"], json!(1));
    assert_eq!(cache(dir.path())["effective"]["ui"]["animationSpeed"], json!("off"));
    drop(store);
    // A new owner continues the revision; an edit while none ran bumps it once.
    assert_eq!(open(&config, dir.path(), managed.clone()).state().revision(), 1);
    std::fs::write(&config, "{\"ui\": {\"animationSpeed\": \"fast\"}}").unwrap();
    assert_eq!(open(&config, dir.path(), managed).state().revision(), 2);
}

#[test]
fn reload_reports_effective_changes_only() {
    let dir = tempfile::tempdir().unwrap();
    let config = dir.path().join("cmux.json");
    std::fs::write(&config, "{\"ui\": {\"animationSpeed\": \"off\"}}").unwrap();
    let mut store = open(&config, dir.path(), Default::default());
    std::fs::write(&config, "// c\n{\"ui\": {\"animationSpeed\": \"off\"}}").unwrap();
    assert!(store.reload().is_none());
    std::fs::write(&config, "{\"ui\": {\"animationSpeed\": \"fast\"}}").unwrap();
    assert_eq!(store.reload().unwrap().keys, vec!["ui.animationSpeed".to_string()]);
}

fn env(pairs: &'static [(&'static str, &'static str)]) -> impl Fn(&str) -> Option<OsString> {
    move |name: &str| pairs.iter().find(|(k, _)| *k == name).map(|(_, v)| OsString::from(v))
}

#[test]
fn the_config_path_honors_the_override() {
    assert_eq!(
        config_path_from(env(&[("HOME", "/Users/a")])),
        PathBuf::from("/Users/a/.config/cmux/cmux.json")
    );
    assert_eq!(
        config_path_from(env(&[("HOME", "/Users/a"), ("CMUX_NEXT_CONFIG_FILE", "/tmp/t.json")])),
        PathBuf::from("/tmp/t.json")
    );
    assert_eq!(
        config_path_from(env(&[("HOME", "/Users/a"), ("CMUX_NEXT_CONFIG_FILE", "~/t.json")])),
        PathBuf::from("/Users/a/t.json")
    );
    assert_eq!(
        config_path_from(env(&[("HOME", "/Users/a"), ("CMUX_NEXT_CONFIG_FILE", "")])),
        PathBuf::from("/Users/a/.config/cmux/cmux.json")
    );
}

#[test]
fn the_watcher_reloads_on_edits_including_a_missing_directory() {
    let dir = tempfile::tempdir().unwrap();
    let config = dir.path().join("later/cmux.json");
    let store = Arc::new(Mutex::new(open(&config, dir.path(), Default::default())));
    let (sender, receiver) = channel();
    let watcher = watch_store(Arc::clone(&store), move |change| {
        let _ = sender.send(change);
    })
    .unwrap();
    std::fs::create_dir_all(config.parent().unwrap()).unwrap();
    std::fs::write(&config, "{\"ui\": {\"animationSpeed\": \"off\"}}").unwrap();
    let change =
        receiver.recv_timeout(Duration::from_secs(20)).expect("a change after the file appeared");
    assert_eq!(change.origin, Origin::File);
    assert!(change.keys.contains(&"ui.animationSpeed".to_string()));
    // Atomic rename over the file, as editors save.
    let temp = config.with_file_name(".cmux.json.tmp");
    std::fs::write(&temp, "{\"ui\": {\"animationSpeed\": \"fast\"}}").unwrap();
    std::fs::rename(&temp, &config).unwrap();
    let mut seen =
        receiver.recv_timeout(Duration::from_secs(20)).expect("a change after the rename");
    while store.lock().unwrap().state().effective().root.pointer("/ui/animationSpeed")
        != Some(&json!("fast"))
    {
        seen = receiver.recv_timeout(Duration::from_secs(20)).expect("the rename becomes visible");
    }
    assert_eq!(seen.origin, Origin::File);
    drop(watcher);
}

#[test]
fn the_team_policy_survives_a_restart() {
    let dir = tempfile::tempdir().unwrap();
    let config = dir.path().join("cmux.json");
    let layer = cmux_config::TeamPolicyLayer {
        team_name: "Acme".into(),
        team_id: "team_1".into(),
        version: 3,
        enforced: [("ui.animationSpeed".to_string(), json!("off"))].into_iter().collect(),
        ..Default::default()
    };
    let mut store = open(&config, dir.path(), Default::default());
    store.apply(cmux_config::Op::TeamPolicySet { layer: layer.clone() }).result.unwrap();
    drop(store);
    // A restarted owner enforces the saved layer before the app sends it again.
    let mut restarted = open(&config, dir.path(), Default::default());
    assert_eq!(restarted.state().team(), &layer);
    assert_eq!(cache(dir.path())["effective"]["ui"]["animationSpeed"], json!("off"));
    let refusal = restarted.apply(set("ui.animationSpeed", json!("fast"))).result.unwrap_err();
    assert_eq!(refusal.code(), "managed");
    // Clearing the layer removes the saved file.
    restarted.apply(cmux_config::Op::TeamPolicySet { layer: Default::default() }).result.unwrap();
    drop(restarted);
    let cleared = open(&config, dir.path(), Default::default());
    assert_eq!(cleared.state().team(), &cmux_config::TeamPolicyLayer::default());
}
