#![cfg(unix)]

use acpmux::store::{EventRecord, LocalStore, Store};
use serde_json::json;
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

fn mode(path: &Path) -> u32 {
    std::fs::metadata(path).unwrap().permissions().mode() & 0o777
}

#[test]
fn local_store_repairs_and_keeps_session_transcripts_owner_only() {
    let directory = TestDirectory::new();
    let root = directory.0.join("sessions");
    let events = root.join("chat").join("events");
    std::fs::create_dir_all(&events).unwrap();
    std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o755)).unwrap();
    std::fs::set_permissions(root.join("chat"), std::fs::Permissions::from_mode(0o755)).unwrap();
    std::fs::set_permissions(&events, std::fs::Permissions::from_mode(0o755)).unwrap();
    let segment = events.join("000001.ndjson");
    std::fs::write(&segment, []).unwrap();
    std::fs::set_permissions(&segment, std::fs::Permissions::from_mode(0o644)).unwrap();

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

    assert_eq!(mode(&root), 0o700);
    assert_eq!(mode(&root.join("chat")), 0o700);
    assert_eq!(mode(&events), 0o700);
    assert_eq!(mode(&segment), 0o600);
}
