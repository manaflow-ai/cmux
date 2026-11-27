use super::*;

/// The shutdown start is visible to the next owner as soon as `begin`
/// returns, with no wait on the disk.
#[test]
fn begin_writes_the_marker_without_waiting_on_disk() {
    let directory =
        std::env::temp_dir().join(format!("cmux-session-shutdown-marker-{}", std::process::id()));
    std::fs::create_dir_all(&directory).expect("temporary directory");
    let marker = directory.join("registry.owner-shutdown");
    let clock = SessionShutdownClock::open(Some(marker.clone()), 1_000);
    clock.set_now_for_test(5_000);
    clock.begin();
    assert_eq!(std::fs::read_to_string(&marker).expect("marker"), "5000");
    let leftovers: Vec<_> = std::fs::read_dir(&directory)
        .expect("list")
        .flatten()
        .filter(|entry| entry.file_name().to_string_lossy().ends_with(".tmp"))
        .collect();
    assert!(leftovers.is_empty(), "temporary marker files left: {leftovers:?}");
    let _ = std::fs::remove_dir_all(&directory);
}

/// Regression guard (cloud-instant-start): `write_marker` runs on the
/// `SIGTERM` path, and a sync there held a Cloud daemon's exit behind the
/// journal commit (`jbd2_log_wait_commit`) past the host's stop grace.
#[test]
fn marker_write_never_syncs() {
    let source = include_str!("session_shutdown.rs");
    let start = source.find("fn write_marker(").expect("write_marker");
    let body = &source[start..];
    let end = body.find("\n}\n").expect("end of write_marker");
    let body = &body[..end];
    for call in ["sync_all", "sync_data", "fsync", "fdatasync"] {
        assert!(!body.contains(call), "write_marker calls {call} on the shutdown path");
    }
}
