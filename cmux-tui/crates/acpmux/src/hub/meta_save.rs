//! Part of `Hub`; see `hub/mod.rs`. A chat's metadata saves (`session.json`).
//!
//! A save copies the chat's metadata and writes the copy. Each chat's saves hold its `meta_save`
//! lock from the copy through the write, so they reach `session.json` in the order of their
//! copies: a save that copied the metadata before a change can no longer write after that
//! change's own save. Before, two saves of one chat ran side by side, and an older copy could
//! write over an acknowledged change, which a `kill -9` before the next save then lost (fuzz row
//! g finding g2: an acknowledged `_acpmux/draft_set`, "the one durable shared draft").
//!
//! A request whose answer reports the change saves with [`Hub::save_meta_answered`]: a save that
//! fails fails the request (`store.save_failed`), so no change is acknowledged that is not in
//! `session.json`. The change stays in memory, as the daemon's other state does, and the next
//! save that succeeds writes it.
//!
//! Test seam (debug builds): `ACPMUX_TEST_SAVE_META_HOLD_DIR` names a folder. When it holds
//! `hold-<session id>`, the next save of that chat's metadata takes the file (renames it to
//! `held-<session id>`) after it copied the metadata and before it writes the copy, and waits until
//! `release-<session id>` exists (at most 30 s). A test so holds an older copy of a chat's
//! metadata while other requests change and save it (`tests/meta_save_order.rs`).

use super::*;

impl Hub {
    /// Saves the chat's metadata; a failure is logged (a save no request answers for).
    pub(super) fn save_meta(&self, session: &Session) {
        if let Err(e) = self.write_meta(session) {
            tracing::warn!(session = %session.id, "save meta failed: {e}");
        }
    }

    /// Saves the chat's metadata for a request whose answer reports the change: a failed save
    /// fails the request.
    pub(super) fn save_meta_answered(&self, session: &Session) -> Result<(), RpcError> {
        self.write_meta(session).map_err(|e| {
            tracing::warn!(session = %session.id, "save meta failed: {e}");
            RpcError::internal(format!("the chat's change was not saved: {e}"))
                .with_data(json!({"reason": "store.save_failed"}))
        })
    }

    /// One save: the copy and its write under the chat's `meta_save` lock (module text). A
    /// purged chat saves nothing.
    pub(super) fn write_meta(&self, session: &Session) -> Result<()> {
        if session.purged.load(Ordering::SeqCst) {
            return Ok(());
        }
        let _order = session.meta_save.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let meta = session.meta();
        #[cfg(debug_assertions)]
        hold_seam(&session.id);
        let saved = self.store.save(&meta);
        // The purge ran between the check and the save: delete it again.
        if session.purged.load(Ordering::SeqCst)
            && let Err(e) = self.store.delete(&session.id)
        {
            tracing::warn!(session = %session.id, "delete of a purged session failed: {e}");
        }
        saved
    }
}

/// The seam in the module text, between a save's copy and its write.
#[cfg(debug_assertions)]
fn hold_seam(session_id: &str) {
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
