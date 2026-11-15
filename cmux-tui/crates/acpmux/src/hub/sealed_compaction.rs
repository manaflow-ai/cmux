//! Part of `Hub`; see `hub/mod.rs`. A live chat's sealed log segments compacted as they seal
//! (`store/sealed_compact.rs`).
//!
//! A chat's log only grew while it was open: retention takes closed chats only (`retention.rs`),
//! so one busy coordinator chat on huge-blue held 1,008 MB in 126 segments after 13 days, and
//! the disk bench (`scripts/measure/chat-disk-growth.py`) measured 1.46 MB per simulated hour.
//! Most of it is tool call updates a later update of the same call replaces (codex-acp sends a
//! command's whole output so far in each).
//!
//! The store calls a hook when a segment rolls over (`LocalStore::append_line`), under its
//! writers' lock: the hook only puts the chat's id in [`Hub::sealed_logs`] and wakes the worker.
//! The worker ([`Hub::sealed_compaction_worker`]) takes the set and, on a blocking thread, one
//! chat after another, compacts at most [`PER_SEAL`] of each chat's sealed segments not yet
//! compacted, oldest first: bounded work per seal, never on an append, an attach or a page. A
//! chat with a backlog (one that grew before this) loses it a segment or two per seal.
//!
//! A chat is left as it is while it is purged, replaced, moving, being imported or restored
//! (`journal_restore.rs`): those read or replace its files as files. The check and the commit run
//! under the chat's append lock, which only waits for the renames (the copies are written and
//! the journal checkpointed before it, `Store::prepare_sealed`).
//!
//! Stop condition: the worker ends when the daemon shuts down (`shutdown.rs` wakes it, and it
//! finds the shutdown begun) or the hub is gone; it holds the hub weakly between wakes.

use super::*;
use crate::store::Compaction;

/// The most sealed segments of one chat a seal compacts.
pub const PER_SEAL: usize = 2;

impl Hub {
    /// Installs the store's seal hook and starts the worker (module docs).
    pub fn sealed_compaction_worker(self: &Arc<Self>) -> tokio::task::JoinHandle<()> {
        let (set, wake) = (self.sealed_logs.clone(), self.sealed_wake.clone());
        self.store.on_segment_sealed(Arc::new(move |id: &str| {
            set.lock().unwrap_or_else(|e| e.into_inner()).insert(id.to_owned());
            wake.notify_one();
        }));
        let hub = Arc::downgrade(self);
        let (set, wake) = (self.sealed_logs.clone(), self.sealed_wake.clone());
        tokio::spawn(async move {
            loop {
                wake.notified().await;
                let Some(hub) = hub.upgrade() else { return };
                if hub.shutting_down() {
                    return;
                }
                let ids = std::mem::take(&mut *set.lock().unwrap_or_else(|e| e.into_inner()));
                let worker = hub.clone();
                let done = tokio::task::spawn_blocking(move || {
                    for id in ids {
                        if worker.shutting_down() {
                            return;
                        }
                        match worker.compact_sealed(&id, PER_SEAL) {
                            Ok(stats) if stats.bytes_before > 0 => tracing::debug!(
                                session = %id,
                                "sealed log segments compacted: {} -> {} bytes, {} records dropped",
                                stats.bytes_before,
                                stats.bytes_after,
                                stats.dropped
                            ),
                            Ok(_) => {}
                            Err(e) => tracing::warn!(session = %id, "sealed log compaction: {e:#}"),
                        }
                    }
                })
                .await;
                if let Err(e) = done {
                    tracing::warn!("sealed log compaction: {e}");
                }
            }
        })
    }

    /// Compacts at most `max` of `id`'s sealed segments not compacted yet (module docs). What it
    /// changed; nothing when the chat is busy as the module docs say, or changed meanwhile.
    pub(crate) fn compact_sealed(&self, id: &str, max: usize) -> anyhow::Result<Compaction> {
        let session = self.sessions.lock().unwrap_or_else(|e| e.into_inner()).get(id).cloned();
        if session.as_deref().is_some_and(|s| !self.sealed_compactable(s)) {
            return Ok(Compaction::default());
        }
        let Some(staged) = self.store.stage_sealed(id, &[], max)? else {
            return Ok(Compaction::default());
        };
        let stats = staged.stats();
        // The journal's checkpoint, before the append lock: it may take seconds.
        if !self.store.prepare_sealed(id)? {
            return Ok(Compaction::default());
        }
        let committed = match session.as_deref() {
            Some(session) => {
                let _order = session.append_lock.lock().unwrap_or_else(|e| e.into_inner());
                self.sealed_compactable(session) && self.store.commit_sealed(id, staged)?
            }
            None => self.store.commit_sealed(id, staged)?,
        };
        Ok(if committed { stats } else { Compaction::default() })
    }

    /// Whether nothing reads or replaces `session`'s files as files now.
    fn sealed_compactable(&self, session: &Session) -> bool {
        !session.purged.load(Ordering::SeqCst)
            && !session.replaced.load(Ordering::SeqCst)
            && !session.restoring.load(Ordering::SeqCst)
            && session.moving().is_none()
            && !self.importing.lock().unwrap_or_else(|e| e.into_inner()).contains(&session.id)
    }
}

#[cfg(test)]
#[path = "sealed_compaction_tests.rs"]
mod tests;
