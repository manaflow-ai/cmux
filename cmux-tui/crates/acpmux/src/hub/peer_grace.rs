//! A short reconnect keeps last-known rows intact. The link itself still reports
//! failure immediately, so forwarding to a dead peer retains its fast refusal.
use super::*;
use crate::peer::PeerNotice;
use tokio::time::{Duration, Instant};

pub(super) const DROP_GRACE: Duration = Duration::from_secs(10);

/// The row deadline of each peer instance's pending outage. Failed retries never
/// extend or re-arm it. A row, list, ready or restart notice ends it; removal or
/// replacement invalidates its generation. Every entry goes at its deadline, so the
/// map never outgrows the peers that dropped in the last `DROP_GRACE`. An outage past
/// its deadline is `Peer::outage_ended`, which goes with its instance.
type Outages = HashMap<(String, u64), Instant>;

impl Hub {
    pub(super) async fn wait_peer_notice_loop(&self) {
        if self.peer_notices_finished.load(Ordering::Acquire) {
            return;
        }
        let notified = self.peer_notices_done.notified();
        if self.peer_notices_finished.load(Ordering::Acquire) {
            return;
        }
        // timeout: shutdown joins the loop's cache flush inside its own grace, never forever.
        let _ = tokio::time::timeout(super::shutdown::OWNED_TASKS_CLOSE, notified).await;
    }

    pub(super) fn note_peer_drop(&self, peer: &str, generation: u64, reason: &str) {
        // Purge fencing and transcript persistence belong to the real link
        // boundary, never to its later row deadline (a new handshake may be busy).
        let Some(current) = self.peer(peer).filter(|p| p.generation == generation) else {
            return;
        };
        {
            let _rows = self.remote_sessions.fence();
            let link = current.link();
            if link.attempts <= 1 {
                tracing::warn!(peer, "peer disconnected: {reason}");
            } else {
                tracing::debug!(peer, attempts = link.attempts, "peer still unreachable: {reason}");
            }
            current.purge_tombstones.link_ended();
        }
        self.peer_snapshots.flush(Some(peer));
    }

    /// The cache write a drop owes, outside the rows writer lock. An outage's first drop
    /// writes now, not at the row deadline: a row change whose save was throttled
    /// reaches disk though the daemon may stop inside the grace window, and the
    /// outage's age is kept for a peer that lists no rows or only closed ones. A drop
    /// that parks the next retry (`Link::next_retry_at`) writes its deadline, so a
    /// daemon update during that wait does not probe at once.
    pub(super) fn save_after_drop(&self, peer: &str, generation: u64, outage_starts: bool) {
        let parked = self
            .peer(peer)
            .filter(|p| p.generation == generation)
            .is_some_and(|p| p.link().next_retry_at.is_some());
        if (outage_starts || parked) && self.shutting_down() {
            // The shutdown stopped every peer at once (`begin_shutdown`), so each link drops
            // here together. One durable write per drop held a NIGHTLY handover's dark socket
            // for its whole agents budget with forty peers ("agents did not stop within 1s").
            // Marked dirty instead: the loop's last flush writes them all at once, and the
            // shutdown waits for that flush.
            if let Some(p) = self.peer(peer).filter(|p| p.generation == generation) {
                p.cache_dirty_seq.fetch_add(1, Ordering::SeqCst);
            }
        } else if outage_starts || parked {
            self.save_peer_cache(peer, generation, true);
        }
    }

    /// Takes every peer's notices (`peer_notices`) and hands each to its peer's shard: one
    /// worker per shard applies them in arrival order, so a peer's notices keep their order
    /// while ten peers' bursts run side by side. One loop for all peers took about 42k notices
    /// per fan-out round at 2000 sessions on ten hosts, 100-170 us each: its queue filled and
    /// every chat update waited behind it for seconds (cmux#49864). This task keeps the row
    /// deadlines' timer and the put-off cache saves.
    pub(super) async fn peer_notice_loop(self: Arc<Self>) {
        let Some(mut rx) = self.peer_notices_rx.lock().await.take() else {
            self.peer_notices_finished.store(true, Ordering::Release);
            self.peer_notices_done.notify_waiters();
            return;
        };
        // A dedicated persistent signal: hub.shutdown's stored Notify permit
        // belongs to the main daemon, including before its waiter registers.
        let mut stop = self.peer_notices_stop.subscribe();
        let grace = Arc::new(Grace::default());
        let mut shards = Vec::with_capacity(NOTICE_SHARDS);
        let mut workers = Vec::with_capacity(NOTICE_SHARDS);
        for _ in 0..NOTICE_SHARDS {
            let (tx, shard_rx) = mpsc::channel(SHARD_QUEUE);
            shards.push(tx);
            workers.push(crate::supervise::once(
                "peer notice shard",
                &self.fatal,
                Self::peer_notice_shard(
                    Arc::downgrade(&self),
                    shard_rx,
                    grace.clone(),
                    self.peer_notices_stop.subscribe(),
                ),
            ));
        }
        // When the put-off cache saves are due: armed by a save put off (`peer_cache_kick`),
        // cleared once nothing is dirty. No timer while no cache waits for a save: an idle daemon
        // used to tick every 30 s with no peer at all.
        let mut cache_due: Option<tokio::time::Instant> = None;
        loop {
            if *stop.borrow() {
                break;
            }
            let rearmed = grace.rearm.notified();
            let deadline = grace.lock().drops.values().copied().min();
            let wait = async {
                match deadline {
                    Some(at) => tokio::time::sleep_until(at).await,
                    None => std::future::pending().await,
                }
            };
            let cache_wait = async {
                match cache_due {
                    Some(at) => tokio::time::sleep_until(at).await,
                    None => std::future::pending().await,
                }
            };
            let work = tokio::select! {
                notice = rx.recv() => match notice {
                    Some((peer, generation, notice)) => Work::Notice(peer, generation, notice),
                    None => break,
                },
                () = rearmed => continue,
                () = wait => {
                    // Each due deadline goes to its peer's shard, behind the notices already
                    // queued there, exactly as the one loop met them. A notice that ends the
                    // outage first takes it out of `firing`, and the expiry then does nothing.
                    let now = Instant::now();
                    let expired: Vec<_> = {
                        let mut state = grace.lock();
                        let keys: Vec<_> = state.drops.iter()
                            .filter(|(_, at)| **at <= now)
                            .map(|(key, _)| key.clone()).collect();
                        for key in &keys {
                            state.drops.remove(key);
                            state.firing.insert(key.clone());
                        }
                        keys
                    };
                    for (peer, generation) in expired {
                        // notice_shard is below NOTICE_SHARDS, the shards' count: always Some.
                        let Some(shard) = shards.get(notice_shard(&peer)) else { continue };
                        tokio::select! {
                            sent = shard.send(Work::Expire(peer, generation)) => if sent.is_err() { break },
                            _ = stop.changed() => break,
                        }
                    }
                    continue;
                }
                // No timer task outlives this loop or daemon shutdown.
                _ = stop.changed() => break,
                () = self.peer_cache_kick.notified() => {
                    if cache_due.is_none() {
                        cache_due = Some(tokio::time::Instant::now() + self.cache_save_every());
                    }
                    continue;
                }
                () = cache_wait => {
                    let dirty: Vec<_> = self.peers.load()
                        .values()
                        .filter(|p| p.cache_is_dirty())
                        .map(|p| (p.name.clone(), p.generation))
                        .collect();
                    for (peer, generation) in &dirty {
                        self.save_peer_cache(peer, *generation, false);
                    }
                    // A save that runs now, failed, or was put off again leaves its peer dirty:
                    // one more round then. Nothing dirty: no timer until the next kick.
                    let still = self.peers.load()
                        .values()
                        .any(|p| p.cache_is_dirty());
                    cache_due = still
                        .then(|| tokio::time::Instant::now() + self.cache_save_every());
                    continue;
                }
            };
            let Work::Notice(peer, ..) = &work else { continue };
            let Some(shard) = shards.get(notice_shard(peer)) else { continue };
            // A full shard holds only the notices behind it here; the other shards keep going.
            tokio::select! {
                sent = shard.send(work) => if sent.is_err() { break },
                _ = stop.changed() => break,
            }
        }
        // The workers stop on the same signal (or on their closed queue); the last cache save
        // waits for them, so no notice lands after it.
        drop(shards);
        for worker in workers {
            let _ = worker.await;
        }
        let dirty: Vec<_> = self
            .peers
            .load()
            .values()
            .filter(|p| p.cache_is_dirty())
            .map(|p| (p.name.clone(), p.generation))
            .collect();
        // Each peer's last save on its own blocking thread, all at once: every save is a few
        // durable commits, and one after another on this task they cost the shutdown one commit
        // round per peer. Each peer's writer lock still orders its own saves.
        let started = std::time::Instant::now();
        let count = dirty.len();
        let saves: Vec<_> = dirty
            .into_iter()
            .map(|(peer, generation)| {
                let hub = self.clone();
                tokio::task::spawn_blocking(move || hub.save_peer_cache(&peer, generation, true))
            })
            .collect();
        for save in saves {
            let _ = save.await;
        }
        if count > 0 {
            tracing::info!(
                "saved the last-known sessions of {count} peers in {:?}",
                started.elapsed()
            );
        }
        self.peer_notices_finished.store(true, Ordering::Release);
        self.peer_notices_done.notify_waiters();
    }

    /// One shard's worker: its peers' notices and row deadlines, in order.
    async fn peer_notice_shard(
        hub: std::sync::Weak<Self>,
        mut rx: mpsc::Receiver<Work>,
        grace: Arc<Grace>,
        mut stop: tokio::sync::watch::Receiver<bool>,
    ) {
        loop {
            if *stop.borrow() {
                break;
            }
            let work = tokio::select! {
                work = rx.recv() => work,
                _ = stop.changed() => break,
            };
            let Some(work) = work else { break };
            // A strong hub only while one item is applied: between items a shard holds none, as
            // the one loop held only its own (the retention test counts the hub's holders).
            let Some(this) = hub.upgrade() else { break };
            let (peer, generation, notice) = match work {
                Work::Expire(peer, generation) => {
                    this.expire_peer_rows(&grace, peer, generation);
                    continue;
                }
                Work::Notice(peer, generation, notice) => (peer, generation, notice),
            };
            let started = Instant::now();
            let queued = rx.len() as u64;
            let label = notice.label();
            if let Some(bytes) = notice.list_bytes() {
                crate::gauges::peer_lists().taken(bytes);
            }
            let Some(current) = this.peer(&peer).filter(|p| p.generation == generation) else {
                continue;
            };
            let settles = matches!(
                notice,
                PeerNotice::Connected | PeerNotice::Disconnected(_) | PeerNotice::Restarting
            );
            let key = (peer.clone(), generation);
            match notice {
                PeerNotice::Disconnected(reason) => {
                    this.note_peer_drop(&peer, generation, &reason);
                    let ongoing = {
                        let mut state = grace.lock();
                        let ongoing = state.drops.contains_key(&key)
                            || state.firing.contains(&key)
                            || current.outage_ended.load(Ordering::SeqCst);
                        if !ongoing {
                            state.drops.insert(key, Instant::now() + DROP_GRACE);
                        }
                        ongoing
                    };
                    if !ongoing {
                        grace.rearm.notify_one();
                        this.events.origin_tee(
                            &peer,
                            super::peers::peer_origin_state(&current),
                            crate::store::now_ms(),
                        );
                    }
                    // The outage's first drop by this loop's own record: the link's
                    // attempt count may already be past it.
                    this.save_after_drop(&peer, generation, !ongoing);
                }
                notice => {
                    // Rows came (a list, a changed row) or the link is up: the peer's chats are
                    // read ahead soon (`peer_snapshot/warm.rs`).
                    let warms = match &notice {
                        PeerNotice::Connected
                        | PeerNotice::Sessions(_)
                        | PeerNotice::SessionsPatch { .. } => true,
                        PeerNotice::SessionChanged { kind, .. } => kind != "purged",
                        _ => false,
                    };
                    // A link that brought rows (or a planned restart, which never
                    // enters the grace path) ends the outage: its next drop starts
                    // a new one, even after this one's rows went unreachable.
                    if !matches!(notice, PeerNotice::Notification { .. }) {
                        {
                            let mut state = grace.lock();
                            state.drops.remove(&key);
                            state.firing.remove(&key);
                        }
                        current.outage_ended.store(false, Ordering::SeqCst);
                    }
                    // The link takes requests: copies ahead of the peer's journals go back
                    // first, and prompts to it wait for that (`peer_snapshot/restore.rs`). Before
                    // the notice, so no message the notice wakes goes ahead of them.
                    if matches!(notice, PeerNotice::Connected) {
                        this.restore_peer_journals(&peer, generation);
                    }
                    this.apply_peer_notice(&peer, generation, notice);
                    if warms {
                        this.warm_peer_copies(&peer);
                    }
                }
            }
            if settles {
                current.mark_settled();
                this.watches.peer_settled();
            }
            crate::gauges::peer_notices().applied(
                label,
                u64::try_from(started.elapsed().as_micros()).unwrap_or(u64::MAX),
                queued,
            );
        }
    }

    /// A peer instance's row deadline came with no notice ending its outage first.
    fn expire_peer_rows(&self, grace: &Grace, peer: String, generation: u64) {
        if !grace.lock().firing.remove(&(peer.clone(), generation)) {
            return;
        }
        let Some(current) = self.peer(&peer).filter(|p| p.generation == generation) else {
            return;
        };
        current.outage_ended.store(true, Ordering::SeqCst);
        self.events.origin_tee(
            &peer,
            super::peers::peer_origin_state(&current),
            crate::store::now_ms(),
        );
        self.mark_peer_unreachable(&peer, generation);
    }
}

/// How many workers apply peer notices. A peer always lands on the same one.
const NOTICE_SHARDS: usize = 16;
/// Each shard's queue; the ingress (`peer_notices`) keeps its own 4096.
const SHARD_QUEUE: usize = 1024;

fn notice_shard(peer: &str) -> usize {
    use std::hash::{BuildHasher, BuildHasherDefault, DefaultHasher};
    // A fixed hasher (no random seed): a peer's shard holds for the daemon's life either way.
    let hash = BuildHasherDefault::<DefaultHasher>::default().hash_one(peer);
    usize::try_from(hash % NOTICE_SHARDS as u64).unwrap_or(0)
}

enum Work {
    Notice(String, u64, PeerNotice),
    /// The timer found this instance's row deadline due (`Grace::firing`).
    Expire(String, u64),
}

/// Row deadlines shared by the timer (the notice loop) and the shards.
#[derive(Default)]
struct Grace {
    state: StdMutex<GraceState>,
    /// A shard added a deadline: the timer takes the new minimum.
    rearm: Notify,
}

#[derive(Default)]
struct GraceState {
    drops: Outages,
    /// Deadlines the timer handed to their shard, not yet applied there.
    firing: HashSet<(String, u64)>,
}

impl Grace {
    fn lock(&self) -> std::sync::MutexGuard<'_, GraceState> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }
}
