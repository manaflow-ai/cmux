//! A short reconnect keeps last-known rows intact. The link itself still reports
//! failure immediately, so forwarding to a dead peer retains its fast refusal.
use super::*;
use crate::peer::PeerNotice;
use tokio::time::{Duration, Instant};

const DROP_GRACE: Duration = Duration::from_secs(10);

/// The row deadline of each peer instance's pending outage. Failed retries never
/// extend or re-arm it. A row, list, ready or restart notice ends it; removal or
/// replacement invalidates its generation. Every entry goes at its deadline, so the
/// map never outgrows the peers that dropped in the last `DROP_GRACE`. An outage past
/// its deadline is `Peer::outage_ended`, which goes with its instance.
type Outages = HashMap<(String, u64), Instant>;

impl Hub {
    pub(super) fn note_peer_drop(&self, peer: &str, generation: u64, reason: &str) {
        // Purge fencing and transcript persistence belong to the real link
        // boundary, never to its later row deadline (a new handshake may be busy).
        {
            let _rows = self.remote_sessions.lock().unwrap();
            let Some(current) = self.peer(peer).filter(|p| p.generation == generation) else {
                return;
            };
            let link = current.link();
            if link.attempts <= 1 {
                tracing::warn!(peer, "peer disconnected: {reason}");
            } else {
                tracing::debug!(peer, attempts = link.attempts, "peer still unreachable: {reason}");
            }
            self.with_tombstones(peer, generation, |t| t.link_ended());
        }
        self.peer_snapshots.flush(Some(peer));
    }

    pub(super) async fn peer_notice_loop(self: Arc<Self>) {
        let Some(mut rx) = self.peer_notices_rx.lock().await.take() else { return };
        // A dedicated persistent signal: hub.shutdown's stored Notify permit
        // belongs to the main daemon, including before its waiter registers.
        let mut stop = self.peer_notices_stop.subscribe();
        let mut drops = Outages::new();
        loop {
            if *stop.borrow() {
                break;
            }
            let deadline = drops.values().copied().min();
            let wait = async {
                match deadline {
                    Some(at) => tokio::time::sleep_until(at).await,
                    None => std::future::pending().await,
                }
            };
            let incoming = tokio::select! {
                notice = rx.recv() => notice,
                () = wait => {
                    let now = Instant::now();
                    let expired: Vec<_> = drops.iter()
                        .filter(|(_, at)| **at <= now)
                        .map(|(key, _)| key.clone()).collect();
                    for (peer, generation) in expired {
                        drops.remove(&(peer.clone(), generation));
                        if let Some(current) = self.peer(&peer).filter(|p| p.generation == generation) {
                            current.outage_ended.store(true, Ordering::SeqCst);
                        }
                        self.mark_peer_unreachable(&peer, generation);
                    }
                    continue;
                }
                // No timer task outlives this loop or daemon shutdown.
                _ = stop.changed() => break,
            };
            let Some((peer, generation, notice)) = incoming else { break };
            let Some(current) = self.peer(&peer).filter(|p| p.generation == generation) else {
                continue;
            };
            let settles = matches!(
                notice,
                PeerNotice::Connected | PeerNotice::Disconnected(_) | PeerNotice::Restarting
            );
            let key = (peer.clone(), generation);
            match notice {
                PeerNotice::Disconnected(reason) => {
                    self.note_peer_drop(&peer, generation, &reason);
                    let ongoing =
                        drops.contains_key(&key) || current.outage_ended.load(Ordering::SeqCst);
                    if !ongoing {
                        drops.insert(key, Instant::now() + DROP_GRACE);
                        // The outage's first drop, by this loop's own record (the
                        // link's attempt count may already be past it): a row change
                        // whose save was throttled reaches disk now, not at the
                        // deadline. The daemon may stop inside the grace window, and
                        // a peer whose rows are all closed changes no row at the deadline.
                        self.save_peer_cache(&peer, generation, true);
                    }
                }
                notice => {
                    // A link that brought rows (or a planned restart, which never
                    // enters the grace path) ends the outage: its next drop starts
                    // a new one, even after this one's rows went unreachable.
                    if !matches!(notice, PeerNotice::Notification { .. }) {
                        drops.remove(&key);
                        current.outage_ended.store(false, Ordering::SeqCst);
                    }
                    self.apply_peer_notice(&peer, generation, notice);
                }
            }
            if settles {
                current.mark_settled();
                self.watches.peer_settled();
            }
        }
    }
}
