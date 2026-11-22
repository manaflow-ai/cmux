//! Tests for atomic config file writes.

use super::*;

#[test]
fn sidebar_plugin_write_preserves_unrelated_config_keys() {
    let dir = std::env::temp_dir().join(format!(
        "mux-config-write-test-{}-{}",
        std::process::id(),
        SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
    ));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("mux.json");
    std::fs::write(
        &path,
        r#"{
            "theme": {"sidebar_rail": 42},
            "sidebar": {"width": 31},
            "future": {"unknown": true}
        }"#,
    )
    .unwrap();

    assert_committed(
        write_sidebar_plugin_at_path(
            &path,
            Some(&SidebarPluginConfig {
                command: vec!["/tmp/plugin".to_string(), "--mode".to_string(), "test".to_string()],
                cwd: Some("/tmp".to_string()),
            }),
        )
        .unwrap(),
    );
    let value: Value = serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
    assert_eq!(value["theme"]["sidebar_rail"], json!(42));
    assert_eq!(value["sidebar"]["width"], json!(31));
    assert_eq!(value["future"]["unknown"], json!(true));
    assert_eq!(value["sidebar"]["plugin"]["command"][0], json!("/tmp/plugin"));
    assert_eq!(value["sidebar"]["plugin"]["cwd"], json!("/tmp"));

    assert_committed(write_sidebar_plugin_at_path(&path, None).unwrap());
    let value: Value = serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
    assert_eq!(value["sidebar"]["width"], json!(31));
    assert!(value["sidebar"].get("plugin").is_none());
    assert_eq!(value["future"]["unknown"], json!(true));
    let _ = std::fs::remove_dir_all(&dir);
}

#[cfg(unix)]
#[test]
fn sidebar_plugin_write_replaces_config_with_private_permissions() {
    use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};

    let dir = TestDirectory::new("private-permissions");
    let path = dir.path.join("cmux-tui.json");
    let mut options = OpenOptions::new();
    options.write(true).create_new(true).mode(0o644);
    let file = options.open(&path).unwrap();
    drop(file);

    assert_committed(
        write_sidebar_plugin_at_path(
            &path,
            Some(&SidebarPluginConfig { command: vec!["/tmp/plugin".to_string()], cwd: None }),
        )
        .unwrap(),
    );

    let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode, 0o600, "config permissions must not expose server.ws_token");
}

#[test]
fn config_write_failure_cleans_staging_file() {
    let dir = TestDirectory::new("failure-cleanup");
    let path = dir.path.join("cmux-tui.json");
    std::fs::create_dir(&path).unwrap();

    let error = write_config_value_atomic(&path, &json!({"server": {"ws_token": "secret"}}))
        .expect_err("replacing a directory must fail");
    assert!(!error.to_string().is_empty());

    let entries = std::fs::read_dir(&dir.path).unwrap().collect::<Result<Vec<_>, _>>().unwrap();
    assert_eq!(entries.len(), 1, "failed writes must remove their staging file");
    assert_eq!(entries[0].path(), path);
}

#[test]
fn config_write_collision_preserves_existing_staging_file() {
    let dir = TestDirectory::new("staging-collision");
    let path = dir.path.join("cmux-tui.json");
    let collision = dir.path.join("collision.tmp");
    let replacement = dir.path.join("replacement.tmp");
    std::fs::write(&collision, b"owned by another writer").unwrap();
    let staging_paths = [collision.clone(), replacement.clone()];
    let staging_path = |_: &Path, attempt: usize| staging_paths[attempt].clone();
    let sync_parent = |_parent: &Path| -> anyhow::Result<ConfigParentSyncOutcome> {
        Ok(ConfigParentSyncOutcome::Synced)
    };

    assert_committed(
        write_config_value_atomic_with_sync_and_staging(
            &path,
            &json!({"server": {"ws_token": "secret"}}),
            &sync_parent,
            &staging_path,
        )
        .expect("a colliding staging path should be retried"),
    );
    assert_eq!(std::fs::read(&collision).unwrap(), b"owned by another writer");
    assert!(!replacement.exists(), "the successful staging file must be renamed");
}

#[test]
fn config_parent_creation_handles_absolute_path_syntax() {
    let dir = TestDirectory::new("absolute-parent");
    let parent = dir.path.join("nested").join("config");

    let created = ensure_config_parent_directory(&parent).unwrap();

    assert!(parent.is_dir());
    assert!(created.iter().any(|directory| directory == &parent));
}

#[test]
fn config_parent_directory_normalizes_relative_path() {
    assert_eq!(config_parent_directory(Path::new("cmux-tui.json")), Path::new("."));
    assert_eq!(config_parent_directory(Path::new("nested/cmux-tui.json")), Path::new("nested"));
}

#[test]
fn config_write_succeeds_after_parent_directory_sync() {
    let dir = TestDirectory::new("parent-sync");
    let path = dir.path.join("cmux-tui.json");
    assert_committed(
        write_config_value_atomic(&path, &json!({"server": {"ws_token": "secret"}})).unwrap(),
    );

    let value: Value = serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
    assert_eq!(value["server"]["ws_token"], json!("secret"));
}

#[cfg(unix)]
#[test]
fn config_write_does_not_report_failure_after_parent_sync_error() {
    let dir = TestDirectory::new("parent-sync-failure");
    let path = dir.path.join("cmux-tui.json");
    let sync_parent = |_parent: &Path| -> anyhow::Result<ConfigParentSyncOutcome> {
        Err(anyhow::anyhow!("injected parent directory sync failure"))
    };

    let result = write_config_value_atomic_with_sync(
        &path,
        &json!({"server": {"ws_token": "secret"}}),
        &sync_parent,
    );

    assert!(matches!(
        result.expect("a committed rename must not be reported as a write failure"),
        ConfigWriteOutcome::CommittedButUnsynced { .. }
    ));
    let value: Value = serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
    assert_eq!(value["server"]["ws_token"], json!("secret"));
}

#[cfg(target_os = "macos")]
#[test]
fn config_write_does_not_warn_for_unsupported_parent_sync() {
    let dir = TestDirectory::new("unsupported-parent-sync");
    let path = dir.path.join("cmux-tui.json");
    let sync_parent = |_parent: &Path| -> anyhow::Result<ConfigParentSyncOutcome> {
        Ok(ConfigParentSyncOutcome::Unsupported)
    };

    let outcome = write_config_value_atomic_with_sync(
        &path,
        &json!({"server": {"ws_token": "secret"}}),
        &sync_parent,
    )
    .expect("a committed rename must not be reported as a write failure");
    assert!(matches!(&outcome, ConfigWriteOutcome::CommittedWithoutDirectorySync));
    assert!(outcome.into_unsynced_error().is_none());
}

#[cfg(unix)]
#[test]
fn config_write_syncs_parents_of_new_directories() {
    let dir = TestDirectory::new("created-parent-sync");
    let parent = dir.path.join("new").join("nested");
    let path = parent.join("cmux-tui.json");
    let synced = RefCell::new(Vec::new());
    let sync_parent = |directory: &Path| -> anyhow::Result<ConfigParentSyncOutcome> {
        synced.borrow_mut().push(directory.to_path_buf());
        Ok(ConfigParentSyncOutcome::Synced)
    };

    assert_committed(
        write_config_value_atomic_with_sync(
            &path,
            &json!({"server": {"ws_token": "secret"}}),
            &sync_parent,
        )
        .unwrap(),
    );

    let synced = synced.into_inner();
    assert!(synced.iter().any(|directory| directory == &parent));
    assert!(synced.iter().any(|directory| directory == &dir.path));
}
