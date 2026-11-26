//! Trace only: `CMUX_WG_STALL_TRACE=1` prints each driver's socket, pacer and
//! device state every [`EVERY`] on stderr (`WGTRACE` lines), and a separate
//! thread prints each driver's last pass, so a driver that stopped polling
//! shows as a growing `since_pass_ms`. Off, one cached env read.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use tokio::time::Instant;

pub(crate) const EVERY: Duration = Duration::from_secs(5);

pub(crate) fn enabled() -> bool {
    static ENABLED: OnceLock<bool> = OnceLock::new();
    *ENABLED.get_or_init(|| {
        std::env::var("CMUX_WG_STALL_TRACE").is_ok_and(|value| !value.is_empty() && value != "0")
    })
}

fn epoch() -> std::time::Instant {
    static EPOCH: OnceLock<std::time::Instant> = OnceLock::new();
    *EPOCH.get_or_init(std::time::Instant::now)
}

fn now_ms() -> u64 {
    u64::try_from(epoch().elapsed().as_millis()).unwrap_or(u64::MAX)
}

pub(crate) fn line(label: &str, text: &str) {
    eprintln!("WGTRACE t={:.3} {label} {text}", now_ms() as f64 / 1000.0);
}

#[derive(Default)]
struct Beat {
    passes: AtomicU64,
    last_pass_ms: AtomicU64,
}

static BEATS: Mutex<Vec<(String, Arc<Beat>)>> = Mutex::new(Vec::new());

/// One driver's trace state.
pub(crate) struct Trace {
    label: String,
    beat: Arc<Beat>,
    next_dump: Instant,
    pub(crate) rx_datagrams: u64,
    pub(crate) rx_bytes: u64,
    pub(crate) tx_packets: u64,
    pub(crate) tx_bytes: u64,
    pub(crate) last_rx: Option<Instant>,
    pub(crate) last_tx: Option<Instant>,
    counts: std::collections::BTreeMap<&'static str, u64>,
}

impl Trace {
    pub(crate) fn new(kind: &str) -> Option<Self> {
        if !enabled() {
            return None;
        }
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let label = format!("{kind}#{}", NEXT.fetch_add(1, Ordering::Relaxed));
        let beat = Arc::new(Beat::default());
        {
            let mut beats = BEATS.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            beats.push((label.clone(), Arc::clone(&beat)));
        }
        static WATCHER: OnceLock<()> = OnceLock::new();
        WATCHER.get_or_init(|| {
            let _ = std::thread::Builder::new().name("wg-stall-trace".into()).spawn(|| {
                loop {
                    std::thread::sleep(EVERY);
                    let beats = BEATS.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
                    let now = now_ms();
                    for (label, beat) in beats.iter() {
                        let last = beat.last_pass_ms.load(Ordering::Relaxed);
                        line(
                            label,
                            &format!(
                                "liveness passes={} since_pass_ms={}",
                                beat.passes.load(Ordering::Relaxed),
                                now.saturating_sub(last)
                            ),
                        );
                    }
                }
            });
        });
        line(&label, "start");
        Some(Self {
            label,
            beat,
            next_dump: Instant::now() + EVERY,
            rx_datagrams: 0,
            rx_bytes: 0,
            tx_packets: 0,
            tx_bytes: 0,
            last_rx: None,
            last_tx: None,
            counts: std::collections::BTreeMap::new(),
        })
    }

    pub(crate) fn pass(&self) {
        self.beat.passes.fetch_add(1, Ordering::Relaxed);
        self.beat.last_pass_ms.store(now_ms(), Ordering::Relaxed);
    }

    pub(crate) fn next_dump(&self) -> Instant {
        self.next_dump
    }

    pub(crate) fn received(&mut self, bytes: usize) {
        self.rx_datagrams += 1;
        self.rx_bytes += bytes as u64;
        self.last_rx = Some(Instant::now());
    }

    pub(crate) fn count(&mut self, what: &'static str) {
        *self.counts.entry(what).or_default() += 1;
    }

    pub(crate) fn sent(&mut self, bytes: usize) {
        self.tx_packets += 1;
        self.tx_bytes += bytes as u64;
        self.last_tx = Some(Instant::now());
    }

    /// The lines, once [`EVERY`] has passed; resets the counters.
    pub(crate) fn due(
        &mut self,
        header: impl FnOnce() -> String,
        body: impl FnOnce() -> Vec<String>,
    ) {
        let now = Instant::now();
        if now < self.next_dump {
            return;
        }
        self.next_dump = now + EVERY;
        let ago = |at: Option<Instant>| at.map(|at| now.saturating_duration_since(at).as_millis());
        line(
            &self.label,
            &format!(
                "driver rx_dgrams={} rx_bytes={} tx_pkts={} tx_bytes={} last_rx_ago_ms={:?} last_tx_ago_ms={:?} counts={:?} {}",
                self.rx_datagrams,
                self.rx_bytes,
                self.tx_packets,
                self.tx_bytes,
                ago(self.last_rx),
                ago(self.last_tx),
                self.counts,
                header()
            ),
        );
        for text in body() {
            line(&self.label, &text);
        }
        self.rx_datagrams = 0;
        self.rx_bytes = 0;
        self.tx_packets = 0;
        self.tx_bytes = 0;
        self.counts.clear();
    }
}
