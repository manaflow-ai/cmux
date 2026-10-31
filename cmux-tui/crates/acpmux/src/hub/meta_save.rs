//! Part of `Hub`; see `hub/mod.rs`. A chat's metadata saves (`session.json`).
//!
//! Test seam (debug builds): `ACPMUX_TEST_SAVE_META_HOLD_DIR` names a folder. When it holds
//! `hold-<session id>`, the next save of that chat's metadata takes the file (renames it to
//! `held-<session id>`) after it copied the metadata and before it writes the copy, and waits until
//! `release-<session id>` exists (at most 30 s). A test so holds an older copy of a chat's
//! metadata while other requests change and save it (`tests/meta_save_order.rs`, fuzz row g
//! finding g2). When the folder holds `kill-<session id>`, that save removes the file and the
//! daemon kills itself with SIGKILL at the same point: after the change is made in memory and
//! copied, before its write (`tests/meta_save_kill_point.rs`).

/// The seam above, between a save's copy and its write.
#[cfg(debug_assertions)]
pub(super) fn hold_seam(session_id: &str) {
    let Some(dir) = std::env::var_os("ACPMUX_TEST_SAVE_META_HOLD_DIR") else { return };
    let dir = std::path::PathBuf::from(dir);
    // Removed first, so the next daemon does not kill itself again.
    if std::fs::remove_file(dir.join(format!("kill-{session_id}"))).is_ok() {
        // SAFETY: a signal to this process; the test that asked for it restarts the daemon.
        unsafe { libc::kill(libc::getpid(), libc::SIGKILL) };
    }
    let hold = dir.join(format!("hold-{session_id}"));
    if std::fs::rename(&hold, dir.join(format!("held-{session_id}"))).is_err() {
        return;
    }
    let release = dir.join(format!("release-{session_id}"));
    let wait = || {
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
        while !release.exists() && std::time::Instant::now() < deadline {
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
    };
    // On a worker of the daemon's runtime, the wait hands the worker's other tasks to another
    // thread first, so the requests the test sends meanwhile run (a task in a blocked worker's
    // LIFO slot is not stolen).
    match tokio::runtime::Handle::try_current().map(|h| h.runtime_flavor()) {
        Ok(tokio::runtime::RuntimeFlavor::MultiThread) => tokio::task::block_in_place(wait),
        _ => wait(),
    }
    let _ = std::fs::remove_file(release);
}
