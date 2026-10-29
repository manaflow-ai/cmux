//! Listing an open chat reads its metadata, never enumerates its event segments.
use super::*;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};

#[test]
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
