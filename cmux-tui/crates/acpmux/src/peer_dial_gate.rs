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

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock, PoisonError};
use std::time::Duration;
use tokio::sync::{OwnedSemaphorePermit, Semaphore};
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
    slots: Arc<Semaphore>,
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
            slots: Arc::new(Semaphore::new(slots)),
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
    pub async fn enter(&self, wanted: bool, jitter: f64) -> Option<OwnedSemaphorePermit> {
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
        match self.slots.clone().try_acquire_owned() {
            Ok(permit) if !spread => return Some(permit),
            other => drop(other),
        }
        self.waited.fetch_add(1, Ordering::Relaxed);
        if spread {
            tokio::time::sleep(self.spread.mul_f64(jitter.clamp(0.0, 1.0))).await;
        }
        // The semaphore is never closed; were it, the dial goes without a slot.
        self.slots.clone().acquire_owned().await.ok()
    }

    /// Dials holding a slot now.
    pub fn in_flight(&self) -> usize {
        self.size.saturating_sub(self.slots.available_permits())
    }

    /// Dials that waited on the gate since start.
    pub fn waited(&self) -> u64 {
        self.waited.load(Ordering::Relaxed)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::AtomicUsize;

    fn gate() -> Arc<DialGate> {
        Arc::new(DialGate::new(3, Duration::from_millis(1500), Duration::from_secs(2)))
    }

    #[tokio::test(start_paused = true)]
    async fn a_single_dial_goes_at_once() {
        let gate = gate();
        let started = Instant::now();
        let slot = gate.enter(false, 0.9).await;
        assert!(slot.is_some());
        assert_eq!(started.elapsed(), Duration::ZERO);
        assert_eq!(gate.in_flight(), 1);
        drop(slot);
        assert_eq!(gate.in_flight(), 0);
        assert_eq!(gate.waited(), 0);
    }

    /// 40 links dropped together: no more than the slots dial at once, the rest start spread
    /// over the window, and every one dials.
    #[tokio::test(start_paused = true)]
    async fn forty_dials_at_once_go_a_few_at_a_time_and_all_go() {
        let gate = gate();
        let t0 = Instant::now();
        let dialing = Arc::new(AtomicUsize::new(0));
        let most = Arc::new(AtomicUsize::new(0));
        let starts = Arc::new(Mutex::new(Vec::new()));
        let mut dials = Vec::new();
        for i in 0..40u32 {
            let (gate, dialing, most, starts) =
                (gate.clone(), dialing.clone(), most.clone(), starts.clone());
            dials.push(tokio::spawn(async move {
                gate.pass(false, f64::from(i) / 40.0, async {
                    let now = dialing.fetch_add(1, Ordering::SeqCst) + 1;
                    most.fetch_max(now, Ordering::SeqCst);
                    starts.lock().unwrap().push(t0.elapsed());
                    // A dial that opens in 50 ms.
                    tokio::time::sleep(Duration::from_millis(50)).await;
                    dialing.fetch_sub(1, Ordering::SeqCst);
                })
                .await;
            }));
        }
        for dial in dials {
            dial.await.unwrap();
        }
        let starts = starts.lock().unwrap().clone();
        assert_eq!(starts.len(), 40);
        assert!(most.load(Ordering::SeqCst) <= 3, "{}", most.load(Ordering::SeqCst));
        let at_once = starts.iter().filter(|s| s.is_zero()).count();
        assert_eq!(at_once, 3, "{starts:?}");
        let last = starts.iter().max().unwrap();
        assert!(*last < Duration::from_secs(3), "{starts:?}");
        assert_eq!(gate.waited(), 37);
    }

    /// A peer a client waits on skips the spread: it dials before the burst's spread ones.
    #[tokio::test(start_paused = true)]
    async fn a_wanted_dial_goes_before_the_spread_ones() {
        let gate = gate();
        let held: Vec<_> = futures::future::join_all((0..3).map(|_| gate.enter(false, 0.0))).await;
        let order = Arc::new(Mutex::new(Vec::new()));
        let spread = {
            let (gate, order) = (gate.clone(), order.clone());
            tokio::spawn(async move {
                gate.pass(false, 0.5, async { order.lock().unwrap().push("spread") }).await;
            })
        };
        let wanted = {
            let (gate, order) = (gate.clone(), order.clone());
            tokio::spawn(async move {
                gate.pass(true, 0.5, async { order.lock().unwrap().push("wanted") }).await;
            })
        };
        tokio::task::yield_now().await;
        drop(held);
        spread.await.unwrap();
        wanted.await.unwrap();
        assert_eq!(*order.lock().unwrap(), vec!["wanted", "spread"]);
    }

    /// A dial that hangs gives its slot back after the hold, and still runs to its end.
    #[tokio::test(start_paused = true)]
    async fn a_hung_dial_frees_its_slot_after_the_hold() {
        let gate = gate();
        let hung: Vec<_> = (0..3)
            .map(|_| {
                let gate = gate.clone();
                tokio::spawn(async move {
                    gate.pass(false, 0.0, tokio::time::sleep(Duration::from_secs(30))).await;
                })
            })
            .collect();
        tokio::task::yield_now().await;
        assert_eq!(gate.in_flight(), 3);
        let started = Instant::now();
        gate.pass(true, 0.0, async {}).await;
        assert_eq!(started.elapsed(), Duration::from_secs(2));
        for dial in hung {
            dial.await.unwrap();
        }
        assert_eq!(gate.in_flight(), 0);
    }

    /// A burst ends: a dial a while later is one link dropping on its own, and goes at once.
    #[tokio::test(start_paused = true)]
    async fn a_dial_after_the_burst_goes_at_once() {
        let gate = gate();
        for _ in 0..10 {
            drop(gate.enter(false, 0.0).await);
        }
        tokio::time::sleep(BURST).await;
        let started = Instant::now();
        drop(gate.enter(false, 0.9).await);
        assert_eq!(started.elapsed(), Duration::ZERO);
    }
}
