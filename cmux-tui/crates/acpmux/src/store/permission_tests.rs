use super::*;
use std::os::unix::fs::PermissionsExt;

struct TempDir(PathBuf);

impl TempDir {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "acpmux-store-permissions-{}-{}",
            std::process::id(),
            uuid::Uuid::now_v7()
        ));
        std::fs::create_dir_all(&path).unwrap();
        Self(path)
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn mode(path: &Path) -> u32 {
    std::fs::symlink_metadata(path).unwrap().permissions().mode() & 0o777
}

#[test]
fn local_store_makes_existing_state_private_and_writes_private_events() {
    let temp = TempDir::new();
    let root = temp.0.join("sessions");
    let session = root.join("session-1");
    let events = session.join("events");
    std::fs::create_dir_all(&events).unwrap();
    let metadata = session.join("session.json");
    let first = events.join("000001.ndjson");
    let second = events.join("000002.ndjson");
    std::fs::write(&metadata, "{}").unwrap();
    std::fs::write(&first, "").unwrap();
    std::fs::write(&second, "").unwrap();
    for directory in [&root, &session, &events] {
        std::fs::set_permissions(directory, std::fs::Permissions::from_mode(0o755)).unwrap();
    }
    for file in [&metadata, &first, &second] {
        std::fs::set_permissions(file, std::fs::Permissions::from_mode(0o644)).unwrap();
    }

    let store = LocalStore::new(root.clone(), 64 * 1024, &crate::supervised::embedded()).unwrap();
    let _ = store.list().unwrap();
    store
        .append(
            "session-1",
            &EventRecord {
                seq: 1,
                at: 1,
                dir: "mux".into(),
                kind: "test".into(),
                msg: serde_json::json!({"text": "private"}),
                host_seq: None,
            },
        )
        .unwrap();
    // Old segments are authenticated and narrowed when a read reaches
    // them. Merely finding their names stays lazy so a tail page never
    // opens an older segment it does not need.
    store.events("session-1", 0, usize::MAX).unwrap();

    assert_eq!(mode(&root), 0o700, "the sessions root contains every chat");
    assert_eq!(mode(&session), 0o700);
    assert_eq!(mode(&events), 0o700);
    assert_eq!(mode(&metadata), 0o600);
    assert_eq!(mode(&first), 0o600);
    assert_eq!(mode(&second), 0o600);
}

/// Review 2 of #26054: a strict read of a log whose segments cannot be listed fails; `scan`
/// reads no record of it.
#[test]
fn a_strict_read_fails_when_the_log_cannot_be_listed() {
    let temp = TempDir::new();
    let root = temp.0.join("sessions");
    let store = LocalStore::new(root.clone(), 64 * 1024, &crate::supervised::embedded()).unwrap();
    let record = EventRecord {
        seq: 1,
        at: 1,
        dir: "mux".into(),
        kind: "host_started".into(),
        msg: serde_json::json!({}),
        host_seq: None,
    };
    store.append("session-1", &record).unwrap();
    let events = root.join("session-1").join("events");
    std::fs::remove_dir_all(&events).unwrap();
    std::fs::write(&events, "not a directory").unwrap();
    assert!(store.scan("session-1", 0, &mut |_| true).is_ok());
    assert!(
        store.scan_strict("session-1", 0, &mut |_| true).is_err(),
        "a strict read of a log it could not list read nothing and passed"
    );
}

#[test]
fn local_store_refuses_a_symlinked_existing_session() {
    let temp = TempDir::new();
    let root = temp.0.join("sessions");
    let outside = temp.0.join("outside");
    std::fs::create_dir_all(&root).unwrap();
    std::fs::create_dir_all(&outside).unwrap();
    std::os::unix::fs::symlink(&outside, root.join("linked-session")).unwrap();
    let store = LocalStore::new(root, 64 * 1024, &crate::supervised::embedded()).unwrap();
    assert!(store.list().is_err());
}

#[cfg(target_os = "macos")]
#[test]
fn local_store_refuses_a_state_root_with_an_extended_acl() {
    let temp = TempDir::new();
    let root = temp.0.join("sessions");
    std::fs::create_dir_all(&root).unwrap();
    let status = std::process::Command::new("/bin/chmod")
        .args(["+a", "group:staff allow read", root.to_str().unwrap()])
        .status()
        .unwrap();
    assert!(status.success());
    assert!(LocalStore::new(root, 64 * 1024, &crate::supervised::embedded()).is_err());
}
