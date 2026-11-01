//! Listing an open chat reads its metadata, never enumerates its event segments.
use super::*;
#[cfg(target_os = "linux")]
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};

#[test]
#[cfg(target_os = "linux")]
fn listing_open_chats_does_not_read_their_log_directories() {
    let home = tempfile::tempdir().unwrap();
    let store = LocalStore::new(home.path().join("sessions"), 64 * 1024).unwrap();
    let mut meta: SessionMeta = serde_json::from_value(serde_json::json!({
        "schema": META_SCHEMA, "id": "chat", "name": "chat", "harness": "fake",
        "cwd": home.path(), "status": "idle", "createdAt": 1, "updatedAt": 1,
    }))
    .unwrap();
    store.save(&meta).unwrap();
    store
        .append(
            "chat",
            &EventRecord {
                seq: 1,
                at: 1,
                dir: "mux".into(),
                kind: "created".into(),
                msg: Value::Null,
                host_seq: None,
            },
        )
        .unwrap();
    // Observe actual getdents access, not opens for the privacy/ACL checks, which remain.
    // SAFETY: creates a new descriptor; OwnedFd below owns its successful result.
    let raw = unsafe { libc::inotify_init1(libc::IN_NONBLOCK | libc::IN_CLOEXEC) };
    assert!(raw >= 0);
    // SAFETY: raw is a new, live descriptor and has no other owner.
    let watch = unsafe { OwnedFd::from_raw_fd(raw) };
    let events =
        std::ffi::CString::new(store.dir("chat").join("events").as_os_str().as_encoded_bytes())
            .unwrap();
    // SAFETY: watch is live and events is a NUL-terminated path.
    assert!(
        unsafe { libc::inotify_add_watch(watch.as_raw_fd(), events.as_ptr(), libc::IN_ACCESS) }
            >= 0
    );
    let accessed = || {
        let mut bytes = [0u8; 4096];
        // SAFETY: writable buffer and live descriptor, whose nonblocking reads never wait.
        let n = unsafe { libc::read(watch.as_raw_fd(), bytes.as_mut_ptr().cast(), bytes.len()) };
        if n < 0 {
            assert_eq!(std::io::Error::last_os_error().kind(), std::io::ErrorKind::WouldBlock);
        }
        n > 0
    };
    assert_eq!(store.list().unwrap().len(), 1);
    assert!(!accessed(), "metadata listing enumerated an open chat's log segments");
    // A closed chat still checks for a log (and this proves the observer detects the scan).
    meta.status = SessionStatus::Closed;
    store.save(&meta).unwrap();
    assert_eq!(store.list().unwrap().len(), 1);
    assert!(accessed(), "the closed-chat purge check did not examine its log");
}

#[test]
fn exact_load_checks_session_and_log_directory_privacy_before_metadata() {
    use std::os::unix::fs::{PermissionsExt, symlink};
    let home = tempfile::tempdir().unwrap();
    let store = LocalStore::new(home.path().join("sessions"), 64 * 1024).unwrap();
    let meta: SessionMeta = serde_json::from_value(serde_json::json!({
        "schema": META_SCHEMA, "id": "chat", "name": "chat", "harness": "fake",
        "cwd": home.path(), "status": "idle", "createdAt": 1, "updatedAt": 1,
    }))
    .unwrap();
    store.save(&meta).unwrap();
    assert!(store.load("missing").unwrap().is_none());
    assert!(!store.dir("missing").exists(), "a missing read created state");
    let session = store.dir("chat");
    let moved = home.path().join("moved-chat");
    std::fs::rename(&session, &moved).unwrap();
    symlink(&moved, &session).unwrap();
    assert!(store.load_startup("chat").is_err(), "exact load followed a session-directory link");
    std::fs::remove_file(&session).unwrap();
    std::fs::rename(&moved, &session).unwrap();
    let events = session.join("events");
    let outside = home.path().join("outside-events");
    std::fs::create_dir(&outside).unwrap();
    symlink(&outside, &events).unwrap();
    assert!(store.load_startup("chat").is_err(), "exact load trusted a log-directory link");
    std::fs::remove_file(&events).unwrap();
    std::fs::create_dir(&events).unwrap();
    for dir in [&session, &events] {
        std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o770)).unwrap();
        assert!(store.load_startup("chat").is_err(), "exact load trusted a writable directory");
        std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700)).unwrap();
    }
    assert_eq!(store.load("chat").unwrap(), Some(meta));
}

#[test]
fn exact_startup_load_excludes_the_same_purged_metadata_as_the_list() {
    let home = tempfile::tempdir().unwrap();
    let store = LocalStore::new(home.path().join("sessions"), 64 * 1024).unwrap();
    let mut meta: SessionMeta = serde_json::from_value(serde_json::json!({
        "schema": META_SCHEMA, "id": "chat", "name": "chat", "harness": "fake",
        "cwd": home.path(), "status": "closed", "createdAt": 1, "updatedAt": 1,
    }))
    .unwrap();
    store.save(&meta).unwrap();
    assert!(store.list().unwrap().is_empty());
    assert!(store.load_startup("chat").unwrap().is_none());
    assert_eq!(
        store.load("chat").unwrap(),
        Some(meta.clone()),
        "raw recovery load keeps its semantics"
    );
    meta.status = SessionStatus::Idle;
    store.save(&meta).unwrap();
    assert_eq!(store.load_startup("chat").unwrap(), Some(meta.clone()));
    meta.status = SessionStatus::Closed;
    store.save(&meta).unwrap();
    store
        .append(
            "chat",
            &EventRecord {
                seq: 1,
                at: 1,
                dir: "mux".into(),
                kind: "created".into(),
                msg: Value::Null,
                host_seq: None,
            },
        )
        .unwrap();
    assert_eq!(store.load_startup("chat").unwrap(), Some(meta));
    assert_eq!(store.list().unwrap().len(), 1);
}
