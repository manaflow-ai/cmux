//! Part of `Hub`; see `hub/mod.rs`. Prompt bookmarks (`_acpmux/bookmark_get`,
//! `_acpmux/bookmark_set`): the person's marks on a chat's own prompts, from
//! the pane's thread minimap, and the Pin of a message's action row. Each is
//! the seq of a `user_message` record (a prompt) or a `turn_result` record (the
//! answer of its turn) in the chat's log, kept in its `SessionMeta` so a restart, a move and every
//! attached pane see the same marks. A change is logged as a mux `bookmarks`
//! record, as tags are, which is how attached panes hear of it.

use super::*;
use std::collections::BTreeSet;

impl Hub {
    /// The most bookmarks one chat keeps.
    pub const MAX_BOOKMARKS: usize = 1000;

    /// Mark or unmark the prompt (or the turn's answer) logged at `seq`, and
    /// return the chat's marks. Only a `user_message` or `turn_result` record of
    /// this chat can be marked; unmarking takes any seq, so a mark whose message
    /// is gone can still be cleared.
    pub async fn set_bookmark(
        self: &Arc<Self>,
        session: &Session,
        seq: u64,
        bookmarked: bool,
    ) -> Result<Vec<u64>, RpcError> {
        if bookmarked && !self.is_markable(session, seq).await {
            return Err(RpcError::invalid_params(format!(
                "seq {seq} is not a prompt or an answer in session {}",
                session.id
            )));
        }
        // One section under the chat's move lock for the check, the change, its record and its
        // save: two sets log (and save) in the order they change the marks, so the last record
        // every pane hears is the marks kept; and a move begins before the change or after it.
        let moving = session.moving.lock().unwrap_or_else(|e| e.into_inner());
        if moving.is_some() {
            return Err(queue::moving_error());
        }
        let (marks, before) = {
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
            let marks = meta.bookmarks.iter().copied().collect::<Vec<_>>();
            (marks, changed.then_some(meta.updated_at))
        };
        // Unchanged: answered once the earlier change that made the marks so is on disk.
        let Some(before) = before else {
            let durable = self.meta_barrier(session);
            drop(moving);
            return durable.map(|()| marks);
        };
        let record = self.append(session, "mux", "bookmarks", json!({"bookmarks": marks}));
        {
            // A mark is not chat activity: the session keeps its place in the list.
            let mut meta = session.meta.lock().unwrap_or_else(|e| e.into_inner());
            if meta.updated_at == record.at {
                meta.updated_at = before;
            }
        }
        let saved = self.save_meta_answered(session);
        drop(moving);
        saved.map(|()| marks)
    }

    /// Whether `seq` is a prompt (`user_message`) or a turn's answer (`turn_result`) in the chat's log. The store reads files, so
    /// the scan runs off the async workers.
    async fn is_markable(self: &Arc<Self>, session: &Session, seq: u64) -> bool {
        if seq == 0 || seq > session.seq.load(Ordering::SeqCst) {
            return false;
        }
        let (hub, id) = (self.clone(), session.id.clone());
        let scan = tokio::task::spawn_blocking(move || {
            let mut found = false;
            let _ = hub.store.scan(&id, seq - 1, &mut |e: EventRecord| {
                found = e.seq == seq
                    && e.dir == "mux"
                    && (e.kind == "user_message" || e.kind == "turn_result");
                false
            });
            found
        });
        scan.await.unwrap_or(false)
    }
}

/// `marks` cut to the newest `Hub::MAX_BOOKMARKS`: a bundle from elsewhere may hold any number.
pub(super) fn capped(marks: &mut BTreeSet<u64>) {
    while marks.len() > Hub::MAX_BOOKMARKS {
        marks.pop_first();
    }
}
