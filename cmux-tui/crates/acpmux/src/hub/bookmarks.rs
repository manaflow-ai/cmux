//! Part of `Hub`; see `hub/mod.rs`. Prompt bookmarks (`_acpmux/bookmark_get`,
//! `_acpmux/bookmark_set`): the person's marks on a chat's own prompts, from
//! the pane's thread minimap. Each is the seq of a `user_message` record in
//! the chat's log, kept in its `SessionMeta` so a restart, a move and every
//! attached pane see the same marks. A change is logged as a mux `bookmarks`
//! record, as tags are, which is how attached panes hear of it.

use super::*;
use std::collections::BTreeSet;

impl Hub {
    /// The most bookmarks one chat keeps.
    pub const MAX_BOOKMARKS: usize = 1000;

    /// Mark or unmark the prompt logged at `seq`, and return the chat's marks.
    /// Only a `user_message` record of this chat can be marked; unmarking takes
    /// any seq, so a mark whose prompt is gone can still be cleared.
    pub fn set_bookmark(
        &self,
        session: &Session,
        seq: u64,
        bookmarked: bool,
    ) -> Result<Vec<u64>, RpcError> {
        if session.moving().is_some() {
            return Err(queue::moving_error());
        }
        if bookmarked && !self.is_prompt(session, seq) {
            return Err(RpcError::invalid_params(format!(
                "seq {seq} is not a prompt in session {}",
                session.id
            )));
        }
        let (marks, changed) = {
            let mut meta = session.meta.lock().unwrap_or_else(|e| e.into_inner());
            if bookmarked
                && !meta.bookmarks.contains(&seq)
                && meta.bookmarks.len() >= Self::MAX_BOOKMARKS
            {
                return Err(RpcError::invalid_params(format!(
                    "a chat keeps at most {} bookmarks",
                    Self::MAX_BOOKMARKS
                )));
            }
            let changed =
                if bookmarked { meta.bookmarks.insert(seq) } else { meta.bookmarks.remove(&seq) };
            (meta.bookmarks.iter().copied().collect::<Vec<_>>(), changed)
        };
        if changed {
            // A mark is not chat activity: the session keeps its place in the list.
            let before = session.meta().updated_at;
            let record = self.append(session, "mux", "bookmarks", json!({"bookmarks": marks}));
            {
                let mut meta = session.meta.lock().unwrap_or_else(|e| e.into_inner());
                if meta.updated_at == record.at {
                    meta.updated_at = before;
                }
            }
            self.save_meta(session);
        }
        Ok(marks)
    }

    /// Whether `seq` is a prompt (`user_message`) in the chat's log.
    fn is_prompt(&self, session: &Session, seq: u64) -> bool {
        if seq == 0 || seq > session.seq.load(Ordering::SeqCst) {
            return false;
        }
        let mut found = false;
        let _ = self.store.scan(&session.id, seq - 1, &mut |e: EventRecord| {
            found = e.seq == seq && e.dir == "mux" && e.kind == "user_message";
            false
        });
        found
    }
}

/// `marks` cut to the newest `Hub::MAX_BOOKMARKS`: a bundle from elsewhere may hold any number.
pub(super) fn capped(marks: &mut BTreeSet<u64>) {
    while marks.len() > Hub::MAX_BOOKMARKS {
        marks.pop_first();
    }
}
