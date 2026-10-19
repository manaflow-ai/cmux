#![cfg(any(unix, windows))]

use acpmux::store::{EventRecord, LocalStore, Store};
use serde_json::json;
#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

struct TestDirectory(PathBuf);

impl TestDirectory {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!("acpmux-store-mode-{}", uuid::Uuid::now_v7()));
        std::fs::create_dir(&path).unwrap();
        Self(path)
    }
}

impl Drop for TestDirectory {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

#[cfg(unix)]
fn make_permissive(path: &Path, mode: u32) {
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode)).unwrap();
}

#[cfg(windows)]
fn make_permissive(_path: &Path, _mode: u32) {}

#[cfg(unix)]
fn owner_only(path: &Path, mode: u32) -> bool {
    std::fs::metadata(path).unwrap().permissions().mode() & 0o777 == mode
}

#[cfg(windows)]
fn owner_only(path: &Path, _mode: u32) -> bool {
    let owner = cmux::local_socket::win::current_identity().unwrap().user_sid;
    cmux::local_socket::win::directory_is_owner_only(path, &owner).unwrap()
}

#[test]
fn local_store_repairs_and_keeps_session_transcripts_owner_only() {
    let directory = TestDirectory::new();
    let root = directory.0.join("sessions");
    let events = root.join("chat").join("events");
    std::fs::create_dir_all(&events).unwrap();
    make_permissive(&root, 0o755);
    make_permissive(&root.join("chat"), 0o755);
    make_permissive(&events, 0o755);
    let segment = events.join("000001.ndjson");
    std::fs::write(&segment, []).unwrap();
    make_permissive(&segment, 0o644);

    let store = LocalStore::new(root.clone(), 64 * 1024).unwrap();
    store
        .append(
            "chat",
            &EventRecord {
                seq: 1,
                at: 1,
                dir: "in".to_owned(),
                kind: "prompt".to_owned(),
                msg: json!({"text": "private transcript"}),
                host_seq: None,
            },
        )
        .unwrap();
    store.flush().unwrap();

    assert!(owner_only(&root, 0o700));
    assert!(owner_only(&root.join("chat"), 0o700));
    assert!(owner_only(&events, 0o700));
    assert!(owner_only(&segment, 0o600));
}
