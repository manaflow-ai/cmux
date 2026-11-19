//! `_acpmux/usage`: what Session Info's Usage draws, every chat's `usageStats` by its list id, and
//! nothing else. Before it, each time Session Info showed, the pane read the whole session list
//! with `usage: true` (`_acpmux/sessions`, 200 rows a page) only to take each row's `usageStats`:
//! 50 requests and every row's bytes at 10,000 chats, on every open, though only the chats of the
//! last day have usage at all.
//!
//! The answer is built from the chats a usage pass reads (`usage_view.rs`): the live ones and the
//! rows changed in the last day (the kept list order, never a walk of every chat), each with its
//! stats as its row lists them ([`Hub::usage_stats_of`]), and the peers' and hub machines' rows
//! that carry `usageStats` ([`PeerRow::usage_stats_text`], no row parsed). Its cost is the chats
//! with usage, not the list.
//!
//! The last answer is kept with the list position it was built at (`list_cursor`). Every change a
//! row's `usageStats` can show moves that position: a pass that changes a chat's stats tells its
//! row (`row_changed`), a purge and a peer's change are stamped, and a chat's own changes (its
//! status, its window, its subagents) are its row's. So an ask at the same position answers the
//! kept one and builds nothing, and one after any change builds anew: an answer is never older
//! than the list it is asked beside. Its digest is of its content: a client that sends the digest
//! it holds (`known`) gets `{digest, unchanged: true}`, no stats, while the stats read the same,
//! however often the position moved.
//!
//! One answer is kept (its size is the chats with usage, the same set a pass reads), so the
//! memory is bounded by what one answer holds. A peer's own link reads only this daemon's chats
//! (as its list does) and is answered unkept.

use super::*;
use std::collections::BTreeMap;
use std::hash::{Hash, Hasher};

/// The last answer, at the list position it was built at.
#[derive(Default)]
pub(crate) struct UsageAnswers {
    last: StdMutex<Option<Arc<Built>>>,
    /// How many answers were built: a test's count of the asks that read the chats.
    #[cfg(test)]
    pub(crate) builds: std::sync::atomic::AtomicU64,
}

struct Built {
    epoch: String,
    head: u64,
    digest: String,
    /// `None` when the stats are larger than a reply page: the client reads the list's pages.
    usage: Option<Value>,
}

impl Hub {
    /// `_acpmux/usage`'s reply: `{digest, usage}` with every listed chat's `usageStats` by its list
    /// id, or `{digest, unchanged: true}` when `known` is the digest of what it would send. Stats
    /// larger than a reply page ([`crate::rpc::REPLY_PAGE_BYTES`]) are `{digest}` alone, and the
    /// client reads them from the list's pages, which are bounded (`server/reply_size_tests.rs`).
    /// `own_only`: a peer's link, which reads only this daemon's chats.
    pub(crate) fn usage_answer(&self, known: Option<&str>, own_only: bool) -> Value {
        let built = self.usage_built(own_only);
        let Some(usage) = built.usage.as_ref() else {
            return json!({"digest": built.digest});
        };
        if known == Some(built.digest.as_str()) {
            return json!({"digest": built.digest, "unchanged": true});
        }
        json!({"digest": built.digest, "usage": usage})
    }

    fn usage_built(&self, own_only: bool) -> Arc<Built> {
        // The position is read before the chats: a change during the build moves it past this
        // one, so the next ask builds again.
        let (head, epoch) = {
            let (head, epoch) = self.list_cursor();
            (head, epoch.to_owned())
        };
        if !own_only {
            let last = self.usage_answers.last.lock().unwrap_or_else(|e| e.into_inner());
            if let Some(last) = last.as_ref().filter(|b| b.head == head && b.epoch == epoch) {
                return last.clone();
            }
        }
        let (usage, whole) = self.usage_by_row(own_only);
        #[cfg(test)]
        self.usage_answers.builds.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        let text = serde_json::to_string(&usage).unwrap_or_default();
        let mut hasher = std::collections::hash_map::DefaultHasher::new();
        text.hash(&mut hasher);
        let digest = format!("{epoch}-{:016x}", hasher.finish());
        // The kept answer is at most a reply page, so its memory is bounded too.
        let usage = (text.len() <= crate::rpc::REPLY_PAGE_BYTES).then(|| json!(usage));
        let built = Arc::new(Built { epoch, head, digest, usage });
        // An answer that read a chat's subagents while their lock was held is sent, not kept: the
        // count it fell back to is fixed by the next ask, not only by the next change.
        if !own_only && whole {
            let mut last = self.usage_answers.last.lock().unwrap_or_else(|e| e.into_inner());
            // A slower build at an older position never replaces a newer one.
            if last.as_ref().is_none_or(|b| b.epoch != built.epoch || b.head <= built.head) {
                *last = Some(built.clone());
            }
        }
        built
    }

    /// Every chat's `usageStats` as its row lists it, by the id the row lists it under: this
    /// daemon's chats a pass reads, and the peers' and hub machines' rows that carry stats. The
    /// flag is false when a chat's subagents were busy as it was read ([`Hub::usage_stats_of`]
    /// reads them without waiting), so the answer is not kept.
    fn usage_by_row(&self, own_only: bool) -> (BTreeMap<String, Value>, bool) {
        let mut usage = BTreeMap::new();
        let mut whole = true;
        let now = crate::store::now_ms();
        let live = self.live_session_handles();
        let recent = self.own_rows_since(now.saturating_sub(crate::usage_stats::DAY_MS));
        for session in live.into_iter().chain(recent) {
            if usage.contains_key(&session.id) {
                continue;
            }
            let m = session.meta();
            let free = || session.subagents.try_lock().is_ok();
            let before = free();
            if let Some(stats) = self.usage_stats_of(&session, &m)
                && let Ok(stats) = serde_json::to_value(stats)
            {
                whole &= before && free();
                usage.insert(session.id.clone(), stats);
            }
        }
        if own_only {
            return (usage, whole);
        }
        let mut mirrored = |row: &RemoteSession| {
            let (Some(id), Some(text)) = (row.summary.session_id(), row.summary.usage_stats_text())
            else {
                return;
            };
            if let Ok(stats) = serde_json::from_str::<Value>(text) {
                usage.entry(id.to_owned()).or_insert(stats);
            }
        };
        for row in self.remote_sessions.read().values() {
            mirrored(row);
        }
        for row in self.mesh_book_rows(|row| row.summary.usage_stats_text().is_some()) {
            mirrored(&row);
        }
        (usage, whole)
    }

    /// How many `_acpmux/usage` answers were built.
    #[cfg(test)]
    pub(crate) fn usage_answer_builds_for_test(&self) -> u64 {
        self.usage_answers.builds.load(std::sync::atomic::Ordering::SeqCst)
    }
}

#[cfg(test)]
#[path = "usage_answer_tests.rs"]
mod tests;
