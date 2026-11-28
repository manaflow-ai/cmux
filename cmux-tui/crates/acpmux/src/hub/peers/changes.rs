//! A peer's changed row (`PeerNotice::SessionChanged`, not a purge) in three steps: built before
//! the rows writer lock ([`Hub::session_change_build`]), put in the table under it
//! ([`Hub::session_change_apply`]), then announced once it is released
//! ([`Hub::session_change_announce`]).
//!
//! A peer notice shard puts a run of changed rows under one taking of the writer lock
//! ([`Hub::apply_session_changes`]). Taken once per row, the lock was the round's serial step:
//! 2000 sessions' turns across a dozen peers were 2000 takings of one mutex by 16 shards, each
//! a copy of the table's touched nodes and a publish, and each one found held handed its worker
//! off (`RemoteTable::fence`). The coordinator drained prompts at ~0.85 ms each, 1.6 s for a
//! round's last reply (sessions-2000-attached, coord-sim fanin `FANIN_PERF_ROLE` profiles:
//! 44k off-CPU samples waiting on that lock under `apply_peer_notice_rows`).

use super::*;
use crate::hub::remote_rows::RemoteRows;

/// A run's bound: one writer hold never covers more rows than this.
pub(in crate::hub) const CHANGES_PER_HOLD: usize = 256;

/// One changed row of a peer, built before the rows writer lock.
pub(in crate::hub) struct SessionChange {
    peer: String,
    generation: u64,
    mux_id: String,
    kind: String,
    seq: u64,
    id: String,
    receipt: Option<SessionReceipt>,
    /// The row as it came, its tools kept from `base`.
    summary: Value,
    /// The row as it came when it took `base`'s tools: one built again starts from it.
    plain: Option<Value>,
    /// The row published when this one was built.
    base: Option<Arc<RemoteSession>>,
    row: PeerRow,
    /// The row the table took, announced once the lock is released; None when it took none.
    announced: Option<PeerRow>,
}

impl SessionChange {
    pub(in crate::hub) fn peer(&self) -> &str {
        &self.peer
    }
}

impl Hub {
    /// A changed row built (its tools kept, its text written) from the row last published,
    /// before the locks: under them only a check that it is still the row there, else built
    /// again from the one there. Built under the locks, every peer's notices waited on each
    /// row's text (a round of 2000 sessions' turns).
    pub(in crate::hub) fn session_change_build(
        &self,
        peer: &str,
        generation: u64,
        mux_id: String,
        session: Value,
        kind: String,
        seq: u64,
    ) -> Option<SessionChange> {
        let summary = Self::remote_summary(peer, session);
        let receipt = session_receipt(&summary)?;
        let id = receipt.qualified_id();
        let base = self.remote_sessions.read().find_mux(peer, &mux_id).map(|(_, r)| Arc::clone(r));
        // The tools a row takes from `base` are not its own: one built again starts from the
        // summary as it came.
        let previous = base.as_ref().map(|r| &r.summary);
        let plain = (summary.get("tools").is_none() && previous.is_some_and(|p| p.has_tools()))
            .then(|| summary.clone());
        let summary = Self::retain_summary_tools(summary, previous);
        let row = PeerRow::new(&summary);
        Some(SessionChange {
            peer: peer.to_owned(),
            generation,
            mux_id,
            kind,
            seq,
            id,
            receipt: Some(receipt),
            summary,
            plain,
            base,
            row,
            announced: None,
        })
    }

    /// Puts a built row in the table, under the rows writer lock (`map` is its copy). False when
    /// its peer instance is gone, and nothing changed.
    pub(in crate::hub) fn session_change_apply(
        &self,
        map: &mut RemoteRows,
        change: &mut SessionChange,
    ) -> bool {
        let Some(current) =
            self.peers.get(&change.peer).filter(|p| p.generation == change.generation)
        else {
            return false;
        };
        let Some(receipt) = change.receipt.take() else { return false };
        current.purge_tombstones.changed(&change.mux_id);
        let old_id = map.find_mux(&change.peer, &change.mux_id).map(|(key, _)| key.clone());
        // Under the same key the row is replaced in place by the insert below
        // (`RemoteRows::insert_shared`), so it is not taken out first.
        let previous = match &old_id {
            Some(key) if *key == change.id => map.get(key).cloned(),
            Some(key) => map.take(key),
            None => None,
        };
        if previous.as_ref().map(Arc::as_ptr) != change.base.as_ref().map(Arc::as_ptr) {
            // A writer came between the check and the lock: built here, as before.
            let came = change.plain.take().unwrap_or_else(|| std::mem::take(&mut change.summary));
            change.summary =
                Self::retain_summary_tools(came, previous.as_ref().map(|r| &r.summary));
            change.row = PeerRow::new(&change.summary);
        }
        let row = std::mem::take(&mut change.row);
        // The table's row and the announcement share its text.
        change.announced = Some(row.clone());
        map.insert(
            change.id.clone(),
            RemoteSession {
                peer: change.peer.clone(),
                // The chart it had stays in the copy kept, never in the notice.
                summary: row.keeping_time_breakdown(previous.as_ref().map(|r| &r.summary)),
                receipt,
            },
        );
        let created = change.summary.get("createdAt").and_then(Value::as_u64);
        if self.peer_snapshots.allows(change.generation) {
            self.peer_snapshots.listed(&change.peer, vec![(change.mux_id.clone(), created)], false);
        }
        current
            .remote_purge_fences
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .remove(&change.mux_id);
        current.remote_rows_epoch.fetch_add(1, std::sync::atomic::Ordering::Release);
        true
    }

    /// What follows a row the table took, once the writer lock is released: its asks, the
    /// peer's cache, the announcement, the closed rows' bound.
    pub(in crate::hub) fn session_change_announce(&self, change: SessionChange) {
        let SessionChange { peer, generation, mux_id, kind, seq, summary, announced, .. } = change;
        let Some(announced) = announced else { return };
        // An ask decided there before the session was listed here never comes back.
        if matches!(kind.as_str(), "permission_decision" | "permission_resolved") {
            self.held_peer_asks.forget(&peer, &mux_id, None);
        }
        self.save_peer_cache(&peer, generation, false);
        let _ = self.events.send_remote(HubEvent {
            session_id: mux_id,
            record: Arc::new(EventRecord {
                seq,
                at: now_ms(),
                dir: "peer".into(),
                kind,
                msg: Value::Null,
                host_seq: None,
            }),
            remote: Some(RemoteRef { peer: peer.clone(), summary: announced }),
            update_line: Default::default(),
            event_params: Default::default(),
            row: Default::default(),
            list_seq: 0,
            peer_batch: false,
        });
        // The rest of its live asks that came before the session was listed, after the row.
        self.release_held_peer_asks(&peer, generation);
        // A row that closed can put the peer's closed rows past the bound.
        if summary.get("status").and_then(Value::as_str) == Some("closed") {
            self.trim_closed_peer_rows(&peer, generation);
        }
    }

    /// The session a notice changes when it can join a run under one writer hold: a change
    /// that is not a purge, to a row that is not closed (a closed row's change is counted
    /// against the closed rows' bound, `peer_closed_bound.rs`, one at a time).
    pub(in crate::hub) fn batchable_change<'n>(
        &self,
        peer: &str,
        notice: &'n crate::peer::PeerNotice,
    ) -> Option<&'n str> {
        let crate::peer::PeerNotice::SessionChanged { session, kind, .. } = notice else {
            return None;
        };
        if kind == "purged" {
            return None;
        }
        let mux = session.get("sessionId").and_then(Value::as_str)?;
        let closed = self
            .remote_sessions
            .read()
            .find_mux(peer, mux)
            .is_some_and(|(_, row)| row.summary.closed());
        (!closed).then_some(mux)
    }

    /// A run of changed rows, each a different session (`batchable_change`), in one taking of
    /// the rows writer lock: each built before it, put in the table under it in the order they
    /// came, and announced after it in that order. The same as applying each alone
    /// (`apply_peer_notice`), but the lock is taken once.
    pub(in crate::hub) fn apply_session_changes(
        &self,
        notices: Vec<(String, u64, crate::peer::PeerNotice)>,
    ) -> Vec<SessionChange> {
        let mut built = Vec::with_capacity(notices.len());
        for (peer, generation, notice) in notices {
            let crate::peer::PeerNotice::SessionChanged { session, kind, seq } = notice else {
                continue;
            };
            let Some(mux_id) = session.get("sessionId").and_then(Value::as_str).map(str::to_owned)
            else {
                continue;
            };
            if let Some(change) =
                self.session_change_build(&peer, generation, mux_id, session, kind, seq)
            {
                built.push(change);
            }
        }
        if built.is_empty() {
            return built;
        }
        {
            #[cfg(test)]
            self.pause_after_peer_session_projection_for_test();
            let mut map = self.remote_sessions.write();
            for change in &mut built {
                self.session_change_apply(&mut map, change);
            }
        }
        built.retain(|c| c.announced.is_some());
        built
    }
}
