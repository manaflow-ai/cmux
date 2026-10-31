//! Part of `Hub`; see `hub/mod.rs`. A chat's metadata saves (`session.json`).
//!
//! Test seam (debug builds): `ACPMUX_TEST_SAVE_META_HOLD_DIR` names a folder. When it holds
//! `hold-<session id>`, the next save of that chat's metadata takes the file (renames it to
//! `held-<session id>`) after it copied the metadata and before it writes the copy, and waits until
//! `release-<session id>` exists (at most 30 s). A test so holds an older copy of a chat's
//! metadata while other requests change and save it (`tests/meta_save_order.rs`, fuzz row g
//! finding g2).

/// The seam above, between a save's copy and its write.
#[cfg(debug_assertions)]
pub(super) fn hold_seam(session_id: &str) {
    let Some(dir) = std::env::var_os("ACPMUX_TEST_SAVE_META_HOLD_DIR") else { return };
    let dir = std::path::PathBuf::from(dir);
    let hold = dir.join(format!("hold-{session_id}"));
    if std::fs::rename(&hold, dir.join(format!("held-{session_id}"))).is_err() {
        return;
    }
    let release = dir.join(format!("release-{session_id}"));
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
    while !release.exists() && std::time::Instant::now() < deadline {
        std::thread::sleep(std::time::Duration::from_millis(5));
    }
    let _ = std::fs::remove_file(release);
}
