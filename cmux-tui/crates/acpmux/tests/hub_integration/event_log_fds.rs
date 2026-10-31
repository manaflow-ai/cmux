//! A session's event log is not held open forever. On cmux16 (2026-10-22) the
//! daemon held one descriptor per session it had written since it started,
//! closed sessions included (193 of its 256), and `acpmux session stop` did not
//! release it: every agent start then failed with "Too many open files".

use super::*;
use std::path::Path;

/// The descriptors this process holds on files under `root`.
fn open_files_under(root: &Path) -> Vec<std::path::PathBuf> {
    let root = std::fs::canonicalize(root).unwrap();
    let mut out = Vec::new();
    #[cfg(target_os = "linux")]
    for entry in std::fs::read_dir("/proc/self/fd").unwrap().flatten() {
        if let Ok(target) = std::fs::read_link(entry.path())
            && target.starts_with(&root)
        {
            out.push(target);
        }
    }
    #[cfg(target_os = "macos")]
    for entry in std::fs::read_dir("/dev/fd").unwrap().flatten() {
        let Ok(fd) = entry.file_name().to_string_lossy().parse::<i32>() else { continue };
        let mut buf = vec![0u8; libc::PATH_MAX as usize];
        if unsafe { libc::fcntl(fd, libc::F_GETPATH, buf.as_mut_ptr()) } != 0 {
            continue;
        }
        let len = buf.iter().position(|&b| b == 0).unwrap_or(buf.len());
        let target = std::path::PathBuf::from(String::from_utf8_lossy(&buf[..len]).into_owned());
        if target.starts_with(&root) {
            out.push(target);
        }
    }
    out
}

/// Stopping a session closes its log: nothing writes to it until it is resumed.
#[cfg(any(target_os = "linux", target_os = "macos"))]
#[tokio::test]
async fn a_stopped_session_does_not_keep_its_event_log_open() {
    let (hub, mut c, dir) = super::transcript_events::setup_segmented(64 * 1024).await;
    let id = new_session(&mut c, "fd-stop").await;
    c.request(method::SESSION_PROMPT, prompt(&id, "hello", None)).await.unwrap();
    let events = dir.join("sessions").join(&hub.resolve("fd-stop").unwrap().id).join("events");
    assert!(!open_files_under(&events).is_empty(), "the live session writes its log");

    c.request(method::MUX_KILL, json!({"sessionId": id})).await.unwrap();
    // The agent's exit is logged (`stopped`) after the kill answers, and that
    // write opens the log for its moment: look until it is closed again.
    let started = std::time::Instant::now();
    let mut open = open_files_under(&events);
    while !open.is_empty() && started.elapsed() < Duration::from_secs(2) {
        tokio::time::sleep(Duration::from_millis(20)).await;
        open = open_files_under(&events);
    }
    assert!(open.is_empty(), "a stopped session still holds its log open: {open:?}");
    let _ = std::fs::remove_dir_all(&dir);
}

/// However many sessions a daemon writes, it holds a bounded number of logs
/// open (64): the rest are opened again when they are next written.
#[cfg(any(target_os = "linux", target_os = "macos"))]
#[test]
fn writing_many_sessions_holds_a_bounded_number_of_logs_open() {
    let dir = std::env::temp_dir().join(format!("acpmux-fds-{}", uuid::Uuid::now_v7()));
    let mut cfg = Config::default();
    cfg.store.mode = StoreMode::Local;
    let store = acpmux::store::open(&cfg.store, &dir).unwrap();
    let record = |seq| acpmux::store::EventRecord {
        seq,
        at: seq,
        dir: "mux".into(),
        kind: "test".into(),
        msg: json!({"n": seq}),
        host_seq: None,
    };
    for n in 0..200 {
        store.append(&format!("session-{n:03}"), &record(1)).unwrap();
    }
    let open = open_files_under(&dir).len();
    assert!(open <= 64, "{open} event logs open after writing 200 sessions");
    // A session whose log was closed keeps appending to the same segment.
    store.append("session-000", &record(2)).unwrap();
    let events = store.events("session-000", 0, usize::MAX).unwrap();
    assert_eq!(events.iter().map(|e| e.seq).collect::<Vec<_>>(), [1, 2]);
    let _ = std::fs::remove_dir_all(&dir);
}
