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
//! A burst is dials that wait on each other: a dial counts in its burst from when it enters until
//! it ends (or gives its slot back). Dials one after another, each done before the next (a Mac
//! adding machines in a row, one link redialing), are never a burst, however many come in a
//! second. Counting every dial that entered within [`BURST`], done or not, held the 7th quick
//! connect in a row back for up to the whole [`SPREAD`]: every 7th 157 ms cold connect took
//! 0.3 to 1.6 s (`peer_cold_connect_bench.rs`, 2026-11-24).
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
/// Dials entering within this of a burst's first, while its earlier dials have not ended, are the
/// same burst.
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
    /// Dials that waited on the gate (spread, or no free slot), since start.
    waited: AtomicU64,
}

#[derive(Default)]
struct Burst {
    since: Option<Instant>,
    /// Dials of this burst that entered and have not ended.
    entered: usize,
    /// Which burst this is, so a dial of an earlier one that ends does not count down this one.
    epoch: u64,
}

/// A dial's place in its burst, held until the dial ends: dropped, it no longer counts.
struct Entered {
    slots: Arc<Slots>,
    epoch: u64,
}

impl Drop for Entered {
    fn drop(&mut self) {
        let mut burst = self.slots.burst.lock().unwrap_or_else(PoisonError::into_inner);
        if burst.epoch == self.epoch {
            burst.entered = burst.entered.saturating_sub(1);
        }
    }
}

impl DialGate {
    pub fn new(slots: usize, spread: Duration, hold: Duration) -> Self {
        let slots = slots.max(1);
        Self {
            slots: Arc::new(Slots {
                waiting: Mutex::new(Waiting { free: slots, ..Waiting::default() }),
                burst: Mutex::default(),
            }),
            size: slots,
            spread,
            hold,
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

    /// Wait for this dial's turn: at once while the burst (the dials that entered within
    /// [`BURST`] of its first and have not ended) is within the slots, else (unless a
    /// client waits on the peer, `wanted`) after a start drawn in the spread with `jitter` (in
    /// `0.0..1.0`); then for a free slot, which the dial holds until it drops it. A wanted dial
    /// skips the spread, so it queues for a slot ahead of the burst's spread ones.
    pub async fn enter(&self, wanted: bool, jitter: f64) -> Option<Slot> {
        let now = Instant::now();
        let (place, entered) = {
            let mut burst = self.slots.burst.lock().unwrap_or_else(PoisonError::into_inner);
            if burst.since.is_none_or(|since| now.saturating_duration_since(since) >= BURST) {
                *burst = Burst { since: Some(now), entered: 0, epoch: burst.epoch + 1 };
            }
            burst.entered += 1;
            (burst.entered, Entered { slots: self.slots.clone(), epoch: burst.epoch })
        };
        let spread = place > self.size && !wanted;
        if !spread && let Some(slot) = Slots::try_take(&self.slots) {
            return Some(slot.entered(entered));
        }
        self.waited.fetch_add(1, Ordering::Relaxed);
        if spread {
            tokio::time::sleep(self.spread.mul_f64(jitter.clamp(0.0, 1.0))).await;
        }
        Slots::take(&self.slots, wanted).await.map(|slot| slot.entered(entered))
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
    burst: Mutex<Burst>,
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
    /// The dial's place in its burst, given up with the slot.
    entered: Option<Entered>,
}

impl Slot {
    fn new(slots: &Arc<Slots>) -> Self {
        Self { slots: Some(slots.clone()), entered: None }
    }

    fn entered(mut self, entered: Entered) -> Self {
        self.entered = Some(entered);
        self
    }
}

impl Drop for Slot {
    fn drop(&mut self) {
        // Out of the burst first: the dial that takes this slot next may enter one at once.
        drop(self.entered.take());
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
        Some(Slot::new(slots))
    }

    /// A free slot now, else the next one given back that no wanted dial (or, for a wanted
    /// one, no earlier wanted dial) waits on. `None` only if the gate itself is gone.
    async fn take(slots: &Arc<Self>, wanted: bool) -> Option<Slot> {
        let handed = {
            let mut waiting = slots.lock();
            if waiting.free > 0 {
                waiting.free -= 1;
                return Some(Slot::new(slots));
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
            match next.send(Slot::new(slots)) {
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
