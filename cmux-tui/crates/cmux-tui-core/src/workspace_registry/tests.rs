use super::*;
use crate::resource::FrontendProjectionPublicId;
use std::sync::Arc;

const TERMINAL_ONE: &str = "00000000000040008000000000000001";
const TERMINAL_TWO: &str = "00000000000040008000000000000002";
const INCARNATION_ONE: &str = "10000000000040008000000000000001";
use serde_json::json;

fn temp_root(label: &str) -> PathBuf {
    std::env::temp_dir().join(format!("cmux-registry-{label}-{}", new_uuid_v4()))
}

fn workspace(id: u64, key: &str, name: &str) -> RegistryWorkspace {
    RegistryWorkspace {
        id,
        public_id: WorkspacePublicId::parse(format!("ws_{id:032x}")).unwrap(),
        key: key.into(),
        name: name.into(),
        group_key: "default".into(),
    }
}

fn seed_workspace(registry: &mut WorkspaceRegistry, key: &str) {
    let revision = registry.snapshot().unwrap().revision;
    registry
        .commit(
            &WorkspaceMutation::new(format!("create-{key}"), "test").unwrap(),
            &json!({"op":"create","key":key}),
            None,
            Some(revision),
            "workspace-added",
            key,
            &[workspace(revision + 1, key, "Workspace")],
            &json!({"key":key}),
        )
        .unwrap();
}

#[test]
fn interrupted_staged_workspace_keeps_reserved_public_id_without_early_publication() {
    let root = temp_root("interrupted-workspace-public-id");
    let key = "018f6e21-7b70-7e70-8000-0000000000aa";
    let public_id =
        WorkspacePublicId::parse("ws_018f6e217b707e7080000000000000aa".to_string()).unwrap();
    let fingerprint = json!({"operation":"workspace.create"});
    let intent = json!({
        "workspace_reservation":{
            "workspace_key":key,
            "workspace_public_id":public_id,
        },
        "terminal_reservation":{
            "terminal_id":"018f6e217b707e7080000000000000ab",
        },
    });
    {
        let mut registry = WorkspaceRegistry::open(&root, "interrupted-public-id").unwrap();
        registry
            .prepare_resource_creation(
                "interrupted-public-id-correlation",
                "interrupted-public-id-attempt",
                "workspace.create",
                &fingerprint,
                &intent,
                true,
                None,
                None,
            )
            .unwrap();
        registry
            .mark_resource_effect_executing(
                "interrupted-public-id-attempt",
                "workspace.create",
                &fingerprint,
            )
            .unwrap();
        let staged = RegistryWorkspace {
            id: 1,
            public_id: public_id.clone(),
            key: key.to_string(),
            name: "Reserved workspace".to_string(),
            group_key: "interrupted-public-id".to_string(),
        };
        registry
            .commit_for_resource_effect(
                &WorkspaceMutation::new("interrupted-public-id-workspace", "resource-api").unwrap(),
                &json!({"operation":"workspace.create","workspace_key":key}),
                None,
                None,
                "workspace-added",
                key,
                std::slice::from_ref(&staged),
                Some(&public_id),
                &json!({"workspace":1,"workspace_id":public_id,"key":key,"index":0}),
            )
            .unwrap();
        let public = registry.resource_topology_snapshot().unwrap();
        assert_eq!(public.revision, 0);
        assert!(public.active_screens.is_empty());
        assert_eq!(public.active_workspace, None);
    }

    let registry = WorkspaceRegistry::open(&root, "interrupted-public-id").unwrap();
    let staged = registry.interrupted_resource_workspaces().unwrap();
    assert_eq!(staged.len(), 1);
    assert_eq!(staged[0].1.public_id, public_id);
    assert_eq!(staged[0].1.key, key);
    let public = registry.resource_topology_snapshot().unwrap();
    assert_eq!(public.revision, 0);
    assert!(public.active_screens.is_empty());
    assert_eq!(public.active_workspace, None);
    drop(registry);
    fs::remove_dir_all(root).unwrap();
}

#[cfg(any(target_os = "ios", target_os = "macos", target_os = "linux", target_os = "android"))]
#[test]
fn reset_keeps_selected_session_guard_file() {
    let root = temp_root("reset-keeps-session-guard");
    let session = "reset-keeps-session-guard";
    drop(WorkspaceRegistry::open(&root, session).unwrap());
    let guard_path = session_guard_lock_path(&root.join(SESSION_GUARD_DIR), session);
    assert!(guard_path.exists(), "open did not create a session guard");

    let resetter = PersistentSessionStateResetter::new(root.clone());
    let preview = resetter.preview(session).unwrap();
    assert_eq!(preview.state_root, root);
    assert_eq!(preview.session_dir, resetter.session_dir(session));
    assert_eq!(resetter.state_root(), root.as_path());
    let reset = resetter.reset(session, Some(&preview.confirm_reset)).unwrap();

    assert!(reset.removed_session_state);
    assert!(guard_path.exists(), "reset removed an unpreviewed session guard");
    fs::remove_dir_all(root).unwrap();
}

#[cfg(unix)]
#[test]
fn reset_manifest_path_key_preserves_invalid_utf8_bytes() {
    use std::os::unix::ffi::OsStrExt;

    let first = Path::new(std::ffi::OsStr::from_bytes(b"\xff"));
    let second = Path::new(std::ffi::OsStr::from_bytes(b"\xfe"));

    assert_eq!(first.display().to_string(), second.display().to_string());
    assert_ne!(reset_manifest_path_key(first), reset_manifest_path_key(second));
}

#[cfg(any(target_os = "ios", target_os = "macos", target_os = "linux", target_os = "android"))]
#[test]
fn reset_does_not_restrict_supplied_state_root() {
    use std::os::unix::fs::PermissionsExt;

    let root = temp_root("reset-preserves-state-root-mode");
    let session = "reset-preserves-state-root-mode";
    fs::create_dir_all(&root).unwrap();
    fs::set_permissions(&root, fs::Permissions::from_mode(0o755)).unwrap();
    let resetter = PersistentSessionStateResetter::new(root.clone());
    let session_dir = resetter.session_dir(session);
    fs::create_dir_all(&session_dir).unwrap();
    fs::write(session_dir.join(WORKSPACE_REGISTRY_FILE), b"db").unwrap();
    fs::write(session_dir.join(SESSION_WRITER_LOCK_FILE), b"").unwrap();
    let before_mode = fs::metadata(&root).unwrap().permissions().mode() & 0o777;

    let preview = resetter.preview(session).unwrap();
    let reset = resetter.reset(session, Some(&preview.confirm_reset)).unwrap();

    assert!(reset.removed_session_state);
    assert_eq!(before_mode, 0o755);
    assert_eq!(fs::metadata(&root).unwrap().permissions().mode() & 0o777, before_mode);
    fs::remove_dir_all(root).unwrap();
}

#[cfg(any(target_os = "ios", target_os = "macos", target_os = "linux", target_os = "android"))]
#[test]
fn reset_accepts_restored_session_without_writer_lock() {
    let root = temp_root("reset-restored-without-writer-lock");
    let session = "reset-restored-without-writer-lock";
    let resetter = PersistentSessionStateResetter::new(root.clone());
    let session_dir = resetter.session_dir(session);
    fs::create_dir_all(&session_dir).unwrap();
    fs::write(session_dir.join(WORKSPACE_REGISTRY_FILE), b"db").unwrap();
    let writer_lock = session_dir.join(SESSION_WRITER_LOCK_FILE);
    assert!(!writer_lock.exists());

    let preview = resetter.preview(session).unwrap();
    let reset = resetter.reset(session, Some(&preview.confirm_reset)).unwrap();

    assert!(reset.removed_session_state);
    assert!(!session_dir.exists(), "reset left restored session state behind");
    fs::remove_dir_all(root).unwrap();
}

#[cfg(any(target_os = "ios", target_os = "macos", target_os = "linux", target_os = "android"))]
#[test]
fn reset_refuses_restored_session_when_legacy_writer_lock_is_busy() {
    let root = temp_root("reset-restored-writer-lock-busy");
    let session = "reset-restored-writer-lock-busy";
    let resetter = PersistentSessionStateResetter::new(root.clone());
    let session_dir = resetter.session_dir(session);
    fs::create_dir_all(&session_dir).unwrap();
    fs::write(session_dir.join(WORKSPACE_REGISTRY_FILE), b"db").unwrap();
    let writer_lock = session_dir.join(SESSION_WRITER_LOCK_FILE);
    assert!(!writer_lock.exists());
    let preview = resetter.preview(session).unwrap();
    let _legacy_owner = SessionLease::acquire(&writer_lock).unwrap();

    let error = resetter.reset(session, Some(&preview.confirm_reset)).unwrap_err();

    assert!(error.to_string().contains("already owned by another daemon"), "{error:#}");
    assert!(session_dir.exists(), "reset deleted state owned by a legacy writer");
    assert!(writer_lock.exists(), "reset removed the busy writer lock");
    fs::remove_dir_all(root).unwrap();
}

#[cfg(any(target_os = "ios", target_os = "macos", target_os = "linux", target_os = "android"))]
#[test]
fn reset_rejects_session_dir_recreated_after_staging() {
    let root = temp_root("reset-recreated-after-staging");
    let session = "reset-recreated-after-staging";
    let resetter = PersistentSessionStateResetter::new(root.clone());
    let session_dir = resetter.session_dir(session);
    fs::create_dir_all(&session_dir).unwrap();
    fs::write(session_dir.join(WORKSPACE_REGISTRY_FILE), b"db").unwrap();
    let preview = resetter.preview(session).unwrap();
    *RESET_RECREATE_SESSION_DIR_AFTER_STAGING.lock().unwrap() = Some(session_dir.clone());

    let error = resetter.reset(session, Some(&preview.confirm_reset)).unwrap_err();

    assert!(error.to_string().contains("reset path changed during reset"), "{error:#}");
    assert!(session_dir.exists(), "reset removed recreated session state");
    assert_eq!(fs::read(session_dir.join("recreated-sidecar")).unwrap(), b"new");
    fs::remove_dir_all(root).unwrap();
}

#[cfg(any(target_os = "ios", target_os = "macos", target_os = "linux", target_os = "android"))]
#[test]
fn reset_accepts_partial_session_without_registry() {
    use std::os::unix::fs::PermissionsExt;

    let root = temp_root("reset-partial-without-registry");
    let session = "reset-partial-without-registry";
    let resetter = PersistentSessionStateResetter::new(root.clone());
    let session_dir = resetter.session_dir(session);
    fs::create_dir_all(&session_dir).unwrap();
    fs::write(session_dir.join("partial-sidecar"), b"partial").unwrap();
    let host_root = crate::terminal_host_runtime::terminal_host_root(&root, session);
    fs::create_dir_all(&host_root).unwrap();
    fs::set_permissions(&host_root, fs::Permissions::from_mode(0o700)).unwrap();
    fs::write(host_root.join("stale-host-sidecar"), b"stale").unwrap();

    let preview = resetter.preview(session).unwrap();
    let reset = resetter.reset(session, Some(&preview.confirm_reset)).unwrap();

    assert!(reset.removed_session_state);
    assert!(reset.removed_terminal_hosts);
    assert!(!session_dir.exists());
    assert!(!host_root.exists());
    fs::remove_dir_all(root).unwrap();
}

#[cfg(any(target_os = "ios", target_os = "macos", target_os = "linux", target_os = "android"))]
#[test]
fn reset_keeps_staged_dir_when_private_rename_sync_fails() {
    let root = temp_root("reset-rename-sync-fails");
    let session = "reset-rename-sync-fails";
    let resetter = PersistentSessionStateResetter::new(root.clone());
    let session_dir = resetter.session_dir(session);
    fs::create_dir_all(&session_dir).unwrap();
    fs::write(session_dir.join(WORKSPACE_REGISTRY_FILE), b"db").unwrap();
    fs::write(session_dir.join("sidecar"), b"previewed").unwrap();
    let preview = resetter.preview(session).unwrap();
    *RESET_RENAME_SYNC_FAILURE_ROOT.lock().unwrap() = Some(root.clone());

    let error = resetter.reset(session, Some(&preview.confirm_reset)).unwrap_err();

    assert!(error.to_string().contains("private reset rename sync failure"), "{error:#}");
    assert!(!session_dir.exists(), "sync failure should leave the staged private path");
    let pending = pending_session_reset_dirs(&root, session).unwrap();
    assert_eq!(pending.len(), 1);
    assert_eq!(pending[0].kind, PendingSessionResetKind::Session);
    assert!(pending[0].path.join(WORKSPACE_REGISTRY_FILE).exists());
    assert_eq!(fs::read(pending[0].path.join("sidecar")).unwrap(), b"previewed");
    fs::remove_dir_all(root).unwrap();
}

#[cfg(unix)]
#[test]
fn reset_delete_rejects_file_added_after_manifest_check() {
    let root = temp_root("reset-delete-rejects-late-file");
    let session = "reset-delete-rejects-late-file";
    let resetter = PersistentSessionStateResetter::new(root.clone());
    let session_dir = resetter.session_dir(session);
    fs::create_dir_all(&session_dir).unwrap();
    fs::write(session_dir.join(WORKSPACE_REGISTRY_FILE), b"db").unwrap();
    let expected_fingerprint =
        session_reset_target_fingerprint(&session_dir, &mut ResetFingerprintBudget::default())
            .unwrap();
    let late = session_dir.join("aaa-late");
    *RESET_DELETE_AFTER_MANIFEST_FILE.lock().unwrap() = Some((session_dir.clone(), late.clone()));

    let error = remove_reset_dir_all(
        &session_dir,
        "workspace session state",
        "session",
        &expected_fingerprint,
    )
    .unwrap_err();

    assert!(error.to_string().contains("reset path changed during reset"), "{error:#}");
    assert_eq!(fs::read(late).unwrap(), b"late");
    fs::remove_dir_all(root).unwrap();
}

#[cfg(unix)]
#[test]
fn reset_delete_rejects_child_replaced_after_verification() {
    let root = temp_root("reset-delete-rejects-replaced-child");
    let session = "reset-delete-rejects-replaced-child";
    let resetter = PersistentSessionStateResetter::new(root.clone());
    let session_dir = resetter.session_dir(session);
    fs::create_dir_all(&session_dir).unwrap();
    fs::write(session_dir.join(WORKSPACE_REGISTRY_FILE), b"db").unwrap();
    let target = session_dir.join("replace-after-verify");
    fs::write(&target, b"previewed").unwrap();
    let expected_fingerprint =
        session_reset_target_fingerprint(&session_dir, &mut ResetFingerprintBudget::default())
            .unwrap();
    *RESET_DELETE_AFTER_CHILD_VERIFY_FILE.lock().unwrap() = Some(target.clone());

    let error = remove_reset_dir_all(
        &session_dir,
        "workspace session state",
        "session",
        &expected_fingerprint,
    )
    .unwrap_err();

    assert!(error.to_string().contains("reset path changed during reset"), "{error:#}");
    assert_eq!(fs::read(&target).unwrap(), b"replacement");
    fs::remove_dir_all(root).unwrap();
}

#[cfg(unix)]
#[test]
fn reset_dir_child_names_rewinds_between_scans() {
    use std::os::unix::fs::OpenOptionsExt;

    let root = temp_root("reset-child-name-rewind");
    fs::create_dir_all(&root).unwrap();
    fs::write(root.join("child"), b"confirmed").unwrap();
    let directory = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_CLOEXEC | libc::O_DIRECTORY | libc::O_NOFOLLOW)
        .open(&root)
        .unwrap();

    let first = reset_dir_child_names(&directory, &root, "workspace session state").unwrap();
    let second = reset_dir_child_names(&directory, &root, "workspace session state").unwrap();

    assert_eq!(first, vec![std::ffi::OsString::from("child")]);
    assert_eq!(second, vec![std::ffi::OsString::from("child")]);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn unsupported_checked_reset_deletion_does_not_mutate_tree() {
    let root = temp_root("reset-unsupported-platform-delete");
    let target = root.join("session");
    let child = target.join("child");
    fs::create_dir_all(&target).unwrap();
    fs::write(&child, b"must-remain").unwrap();

    let error = unsupported_checked_reset_deletion(&target, "workspace session state").unwrap_err();

    assert!(error.to_string().contains("safe saved-state reset is not supported"), "{error:#}");
    assert_eq!(fs::read(&child).unwrap(), b"must-remain");
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn reset_unsupported_checked_deletion_fails_before_staging_session_dir() {
    let root = temp_root("reset-unsupported-before-staging");
    let session = "reset-unsupported-before-staging";
    let resetter = PersistentSessionStateResetter::new(root.clone());
    let session_dir = resetter.session_dir(session);
    fs::create_dir_all(&session_dir).unwrap();
    fs::write(session_dir.join(WORKSPACE_REGISTRY_FILE), b"db").unwrap();
    let preview = resetter.preview(session).unwrap();
    *RESET_UNSUPPORTED_CHECKED_DELETION_ROOT.lock().unwrap() = Some(root.clone());

    let error = resetter.reset(session, Some(&preview.confirm_reset)).unwrap_err();

    assert!(error.to_string().contains("safe saved-state reset is not supported"), "{error:#}");
    assert!(session_dir.exists(), "reset moved the session dir before platform support failed");
    assert!(session_dir.join(WORKSPACE_REGISTRY_FILE).exists());
    assert!(pending_session_reset_dirs(&root, session).unwrap().is_empty());
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn reset_device_boundary_rejects_nested_device_change() {
    let error = ensure_reset_device_boundary(Path::new("nested"), Some(1), Some(2)).unwrap_err();

    assert!(error.to_string().contains("filesystem boundary"));
    ensure_reset_device_boundary(Path::new("nested"), Some(1), Some(1)).unwrap();
    ensure_reset_device_boundary(Path::new("nested"), None, Some(2)).unwrap();
}

#[cfg(any(target_os = "ios", target_os = "macos", target_os = "linux", target_os = "android"))]
#[test]
fn reset_retries_previous_private_deletion_dir() {
    let root = temp_root("reset-retries-private-delete");
    let session = "reset-retries-private-delete";
    fs::create_dir_all(&root).unwrap();
    let pending_reset_dir = root.join(format!(
        ".reset-{}-session-{}.deleting",
        session_storage_component(session),
        new_uuid_v4()
    ));
    fs::create_dir_all(pending_reset_dir.join("nested")).unwrap();
    fs::write(pending_reset_dir.join("nested").join("saved-state"), b"old").unwrap();

    let resetter = PersistentSessionStateResetter::new(root.clone());
    let preview = resetter.preview(session).unwrap();
    assert_eq!(preview.pending_reset_dirs, vec![pending_reset_dir.clone()]);
    let reset = resetter.reset(session, Some(&preview.confirm_reset)).unwrap();

    assert!(reset.removed_session_state);
    assert!(!pending_reset_dir.exists(), "reset left a private deletion dir behind");
    fs::remove_dir_all(root).unwrap();
}

#[cfg(any(target_os = "ios", target_os = "macos", target_os = "linux", target_os = "android"))]
#[test]
fn reset_retries_previous_terminal_host_deletion_dir_as_terminal_hosts() {
    let root = temp_root("reset-retries-terminal-host-private-delete");
    let session = "reset-retries-terminal-host-private-delete";
    fs::create_dir_all(&root).unwrap();
    let pending_reset_dir = root.join(format!(
        ".reset-{}-terminal-hosts-{}.deleting",
        session_storage_component(session),
        new_uuid_v4()
    ));
    fs::create_dir_all(pending_reset_dir.join("nested")).unwrap();
    fs::write(pending_reset_dir.join("nested").join("terminal-host-state"), b"old").unwrap();

    let resetter = PersistentSessionStateResetter::new(root.clone());
    let preview = resetter.preview(session).unwrap();
    assert_eq!(preview.pending_reset_dirs, vec![pending_reset_dir.clone()]);
    let reset = resetter.reset(session, Some(&preview.confirm_reset)).unwrap();

    assert!(!reset.removed_session_state);
    assert!(reset.removed_terminal_hosts);
    assert!(!pending_reset_dir.exists(), "reset left a terminal-host deletion dir behind");
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn reset_preserves_invalid_lookalike_private_deletion_dir() {
    let root = temp_root("reset-preserves-invalid-private-delete");
    let session = "reset-preserves-invalid-private-delete";
    fs::create_dir_all(&root).unwrap();
    let lookalike = root
        .join(format!(".reset-{}-session-not-a-uuid.deleting", session_storage_component(session)));
    fs::create_dir_all(&lookalike).unwrap();
    fs::write(lookalike.join("unrelated"), b"keep").unwrap();

    let resetter = PersistentSessionStateResetter::new(root.clone());
    let preview = resetter.preview(session).unwrap();
    assert!(preview.pending_reset_dirs.is_empty());
    let reset = resetter.reset(session, Some(&preview.confirm_reset)).unwrap();

    assert!(!reset.removed_session_state);
    assert!(!reset.removed_terminal_hosts);
    assert!(lookalike.join("unrelated").exists(), "reset removed an invalid look-alike path");
    fs::remove_dir_all(root).unwrap();
}

#[cfg(unix)]
#[test]
fn reset_rejects_same_file_rewrite_with_restored_mtime() {
    let root = temp_root("reset-restored-mtime");
    let session = "reset-restored-mtime";
    drop(WorkspaceRegistry::open(&root, session).unwrap());
    let resetter = PersistentSessionStateResetter::new(root.clone());
    let session_dir = resetter.session_dir(session);
    let target = session_dir.join("sidecar");
    fs::write(&target, b"expected").unwrap();
    let before = fs::metadata(&target).unwrap();
    let before_modified = before.modified().unwrap();
    let preview = resetter.preview(session).unwrap();

    let mut file = OpenOptions::new().write(true).truncate(true).open(&target).unwrap();
    file.write_all(b"mutated!").unwrap();
    file.sync_all().unwrap();
    file.set_times(fs::FileTimes::new().set_modified(before_modified)).unwrap();
    let after = file.metadata().unwrap();
    assert_eq!(metadata_identity(&after), metadata_identity(&before));
    drop(file);

    let error = resetter.reset(session, Some(&preview.confirm_reset)).unwrap_err();

    assert!(error.to_string().contains("reset confirmation is required"));
    assert_eq!(fs::read(&target).unwrap(), b"mutated!");
    fs::remove_dir_all(root).unwrap();
}

#[cfg(unix)]
#[test]
fn reset_errors_when_state_root_cannot_be_inspected() {
    use std::os::unix::fs::PermissionsExt;

    let root = temp_root("reset-inaccessible-root");
    let blocked_parent = root.join("blocked");
    let state_root = blocked_parent.join("state");
    fs::create_dir_all(&state_root).unwrap();
    fs::set_permissions(&blocked_parent, fs::Permissions::from_mode(0o000)).unwrap();

    let resetter = PersistentSessionStateResetter::new(state_root);
    let error = resetter.reset("reset-inaccessible-root", Some("unused")).unwrap_err();

    fs::set_permissions(&blocked_parent, fs::Permissions::from_mode(0o755)).unwrap();
    assert!(error.to_string().contains("inspect workspace state root"));
    fs::remove_dir_all(root).unwrap();
}

#[cfg(unix)]
#[test]
fn reset_rejects_symlinked_state_root() {
    use std::os::unix::fs::symlink;

    let real_root = temp_root("reset-symlink-real-root");
    let linked_root = temp_root("reset-symlink-linked-root");
    let session = "reset-symlinked-state-root";
    let resetter = PersistentSessionStateResetter::new(linked_root.clone());
    let session_dir = real_root.join(session_storage_component(session));
    fs::create_dir_all(&session_dir).unwrap();
    fs::write(session_dir.join(WORKSPACE_REGISTRY_FILE), b"db").unwrap();
    symlink(&real_root, &linked_root).unwrap();

    let preview_error = resetter.preview(session).unwrap_err();
    let reset_error = resetter.reset(session, Some("unused")).unwrap_err();

    assert!(preview_error.to_string().contains("workspace state root must not be a symbolic link"));
    assert!(reset_error.to_string().contains("workspace state root must not be a symbolic link"));
    assert!(session_dir.exists(), "reset touched the symlink target");
    fs::remove_file(linked_root).unwrap();
    fs::remove_dir_all(real_root).unwrap();
}

#[cfg(unix)]
#[test]
fn terminal_host_reset_holds_structured_live_marker_lock() {
    use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};

    let root = temp_root("terminal-host-reset-holds-live-lock");
    fs::create_dir_all(&root).unwrap();
    fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
    let uid = fs::metadata(&root).unwrap().uid();
    let terminal_id = TERMINAL_ONE;
    let incarnation = INCARNATION_ONE;
    let host_start_nonce = "02".repeat(32);
    let record = crate::terminal_host_runtime::TerminalHostRecord {
        record_version: 2,
        terminal_id: terminal_id.to_string(),
        incarnation: incarnation.to_string(),
        endpoint: format!("/tmp/cmux-th-{uid}/{terminal_id}.sock"),
        owner_token: "01".repeat(32),
        host_pid: std::process::id(),
        host_start_nonce,
        workspace_key: String::new(),
        supports_set_defaults: true,
        supports_clear_history: true,
        supports_terminate_ack: false,
    };
    let record_path = record.record_path(&root);
    let live_path = terminal_host_live_marker_path(&record_path, &record);
    let _live_file = OpenOptions::new()
        .read(true)
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&live_path)
        .unwrap();
    let mut record_file =
        OpenOptions::new().write(true).create_new(true).mode(0o600).open(&record_path).unwrap();
    record_file.write_all(&serde_json::to_vec(&record).unwrap()).unwrap();
    record_file.sync_all().unwrap();

    let leases = prepare_terminal_host_root_for_reset(&root).unwrap();
    assert_eq!(
        crate::terminal_host_runtime::terminal_host_record_liveness(&record_path, &record).unwrap(),
        TerminalHostLiveness::Live,
        "reset must hold the structured live-marker lock until directory removal"
    );
    drop(leases);
    assert_eq!(
        crate::terminal_host_runtime::terminal_host_record_liveness(&record_path, &record).unwrap(),
        TerminalHostLiveness::Dead
    );

    fs::remove_dir_all(root).unwrap();
}

#[cfg(unix)]
#[test]
fn terminal_host_reset_refuses_busy_live_marker() {
    use std::os::fd::AsRawFd;
    use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};

    let root = temp_root("terminal-host-reset-refuses-busy-live-marker");
    fs::create_dir_all(&root).unwrap();
    fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
    let uid = fs::metadata(&root).unwrap().uid();
    let live_path = root.join("orphan.live");
    let live_file = OpenOptions::new()
        .read(true)
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&live_path)
        .unwrap();
    // SAFETY: flock only changes the advisory lock on this valid test file descriptor.
    assert_eq!(unsafe { libc::flock(live_file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) }, 0);

    assert!(matches!(
        lock_verified_dead_live_marker(&root.join("missing.live"), uid).unwrap(),
        TerminalHostLiveMarkerLock::Missing
    ));
    assert!(matches!(
        lock_verified_dead_live_marker(&live_path, uid).unwrap(),
        TerminalHostLiveMarkerLock::Unsafe
    ));
    let error = match prepare_terminal_host_root_for_reset(&root) {
        Ok(_) => panic!("reset accepted a busy live marker"),
        Err(error) => error,
    };

    assert!(error.to_string().contains("live or unverified hosts"), "{error:#}");
    assert!(live_path.exists(), "reset removed a busy live marker");
    drop(live_file);
    fs::remove_dir_all(root).unwrap();
}

#[cfg(unix)]
#[test]
fn terminal_host_reset_checks_legacy_live_marker_as_orphan() {
    use std::os::fd::AsRawFd;
    use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};

    let root = temp_root("terminal-host-reset-legacy-marker");
    fs::create_dir_all(&root).unwrap();
    fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
    let uid = fs::metadata(&root).unwrap().uid();
    let terminal_id = TERMINAL_ONE;
    let record = crate::terminal_host_runtime::TerminalHostRecord {
        record_version: 1,
        terminal_id: terminal_id.to_string(),
        incarnation: INCARNATION_ONE.to_string(),
        endpoint: format!("/tmp/cmux-th-{uid}/{terminal_id}.sock"),
        owner_token: "01".repeat(32),
        host_pid: 0,
        host_start_nonce: String::new(),
        workspace_key: String::new(),
        supports_set_defaults: false,
        supports_clear_history: false,
        supports_terminate_ack: false,
    };
    let record_path = record.record_path(&root);
    let live_path = terminal_host_live_marker_path(&record_path, &record);
    let live_file = OpenOptions::new()
        .read(true)
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&live_path)
        .unwrap();
    // SAFETY: flock only changes the advisory lock on this valid test file descriptor.
    assert_eq!(unsafe { libc::flock(live_file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) }, 0);
    let mut record_file =
        OpenOptions::new().write(true).create_new(true).mode(0o600).open(&record_path).unwrap();
    record_file.write_all(&serde_json::to_vec(&record).unwrap()).unwrap();
    record_file.sync_all().unwrap();
    *RESET_REMOVE_LEGACY_HOST_RECORD_BEFORE_LIVENESS.lock().unwrap() = Some(record_path.clone());

    let error = match prepare_terminal_host_root_for_reset(&root) {
        Ok(_) => panic!("reset ignored a busy legacy live marker"),
        Err(error) => error,
    };
    *RESET_REMOVE_LEGACY_HOST_RECORD_BEFORE_LIVENESS.lock().unwrap() = None;

    assert!(error.to_string().contains("live or unverified hosts"), "{error:#}");
    assert!(record_path.exists(), "reset reached the liveness hook before checking the marker");
    assert!(live_path.exists(), "reset removed a busy legacy live marker");
    drop(live_file);
    fs::remove_dir_all(root).unwrap();
}

#[cfg(any(target_os = "ios", target_os = "macos", target_os = "linux", target_os = "android"))]
#[test]
fn reset_rejects_unpublished_terminal_host_publication() {
    let root = temp_root("reset-rejects-unpublished-terminal-host");
    let session = "reset-rejects-unpublished-terminal-host";
    drop(WorkspaceRegistry::open(&root, session).unwrap());
    let resetter = PersistentSessionStateResetter::new(root.clone());
    let session_dir = resetter.session_dir(session);
    let host_root = crate::terminal_host_runtime::terminal_host_root(&root, session);
    crate::terminal_host_runtime::prepare_terminal_host_publication_lock(&host_root).unwrap();
    let _publication =
        crate::terminal_host_runtime::acquire_terminal_host_publication_lock(&host_root).unwrap();

    let preview = resetter.preview(session).unwrap();
    let error = resetter.reset(session, Some(&preview.confirm_reset)).unwrap_err();

    assert!(error.to_string().contains("live or unverified hosts"), "{error:#}");
    assert!(session_dir.exists(), "reset removed session state during host publication");
    assert!(host_root.exists(), "reset removed terminal-host state during host publication");

    fs::remove_dir_all(root).unwrap();
}

#[cfg(any(target_os = "ios", target_os = "macos", target_os = "linux", target_os = "android"))]
#[test]
fn reset_refuses_unparseable_terminal_host_record() {
    use std::os::unix::fs::PermissionsExt;

    let root = temp_root("reset-refuses-unparseable-terminal-host-record");
    let session = "reset-refuses-unparseable-terminal-host-record";
    drop(WorkspaceRegistry::open(&root, session).unwrap());
    let resetter = PersistentSessionStateResetter::new(root.clone());
    let session_dir = resetter.session_dir(session);
    let host_root = crate::terminal_host_runtime::terminal_host_root(&root, session);
    fs::create_dir_all(&host_root).unwrap();
    fs::set_permissions(&host_root, fs::Permissions::from_mode(0o700)).unwrap();
    crate::terminal_host_runtime::prepare_terminal_host_publication_lock(&host_root).unwrap();
    let record_path = host_root.join(format!("{TERMINAL_ONE}.json"));
    fs::write(&record_path, b"{").unwrap();

    let preview = resetter.preview(session).unwrap();
    let error = resetter.reset(session, Some(&preview.confirm_reset)).unwrap_err();

    assert!(format!("{error:#}").contains("live or unverified hosts"), "{error:#}");
    assert!(session_dir.exists(), "reset removed the registry before host verification");
    assert!(record_path.exists(), "reset removed an unverified terminal-host record");
    fs::remove_dir_all(root).unwrap();
}

#[cfg(any(target_os = "ios", target_os = "macos", target_os = "linux", target_os = "android"))]
#[test]
fn reset_accepts_dead_v2_terminal_host_without_creating_live_marker() {
    use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};

    let root = temp_root("reset-dead-v2-host-without-marker");
    let session = "reset-dead-v2-host-without-marker";
    drop(WorkspaceRegistry::open(&root, session).unwrap());
    let resetter = PersistentSessionStateResetter::new(root.clone());
    let host_root = crate::terminal_host_runtime::terminal_host_root(&root, session);
    fs::create_dir_all(&host_root).unwrap();
    fs::set_permissions(&host_root, fs::Permissions::from_mode(0o700)).unwrap();
    crate::terminal_host_runtime::prepare_terminal_host_publication_lock(&host_root).unwrap();
    let uid = fs::metadata(&host_root).unwrap().uid();
    let terminal_id = TERMINAL_ONE;
    let record = crate::terminal_host_runtime::TerminalHostRecord {
        record_version: 2,
        terminal_id: terminal_id.to_string(),
        incarnation: INCARNATION_ONE.to_string(),
        endpoint: format!("/tmp/cmux-th-{uid}/{terminal_id}.sock"),
        owner_token: "01".repeat(32),
        host_pid: u32::MAX,
        host_start_nonce: "02".repeat(32),
        workspace_key: String::new(),
        supports_set_defaults: true,
        supports_clear_history: true,
        supports_terminate_ack: false,
    };
    let record_path = record.record_path(&host_root);
    let live_path = terminal_host_live_marker_path(&record_path, &record);
    let mut record_file =
        OpenOptions::new().write(true).create_new(true).mode(0o600).open(&record_path).unwrap();
    record_file.write_all(&serde_json::to_vec(&record).unwrap()).unwrap();
    record_file.sync_all().unwrap();

    let preview = resetter.preview(session).unwrap();
    let reset = resetter.reset(session, Some(&preview.confirm_reset)).unwrap();

    assert!(reset.removed_session_state);
    assert!(reset.removed_terminal_hosts);
    assert!(!live_path.exists(), "reset created a live marker before deletion");
    assert!(!host_root.exists());
    fs::remove_dir_all(root).unwrap();
}

#[cfg(any(target_os = "ios", target_os = "macos", target_os = "linux", target_os = "android"))]
#[test]
fn reset_terminal_host_only_state_reports_only_terminal_hosts() {
    use std::os::unix::fs::PermissionsExt;

    let root = temp_root("reset-terminal-host-only");
    let session = "reset-terminal-host-only";
    fs::create_dir_all(&root).unwrap();
    let host_root = crate::terminal_host_runtime::terminal_host_root(&root, session);
    fs::create_dir_all(&host_root).unwrap();
    fs::set_permissions(&host_root, fs::Permissions::from_mode(0o700)).unwrap();
    fs::write(host_root.join("stale-sidecar"), b"stale").unwrap();
    let resetter = PersistentSessionStateResetter::new(root.clone());

    let preview = resetter.preview(session).unwrap();
    let reset = resetter.reset(session, Some(&preview.confirm_reset)).unwrap();

    assert!(!reset.removed_session_state);
    assert!(reset.removed_terminal_hosts);
    assert!(!host_root.exists());
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn reset_preview_rejects_confirmation_manifest_path_budget() {
    let root = temp_root("reset-manifest-path-budget");
    let session = "reset-manifest-path-budget";
    let resetter = PersistentSessionStateResetter::new(root.clone());
    let session_dir = resetter.session_dir(session);
    fs::create_dir_all(&session_dir).unwrap();
    fs::write(session_dir.join(WORKSPACE_REGISTRY_FILE), b"db").unwrap();
    for index in 0..MAX_RESET_CONFIRMATION_FINGERPRINT_ENTRIES {
        fs::write(session_dir.join(format!("extra-{index}")), b"x").unwrap();
    }

    let error = resetter.preview(session).unwrap_err();

    assert!(error.to_string().contains("reset confirmation scan exceeds"), "{error:#}");
    assert!(error.to_string().contains("paths"), "{error:#}");
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn reset_preview_rejects_confirmation_manifest_byte_budget() {
    let root = temp_root("reset-manifest-byte-budget");
    let session = "reset-manifest-byte-budget";
    let resetter = PersistentSessionStateResetter::new(root.clone());
    let session_dir = resetter.session_dir(session);
    fs::create_dir_all(&session_dir).unwrap();
    fs::write(
        session_dir.join(WORKSPACE_REGISTRY_FILE),
        vec![0_u8; usize::try_from(MAX_RESET_CONFIRMATION_FINGERPRINT_BYTES).unwrap() + 1],
    )
    .unwrap();

    let error = resetter.preview(session).unwrap_err();

    assert!(error.to_string().contains("reset confirmation scan exceeds"), "{error:#}");
    assert!(error.to_string().contains("bytes"), "{error:#}");
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn reset_preview_rejects_confirmation_manifest_string_budget() {
    let root = temp_root("reset-manifest-string-budget");
    let session = "reset-manifest-string-budget";
    let resetter = PersistentSessionStateResetter::new(root.clone());
    let session_dir = resetter.session_dir(session);
    let mut nested = session_dir;
    fs::create_dir_all(&nested).unwrap();
    fs::write(nested.join(WORKSPACE_REGISTRY_FILE), b"db").unwrap();
    for index in 0..16 {
        nested = nested.join(format!("long-reset-manifest-component-{index:02}"));
        fs::create_dir_all(&nested).unwrap();
        fs::write(nested.join(format!("long-reset-manifest-leaf-{index:02}")), b"x").unwrap();
    }

    let error = resetter.preview(session).unwrap_err();

    assert!(error.to_string().contains("reset confirmation scan exceeds"), "{error:#}");
    assert!(error.to_string().contains("manifest bytes"), "{error:#}");
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn reset_private_rename_rejects_replaced_directory_fingerprint() {
    let root = temp_root("reset-rename-rejects-replacement");
    let session = "reset-rename-rejects-replacement";
    let resetter = PersistentSessionStateResetter::new(root.clone());
    let session_dir = resetter.session_dir(session);
    fs::create_dir_all(&session_dir).unwrap();
    fs::write(session_dir.join(WORKSPACE_REGISTRY_FILE), b"old").unwrap();
    let expected_fingerprint =
        session_reset_target_fingerprint(&session_dir, &mut ResetFingerprintBudget::default())
            .unwrap();

    fs::remove_dir_all(&session_dir).unwrap();
    fs::create_dir_all(&session_dir).unwrap();
    let replacement = session_dir.join("replacement");
    fs::write(&replacement, b"new").unwrap();

    let error = rename_session_dir_for_reset(&root, session, &session_dir, &expected_fingerprint)
        .unwrap_err();

    assert!(error.to_string().contains("reset path changed during reset"));
    assert!(replacement.exists(), "reset deleted the replacement directory");
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn reset_private_rename_rejects_late_nested_session_file() {
    let root = temp_root("reset-rename-rejects-late-session-file");
    let session = "reset-rename-rejects-late-session-file";
    let resetter = PersistentSessionStateResetter::new(root.clone());
    let session_dir = resetter.session_dir(session);
    let nested = session_dir.join("nested");
    fs::create_dir_all(&nested).unwrap();
    fs::write(session_dir.join(WORKSPACE_REGISTRY_FILE), b"db").unwrap();
    fs::write(nested.join("previewed"), b"old").unwrap();
    let expected_fingerprint =
        session_reset_target_fingerprint(&session_dir, &mut ResetFingerprintBudget::default())
            .unwrap();

    let late = nested.join("late-sidecar");
    fs::write(&late, b"new").unwrap();
    let error = rename_session_dir_for_reset(&root, session, &session_dir, &expected_fingerprint)
        .unwrap_err();

    assert!(error.to_string().contains("reset path changed during reset"));
    assert!(session_dir.exists(), "reset staged the changed session directory");
    assert!(late.exists(), "reset deleted an unconfirmed nested session file");
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn reset_private_rename_rejects_late_terminal_host_file() {
    let root = temp_root("reset-rename-rejects-late-terminal-host-file");
    let session = "reset-rename-rejects-late-terminal-host-file";
    let host_root = crate::terminal_host_runtime::terminal_host_root(&root, session);
    let nested = host_root.join("nested");
    fs::create_dir_all(&nested).unwrap();
    fs::write(nested.join("previewed"), b"old").unwrap();
    let expected_fingerprint =
        reset_dir_fingerprint("terminal-hosts", &host_root, &mut ResetFingerprintBudget::default())
            .unwrap();

    let late = nested.join("late-sidecar");
    fs::write(&late, b"new").unwrap();
    let error =
        rename_terminal_host_dir_for_reset(&root, session, &host_root, &expected_fingerprint)
            .unwrap_err();

    assert!(error.to_string().contains("reset path changed during reset"));
    assert!(host_root.exists(), "reset staged the changed terminal-host directory");
    assert!(late.exists(), "reset deleted an unconfirmed terminal-host file");
    fs::remove_dir_all(root).unwrap();
}

#[cfg(any(target_os = "ios", target_os = "macos", target_os = "linux", target_os = "android"))]
#[test]
fn reset_exclusive_rename_preserves_an_existing_private_target() {
    use std::ffi::OsStr;
    use std::os::fd::AsRawFd;

    let root = temp_root("reset-exclusive-rename-existing-target");
    fs::create_dir_all(&root).unwrap();
    let source = root.join("source");
    let target = root.join("target");
    fs::write(&source, b"source").unwrap();
    fs::write(&target, b"target").unwrap();
    let directory = File::open(&root).unwrap();

    let error = reset_rename_child_exclusive(
        directory.as_raw_fd(),
        OsStr::new("source"),
        OsStr::new("target"),
        &source,
        &target,
    )
    .unwrap_err();

    assert!(format!("{error:#}").contains("move reset path"));
    assert_eq!(fs::read(&source).unwrap(), b"source");
    assert_eq!(fs::read(&target).unwrap(), b"target");
    fs::remove_dir_all(root).unwrap();
}

#[cfg(unix)]
#[test]
fn reset_directory_scan_clears_stale_errno_before_readdir() {
    let root = temp_root("reset-readdir-clears-errno");
    fs::create_dir_all(&root).unwrap();
    let directory = File::open(&root).unwrap();
    set_reset_readdir_errno(libc::EIO);

    let names = reset_dir_child_names(&directory, &root, "saved state").unwrap();

    assert!(names.is_empty());
    fs::remove_dir_all(root).unwrap();
}

#[cfg(unix)]
#[test]
fn session_guard_rejects_symlinked_lock_directory() {
    use std::os::unix::fs::symlink;

    let root = temp_root("session-guard-symlink");
    let outside = temp_root("session-guard-symlink-outside");
    fs::create_dir_all(&root).unwrap();
    fs::create_dir_all(&outside).unwrap();
    symlink(&outside, root.join(SESSION_GUARD_DIR)).unwrap();

    let error = WorkspaceRegistry::open(&root, "symlinked-lock-dir").unwrap_err();

    assert!(error.to_string().contains("session lock directory is not a directory"));
    assert!(fs::read_dir(&outside).unwrap().next().is_none());
    fs::remove_dir_all(root).unwrap();
    fs::remove_dir_all(outside).unwrap();
}

#[test]
fn reset_session_guard_coordinator_busy_fails_without_waiting_forever() {
    let root = temp_root("session-guard-coordinator-busy");
    fs::create_dir_all(&root).unwrap();
    let lock_dir = prepare_session_guard_dir(&root).unwrap();
    let _held = SessionLease::acquire(&session_guard_coordinator_path(&lock_dir)).unwrap();
    let started = std::time::Instant::now();

    let error = match acquire_existing_session_reset_guard(&root, "blocked-by-coordinator") {
        Ok(_) => panic!("reset acquired a busy session coordinator"),
        Err(error) => error,
    };

    assert!(started.elapsed() < std::time::Duration::from_secs(1));
    assert!(format!("{error:#}").contains("workspace session coordinator is busy"));
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn workspace_commit_publishes_one_normalized_resource_event() {
    let mut registry = WorkspaceRegistry::in_memory("test").unwrap();
    seed_workspace(&mut registry, "legacy-only");

    let snapshot = registry.snapshot().unwrap();
    assert_eq!(snapshot.revision, 1);
    assert_eq!(snapshot.resource_revision, 1);
    let events = registry.resource_events_after(0).unwrap();
    assert_eq!(events.batches.len(), 1);
    assert_eq!(events.batches[0].previous_revision, 0);
    assert_eq!(events.batches[0].revision, 1);
    assert_eq!(events.batches[0].changes.as_array().unwrap().len(), 1);
    assert_eq!(events.batches[0].changes[0]["kind"], "upsert");
    assert_eq!(events.batches[0].changes[0]["resource"], "workspace");
    assert!(events.batches[0].changes[0].get("event").is_none());
    assert_eq!(
        registry
            .connection
            .query_row("SELECT COUNT(*) FROM resource_mutations", [], |row| {
                row.get::<_, i64>(0)
            })
            .unwrap(),
        1
    );
}

#[test]
fn resource_event_replay_pages_a_far_behind_cursor() {
    const EVENT_COUNT: usize = 1_025;
    const EXPECTED_PAGE_SIZE: usize = 1_024;

    let mut registry = WorkspaceRegistry::in_memory("bounded-resource-replay").unwrap();
    for index in 0..EVENT_COUNT {
        seed_workspace(&mut registry, &format!("bounded-resource-replay-{index}"));
    }

    let page = registry.resource_events_after(0).unwrap();
    assert_eq!(page.head_revision, u64::try_from(EVENT_COUNT).unwrap());
    assert_eq!(page.batches.len(), EXPECTED_PAGE_SIZE);
    assert_eq!(page.batches.last().unwrap().revision, u64::try_from(EXPECTED_PAGE_SIZE).unwrap());
}

#[test]
fn resource_event_replay_reads_checkpointed_sealed_segments() {
    let root = temp_root("sealed-resource-replay");
    let mut registry = WorkspaceRegistry::open(&root, "sealed-resource-replay").unwrap();
    let database = registry.session_journal_database_path().unwrap();
    seed_workspace(&mut registry, "sealed-resource-replay-event");
    let through = registry.session_journal_after(0, 32).unwrap().head_sequence;
    registry
        .create_journal_checkpoint(
            through,
            1,
            &json!({
                "session_snapshot":{"cursor":{"revision":"1"}},
                "journal_extensions":{"producers":[],"hooks":[]},
            }),
            &[],
            "client_test",
            "sealed_resource_checkpoint",
        )
        .unwrap();
    let plan = match registry
        .begin_journal_segment_seal(through, "client_test", "sealed_resource_segment")
        .unwrap()
    {
        JournalSegmentSealStart::Prepare(plan) => plan,
        JournalSegmentSealStart::Replay(_) => panic!("first segment seal unexpectedly replayed"),
    };
    let reader = SessionJournalReader::open(&database).unwrap();
    let prepared = plan.prepare(&reader).unwrap();
    registry
        .commit_journal_segment_seal(prepared, "client_test", "sealed_resource_segment")
        .unwrap()
        .expect("segment boundary remained stable");

    drop(reader);
    drop(registry);
    let legacy = Connection::open(&database).unwrap();
    legacy
        .execute_batch(
            "PRAGMA foreign_keys=OFF;
             CREATE TABLE legacy_journal_event_index (
               event_id TEXT PRIMARY KEY NOT NULL,
               sequence INTEGER UNIQUE NOT NULL CHECK(sequence > 0),
               causation_depth INTEGER NOT NULL CHECK(causation_depth >= 0),
               causation_id TEXT,
               causal_hook_id TEXT
             );
             INSERT INTO legacy_journal_event_index
               SELECT event_id, sequence, causation_depth, causation_id, causal_hook_id
               FROM journal_event_index;
             DROP TABLE journal_event_index;
             ALTER TABLE legacy_journal_event_index RENAME TO journal_event_index;
             DELETE FROM meta WHERE key = 'journal_event_index_resource_v1';
             PRAGMA foreign_keys=ON;",
        )
        .unwrap();
    drop(legacy);

    let registry = WorkspaceRegistry::open(&root, "sealed-resource-replay").unwrap();

    let page = registry.resource_events_after(0).unwrap();
    assert_eq!(page.head_revision, 1);
    assert_eq!(page.batches.len(), 1);
    assert_eq!(page.batches[0].previous_revision, 0);
    assert_eq!(page.batches[0].revision, 1);

    drop(registry);
    fs::remove_dir_all(root).unwrap();
}

fn terminal(id: &str, workspace_key: &str) -> RegistryTerminal {
    RegistryTerminal {
        terminal_id: id.into(),
        workspace_key: workspace_key.into(),
        incarnation: None,
        lifecycle: TerminalLifecycle::Launching,
        launch_spec: json!({"command":["/bin/zsh"],"cwd":"/tmp","rows":24,"cols":80}),
        exit: None,
    }
}

fn screen_id(value: u128) -> ScreenPublicId {
    ScreenPublicId::parse(format!("screen_{value:032x}")).unwrap()
}

fn pane_id(value: u128) -> PanePublicId {
    PanePublicId::parse(format!("pane_{value:032x}")).unwrap()
}

fn tab_id(value: u128) -> TabPublicId {
    TabPublicId::parse(format!("tab_{value:032x}")).unwrap()
}

fn split_id(value: u128) -> SplitPublicId {
    SplitPublicId::parse(format!("split_{value:032x}")).unwrap()
}

fn terminal_resource(id: &str) -> TerminalPublicId {
    let value = if id == TERMINAL_ONE { 1 } else { 2 };
    TerminalPublicId::parse(format!("term_{value:032x}")).unwrap()
}

fn agent_resource(terminal_id: &TerminalPublicId) -> crate::resource::AgentPublicId {
    let digest = Sha256::digest(format!("cmux.protocol/2/agent/{terminal_id}").as_bytes());
    let payload = digest[..16].iter().map(|byte| format!("{byte:02x}")).collect::<String>();
    crate::resource::AgentPublicId::parse(format!("agent_{payload}")).unwrap()
}

fn browser_id(value: u128) -> BrowserPublicId {
    BrowserPublicId::parse(format!("browser_{value:032x}")).unwrap()
}

#[test]
fn machine_identity_is_state_root_global_and_survives_restart() {
    let root = temp_root("machine-identity");
    let first = WorkspaceRegistry::open(&root, "alpha").unwrap();
    let machine = first.machine_id().clone();
    let session = first.session_id().clone();
    let second = WorkspaceRegistry::open(&root, "beta").unwrap();
    assert_eq!(second.machine_id(), &machine);
    assert_ne!(second.session_id(), &session);
    drop(first);
    let restarted = WorkspaceRegistry::open(&root, "alpha").unwrap();
    assert_eq!(restarted.machine_id(), &machine);
    assert_eq!(restarted.session_id(), &session);
    drop(second);
    drop(restarted);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn concurrent_first_open_converges_on_one_machine_identity() {
    let root = temp_root("machine-race");
    let barrier = Arc::new(std::sync::Barrier::new(12));
    let threads = (0..12)
        .map(|index| {
            let root = root.clone();
            let barrier = barrier.clone();
            std::thread::spawn(move || {
                barrier.wait();
                WorkspaceRegistry::open(&root, &format!("session-{index}"))
                    .unwrap()
                    .machine_id()
                    .clone()
            })
        })
        .collect::<Vec<_>>();
    let identities =
        threads.into_iter().map(|thread| thread.join().unwrap()).collect::<HashSet<_>>();
    assert_eq!(identities.len(), 1);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn corrupt_machine_identity_fails_closed() {
    let root = temp_root("machine-corrupt");
    fs::create_dir_all(&root).unwrap();
    fs::write(root.join(MACHINE_ID_FILE), b"machine_not-an-id\n").unwrap();
    let error = WorkspaceRegistry::open(&root, "alpha").unwrap_err();
    assert!(error.to_string().contains("machine identity file is corrupt"));
    fs::remove_dir_all(root).unwrap();
}

#[cfg(unix)]
#[test]
fn machine_identity_files_are_owner_only() {
    use std::os::unix::fs::PermissionsExt;

    let root = temp_root("machine-mode");
    let registry = WorkspaceRegistry::open(&root, "alpha").unwrap();
    assert_eq!(
        fs::metadata(root.join(MACHINE_ID_FILE)).unwrap().permissions().mode() & 0o777,
        0o600
    );
    assert_eq!(
        fs::metadata(root.join(MACHINE_ID_LOCK_FILE)).unwrap().permissions().mode() & 0o777,
        0o600
    );
    assert_eq!(
        fs::metadata(root.join(RESOURCE_EFFECT_PEPPER_FILE)).unwrap().permissions().mode() & 0o777,
        0o600
    );
    assert_eq!(
        fs::metadata(root.join(RESOURCE_EFFECT_PEPPER_LOCK_FILE)).unwrap().permissions().mode()
            & 0o777,
        0o600
    );
    drop(registry);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn resource_effect_pepper_is_stable_per_root_and_unlinkable_across_roots() {
    let first_root = temp_root("receipt-pepper-first");
    let second_root = temp_root("receipt-pepper-second");
    let message = b"{\"text\":\"same secret\"}";
    let first = {
        let registry = WorkspaceRegistry::open(&first_root, "alpha").unwrap();
        registry.resource_input_receipt_hmac("same-key", "terminal.input.write", message)
    };
    let same_root = {
        let registry = WorkspaceRegistry::open(&first_root, "beta").unwrap();
        registry.resource_input_receipt_hmac("same-key", "terminal.input.write", message)
    };
    let reopened = {
        let registry = WorkspaceRegistry::open(&first_root, "alpha").unwrap();
        registry.resource_input_receipt_hmac("same-key", "terminal.input.write", message)
    };
    let second = {
        let registry = WorkspaceRegistry::open(&second_root, "alpha").unwrap();
        registry.resource_input_receipt_hmac("same-key", "terminal.input.write", message)
    };
    let memory_one = WorkspaceRegistry::in_memory("one").unwrap().resource_input_receipt_hmac(
        "same-key",
        "terminal.input.write",
        message,
    );
    let memory_two = WorkspaceRegistry::in_memory("two").unwrap().resource_input_receipt_hmac(
        "same-key",
        "terminal.input.write",
        message,
    );

    assert_eq!(first, same_root);
    assert_eq!(first, reopened);
    assert_ne!(first, second);
    assert_ne!(memory_one, memory_two);

    let pepper = fs::read(first_root.join(RESOURCE_EFFECT_PEPPER_FILE)).unwrap();
    assert_eq!(pepper.len(), RESOURCE_EFFECT_PEPPER_BYTES);
    let session_dir = first_root.join(session_storage_component("alpha"));
    for entry in fs::read_dir(session_dir).unwrap() {
        let path = entry.unwrap().path();
        if path.is_file() {
            let bytes = fs::read(&path).unwrap();
            assert!(
                !bytes.windows(pepper.len()).any(|window| window == pepper),
                "raw receipt pepper persisted in {}",
                path.display()
            );
        }
    }

    fs::remove_dir_all(first_root).unwrap();
    fs::remove_dir_all(second_root).unwrap();
}

#[test]
fn resource_effect_pepper_missing_corrupt_and_mismatch_fail_closed() {
    let missing_root = temp_root("receipt-pepper-missing");
    drop(WorkspaceRegistry::open(&missing_root, "session").unwrap());
    fs::remove_file(missing_root.join(RESOURCE_EFFECT_PEPPER_FILE)).unwrap();
    assert!(
        WorkspaceRegistry::open(&missing_root, "session")
            .unwrap_err()
            .to_string()
            .contains("resource receipt pepper is missing")
    );
    fs::remove_dir_all(missing_root).unwrap();

    let corrupt_root = temp_root("receipt-pepper-corrupt");
    drop(WorkspaceRegistry::open(&corrupt_root, "session").unwrap());
    fs::write(corrupt_root.join(RESOURCE_EFFECT_PEPPER_FILE), b"short").unwrap();
    assert!(
        WorkspaceRegistry::open(&corrupt_root, "session")
            .unwrap_err()
            .to_string()
            .contains("resource receipt pepper is corrupt")
    );
    fs::remove_dir_all(corrupt_root).unwrap();

    let mismatch_root = temp_root("receipt-pepper-mismatch");
    drop(WorkspaceRegistry::open(&mismatch_root, "session").unwrap());
    fs::write(
        mismatch_root.join(RESOURCE_EFFECT_PEPPER_FILE),
        [0xa5; RESOURCE_EFFECT_PEPPER_BYTES],
    )
    .unwrap();
    assert!(
        WorkspaceRegistry::open(&mismatch_root, "session")
            .unwrap_err()
            .to_string()
            .contains("resource receipt pepper does not match")
    );
    fs::remove_dir_all(mismatch_root).unwrap();
}

fn viewport_screen() -> RegistryScreen {
    let workspace = workspace(1, "one", "One").public_id;
    let screen = screen_id(1);
    let first = pane_id(1);
    let second = pane_id(2);
    let third = pane_id(3);
    let internal = split_id(1);
    let boundary = split_id(2);
    let base_column = split_id(3);
    let first_column = RegistryLayoutNode::Split {
        split: internal,
        direction: "down".into(),
        ratio: 0.5,
        first: Box::new(RegistryLayoutNode::Leaf { pane: first }),
        second: Box::new(RegistryLayoutNode::Leaf { pane: second }),
    };
    RegistryScreen {
        public_id: screen,
        workspace_id: workspace,
        position: 0,
        name: None,
        layout: RegistryLayoutNode::Split {
            split: boundary.clone(),
            direction: "right".into(),
            ratio: 1.0 / (1.0 + 0.5),
            first: Box::new(first_column.clone()),
            second: Box::new(RegistryLayoutNode::Leaf { pane: third.clone() }),
        },
        active_pane: third.clone(),
        zoomed_pane: Some(third.clone()),
        auto_layout: None,
        viewport: RegistryViewport {
            base_width: Some(1.0),
            columns: vec![
                RegistryViewportColumn {
                    id: base_column,
                    width: 1.0,
                    layout: first_column,
                    auto_layout: None,
                },
                RegistryViewportColumn {
                    id: boundary,
                    width: 0.5,
                    layout: RegistryLayoutNode::Leaf { pane: third },
                    auto_layout: Some(vec![pane_id(3)]),
                },
            ],
        },
    }
}

#[test]
fn viewport_schema_rejects_missing_duplicate_and_owner_splits() {
    let valid = viewport_screen();
    resource_store::validate_resource_patch(&ResourcePatch {
        changes: vec![ResourceChange::UpsertScreen(valid.clone())],
    })
    .unwrap();

    let mut missing = valid.clone();
    missing.viewport.columns[0].layout =
        RegistryLayoutNode::Stack { panes: vec![pane_id(1), pane_id(2)], expanded: pane_id(2) };
    assert!(
        resource_store::validate_resource_patch(&ResourcePatch {
            changes: vec![ResourceChange::UpsertScreen(missing)],
        })
        .unwrap_err()
        .to_string()
        .contains("do not cover the screen splits")
    );

    let mut owner_inside = valid.clone();
    owner_inside.viewport.columns[1].id = split_id(1);
    assert!(
        resource_store::validate_resource_patch(&ResourcePatch {
            changes: vec![ResourceChange::UpsertScreen(owner_inside)],
        })
        .unwrap_err()
        .to_string()
        .contains("boundary owner also appears inside")
    );

    let mut duplicate = valid.clone();
    let fourth = pane_id(4);
    if let RegistryLayoutNode::Split { second, .. } = &mut duplicate.layout {
        **second = RegistryLayoutNode::Split {
            split: split_id(4),
            direction: "down".into(),
            ratio: 0.5,
            first: Box::new(RegistryLayoutNode::Leaf { pane: pane_id(3) }),
            second: Box::new(RegistryLayoutNode::Leaf { pane: fourth.clone() }),
        };
    }
    duplicate.viewport.columns[1].layout = RegistryLayoutNode::Split {
        split: split_id(1),
        direction: "down".into(),
        ratio: 0.5,
        first: Box::new(RegistryLayoutNode::Leaf { pane: pane_id(3) }),
        second: Box::new(RegistryLayoutNode::Leaf { pane: fourth }),
    };
    assert!(
        resource_store::validate_resource_patch(&ResourcePatch {
            changes: vec![ResourceChange::UpsertScreen(duplicate)],
        })
        .unwrap_err()
        .to_string()
        .contains("more than one viewport column")
    );

    let mut mismatch = valid;
    if let RegistryLayoutNode::Split { ratio, .. } = &mut mismatch.layout {
        *ratio = 0.5;
    }
    assert!(
        resource_store::validate_resource_patch(&ResourcePatch {
            changes: vec![ResourceChange::UpsertScreen(mismatch)],
        })
        .unwrap_err()
        .to_string()
        .contains("compatibility layout")
    );
}

fn terminal_topology_patch() -> ResourcePatch {
    let workspace = workspace(1, "one", "One");
    let screen = screen_id(1);
    let pane = pane_id(1);
    let tab = tab_id(1);
    let terminal_id = terminal_resource(TERMINAL_ONE);
    ResourcePatch {
        changes: vec![
            ResourceChange::UpsertWorkspace {
                workspace: workspace.clone(),
                position: 0,
                active_screen: Some(screen.clone()),
            },
            ResourceChange::UpsertScreen(RegistryScreen {
                public_id: screen.clone(),
                workspace_id: workspace.public_id.clone(),
                position: 0,
                name: Some("Main".into()),
                layout: RegistryLayoutNode::Leaf { pane: pane.clone() },
                active_pane: pane.clone(),
                zoomed_pane: None,
                auto_layout: None,
                viewport: RegistryViewport::default(),
            }),
            ResourceChange::UpsertPane(RegistryPane {
                public_id: pane.clone(),
                screen_id: screen.clone(),
                name: Some("Shell".into()),
                active_tab: Some(tab.clone()),
                creation_ordinal: 1,
            }),
            ResourceChange::UpsertTerminal {
                public_id: terminal_id.clone(),
                terminal: terminal(TERMINAL_ONE, "one"),
            },
            ResourceChange::UpsertTab(RegistryTab {
                public_id: tab.clone(),
                pane_id: pane.clone(),
                position: 0,
                content_id: ContentPublicId::Terminal(terminal_id),
                name: Some("zsh".into()),
                browser_url: None,
                terminal_id: Some(TERMINAL_ONE.into()),
            }),
            ResourceChange::SetWorkspaceOrder { workspace_ids: vec![workspace.public_id.clone()] },
            ResourceChange::SetScreenOrder {
                workspace_id: workspace.public_id.clone(),
                screen_ids: vec![screen],
            },
            ResourceChange::SetTabOrder { pane_id: pane, tab_ids: vec![tab] },
            ResourceChange::SetActiveWorkspace { workspace_id: Some(workspace.public_id) },
        ],
    }
}

fn commit_terminal_topology(
    registry: &mut WorkspaceRegistry,
    mutation_id: &str,
) -> ResourcePatchCommit {
    registry
        .commit_resource_patch(
            &WorkspaceMutation::new(mutation_id, "test").unwrap(),
            "workspace.create",
            &json!({"operation":"workspace.create","name":"One"}),
            None,
            Some(0),
            &terminal_topology_patch(),
            &json!({"workspace_id":workspace(1, "one", "One").public_id}),
            &json!([{"kind":"workspace.created"}]),
        )
        .unwrap()
}

fn commit_browser_topology(
    registry: &mut WorkspaceRegistry,
    mutation_id: &str,
    browser: RegistryBrowser,
) -> ResourcePatchCommit {
    let workspace_public_id = workspace(1, "one", "One").public_id;
    let screen = screen_id(1);
    let first_pane = pane_id(1);
    let second_pane = pane_id(2);
    let second_tab = tab_id(2);
    let split = split_id(1);
    registry
        .commit_resource_patch(
            &WorkspaceMutation::new(mutation_id, "test").unwrap(),
            "tab.create_browser",
            &json!({"operation":"tab.create_browser"}),
            None,
            Some(1),
            &ResourcePatch {
                changes: vec![
                    ResourceChange::UpsertScreen(RegistryScreen {
                        public_id: screen.clone(),
                        workspace_id: workspace_public_id,
                        position: 0,
                        name: Some("Main".into()),
                        layout: RegistryLayoutNode::Split {
                            split,
                            direction: "right".into(),
                            ratio: 0.5,
                            first: Box::new(RegistryLayoutNode::Leaf { pane: first_pane.clone() }),
                            second: Box::new(RegistryLayoutNode::Leaf {
                                pane: second_pane.clone(),
                            }),
                        },
                        active_pane: first_pane,
                        zoomed_pane: None,
                        auto_layout: None,
                        viewport: RegistryViewport::default(),
                    }),
                    ResourceChange::UpsertPane(RegistryPane {
                        public_id: second_pane.clone(),
                        screen_id: screen,
                        name: Some("Docs".into()),
                        active_tab: Some(second_tab.clone()),
                        creation_ordinal: 2,
                    }),
                    ResourceChange::UpsertBrowser(browser.clone()),
                    ResourceChange::UpsertTab(RegistryTab {
                        public_id: second_tab.clone(),
                        pane_id: second_pane.clone(),
                        position: 0,
                        content_id: ContentPublicId::Browser(browser.public_id),
                        name: Some("Docs".into()),
                        browser_url: Some(browser.url),
                        terminal_id: None,
                    }),
                    ResourceChange::SetTabOrder { pane_id: second_pane, tab_ids: vec![second_tab] },
                ],
            },
            &json!({"created":true}),
            &json!([{"kind":"tab.created"}]),
        )
        .unwrap()
}

#[test]
fn resource_patch_commits_terminal_and_topology_in_one_revision() {
    let mut registry = WorkspaceRegistry::in_memory("test").unwrap();
    let commit = commit_terminal_topology(&mut registry, "create-one");
    assert_eq!(commit.revision, 1);
    assert!(!commit.replayed);

    let snapshot = registry.resource_topology_snapshot().unwrap();
    assert_eq!(snapshot.revision, 1);
    assert_eq!(snapshot.active_workspace, Some(workspace(1, "one", "One").public_id));
    assert_eq!(snapshot.screens.len(), 1);
    assert_eq!(snapshot.panes.len(), 1);
    assert_eq!(snapshot.tabs.len(), 1);
    assert_eq!(
        registry.terminal_record(TERMINAL_ONE).unwrap().unwrap().lifecycle,
        TerminalLifecycle::Launching
    );
    assert_eq!(
        registry
            .connection
            .query_row("SELECT COUNT(*) FROM session_journal", [], |row| row.get::<_, i64>(0))
            .unwrap(),
        1
    );
    let journal = registry.session_journal_after(0, 1).unwrap();
    assert_eq!(journal.records[0].kind, "workspace.create");
    for (kind, id) in [
        ("workspace", workspace(1, "one", "One").public_id.to_string()),
        ("screen", screen_id(1).to_string()),
        ("pane", pane_id(1).to_string()),
        ("tab", tab_id(1).to_string()),
        ("terminal", terminal_resource(TERMINAL_ONE).to_string()),
    ] {
        assert!(
            journal.records[0]
                .subjects
                .iter()
                .any(|subject| subject.kind == kind && subject.id == id),
            "missing {kind} journal subject {id}"
        );
    }
    assert_eq!(
        registry
            .connection
            .query_row("SELECT COUNT(*) FROM resource_mutations", [], |row| {
                row.get::<_, i64>(0)
            })
            .unwrap(),
        1
    );
}

#[test]
fn resource_tab_detach_preserves_exited_terminal_identity_and_outcome() {
    let mut registry = WorkspaceRegistry::in_memory("terminal-detach").unwrap();
    commit_terminal_topology(&mut registry, "create-terminal-detach");
    let mut terminal = registry.terminal_record(TERMINAL_ONE).unwrap().unwrap();
    terminal.lifecycle = TerminalLifecycle::Running;
    terminal.incarnation = Some(INCARNATION_ONE.into());
    registry
        .commit_terminal(
            &WorkspaceMutation::new("terminal-ready", "test").unwrap(),
            &json!({"operation":"terminal-ready"}),
            None,
            Some(0),
            "terminal-ready",
            &terminal,
            &json!({"terminal_id":TERMINAL_ONE}),
        )
        .unwrap();
    let exit = json!({
        "outcome":{"kind":"signal","signal":15,"core_dumped":false},
        "exited_at":"7654321",
        "revision":"1",
    });
    terminal.lifecycle = TerminalLifecycle::Exited;
    terminal.exit = Some(exit.clone());
    registry
        .commit_terminal(
            &WorkspaceMutation::new("terminal-exited", "test").unwrap(),
            &json!({"operation":"terminal-exited"}),
            None,
            Some(1),
            "terminal-exited",
            &terminal,
            &json!({"terminal_id":TERMINAL_ONE}),
        )
        .unwrap();
    let terminal_public_id = terminal_resource(TERMINAL_ONE);

    registry
        .commit_resource_patch(
            &WorkspaceMutation::new("detach-exited-tab", "cmux-tui-runtime").unwrap(),
            "terminal.exit.detach",
            &json!({"terminal":terminal_public_id}),
            None,
            Some(1),
            &ResourcePatch {
                changes: vec![
                    ResourceChange::UpsertPane(RegistryPane {
                        public_id: pane_id(1),
                        screen_id: screen_id(1),
                        name: Some("Shell".into()),
                        active_tab: None,
                        creation_ordinal: 1,
                    }),
                    ResourceChange::TombstoneTab { tab_id: tab_id(1), close_content: false },
                    ResourceChange::SetTabOrder { pane_id: pane_id(1), tab_ids: Vec::new() },
                ],
            },
            &json!({"detached":true}),
            &json!([
                {"kind":"delete","sequence":0,"resource":"terminal","id":terminal_public_id},
                {"kind":"delete","sequence":1,"resource":"tab","id":tab_id(1)},
            ]),
        )
        .unwrap();

    assert!(registry.resource_topology_snapshot().unwrap().tabs.is_empty());
    assert_eq!(registry.terminal_resource_id(TERMINAL_ONE).unwrap(), Some(terminal_public_id));
    let terminal = registry.terminal_record(TERMINAL_ONE).unwrap().unwrap();
    assert_eq!(terminal.lifecycle, TerminalLifecycle::Exited);
    assert_eq!(terminal.exit, Some(exit));
    let transaction = registry.connection.unchecked_transaction().unwrap();
    validate_resource_invariants(&transaction).unwrap();
    transaction.commit().unwrap();
}

#[test]
fn resource_tab_detach_rejects_live_terminal_content() {
    let mut registry = WorkspaceRegistry::in_memory("terminal-detach-live").unwrap();
    commit_terminal_topology(&mut registry, "create-terminal-detach-live");

    let error = registry
        .commit_resource_patch(
            &WorkspaceMutation::new("detach-live-tab", "cmux-tui-runtime").unwrap(),
            "terminal.exit.detach",
            &json!({"terminal":terminal_resource(TERMINAL_ONE)}),
            None,
            Some(1),
            &ResourcePatch {
                changes: vec![
                    ResourceChange::UpsertPane(RegistryPane {
                        public_id: pane_id(1),
                        screen_id: screen_id(1),
                        name: Some("Shell".into()),
                        active_tab: None,
                        creation_ordinal: 1,
                    }),
                    ResourceChange::TombstoneTab { tab_id: tab_id(1), close_content: false },
                    ResourceChange::SetTabOrder { pane_id: pane_id(1), tab_ids: Vec::new() },
                ],
            },
            &json!({"detached":true}),
            &json!([]),
        )
        .unwrap_err();

    assert!(error.to_string().contains("can detach only exited terminal content"));
    let snapshot = registry.resource_topology_snapshot().unwrap();
    assert_eq!(snapshot.revision, 1);
    assert_eq!(snapshot.tabs.len(), 1);
}

#[test]
fn resource_tab_detach_rejects_browser_content() {
    let mut registry = WorkspaceRegistry::in_memory("browser-detach").unwrap();
    commit_terminal_topology(&mut registry, "create-browser-detach");
    let browser = RegistryBrowser::recreate(browser_id(1), "https://cmux.dev/docs".into(), 117, 43);
    commit_browser_topology(&mut registry, "create-browser", browser.clone());

    let error = registry
        .commit_resource_patch(
            &WorkspaceMutation::new("detach-browser-tab", "cmux-tui-runtime").unwrap(),
            "tab.detach",
            &json!({"browser":browser.public_id}),
            None,
            Some(2),
            &ResourcePatch {
                changes: vec![
                    ResourceChange::UpsertPane(RegistryPane {
                        public_id: pane_id(2),
                        screen_id: screen_id(1),
                        name: Some("Docs".into()),
                        active_tab: None,
                        creation_ordinal: 2,
                    }),
                    ResourceChange::TombstoneTab { tab_id: tab_id(2), close_content: false },
                    ResourceChange::SetTabOrder { pane_id: pane_id(2), tab_ids: Vec::new() },
                ],
            },
            &json!({"detached":true}),
            &json!([]),
        )
        .unwrap_err();

    assert!(error.to_string().contains("cannot detach browser content"));
    let snapshot = registry.resource_topology_snapshot().unwrap();
    assert_eq!(snapshot.revision, 2);
    assert!(snapshot.tabs.iter().any(|tab| tab.public_id == tab_id(2)));
    assert_eq!(snapshot.browsers, vec![browser]);
}

#[test]
fn resource_tab_close_preserves_terminal_content_without_an_explicit_terminal_change() {
    let mut registry = WorkspaceRegistry::in_memory("terminal-tab-close").unwrap();
    commit_terminal_topology(&mut registry, "create-terminal-tab-close");

    registry
        .commit_resource_patch(
            &WorkspaceMutation::new("close-terminal-tab", "cmux-tui-runtime").unwrap(),
            "tab.close",
            &json!({"tab":tab_id(1)}),
            None,
            Some(1),
            &ResourcePatch {
                changes: vec![
                    ResourceChange::UpsertPane(RegistryPane {
                        public_id: pane_id(1),
                        screen_id: screen_id(1),
                        name: Some("Shell".into()),
                        active_tab: None,
                        creation_ordinal: 1,
                    }),
                    ResourceChange::TombstoneTab { tab_id: tab_id(1), close_content: true },
                    ResourceChange::SetTabOrder { pane_id: pane_id(1), tab_ids: Vec::new() },
                ],
            },
            &json!({"closed":true}),
            &json!([]),
        )
        .unwrap();

    assert!(registry.resource_topology_snapshot().unwrap().tabs.is_empty());
    assert_eq!(
        registry.terminal_resource_id(TERMINAL_ONE).unwrap(),
        Some(terminal_resource(TERMINAL_ONE)),
    );
    let transaction = registry.connection.unchecked_transaction().unwrap();
    validate_resource_invariants(&transaction).unwrap();
    transaction.commit().unwrap();
}

#[test]
fn resource_patch_replay_precedes_revision_and_rejects_changed_input() {
    let mut registry = WorkspaceRegistry::in_memory("test").unwrap();
    let first = commit_terminal_topology(&mut registry, "same-key");
    let retry = registry
        .commit_resource_patch(
            &WorkspaceMutation::new("same-key", "reconnected-client").unwrap(),
            "workspace.create",
            &json!({"operation":"workspace.create","name":"One"}),
            None,
            Some(0),
            &terminal_topology_patch(),
            &json!({"workspace_id":workspace(1, "one", "One").public_id}),
            &json!([{"kind":"workspace.created"}]),
        )
        .unwrap();
    assert_eq!(retry.revision, first.revision);
    assert!(retry.replayed);
    let error = registry
        .commit_resource_patch(
            &WorkspaceMutation::new("same-key", "another-client").unwrap(),
            "workspace.create",
            &json!({"operation":"workspace.create","name":"Different"}),
            None,
            None,
            &terminal_topology_patch(),
            &json!({}),
            &json!([]),
        )
        .unwrap_err();
    assert!(error.to_string().contains("idempotency.conflict"));
    assert_eq!(registry.resource_topology_snapshot().unwrap().revision, 1);
}

#[test]
fn resource_patch_replays_across_registry_reopen_and_origin_change() {
    let root = temp_root("resource-reconnect-replay");
    let first = {
        let mut registry = WorkspaceRegistry::open(&root, "session").unwrap();
        commit_terminal_topology(&mut registry, "reconnect-key")
    };
    let mut registry = WorkspaceRegistry::open(&root, "session").unwrap();
    let replay = registry
        .commit_resource_patch(
            &WorkspaceMutation::new("reconnect-key", "new-connection").unwrap(),
            "workspace.create",
            &json!({"operation":"workspace.create","name":"One"}),
            None,
            Some(0),
            &terminal_topology_patch(),
            &json!({"workspace_id":workspace(1, "one", "One").public_id}),
            &json!([{"kind":"workspace.created"}]),
        )
        .unwrap();
    assert_eq!(replay.revision, first.revision);
    assert!(replay.replayed);
    assert_eq!(registry.resource_topology_snapshot().unwrap().revision, 1);
}

#[test]
fn resource_mutation_pruning_allows_only_one_batch_of_runtime_slack() {
    let mut registry = WorkspaceRegistry::in_memory("mutation-runtime-bound").unwrap();
    let capacity = resource_store::RESOURCE_MUTATION_REPLAY_CAPACITY;
    let interval = usize::try_from(resource_store::RESOURCE_MUTATION_PRUNE_INTERVAL).unwrap();
    let before_boundary = capacity + interval - 1;
    {
        let tx = registry.connection.transaction().unwrap();
        for index in 0..before_boundary {
            tx.execute(
                "INSERT INTO resource_mutations(
                   idempotency_key, origin, operation, fingerprint, result_json,
                   committed_revision
                 ) VALUES(?1, 'test', 'test.pure', ?2, ?3, ?4)",
                params![
                    format!("bounded-{index:08}"),
                    canonical_json(&json!({"sequence":index})).unwrap(),
                    canonical_json(&json!({"sequence":index})).unwrap(),
                    i64::try_from(index + 1).unwrap(),
                ],
            )
            .unwrap();
        }
        tx.execute(
            "UPDATE meta SET value = ?1 WHERE key = 'resource_revision'",
            [before_boundary.to_string()],
        )
        .unwrap();
        resource_store::prune_resource_mutations(&tx).unwrap();
        tx.commit().unwrap();
    }
    assert_eq!(
        registry.resource_mutation_count_for_test().unwrap(),
        u64::try_from(before_boundary).unwrap()
    );

    {
        let tx = registry.connection.transaction().unwrap();
        let index = before_boundary;
        tx.execute(
            "INSERT INTO resource_mutations(
               idempotency_key, origin, operation, fingerprint, result_json,
               committed_revision
             ) VALUES(?1, 'test', 'test.pure', ?2, ?3, ?4)",
            params![
                format!("bounded-{index:08}"),
                canonical_json(&json!({"sequence":index})).unwrap(),
                canonical_json(&json!({"sequence":index})).unwrap(),
                i64::try_from(index + 1).unwrap(),
            ],
        )
        .unwrap();
        tx.execute(
            "UPDATE meta SET value = ?1 WHERE key = 'resource_revision'",
            [(before_boundary + 1).to_string()],
        )
        .unwrap();
        resource_store::prune_resource_mutations(&tx).unwrap();
        tx.commit().unwrap();
    }

    assert_eq!(
        registry.resource_mutation_count_for_test().unwrap(),
        u64::try_from(capacity).unwrap()
    );
    let oldest: i64 = registry
        .connection
        .query_row(
            "SELECT COUNT(*) FROM resource_mutations WHERE idempotency_key = 'bounded-00000000'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    let first_retained: i64 = registry
        .connection
        .query_row(
            "SELECT COUNT(*) FROM resource_mutations WHERE idempotency_key = ?1",
            [format!("bounded-{interval:08}")],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(oldest, 0);
    assert_eq!(first_retained, 1);

    let pages_after_first_wave: i64 =
        registry.connection.query_row("PRAGMA page_count", [], |row| row.get(0)).unwrap();
    let wave = capacity + interval;
    let mut pages = vec![pages_after_first_wave];
    for wave_index in 0..2 {
        let start = before_boundary + 1 + wave_index * wave;
        let tx = registry.connection.transaction().unwrap();
        for index in start..start + wave {
            tx.execute(
                "INSERT INTO resource_mutations(
                   idempotency_key, origin, operation, fingerprint, result_json,
                   committed_revision
                 ) VALUES(?1, 'test', 'test.pure', ?2, ?3, ?4)",
                params![
                    format!("bounded-{index:08}"),
                    canonical_json(&json!({"sequence":index})).unwrap(),
                    canonical_json(&json!({"sequence":index})).unwrap(),
                    i64::try_from(index + 1).unwrap(),
                ],
            )
            .unwrap();
            tx.execute(
                "UPDATE meta SET value = ?1 WHERE key = 'resource_revision'",
                [(index + 1).to_string()],
            )
            .unwrap();
            resource_store::prune_resource_mutations(&tx).unwrap();
        }
        tx.commit().unwrap();
        assert_eq!(
            registry.resource_mutation_count_for_test().unwrap(),
            u64::try_from(capacity).unwrap()
        );
        pages.push(
            registry.connection.query_row("PRAGMA page_count", [], |row| row.get(0)).unwrap(),
        );
    }
    assert!(
        pages[1] <= pages[0] + 16,
        "mutation journal grew after reaching steady state: {pages:?}"
    );
    assert!(pages[2] <= pages[1] + 16, "mutation journal did not reuse freed pages: {pages:?}");
}

#[test]
fn completed_creation_counts_in_the_boundary_replay_window() {
    let mut registry = WorkspaceRegistry::in_memory("creation-mutation-bound").unwrap();
    let capacity = resource_store::RESOURCE_MUTATION_REPLAY_CAPACITY;
    let interval = usize::try_from(resource_store::RESOURCE_MUTATION_PRUNE_INTERVAL).unwrap();
    let boundary = capacity + interval;
    let before_boundary = boundary - 1;
    {
        let tx = registry.connection.transaction().unwrap();
        for index in 0..before_boundary {
            tx.execute(
                "INSERT INTO resource_mutations(
                   idempotency_key, origin, operation, fingerprint, result_json,
                   committed_revision
                 ) VALUES(?1, 'test', 'test.pure', ?2, ?3, ?4)",
                params![
                    format!("creation-bound-{index:08}"),
                    canonical_json(&json!({"sequence":index})).unwrap(),
                    canonical_json(&json!({"sequence":index})).unwrap(),
                    i64::try_from(index + 1).unwrap(),
                ],
            )
            .unwrap();
        }
        tx.execute(
            "UPDATE meta SET value = ?1 WHERE key = 'resource_revision'",
            [before_boundary.to_string()],
        )
        .unwrap();
        tx.commit().unwrap();
    }

    let fingerprint = json!({"name":"boundary"});
    registry
        .prepare_resource_creation(
            "boundary-correlation",
            "boundary-attempt",
            "test.create.boundary",
            &fingerprint,
            &json!({"reservation":"boundary"}),
            false,
            None,
            Some(u64::try_from(before_boundary).unwrap()),
        )
        .unwrap();
    registry
        .commit_resource_creation_patch(
            "boundary-correlation",
            &WorkspaceMutation::new("boundary-attempt", "test").unwrap(),
            "test.create.boundary",
            &fingerprint,
            &ResourcePatch { changes: Vec::new() },
            &json!({"created":true}),
            &json!({"kind":"test","id":"boundary"}),
            &json!([]),
        )
        .unwrap();
    assert_eq!(
        registry.resource_mutation_count_for_test().unwrap(),
        u64::try_from(capacity).unwrap()
    );

    {
        let tx = registry.connection.transaction().unwrap();
        for offset in 1..interval {
            let revision = boundary + offset;
            tx.execute(
                "INSERT INTO resource_mutations(
                   idempotency_key, origin, operation, fingerprint, result_json,
                   committed_revision
                 ) VALUES(?1, 'test', 'test.pure', ?2, ?3, ?4)",
                params![
                    format!("creation-slack-{offset:08}"),
                    canonical_json(&json!({"sequence":revision})).unwrap(),
                    canonical_json(&json!({"sequence":revision})).unwrap(),
                    i64::try_from(revision).unwrap(),
                ],
            )
            .unwrap();
            tx.execute(
                "UPDATE meta SET value = ?1 WHERE key = 'resource_revision'",
                [revision.to_string()],
            )
            .unwrap();
            resource_store::prune_resource_mutations(&tx).unwrap();
        }
        tx.commit().unwrap();
    }
    assert_eq!(
        registry.resource_mutation_count_for_test().unwrap(),
        u64::try_from(capacity + interval - 1).unwrap()
    );

    {
        let tx = registry.connection.transaction().unwrap();
        let revision = boundary + interval;
        tx.execute(
            "INSERT INTO resource_mutations(
               idempotency_key, origin, operation, fingerprint, result_json,
               committed_revision
             ) VALUES(?1, 'test', 'test.pure', ?2, ?3, ?4)",
            params![
                "creation-next-boundary",
                canonical_json(&json!({"sequence":revision})).unwrap(),
                canonical_json(&json!({"sequence":revision})).unwrap(),
                i64::try_from(revision).unwrap(),
            ],
        )
        .unwrap();
        tx.execute(
            "UPDATE meta SET value = ?1 WHERE key = 'resource_revision'",
            [revision.to_string()],
        )
        .unwrap();
        resource_store::prune_resource_mutations(&tx).unwrap();
        tx.commit().unwrap();
    }
    assert_eq!(
        registry.resource_mutation_count_for_test().unwrap(),
        u64::try_from(capacity).unwrap()
    );
}

#[test]
fn startup_mutation_compaction_preserves_recovery_authorities_and_recent_replay() {
    let root = temp_root("mutation-startup-bound");
    let effect_fingerprint = json!({"title":"pending"});
    let effect_intent = json!({"notification_id":"reserved"});
    let active_creation_fingerprint = json!({"name":"active"});
    let active_creation_intent = json!({"reservation":"active"});
    let created_fingerprint = json!({"name":"created"});
    let created_intent = json!({"reservation":"created"});
    let created_path = json!({"kind":"test","id":"created"});
    let capacity = resource_store::RESOURCE_MUTATION_REPLAY_CAPACITY;
    let ordinary_count = capacity + 32;

    {
        let mut registry = WorkspaceRegistry::open(&root, "mutation-retention").unwrap();
        registry
            .prepare_resource_creation(
                "created-correlation",
                "created-attempt",
                "test.create.completed",
                &created_fingerprint,
                &created_intent,
                false,
                None,
                Some(0),
            )
            .unwrap();
        registry
            .commit_resource_creation_patch(
                "created-correlation",
                &WorkspaceMutation::new("created-attempt", "test").unwrap(),
                "test.create.completed",
                &created_fingerprint,
                &ResourcePatch { changes: Vec::new() },
                &json!({"created":true}),
                &created_path,
                &json!([]),
            )
            .unwrap();
        registry
            .prepare_resource_effect(
                "pending-effect",
                "notification.create",
                &effect_fingerprint,
                &effect_intent,
                None,
                None,
            )
            .unwrap();
        registry
            .prepare_resource_creation(
                "active-correlation",
                "active-attempt",
                "test.create.active",
                &active_creation_fingerprint,
                &active_creation_intent,
                false,
                None,
                None,
            )
            .unwrap();

        let tx = registry.connection.transaction().unwrap();
        for (key, operation, fingerprint, result, revision) in [
            (
                "pending-effect",
                "notification.create",
                effect_fingerprint.clone(),
                json!({"pending":true}),
                2_i64,
            ),
            (
                "active-attempt",
                "test.create.active",
                active_creation_fingerprint.clone(),
                json!({"active":true}),
                3_i64,
            ),
            (
                "terminal-defaults",
                "session.terminal_defaults.update",
                json!({"operation":"session.terminal_defaults.update"}),
                json!({
                    "foreground":"#123456",
                    "background":null,
                    "cursor":null,
                    "selection_background":null,
                    "selection_foreground":null,
                    "cursor_style":"block",
                    "cursor_blink":false,
                    "palette":{},
                }),
                4_i64,
            ),
        ] {
            tx.execute(
                "INSERT INTO resource_mutations(
                   idempotency_key, origin, operation, fingerprint, result_json,
                   committed_revision
                 ) VALUES(?1, 'test', ?2, ?3, ?4, ?5)",
                params![
                    key,
                    operation,
                    canonical_json(&fingerprint).unwrap(),
                    canonical_json(&result).unwrap(),
                    revision,
                ],
            )
            .unwrap();
        }
        for index in 0..ordinary_count {
            tx.execute(
                "INSERT INTO resource_mutations(
                   idempotency_key, origin, operation, fingerprint, result_json,
                   committed_revision
                 ) VALUES(?1, 'test', 'test.pure', ?2, ?3, ?4)",
                params![
                    format!("ordinary-{index:08}"),
                    canonical_json(&json!({"sequence":index})).unwrap(),
                    canonical_json(&json!({"sequence":index})).unwrap(),
                    i64::try_from(index + 5).unwrap(),
                ],
            )
            .unwrap();
        }
        tx.commit().unwrap();
        assert_eq!(
            registry.resource_mutation_count_for_test().unwrap(),
            u64::try_from(ordinary_count + 4).unwrap()
        );
    }

    let reopened = WorkspaceRegistry::open(&root, "mutation-retention").unwrap();
    assert_eq!(
        reopened.resource_mutation_count_for_test().unwrap(),
        u64::try_from(capacity + 3).unwrap()
    );
    for key in ["pending-effect", "active-attempt", "terminal-defaults"] {
        let count: i64 = reopened
            .connection
            .query_row(
                "SELECT COUNT(*) FROM resource_mutations WHERE idempotency_key = ?1",
                [key],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(count, 1, "{key}");
    }
    for key in ["created-attempt", "ordinary-00000000"] {
        let count: i64 = reopened
            .connection
            .query_row(
                "SELECT COUNT(*) FROM resource_mutations WHERE idempotency_key = ?1",
                [key],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(count, 0, "{key}");
    }

    assert_eq!(
        reopened
            .lookup_resource_effect("pending-effect", "notification.create", &effect_fingerprint,)
            .unwrap(),
        Some(ResourceEffectPreparation::Execute { intent: effect_intent, resumed: true })
    );
    assert_eq!(
        reopened
            .lookup_resource_creation(
                "active-correlation",
                "active-attempt",
                "test.create.active",
                &active_creation_fingerprint,
                false,
            )
            .unwrap(),
        Some(ResourceCreationPreparation::Execute {
            idempotency_key: "active-attempt".to_string(),
            intent: active_creation_intent,
            resumed: true,
        })
    );
    assert!(matches!(
        reopened
            .lookup_resource_creation(
                "created-correlation",
                "created-attempt",
                "test.create.completed",
                &created_fingerprint,
                false,
            )
            .unwrap(),
        Some(ResourceCreationPreparation::Created { created_path: path, revision: 1, .. })
            if path == created_path
    ));
    assert!(
        reopened
            .replay_resource_patch(
                &WorkspaceMutation::new("created-attempt", "retry").unwrap(),
                "test.create.completed",
                &created_fingerprint,
            )
            .unwrap()
            .is_none(),
        "completed correlation remains authoritative after its replay key expires"
    );

    let newest_index = ordinary_count - 1;
    let newest_key = format!("ordinary-{newest_index:08}");
    let newest_fingerprint = json!({"sequence":newest_index});
    let replay = reopened
        .replay_resource_patch(
            &WorkspaceMutation::new(&newest_key, "retry").unwrap(),
            "test.pure",
            &newest_fingerprint,
        )
        .unwrap()
        .unwrap();
    assert!(replay.replayed);
    assert_eq!(replay.result, json!({"sequence":newest_index}));
    let conflict = reopened
        .replay_resource_patch(
            &WorkspaceMutation::new(&newest_key, "retry").unwrap(),
            "test.pure",
            &json!({"sequence":"changed"}),
        )
        .unwrap_err();
    assert!(conflict.to_string().contains("idempotency.conflict"));
    assert!(reopened.public_projections().unwrap().terminal_defaults.is_some());
    drop(reopened);

    let reopened_again = WorkspaceRegistry::open(&root, "mutation-retention").unwrap();
    assert_eq!(
        reopened_again.resource_mutation_count_for_test().unwrap(),
        u64::try_from(capacity + 3).unwrap()
    );
    drop(reopened_again);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn resource_patch_failure_rolls_back_every_projection_and_log() {
    let mut registry = WorkspaceRegistry::in_memory("test").unwrap();
    registry.set_resource_patch_failure(true).unwrap();
    let error = registry
        .commit_resource_patch(
            &WorkspaceMutation::new("forced-failure", "test").unwrap(),
            "workspace.create",
            &json!({"operation":"workspace.create"}),
            None,
            Some(0),
            &terminal_topology_patch(),
            &json!({}),
            &json!([]),
        )
        .unwrap_err();
    assert!(error.to_string().contains("forced resource patch failure"));
    registry.set_resource_patch_failure(false).unwrap();
    assert_eq!(registry.resource_topology_snapshot().unwrap().revision, 0);
    assert!(registry.snapshot().unwrap().workspaces.is_empty());
    assert!(registry.terminal_record(TERMINAL_ONE).unwrap().is_none());
    for table in [
        "resource_identities",
        "resource_screens",
        "resource_panes",
        "resource_tabs",
        "resource_terminals",
        "resource_mutations",
        "session_journal",
    ] {
        let count = registry
            .connection
            .query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |row| row.get::<_, i64>(0))
            .unwrap();
        assert_eq!(count, 0, "{table} was not rolled back");
    }
}

#[test]
fn targeted_resource_patch_does_not_rewrite_unrelated_rows() {
    let mut registry = WorkspaceRegistry::in_memory("test").unwrap();
    commit_terminal_topology(&mut registry, "create");
    let pane = pane_id(1);
    let screen = screen_id(1);
    let tab = tab_id(1);
    registry
        .commit_resource_patch(
            &WorkspaceMutation::new("rename-pane", "test").unwrap(),
            "pane.rename",
            &json!({"operation":"pane.rename","pane_id":pane,"name":"Build"}),
            None,
            Some(1),
            &ResourcePatch {
                changes: vec![ResourceChange::UpsertPane(RegistryPane {
                    public_id: pane.clone(),
                    screen_id: screen.clone(),
                    name: Some("Build".into()),
                    active_tab: Some(tab.clone()),
                    creation_ordinal: 1,
                })],
            },
            &json!({"pane_id":pane}),
            &json!([{"kind":"pane.renamed"}]),
        )
        .unwrap();
    let revisions = |table: &str, public_id: &str| {
        registry
            .connection
            .query_row(
                &format!("SELECT updated_revision FROM {table} WHERE public_id = ?1"),
                [public_id],
                |row| row.get::<_, i64>(0),
            )
            .unwrap()
    };
    assert_eq!(revisions("resource_panes", pane.as_str()), 2);
    assert_eq!(revisions("resource_screens", screen.as_str()), 1);
    assert_eq!(revisions("resource_tabs", tab.as_str()), 1);
    assert_eq!(revisions("resource_terminals", terminal_resource(TERMINAL_ONE).as_str()), 1);
}

#[test]
fn resource_tombstones_prevent_public_id_and_workspace_key_reuse() {
    let mut registry = WorkspaceRegistry::in_memory("test").unwrap();
    commit_terminal_topology(&mut registry, "create");
    let workspace = workspace(1, "one", "One");
    registry
        .commit_resource_patch(
            &WorkspaceMutation::new("close", "test").unwrap(),
            "workspace.close",
            &json!({"operation":"workspace.close","workspace_id":workspace.public_id}),
            None,
            Some(1),
            &ResourcePatch {
                changes: vec![
                    ResourceChange::TombstoneWorkspace {
                        workspace_id: workspace.public_id.clone(),
                    },
                    ResourceChange::SetWorkspaceOrder { workspace_ids: vec![] },
                    ResourceChange::SetActiveWorkspace { workspace_id: None },
                ],
            },
            &json!({"closed":true}),
            &json!([{"kind":"workspace.closed"}]),
        )
        .unwrap();
    assert!(registry.resource_topology_snapshot().unwrap().screens.is_empty());
    assert_eq!(registry.terminal_snapshot().unwrap().terminals.len(), 1);
    let error = registry
        .commit_resource_patch(
            &WorkspaceMutation::new("recreate", "test").unwrap(),
            "workspace.create",
            &json!({"operation":"workspace.create"}),
            None,
            Some(2),
            &ResourcePatch {
                changes: vec![
                    ResourceChange::UpsertWorkspace { workspace, position: 0, active_screen: None },
                    ResourceChange::SetWorkspaceOrder {
                        workspace_ids: vec![
                            WorkspacePublicId::parse(format!("ws_{:032x}", 1)).unwrap(),
                        ],
                    },
                ],
            },
            &json!({}),
            &json!([]),
        )
        .unwrap_err();
    assert!(error.to_string().contains("tombstoned workspace key cannot be reused"));
    assert_eq!(registry.resource_topology_snapshot().unwrap().revision, 2);
}

#[test]
fn resource_order_is_exact_and_positions_are_contiguous() {
    let mut registry = WorkspaceRegistry::in_memory("test").unwrap();
    let one = workspace(1, "one", "One");
    let two = workspace(2, "two", "Two");
    registry
        .commit_resource_patch(
            &WorkspaceMutation::new("create-two", "test").unwrap(),
            "workspace.create",
            &json!({"operation":"workspace.create"}),
            None,
            Some(0),
            &ResourcePatch {
                changes: vec![
                    ResourceChange::UpsertWorkspace {
                        workspace: one.clone(),
                        position: 0,
                        active_screen: None,
                    },
                    ResourceChange::UpsertWorkspace {
                        workspace: two.clone(),
                        position: 1,
                        active_screen: None,
                    },
                    ResourceChange::SetWorkspaceOrder {
                        workspace_ids: vec![one.public_id.clone(), two.public_id.clone()],
                    },
                    ResourceChange::SetActiveWorkspace {
                        workspace_id: Some(one.public_id.clone()),
                    },
                ],
            },
            &json!({}),
            &json!([]),
        )
        .unwrap();
    registry
        .commit_resource_patch(
            &WorkspaceMutation::new("move", "test").unwrap(),
            "workspace.move",
            &json!({"operation":"workspace.move"}),
            None,
            Some(1),
            &ResourcePatch {
                changes: vec![ResourceChange::SetWorkspaceOrder {
                    workspace_ids: vec![two.public_id.clone(), one.public_id.clone()],
                }],
            },
            &json!({}),
            &json!([]),
        )
        .unwrap();
    assert_eq!(
        registry
            .snapshot()
            .unwrap()
            .workspaces
            .into_iter()
            .map(|workspace| workspace.public_id)
            .collect::<Vec<_>>(),
        vec![two.public_id, one.public_id]
    );
}

#[test]
fn resource_ids_survive_registry_restart() {
    let root = temp_root("resource-restart");
    let before = {
        let mut registry = WorkspaceRegistry::open(&root, "session").unwrap();
        commit_terminal_topology(&mut registry, "create");
        registry.resource_topology_snapshot().unwrap()
    };
    let registry = WorkspaceRegistry::open(&root, "session").unwrap();
    let after = registry.resource_topology_snapshot().unwrap();
    assert_eq!(after.session_id, before.session_id);
    assert_eq!(after.revision, before.revision);
    assert_eq!(after.active_workspace, before.active_workspace);
    assert_eq!(after.screens, before.screens);
    assert_eq!(after.panes, before.panes);
    assert_eq!(after.tabs, before.tabs);
    assert_eq!(after.browsers, before.browsers);
    assert_ne!(after.generation, before.generation);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn opening_legacy_workspaces_seeds_compatibility_active_workspace() {
    let root = temp_root("legacy-active-workspace");
    {
        let registry = WorkspaceRegistry::open(&root, "session").unwrap();
        registry
            .connection
            .execute_batch(
                "INSERT INTO workspaces(
                   workspace_key, numeric_id, name, group_key, position,
                   tombstoned, created_revision, updated_revision, deleted_revision
                 ) VALUES
                   ('later', 2, 'Later', 'default', 1, 0, 1, 1, NULL),
                   ('first', 1, 'First', 'default', 0, 0, 2, 2, NULL);
                 UPDATE meta SET value = '2' WHERE key = 'revision';",
            )
            .unwrap();
    }

    let registry = WorkspaceRegistry::open(&root, "session").unwrap();
    let workspaces = registry.snapshot().unwrap().workspaces;
    let topology = registry.resource_topology_snapshot().unwrap();
    assert_eq!(
        workspaces.iter().map(|workspace| workspace.key.as_str()).collect::<Vec<_>>(),
        ["first", "later"]
    );
    assert_eq!(topology.active_workspace.as_ref(), Some(&workspaces[0].public_id));
    drop(registry);

    let reopened = WorkspaceRegistry::open(&root, "session").unwrap();
    assert_eq!(
        reopened.resource_topology_snapshot().unwrap().active_workspace,
        Some(workspaces[0].public_id.clone())
    );
    drop(reopened);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn browser_restart_metadata_is_safe_and_exact() {
    let browser = RegistryBrowser {
        public_id: browser_id(1),
        url: "https://cmux.dev/docs".into(),
        source: RegistryBrowserSource::External,
        launch: RegistryBrowserLaunch::Adopted,
        reconnect: RegistryBrowserReconnect::Recreate,
        status: RegistryBrowserStatus::Live,
        cols: 117,
        rows: 43,
    };
    let encoded = serde_json::to_string(&browser).unwrap();
    for forbidden in
        ["target_id", "session_id", "websocket", "access_token", "authorization", "cdp"]
    {
        assert!(!encoded.contains(forbidden), "browser metadata leaked {forbidden}");
    }

    let mut registry = WorkspaceRegistry::in_memory("test").unwrap();
    commit_terminal_topology(&mut registry, "create");
    commit_browser_topology(&mut registry, "browser", browser.clone());
    assert_eq!(registry.resource_topology_snapshot().unwrap().browsers, vec![browser]);
}

#[test]
fn invalid_browser_restart_metadata_is_rejected_before_commit() {
    let mut registry = WorkspaceRegistry::in_memory("test").unwrap();
    commit_terminal_topology(&mut registry, "create");
    let error = commit_browser_topology_unchecked(
        &mut registry,
        RegistryBrowser::recreate(browser_id(1), "https://cmux.dev".into(), 0, 24),
    );
    assert!(error.to_string().contains("invalid size 0x24"));
    assert_eq!(registry.resource_topology_snapshot().unwrap().revision, 1);
}

fn commit_browser_topology_unchecked(
    registry: &mut WorkspaceRegistry,
    browser: RegistryBrowser,
) -> anyhow::Error {
    let workspace_public_id = workspace(1, "one", "One").public_id;
    let screen = screen_id(1);
    let first_pane = pane_id(1);
    let second_pane = pane_id(2);
    let second_tab = tab_id(2);
    registry
        .commit_resource_patch(
            &WorkspaceMutation::new("invalid-browser", "test").unwrap(),
            "tab.create_browser",
            &json!({"operation":"tab.create_browser"}),
            None,
            Some(1),
            &ResourcePatch {
                changes: vec![
                    ResourceChange::UpsertScreen(RegistryScreen {
                        public_id: screen.clone(),
                        workspace_id: workspace_public_id,
                        position: 0,
                        name: Some("Main".into()),
                        layout: RegistryLayoutNode::Split {
                            split: split_id(1),
                            direction: "right".into(),
                            ratio: 0.5,
                            first: Box::new(RegistryLayoutNode::Leaf { pane: first_pane.clone() }),
                            second: Box::new(RegistryLayoutNode::Leaf {
                                pane: second_pane.clone(),
                            }),
                        },
                        active_pane: first_pane,
                        zoomed_pane: None,
                        auto_layout: None,
                        viewport: RegistryViewport::default(),
                    }),
                    ResourceChange::UpsertPane(RegistryPane {
                        public_id: second_pane.clone(),
                        screen_id: screen,
                        name: None,
                        active_tab: Some(second_tab.clone()),
                        creation_ordinal: 2,
                    }),
                    ResourceChange::UpsertBrowser(browser.clone()),
                    ResourceChange::UpsertTab(RegistryTab {
                        public_id: second_tab.clone(),
                        pane_id: second_pane.clone(),
                        position: 0,
                        content_id: ContentPublicId::Browser(browser.public_id),
                        name: None,
                        browser_url: Some(browser.url),
                        terminal_id: None,
                    }),
                    ResourceChange::SetTabOrder { pane_id: second_pane, tab_ids: vec![second_tab] },
                ],
            },
            &json!({}),
            &json!([]),
        )
        .unwrap_err()
}

#[test]
fn corrupt_browser_restart_metadata_fails_closed_on_open() {
    let root = temp_root("browser-metadata-corrupt");
    let browser = browser_id(1);
    {
        let mut registry = WorkspaceRegistry::open(&root, "session").unwrap();
        commit_terminal_topology(&mut registry, "create");
        commit_browser_topology(
            &mut registry,
            "browser",
            RegistryBrowser::recreate(browser.clone(), "https://cmux.dev".into(), 91, 31),
        );
    }
    let session_dir = root.join(session_storage_component("session"));
    let connection = Connection::open(session_dir.join("workspace-registry.sqlite3")).unwrap();
    connection
        .execute(
            "UPDATE resource_browsers
             SET metadata_json = '{\"public_id\":\"browser_00000000000000000000000000000001\",\"url\":\"https://cmux.dev\",\"source\":\"unknown\",\"launch\":\"create\",\"reconnect\":\"recreate\",\"status\":\"starting\",\"cols\":91,\"rows\":31,\"target_id\":\"secret\"}'
             WHERE public_id = ?1",
            [browser.as_str()],
        )
        .unwrap();
    drop(connection);
    let error = WorkspaceRegistry::open(&root, "session").unwrap_err();
    assert!(error.to_string().contains("invalid metadata for browser"));
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn split_and_browser_identities_follow_targeted_parent_lifecycle() {
    let mut registry = WorkspaceRegistry::in_memory("test").unwrap();
    commit_terminal_topology(&mut registry, "create");
    let workspace_public_id = workspace(1, "one", "One").public_id;
    let screen = screen_id(1);
    let first_pane = pane_id(1);
    let second_pane = pane_id(2);
    let second_tab = tab_id(2);
    let split = split_id(1);
    let browser = browser_id(1);
    registry
        .commit_resource_patch(
            &WorkspaceMutation::new("split", "test").unwrap(),
            "pane.split",
            &json!({"operation":"pane.split"}),
            None,
            Some(1),
            &ResourcePatch {
                changes: vec![
                    ResourceChange::UpsertScreen(RegistryScreen {
                        public_id: screen.clone(),
                        workspace_id: workspace_public_id.clone(),
                        position: 0,
                        name: Some("Main".into()),
                        layout: RegistryLayoutNode::Split {
                            split: split.clone(),
                            direction: "right".into(),
                            ratio: 0.5,
                            first: Box::new(RegistryLayoutNode::Leaf { pane: first_pane.clone() }),
                            second: Box::new(RegistryLayoutNode::Leaf {
                                pane: second_pane.clone(),
                            }),
                        },
                        active_pane: first_pane.clone(),
                        zoomed_pane: None,
                        auto_layout: None,
                        viewport: RegistryViewport::default(),
                    }),
                    ResourceChange::UpsertPane(RegistryPane {
                        public_id: second_pane.clone(),
                        screen_id: screen.clone(),
                        name: Some("Docs".into()),
                        active_tab: Some(second_tab.clone()),
                        creation_ordinal: 2,
                    }),
                    ResourceChange::UpsertBrowser(RegistryBrowser::recreate(
                        browser.clone(),
                        "https://cmux.dev".into(),
                        80,
                        24,
                    )),
                    ResourceChange::UpsertTab(RegistryTab {
                        public_id: second_tab.clone(),
                        pane_id: second_pane.clone(),
                        position: 0,
                        content_id: ContentPublicId::Browser(browser.clone()),
                        name: Some("Docs".into()),
                        browser_url: Some("https://cmux.dev".into()),
                        terminal_id: None,
                    }),
                    ResourceChange::SetTabOrder {
                        pane_id: second_pane.clone(),
                        tab_ids: vec![second_tab],
                    },
                ],
            },
            &json!({}),
            &json!([]),
        )
        .unwrap();
    assert_eq!(
        registry
            .connection
            .query_row(
                "SELECT kind FROM resource_identities
                     WHERE public_id = ?1 AND deleted_revision IS NULL",
                [split.as_str()],
                |row| row.get::<_, String>(0),
            )
            .unwrap(),
        "split"
    );

    registry
        .commit_resource_patch(
            &WorkspaceMutation::new("unsplit", "test").unwrap(),
            "pane.close",
            &json!({"operation":"pane.close"}),
            None,
            Some(2),
            &ResourcePatch {
                changes: vec![
                    ResourceChange::UpsertScreen(RegistryScreen {
                        public_id: screen,
                        workspace_id: workspace_public_id,
                        position: 0,
                        name: Some("Main".into()),
                        layout: RegistryLayoutNode::Leaf { pane: first_pane.clone() },
                        active_pane: first_pane,
                        zoomed_pane: None,
                        auto_layout: None,
                        viewport: RegistryViewport::default(),
                    }),
                    ResourceChange::TombstonePane { pane_id: second_pane },
                ],
            },
            &json!({}),
            &json!([]),
        )
        .unwrap();
    for public_id in [split.as_str(), browser.as_str()] {
        assert!(
            registry
                .connection
                .query_row(
                    "SELECT deleted_revision FROM resource_identities WHERE public_id = ?1",
                    [public_id],
                    |row| row.get::<_, Option<i64>>(0),
                )
                .unwrap()
                .is_some()
        );
    }
}

#[test]
fn resource_identity_sql_check_rejects_non_hex_payload() {
    let registry = WorkspaceRegistry::in_memory("test").unwrap();
    let invalid = format!("pane_{}", "z".repeat(32));
    let error = registry
        .connection
        .execute(
            "INSERT INTO resource_identities(
                   public_id, kind, created_revision, updated_revision, deleted_revision
                 ) VALUES(?1, 'pane', 1, 1, NULL)",
            [&invalid],
        )
        .unwrap_err();
    assert!(error.to_string().contains("CHECK constraint failed"));
}

#[test]
fn resource_terminals_reject_orphans_while_terminal_hosts_are_session_owned() {
    let mut registry = WorkspaceRegistry::in_memory("test").unwrap();
    let public_id = terminal_resource(TERMINAL_TWO);
    {
        let tx = registry.connection.transaction().unwrap();
        tx.execute(
            "INSERT INTO resource_identities(
                   public_id, kind, created_revision, updated_revision, deleted_revision
                 ) VALUES(?1, 'terminal', 1, 1, NULL)",
            [public_id.as_str()],
        )
        .unwrap();
        tx.execute(
            "INSERT INTO resource_terminals(
                   public_id, terminal_id, lifecycle,
                   created_revision, updated_revision, deleted_revision
                 ) VALUES(?1, ?2, 'active', 1, 1, NULL)",
            params![public_id.as_str(), TERMINAL_TWO],
        )
        .unwrap();
        assert!(tx.commit().unwrap_err().to_string().contains("FOREIGN KEY constraint failed"));
    }
    assert_eq!(
        registry
            .connection
            .query_row("SELECT COUNT(*) FROM resource_terminals", [], |row| {
                row.get::<_, i64>(0)
            })
            .unwrap(),
        0
    );

    let tx = registry.connection.transaction().unwrap();
    tx.execute(
        "INSERT INTO terminal_hosts(
               terminal_id, workspace_key, incarnation, lifecycle, launch_spec_json,
               exit_json, created_revision, updated_revision, deleted_revision
             ) VALUES(?1, 'missing', NULL, 'launching', '{}', NULL, 1, 1, NULL)",
        [TERMINAL_TWO],
    )
    .unwrap();
    tx.commit().unwrap();
    assert_eq!(
        registry
            .connection
            .query_row("SELECT COUNT(*) FROM terminal_hosts", [], |row| { row.get::<_, i64>(0) })
            .unwrap(),
        1
    );
}

#[test]
fn thousand_workspace_rename_has_bounded_writes_and_time() {
    let mut registry = WorkspaceRegistry::in_memory("test").unwrap();
    let workspaces = (1..=1_000)
        .map(|id| workspace(id, &format!("workspace-{id}"), &format!("Workspace {id}")))
        .collect::<Vec<_>>();
    let mut changes = workspaces
        .iter()
        .enumerate()
        .map(|(position, workspace)| ResourceChange::UpsertWorkspace {
            workspace: workspace.clone(),
            position,
            active_screen: None,
        })
        .collect::<Vec<_>>();
    changes.push(ResourceChange::SetWorkspaceOrder {
        workspace_ids: workspaces.iter().map(|workspace| workspace.public_id.clone()).collect(),
    });
    changes.push(ResourceChange::SetActiveWorkspace {
        workspace_id: Some(workspaces[0].public_id.clone()),
    });
    registry
        .commit_resource_patch(
            &WorkspaceMutation::new("seed-1000", "perf-test").unwrap(),
            "workspace.create",
            &json!({"count":1000}),
            None,
            Some(0),
            &ResourcePatch { changes },
            &json!({}),
            &json!([]),
        )
        .unwrap();

    let target = workspaces[499].clone();
    let mut renamed = target.clone();
    renamed.name = "Renamed".into();
    let changes_before = registry.connection.total_changes();
    let started = std::time::Instant::now();
    registry
        .commit_resource_patch(
            &WorkspaceMutation::new("rename-one-of-1000", "perf-test").unwrap(),
            "workspace.rename",
            &json!({"workspace_id":target.public_id,"name":"Renamed"}),
            None,
            Some(1),
            &ResourcePatch {
                changes: vec![ResourceChange::UpsertWorkspace {
                    workspace: renamed,
                    position: 499,
                    active_screen: None,
                }],
            },
            &json!({}),
            &json!([]),
        )
        .unwrap();
    let elapsed = started.elapsed();
    let changed_rows = registry.connection.total_changes() - changes_before;
    // The fixed write budget includes one append-only journal row and its
    // session and workspace subject-index rows. It must not grow with the
    // number of workspaces in the registry.
    assert!(changed_rows <= 10, "rename changed {changed_rows} rows");
    let latest_sequence = registry
        .connection
        .query_row("SELECT MAX(sequence) FROM session_journal", [], |row| row.get::<_, i64>(0))
        .unwrap();
    let indexed_subjects = registry
        .connection
        .query_row(
            "SELECT COUNT(*) FROM journal_subject_index WHERE sequence = ?1",
            [latest_sequence],
            |row| row.get::<_, i64>(0),
        )
        .unwrap();
    assert_eq!(indexed_subjects, 2);
    let expected_subjects = registry
        .connection
        .query_row(
            "SELECT COUNT(*) FROM journal_subject_index
             WHERE sequence = ?1
               AND ((kind = 'session' AND id = ?2)
                 OR (kind = 'workspace' AND id = ?3))",
            params![latest_sequence, registry.session_id().as_str(), target.public_id.as_str()],
            |row| row.get::<_, i64>(0),
        )
        .unwrap();
    assert_eq!(expected_subjects, 2);
    assert!(elapsed < std::time::Duration::from_secs(1), "targeted rename took {elapsed:?}");
    assert_eq!(
        registry
            .connection
            .query_row("SELECT COUNT(*) FROM workspaces WHERE updated_revision = 2", [], |row| row
                .get::<_, i64>(
                0
            ),)
            .unwrap(),
        1
    );
    assert_eq!(
        registry
            .connection
            .query_row(
                "SELECT COUNT(*) FROM resource_workspaces WHERE updated_revision = 2",
                [],
                |row| row.get::<_, i64>(0),
            )
            .unwrap(),
        1
    );
}

#[test]
fn durable_commit_recovers_and_changes_generation() {
    let root = temp_root("recover");
    let first = {
        let mut registry = WorkspaceRegistry::open(&root, "session").unwrap();
        let before = registry.snapshot().unwrap();
        let mutation = WorkspaceMutation::new(new_uuid_v4(), "browser").unwrap();
        let result = json!({"key":"one"});
        let commit = registry
            .commit(
                &mutation,
                &json!({"op":"create","key":"one"}),
                None,
                Some(0),
                "workspace-added",
                "one",
                &[RegistryWorkspace {
                    id: 1,
                    public_id: WorkspacePublicId::parse(format!("ws_{:032x}", 1)).unwrap(),
                    key: "one".into(),
                    name: "One".into(),
                    group_key: "default".into(),
                }],
                &result,
            )
            .unwrap();
        assert_eq!(commit.revision, 1);
        (before.registry_id, before.generation)
    };
    let recovered = WorkspaceRegistry::open(&root, "session").unwrap();
    let snapshot = recovered.snapshot().unwrap();
    assert_eq!(snapshot.registry_id, first.0);
    assert_ne!(snapshot.generation, first.1);
    assert_eq!(snapshot.revision, 1);
    assert_eq!(snapshot.workspaces[0].key, "one");
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn retry_precedes_revision_check_and_payload_mismatch_is_rejected() {
    let mut registry = WorkspaceRegistry::in_memory("test").unwrap();
    let mutation = WorkspaceMutation::new("mutation", "browser").unwrap();
    let fingerprint = json!({"op":"create","key":"one"});
    let result = json!({"key":"one"});
    let workspaces = [RegistryWorkspace {
        id: 1,
        public_id: WorkspacePublicId::parse(format!("ws_{:032x}", 1)).unwrap(),
        key: "one".into(),
        name: "One".into(),
        group_key: "default".into(),
    }];
    let first = registry
        .commit(
            &mutation,
            &fingerprint,
            None,
            Some(0),
            "workspace-added",
            "one",
            &workspaces,
            &result,
        )
        .unwrap();
    assert!(!first.replayed);
    let retry = registry
        .commit(
            &mutation,
            &fingerprint,
            None,
            Some(0),
            "workspace-added",
            "one",
            &workspaces,
            &result,
        )
        .unwrap();
    assert!(retry.replayed);
    assert_eq!(retry.revision, 1);
    assert!(
        registry
            .commit(
                &mutation,
                &json!({"op":"create","key":"different"}),
                None,
                None,
                "workspace-added",
                "different",
                &workspaces,
                &result,
            )
            .is_err()
    );
}

#[test]
fn second_writer_is_rejected() {
    let root = temp_root("lease");
    let first = WorkspaceRegistry::open(&root, "same").unwrap();
    assert!(WorkspaceRegistry::open(&root, "same").is_err());
    drop(first);
    WorkspaceRegistry::open(&root, "same").unwrap();
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn tombstones_prevent_workspace_key_reuse() {
    let mut registry = WorkspaceRegistry::in_memory("test").unwrap();
    registry
        .commit(
            &WorkspaceMutation::new("create", "browser").unwrap(),
            &json!({"op":"create"}),
            None,
            Some(0),
            "workspace-added",
            "stable",
            &[workspace(1, "stable", "One")],
            &json!({"workspace":1,"key":"stable"}),
        )
        .unwrap();
    assert_eq!(registry.snapshot().unwrap().next_numeric_id, 2);
    registry
        .commit(
            &WorkspaceMutation::new("close", "browser").unwrap(),
            &json!({"op":"close"}),
            None,
            Some(1),
            "workspace-closed",
            "stable",
            &[],
            &json!({"workspace":1,"key":"stable"}),
        )
        .unwrap();
    assert_eq!(registry.snapshot().unwrap().next_numeric_id, 2);
    let error = registry
        .commit(
            &WorkspaceMutation::new("recreate", "browser").unwrap(),
            &json!({"op":"create"}),
            None,
            Some(2),
            "workspace-added",
            "stable",
            &[workspace(2, "stable", "Again")],
            &json!({"workspace":2,"key":"stable"}),
        )
        .unwrap_err();
    assert!(error.to_string().contains("tombstoned workspace key cannot be reused"));
}

#[test]
fn frontend_projection_is_durable_cas_and_exactly_once() {
    let root = temp_root("projection");
    let mutation = WorkspaceMutation::new("layout-1", "browser-profile").unwrap();
    {
        let mut registry = WorkspaceRegistry::open(&root, "session").unwrap();
        let first = registry
            .put_frontend_projection(
                &mutation,
                "cmux-browser",
                "window-group",
                "group-a",
                1,
                Some(0),
                &json!({"columns":[{"workspace":"one"}]}),
            )
            .unwrap();
        assert_eq!(first.projection.projection_revision, 1);
        assert!(!first.replayed);
        let retry = registry
            .put_frontend_projection(
                &mutation,
                "cmux-browser",
                "window-group",
                "group-a",
                1,
                Some(0),
                &json!({"columns":[{"workspace":"one"}]}),
            )
            .unwrap();
        assert!(retry.replayed);
        assert_eq!(retry.projection.projection_revision, 1);
        assert!(
            registry
                .put_frontend_projection(
                    &WorkspaceMutation::new("layout-2", "browser-profile").unwrap(),
                    "cmux-browser",
                    "window-group",
                    "group-a",
                    1,
                    Some(0),
                    &json!({}),
                )
                .unwrap_err()
                .to_string()
                .contains("projection revision conflict")
        );
    }
    let registry = WorkspaceRegistry::open(&root, "session").unwrap();
    let recovered = registry
        .get_frontend_projection("cmux-browser", "window-group", "group-a")
        .unwrap()
        .unwrap();
    assert_eq!(recovered.projection_revision, 1);
    assert_eq!(recovered.projection["columns"][0]["workspace"], "one");
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn personal_and_shared_frontend_projections_coexist_and_restore_independently() {
    let root = temp_root("projection-scopes");
    {
        let mut registry = WorkspaceRegistry::open(&root, "session").unwrap();
        registry
            .put_frontend_projection(
                &WorkspaceMutation::new("personal-layout", "cmux-tui").unwrap(),
                "cmux-tui",
                "personal",
                "profile-lawrence",
                1,
                Some(0),
                &json!({"selected_workspace":"alpha","scroll":{"term-a":12}}),
            )
            .unwrap();
        registry
            .put_frontend_projection(
                &WorkspaceMutation::new("shared-layout", "cmux-tui").unwrap(),
                "cmux-tui",
                "shared",
                "pairing-room",
                1,
                Some(0),
                &json!({"columns":["alpha","beta"]}),
            )
            .unwrap();
    }

    let registry = WorkspaceRegistry::open(&root, "session").unwrap();
    let personal = registry
        .get_frontend_projection("cmux-tui", "personal", "profile-lawrence")
        .unwrap()
        .unwrap();
    let shared =
        registry.get_frontend_projection("cmux-tui", "shared", "pairing-room").unwrap().unwrap();
    assert_eq!(personal.projection["selected_workspace"], "alpha");
    assert_eq!(personal.projection["scroll"]["term-a"], 12);
    assert_eq!(shared.projection["columns"], json!(["alpha", "beta"]));
    assert!(
        registry.get_frontend_projection("cmux-tui", "personal", "pairing-room").unwrap().is_none(),
        "scope participates in projection identity"
    );
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn terminal_lifecycle_is_exactly_once_and_has_an_independent_revision() {
    let mut registry = WorkspaceRegistry::in_memory("test").unwrap();
    seed_workspace(&mut registry, "one");
    assert_eq!(registry.snapshot().unwrap().revision, 1);
    assert_eq!(registry.terminal_snapshot().unwrap().revision, 0);

    let terminal = terminal(TERMINAL_ONE, "one");
    let reserve = WorkspaceMutation::new("reserve-1", "browser").unwrap();
    let fingerprint = json!({"op":"reserve-terminal","terminal_id":TERMINAL_ONE});
    let result = json!({"terminal_id":TERMINAL_ONE,"state":"launching"});
    let first = registry
        .commit_terminal(
            &reserve,
            &fingerprint,
            None,
            Some(0),
            "terminal-added",
            &terminal,
            &result,
        )
        .unwrap();
    assert_eq!(first.revision, 1);
    assert!(!first.replayed);
    let retry = registry
        .commit_terminal(
            &reserve,
            &fingerprint,
            None,
            Some(0),
            "terminal-added",
            &terminal,
            &result,
        )
        .unwrap();
    assert_eq!(retry.revision, 1);
    assert!(retry.replayed);

    let mut adopting = terminal.clone();
    adopting.lifecycle = TerminalLifecycle::Adopting;
    adopting.incarnation = Some(INCARNATION_ONE.into());
    registry
        .commit_terminal(
            &WorkspaceMutation::new("adopt-1", "daemon").unwrap(),
            &json!({"op":"adopt-terminal","terminal_id":TERMINAL_ONE}),
            None,
            Some(1),
            "terminal-adopting",
            &adopting,
            &json!({"terminal_id":TERMINAL_ONE,"state":"adopting"}),
        )
        .unwrap();
    let mut running = adopting;
    running.lifecycle = TerminalLifecycle::Running;
    registry
        .commit_terminal(
            &WorkspaceMutation::new("ready-1", "daemon").unwrap(),
            &json!({"op":"terminal-ready","terminal_id":TERMINAL_ONE}),
            None,
            Some(2),
            "terminal-ready",
            &running,
            &json!({"terminal_id":TERMINAL_ONE,"state":"running"}),
        )
        .unwrap();

    let terminals = registry.terminal_snapshot().unwrap();
    assert_eq!(terminals.revision, 3);
    assert_eq!(terminals.terminals, vec![running]);
    assert_eq!(registry.snapshot().unwrap().revision, 1);
    assert_eq!(registry.terminal_events_after(0).unwrap().len(), 3);
}

#[test]
fn first_exit_metadata_wins_and_exited_ids_cannot_be_relaunched() {
    let mut registry = WorkspaceRegistry::in_memory("test").unwrap();
    seed_workspace(&mut registry, "one");
    let launching = terminal(TERMINAL_ONE, "one");
    registry
        .commit_terminal(
            &WorkspaceMutation::new("reserve", "browser").unwrap(),
            &json!({"op":"reserve-terminal","terminal_id":TERMINAL_ONE}),
            None,
            Some(0),
            "terminal-reserved",
            &launching,
            &json!({"terminal_id":TERMINAL_ONE}),
        )
        .unwrap();

    let mut first_exit = launching.clone();
    first_exit.lifecycle = TerminalLifecycle::Exited;
    first_exit.exit = Some(json!({"reason":"first-observer","status":17}));
    let first = registry
        .commit_terminal(
            &WorkspaceMutation::new("exit-one", "daemon").unwrap(),
            &json!({"op":"terminal-exited","terminal_id":TERMINAL_ONE}),
            None,
            Some(1),
            "terminal-exited",
            &first_exit,
            &json!({"terminal_id":TERMINAL_ONE}),
        )
        .unwrap();
    assert_eq!(first.revision, 2);

    let mut late_exit = first_exit.clone();
    late_exit.exit = Some(json!({"reason":"late-observer","status":99}));
    let duplicate = registry
        .commit_terminal(
            &WorkspaceMutation::new("exit-two", "daemon").unwrap(),
            &json!({"op":"terminal-exited-again","terminal_id":TERMINAL_ONE}),
            None,
            Some(2),
            "terminal-exited",
            &late_exit,
            &json!({"terminal_id":TERMINAL_ONE}),
        )
        .unwrap();
    assert!(duplicate.replayed);
    assert_eq!(duplicate.revision, 2);
    assert_eq!(registry.terminal_record(TERMINAL_ONE).unwrap().unwrap().exit, first_exit.exit);
    assert_eq!(registry.terminal_events_after(0).unwrap().len(), 2);

    let error = registry
        .commit_terminal(
            &WorkspaceMutation::new("reuse-exited", "browser").unwrap(),
            &json!({"op":"reserve-terminal","terminal_id":TERMINAL_ONE}),
            None,
            Some(2),
            "terminal-reserved",
            &launching,
            &json!({"terminal_id":TERMINAL_ONE}),
        )
        .unwrap_err();
    assert!(error.to_string().contains("invalid terminal transition Exited -> Launching"));
    assert_eq!(
        registry.terminal_record(TERMINAL_ONE).unwrap().unwrap().lifecycle,
        TerminalLifecycle::Exited
    );
}

#[test]
fn batch_terminal_close_rolls_back_every_tab_on_mid_transaction_failure() {
    let mut registry = WorkspaceRegistry::in_memory("test").unwrap();
    seed_workspace(&mut registry, "one");
    for (revision, terminal_id) in [(0, TERMINAL_ONE), (1, TERMINAL_TWO)] {
        registry
            .commit_terminal(
                &WorkspaceMutation::new(format!("reserve-{revision}"), "browser").unwrap(),
                &json!({"op":"reserve-terminal","terminal_id":terminal_id}),
                None,
                Some(revision),
                "terminal-reserved",
                &terminal(terminal_id, "one"),
                &json!({"terminal_id":terminal_id}),
            )
            .unwrap();
    }
    registry
        .connection
        .execute_batch(&format!(
            "CREATE TEMP TRIGGER fail_second_terminal_close
                 BEFORE UPDATE OF lifecycle ON terminal_hosts
                 WHEN NEW.terminal_id = '{TERMINAL_TWO}'
                 BEGIN SELECT RAISE(ABORT, 'forced batch failure'); END;"
        ))
        .unwrap();
    let requests = vec![(TERMINAL_ONE.to_string(), None), (TERMINAL_TWO.to_string(), None)];
    let error = registry
        .close_terminals_atomically(
            &WorkspaceMutation::new("close-pane-failed", "tui").unwrap(),
            &requests,
        )
        .unwrap_err();
    assert!(error.to_string().contains("forced batch failure"));
    assert_eq!(registry.terminal_snapshot().unwrap().revision, 2);
    for terminal_id in [TERMINAL_ONE, TERMINAL_TWO] {
        assert_eq!(
            registry.terminal_record(terminal_id).unwrap().unwrap().lifecycle,
            TerminalLifecycle::Launching
        );
    }
    registry.connection.execute_batch("DROP TRIGGER fail_second_terminal_close").unwrap();

    let closed = registry
        .close_terminals_atomically(
            &WorkspaceMutation::new("close-pane", "tui").unwrap(),
            &requests,
        )
        .unwrap();
    assert_eq!(closed, TerminalBatchClose { revision: 4, closed: 2 });
    assert_eq!(registry.terminal_events_after(2).unwrap().len(), 2);
    for terminal_id in [TERMINAL_ONE, TERMINAL_TWO] {
        assert_eq!(
            registry.terminal_record(terminal_id).unwrap().unwrap().lifecycle,
            TerminalLifecycle::Tombstoned
        );
    }
}

#[test]
fn terminal_close_tombstones_before_kill_and_retries_safely() {
    let mut registry = WorkspaceRegistry::in_memory("test").unwrap();
    seed_workspace(&mut registry, "one");
    let terminal = terminal(TERMINAL_ONE, "one");
    registry
        .commit_terminal(
            &WorkspaceMutation::new("reserve-1", "browser").unwrap(),
            &json!({"op":"reserve-terminal","terminal_id":TERMINAL_ONE}),
            None,
            Some(0),
            "terminal-added",
            &terminal,
            &json!({"terminal_id":TERMINAL_ONE}),
        )
        .unwrap();

    let close = WorkspaceMutation::new("close-1", "browser").unwrap();
    let first = registry.close_terminal(&close, None, Some(1), TERMINAL_ONE, None).unwrap();
    assert_eq!(first.revision, 2);
    assert_eq!(first.result["already_closed"], false);
    assert_eq!(
        registry.terminal_record(TERMINAL_ONE).unwrap().unwrap().lifecycle,
        TerminalLifecycle::Tombstoned
    );
    assert!(registry.terminal_snapshot().unwrap().terminals.is_empty());

    let lost_reply_retry =
        registry.close_terminal(&close, None, Some(1), TERMINAL_ONE, None).unwrap();
    assert!(lost_reply_retry.replayed);
    assert_eq!(lost_reply_retry.revision, 2);

    let second_close = registry
        .close_terminal(
            &WorkspaceMutation::new("close-2", "tui").unwrap(),
            None,
            Some(2),
            TERMINAL_ONE,
            None,
        )
        .unwrap();
    assert_eq!(second_close.revision, 2);
    assert_eq!(second_close.result["already_closed"], true);
    assert_eq!(registry.terminal_events_after(0).unwrap().len(), 2);

    assert!(
        registry
            .commit_terminal(
                &WorkspaceMutation::new("reuse", "browser").unwrap(),
                &json!({"op":"reserve-terminal","terminal_id":TERMINAL_ONE}),
                None,
                Some(2),
                "terminal-added",
                &terminal,
                &json!({"terminal_id":TERMINAL_ONE}),
            )
            .unwrap_err()
            .to_string()
            .contains("tombstoned terminal id cannot be reused")
    );
}

#[test]
fn closing_workspace_detaches_views_without_tombstoning_terminal_hosts() {
    let mut registry = WorkspaceRegistry::in_memory("test").unwrap();
    seed_workspace(&mut registry, "one");
    for (index, id) in [TERMINAL_ONE, TERMINAL_TWO].into_iter().enumerate() {
        let revision = u64::try_from(index).unwrap();
        registry
            .commit_terminal(
                &WorkspaceMutation::new(format!("reserve-{}", index + 1), "browser").unwrap(),
                &json!({"op":"reserve-terminal","terminal_id":id}),
                None,
                Some(revision),
                "terminal-added",
                &terminal(id, "one"),
                &json!({"terminal_id":id}),
            )
            .unwrap();
    }
    registry
        .commit(
            &WorkspaceMutation::new("close-workspace", "browser").unwrap(),
            &json!({"op":"close-workspace","workspace_key":"one"}),
            None,
            Some(1),
            "workspace-closed",
            "one",
            &[],
            &json!({"workspace_key":"one"}),
        )
        .unwrap();

    assert!(registry.snapshot().unwrap().workspaces.is_empty());
    let terminals = registry.terminal_snapshot().unwrap();
    assert_eq!(terminals.revision, 2);
    assert_eq!(terminals.terminals.len(), 2);
    for id in [TERMINAL_ONE, TERMINAL_TWO] {
        assert_eq!(
            registry.terminal_record(id).unwrap().unwrap().lifecycle,
            TerminalLifecycle::Launching
        );
    }
    assert!(registry.terminal_events_after(2).unwrap().is_empty());
}

#[test]
fn terminal_reserve_after_workspace_close_fails_referentially() {
    let mut registry = WorkspaceRegistry::in_memory("test").unwrap();
    seed_workspace(&mut registry, "one");
    registry
        .commit(
            &WorkspaceMutation::new("close", "browser").unwrap(),
            &json!({"op":"close-workspace"}),
            None,
            Some(1),
            "workspace-closed",
            "one",
            &[],
            &json!({"key":"one"}),
        )
        .unwrap();
    let error = registry
        .commit_terminal(
            &WorkspaceMutation::new("late-reserve", "browser").unwrap(),
            &json!({"op":"create-terminal","terminal_id":TERMINAL_ONE}),
            None,
            Some(0),
            "terminal-reserved",
            &terminal(TERMINAL_ONE, "one"),
            &json!({"terminal_id":TERMINAL_ONE}),
        )
        .unwrap_err();
    assert!(error.to_string().contains("workspace is missing or closed"));
    assert!(registry.terminal_record(TERMINAL_ONE).unwrap().is_none());
    assert_eq!(registry.terminal_snapshot().unwrap().revision, 0);
}

#[test]
fn schema_six_securely_discards_legacy_sensitive_input_receipts() {
    let root = temp_root("schema-six-sensitive-receipts");
    let session_dir = root.join(session_storage_component("session"));
    let database = session_dir.join(WORKSPACE_REGISTRY_FILE);
    let sentinel = "legacy-password-sentinel-do-not-retain";
    let public_url = "https://example.test/public-browser-url";
    drop(WorkspaceRegistry::open(&root, "session").unwrap());

    {
        let connection = Connection::open(&database).unwrap();
        connection
            .execute_batch(&format!(
                "PRAGMA wal_autocheckpoint=0;
                 BEGIN IMMEDIATE;
                 UPDATE meta SET value = '6' WHERE key = 'schema_version';
                 DELETE FROM meta WHERE key = '{RESOURCE_EFFECT_PEPPER_META_KEY}';
                 INSERT INTO resource_effect_receipts(
                   idempotency_key, operation, fingerprint, intent_json, state,
                   outcome_json, committed_revision
                 ) VALUES(
                   'legacy-sensitive', 'terminal.input.write',
                   '{{\"fields\":{{\"text\":\"{sentinel}\"}}}}',
                   '{{\"terminal_id\":\"term_00000000000000000000000000000001\",\"fields\":{{\"text\":\"{sentinel}\"}}}}',
                   'pending', NULL, NULL
                 );
                 INSERT INTO resource_effect_receipts(
                   idempotency_key, operation, fingerprint, intent_json, state,
                   outcome_json, committed_revision
                 ) VALUES(
                   'legacy-navigation', 'browser.navigate',
                   '{{\"fields\":{{\"url\":\"{public_url}\"}}}}',
                   '{{\"browser_id\":\"browser_00000000000000000000000000000001\",\"fields\":{{\"url\":\"{public_url}\"}}}}',
                   'pending', NULL, NULL
                 );
                 COMMIT;"
            ))
            .unwrap();
    }
    fs::remove_file(root.join(RESOURCE_EFFECT_PEPPER_FILE)).unwrap();

    let migrated = WorkspaceRegistry::open(&root, "session").unwrap();
    let sensitive: i64 = migrated
        .connection
        .query_row(
            "SELECT COUNT(*) FROM resource_effect_receipts
             WHERE idempotency_key = 'legacy-sensitive'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    let navigation: i64 = migrated
        .connection
        .query_row(
            "SELECT COUNT(*) FROM resource_effect_receipts
             WHERE idempotency_key = 'legacy-navigation'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(sensitive, 0);
    assert_eq!(navigation, 1);
    assert_eq!(
        required_meta(&migrated.connection, "schema_version").unwrap(),
        SCHEMA_VERSION.to_string()
    );
    assert_eq!(
        required_meta(&migrated.connection, RESOURCE_EFFECT_PEPPER_META_KEY).unwrap().len(),
        64
    );
    assert!(
        meta_value(&migrated.connection, RESOURCE_EFFECT_PEPPER_CLEANUP_META_KEY)
            .unwrap()
            .is_none()
    );
    drop(migrated);

    for entry in fs::read_dir(&session_dir).unwrap() {
        let path = entry.unwrap().path();
        if !path.is_file() {
            continue;
        }
        let bytes = fs::read(&path).unwrap();
        assert!(
            !bytes.windows(sentinel.len()).any(|window| window == sentinel.as_bytes()),
            "legacy sensitive receipt remained in {}",
            path.display()
        );
        if path.file_name().and_then(|name| name.to_str()) == Some("workspace-registry.sqlite3-wal")
        {
            assert!(bytes.is_empty(), "migration did not truncate the SQLite WAL");
        }
    }
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn schema_seven_resumes_interrupted_sensitive_receipt_cleanup() {
    let root = temp_root("schema-seven-resume-sensitive-cleanup");
    let database = root.join(session_storage_component("session")).join(WORKSPACE_REGISTRY_FILE);
    drop(WorkspaceRegistry::open(&root, "session").unwrap());
    Connection::open(&database)
        .unwrap()
        .execute(
            "INSERT INTO meta(key, value) VALUES(?1, '1')",
            [RESOURCE_EFFECT_PEPPER_CLEANUP_META_KEY],
        )
        .unwrap();

    let reopened = WorkspaceRegistry::open(&root, "session").unwrap();
    assert!(
        meta_value(&reopened.connection, RESOURCE_EFFECT_PEPPER_CLEANUP_META_KEY)
            .unwrap()
            .is_none()
    );
    drop(reopened);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn schema_seven_migrates_latest_agent_and_preserves_it_after_tombstone() {
    assert_schema_migrates_latest_agent_and_preserves_it_after_tombstone(7);
}

#[test]
fn schema_eight_migrates_latest_agent_and_preserves_it_after_tombstone() {
    assert_schema_migrates_latest_agent_and_preserves_it_after_tombstone(8);
}

fn assert_schema_migrates_latest_agent_and_preserves_it_after_tombstone(legacy_schema: u32) {
    let root = temp_root(&format!("schema-{legacy_schema}-agent-projection"));
    let database = root.join(session_storage_component("session")).join(WORKSPACE_REGISTRY_FILE);
    let terminal = terminal_resource(TERMINAL_ONE);
    let pepper_id;
    {
        let mut registry = WorkspaceRegistry::open(&root, "session").unwrap();
        pepper_id = required_meta(&registry.connection, RESOURCE_EFFECT_PEPPER_META_KEY).unwrap();
        commit_terminal_topology(&mut registry, "agent-migration-topology");
        let session = registry.session_id().clone();
        let agent = agent_resource(&terminal);
        for (key, state, source_session, expected_revision) in [
            ("agent-migration-old", "working", "old-session", 1_u64),
            ("agent-migration-new", "done", "new-session", 2_u64),
        ] {
            let fingerprint = json!({
                "terminal_id":terminal,
                "state":state,
                "source":"hook",
                "source_session":source_session,
            });
            let result = json!({
                "id":agent,
                "session_id":session,
                "terminal_id":terminal,
                "state":state,
                "source":"hook",
                "updated_at_ms":expected_revision.to_string(),
                "source_session":source_session,
            });
            let commit = registry
                .commit_agent_projection(
                    &WorkspaceMutation::new(key, "migration-test").unwrap(),
                    &fingerprint,
                    Some(expected_revision),
                    &terminal,
                    &result,
                    &json!([{
                        "kind":"upsert",
                        "sequence":0,
                        "resource":"agent",
                        "id":agent,
                        "value":result,
                    }]),
                )
                .unwrap();
            assert_eq!(commit.revision, expected_revision + 1);
        }
        assert_eq!(registry.resource_agent_projection_count_for_test().unwrap(), 1);
    }
    Connection::open(&database)
        .unwrap()
        .execute_batch(&format!(
            "DROP TRIGGER IF EXISTS resource_agent_projection_terminal_tombstone;
             DROP TABLE resource_agent_projections;
             UPDATE meta SET value = '{legacy_schema}' WHERE key = 'schema_version';"
        ))
        .unwrap();

    let mut migrated = WorkspaceRegistry::open(&root, "session").unwrap();
    assert_eq!(
        required_meta(&migrated.connection, "schema_version").unwrap(),
        SCHEMA_VERSION.to_string()
    );
    assert_eq!(migrated.resource_agent_projection_count_for_test().unwrap(), 1);
    assert_eq!(
        required_meta(&migrated.connection, RESOURCE_EFFECT_PEPPER_META_KEY).unwrap(),
        pepper_id
    );
    let legacy_trigger_count: i64 = migrated
        .connection
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master
             WHERE type = 'trigger'
               AND name = 'resource_agent_projection_terminal_tombstone'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(legacy_trigger_count, 0);
    let agents = migrated.public_projections().unwrap().agents;
    assert_eq!(agents.len(), 1);
    assert_eq!(agents[0].terminal_id, terminal);
    assert_eq!(agents[0].state, "done");
    assert_eq!(agents[0].source, "hook");
    assert_eq!(agents[0].source_session.as_deref(), Some("new-session"));

    migrated
        .commit_resource_patch(
            &WorkspaceMutation::new("agent-migration-tombstone", "migration-test").unwrap(),
            "terminal.close",
            &json!({"terminal_id":terminal}),
            None,
            Some(3),
            &ResourcePatch {
                changes: vec![
                    ResourceChange::UpsertPane(RegistryPane {
                        public_id: pane_id(1),
                        screen_id: screen_id(1),
                        name: Some("Shell".into()),
                        active_tab: None,
                        creation_ordinal: 1,
                    }),
                    ResourceChange::TombstoneTab { tab_id: tab_id(1), close_content: true },
                    ResourceChange::TombstoneTerminal {
                        public_id: terminal,
                        expected_incarnation: None,
                    },
                    ResourceChange::SetTabOrder { pane_id: pane_id(1), tab_ids: Vec::new() },
                ],
            },
            &json!({"closed":true}),
            &json!([]),
        )
        .unwrap();
    assert_eq!(migrated.resource_agent_projection_count_for_test().unwrap(), 1);
    assert_eq!(migrated.public_projections().unwrap().agents.len(), 1);
    drop(migrated);

    // Re-running the legacy migration recovers the durable projection from the
    // latest report even though its terminal is already tombstoned.
    Connection::open(&database)
        .unwrap()
        .execute_batch(&format!(
            "DROP TRIGGER IF EXISTS resource_agent_projection_terminal_tombstone;
             DROP TABLE resource_agent_projections;
             UPDATE meta SET value = '{legacy_schema}' WHERE key = 'schema_version';"
        ))
        .unwrap();
    let reopened = WorkspaceRegistry::open(&root, "session").unwrap();
    assert_eq!(reopened.resource_agent_projection_count_for_test().unwrap(), 1);
    assert_eq!(reopened.public_projections().unwrap().agents.len(), 1);
    drop(reopened);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn schema_eight_migrates_terminal_hosts_and_allows_multiple_durable_views() {
    let root = temp_root("schema-eight-terminal-multiview");
    let database = root.join(session_storage_component("session")).join(WORKSPACE_REGISTRY_FILE);
    {
        let mut registry = WorkspaceRegistry::open(&root, "session").unwrap();
        commit_terminal_topology(&mut registry, "schema-eight-seed");
    }
    let legacy = Connection::open(&database).unwrap();
    legacy
        .execute_batch(
            "PRAGMA foreign_keys=OFF;
             BEGIN IMMEDIATE;
             DROP INDEX IF EXISTS live_resource_tab_position;
             DROP INDEX IF EXISTS live_resource_browser_view;
             CREATE TABLE resource_tabs_v8 (
               public_id TEXT PRIMARY KEY NOT NULL REFERENCES resource_identities(public_id),
               pane_id TEXT NOT NULL REFERENCES resource_panes(public_id)
                 DEFERRABLE INITIALLY DEFERRED,
               position INTEGER,
               content_kind TEXT NOT NULL CHECK(content_kind IN ('terminal','browser')),
               content_id TEXT NOT NULL REFERENCES resource_identities(public_id)
                 DEFERRABLE INITIALLY DEFERRED,
               name TEXT,
               created_revision INTEGER NOT NULL,
               updated_revision INTEGER NOT NULL,
               deleted_revision INTEGER,
               CHECK (
                 (deleted_revision IS NULL AND position IS NOT NULL) OR
                 (deleted_revision IS NOT NULL AND position IS NULL)
               )
             );
             INSERT INTO resource_tabs_v8(
               public_id, pane_id, position, content_kind, content_id, name,
               created_revision, updated_revision, deleted_revision
             )
             SELECT public_id, pane_id, position, content_kind, content_id, name,
                    created_revision, updated_revision, deleted_revision
             FROM resource_tabs;
             DROP TABLE resource_tabs;
             ALTER TABLE resource_tabs_v8 RENAME TO resource_tabs;
             CREATE UNIQUE INDEX live_resource_tab_position
               ON resource_tabs(pane_id, position) WHERE deleted_revision IS NULL;
             ALTER TABLE terminal_hosts RENAME TO terminal_placements;
             UPDATE meta SET value = '8' WHERE key = 'schema_version';
             COMMIT;
             PRAGMA foreign_keys=ON;",
        )
        .unwrap();
    let terminal_id = terminal_resource(TERMINAL_ONE);
    let second_tab = tab_id(2);
    legacy
        .execute(
            "INSERT INTO resource_identities(
               public_id, kind, created_revision, updated_revision, deleted_revision
             ) VALUES(?1, 'tab', 1, 1, NULL)",
            [second_tab.as_str()],
        )
        .unwrap();
    legacy
        .execute(
            "INSERT INTO resource_tabs(
               public_id, pane_id, position, content_kind, content_id, name,
               created_revision, updated_revision, deleted_revision
             ) VALUES(?1, ?2, 1, 'terminal', ?3, 'second view', 1, 1, NULL)",
            params![second_tab.as_str(), pane_id(1).as_str(), terminal_id.as_str()],
        )
        .unwrap();
    drop(legacy);

    let migrated = WorkspaceRegistry::open(&root, "session").unwrap();
    assert_eq!(
        required_meta(&migrated.connection, "schema_version").unwrap(),
        SCHEMA_VERSION.to_string()
    );
    for (table, expected) in [("terminal_hosts", 1_i64), ("terminal_placements", 0_i64)] {
        let count = migrated
            .connection
            .query_row(
                "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?1",
                [table],
                |row| row.get::<_, i64>(0),
            )
            .unwrap();
        assert_eq!(count, expected, "unexpected table state for {table}");
    }
    let browser_view_indexes = migrated
        .connection
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master
             WHERE type = 'index' AND name = 'live_resource_browser_view'",
            [],
            |row| row.get::<_, i64>(0),
        )
        .unwrap();
    assert_eq!(browser_view_indexes, 1);
    let workspace_foreign_keys = migrated
        .connection
        .query_row(
            "SELECT COUNT(*) FROM pragma_foreign_key_list('terminal_hosts')
             WHERE \"table\" = 'workspaces' AND \"from\" = 'workspace_key'",
            [],
            |row| row.get::<_, i64>(0),
        )
        .unwrap();
    assert_eq!(workspace_foreign_keys, 0);
    drop(migrated);

    let reopened = WorkspaceRegistry::open(&root, "session").unwrap();
    let views = reopened
        .resource_topology_snapshot()
        .unwrap()
        .tabs
        .into_iter()
        .filter(|tab| tab.content_id == ContentPublicId::Terminal(terminal_id.clone()))
        .collect::<Vec<_>>();
    assert_eq!(views.len(), 2);
    assert_eq!(views[0].public_id, tab_id(1));
    assert_eq!(views[1].public_id, second_tab);
    assert!(
        reopened
            .connection
            .query_row("PRAGMA foreign_key_check", [], |_| Ok(()))
            .optional()
            .unwrap()
            .is_none()
    );
    drop(reopened);
    fs::remove_dir_all(root).unwrap();
}

fn rewrite_resource_tabs_with_legacy_single_view_schema(connection: &Connection) {
    connection
        .execute_batch(
            "PRAGMA foreign_keys=OFF;
             BEGIN IMMEDIATE;
             DROP INDEX IF EXISTS live_resource_tab_position;
             DROP INDEX IF EXISTS live_resource_browser_view;
             CREATE TABLE resource_tabs_legacy (
               public_id TEXT PRIMARY KEY NOT NULL REFERENCES resource_identities(public_id),
               pane_id TEXT NOT NULL REFERENCES resource_panes(public_id)
                 DEFERRABLE INITIALLY DEFERRED,
               position INTEGER,
               content_kind TEXT NOT NULL CHECK(content_kind IN ('terminal','browser')),
               content_id TEXT UNIQUE NOT NULL REFERENCES resource_identities(public_id)
                 DEFERRABLE INITIALLY DEFERRED,
               name TEXT,
               created_revision INTEGER NOT NULL,
               updated_revision INTEGER NOT NULL,
               deleted_revision INTEGER,
               CHECK (
                 (deleted_revision IS NULL AND position IS NOT NULL) OR
                 (deleted_revision IS NOT NULL AND position IS NULL)
               )
             );
             INSERT INTO resource_tabs_legacy(
               public_id, pane_id, position, content_kind, content_id, name,
               created_revision, updated_revision, deleted_revision
             )
             SELECT public_id, pane_id, position, content_kind, content_id, name,
                    created_revision, updated_revision, deleted_revision
             FROM resource_tabs;
             DROP TABLE resource_tabs;
             ALTER TABLE resource_tabs_legacy RENAME TO resource_tabs;
             CREATE UNIQUE INDEX live_resource_tab_position
               ON resource_tabs(pane_id, position) WHERE deleted_revision IS NULL;
             COMMIT;
             PRAGMA foreign_keys=ON;",
        )
        .unwrap();
}

#[test]
fn current_schema_normalizes_legacy_single_view_resource_tabs() {
    let root = temp_root("current-schema-terminal-multiview");
    let database = root.join(session_storage_component("session")).join(WORKSPACE_REGISTRY_FILE);
    {
        let mut registry = WorkspaceRegistry::open(&root, "session").unwrap();
        commit_terminal_topology(&mut registry, "current-schema-seed");
    }
    let legacy = Connection::open(&database).unwrap();
    rewrite_resource_tabs_with_legacy_single_view_schema(&legacy);
    drop(legacy);

    let mut reopened = WorkspaceRegistry::open(&root, "session").unwrap();
    let second_tab = tab_id(2);
    reopened
        .commit_resource_patch(
            &WorkspaceMutation::new("current-schema-project", "test").unwrap(),
            "terminal.project",
            &json!({"operation":"terminal.project"}),
            None,
            Some(1),
            &ResourcePatch {
                changes: vec![
                    ResourceChange::UpsertPane(RegistryPane {
                        public_id: pane_id(1),
                        screen_id: screen_id(1),
                        name: Some("Shell".into()),
                        active_tab: Some(tab_id(1)),
                        creation_ordinal: 1,
                    }),
                    ResourceChange::UpsertTab(RegistryTab {
                        public_id: second_tab.clone(),
                        pane_id: pane_id(1),
                        position: 1,
                        content_id: ContentPublicId::Terminal(terminal_resource(TERMINAL_ONE)),
                        name: Some("second view".into()),
                        browser_url: None,
                        terminal_id: Some(TERMINAL_ONE.into()),
                    }),
                    ResourceChange::SetTabOrder {
                        pane_id: pane_id(1),
                        tab_ids: vec![tab_id(1), second_tab.clone()],
                    },
                ],
            },
            &json!({"tab_id":second_tab}),
            &json!([]),
        )
        .unwrap();
    assert_eq!(
        reopened
            .resource_topology_snapshot()
            .unwrap()
            .tabs
            .into_iter()
            .filter(|tab| {
                tab.content_id == ContentPublicId::Terminal(terminal_resource(TERMINAL_ONE))
            })
            .count(),
        2
    );
    drop(reopened);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn current_schema_rejects_semantically_different_browser_view_predicate() {
    let root = temp_root("current-schema-wrong-browser-predicate");
    let database = root.join(session_storage_component("session")).join(WORKSPACE_REGISTRY_FILE);
    let browser = browser_id(1);
    {
        let mut registry = WorkspaceRegistry::open(&root, "session").unwrap();
        commit_terminal_topology(&mut registry, "wrong-browser-predicate-terminal");
        commit_browser_topology(
            &mut registry,
            "wrong-browser-predicate-browser",
            RegistryBrowser::recreate(browser.clone(), "https://cmux.dev".into(), 80, 24),
        );
    }
    let malformed = Connection::open(&database).unwrap();
    malformed
        .execute_batch(
            "DROP INDEX live_resource_browser_view;
             CREATE UNIQUE INDEX live_resource_browser_view
               ON resource_tabs(content_id)
               WHERE content_kind = 'browser' AND deleted_revision IS NULL
                 AND name IS NOT NULL;",
        )
        .unwrap();
    let second_tab = tab_id(3);
    malformed
        .execute(
            "INSERT INTO resource_identities(
               public_id, kind, created_revision, updated_revision, deleted_revision
             ) VALUES(?1, 'tab', 3, 3, NULL)",
            [second_tab.as_str()],
        )
        .unwrap();
    malformed
        .execute(
            "INSERT INTO resource_tabs(
               public_id, pane_id, position, content_kind, content_id, name,
               created_revision, updated_revision, deleted_revision
             ) VALUES(?1, ?2, 1, 'browser', ?3, NULL, 3, 3, NULL)",
            params![second_tab.as_str(), pane_id(2).as_str(), browser.as_str()],
        )
        .unwrap();
    drop(malformed);

    let error = WorkspaceRegistry::open(&root, "session").unwrap_err();
    assert!(
        error
            .to_string()
            .contains("workspace registry contains multiple live views for one browser"),
        "unexpected normalization error: {error:#}"
    );
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn current_schema_canonicalizes_equivalent_formatted_browser_view_predicate_once() {
    let root = temp_root("current-schema-formatted-browser-predicate");
    let database = root.join(session_storage_component("session")).join(WORKSPACE_REGISTRY_FILE);
    {
        let registry = WorkspaceRegistry::open(&root, "session").unwrap();
        drop(registry);
    }
    let formatted = Connection::open(&database).unwrap();
    formatted
        .execute_batch(
            "DROP INDEX live_resource_browser_view;
             CREATE UNIQUE INDEX live_resource_browser_view
               ON resource_tabs(content_id)
               WHERE (deleted_revision IS NULL)
                 AND (content_kind = 'browser');",
        )
        .unwrap();
    let definition_before = formatted
        .query_row(
            "SELECT sql FROM sqlite_master
             WHERE type = 'index' AND name = 'live_resource_browser_view'",
            [],
            |row| row.get::<_, String>(0),
        )
        .unwrap();
    let schema_version_before =
        formatted.query_row("PRAGMA schema_version", [], |row| row.get::<_, i64>(0)).unwrap();
    drop(formatted);

    let reopened = WorkspaceRegistry::open(&root, "session").unwrap();
    let canonical_definition = reopened
        .connection
        .query_row(
            "SELECT sql FROM sqlite_master
             WHERE type = 'index' AND name = 'live_resource_browser_view'",
            [],
            |row| row.get::<_, String>(0),
        )
        .unwrap();
    let schema_version_after_normalization = reopened
        .connection
        .query_row("PRAGMA schema_version", [], |row| row.get::<_, i64>(0))
        .unwrap();
    assert_ne!(canonical_definition, definition_before);
    assert_eq!(
        canonical_definition.split_whitespace().collect::<Vec<_>>().join(" "),
        "CREATE UNIQUE INDEX live_resource_browser_view ON resource_tabs(content_id) WHERE content_kind = 'browser' AND deleted_revision IS NULL"
    );
    assert!(schema_version_after_normalization > schema_version_before);
    drop(reopened);

    let reopened_again = WorkspaceRegistry::open(&root, "session").unwrap();
    let definition_after_second_open = reopened_again
        .connection
        .query_row(
            "SELECT sql FROM sqlite_master
             WHERE type = 'index' AND name = 'live_resource_browser_view'",
            [],
            |row| row.get::<_, String>(0),
        )
        .unwrap();
    let schema_version_after_second_open = reopened_again
        .connection
        .query_row("PRAGMA schema_version", [], |row| row.get::<_, i64>(0))
        .unwrap();
    assert_eq!(definition_after_second_open, canonical_definition);
    assert_eq!(schema_version_after_second_open, schema_version_after_normalization);
    drop(reopened_again);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn multiview_normalization_requires_browser_view_index() {
    let registry = WorkspaceRegistry::in_memory("missing-browser-view-index").unwrap();
    registry.connection.execute("DROP INDEX live_resource_browser_view", []).unwrap();

    assert!(resource_tabs_needs_multiview_normalization(&registry.connection).unwrap());
}

#[test]
fn schema_eight_rejects_multiple_live_views_for_one_browser() {
    let root = temp_root("schema-eight-duplicate-browser-views");
    let database = root.join(session_storage_component("session")).join(WORKSPACE_REGISTRY_FILE);
    let browser = browser_id(1);
    {
        let mut registry = WorkspaceRegistry::open(&root, "session").unwrap();
        commit_terminal_topology(&mut registry, "duplicate-browser-seed");
        commit_browser_topology(
            &mut registry,
            "duplicate-browser-view-seed",
            RegistryBrowser::recreate(browser.clone(), "https://cmux.dev".into(), 80, 24),
        );
    }
    let legacy = Connection::open(&database).unwrap();
    legacy
        .execute_batch(
            "PRAGMA foreign_keys=OFF;
             DROP INDEX live_resource_browser_view;
             CREATE INDEX live_resource_browser_view ON resource_tabs(content_id);
             UPDATE meta SET value = '8' WHERE key = 'schema_version';",
        )
        .unwrap();
    let second_tab = tab_id(3);
    legacy
        .execute(
            "INSERT INTO resource_identities(
               public_id, kind, created_revision, updated_revision, deleted_revision
             ) VALUES(?1, 'tab', 2, 2, NULL)",
            [second_tab.as_str()],
        )
        .unwrap();
    legacy
        .execute(
            "INSERT INTO resource_tabs(
               public_id, pane_id, position, content_kind, content_id, name,
               created_revision, updated_revision, deleted_revision
             ) VALUES(?1, ?2, 1, 'browser', ?3, NULL, 2, 2, NULL)",
            params![second_tab.as_str(), pane_id(2).as_str(), browser.as_str()],
        )
        .unwrap();
    drop(legacy);

    let error = WorkspaceRegistry::open(&root, "session").unwrap_err();
    assert!(
        error
            .to_string()
            .contains("workspace registry contains multiple live views for one browser"),
        "unexpected migration error: {error:#}"
    );
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn schema_eight_rejects_both_terminal_storage_tables() {
    let root = temp_root("schema-eight-duplicate-terminal-storage");
    let database = root.join(session_storage_component("session")).join(WORKSPACE_REGISTRY_FILE);
    {
        let registry = WorkspaceRegistry::open(&root, "session").unwrap();
        drop(registry);
    }
    let legacy = Connection::open(&database).unwrap();
    legacy
        .execute_batch(
            "CREATE TABLE terminal_placements AS SELECT * FROM terminal_hosts WHERE 0;
             UPDATE meta SET value = '8' WHERE key = 'schema_version';",
        )
        .unwrap();
    drop(legacy);

    let error = WorkspaceRegistry::open(&root, "session").unwrap_err();
    assert!(
        error.to_string().contains(
            "workspace registry contains both legacy terminal placements and terminal hosts"
        ),
        "unexpected migration error: {error:#}"
    );
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn schema_nine_multiview_converges_with_the_session_journal() {
    let root = temp_root("schema-nine-multiview-journal");
    let database = root.join(session_storage_component("session")).join(WORKSPACE_REGISTRY_FILE);
    {
        let mut registry = WorkspaceRegistry::open(&root, "session").unwrap();
        commit_terminal_topology(&mut registry, "schema-nine-seed");
    }

    let legacy = Connection::open(&database).unwrap();
    let event = legacy
        .query_row(
            "SELECT resource_revision, previous_resource_revision,
                    json_extract(producer_json, '$.id'), correlation_id,
                    json_extract(payload_json, '$.changes')
             FROM session_journal WHERE resource_revision IS NOT NULL",
            [],
            |row| {
                Ok((
                    row.get::<_, i64>(0)?,
                    row.get::<_, i64>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?,
                    row.get::<_, String>(4)?,
                ))
            },
        )
        .unwrap();
    legacy
        .execute_batch(
            "PRAGMA foreign_keys=OFF;
             DROP TABLE journal_hook_deliveries;
             DROP TABLE journal_hooks;
             DROP TABLE journal_ingress_receipts;
             DROP TABLE journal_operation_receipts;
             DROP TABLE journal_producers;
             DROP TABLE journal_checkpoints;
             DROP TABLE journal_content_blobs;
             DROP TABLE journal_segments;
             DROP TABLE journal_event_index;
             DROP TABLE session_journal;
             CREATE TABLE resource_events (
               revision INTEGER PRIMARY KEY NOT NULL,
               previous_revision INTEGER NOT NULL,
               origin TEXT NOT NULL,
               idempotency_key TEXT NOT NULL,
               deltas_json TEXT NOT NULL
             );
             UPDATE meta SET value = '9' WHERE key = 'schema_version';
             PRAGMA foreign_keys=ON;",
        )
        .unwrap();
    legacy
        .execute(
            "INSERT INTO resource_events(
               revision, previous_revision, origin, idempotency_key, deltas_json
             ) VALUES(?1, ?2, ?3, ?4, ?5)",
            params![event.0, event.1, event.2, event.3, event.4],
        )
        .unwrap();
    drop(legacy);

    let migrated = WorkspaceRegistry::open(&root, "session").unwrap();
    assert_eq!(
        required_meta(&migrated.connection, "schema_version").unwrap(),
        SCHEMA_VERSION.to_string()
    );
    let page = migrated.session_journal_after(0, 10).unwrap();
    assert_eq!(page.records.len(), 2);
    assert_eq!(page.records[0].kind, "session.journal.migrated");
    assert_eq!(page.records[1].resource_revision, Some(1));
    let resource_events = migrated
        .connection
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master
             WHERE type = 'table' AND name = 'resource_events'",
            [],
            |row| row.get::<_, i64>(0),
        )
        .unwrap();
    assert_eq!(resource_events, 0);
    drop(migrated);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn schema_ten_journal_converges_with_terminal_multiview() {
    let root = temp_root("schema-ten-journal-multiview");
    let database = root.join(session_storage_component("session")).join(WORKSPACE_REGISTRY_FILE);
    {
        let mut registry = WorkspaceRegistry::open(&root, "session").unwrap();
        commit_terminal_topology(&mut registry, "schema-ten-seed");
    }

    let legacy = Connection::open(&database).unwrap();
    legacy
        .execute_batch(
            "PRAGMA foreign_keys=OFF;
             BEGIN IMMEDIATE;
             DROP INDEX IF EXISTS live_resource_tab_position;
             DROP INDEX IF EXISTS live_resource_browser_view;
             CREATE TABLE resource_tabs_single_view (
               public_id TEXT PRIMARY KEY NOT NULL REFERENCES resource_identities(public_id),
               pane_id TEXT NOT NULL REFERENCES resource_panes(public_id)
                 DEFERRABLE INITIALLY DEFERRED,
               position INTEGER,
               content_kind TEXT NOT NULL CHECK(content_kind IN ('terminal','browser')),
               content_id TEXT UNIQUE NOT NULL REFERENCES resource_identities(public_id)
                 DEFERRABLE INITIALLY DEFERRED,
               name TEXT,
               created_revision INTEGER NOT NULL,
               updated_revision INTEGER NOT NULL,
               deleted_revision INTEGER,
               CHECK (
                 (deleted_revision IS NULL AND position IS NOT NULL) OR
                 (deleted_revision IS NOT NULL AND position IS NULL)
               )
             );
             INSERT INTO resource_tabs_single_view(
               public_id, pane_id, position, content_kind, content_id, name,
               created_revision, updated_revision, deleted_revision
             )
             SELECT public_id, pane_id, position, content_kind, content_id, name,
                    created_revision, updated_revision, deleted_revision
             FROM resource_tabs;
             DROP TABLE resource_tabs;
             ALTER TABLE resource_tabs_single_view RENAME TO resource_tabs;
             CREATE UNIQUE INDEX live_resource_tab_position
               ON resource_tabs(pane_id, position) WHERE deleted_revision IS NULL;
             UPDATE meta SET value = '10' WHERE key = 'schema_version';
             COMMIT;
             PRAGMA foreign_keys=ON;",
        )
        .unwrap();
    drop(legacy);

    let migrated = WorkspaceRegistry::open(&root, "session").unwrap();
    assert_eq!(
        required_meta(&migrated.connection, "schema_version").unwrap(),
        SCHEMA_VERSION.to_string()
    );
    let terminal_id = terminal_resource(TERMINAL_ONE);
    let second_tab = tab_id(2);
    migrated
        .connection
        .execute(
            "INSERT INTO resource_identities(
               public_id, kind, created_revision, updated_revision, deleted_revision
             ) VALUES(?1, 'tab', 2, 2, NULL)",
            [second_tab.as_str()],
        )
        .unwrap();
    migrated
        .connection
        .execute(
            "INSERT INTO resource_tabs(
               public_id, pane_id, position, content_kind, content_id, name,
               created_revision, updated_revision, deleted_revision
             ) VALUES(?1, ?2, 1, 'terminal', ?3, 'second view', 2, 2, NULL)",
            params![second_tab.as_str(), pane_id(1).as_str(), terminal_id.as_str()],
        )
        .unwrap();
    let live_views = migrated
        .connection
        .query_row(
            "SELECT COUNT(*) FROM resource_tabs
             WHERE content_id = ?1 AND deleted_revision IS NULL",
            [terminal_id.as_str()],
            |row| row.get::<_, i64>(0),
        )
        .unwrap();
    assert_eq!(live_views, 2);
    assert!(!migrated.session_journal_after(0, 10).unwrap().records.is_empty());
    drop(migrated);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn schema_thirteen_wraps_legacy_resource_api_frontend_projections() {
    let root = temp_root("schema-thirteen-frontend-projection");
    let projection_id =
        FrontendProjectionPublicId::parse(format!("projection_{:032x}", 13)).unwrap();
    {
        let mut registry = WorkspaceRegistry::open(&root, "session").unwrap();
        registry
            .put_frontend_projection(
                &WorkspaceMutation::new("legacy-projection", "resource-api").unwrap(),
                "resource-api",
                "session",
                projection_id.as_str(),
                1,
                Some(0),
                &json!({"selected_workspace":"alpha"}),
            )
            .unwrap();
        registry
            .connection
            .execute("UPDATE meta SET value = '13' WHERE key = 'schema_version'", [])
            .unwrap();
    }

    let migrated = WorkspaceRegistry::open(&root, "session").unwrap();
    assert_eq!(required_meta(&migrated.connection, "schema_version").unwrap(), "14");
    let projections = migrated.public_projections().unwrap().frontend_projections;
    assert_eq!(projections.len(), 1);
    assert_eq!(projections[0].schema_version, 2);
    assert_eq!(projections[0].projection["frontend_id"], "legacy-resource-api");
    assert_eq!(projections[0].projection["window_id"], projection_id.as_str());
    assert_eq!(projections[0].projection["generation"], "legacy-schema-13");
    assert_eq!(projections[0].projection["projection"], json!({"selected_workspace":"alpha"}));
    drop(migrated);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn terminal_journal_subject_expands_to_every_live_view_path() {
    let mut registry = WorkspaceRegistry::in_memory("journal-multiview-subjects").unwrap();
    commit_terminal_topology(&mut registry, "journal-multiview-seed");
    let terminal_id = terminal_resource(TERMINAL_ONE);
    let first_tab = tab_id(1);
    let second_tab = tab_id(2);
    registry
        .commit_resource_patch(
            &WorkspaceMutation::new("journal-multiview-second-view", "test").unwrap(),
            "terminal.project",
            &json!({"terminal_id":terminal_id,"pane_id":pane_id(1)}),
            None,
            Some(1),
            &ResourcePatch {
                changes: vec![
                    ResourceChange::UpsertPane(RegistryPane {
                        public_id: pane_id(1),
                        screen_id: screen_id(1),
                        name: Some("Shell".into()),
                        active_tab: Some(second_tab.clone()),
                        creation_ordinal: 1,
                    }),
                    ResourceChange::UpsertTab(RegistryTab {
                        public_id: second_tab.clone(),
                        pane_id: pane_id(1),
                        position: 1,
                        content_id: ContentPublicId::Terminal(terminal_id.clone()),
                        name: Some("second view".into()),
                        browser_url: None,
                        terminal_id: Some(TERMINAL_ONE.into()),
                    }),
                    ResourceChange::SetTabOrder {
                        pane_id: pane_id(1),
                        tab_ids: vec![first_tab.clone(), second_tab.clone()],
                    },
                ],
            },
            &json!({"terminal_id":terminal_id,"tab_id":second_tab}),
            &json!([{"kind":"upsert","resource":"terminal","id":terminal_id}]),
        )
        .unwrap();

    let record = registry
        .session_journal_after(0, 10)
        .unwrap()
        .records
        .into_iter()
        .find(|record| record.kind == "terminal.project")
        .unwrap();
    let pane = pane_id(1);
    let screen = screen_id(1);
    let workspace_id = workspace(1, "one", "One").public_id;
    for (kind, id) in [
        ("terminal", terminal_id.as_str()),
        ("tab", first_tab.as_str()),
        ("tab", second_tab.as_str()),
        ("pane", pane.as_str()),
        ("screen", screen.as_str()),
        ("workspace", workspace_id.as_str()),
    ] {
        assert!(
            record.subjects.iter().any(|subject| subject.kind == kind && subject.id == id),
            "missing {kind}:{id} from {:#?}",
            record.subjects
        );
    }
}

#[test]
fn terminal_journal_persists_exact_output_and_geometry_in_order() {
    let mut registry = WorkspaceRegistry::in_memory("journal-terminal-content").unwrap();
    commit_terminal_topology(&mut registry, "journal-terminal-content-seed");
    let terminal_id = terminal_resource(TERMINAL_ONE);
    let journal_terminal_id = Arc::new(terminal_id.clone());
    let output = b"prompt> \x1b[31merror\x1b[0m\r\n\0binary";

    let events = [
        crate::journal_ingress::JournalIngressEvent::TerminalOutput {
            terminal_id: journal_terminal_id.clone(),
            generation: "incarnation-one".into(),
            occurred_at_ms: 42,
            bytes: output.to_vec(),
        },
        crate::journal_ingress::JournalIngressEvent::TerminalResize {
            terminal_id: journal_terminal_id.clone(),
            generation: "incarnation-one".into(),
            occurred_at_ms: 43,
            cols: 120,
            rows: 40,
            cell_width: 9,
            cell_height: 18,
        },
        crate::journal_ingress::JournalIngressEvent::TerminalOutputGap {
            terminal_id: journal_terminal_id,
            generation: "incarnation-one".into(),
            occurred_at_ms: 44,
            reason: "detach_fence_failed",
        },
    ];
    let appended =
        registry.append_journal_ingress_events(&events.iter().collect::<Vec<_>>()).unwrap();
    assert_eq!(appended.len(), 3);

    let records = registry
        .session_journal_after(0, 32)
        .unwrap()
        .records
        .into_iter()
        .filter(|record| {
            matches!(
                record.kind.as_str(),
                "terminal.output" | "terminal.resized" | "terminal.output.gap"
            )
        })
        .collect::<Vec<_>>();
    assert_eq!(records.len(), 3);
    let output_record = &records[0];
    assert_eq!(output_record.kind, "terminal.output");
    assert_eq!(output_record.replay, JournalReplayPolicy::Required);
    assert_eq!(output_record.sensitivity, JournalSensitivity::Sensitive);
    assert_eq!(output_record.terminal_output.as_deref(), Some(output.as_slice()));
    assert!(output_record.payload.get("data").is_none());
    assert_eq!(output_record.payload["byte_count"], output.len().to_string());
    assert_eq!(output_record.payload["stream_offset_start"], "0");
    assert_eq!(output_record.payload["stream_offset_end"], output.len().to_string());
    assert_eq!(output_record.payload["encoding"], "raw");
    assert_eq!(output_record.payload["sha256"].as_str().unwrap().len(), 64);
    assert_eq!(output_record.authority.as_ref().unwrap().generation, "incarnation-one");

    let resize_record = &records[1];
    assert_eq!(resize_record.kind, "terminal.resized");
    assert!(resize_record.terminal_output.is_none());
    assert_eq!(resize_record.payload["cols"], 120);
    assert_eq!(resize_record.payload["rows"], 40);
    assert_eq!(resize_record.payload["cell_width"], 9);
    assert_eq!(resize_record.payload["cell_height"], 18);

    let gap_record = &records[2];
    assert_eq!(gap_record.kind, "terminal.output.gap");
    assert_eq!(gap_record.replay, JournalReplayPolicy::Required);
    assert!(gap_record.terminal_output.is_none());
    assert_eq!(gap_record.payload["format"], "cmux.terminal-output-gap.v1");
    assert_eq!(gap_record.payload["reason"], "detach_fence_failed");

    let pane = pane_id(1);
    let screen = screen_id(1);
    let workspace_id = workspace(1, "one", "One").public_id;
    for record in &records {
        for (kind, id) in [
            ("terminal", terminal_id.as_str()),
            ("tab", tab_id(1).as_str()),
            ("pane", pane.as_str()),
            ("screen", screen.as_str()),
            ("workspace", workspace_id.as_str()),
        ] {
            assert!(
                record.subjects.iter().any(|subject| subject.kind == kind && subject.id == id),
                "missing {kind}:{id} from {} subjects: {:#?}",
                record.kind,
                record.subjects
            );
        }
    }
}

#[test]
fn agent_projection_is_derived_from_pi_journal_and_reopen_preserves_continuity() {
    let root = temp_root("agent-pi-journal-projection");
    let terminal_id = terminal_resource(TERMINAL_ONE);
    let original_agent_projection_json = {
        let mut registry = WorkspaceRegistry::open(&root, "agent-pi-journal-projection").unwrap();
        commit_terminal_topology(&mut registry, "agent-pi-journal-projection-seed");
        let ingress = crate::agent_hook_journal_ingress(
            "pi",
            "agent_start",
            Some(terminal_id.as_str()),
            json!({
                "context":{"session_id":"pi-real-session-1","cwd":"/tmp/project"},
                "event":{"agent":{"id":"pi-worker-1"}}
            }),
        )
        .unwrap();
        let validated = crate::journal_kernel::ValidatedJournalIngress {
            class: JournalClass::Observation,
            replay: JournalReplayPolicy::Advisory,
            sensitivity: JournalSensitivity::Sensitive,
        };
        let commit = registry
            .append_journal_ingress(&ingress, &validated, "client_test", "pi_agent_start")
            .unwrap();
        assert!(!commit.replayed);

        let agents = registry.public_projections().unwrap().agents;
        assert_eq!(agents.len(), 1);
        assert_eq!(agents[0].terminal_id, terminal_id);
        assert_eq!(agents[0].state, "working");
        assert_eq!(agents[0].source, "hook");
        assert_eq!(agents[0].source_session.as_deref(), Some("pi-real-session-1"));
        assert_eq!(registry.resource_agent_projection_count_for_test().unwrap(), 1);
        let projection_json = registry
            .connection
            .query_row(
                "SELECT result_json FROM resource_agent_projections WHERE terminal_id = ?1",
                [terminal_id.as_str()],
                |row| row.get::<_, String>(0),
            )
            .unwrap();

        registry
            .connection
            .execute_batch(
                "DELETE FROM resource_agent_projections;
                 DELETE FROM meta WHERE key = 'agent_projection_journal_sequence_v1';",
            )
            .unwrap();
        assert!(
            registry.public_projections().unwrap().agents.is_empty(),
            "test must prove the projection can be rebuilt from the journal"
        );
        projection_json
    };

    let reopened = WorkspaceRegistry::open(&root, "agent-pi-journal-projection").unwrap();
    let rebuilt = reopened.public_projections().unwrap().agents;
    assert_eq!(rebuilt.len(), 1);
    assert_eq!(rebuilt[0].terminal_id, terminal_id);
    assert_eq!(rebuilt[0].state, "working");
    assert_eq!(rebuilt[0].source, "hook");
    assert_eq!(rebuilt[0].source_session.as_deref(), Some("pi-real-session-1"));
    let rebuilt_agent_projection_json = reopened
        .connection
        .query_row(
            "SELECT result_json FROM resource_agent_projections WHERE terminal_id = ?1",
            [terminal_id.as_str()],
            |row| row.get::<_, String>(0),
        )
        .unwrap();
    assert_eq!(
        rebuilt_agent_projection_json, original_agent_projection_json,
        "AgentProjection rebuild must be byte-for-byte deterministic"
    );
    let interrupted = reopened
        .session_journal_after(0, 1024)
        .unwrap()
        .records
        .into_iter()
        .filter(|record| record.kind == "agent.session.interrupted")
        .collect::<Vec<_>>();
    assert!(
        interrupted.is_empty(),
        "registry reopen must not classify interruption without durable host-death evidence"
    );
    drop(reopened);

    let reopened_again = WorkspaceRegistry::open(&root, "agent-pi-journal-projection").unwrap();
    let interrupted_again = reopened_again
        .session_journal_after(0, 1024)
        .unwrap()
        .records
        .into_iter()
        .filter(|record| record.kind == "agent.session.interrupted")
        .count();
    assert_eq!(
        interrupted_again, 0,
        "duplicate reopen must not invent or duplicate interruption records"
    );
    drop(reopened_again);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn journal_agent_projection_cursor_advances_and_replays_only_a_suffix() {
    let root = temp_root("journal-agent-projection-cursor");
    let session = "journal-agent-projection-cursor";
    let database = root.join(session_storage_component(session)).join(WORKSPACE_REGISTRY_FILE);
    let (agent_sequence, head_sequence) = {
        let mut registry = WorkspaceRegistry::open(&root, session).unwrap();
        commit_terminal_topology(&mut registry, "journal-agent-projection-cursor-topology");
        let terminal_id = terminal_resource(TERMINAL_ONE);
        let ingress = crate::agent_hook_journal_ingress(
            "pi",
            "agent_start",
            Some(terminal_id.as_str()),
            json!({
                "context":{"session_id":"pi-cursor-session","cwd":"/tmp/project"},
                "event":{"agent":{"id":"pi-cursor-worker"}}
            }),
        )
        .unwrap();
        let validated = crate::journal_kernel::ValidatedJournalIngress {
            class: JournalClass::Observation,
            replay: JournalReplayPolicy::Advisory,
            sensitivity: JournalSensitivity::Sensitive,
        };
        let agent_sequence = registry
            .append_journal_ingress(
                &ingress,
                &validated,
                "client_cursor",
                "journal_agent_projection_cursor",
            )
            .unwrap()
            .sequence;
        let applied = registry
            .connection
            .query_row(
                "SELECT value FROM meta WHERE key = 'agent_projection_journal_sequence_v1'",
                [],
                |row| row.get::<_, String>(0),
            )
            .unwrap()
            .parse::<u64>()
            .unwrap();
        assert_eq!(applied, agent_sequence);

        let producer = JournalProducer { kind: "test".into(), id: "cursor".into() };
        let payload = json!({"marker":"trailing non-agent record"});
        let tx = registry.connection.unchecked_transaction().unwrap();
        let head_sequence = session_journal::append_journal_record(
            &tx,
            &session_journal::JournalAppend {
                event_id: "event_agent_cursor_trailing_record",
                schema_version: 1,
                kind: "test.cursor.marker",
                class: JournalClass::Observation,
                replay: JournalReplayPolicy::Never,
                occurred_at_ms: 1,
                producer: &producer,
                authority: None,
                causation_id: None,
                correlation_id: None,
                causation_depth: 0,
                subjects: &[],
                sensitivity: JournalSensitivity::Metadata,
                payload: &payload,
                content: None,
                resource_revision: None,
                previous_resource_revision: None,
            },
        )
        .unwrap();
        tx.commit().unwrap();
        assert!(head_sequence > agent_sequence);
        (agent_sequence, head_sequence)
    };

    Connection::open(&database)
        .unwrap()
        .execute(
            "UPDATE meta SET value = ?1
             WHERE key = 'agent_projection_journal_sequence_v1'",
            [agent_sequence.saturating_sub(1).to_string()],
        )
        .unwrap();

    let reopened = WorkspaceRegistry::open(&root, session).unwrap();
    let applied = reopened
        .connection
        .query_row(
            "SELECT value FROM meta WHERE key = 'agent_projection_journal_sequence_v1'",
            [],
            |row| row.get::<_, String>(0),
        )
        .unwrap()
        .parse::<u64>()
        .unwrap();
    assert_eq!(applied, head_sequence);
    let agents = reopened.public_projections().unwrap().agents;
    assert_eq!(agents.len(), 1);
    assert_eq!(agents[0].state, "working");
    drop(reopened);

    let reopened_again = WorkspaceRegistry::open(&root, session).unwrap();
    let applied_again = reopened_again
        .connection
        .query_row(
            "SELECT value FROM meta WHERE key = 'agent_projection_journal_sequence_v1'",
            [],
            |row| row.get::<_, String>(0),
        )
        .unwrap()
        .parse::<u64>()
        .unwrap();
    assert_eq!(applied_again, head_sequence);
    drop(reopened_again);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn journal_agent_projection_rebuild_is_bounded_and_resumable() {
    const EVENT_COUNT: usize = 1_025;

    let root = temp_root("journal-agent-bounded-rebuild");
    let session = "journal-agent-bounded-rebuild";
    let database = root.join(session_storage_component(session)).join(WORKSPACE_REGISTRY_FILE);
    let head_sequence = {
        let mut registry = WorkspaceRegistry::open(&root, session).unwrap();
        commit_terminal_topology(&mut registry, "journal-agent-bounded-rebuild-topology");
        let producer = JournalProducer { kind: "test".into(), id: "bounded-rebuild".into() };
        let payload = json!({});
        let tx = registry.connection.unchecked_transaction().unwrap();
        let mut head_sequence = 0;
        for index in 0..EVENT_COUNT {
            let event_id = format!("event_agent_bounded_rebuild_{index:04}");
            head_sequence = session_journal::append_journal_record(
                &tx,
                &session_journal::JournalAppend {
                    event_id: &event_id,
                    schema_version: 1,
                    kind: "agent.unknown",
                    class: JournalClass::Observation,
                    replay: JournalReplayPolicy::Advisory,
                    occurred_at_ms: index as u64,
                    producer: &producer,
                    authority: None,
                    causation_id: None,
                    correlation_id: None,
                    causation_depth: 0,
                    subjects: &[],
                    sensitivity: JournalSensitivity::Metadata,
                    payload: &payload,
                    content: None,
                    resource_revision: None,
                    previous_resource_revision: None,
                },
            )
            .unwrap();
        }
        tx.commit().unwrap();
        head_sequence
    };

    Connection::open(&database)
        .unwrap()
        .execute_batch(
            "DELETE FROM meta
             WHERE key IN (
               'agent_projection_journal_sequence_v1',
               'agent_projection_journal_candidate_sequence_v1'
             );",
        )
        .unwrap();

    let reopened = WorkspaceRegistry::open(&root, session).unwrap();
    let first_cursor = reopened
        .connection
        .query_row(
            "SELECT value FROM meta WHERE key = 'agent_projection_journal_sequence_v1'",
            [],
            |row| row.get::<_, String>(0),
        )
        .unwrap()
        .parse::<u64>()
        .unwrap();
    assert!(
        first_cursor < head_sequence,
        "one open must not scan the complete journal when the rebuild exceeds one page"
    );
    drop(reopened);

    let reopened_again = WorkspaceRegistry::open(&root, session).unwrap();
    let resumed_cursor = reopened_again
        .connection
        .query_row(
            "SELECT value FROM meta WHERE key = 'agent_projection_journal_sequence_v1'",
            [],
            |row| row.get::<_, String>(0),
        )
        .unwrap()
        .parse::<u64>()
        .unwrap();
    assert_eq!(resumed_cursor, head_sequence);
    drop(reopened_again);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn journal_agent_generation_backfill_runs_once() {
    let root = temp_root("journal-agent-generation-backfill-once");
    let session = "journal-agent-generation-backfill-once";
    let terminal_id = terminal_resource(TERMINAL_ONE);
    {
        let mut registry = WorkspaceRegistry::open(&root, session).unwrap();
        commit_terminal_topology(&mut registry, "journal-agent-generation-backfill-once-topology");
        let current = json!({
            "id":agent_resource(&terminal_id),
            "session_id":registry.session_id(),
            "terminal_id":terminal_id,
            "state":"working",
            "source":"socket",
            "updated_at_ms":"1",
            "source_session":"current-generation-session",
            "extra":{"provider":"pi"},
        });
        registry
            .commit_agent_projection(
                &WorkspaceMutation::new("journal-agent-current-generation", "socket-test").unwrap(),
                &json!({"source_session":"current-generation-session"}),
                Some(1),
                &terminal_id,
                &current,
                &json!([]),
            )
            .unwrap();
        let late_historical = canonical_json(&json!({
            "id":agent_resource(&terminal_id),
            "session_id":registry.session_id(),
            "terminal_id":terminal_id,
            "state":"done",
            "source":"socket",
            "updated_at_ms":"2",
            "source_session":"late-historical-generation",
            "extra":{"provider":"pi"},
        }))
        .unwrap();
        registry
            .connection
            .execute(
                "INSERT INTO resource_mutations(
                   idempotency_key, origin, operation, fingerprint,
                   result_json, committed_revision
                 ) VALUES('journal-agent-late-historical-report', 'test',
                          'agent.report', 'late-historical', ?1, 2)",
                [late_historical],
            )
            .unwrap();
    }

    let reopened = WorkspaceRegistry::open(&root, session).unwrap();
    let imported = reopened
        .connection
        .query_row(
            "SELECT COUNT(*) FROM resource_agent_session_generations
             WHERE terminal_id = ?1 AND provider = 'pi'
               AND source_session = 'late-historical-generation'",
            [terminal_id.as_str()],
            |row| row.get::<_, i64>(0),
        )
        .unwrap();
    assert_eq!(imported, 0);
    drop(reopened);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn journal_agent_live_session_waits_in_journal_for_pending_rebuild() {
    const EVENT_COUNT: usize = 1_025;

    let root = temp_root("journal-agent-live-during-rebuild");
    let session = "journal-agent-live-during-rebuild";
    let database = root.join(session_storage_component(session)).join(WORKSPACE_REGISTRY_FILE);
    let terminal_id = terminal_resource(TERMINAL_ONE);
    {
        let mut registry = WorkspaceRegistry::open(&root, session).unwrap();
        commit_terminal_topology(&mut registry, "journal-agent-live-during-rebuild-topology");
        let result = json!({
            "id":agent_resource(&terminal_id),
            "session_id":registry.session_id(),
            "terminal_id":terminal_id,
            "state":"working",
            "source":"socket",
            "updated_at_ms":"1",
            "source_session":"session-before-rebuild",
            "extra":{"provider":"pi"},
        });
        registry
            .commit_agent_projection(
                &WorkspaceMutation::new("journal-agent-before-rebuild", "socket-test").unwrap(),
                &json!({"source_session":"session-before-rebuild"}),
                Some(1),
                &terminal_id,
                &result,
                &json!([]),
            )
            .unwrap();

        let producer = JournalProducer { kind: "test".into(), id: "live-rebuild".into() };
        let payload = json!({});
        let tx = registry.connection.unchecked_transaction().unwrap();
        for index in 0..EVENT_COUNT {
            let event_id = format!("event_agent_live_rebuild_{index:04}");
            session_journal::append_journal_record(
                &tx,
                &session_journal::JournalAppend {
                    event_id: &event_id,
                    schema_version: 1,
                    kind: "agent.unknown",
                    class: JournalClass::Observation,
                    replay: JournalReplayPolicy::Advisory,
                    occurred_at_ms: index as u64,
                    producer: &producer,
                    authority: None,
                    causation_id: None,
                    correlation_id: None,
                    causation_depth: 0,
                    subjects: &[],
                    sensitivity: JournalSensitivity::Metadata,
                    payload: &payload,
                    content: None,
                    resource_revision: None,
                    previous_resource_revision: None,
                },
            )
            .unwrap();
        }
        tx.commit().unwrap();
    }
    Connection::open(&database)
        .unwrap()
        .execute(
            "DELETE FROM meta
             WHERE key IN (
               'agent_projection_journal_sequence_v1',
               'agent_projection_journal_candidate_sequence_v1',
               'agent_projection_journal_rebuild_target_sequence_v1'
             )",
            [],
        )
        .unwrap();

    let mut reopened = WorkspaceRegistry::open(&root, session).unwrap();
    assert!(reopened.agent_projection_rebuild_pending().unwrap());
    let ingress = crate::agent_hook_journal_ingress(
        "pi",
        "SessionStart",
        Some(terminal_id.as_str()),
        json!({"session_id":"session-during-rebuild"}),
    )
    .unwrap();
    let validated = crate::journal_kernel::ValidatedJournalIngress {
        class: JournalClass::Observation,
        replay: JournalReplayPolicy::Advisory,
        sensitivity: JournalSensitivity::Sensitive,
    };
    reopened
        .append_journal_ingress(
            &ingress,
            &validated,
            "client_live_during_rebuild",
            "journal_agent_live_during_rebuild",
        )
        .unwrap();

    for _ in 0..4 {
        if reopened.continue_agent_projection_rebuild().unwrap() {
            break;
        }
    }
    assert!(!reopened.agent_projection_rebuild_pending().unwrap());
    let agent = reopened.public_projections().unwrap().agents.remove(0);
    assert_eq!(agent.source, "hook");
    assert_eq!(agent.source_session.as_deref(), Some("session-during-rebuild"));
    drop(reopened);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn journal_agent_projection_rebuild_continues_in_owned_mux_worker() {
    const EVENT_COUNT: usize = 1_025;

    let root = temp_root("journal-agent-owned-rebuild");
    let session = "journal-agent-owned-rebuild";
    let database = root.join(session_storage_component(session)).join(WORKSPACE_REGISTRY_FILE);
    {
        let registry = WorkspaceRegistry::open(&root, session).unwrap();
        let producer = JournalProducer { kind: "test".into(), id: "owned-rebuild".into() };
        let payload = json!({});
        let tx = registry.connection.unchecked_transaction().unwrap();
        for index in 0..EVENT_COUNT {
            let event_id = format!("event_agent_owned_rebuild_{index:04}");
            session_journal::append_journal_record(
                &tx,
                &session_journal::JournalAppend {
                    event_id: &event_id,
                    schema_version: 1,
                    kind: "agent.unknown",
                    class: JournalClass::Observation,
                    replay: JournalReplayPolicy::Advisory,
                    occurred_at_ms: index as u64,
                    producer: &producer,
                    authority: None,
                    causation_id: None,
                    correlation_id: None,
                    causation_depth: 0,
                    subjects: &[],
                    sensitivity: JournalSensitivity::Metadata,
                    payload: &payload,
                    content: None,
                    resource_revision: None,
                    previous_resource_revision: None,
                },
            )
            .unwrap();
        }
        tx.commit().unwrap();
    }
    Connection::open(&database)
        .unwrap()
        .execute_batch(
            "DELETE FROM meta
             WHERE key IN (
               'agent_projection_journal_sequence_v1',
               'agent_projection_journal_candidate_sequence_v1'
             );",
        )
        .unwrap();

    let mux =
        crate::Mux::open_persistent(session, crate::SurfaceOptions::default(), &root).unwrap();
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    let mut epoch = mux.journal_event_epoch();
    while mux.agent_projection_rebuild_pending_for_test().unwrap() {
        let remaining = deadline.saturating_duration_since(std::time::Instant::now());
        assert!(!remaining.is_zero(), "owned agent projection rebuild did not complete");
        epoch = mux.wait_for_journal_event(epoch, remaining);
    }
    assert!(!mux.agent_projection_rebuild_pending_for_test().unwrap());
    mux.shutdown();
    drop(mux);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn journal_agent_projection_rebuild_keeps_live_terminal_projection_visible() {
    let mut registry = WorkspaceRegistry::in_memory("journal-agent-live-during-rebuild").unwrap();
    commit_terminal_topology(&mut registry, "journal-agent-live-during-rebuild-topology");
    let terminal_id = terminal_resource(TERMINAL_ONE);
    let ingress = crate::agent_hook_journal_ingress(
        "pi",
        "AgentStart",
        Some(terminal_id.as_str()),
        json!({"session_id":"live-during-rebuild"}),
    )
    .unwrap();
    let validated = crate::journal_kernel::ValidatedJournalIngress {
        class: JournalClass::Observation,
        replay: JournalReplayPolicy::Advisory,
        sensitivity: JournalSensitivity::Sensitive,
    };
    registry
        .append_journal_ingress(
            &ingress,
            &validated,
            "client_live_during_rebuild",
            "journal_agent_live_during_rebuild",
        )
        .unwrap();
    registry
        .connection
        .execute(
            "INSERT INTO meta(key, value)
             VALUES ('agent_projection_journal_rebuild_target_sequence_v1', '999999')
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            [],
        )
        .unwrap();

    let full_agents = registry.public_projections().unwrap().agents;
    assert_eq!(full_agents.len(), 1);
    assert_eq!(full_agents[0].terminal_id, terminal_id);
    assert_eq!(full_agents[0].state, "working");
    assert_eq!(full_agents[0].source, "hook");
    let agents = registry.public_agent_projections(Some(&terminal_id), None).unwrap();
    assert_eq!(agents.len(), 1);
    assert_eq!(agents[0].state, "working");
    assert_eq!(agents[0].source, "hook");
}

#[test]
fn journal_agent_legacy_upgrade_without_candidate_replays_hook_events() {
    let root = temp_root("journal-agent-upgrade-without-candidate");
    let session = "journal-agent-upgrade-without-candidate";
    let database = root.join(session_storage_component(session)).join(WORKSPACE_REGISTRY_FILE);
    let terminal_id = terminal_resource(TERMINAL_ONE);
    {
        let mut registry = WorkspaceRegistry::open(&root, session).unwrap();
        commit_terminal_topology(&mut registry, "journal-agent-upgrade-without-candidate-topology");
        let ingress = crate::agent_hook_journal_ingress(
            "pi",
            "AgentStart",
            Some(terminal_id.as_str()),
            json!({"session_id":"legacy-hook-session"}),
        )
        .unwrap();
        let validated = crate::journal_kernel::ValidatedJournalIngress {
            class: JournalClass::Observation,
            replay: JournalReplayPolicy::Advisory,
            sensitivity: JournalSensitivity::Sensitive,
        };
        registry
            .append_journal_ingress(
                &ingress,
                &validated,
                "client_upgrade_without_candidate",
                "journal_agent_upgrade_without_candidate",
            )
            .unwrap();
    }

    Connection::open(&database)
        .unwrap()
        .execute_batch(
            "DELETE FROM resource_agent_projections;
             DELETE FROM meta
             WHERE key IN (
               'agent_projection_journal_sequence_v1',
               'agent_projection_journal_candidate_sequence_v1'
             );",
        )
        .unwrap();

    let reopened = WorkspaceRegistry::open(&root, session).unwrap();
    let agent = reopened.public_projections().unwrap().agents.remove(0);
    assert_eq!(agent.state, "working");
    assert_eq!(agent.source, "hook");
    assert_eq!(agent.source_session.as_deref(), Some("legacy-hook-session"));
    drop(reopened);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn journal_agent_rebuild_includes_resource_agent_reports() {
    let root = temp_root("journal-agent-resource-report-rebuild");
    let session = "journal-agent-resource-report-rebuild";
    let database = root.join(session_storage_component(session)).join(WORKSPACE_REGISTRY_FILE);
    let terminal_id = terminal_resource(TERMINAL_ONE);
    {
        let mut registry = WorkspaceRegistry::open(&root, session).unwrap();
        commit_terminal_topology(&mut registry, "journal-agent-resource-report-rebuild-topology");
        let result = json!({
            "id":agent_resource(&terminal_id),
            "session_id":registry.session_id(),
            "terminal_id":terminal_id,
            "state":"idle",
            "source":"socket",
            "updated_at_ms":"42",
            "source_session":"resource-report-session",
            "extra":{"provider":"socket-test"},
        });
        registry
            .commit_agent_projection(
                &WorkspaceMutation::new("journal-agent-resource-report-rebuild", "socket-test")
                    .unwrap(),
                &json!({"source_session":"resource-report-session"}),
                Some(1),
                &terminal_id,
                &result,
                &json!([]),
            )
            .unwrap();
    }

    Connection::open(&database)
        .unwrap()
        .execute_batch(
            "DELETE FROM resource_agent_projections;
             DELETE FROM meta
             WHERE key IN (
               'agent_projection_journal_sequence_v1',
               'agent_projection_journal_candidate_sequence_v1'
             );",
        )
        .unwrap();

    let reopened = WorkspaceRegistry::open(&root, session).unwrap();
    let agent = reopened.public_projections().unwrap().agents.remove(0);
    assert_eq!(agent.state, "idle");
    assert_eq!(agent.source, "socket");
    assert_eq!(agent.source_session.as_deref(), Some("resource-report-session"));
    drop(reopened);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn journal_agent_legacy_upgrade_reads_only_indexed_agent_events() {
    let root = temp_root("journal-agent-indexed-upgrade");
    let session = "journal-agent-indexed-upgrade";
    let database = root.join(session_storage_component(session)).join(WORKSPACE_REGISTRY_FILE);
    let terminal_id = terminal_resource(TERMINAL_ONE);
    {
        let mut registry = WorkspaceRegistry::open(&root, session).unwrap();
        commit_terminal_topology(&mut registry, "journal-agent-indexed-upgrade-topology");
        let ingress = crate::agent_hook_journal_ingress(
            "pi",
            "agent_start",
            Some(terminal_id.as_str()),
            json!({"context":{"session_id":"indexed-upgrade-session"}}),
        )
        .unwrap();
        let validated = crate::journal_kernel::ValidatedJournalIngress {
            class: JournalClass::Observation,
            replay: JournalReplayPolicy::Advisory,
            sensitivity: JournalSensitivity::Sensitive,
        };
        registry
            .append_journal_ingress(
                &ingress,
                &validated,
                "client_indexed_upgrade",
                "journal_agent_indexed_upgrade",
            )
            .unwrap();
    }

    Connection::open(&database)
        .unwrap()
        .execute_batch(
            "DROP TRIGGER session_journal_reject_update;
             UPDATE session_journal
             SET producer_json = '{}'
             WHERE event_id = 'event_resource_00000000000000000001';
             CREATE TRIGGER session_journal_reject_update
             BEFORE UPDATE ON session_journal
             BEGIN SELECT RAISE(ABORT, 'session journal is append-only'); END;
             DELETE FROM resource_agent_projections;
             DELETE FROM meta WHERE key = 'agent_projection_journal_sequence_v1';",
        )
        .unwrap();

    let reopened = WorkspaceRegistry::open(&root, session).unwrap();
    let agents = reopened.public_projections().unwrap().agents;
    assert_eq!(agents.len(), 1);
    assert_eq!(agents[0].terminal_id, terminal_id);
    assert_eq!(agents[0].state, "working");
    assert_eq!(agents[0].source_session.as_deref(), Some("indexed-upgrade-session"));
    drop(reopened);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn journal_agent_rebuild_skips_indexed_archived_non_agent_segments() {
    let root = temp_root("journal-agent-indexed-archive");
    let session = "journal-agent-indexed-archive";
    let database = root.join(session_storage_component(session)).join(WORKSPACE_REGISTRY_FILE);
    let terminal_id = terminal_resource(TERMINAL_ONE);
    {
        let mut registry = WorkspaceRegistry::open(&root, session).unwrap();
        commit_terminal_topology(&mut registry, "journal-agent-indexed-archive-topology");
        let through = registry.session_journal_after(0, 32).unwrap().head_sequence;
        registry
            .create_journal_checkpoint(
                through,
                1,
                &json!({
                    "session_snapshot":{"cursor":{"revision":"1"}},
                    "journal_extensions":{"producers":[],"hooks":[]},
                }),
                &[],
                "client_indexed_archive",
                "journal_agent_indexed_archive_checkpoint",
            )
            .unwrap();
        let plan = match registry
            .begin_journal_segment_seal(
                through,
                "client_indexed_archive",
                "journal_agent_indexed_archive_segment",
            )
            .unwrap()
        {
            JournalSegmentSealStart::Prepare(plan) => plan,
            JournalSegmentSealStart::Replay(_) => {
                panic!("first non-agent segment seal unexpectedly replayed")
            }
        };
        let reader = SessionJournalReader::open(&database).unwrap();
        let prepared = plan.prepare(&reader).unwrap();
        registry
            .commit_journal_segment_seal(
                prepared,
                "client_indexed_archive",
                "journal_agent_indexed_archive_segment",
            )
            .unwrap()
            .expect("non-agent segment boundary remained stable");
        drop(reader);

        let ingress = crate::agent_hook_journal_ingress(
            "pi",
            "agent_start",
            Some(terminal_id.as_str()),
            json!({"context":{"session_id":"indexed-archive-session"}}),
        )
        .unwrap();
        let validated = crate::journal_kernel::ValidatedJournalIngress {
            class: JournalClass::Observation,
            replay: JournalReplayPolicy::Advisory,
            sensitivity: JournalSensitivity::Sensitive,
        };
        registry
            .append_journal_ingress(
                &ingress,
                &validated,
                "client_indexed_archive",
                "journal_agent_indexed_archive_start",
            )
            .unwrap();
    }

    Connection::open(&database)
        .unwrap()
        .execute_batch(
            "DROP TRIGGER journal_segments_reject_update;
             UPDATE journal_segments SET content = X'00';
             CREATE TRIGGER journal_segments_reject_update
             BEFORE UPDATE ON journal_segments
             BEGIN SELECT RAISE(ABORT, 'journal segments are immutable'); END;
             DELETE FROM resource_agent_projections;
             DELETE FROM meta
             WHERE key IN (
               'agent_projection_journal_sequence_v1',
               'agent_projection_journal_candidate_sequence_v1'
             );",
        )
        .unwrap();

    let reopened = WorkspaceRegistry::open(&root, session).unwrap();
    let agent = reopened.public_projections().unwrap().agents.remove(0);
    assert_eq!(agent.state, "working");
    assert_eq!(agent.source, "hook");
    assert_eq!(agent.source_session.as_deref(), Some("indexed-archive-session"));
    drop(reopened);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn journal_agent_legacy_upgrade_backfills_archived_agent_event_kinds() {
    let root = temp_root("journal-agent-legacy-archived-kind");
    let session = "journal-agent-legacy-archived-kind";
    let database = root.join(session_storage_component(session)).join(WORKSPACE_REGISTRY_FILE);
    let terminal_id = terminal_resource(TERMINAL_ONE);
    {
        let mut registry = WorkspaceRegistry::open(&root, session).unwrap();
        commit_terminal_topology(&mut registry, "journal-agent-legacy-archived-kind-topology");
        let ingress = crate::agent_hook_journal_ingress(
            "pi",
            "agent_start",
            Some(terminal_id.as_str()),
            json!({"context":{"session_id":"legacy-archived-session"}}),
        )
        .unwrap();
        let validated = crate::journal_kernel::ValidatedJournalIngress {
            class: JournalClass::Observation,
            replay: JournalReplayPolicy::Advisory,
            sensitivity: JournalSensitivity::Sensitive,
        };
        registry
            .append_journal_ingress(
                &ingress,
                &validated,
                "client_legacy_archived_kind",
                "journal_agent_legacy_archived_kind_start",
            )
            .unwrap();
        let through = registry.session_journal_after(0, 32).unwrap().head_sequence;
        registry
            .create_journal_checkpoint(
                through,
                1,
                &json!({
                    "session_snapshot":{"cursor":{"revision":"1"}},
                    "journal_extensions":{"producers":[],"hooks":[]},
                }),
                &[],
                "client_legacy_archived_kind",
                "journal_agent_legacy_archived_kind_checkpoint",
            )
            .unwrap();
        let plan = match registry
            .begin_journal_segment_seal(
                through,
                "client_legacy_archived_kind",
                "journal_agent_legacy_archived_kind_segment",
            )
            .unwrap()
        {
            JournalSegmentSealStart::Prepare(plan) => plan,
            JournalSegmentSealStart::Replay(_) => panic!("first archived agent seal replayed"),
        };
        let reader = SessionJournalReader::open(&database).unwrap();
        let prepared = plan.prepare(&reader).unwrap();
        registry
            .commit_journal_segment_seal(
                prepared,
                "client_legacy_archived_kind",
                "journal_agent_legacy_archived_kind_segment",
            )
            .unwrap()
            .expect("archived agent segment boundary remained stable");
    }

    Connection::open(&database)
        .unwrap()
        .execute_batch(
            "UPDATE journal_event_index SET kind = NULL;
             DELETE FROM resource_agent_projections;
             DELETE FROM meta
             WHERE key IN (
               'agent_projection_journal_sequence_v1',
               'agent_projection_journal_candidate_sequence_v1',
               'agent_projection_journal_rebuild_target_sequence_v1'
             );",
        )
        .unwrap();

    let reopened = WorkspaceRegistry::open(&root, session).unwrap();
    assert!(reopened.agent_projection_rebuild_pending().unwrap());
    assert!(reopened.public_projections().unwrap().agents.is_empty());
    let missing_kinds = reopened
        .connection
        .query_row("SELECT COUNT(*) FROM journal_event_index WHERE kind IS NULL", [], |row| {
            row.get::<_, i64>(0)
        })
        .unwrap();
    assert!(missing_kinds > 0, "open must defer archived segment decoding");
    assert!(reopened.continue_agent_projection_rebuild().unwrap());
    let agent = reopened.public_projections().unwrap().agents.remove(0);
    assert_eq!(agent.state, "working");
    assert_eq!(agent.source, "hook");
    assert_eq!(agent.source_session.as_deref(), Some("legacy-archived-session"));
    drop(reopened);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn journal_agent_kind_backfill_uses_the_missing_kind_index() {
    let registry = WorkspaceRegistry::in_memory("journal-agent-kind-backfill-index").unwrap();
    let plan = {
        let mut statement = registry
            .connection
            .prepare(
                "EXPLAIN QUERY PLAN
                 SELECT event.sequence
                 FROM journal_event_index event
                      INDEXED BY journal_event_index_by_missing_kind_sequence
                 JOIN session_journal journal ON journal.sequence = event.sequence
                 WHERE event.kind IS NULL
                 ORDER BY event.sequence ASC
                 LIMIT 1024",
            )
            .unwrap();
        statement
            .query_map([], |row| row.get::<_, String>(3))
            .unwrap()
            .collect::<Result<Vec<_>, _>>()
            .unwrap()
    };
    assert!(
        plan.iter().any(|detail| detail.contains("journal_event_index_by_missing_kind_sequence")),
        "missing-kind scan must use its partial sequence index: {plan:#?}"
    );
}

#[test]
fn journal_agent_legacy_upgrade_keeps_later_stored_socket_projection() {
    let root = temp_root("journal-agent-upgrade-stored-socket");
    let session = "journal-agent-upgrade-stored-socket";
    let database = root.join(session_storage_component(session)).join(WORKSPACE_REGISTRY_FILE);
    let terminal_id = terminal_resource(TERMINAL_ONE);
    {
        let mut registry = WorkspaceRegistry::open(&root, session).unwrap();
        commit_terminal_topology(&mut registry, "journal-agent-upgrade-stored-socket-topology");
        let ingress = crate::agent_hook_journal_ingress(
            "pi",
            "agent_start",
            Some(terminal_id.as_str()),
            json!({"context":{"session_id":"old-hook-session"}}),
        )
        .unwrap();
        let validated = crate::journal_kernel::ValidatedJournalIngress {
            class: JournalClass::Observation,
            replay: JournalReplayPolicy::Advisory,
            sensitivity: JournalSensitivity::Sensitive,
        };
        registry
            .append_journal_ingress(
                &ingress,
                &validated,
                "client_upgrade_socket",
                "journal_agent_upgrade_old_hook",
            )
            .unwrap();
        let socket_updated_at = unix_epoch_ms().unwrap().saturating_add(1_000);
        let result = json!({
            "id":agent_resource(&terminal_id),
            "session_id":registry.session_id(),
            "terminal_id":terminal_id,
            "state":"done",
            "source":"socket",
            "updated_at_ms":socket_updated_at.to_string(),
            "source_session":"old-hook-session",
            "extra":{"provider":"pi"},
        });
        registry
            .commit_agent_projection(
                &WorkspaceMutation::new("journal-agent-upgrade-socket", "socket-test").unwrap(),
                &json!({"source_session":"old-hook-session"}),
                Some(1),
                &terminal_id,
                &result,
                &json!([]),
            )
            .unwrap();
    }
    Connection::open(&database)
        .unwrap()
        .execute("DELETE FROM meta WHERE key = 'agent_projection_journal_sequence_v1'", [])
        .unwrap();

    let reopened = WorkspaceRegistry::open(&root, session).unwrap();
    let agent = reopened.public_projections().unwrap().agents.remove(0);
    assert_eq!(agent.state, "done");
    assert_eq!(agent.source, "socket");
    assert_eq!(agent.source_session.as_deref(), Some("old-hook-session"));
    drop(reopened);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn journal_agent_legacy_upgrade_keeps_later_journal_session_start() {
    let root = temp_root("journal-agent-upgrade-later-hook");
    let session = "journal-agent-upgrade-later-hook";
    let database = root.join(session_storage_component(session)).join(WORKSPACE_REGISTRY_FILE);
    let terminal_id = terminal_resource(TERMINAL_ONE);
    let stored_socket_json = {
        let mut registry = WorkspaceRegistry::open(&root, session).unwrap();
        commit_terminal_topology(&mut registry, "journal-agent-upgrade-later-hook-topology");
        let result = json!({
            "id":agent_resource(&terminal_id),
            "session_id":registry.session_id(),
            "terminal_id":terminal_id,
            "state":"working",
            "source":"socket",
            "updated_at_ms":"2",
            "source_session":"old-socket-session",
            "extra":{"provider":"socket-test"},
        });
        registry
            .commit_agent_projection(
                &WorkspaceMutation::new("journal-agent-upgrade-old-socket", "socket-test").unwrap(),
                &json!({"source_session":"old-socket-session"}),
                Some(1),
                &terminal_id,
                &result,
                &json!([]),
            )
            .unwrap();

        let ingress = crate::agent_hook_journal_ingress(
            "pi",
            "SessionStart",
            Some(terminal_id.as_str()),
            json!({"session_id":"new-hook-session"}),
        )
        .unwrap();
        let validated = crate::journal_kernel::ValidatedJournalIngress {
            class: JournalClass::Observation,
            replay: JournalReplayPolicy::Advisory,
            sensitivity: JournalSensitivity::Sensitive,
        };
        registry
            .append_journal_ingress(
                &ingress,
                &validated,
                "client_upgrade_later_hook",
                "journal_agent_upgrade_later_hook",
            )
            .unwrap();
        canonical_json(&result).unwrap()
    };
    Connection::open(&database)
        .unwrap()
        .execute(
            "UPDATE resource_agent_projections
             SET result_json = ?1, committed_revision = 2
             WHERE terminal_id = ?2",
            params![stored_socket_json, terminal_id.as_str()],
        )
        .unwrap();
    Connection::open(&database)
        .unwrap()
        .execute("DELETE FROM meta WHERE key = 'agent_projection_journal_sequence_v1'", [])
        .unwrap();

    let reopened = WorkspaceRegistry::open(&root, session).unwrap();
    let agent = reopened.public_projections().unwrap().agents.remove(0);
    assert_eq!(agent.state, "idle");
    assert_eq!(agent.source, "hook");
    assert_eq!(agent.source_session.as_deref(), Some("new-hook-session"));
    drop(reopened);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn journal_agent_append_applies_a_contiguous_projection_prefix() {
    let root = temp_root("journal-agent-contiguous-projection");
    let session = "journal-agent-contiguous-projection";
    let terminal_id = terminal_resource(TERMINAL_ONE);
    {
        let mut registry = WorkspaceRegistry::open(&root, session).unwrap();
        commit_terminal_topology(&mut registry, "journal-agent-contiguous-topology");
        let ingress = crate::agent_hook_journal_ingress(
            "pi",
            "agent_start",
            Some(terminal_id.as_str()),
            json!({"context":{"session_id":"pi-contiguous-session"}}),
        )
        .unwrap();
        let validated = crate::journal_kernel::ValidatedJournalIngress {
            class: JournalClass::Observation,
            replay: JournalReplayPolicy::Advisory,
            sensitivity: JournalSensitivity::Sensitive,
        };
        registry
            .append_journal_ingress(
                &ingress,
                &validated,
                "client_contiguous",
                "journal_agent_contiguous_start",
            )
            .unwrap();

        let subjects =
            vec![JournalSubject { kind: "terminal".into(), id: terminal_id.to_string() }];
        let payload = json!({
            "format":"cmux.agent-recovery.v1",
            "outcome":"classified_interrupted",
            "source_session":"pi-contiguous-session",
            "provider":"pi",
        });
        let producer =
            JournalProducer { kind: "recovery_policy".into(), id: "agent-recovery-v1".into() };
        let tx = registry.connection.unchecked_transaction().unwrap();
        session_journal::append_journal_record(
            &tx,
            &session_journal::JournalAppend {
                event_id: "event_agent_contiguous_recovery",
                schema_version: 1,
                kind: "agent.session.interrupted",
                class: JournalClass::State,
                replay: JournalReplayPolicy::Required,
                occurred_at_ms: 42,
                producer: &producer,
                authority: None,
                causation_id: None,
                correlation_id: None,
                causation_depth: 0,
                subjects: &subjects,
                sensitivity: JournalSensitivity::Sensitive,
                payload: &payload,
                content: None,
                resource_revision: None,
                previous_resource_revision: None,
            },
        )
        .unwrap();
        tx.commit().unwrap();

        let later = crate::agent_hook_journal_ingress(
            "pi",
            "agent_start",
            None,
            json!({"context":{"session_id":"pi-other-session"}}),
        )
        .unwrap();
        registry
            .append_journal_ingress(
                &later,
                &validated,
                "client_contiguous",
                "journal_agent_contiguous_later",
            )
            .unwrap();
    }

    let reopened = WorkspaceRegistry::open(&root, session).unwrap();
    let agents = reopened.public_projections().unwrap().agents;
    assert_eq!(agents.len(), 1);
    assert_eq!(agents[0].terminal_id, terminal_id);
    assert_eq!(agents[0].state, "interrupted");
    assert_eq!(agents[0].source_session.as_deref(), Some("pi-contiguous-session"));
    drop(reopened);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn journal_agent_future_socket_from_different_hook_session_is_rejected() {
    let mut registry = WorkspaceRegistry::in_memory("journal-agent-socket-transition").unwrap();
    commit_terminal_topology(&mut registry, "journal-agent-socket-transition-topology");
    let terminal_id = terminal_resource(TERMINAL_ONE);
    let ingress = crate::agent_hook_journal_ingress(
        "pi",
        "agent_start",
        Some(terminal_id.as_str()),
        json!({"context":{"session_id":"old-hook-session"}}),
    )
    .unwrap();
    let validated = crate::journal_kernel::ValidatedJournalIngress {
        class: JournalClass::Observation,
        replay: JournalReplayPolicy::Advisory,
        sensitivity: JournalSensitivity::Sensitive,
    };
    registry
        .append_journal_ingress(
            &ingress,
            &validated,
            "client_socket_transition",
            "journal_agent_socket_hook",
        )
        .unwrap();

    let session_id = registry.session_id().clone();
    let agent_id = agent_resource(&terminal_id);
    let socket_updated_at = unix_epoch_ms().unwrap().saturating_add(1_000);
    for (revision, source_session) in [(1, "old-hook-session"), (2, "new-socket-session")] {
        let result = json!({
            "id":agent_id,
            "session_id":session_id,
            "terminal_id":terminal_id,
            "state":"working",
            "source":"socket",
            "updated_at_ms":socket_updated_at.saturating_add(revision).to_string(),
            "source_session":source_session,
            "extra":{"provider":"pi"},
        });
        let commit = registry.commit_agent_projection(
            &WorkspaceMutation::new(
                format!("journal-agent-socket-transition-{revision}"),
                "socket-test",
            )
            .unwrap(),
            &json!({"source_session":source_session}),
            Some(revision),
            &terminal_id,
            &result,
            &json!([]),
        );
        let agent = registry.public_projections().unwrap().agents.remove(0);
        if source_session == "old-hook-session" {
            commit.unwrap();
            assert_eq!(agent.source, "hook");
        } else {
            let error = commit.unwrap_err();
            assert!(error.to_string().contains(
                "agent socket report session Some(\"new-socket-session\") conflicts with active hook session Some(\"old-hook-session\")"
            ));
            assert_eq!(agent.source, "hook");
            assert_eq!(agent.source_session.as_deref(), Some("old-hook-session"));
        }
    }
}

#[test]
fn journal_agent_socket_generation_rejects_late_superseded_session() {
    let root = temp_root("journal-agent-socket-generation");
    let session = "journal-agent-socket-generation";
    let terminal_id = terminal_resource(TERMINAL_ONE);
    let mut registry = WorkspaceRegistry::open(&root, session).unwrap();
    commit_terminal_topology(&mut registry, "journal-agent-socket-generation-topology");
    for (revision, state, source_session) in [
        (1, "working", "socket-session-a"),
        (2, "done", "socket-session-a"),
        (3, "working", "socket-session-b"),
        (4, "done", "socket-session-b"),
    ] {
        let result = json!({
            "id":agent_resource(&terminal_id),
            "session_id":registry.session_id(),
            "terminal_id":terminal_id,
            "state":state,
            "source":"socket",
            "updated_at_ms":revision.to_string(),
            "source_session":source_session,
            "extra":{},
        });
        registry
            .commit_agent_projection(
                &WorkspaceMutation::new(
                    format!("journal-agent-socket-generation-{revision}"),
                    "socket-test",
                )
                .unwrap(),
                &json!({"source_session":source_session}),
                Some(revision),
                &terminal_id,
                &result,
                &json!([]),
            )
            .unwrap();
    }
    drop(registry);

    let mut registry = WorkspaceRegistry::open(&root, session).unwrap();
    let result = json!({
        "id":agent_resource(&terminal_id),
        "session_id":registry.session_id(),
        "terminal_id":terminal_id,
        "state":"working",
        "source":"socket",
        "updated_at_ms":"5",
        "source_session":"socket-session-a",
        "extra":{},
    });
    let error = registry
        .commit_agent_projection(
            &WorkspaceMutation::new("journal-agent-socket-generation-5", "socket-test").unwrap(),
            &json!({"source_session":"socket-session-a"}),
            Some(5),
            &terminal_id,
            &result,
            &json!([]),
        )
        .unwrap_err();
    assert!(error.to_string().contains(
        "agent socket report session Some(\"socket-session-a\") conflicts with active socket session Some(\"socket-session-b\")"
    ));

    let agent = registry.public_projections().unwrap().agents.remove(0);
    assert_eq!(agent.state, "done");
    assert_eq!(agent.source, "socket");
    assert_eq!(agent.source_session.as_deref(), Some("socket-session-b"));
    drop(registry);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn journal_agent_generation_scopes_same_session_id_to_provider() {
    let mut registry = WorkspaceRegistry::in_memory("journal-agent-provider-generation").unwrap();
    commit_terminal_topology(&mut registry, "journal-agent-provider-generation-topology");
    let terminal_id = terminal_resource(TERMINAL_ONE);
    for (revision, provider, state) in [
        (1, "provider-a", "working"),
        (2, "provider-a", "done"),
        (3, "provider-b", "working"),
        (4, "provider-b", "done"),
    ] {
        let result = json!({
            "id":agent_resource(&terminal_id),
            "session_id":registry.session_id(),
            "terminal_id":terminal_id,
            "state":state,
            "source":"socket",
            "updated_at_ms":revision.to_string(),
            "source_session":"shared-provider-session",
            "extra":{"provider":provider},
        });
        registry
            .commit_agent_projection(
                &WorkspaceMutation::new(
                    format!("journal-agent-provider-generation-{revision}"),
                    "socket-test",
                )
                .unwrap(),
                &json!({"source_session":"shared-provider-session"}),
                Some(revision),
                &terminal_id,
                &result,
                &json!([]),
            )
            .unwrap();
    }

    let delayed = json!({
        "id":agent_resource(&terminal_id),
        "session_id":registry.session_id(),
        "terminal_id":terminal_id,
        "state":"working",
        "source":"socket",
        "updated_at_ms":"5",
        "source_session":"shared-provider-session",
        "extra":{"provider":"provider-a"},
    });
    let error = registry
        .commit_agent_projection(
            &WorkspaceMutation::new("journal-agent-provider-generation-delayed-a", "socket-test")
                .unwrap(),
            &json!({"source_session":"shared-provider-session"}),
            Some(5),
            &terminal_id,
            &delayed,
            &json!([]),
        )
        .unwrap_err();
    assert!(error.to_string().contains("superseded generation"));

    let stored: Value = registry
        .connection
        .query_row(
            "SELECT result_json FROM resource_agent_projections WHERE terminal_id = ?1",
            [terminal_id.as_str()],
            |row| row.get::<_, String>(0),
        )
        .map(|value| serde_json::from_str(&value).unwrap())
        .unwrap();
    assert_eq!(stored["state"], "done");
    assert_eq!(stored["extra"]["provider"], "provider-b");
}

#[test]
fn journal_agent_prejournal_migration_retires_older_hook_sessions() {
    let root = temp_root("journal-agent-prejournal-hook-generations");
    let session = "journal-agent-prejournal-hook-generations";
    let terminal_id = terminal_resource(TERMINAL_ONE);
    {
        let mut registry = WorkspaceRegistry::open(&root, session).unwrap();
        commit_terminal_topology(
            &mut registry,
            "journal-agent-prejournal-hook-generations-topology",
        );
        let ingress = crate::agent_hook_journal_ingress(
            "pi",
            "SessionStart",
            Some(terminal_id.as_str()),
            json!({"session_id":"older-hook-session"}),
        )
        .unwrap();
        let validated = crate::journal_kernel::ValidatedJournalIngress {
            class: JournalClass::Observation,
            replay: JournalReplayPolicy::Advisory,
            sensitivity: JournalSensitivity::Sensitive,
        };
        registry
            .append_journal_ingress(
                &ingress,
                &validated,
                "client_prejournal_hook_generations",
                "journal_agent_prejournal_hook_generations_older",
            )
            .unwrap();

        let current = canonical_json(&json!({
            "id":agent_resource(&terminal_id),
            "session_id":registry.session_id(),
            "terminal_id":terminal_id,
            "state":"working",
            "source":"hook",
            "updated_at_ms":"42",
            "source_session":"current-hook-session",
            "extra":{"provider":"pi"},
        }))
        .unwrap();
        registry
            .connection
            .execute(
                "UPDATE resource_agent_projections
                 SET result_json = ?1, committed_revision = 1
                 WHERE terminal_id = ?2",
                params![current, terminal_id.as_str()],
            )
            .unwrap();
        registry.connection.execute("DELETE FROM resource_agent_session_generations", []).unwrap();
        registry
            .connection
            .execute(
                "DELETE FROM meta
                 WHERE key IN (
                   'agent_projection_journal_sequence_v1',
                   'agent_projection_journal_candidate_sequence_v1',
                   'agent_projection_journal_rebuild_target_sequence_v1'
                 )",
                [],
            )
            .unwrap();
    }

    let mut registry = WorkspaceRegistry::open(&root, session).unwrap();
    let validated = crate::journal_kernel::ValidatedJournalIngress {
        class: JournalClass::Observation,
        replay: JournalReplayPolicy::Advisory,
        sensitivity: JournalSensitivity::Sensitive,
    };
    let end = crate::agent_hook_journal_ingress(
        "pi",
        "AgentEnd",
        Some(terminal_id.as_str()),
        json!({"session_id":"current-hook-session"}),
    )
    .unwrap();
    registry
        .append_journal_ingress(
            &end,
            &validated,
            "client_prejournal_hook_generations",
            "journal_agent_prejournal_hook_generations_current_end",
        )
        .unwrap();

    let delayed = crate::agent_hook_journal_ingress(
        "pi",
        "AgentStart",
        Some(terminal_id.as_str()),
        json!({"session_id":"older-hook-session"}),
    )
    .unwrap();
    let error = registry
        .append_journal_ingress(
            &delayed,
            &validated,
            "client_prejournal_hook_generations",
            "journal_agent_prejournal_hook_generations_delayed_older",
        )
        .unwrap_err();
    assert!(error.to_string().contains("superseded generation"));

    let agent = registry.public_projections().unwrap().agents.remove(0);
    assert_eq!(agent.state, "done");
    assert_eq!(agent.source_session.as_deref(), Some("current-hook-session"));
    drop(registry);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn journal_agent_socket_with_missing_session_preserves_hook_identity() {
    let mut registry =
        WorkspaceRegistry::in_memory("journal-agent-socket-missing-session").unwrap();
    commit_terminal_topology(&mut registry, "journal-agent-socket-missing-session-topology");
    let terminal_id = terminal_resource(TERMINAL_ONE);
    let ingress = crate::agent_hook_journal_ingress(
        "pi",
        "agent_start",
        Some(terminal_id.as_str()),
        json!({}),
    )
    .unwrap();
    let validated = crate::journal_kernel::ValidatedJournalIngress {
        class: JournalClass::Observation,
        replay: JournalReplayPolicy::Advisory,
        sensitivity: JournalSensitivity::Sensitive,
    };
    registry
        .append_journal_ingress(
            &ingress,
            &validated,
            "client_socket_missing_session",
            "journal_agent_socket_missing_hook",
        )
        .unwrap();

    let result = json!({
        "id":agent_resource(&terminal_id),
        "session_id":registry.session_id(),
        "terminal_id":terminal_id,
        "state":"working",
        "source":"socket",
        "updated_at_ms":unix_epoch_ms().unwrap().saturating_add(1_000).to_string(),
        "source_session":null,
        "extra":{"provider":"socket-test"},
    });
    registry
        .commit_agent_projection(
            &WorkspaceMutation::new("journal-agent-socket-missing-session", "socket-test").unwrap(),
            &json!({"source_session":null}),
            Some(1),
            &terminal_id,
            &result,
            &json!([]),
        )
        .unwrap();
    let agent = registry.public_projections().unwrap().agents.remove(0);
    assert_eq!(agent.source, "hook");
    assert!(agent.source_session.is_none());
}

#[test]
fn journal_agent_stale_socket_does_not_replace_hook_without_session_identity() {
    let mut registry = WorkspaceRegistry::in_memory("journal-agent-stale-unknown-socket").unwrap();
    commit_terminal_topology(&mut registry, "journal-agent-stale-unknown-socket-topology");
    let terminal_id = terminal_resource(TERMINAL_ONE);
    let ingress = crate::agent_hook_journal_ingress(
        "pi",
        "agent_start",
        Some(terminal_id.as_str()),
        json!({}),
    )
    .unwrap();
    let validated = crate::journal_kernel::ValidatedJournalIngress {
        class: JournalClass::Observation,
        replay: JournalReplayPolicy::Advisory,
        sensitivity: JournalSensitivity::Sensitive,
    };
    registry
        .append_journal_ingress(
            &ingress,
            &validated,
            "client_stale_unknown_socket",
            "journal_agent_stale_unknown_hook",
        )
        .unwrap();

    let result = json!({
        "id":agent_resource(&terminal_id),
        "session_id":registry.session_id(),
        "terminal_id":terminal_id,
        "state":"working",
        "source":"socket",
        "updated_at_ms":"1",
        "source_session":null,
        "extra":{"provider":"socket-test"},
    });
    registry
        .commit_agent_projection(
            &WorkspaceMutation::new("journal-agent-stale-unknown-socket", "socket-test").unwrap(),
            &json!({"source_session":null}),
            Some(1),
            &terminal_id,
            &result,
            &json!([]),
        )
        .unwrap();

    let agent = registry.public_projections().unwrap().agents.remove(0);
    assert_eq!(agent.source, "hook");
    assert!(agent.source_session.is_none());
}

#[test]
fn journal_agent_delayed_socket_report_for_different_hook_session_is_rejected() {
    let mut registry = WorkspaceRegistry::in_memory("journal-agent-delayed-socket").unwrap();
    commit_terminal_topology(&mut registry, "journal-agent-delayed-socket-topology");
    let terminal_id = terminal_resource(TERMINAL_ONE);
    let ingress = crate::agent_hook_journal_ingress(
        "pi",
        "SessionStart",
        Some(terminal_id.as_str()),
        json!({"session_id":"active-hook-session"}),
    )
    .unwrap();
    let validated = crate::journal_kernel::ValidatedJournalIngress {
        class: JournalClass::Observation,
        replay: JournalReplayPolicy::Advisory,
        sensitivity: JournalSensitivity::Sensitive,
    };
    registry
        .append_journal_ingress(
            &ingress,
            &validated,
            "client_delayed_socket",
            "journal_agent_active_hook_session",
        )
        .unwrap();
    let result = json!({
        "id":agent_resource(&terminal_id),
        "session_id":registry.session_id(),
        "terminal_id":terminal_id,
        "state":"idle",
        "source":"socket",
        "updated_at_ms":"1",
        "source_session":"stale-socket-session",
        "extra":{"provider":"socket-test"},
    });
    let error = registry
        .commit_agent_projection(
            &WorkspaceMutation::new("journal-agent-delayed-socket", "socket-test").unwrap(),
            &json!({"source_session":"stale-socket-session"}),
            Some(1),
            &terminal_id,
            &result,
            &json!([]),
        )
        .unwrap_err();
    assert!(error.to_string().contains(
        "agent socket report session Some(\"stale-socket-session\") conflicts with active hook session Some(\"active-hook-session\")"
    ));
    let agent = registry.public_projections().unwrap().agents.remove(0);
    assert_eq!(agent.source, "hook");
    assert_eq!(agent.source_session.as_deref(), Some("active-hook-session"));
}

#[test]
fn journal_agent_final_socket_report_overrides_same_session_hook_state() {
    let mut registry = WorkspaceRegistry::in_memory("journal-agent-final-socket").unwrap();
    commit_terminal_topology(&mut registry, "journal-agent-final-socket-topology");
    let terminal_id = terminal_resource(TERMINAL_ONE);
    let ingress = crate::agent_hook_journal_ingress(
        "pi",
        "AgentStart",
        Some(terminal_id.as_str()),
        json!({"session_id":"shared-session"}),
    )
    .unwrap();
    let validated = crate::journal_kernel::ValidatedJournalIngress {
        class: JournalClass::Observation,
        replay: JournalReplayPolicy::Advisory,
        sensitivity: JournalSensitivity::Sensitive,
    };
    registry
        .append_journal_ingress(
            &ingress,
            &validated,
            "client_final_socket",
            "journal_agent_final_socket_hook",
        )
        .unwrap();
    let result = json!({
        "id":agent_resource(&terminal_id),
        "session_id":registry.session_id(),
        "terminal_id":terminal_id,
        "state":"done",
        "source":"socket",
        "updated_at_ms":unix_epoch_ms().unwrap().saturating_add(1_000).to_string(),
        "source_session":"shared-session",
        "extra":{"provider":"pi"},
    });
    registry
        .commit_agent_projection(
            &WorkspaceMutation::new("journal-agent-final-socket", "socket-test").unwrap(),
            &json!({"source_session":"shared-session"}),
            Some(1),
            &terminal_id,
            &result,
            &json!([]),
        )
        .unwrap();
    let agent = registry.public_projections().unwrap().agents.remove(0);
    assert_eq!(agent.state, "done");
    assert_eq!(agent.source, "socket");
    assert_eq!(agent.source_session.as_deref(), Some("shared-session"));
}

#[test]
fn journal_agent_final_socket_without_provider_preserves_hook_state() {
    let mut registry =
        WorkspaceRegistry::in_memory("journal-agent-final-providerless-socket").unwrap();
    commit_terminal_topology(&mut registry, "journal-agent-final-providerless-socket-topology");
    let terminal_id = terminal_resource(TERMINAL_ONE);
    let ingress = crate::agent_hook_journal_ingress(
        "pi",
        "AgentStart",
        Some(terminal_id.as_str()),
        json!({"session_id":"shared-session"}),
    )
    .unwrap();
    let validated = crate::journal_kernel::ValidatedJournalIngress {
        class: JournalClass::Observation,
        replay: JournalReplayPolicy::Advisory,
        sensitivity: JournalSensitivity::Sensitive,
    };
    registry
        .append_journal_ingress(
            &ingress,
            &validated,
            "client_final_providerless_socket",
            "journal_agent_final_providerless_socket_hook",
        )
        .unwrap();
    let result = json!({
        "id":agent_resource(&terminal_id),
        "session_id":registry.session_id(),
        "terminal_id":terminal_id,
        "state":"done",
        "source":"socket",
        "updated_at_ms":unix_epoch_ms().unwrap().saturating_add(1_000).to_string(),
        "source_session":"shared-session",
        "extra":{},
    });
    registry
        .commit_agent_projection(
            &WorkspaceMutation::new("journal-agent-final-providerless-socket", "socket-test")
                .unwrap(),
            &json!({"source_session":"shared-session"}),
            Some(1),
            &terminal_id,
            &result,
            &json!([]),
        )
        .unwrap();

    let agent = registry.public_projections().unwrap().agents.remove(0);
    assert_eq!(agent.state, "working");
    assert_eq!(agent.source, "hook");
    assert_eq!(agent.source_session.as_deref(), Some("shared-session"));
}

#[test]
fn journal_agent_stale_final_socket_does_not_replace_newer_hook_state() {
    let mut registry = WorkspaceRegistry::in_memory("journal-agent-stale-final-socket").unwrap();
    commit_terminal_topology(&mut registry, "journal-agent-stale-final-socket-topology");
    let terminal_id = terminal_resource(TERMINAL_ONE);
    let ingress = crate::agent_hook_journal_ingress(
        "pi",
        "AgentStart",
        Some(terminal_id.as_str()),
        json!({"session_id":"shared-session"}),
    )
    .unwrap();
    let validated = crate::journal_kernel::ValidatedJournalIngress {
        class: JournalClass::Observation,
        replay: JournalReplayPolicy::Advisory,
        sensitivity: JournalSensitivity::Sensitive,
    };
    registry
        .append_journal_ingress(
            &ingress,
            &validated,
            "client_stale_final_socket",
            "journal_agent_stale_final_socket_hook",
        )
        .unwrap();
    let result = json!({
        "id":agent_resource(&terminal_id),
        "session_id":registry.session_id(),
        "terminal_id":terminal_id,
        "state":"done",
        "source":"socket",
        "updated_at_ms":"1",
        "source_session":"shared-session",
        "extra":{"provider":"pi"},
    });
    registry
        .commit_agent_projection(
            &WorkspaceMutation::new("journal-agent-stale-final-socket", "socket-test").unwrap(),
            &json!({"source_session":"shared-session"}),
            Some(1),
            &terminal_id,
            &result,
            &json!([]),
        )
        .unwrap();

    let agent = registry.public_projections().unwrap().agents.remove(0);
    assert_eq!(agent.state, "working");
    assert_eq!(agent.source, "hook");
    assert_eq!(agent.source_session.as_deref(), Some("shared-session"));
}

#[test]
fn journal_agent_late_hook_does_not_reopen_final_socket_session() {
    let mut registry = WorkspaceRegistry::in_memory("journal-agent-late-hook").unwrap();
    commit_terminal_topology(&mut registry, "journal-agent-late-hook-topology");
    let terminal_id = terminal_resource(TERMINAL_ONE);
    let validated = crate::journal_kernel::ValidatedJournalIngress {
        class: JournalClass::Observation,
        replay: JournalReplayPolicy::Advisory,
        sensitivity: JournalSensitivity::Sensitive,
    };
    let start = crate::agent_hook_journal_ingress(
        "pi",
        "AgentStart",
        Some(terminal_id.as_str()),
        json!({"session_id":"shared-session"}),
    )
    .unwrap();
    registry
        .append_journal_ingress(
            &start,
            &validated,
            "client_late_hook",
            "journal_agent_late_hook_start",
        )
        .unwrap();

    let result = json!({
        "id":agent_resource(&terminal_id),
        "session_id":registry.session_id(),
        "terminal_id":terminal_id,
        "state":"done",
        "source":"socket",
        "updated_at_ms":unix_epoch_ms().unwrap().saturating_add(1_000).to_string(),
        "source_session":"shared-session",
        "extra":{"provider":"pi"},
    });
    registry
        .commit_agent_projection(
            &WorkspaceMutation::new("journal-agent-late-hook-final", "socket-test").unwrap(),
            &json!({"source_session":"shared-session"}),
            Some(1),
            &terminal_id,
            &result,
            &json!([]),
        )
        .unwrap();

    let late_hook = crate::agent_hook_journal_ingress(
        "pi",
        "PreToolUse",
        Some(terminal_id.as_str()),
        json!({"session_id":"shared-session"}),
    )
    .unwrap();
    registry
        .append_journal_ingress(
            &late_hook,
            &validated,
            "client_late_hook",
            "journal_agent_late_hook_activity",
        )
        .unwrap();

    let agent = registry.public_projections().unwrap().agents.remove(0);
    assert_eq!(agent.state, "done");
    assert_eq!(agent.source, "socket");
    assert_eq!(agent.source_session.as_deref(), Some("shared-session"));
}

#[test]
fn journal_agent_explicit_start_reopens_final_same_session_identity() {
    let mut registry = WorkspaceRegistry::in_memory("journal-agent-restart-same-session").unwrap();
    commit_terminal_topology(&mut registry, "journal-agent-restart-same-session-topology");
    let terminal_id = terminal_resource(TERMINAL_ONE);
    let validated = crate::journal_kernel::ValidatedJournalIngress {
        class: JournalClass::Observation,
        replay: JournalReplayPolicy::Advisory,
        sensitivity: JournalSensitivity::Sensitive,
    };
    let start = crate::agent_hook_journal_ingress(
        "pi",
        "SessionStart",
        Some(terminal_id.as_str()),
        json!({"session_id":"shared-session"}),
    )
    .unwrap();
    registry
        .append_journal_ingress(
            &start,
            &validated,
            "client_restart_same_session",
            "journal_agent_restart_same_session_start",
        )
        .unwrap();

    let result = json!({
        "id":agent_resource(&terminal_id),
        "session_id":registry.session_id(),
        "terminal_id":terminal_id,
        "state":"done",
        "source":"socket",
        "updated_at_ms":unix_epoch_ms().unwrap().saturating_add(1_000).to_string(),
        "source_session":"shared-session",
        "extra":{"provider":"pi"},
    });
    registry
        .commit_agent_projection(
            &WorkspaceMutation::new("journal-agent-restart-same-session-final", "socket-test")
                .unwrap(),
            &json!({"source_session":"shared-session"}),
            Some(1),
            &terminal_id,
            &result,
            &json!([]),
        )
        .unwrap();

    let restart = crate::agent_hook_journal_ingress(
        "pi",
        "SessionStart",
        Some(terminal_id.as_str()),
        json!({"session_id":"shared-session"}),
    )
    .unwrap();
    registry
        .append_journal_ingress(
            &restart,
            &validated,
            "client_restart_same_session",
            "journal_agent_restart_same_session_again",
        )
        .unwrap();

    let agent = registry.public_projections().unwrap().agents.remove(0);
    assert_eq!(agent.state, "idle");
    assert_eq!(agent.source, "hook");
    assert_eq!(agent.source_session.as_deref(), Some("shared-session"));
}

#[test]
fn journal_agent_new_turn_identity_reopens_final_reused_session() {
    let root = temp_root("journal-agent-reused-session-new-turn");
    let session = "journal-agent-reused-session-new-turn";
    let terminal_id = terminal_resource(TERMINAL_ONE);
    {
        let mut registry = WorkspaceRegistry::open(&root, session).unwrap();
        commit_terminal_topology(&mut registry, "journal-agent-reused-session-topology");
        let validated = crate::journal_kernel::ValidatedJournalIngress {
            class: JournalClass::Observation,
            replay: JournalReplayPolicy::Advisory,
            sensitivity: JournalSensitivity::Sensitive,
        };
        for (index, event, turn_id) in [
            (0, "SessionStart", "turn-one"),
            (1, "AgentEnd", "turn-one"),
            (2, "AgentStart", "turn-two"),
        ] {
            let ingress = crate::agent_hook_journal_ingress(
                "pi",
                event,
                Some(terminal_id.as_str()),
                json!({"session_id":"reused-session","turn_id":turn_id}),
            )
            .unwrap();
            registry
                .append_journal_ingress(
                    &ingress,
                    &validated,
                    "client_reused_session_new_turn",
                    &format!("journal_agent_reused_session_new_turn_{index}"),
                )
                .unwrap();
        }
        let stored_turn_id = registry
            .connection
            .query_row(
                "SELECT json_extract(result_json, '$.extra.turn_id')
                 FROM resource_agent_projections
                 WHERE terminal_id = ?1",
                [terminal_id.as_str()],
                |row| row.get::<_, String>(0),
            )
            .unwrap();
        assert_eq!(stored_turn_id, "turn-two");
    }

    let reopened = WorkspaceRegistry::open(&root, session).unwrap();
    let agent = reopened.public_projections().unwrap().agents.remove(0);
    assert_eq!(agent.state, "working");
    assert_eq!(agent.source, "hook");
    assert_eq!(agent.source_session.as_deref(), Some("reused-session"));
    drop(reopened);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn journal_agent_same_turn_identity_does_not_reopen_final_session() {
    let mut registry = WorkspaceRegistry::in_memory("journal-agent-same-turn-after-final").unwrap();
    commit_terminal_topology(&mut registry, "journal-agent-same-turn-after-final-topology");
    let terminal_id = terminal_resource(TERMINAL_ONE);
    let validated = crate::journal_kernel::ValidatedJournalIngress {
        class: JournalClass::Observation,
        replay: JournalReplayPolicy::Advisory,
        sensitivity: JournalSensitivity::Sensitive,
    };
    for (index, event) in ["SessionStart", "AgentEnd", "AgentStart"].into_iter().enumerate() {
        let ingress = crate::agent_hook_journal_ingress(
            "pi",
            event,
            Some(terminal_id.as_str()),
            json!({"session_id":"reused-session","turn_id":"turn-one"}),
        )
        .unwrap();
        registry
            .append_journal_ingress(
                &ingress,
                &validated,
                "client_same_turn_after_final",
                &format!("journal_agent_same_turn_after_final_{index}"),
            )
            .unwrap();
    }

    let agent = registry.public_projections().unwrap().agents.remove(0);
    assert_eq!(agent.state, "done");
    assert_eq!(agent.source_session.as_deref(), Some("reused-session"));
}

#[test]
fn journal_agent_new_activity_replaces_final_session_without_start_hook() {
    let mut registry = WorkspaceRegistry::in_memory("journal-agent-after-final-session").unwrap();
    commit_terminal_topology(&mut registry, "journal-agent-after-final-session-topology");
    let terminal_id = terminal_resource(TERMINAL_ONE);
    let validated = crate::journal_kernel::ValidatedJournalIngress {
        class: JournalClass::Observation,
        replay: JournalReplayPolicy::Advisory,
        sensitivity: JournalSensitivity::Sensitive,
    };
    for (index, event, source_session) in [
        (0, "SessionStart", "final-session"),
        (1, "AgentEnd", "final-session"),
        (2, "AgentStart", "new-active-session"),
    ] {
        let ingress = crate::agent_hook_journal_ingress(
            "pi",
            event,
            Some(terminal_id.as_str()),
            json!({"session_id":source_session}),
        )
        .unwrap();
        registry
            .append_journal_ingress(
                &ingress,
                &validated,
                "client_after_final_session",
                &format!("journal_agent_after_final_{index}"),
            )
            .unwrap();
    }
    let agent = registry.public_projections().unwrap().agents.remove(0);
    assert_eq!(agent.state, "working");
    assert_eq!(agent.source_session.as_deref(), Some("new-active-session"));
}

#[test]
fn journal_agent_child_completion_does_not_finish_terminal_owner() {
    let mut registry = WorkspaceRegistry::in_memory("journal-agent-child-completion").unwrap();
    commit_terminal_topology(&mut registry, "journal-agent-child-completion-topology");
    let terminal_id = terminal_resource(TERMINAL_ONE);
    let validated = crate::journal_kernel::ValidatedJournalIngress {
        class: JournalClass::Observation,
        replay: JournalReplayPolicy::Advisory,
        sensitivity: JournalSensitivity::Sensitive,
    };
    let root = crate::agent_hook_journal_ingress(
        "codex",
        "AgentStart",
        Some(terminal_id.as_str()),
        json!({
            "session_id":"tree-session",
            "agent_id":"root-agent",
            "root_agent_id":"root-agent",
        }),
    )
    .unwrap();
    registry
        .append_journal_ingress(
            &root,
            &validated,
            "client_child_completion",
            "journal_agent_root_start",
        )
        .unwrap();

    let child = crate::agent_hook_journal_ingress(
        "codex",
        "AgentEnd",
        Some(terminal_id.as_str()),
        json!({
            "session_id":"tree-session",
            "agent_id":"child-agent",
            "parent_agent_id":"root-agent",
            "root_agent_id":"root-agent",
            "agent_depth":1,
        }),
    )
    .unwrap();
    registry
        .append_journal_ingress(
            &child,
            &validated,
            "client_child_completion",
            "journal_agent_child_end",
        )
        .unwrap();

    let agent = registry.public_projections().unwrap().agents.remove(0);
    assert_eq!(agent.state, "working");
    assert_eq!(agent.source_session.as_deref(), Some("tree-session"));
}

#[test]
fn journal_agent_tool_start_resumes_blocked_terminal_owner() {
    let mut registry = WorkspaceRegistry::in_memory("journal-agent-tool-resume").unwrap();
    commit_terminal_topology(&mut registry, "journal-agent-tool-resume-topology");
    let terminal_id = terminal_resource(TERMINAL_ONE);
    let validated = crate::journal_kernel::ValidatedJournalIngress {
        class: JournalClass::Observation,
        replay: JournalReplayPolicy::Advisory,
        sensitivity: JournalSensitivity::Sensitive,
    };
    for (index, event) in ["AgentStart", "PermissionRequest", "PreToolUse"].into_iter().enumerate()
    {
        let ingress = crate::agent_hook_journal_ingress(
            "codex",
            event,
            Some(terminal_id.as_str()),
            json!({"session_id":"resumed-session","tool_name":"Bash"}),
        )
        .unwrap();
        registry
            .append_journal_ingress(
                &ingress,
                &validated,
                "client_tool_resume",
                &format!("journal_agent_tool_resume_{index}"),
            )
            .unwrap();
        let state = registry.public_projections().unwrap().agents.remove(0).state;
        assert_eq!(state, ["working", "blocked", "working"][index]);
    }
}

#[test]
fn journal_agent_late_or_unidentified_event_keeps_active_session_identity() {
    let mut registry =
        WorkspaceRegistry::in_memory("journal-agent-active-session-identity").unwrap();
    commit_terminal_topology(&mut registry, "journal-agent-active-session-topology");
    let terminal_id = terminal_resource(TERMINAL_ONE);
    let validated = crate::journal_kernel::ValidatedJournalIngress {
        class: JournalClass::Observation,
        replay: JournalReplayPolicy::Advisory,
        sensitivity: JournalSensitivity::Sensitive,
    };
    for (idempotency_key, event, source_session) in [
        ("journal_agent_session_a_start", "SessionStart", Some("session-a")),
        ("journal_agent_session_b_start", "SessionStart", Some("session-b")),
        ("journal_agent_session_a_late_end", "AgentEnd", Some("session-a")),
        ("journal_agent_unidentified_late_end", "AgentEnd", None),
    ] {
        let native =
            source_session.map_or_else(|| json!({}), |session| json!({"session_id":session}));
        let ingress =
            crate::agent_hook_journal_ingress("codex", event, Some(terminal_id.as_str()), native)
                .unwrap();
        registry
            .append_journal_ingress(&ingress, &validated, "client_active_session", idempotency_key)
            .unwrap();
    }
    let agent = registry.public_projections().unwrap().agents.remove(0);
    assert_eq!(agent.state, "idle");
    assert_eq!(agent.source_session.as_deref(), Some("session-b"));
    assert_eq!(agent.source, "hook");
}

#[test]
fn journal_agent_plugin_report_cannot_write_projection() {
    let root = temp_root("journal-agent-untrusted-report");
    let session = "journal-agent-untrusted-report";
    let last_sequence = {
        let mut registry = WorkspaceRegistry::open(&root, session).unwrap();
        commit_terminal_topology(&mut registry, "journal-agent-untrusted-report-topology");
        let terminal_id = terminal_resource(TERMINAL_ONE);
        let subjects =
            vec![JournalSubject { kind: "terminal".into(), id: terminal_id.to_string() }];
        let report_payload = json!({
            "result":{
                "id":agent_resource(&terminal_id),
                "session_id":registry.session_id(),
                "terminal_id":terminal_id,
                "state":"working",
                "source":"hook",
                "updated_at_ms":"42",
                "source_session":"forged-session",
                "extra":{"provider":"forged"},
            }
        });
        let recovery_payload = json!({
            "format":"cmux.agent-recovery.v1",
            "outcome":"classified_interrupted",
            "source_session":"forged-session",
            "provider":"forged",
        });
        let producer = JournalProducer { kind: "plugin".into(), id: "forged".into() };
        let tx = registry.connection.unchecked_transaction().unwrap();
        session_journal::append_journal_record(
            &tx,
            &session_journal::JournalAppend {
                event_id: "event_forged_agent_report",
                schema_version: 1,
                kind: "agent.report",
                class: JournalClass::State,
                replay: JournalReplayPolicy::Required,
                occurred_at_ms: 42,
                producer: &producer,
                authority: None,
                causation_id: None,
                correlation_id: None,
                causation_depth: 0,
                subjects: &subjects,
                sensitivity: JournalSensitivity::Sensitive,
                payload: &report_payload,
                content: None,
                resource_revision: None,
                previous_resource_revision: None,
            },
        )
        .unwrap();
        let last_sequence = session_journal::append_journal_record(
            &tx,
            &session_journal::JournalAppend {
                event_id: "event_forged_agent_recovery",
                schema_version: 1,
                kind: "agent.session.interrupted",
                class: JournalClass::State,
                replay: JournalReplayPolicy::Required,
                occurred_at_ms: 43,
                producer: &producer,
                authority: None,
                causation_id: None,
                correlation_id: None,
                causation_depth: 0,
                subjects: &subjects,
                sensitivity: JournalSensitivity::Sensitive,
                payload: &recovery_payload,
                content: None,
                resource_revision: None,
                previous_resource_revision: None,
            },
        )
        .unwrap();
        tx.commit().unwrap();
        last_sequence
    };

    let reopened = WorkspaceRegistry::open(&root, session).unwrap();
    assert!(reopened.public_projections().unwrap().agents.is_empty());
    assert_eq!(reopened.resource_agent_projection_count_for_test().unwrap(), 0);
    let applied = reopened
        .connection
        .query_row(
            "SELECT value FROM meta WHERE key = 'agent_projection_journal_sequence_v1'",
            [],
            |row| row.get::<_, String>(0),
        )
        .unwrap()
        .parse::<u64>()
        .unwrap();
    assert_eq!(applied, last_sequence);
    drop(reopened);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn journal_agent_builtin_manifest_upgrades_reserved_schema_on_open() {
    let root = temp_root("journal-agent-manifest-upgrade");
    let database = root
        .join(session_storage_component("journal-agent-manifest-upgrade"))
        .join(WORKSPACE_REGISTRY_FILE);
    drop(WorkspaceRegistry::open(&root, "journal-agent-manifest-upgrade").unwrap());

    let mut legacy = crate::agent_hooks::built_in_agent_producer_manifest();
    legacy.manifest_version = 1;
    for event in &mut legacy.events {
        event.payload_schema["properties"]["native"] = json!({});
    }
    let legacy_json = canonical_json(&serde_json::to_value(&legacy).unwrap()).unwrap();
    Connection::open(&database)
        .unwrap()
        .execute(
            "UPDATE journal_producers
             SET manifest_version = 1, manifest_json = ?1
             WHERE producer_id = ?2",
            params![legacy_json, crate::AGENT_HOOK_PRODUCER_ID],
        )
        .unwrap();

    let reopened = WorkspaceRegistry::open(&root, "journal-agent-manifest-upgrade").unwrap();
    let (stored_version, stored_json) = reopened
        .connection
        .query_row(
            "SELECT manifest_version, manifest_json
             FROM journal_producers WHERE producer_id = ?1",
            [crate::AGENT_HOOK_PRODUCER_ID],
            |row| Ok((row.get::<_, i64>(0)?, row.get::<_, String>(1)?)),
        )
        .unwrap();
    let current = crate::agent_hooks::built_in_agent_producer_manifest();
    assert_eq!(crate::AGENT_HOOK_MANIFEST_VERSION, 2);
    assert_eq!(stored_version, 2);
    assert_eq!(serde_json::from_str::<JournalProducerManifest>(&stored_json).unwrap(), current);
    drop(reopened);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn journal_agent_prejournal_projection_migrates_once_and_survives_reopen() {
    let root = temp_root("journal-agent-prejournal-projection");
    let session = "journal-agent-prejournal-projection";
    let terminal_id = terminal_resource(TERMINAL_ONE);
    let original_json = {
        let mut registry = WorkspaceRegistry::open(&root, session).unwrap();
        commit_terminal_topology(&mut registry, "journal-agent-prejournal-topology");
        let value = json!({
            "id":agent_resource(&terminal_id),
            "session_id":registry.session_id(),
            "terminal_id":terminal_id,
            "state":"working",
            "source":"hook",
            "updated_at_ms":"42",
            "source_session":"legacy-agent-session",
            "extra":{"provider":"pi"},
        });
        let value = canonical_json(&value).unwrap();
        registry
            .connection
            .execute(
                "INSERT INTO resource_agent_projections(
                   terminal_id, result_json, committed_revision
                 ) VALUES(?1, ?2, 1)",
                params![terminal_id.as_str(), value],
            )
            .unwrap();
        registry
            .connection
            .execute("DELETE FROM meta WHERE key = 'agent_projection_journal_sequence_v1'", [])
            .unwrap();
        value
    };

    let reopened = WorkspaceRegistry::open(&root, session).unwrap();
    let migrated_json = reopened
        .connection
        .query_row(
            "SELECT result_json FROM resource_agent_projections WHERE terminal_id = ?1",
            [terminal_id.as_str()],
            |row| row.get::<_, String>(0),
        )
        .unwrap();
    assert_eq!(migrated_json, original_json);
    let migration_records = reopened
        .session_journal_after(0, 1024)
        .unwrap()
        .records
        .into_iter()
        .filter(|record| record.kind == "agent.report")
        .count();
    assert_eq!(migration_records, 1);
    drop(reopened);

    let reopened_again = WorkspaceRegistry::open(&root, session).unwrap();
    let reopened_json = reopened_again
        .connection
        .query_row(
            "SELECT result_json FROM resource_agent_projections WHERE terminal_id = ?1",
            [terminal_id.as_str()],
            |row| row.get::<_, String>(0),
        )
        .unwrap();
    assert_eq!(reopened_json, original_json);
    let migration_records_again = reopened_again
        .session_journal_after(0, 1024)
        .unwrap()
        .records
        .into_iter()
        .filter(|record| record.kind == "agent.report")
        .count();
    assert_eq!(migration_records_again, 1);
    drop(reopened_again);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn journal_agent_prejournal_projection_migration_is_bounded_on_open() {
    const PROJECTION_COUNT: usize = 65;

    let root = temp_root("journal-agent-bounded-prejournal-migration");
    let session = "journal-agent-bounded-prejournal-migration";
    {
        let registry = WorkspaceRegistry::open(&root, session).unwrap();
        let session_id = registry.session_id().clone();
        let tx = registry.connection.unchecked_transaction().unwrap();
        for index in 0..PROJECTION_COUNT {
            let terminal_id =
                TerminalPublicId::parse(format!("term_{:032x}", index + 1_000)).unwrap();
            let host_id = format!("legacy-agent-host-{index:04}");
            let result = canonical_json(&json!({
                "id":agent_resource(&terminal_id),
                "session_id":session_id,
                "terminal_id":terminal_id,
                "state":"working",
                "source":"hook",
                "updated_at_ms":"42",
                "source_session":format!("legacy-session-{index:04}"),
                "extra":{"provider":"pi"},
            }))
            .unwrap();
            tx.execute(
                "INSERT INTO terminal_hosts(
                   terminal_id, workspace_key, incarnation, lifecycle, launch_spec_json,
                   exit_json, created_revision, updated_revision, deleted_revision
                 ) VALUES(?1, 'legacy-agent-workspace', NULL, 'launching',
                          '{\"command\":[\"/bin/zsh\"],\"cwd\":\"/tmp\",\"rows\":24,\"cols\":80}',
                          NULL, 1, 1, NULL)",
                [&host_id],
            )
            .unwrap();
            tx.execute(
                "INSERT INTO resource_identities(
                   public_id, kind, created_revision, updated_revision, deleted_revision
                 ) VALUES(?1, 'terminal', 1, 1, NULL)",
                [terminal_id.as_str()],
            )
            .unwrap();
            tx.execute(
                "INSERT INTO resource_terminals(
                   public_id, terminal_id, lifecycle,
                   created_revision, updated_revision, deleted_revision
                 ) VALUES(?1, ?2, 'active', 1, 1, NULL)",
                params![terminal_id.as_str(), host_id],
            )
            .unwrap();
            tx.execute(
                "INSERT INTO resource_agent_projections(
                   terminal_id, result_json, committed_revision
                 ) VALUES(?1, ?2, 1)",
                params![terminal_id.as_str(), result],
            )
            .unwrap();
        }
        tx.execute(
            "DELETE FROM meta
             WHERE key IN (
               'agent_projection_journal_sequence_v1',
               'agent_projection_journal_candidate_sequence_v1',
               'agent_projection_journal_rebuild_target_sequence_v1'
             )",
            [],
        )
        .unwrap();
        tx.commit().unwrap();
    }

    let reopened = WorkspaceRegistry::open(&root, session).unwrap();
    let migration_records = reopened
        .connection
        .query_row("SELECT COUNT(*) FROM session_journal WHERE kind = 'agent.report'", [], |row| {
            row.get::<_, i64>(0)
        })
        .unwrap();
    assert!(migration_records > 0);
    assert!(
        migration_records < PROJECTION_COUNT as i64,
        "one open must not migrate every legacy projection"
    );
    assert!(reopened.agent_projection_rebuild_pending().unwrap());
    assert_eq!(
        reopened.public_projections().unwrap().agents.len(),
        PROJECTION_COUNT,
        "a bounded migration must keep the last durable agent snapshot visible"
    );
    drop(reopened);
    fs::remove_dir_all(root).unwrap();
}

#[test]
#[ignore = "manual release-mode journal writer throughput probe"]
fn terminal_journal_writer_throughput_probe() {
    const BATCH_SIZE: usize = 1_024;
    const BATCHES: usize = 16;
    const CHUNK_BYTES: usize = 4 * 1_024;

    let mut registry = WorkspaceRegistry::in_memory("journal-terminal-throughput").unwrap();
    commit_terminal_topology(&mut registry, "journal-terminal-throughput-seed");
    let terminal_id = terminal_resource(TERMINAL_ONE);
    let journal_terminal_id = Arc::new(terminal_id.clone());
    let mut chunk = vec![b'x'; CHUNK_BYTES];
    chunk[CHUNK_BYTES - 17..].copy_from_slice(b"terminal-output\r\n");
    let started = std::time::Instant::now();
    for batch in 0..BATCHES {
        let events = (0..BATCH_SIZE)
            .map(|index| crate::journal_ingress::JournalIngressEvent::TerminalOutput {
                terminal_id: journal_terminal_id.clone(),
                generation: "throughput-generation".into(),
                occurred_at_ms: u64::try_from(batch * BATCH_SIZE + index).unwrap(),
                bytes: chunk.clone(),
            })
            .collect::<Vec<_>>();
        let references = events.iter().collect::<Vec<_>>();
        assert_eq!(registry.append_journal_ingress_events(&references).unwrap().len(), BATCH_SIZE);
    }
    let elapsed = started.elapsed();
    let event_count = BATCH_SIZE * BATCHES;
    let byte_count = event_count * CHUNK_BYTES;
    let events_per_second = event_count as f64 / elapsed.as_secs_f64();
    let mebibytes_per_second = byte_count as f64 / (1024.0 * 1024.0) / elapsed.as_secs_f64();
    eprintln!(
        "terminal journal writer: {event_count} records / {} MiB in {elapsed:?}, \
         {events_per_second:.0} records/s, {mebibytes_per_second:.1} MiB/s",
        byte_count / (1024 * 1024)
    );
    assert!(events_per_second >= 5_000.0, "journal writer regressed: {events_per_second:.0}/s");
    assert!(
        mebibytes_per_second >= 20.0,
        "journal writer regressed: {mebibytes_per_second:.1} MiB/s"
    );
    let stored_offset = registry
        .connection
        .query_row(
            "SELECT next_offset FROM journal_terminal_streams
             WHERE terminal_id = ?1 AND generation = ?2",
            params![terminal_id.as_str(), "throughput-generation"],
            |row| row.get::<_, i64>(0),
        )
        .unwrap();
    assert_eq!(usize::try_from(stored_offset).unwrap(), byte_count);
}

#[test]
fn terminal_output_survives_immutable_segment_round_trip() {
    let root = temp_root("journal-terminal-segment");
    let mut registry = WorkspaceRegistry::open(&root, "journal-terminal-segment").unwrap();
    commit_terminal_topology(&mut registry, "journal-terminal-segment-seed");
    let terminal_id = terminal_resource(TERMINAL_ONE);
    let output = b"segment output \x1b[32mready\x1b[0m\r\n\0";
    let events = [crate::journal_ingress::JournalIngressEvent::TerminalOutput {
        terminal_id: Arc::new(terminal_id),
        generation: "segment-incarnation".into(),
        occurred_at_ms: 42,
        bytes: output.to_vec(),
    }];
    registry.append_journal_ingress_events(&events.iter().collect::<Vec<_>>()).unwrap();
    let through = registry.session_journal_after(0, 32).unwrap().head_sequence;
    registry
        .create_journal_checkpoint(
            through,
            1,
            &json!({
                "session_snapshot":{"cursor":{"revision":"1"}},
                "journal_extensions":{"producers":[],"hooks":[]},
            }),
            &[],
            "client_test",
            "terminal_segment_checkpoint",
        )
        .unwrap();

    let plan = match registry
        .begin_journal_segment_seal(through, "client_test", "terminal_segment_seal")
        .unwrap()
    {
        JournalSegmentSealStart::Prepare(plan) => plan,
        JournalSegmentSealStart::Replay(_) => panic!("first segment seal unexpectedly replayed"),
    };
    let reader = SessionJournalReader::open(
        &registry.session_journal_database_path().expect("persistent registry has a path"),
    )
    .unwrap();
    let prepared = plan.prepare(&reader).unwrap();
    let commit = registry
        .commit_journal_segment_seal(prepared, "client_test", "terminal_segment_seal")
        .unwrap()
        .expect("segment boundary remained stable");
    assert_eq!(commit.through_sequence, through);

    let record = registry
        .session_journal_after(0, 32)
        .unwrap()
        .records
        .into_iter()
        .find(|record| record.kind == "terminal.output")
        .unwrap();
    assert_eq!(record.terminal_output.as_deref(), Some(output.as_slice()));
    assert_eq!(record.payload["encoding"], "raw");
    assert!(record.payload.get("data").is_none());

    drop(reader);
    drop(registry);
    fs::remove_dir_all(root).unwrap();
}

fn receipt_test_producer() -> JournalProducerManifest {
    JournalProducerManifest {
        producer_id: "receipt_test".into(),
        namespace: "plugin.receipt_test".into(),
        manifest_version: 1,
        max_sensitivity: JournalSensitivity::Metadata,
        permissions: vec!["journal.append.plugin.receipt_test".into()],
        events: vec![JournalEventSchema {
            kind: "plugin.receipt_test.event".into(),
            schema_version: 1,
            class: JournalClass::Observation,
            replay: JournalReplayPolicy::Advisory,
            sensitivity: JournalSensitivity::Metadata,
            payload_schema: json!({"type":"object","additionalProperties":true}),
        }],
    }
}

#[test]
fn journal_producers_reject_plaintext_secret_schemas() {
    let mut registry = WorkspaceRegistry::in_memory("journal-secret-schema").unwrap();
    let mut manifest = receipt_test_producer();
    manifest.max_sensitivity = JournalSensitivity::Secret;
    let error = registry
        .put_journal_producer(&manifest, "client_secret", "install_secret_producer")
        .unwrap_err()
        .to_string();
    assert!(error.contains("encrypted retention"), "{error}");

    manifest.max_sensitivity = JournalSensitivity::Sensitive;
    manifest.events[0].sensitivity = JournalSensitivity::Secret;
    let error = registry
        .put_journal_producer(&manifest, "client_secret", "install_secret_event")
        .unwrap_err()
        .to_string();
    assert!(error.contains("encrypted retention"), "{error}");
}

#[test]
fn journal_commit_time_is_local_and_independent_of_producer_time() {
    let mut registry = WorkspaceRegistry::in_memory("journal-independent-commit-time").unwrap();
    let manifest = receipt_test_producer();
    registry.put_journal_producer(&manifest, "client_time", "install_time_producer").unwrap();
    let ingress = JournalIngress {
        producer_id: manifest.producer_id,
        manifest_version: manifest.manifest_version,
        kind: manifest.events[0].kind.clone(),
        schema_version: manifest.events[0].schema_version,
        occurred_at_ms: Some(crate::resource::WireDecimal::new(1)),
        subjects: Vec::new(),
        sensitivity: None,
        payload: json!({"message":"historical occurrence"}),
        causation_id: None,
        correlation_id: None,
    };
    let validated = crate::journal_kernel::ValidatedJournalIngress {
        class: JournalClass::Observation,
        replay: JournalReplayPolicy::Advisory,
        sensitivity: JournalSensitivity::Metadata,
    };
    let before = unix_epoch_ms().unwrap();
    let commit = registry
        .append_journal_ingress(&ingress, &validated, "client_time", "historical_event")
        .unwrap();
    let after = unix_epoch_ms().unwrap();
    let record = registry
        .session_journal_after(commit.sequence - 1, 1)
        .unwrap()
        .records
        .into_iter()
        .next()
        .unwrap();
    assert_eq!(record.occurred_at_ms, 1);
    assert!(
        (before..=after).contains(&record.committed_at_ms),
        "commit time {} was not sampled locally in {before}..={after}",
        record.committed_at_ms,
    );
}

#[test]
fn journal_idempotency_keys_are_scoped_to_the_calling_origin() {
    let mut registry = WorkspaceRegistry::in_memory("journal-origin-receipts").unwrap();
    let manifest = receipt_test_producer();
    let first =
        registry.put_journal_producer(&manifest, "client_origin_one", "shared_key").unwrap();
    let second =
        registry.put_journal_producer(&manifest, "client_origin_two", "shared_key").unwrap();
    let replay =
        registry.put_journal_producer(&manifest, "client_origin_one", "shared_key").unwrap();
    assert!(!first.replayed);
    assert!(!second.replayed);
    assert!(second.sequence > first.sequence);
    assert!(replay.replayed);
    assert_eq!(replay.sequence, first.sequence);

    let ingress = JournalIngress {
        producer_id: manifest.producer_id.clone(),
        manifest_version: manifest.manifest_version,
        kind: manifest.events[0].kind.clone(),
        schema_version: 1,
        occurred_at_ms: None,
        subjects: Vec::new(),
        sensitivity: None,
        payload: json!({"message":"same payload"}),
        causation_id: None,
        correlation_id: None,
    };
    let validated = crate::journal_kernel::ValidatedJournalIngress {
        class: JournalClass::Observation,
        replay: JournalReplayPolicy::Advisory,
        sensitivity: JournalSensitivity::Metadata,
    };
    let first = registry
        .append_journal_ingress(&ingress, &validated, "client_origin_one", "shared_ingress_key")
        .unwrap();
    let second = registry
        .append_journal_ingress(&ingress, &validated, "client_origin_two", "shared_ingress_key")
        .unwrap();
    assert!(!first.replayed);
    assert!(!second.replayed);
    assert!(second.sequence > first.sequence);
}

#[test]
fn schema_eleven_receipts_gain_origin_scope_without_losing_replays() {
    let root = temp_root("schema-eleven-journal-receipts");
    let database = root.join(session_storage_component("session")).join(WORKSPACE_REGISTRY_FILE);
    let manifest = receipt_test_producer();
    let first = {
        let mut registry = WorkspaceRegistry::open(&root, "session").unwrap();
        registry.put_journal_producer(&manifest, "client_legacy", "legacy_shared_key").unwrap()
    };
    let legacy = Connection::open(&database).unwrap();
    legacy
        .execute_batch(
            "PRAGMA foreign_keys=OFF;
             ALTER TABLE journal_operation_receipts RENAME TO journal_operation_receipts_current;
             CREATE TABLE journal_operation_receipts (
               operation TEXT NOT NULL,
               idempotency_key TEXT NOT NULL,
               fingerprint BLOB NOT NULL CHECK(length(fingerprint) = 32),
               result_json TEXT NOT NULL CHECK(json_valid(result_json)),
               journal_sequence INTEGER NOT NULL UNIQUE,
               PRIMARY KEY(operation, idempotency_key)
             );
             INSERT INTO journal_operation_receipts(
               operation, idempotency_key, fingerprint, result_json, journal_sequence
             )
             SELECT operation, idempotency_key, fingerprint, result_json, journal_sequence
             FROM journal_operation_receipts_current;
             DROP TABLE journal_operation_receipts_current;
             ALTER TABLE journal_ingress_receipts RENAME TO journal_ingress_receipts_current;
             CREATE TABLE journal_ingress_receipts (
               producer_id TEXT NOT NULL,
               idempotency_key TEXT NOT NULL,
               fingerprint BLOB NOT NULL CHECK(length(fingerprint) = 32),
               event_id TEXT NOT NULL UNIQUE,
               journal_sequence INTEGER NOT NULL UNIQUE,
               result_json TEXT NOT NULL CHECK(json_valid(result_json)),
               PRIMARY KEY(producer_id, idempotency_key),
               FOREIGN KEY(producer_id) REFERENCES journal_producers(producer_id)
             );
             INSERT INTO journal_ingress_receipts(
               producer_id, idempotency_key, fingerprint, event_id,
               journal_sequence, result_json
             )
             SELECT producer_id, idempotency_key, fingerprint, event_id,
                    journal_sequence, result_json
             FROM journal_ingress_receipts_current;
             DROP TABLE journal_ingress_receipts_current;
             UPDATE meta SET value = '11' WHERE key = 'schema_version';
             PRAGMA foreign_keys=ON;",
        )
        .unwrap();
    drop(legacy);

    let mut migrated = WorkspaceRegistry::open(&root, "session").unwrap();
    let replay =
        migrated.put_journal_producer(&manifest, "client_legacy", "legacy_shared_key").unwrap();
    let other_origin =
        migrated.put_journal_producer(&manifest, "client_new", "legacy_shared_key").unwrap();
    assert!(replay.replayed);
    assert_eq!(replay.sequence, first.sequence);
    assert!(!other_origin.replayed);
    assert!(other_origin.sequence > first.sequence);
    assert_eq!(
        required_meta(&migrated.connection, "schema_version").unwrap(),
        SCHEMA_VERSION.to_string()
    );
    drop(migrated);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn saved_session_integrity_failure_has_actionable_public_copy() {
    let root = temp_root("saved-session-integrity-public-copy");
    let database = root.join(session_storage_component("session")).join(WORKSPACE_REGISTRY_FILE);
    {
        let mut registry = WorkspaceRegistry::open(&root, "session").unwrap();
        commit_terminal_topology(&mut registry, "saved-session-integrity-seed");
    }
    let connection = Connection::open(database).unwrap();
    connection.execute_batch("PRAGMA foreign_keys=OFF;").unwrap();
    connection
        .execute(
            "UPDATE resource_tabs SET pane_id = ?1 WHERE public_id = ?2",
            params![pane_id(99).as_str(), tab_id(1).as_str()],
        )
        .unwrap();
    drop(connection);

    let error = WorkspaceRegistry::open(&root, "session").unwrap_err();
    assert_eq!(
        error.to_string(),
        "saved session data could not be loaded; start a new session or restore this session from a backup"
    );
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn schema_four_backfills_safe_browser_restart_metadata() {
    let root = temp_root("schema-four-browser");
    let browser = browser_id(1);
    let session_dir = root.join(session_storage_component("session"));
    {
        let mut registry = WorkspaceRegistry::open(&root, "session").unwrap();
        commit_terminal_topology(&mut registry, "create");
        commit_browser_topology(
            &mut registry,
            "browser",
            RegistryBrowser {
                public_id: browser.clone(),
                url: "https://cmux.dev/migrate".into(),
                source: RegistryBrowserSource::External,
                launch: RegistryBrowserLaunch::Adopted,
                reconnect: RegistryBrowserReconnect::Recreate,
                status: RegistryBrowserStatus::Live,
                cols: 111,
                rows: 42,
            },
        );
    }
    {
        let connection = Connection::open(session_dir.join("workspace-registry.sqlite3")).unwrap();
        connection
            .execute_batch(
                "PRAGMA foreign_keys=OFF;
                 BEGIN IMMEDIATE;
                 ALTER TABLE resource_browsers RENAME TO resource_browsers_v5;
                 CREATE TABLE resource_browsers (
                   public_id TEXT PRIMARY KEY NOT NULL REFERENCES resource_identities(public_id),
                   url TEXT NOT NULL,
                   lifecycle TEXT NOT NULL CHECK(lifecycle IN ('running','tombstoned')),
                   created_revision INTEGER NOT NULL,
                   updated_revision INTEGER NOT NULL,
                   deleted_revision INTEGER,
                   CHECK (
                     (deleted_revision IS NULL AND lifecycle = 'running') OR
                     (deleted_revision IS NOT NULL AND lifecycle = 'tombstoned')
                   )
                 );
                 INSERT INTO resource_browsers(
                   public_id, url, lifecycle, created_revision, updated_revision, deleted_revision
                 )
                 SELECT public_id, url, lifecycle, created_revision, updated_revision,
                        deleted_revision
                 FROM resource_browsers_v5;
                 DROP TABLE resource_browsers_v5;
                 UPDATE meta SET value = '4' WHERE key = 'schema_version';
                 COMMIT;
                 PRAGMA foreign_keys=ON;",
            )
            .unwrap();
    }
    let migrated = WorkspaceRegistry::open(&root, "session").unwrap();
    assert_eq!(
        required_meta(&migrated.connection, "schema_version").unwrap(),
        SCHEMA_VERSION.to_string()
    );
    assert_eq!(
        migrated.resource_topology_snapshot().unwrap().browsers,
        vec![RegistryBrowser::recreate(browser, "https://cmux.dev/migrate".into(), 80, 24,)]
    );
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn schema_one_migrates_transactionally_to_terminal_registry() {
    let root = temp_root("schema-one");
    let session_dir = root.join(session_storage_component("session"));
    {
        let registry = WorkspaceRegistry::open(&root, "session").unwrap();
        drop(registry);
        let connection = Connection::open(session_dir.join("workspace-registry.sqlite3")).unwrap();
        connection
            .execute_batch(
                "DROP TABLE terminal_events;
                     DROP TABLE terminal_mutations;
                     DROP TABLE terminal_hosts;
                     DELETE FROM meta WHERE key = 'terminal_revision';
                     UPDATE meta SET value = '1' WHERE key = 'schema_version';",
            )
            .unwrap();
    }
    let migrated = WorkspaceRegistry::open(&root, "session").unwrap();
    assert_eq!(migrated.terminal_snapshot().unwrap().revision, 0);
    assert!(migrated.terminal_snapshot().unwrap().terminals.is_empty());
    assert_eq!(
        required_meta(&migrated.connection, "schema_version").unwrap(),
        SCHEMA_VERSION.to_string()
    );
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn interrupted_transaction_and_newer_schema_fail_closed() {
    let root = temp_root("transaction");
    {
        let mut registry = WorkspaceRegistry::open(&root, "session").unwrap();
        let tx = registry.connection.transaction().unwrap();
        tx.execute("UPDATE meta SET value = '77' WHERE key = 'revision'", []).unwrap();
        drop(tx);
        assert_eq!(registry.snapshot().unwrap().revision, 0);
    }
    fs::remove_dir_all(&root).unwrap();

    let newer_root = temp_root("newer");
    drop(load_or_create_resource_effect_pepper(&newer_root).unwrap());
    let session_dir = newer_root.join(session_storage_component("session"));
    fs::create_dir_all(&session_dir).unwrap();
    let database = session_dir.join(WORKSPACE_REGISTRY_FILE);
    let db = Connection::open(&database).unwrap();
    db.execute_batch(
        "CREATE TABLE meta(key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL);
             INSERT INTO meta(key,value) VALUES('schema_version','999');",
    )
    .unwrap();
    drop(db);
    let error = WorkspaceRegistry::open(&newer_root, "session").unwrap_err();
    let schema = error.downcast_ref::<UnsupportedWorkspaceRegistrySchema>().unwrap();
    assert_eq!(schema.found(), 999);
    assert_eq!(schema.newest_supported(), SCHEMA_VERSION);
    assert_eq!(schema.database_path(), Some(database.as_path()));
    assert!(error.to_string().contains("unsupported workspace registry schema"));
    fs::remove_dir_all(newer_root).unwrap();
}

#[test]
fn newer_schema_is_reported_before_writer_lease_conflict() {
    let root = temp_root("newer-before-lease");
    let registry = WorkspaceRegistry::open(&root, "session").unwrap();
    registry
        .connection
        .execute(
            "UPDATE meta SET value = ?1 WHERE key = 'schema_version'",
            [(SCHEMA_VERSION + 1).to_string()],
        )
        .unwrap();

    let error = WorkspaceRegistry::open(&root, "session").unwrap_err();
    let schema = error.downcast_ref::<UnsupportedWorkspaceRegistrySchema>().unwrap();
    assert_eq!(schema.found(), SCHEMA_VERSION + 1);
    assert_eq!(schema.registry_id(), Some(registry.registry_id()));
    assert!(!error.to_string().contains("already owned"));

    drop(registry);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn schema_preflight_failures_defer_to_authoritative_open() {
    let root = temp_root("preflight-failure");
    fs::create_dir_all(&root).unwrap();
    let database = root.join(WORKSPACE_REGISTRY_FILE);
    fs::write(&database, b"not a sqlite database").unwrap();

    assert!(preflight_unsupported_schema(&database).is_none());

    fs::remove_dir_all(root).unwrap();
}
