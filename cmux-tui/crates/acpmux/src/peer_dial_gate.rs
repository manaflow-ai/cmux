//! One gate for every peer link's dial on this host: a few dials in flight at once, and when
//! many links dial together (one relay cut, or this daemon's own stall dropping every link in
//! the same moment) the rest spread over a short window, peers a client waits on first.
//!
//! Each peer has its own link, ping and backoff (`peer_runtime_io.rs`), and a ready link that
//! dies redials with no wait at all. That is right for one link: an open chat resumes at once.
//! For 40 links dropped together it was 40 dials in the same instant, on a host already at load
//! 150 (Leo's Mac, 2026-11-23). Through the gate the first [`SLOTS`] dials still go at once, so a
//! single dropped link (or a handful) redials exactly as before; past them, a dial a client is
//! not waiting on draws a start in the next [`SPREAD`], and every dial waits for a free slot.
//!
//! A slot is given back when the dial's connection opens or fails, or after [`HOLD`] at most,
//! so a path that hangs (a dead relay) cannot hold the gate shut for its whole connect timeout.
//! A freed slot goes to a waiting wanted dial first, then to the others in the order they came
//! (a FIFO semaphore would hand it to a background dial that only queued earlier).

use std::collections::VecDeque;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock, PoisonError};
use std::time::Duration;
use tokio::sync::oneshot;
use tokio::time::Instant;

/// Dials in flight at once, and dials of one burst that go with no spread.
pub const SLOTS: usize = 6;
/// The window a burst's later dials (not wanted by a client) are spread over.
pub const SPREAD: Duration = Duration::from_millis(1500);
/// The longest one dial holds its slot.
pub const HOLD: Duration = Duration::from_secs(2);
/// Dials entering within this of a burst's first are the same burst.
pub const BURST: Duration = Duration::from_secs(1);

/// The daemon's gate.
pub fn global() -> &'static DialGate {
    static GATE: OnceLock<DialGate> = OnceLock::new();
    GATE.get_or_init(|| DialGate::new(SLOTS, SPREAD, HOLD))
}

pub struct DialGate {
    slots: Arc<Slots>,
    size: usize,
    spread: Duration,
    hold: Duration,
    burst: Mutex<Burst>,
    /// Dials that waited on the gate (spread, or no free slot), since start.
    waited: AtomicU64,
}

#[derive(Default)]
struct Burst {
    since: Option<Instant>,
    entered: usize,
}

impl DialGate {
    pub fn new(slots: usize, spread: Duration, hold: Duration) -> Self {
        let slots = slots.max(1);
        Self {
            slots: Arc::new(Slots {
                waiting: Mutex::new(Waiting { free: slots, ..Waiting::default() }),
            }),
            size: slots,
            spread,
            hold,
            burst: Mutex::default(),
            waited: AtomicU64::new(0),
        }
    }

    /// Run `dial` in its turn ([`Self::enter`]), holding a slot while it runs, for at most
    /// the gate's hold: a dial that hangs keeps running but no longer keeps others waiting.
    pub async fn pass<F: std::future::Future>(
        &self,
        wanted: bool,
        jitter: f64,
        dial: F,
    ) -> F::Output {
        let mut slot = Some(self.enter(wanted, jitter).await);
        let hold = tokio::time::sleep(self.hold);
        tokio::pin!(dial, hold);
        loop {
            tokio::select! {
                out = &mut dial => return out,
                () = &mut hold, if slot.is_some() => slot = None,
            }
        }
    }

    /// Wait for this dial's turn: at once while the burst is within the slots, else (unless a
    /// client waits on the peer, `wanted`) after a start drawn in the spread with `jitter` (in
    /// `0.0..1.0`); then for a free slot, which the dial holds until it drops it. A wanted dial
    /// skips the spread, so it queues for a slot ahead of the burst's spread ones.
    pub async fn enter(&self, wanted: bool, jitter: f64) -> Option<Slot> {
        let now = Instant::now();
        let place = {
            let mut burst = self.burst.lock().unwrap_or_else(PoisonError::into_inner);
            if burst.since.is_none_or(|since| now.saturating_duration_since(since) >= BURST) {
                *burst = Burst { since: Some(now), entered: 0 };
            }
            burst.entered += 1;
            burst.entered
        };
        let spread = place > self.size && !wanted;
        if !spread && let Some(slot) = Slots::try_take(&self.slots) {
            return Some(slot);
        }
        self.waited.fetch_add(1, Ordering::Relaxed);
        if spread {
            tokio::time::sleep(self.spread.mul_f64(jitter.clamp(0.0, 1.0))).await;
        }
        Slots::take(&self.slots, wanted).await
    }

    /// Dials holding a slot now.
    pub fn in_flight(&self) -> usize {
        self.size.saturating_sub(self.slots.lock().free)
    }

    /// Dials that waited on the gate since start.
    pub fn waited(&self) -> u64 {
        self.waited.load(Ordering::Relaxed)
    }
}

/// The gate's slots: a count of free ones, and the dials waiting for one, wanted ones apart.
struct Slots {
    waiting: Mutex<Waiting>,
}

#[derive(Default)]
struct Waiting {
    free: usize,
    wanted: VecDeque<oneshot::Sender<Slot>>,
    rest: VecDeque<oneshot::Sender<Slot>>,
}

/// A dial's slot, given back (to the next waiting dial, or to the free count) when dropped.
/// A slot handed to a waiter that was cancelled is dropped with the channel, so it comes back too.
pub struct Slot {
    slots: Option<Arc<Slots>>,
}

impl Drop for Slot {
    fn drop(&mut self) {
        if let Some(slots) = self.slots.take() {
            Slots::give_back(&slots);
        }
    }
}

impl Slots {
    fn lock(&self) -> std::sync::MutexGuard<'_, Waiting> {
        self.waiting.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn try_take(slots: &Arc<Self>) -> Option<Slot> {
        let mut waiting = slots.lock();
        if waiting.free == 0 {
            return None;
        }
        waiting.free -= 1;
        Some(Slot { slots: Some(slots.clone()) })
    }

    /// A free slot now, else the next one given back that no wanted dial (or, for a wanted
    /// one, no earlier wanted dial) waits on. `None` only if the gate itself is gone.
    async fn take(slots: &Arc<Self>, wanted: bool) -> Option<Slot> {
        let handed = {
            let mut waiting = slots.lock();
            if waiting.free > 0 {
                waiting.free -= 1;
                return Some(Slot { slots: Some(slots.clone()) });
            }
            let (tx, rx) = oneshot::channel();
            let queue = if wanted { &mut waiting.wanted } else { &mut waiting.rest };
            queue.retain(|waiter| !waiter.is_closed());
            queue.push_back(tx);
            rx
        };
        handed.await.ok()
    }

    /// Hand a slot to the first live waiter, wanted ones first; with none, it is free.
    fn give_back(slots: &Arc<Self>) {
        loop {
            let next = {
                let mut waiting = slots.lock();
                match waiting.wanted.pop_front().or_else(|| waiting.rest.pop_front()) {
                    Some(next) => next,
                    None => {
                        waiting.free += 1;
                        return;
                    }
                }
            };
            match next.send(Slot { slots: Some(slots.clone()) }) {
                Ok(()) => return,
                // That waiter was cancelled: this slot goes to the next one, not back through drop.
                Err(mut slot) => slot.slots = None,
            }
        }
    }
}

#[cfg(test)]
#[path = "peer_dial_gate_tests.rs"]
mod tests;
