//! Sign-out erases every peer copy, including a leased peer whose connection already ended.
//! The rows writer lock (`RemoteTable::fence`) orders the barrier and clear after every accepted
//! listing/capture. Existing peer instances stay barred even if they reconnect; only a new
//! instance may cache again.

use super::*;

/// The caller holds this home's daemon lock, so there is no concurrent snapshot writer.
pub(crate) fn clear_offline(home: &Path) -> anyhow::Result<()> {
    let mut store = Store::new(disk::root(home), Arc::default());
    store.scan();
    if !store.clear() {
        anyhow::bail!("peer snapshot removal did not complete");
    }
    Ok(())
}

impl PeerSnapshots {
    pub(crate) fn allows(&self, generation: u64) -> bool {
        generation >= self.generation_floor.load(Ordering::Acquire)
    }

    fn begin_clear(&self) -> Option<mpsc::Receiver<bool>> {
        self.generation_floor.store(crate::peer::generation_boundary(), Ordering::Release);
        self.dir.as_ref()?;
        let (done, rx) = mpsc::sync_channel(1);
        let mut dropped = self.dropped();
        // Like shutdown, this control op is bounded by its waiting caller, not the capture
        // queue. Captures saturating that queue must never make a sign-out lose its deletion.
        self.send_unsent(&mut dropped);
        self.send(0, Op::Clear(done));
        Some(rx)
    }
}

impl Store {
    pub(super) fn clear(&mut self) -> bool {
        for key in self.copies.keys().cloned().collect::<Vec<_>>() {
            self.remove(&key);
        }
        self.listed.clear();
        self.full_listed.clear();
        self.barred.clear();
        self.links.clear();
        // A directory that could not be read yet must discard its previous run's copies when
        // it recovers, rather than load them after the successful in-memory deletion.
        self.unread_all = !self.scanned;
        self.write_due(None, When::Last);
        self.scanned && self.dead.is_empty()
    }
}

impl Hub {
    /// Local sign-out hook. The reply confirms disk removal; a refused removal remains queued
    /// for the store's existing retry and is reported as an error rather than success.
    pub fn clear_peer_snapshots(&self) -> Result<Value, RpcError> {
        let reply = {
            let _rows = self.remote_sessions.fence();
            self.peer_snapshots.begin_clear()
        };
        if let Some(reply) = reply
            && blocking(|| reply.recv_timeout(ANSWER_WITHIN)) != Ok(true)
        {
            return Err(RpcError::internal("peer snapshot removal did not complete"));
        }
        Ok(json!({"cleared": true}))
    }
}
