//! The remote origins the index refuses past its bound (`acpmux_core::hub::MAX_ORIGINS`), the
//! daemon log's sign of them, and their way back in (decision 261). The hub takes a submit into its
//! queue and its writer refuses the origin later, so the `Ok` the tee gets says nothing: the tee
//! tells a refusal itself, from the index it reads, before it submits. A slot frees when the
//! writer drops a removed origin's record (at a compaction) or a source with none; then
//! `Hub::origin_slots_freed` moves and the tee offers each origin kept here again, whole.
use super::TeeState;
use acpmux_book::index::OriginState;
use acpmux_core::hub::{Hub, MAX_ORIGINS};
use std::collections::BTreeSet;
use std::sync::atomic::Ordering;

#[derive(Default)]
pub(super) struct Refused {
    /// The origins seen refused and not admitted since, at most `MAX_ORIGINS`.
    ids: BTreeSet<String>,
    /// More origins were refused than `ids` keeps: the next release walks every remote row.
    overflow: bool,
    /// Every refused submit this tee made, the count each warn names.
    submits: u64,
    /// Warn lines written, for the tests of their bound.
    #[cfg(test)]
    pub(super) warns: u64,
}

impl Refused {
    /// Notes a submit for `origin`, which the hub has no source for: refused when the index has
    /// no record of `origin` and the writer's count (`Hub::origins_counted`) is at the bound. A
    /// record waiting on a log retry is counted by the writer alone, and the writer may fill the
    /// index after this submit: then the refusal goes untold until the origin's next change.
    pub(super) fn note(&mut self, hub: &Hub, origin: &str) {
        if hub.snapshot().origin(origin).is_some() || hub.origins_counted() < MAX_ORIGINS {
            return;
        }
        self.submits += 1;
        let kept = self.ids.contains(origin);
        if !kept && self.ids.len() == MAX_ORIGINS {
            // Full: the origins the writer counts now got in since, and were marked whole by the
            // release that let them in. Read only here, at most once per refused submit.
            let index = hub.snapshot();
            self.ids.retain(|id| index.origin(id).is_none() && hub.source(id).is_none());
        }
        let new = !kept && self.ids.len() < MAX_ORIGINS;
        if new {
            self.ids.insert(origin.to_owned());
        } else if !kept {
            self.overflow = true;
        }
        // A line for each origin newly refused, and else at each doubling of the count: the
        // lines follow the number of origins and the log of the submits, not the submits.
        if new || self.submits.is_power_of_two() {
            #[cfg(test)]
            {
                self.warns += 1;
            }
            tracing::warn!(
                origin,
                refused_submits = self.submits,
                refused_origins = self.ids.len(),
                more = self.overflow,
                limit = MAX_ORIGINS,
                "v2 list: the index holds its most origins; this machine's chats are not in the \
                 v2 list until a slot frees"
            );
        }
    }

    /// `origin` has a source in the hub: it got in when the index holds its record too. A row
    /// admitted alone (its source made by that row) leaves the origin kept, so a release still
    /// brings its record and its other rows.
    pub(super) fn admitted(&mut self, hub: &Hub, origin: &str) {
        if self.ids.contains(origin) && hub.snapshot().origin(origin).is_some() {
            self.ids.remove(origin);
        }
    }

    /// Nothing kept: no origin and no overflow.
    pub(super) fn is_empty(&self) -> bool {
        self.ids.is_empty() && !self.overflow
    }

    /// Drops `origin`, which v1 no longer lists.
    fn forget(&mut self, origin: &str) {
        self.ids.remove(origin);
    }

    #[cfg(test)]
    pub(super) fn kept(&self) -> (Vec<String>, bool) {
        (self.ids.iter().cloned().collect(), self.overflow)
    }
}

/// A slot may be free: marks each kept origin again through the tee's mark sets, its state as
/// v1 has it and every row v1 lists for it (an ssh peer's and the mesh hub's), so the drains that
/// follow submit at most a batch each and no writer turn does more. The origins stay kept until
/// the index holds their record (`Refused::admitted`); one refused again stays. Answers whether
/// more origins were refused than kept: the caller then runs the remote reconcile whole once,
/// O(remote rows), only on a slot freed after an overflow. The flag is cleared here, so a refusal
/// during that reconcile sets it again.
pub(super) fn release(v1: &crate::hub::Hub, hub: &Hub, state: &TeeState) -> bool {
    let (ids, overflow) = {
        let mut refused = state.refused.lock().unwrap_or_else(|e| e.into_inner());
        let index = hub.snapshot();
        refused.ids.retain(|id| index.origin(id).is_none());
        let kept = (refused.ids.iter().cloned().collect::<Vec<_>>(), refused.overflow);
        refused.overflow = false;
        state.refused_any.store(!refused.is_empty(), Ordering::Release);
        kept
    };
    let now = crate::store::now_ms();
    let mut gone = Vec::new();
    for id in &ids {
        if let Some(peer) = v1.peer_by_name(id) {
            state.origin(id, crate::hub::peers::peer_origin_state(&peer), now);
        } else if v1.mesh_book_has_host(id) {
            state.origin(id, OriginState::Connected, now);
        } else {
            gone.push(id);
            continue;
        }
        let rows = v1.remote_sessions.snapshot();
        for (_, row) in rows.of_peer(id) {
            if let Some(chat) = row.summary.session_id() {
                state.mark_remote(id, chat);
            }
        }
        drop(rows);
        for chat in v1.mesh_book_ids(id) {
            state.mark_remote(id, &chat);
        }
    }
    if !gone.is_empty() {
        let mut refused = state.refused.lock().unwrap_or_else(|e| e.into_inner());
        for id in gone {
            refused.forget(id);
        }
        state.refused_any.store(!refused.is_empty(), Ordering::Release);
    }
    overflow
}
