//! A short reconnect keeps last-known rows intact. The link itself still reports
//! failure immediately, so forwarding to a dead peer retains its fast refusal.
use super::*;
use crate::peer::PeerNotice;
use tokio::time::{Duration, Instant};

const DROP_GRACE: Duration = Duration::from_secs(10);

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
        // At most one deadline per peer instance. Retries never extend it. A
        // list/ready notice cancels it; removal/replacement invalidates its generation.
        let mut drops: HashMap<(String, u64), Instant> = HashMap::new();
        loop {
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
                        self.mark_peer_unreachable(&peer, generation);
                    }
                    continue;
                }
                // No timer task outlives this loop or daemon shutdown.
                () = self.shutdown.notified() => break,
            };
            let Some((peer, generation, notice)) = incoming else { break };
            let Some(current) = self.peer(&peer).filter(|p| p.generation == generation) else {
                continue;
            };
            let settles = matches!(notice, PeerNotice::Connected | PeerNotice::Disconnected(_));
            let key = (peer.clone(), generation);
            match notice {
                PeerNotice::Disconnected(reason) => {
                    self.note_peer_drop(&peer, generation, &reason);
                    drops.entry(key).or_insert_with(|| Instant::now() + DROP_GRACE);
                }
                notice => {
                    if matches!(notice, PeerNotice::Connected | PeerNotice::Sessions(_)) {
                        drops.remove(&key);
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
