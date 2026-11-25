//! Part of `Hub`; see `hub/mod.rs`. A chat's sealed log segments go cold as they seal
//! (`store/cold_segments.rs`), with `agents.chats.coldSegments` on (off by default), at zstd
//! `agents.chats.coldSegmentsLevel` (3 by default). The settings are read from the settings file
//! at each pass, so turning it on takes the next seal (and each chat's backlog) and turning it off
//! stops the next pass; segments already cold stay cold and read as before.
//!
//! An open chat's log only grew: 152.1 MB at 100k rows (`scripts/measure/chat-disk-growth.py`),
//! 1.461 MB per simulated hour. With the setting on, everything but the open segment and the
//! indexes is compressed: `scripts/measure/chat-cold-segments.py` measures it.
//!
//! One worker for the daemon ([`Hub::cold_segments_worker`]), never a thread per segment. The
//! store calls a hook when a segment rolls over (`LocalStore::append_line`), under its writers'
//! lock: the hook only puts the chat's id in [`Hub::cold_sealed`] and wakes the worker. The worker
//! takes the set and, on one blocking thread, one chat after another, moves at most [`PER_PASS`]
//! of each chat's sealed segments still hot, oldest first; a chat with more left goes back in the
//! set for the next round, so a backlog drains a few segments at a time behind every other chat's.
//! Its first pass takes every chat: it finishes what a crash left (`settle_cold_segments`, with
//! the setting on or off) and, with it on, starts each chat's backlog.
//!
//! Each move is the store's: archive, verify and sync with no lock held, then the journal's
//! checkpoint through the chat's newest record (`Store::prepare_cold_segments`): a segment goes
//! cold only once the checkpoint covers its last line, so a replay (`journal_store/repair.rs`,
//! `journal_restore.rs`) rewrites only the tail past it. The commit runs under the chat's append
//! lock. A chat is left as it is while it is purged, replaced, moving, being imported or restored:
//! those read or replace its files as files.
//!
//! Stop condition: the worker is a task of the hub's scope and ends when the daemon shuts down
//! (the scope's close cancels it; `shutdown.rs` also wakes it, and it finds the shutdown begun; a
//! round checks it between chats) or the hub is gone; it holds the hub weakly between wakes.

use super::*;
use crate::store::ColdMoved;

/// Whether sealed segments go cold.
pub(crate) const SETTING_ON: &str = "agents.chats.coldSegments";
/// zstd's level for them.
pub(crate) const SETTING_LEVEL: &str = "agents.chats.coldSegmentsLevel";
/// The most sealed segments of one chat a round moves.
pub const PER_PASS: usize = 2;

/// The zstd level to move segments at, from the settings document; None when the setting is off.
pub(crate) fn level_of(doc: &Value) -> Option<i32> {
    if crate::user_settings::value(doc, SETTING_ON) != Some(Value::Bool(true)) {
        return None;
    }
    let level = crate::user_settings::value(doc, SETTING_LEVEL)
        .and_then(|v| v.as_i64())
        .and_then(|v| i32::try_from(v).ok())
        .filter(|v| (1..=19).contains(v))
        .unwrap_or(crate::store::cold_segments::DEFAULT_LEVEL);
    Some(level)
}

/// [`level_of`] of the settings file as it is now.
fn level_now() -> Option<i32> {
    match crate::user_settings::read() {
        crate::user_settings::Settings::Parsed(doc) => level_of(&doc),
        _ => None,
    }
}

impl Hub {
    /// Installs the store's seal hook and starts the worker (module docs).
    /// The hub's scope owns it: its close at shutdown ends it, as the shutdown check does.
    pub fn cold_segments_worker(self: &Arc<Self>) -> tokio::task::JoinHandle<Option<()>> {
        let (set, wake) = (self.cold_sealed.clone(), self.cold_sealed_wake.clone());
        self.store.on_segment_sealed(Arc::new(move |id: &str| {
            set.lock().unwrap_or_else(|e| e.into_inner()).insert(id.to_owned());
            wake.notify_one();
        }));
        // The first pass takes every chat.
        {
            let mut set = self.cold_sealed.lock().unwrap_or_else(|e| e.into_inner());
            set.extend(self.sessions().into_iter().map(|s| s.id.clone()));
        }
        self.cold_sealed_wake.notify_one();
        let hub = Arc::downgrade(self);
        let (set, wake) = (self.cold_sealed.clone(), self.cold_sealed_wake.clone());
        self.scope.spawn_until_cancelled("cold-segments", async move {
            loop {
                wake.notified().await;
                let Some(hub) = hub.upgrade() else { return };
                if hub.shutting_down() {
                    return;
                }
                let ids = std::mem::take(&mut *set.lock().unwrap_or_else(|e| e.into_inner()));
                let worker = hub.clone();
                let done =
                    tokio::task::spawn_blocking(move || worker.cold_segments_round(ids)).await;
                match done {
                    Ok(true) => hub.cold_sealed_wake.notify_one(),
                    Ok(false) => {}
                    Err(e) => tracing::warn!("cold log segments: {e}"),
                }
            }
        })
    }

    /// One round over `ids` (module docs): whether a chat has more to move.
    pub(crate) fn cold_segments_round(&self, ids: std::collections::BTreeSet<String>) -> bool {
        #[cfg(test)]
        let level = self
            .cold_segments_level
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .unwrap_or_else(level_now);
        #[cfg(not(test))]
        let level = level_now();
        let mut more = false;
        for id in ids {
            if self.shutting_down() {
                return false;
            }
            match self.cold_segments_of(&id, level) {
                Ok((moved, left)) => {
                    if moved.segments > 0 {
                        tracing::debug!(session = %id, "{} sealed log segments went cold: {} -> {} bytes", moved.segments, moved.raw, moved.comp);
                    }
                    if left {
                        self.cold_sealed.lock().unwrap_or_else(|e| e.into_inner()).insert(id);
                        more = true;
                    }
                }
                Err(e) => tracing::warn!(session = %id, "cold log segments: {e:#}"),
            }
        }
        more
    }

    /// Settles `id`'s cold segments and, at `level` (None: the setting is off), moves at most
    /// [`PER_PASS`] of its sealed segments cold. What it moved, and whether more wait.
    pub(crate) fn cold_segments_of(
        &self,
        id: &str,
        level: Option<i32>,
    ) -> anyhow::Result<(ColdMoved, bool)> {
        let session = self.sessions.lock().unwrap_or_else(|e| e.into_inner()).get(id).cloned();
        if session.as_deref().is_some_and(|s| !self.cold_segments_movable(s)) {
            return Ok((ColdMoved::default(), false));
        }
        self.store.settle_cold_segments(id)?;
        let Some(level) = level else { return Ok((ColdMoved::default(), false)) };
        let Some(staged) = self.store.stage_cold_segments(id, PER_PASS, level)? else {
            return Ok((ColdMoved::default(), false));
        };
        let more = staged.more;
        // The journal's checkpoint, before the append lock: it may take seconds.
        // Not now (a frozen journal): the next seal tries again, never a loop here.
        if !self.store.prepare_cold_segments(id, &staged)? {
            return Ok((ColdMoved::default(), false));
        }
        let moved = match session.as_deref() {
            Some(session) => {
                let _order = session.append_lock.lock().unwrap_or_else(|e| e.into_inner());
                if !self.cold_segments_movable(session) {
                    return Ok((ColdMoved::default(), false));
                }
                self.store.commit_cold_segments(id, staged)?
            }
            None => self.store.commit_cold_segments(id, staged)?,
        };
        Ok((moved, more))
    }

    /// `cmux chats warm` (`_acpmux/chats_warm`): every cold segment of `only`, or of every chat,
    /// back to a plain `.ndjson` (`LocalStore::warm_cold_segments`), each chat under its append
    /// lock as a move's commit is. Refused while the setting is on: the worker would compress them
    /// again. What it brought back, what it left cold and why, and the chats it skipped.
    pub(crate) fn warm_cold_segments(&self, only: Option<&str>) -> anyhow::Result<Value> {
        #[cfg(test)]
        let level = self
            .cold_segments_level
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .unwrap_or_else(level_now);
        #[cfg(not(test))]
        let level = level_now();
        anyhow::ensure!(
            level.is_none(),
            "{SETTING_ON} is on, so its worker would compress them again: turn it off first \
             (`cmux settings set {SETTING_ON} false`), then run `cmux chats warm` again"
        );
        // A chat this daemon has not loaded is warmed from its files all the same.
        let ids: Vec<String> = match only {
            Some(id) => vec![id.to_owned()],
            None => self.sessions().into_iter().map(|s| s.id.clone()).collect(),
        };
        let (mut chats, mut segments, mut raw, mut comp) = (0u64, 0u64, 0u64, 0u64);
        let (mut left, mut skipped) = (Vec::new(), Vec::new());
        for id in ids {
            let session = self.sessions.lock().unwrap_or_else(|e| e.into_inner()).get(&id).cloned();
            let warmed = match session.as_deref() {
                Some(session) => {
                    let _order = session.append_lock.lock().unwrap_or_else(|e| e.into_inner());
                    if !self.cold_segments_movable(session) {
                        skipped.push(json!({"chat": id, "reason": "busy: moving, restoring, importing or purged; try again"}));
                        continue;
                    }
                    self.store.warm_cold_segments(&id)
                }
                None => self.store.warm_cold_segments(&id),
            };
            let warmed = match warmed {
                Ok(warmed) => warmed,
                Err(e) => {
                    left.push(json!({"chat": id, "error": format!("{e:#}")}));
                    continue;
                }
            };
            if warmed.archived_whole {
                skipped.push(json!({"chat": id, "reason": "compressed whole by Compress Old Chats: open it, then warm it"}));
            }
            if warmed.segments > 0 {
                chats += 1;
            }
            segments += warmed.segments;
            raw += warmed.raw;
            comp += warmed.comp;
            for (segment, error) in warmed.left {
                left.push(json!({"chat": id, "segment": segment, "error": error}));
            }
        }
        Ok(json!({
            "chats": chats,
            "segments": segments,
            "rawBytes": raw,
            "compressedBytes": comp,
            "left": left,
            "skipped": skipped,
        }))
    }

    /// Whether nothing reads or replaces `session`'s files as files now.
    fn cold_segments_movable(&self, session: &Session) -> bool {
        !session.purged.load(Ordering::SeqCst)
            && !session.replaced.load(Ordering::SeqCst)
            && !session.restoring.load(Ordering::SeqCst)
            && session.moving().is_none()
            && !self.importing.lock().unwrap_or_else(|e| e.into_inner()).contains(&session.id)
    }
}

#[cfg(test)]
#[path = "cold_segments_tests.rs"]
mod tests;
