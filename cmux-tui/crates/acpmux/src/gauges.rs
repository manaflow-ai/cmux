//! What `daemon status` says about the daemon's own cost (`gauges` in `_acpmux/status`): how long
//! each startup phase took and its resident memory, with the bytes queued for each connection
//! (`server/queue_gauge.rs`) beside them. No whole session list is built any more (a list reply
//! costs its page or its changes, `hub/row_log.rs`), so none is counted.
//!
//! On 2026-11-12 a daemon on Leo's Mac grew to 11 GB within 15 minutes of its start, took 93 s
//! from socket-ready to "agents may spawn", and nothing it answered said which phase or which
//! queue held the time or the memory (rework finding E3, `docs/design/acpmux-otp-rework.md`).
//! Every gauge here is a few atomics or a short lock that no request holds, so `daemon status`
//! reads them even while startup runs.

use serde_json::{Value, json};
use std::sync::atomic::{AtomicU32, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Mutex, OnceLock, PoisonError};
use std::time::{Duration, Instant};

/// The daemon's gauges: one per process, as a daemon is.
pub fn global() -> &'static Gauges {
    static GAUGES: OnceLock<Gauges> = OnceLock::new();
    GAUGES.get_or_init(Gauges::new)
}

/// The most startup phases kept: a daemon has about 15; a test process starts many hubs.
const PHASES: usize = 64;

pub struct Gauges {
    /// The first touch: `daemon::run` reads [`global`] first, so this is the daemon's start.
    born: Instant,
    phases: Mutex<Vec<Phase>>,
}

#[derive(Clone)]
struct Phase {
    name: &'static str,
    /// Milliseconds from [`Gauges::born`] to its start.
    at_ms: u64,
    /// Its length; None while it runs. A mark is a phase of 0 ms.
    ms: Option<u64>,
}

/// A running phase: its length is recorded when this drops.
pub struct PhaseGuard {
    gauges: &'static Gauges,
    index: usize,
    started: Instant,
}

impl Drop for PhaseGuard {
    fn drop(&mut self) {
        let ms = millis(self.started.elapsed());
        let mut phases = self.gauges.phases.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(phase) = phases.get_mut(self.index) {
            phase.ms = Some(ms);
        }
    }
}

fn millis(d: Duration) -> u64 {
    u64::try_from(d.as_millis()).unwrap_or(u64::MAX)
}

impl Gauges {
    fn new() -> Self {
        Self { born: Instant::now(), phases: Mutex::default() }
    }

    /// A startup phase begins now; it ends when the guard drops.
    pub fn phase(&'static self, name: &'static str) -> PhaseGuard {
        let started = Instant::now();
        let mut phases = self.phases.lock().unwrap_or_else(PoisonError::into_inner);
        if phases.len() >= PHASES {
            return PhaseGuard { gauges: self, index: usize::MAX, started };
        }
        phases.push(Phase { name, at_ms: millis(started - self.born), ms: None });
        PhaseGuard { gauges: self, index: phases.len() - 1, started }
    }

    /// A point in startup (`socket ready`, `first list reply`), kept the first time only.
    pub fn mark(&self, name: &'static str) {
        let mut phases = self.phases.lock().unwrap_or_else(PoisonError::into_inner);
        if phases.len() >= PHASES || phases.iter().any(|p| p.name == name) {
            return;
        }
        phases.push(Phase { name, at_ms: millis(self.born.elapsed()), ms: Some(0) });
    }

    /// `gauges` in `_acpmux/status`, but for the connections' queues, which the server adds.
    pub fn status(&self) -> Value {
        let phases: Vec<Value> = {
            let phases = self.phases.lock().unwrap_or_else(PoisonError::into_inner);
            phases.iter().map(|p| json!({"name": p.name, "atMs": p.at_ms, "ms": p.ms})).collect()
        };
        json!({
            "uptimeMs": millis(self.born.elapsed()),
            "startup": phases,
            "memory": memory(),
            "peerLists": peer_lists().status(),
            "attach": attach_latency().status(),
            "fanout": fanout_status(),
        })
    }
}

/// Peers' lists (whole, or a follow's patch) a link handed the hub's one notice loop that it has
/// not taken yet: counted by the link that sends one (`peer_runtime_io.rs`) and by the loop that
/// takes it (`hub/peer_grace.rs`). The hub's notice channel is bounded by notices, not bytes, so a
/// loop slower than the lists coming in holds every one of them.
pub fn peer_lists() -> &'static PeerLists {
    static LISTS: OnceLock<PeerLists> = OnceLock::new();
    LISTS.get_or_init(PeerLists::default)
}

#[derive(Default)]
pub struct PeerLists {
    lists: AtomicU64,
    bytes: AtomicU64,
    peak_lists: AtomicU64,
    peak_bytes: AtomicU64,
}

impl PeerLists {
    /// A list of `bytes` of row text is on its way into the queue.
    pub fn queued(&self, bytes: u64) {
        let lists = self.lists.fetch_add(1, Ordering::Relaxed) + 1;
        let bytes = self.bytes.fetch_add(bytes, Ordering::Relaxed) + bytes;
        self.peak_lists.fetch_max(lists, Ordering::Relaxed);
        self.peak_bytes.fetch_max(bytes, Ordering::Relaxed);
    }

    /// The loop took a list of `bytes`. Saturating: a test may send a list no link counted.
    pub fn taken(&self, bytes: u64) {
        let less = |by: u64| move |v: u64| Some(v.saturating_sub(by));
        let _ = self.lists.fetch_update(Ordering::Relaxed, Ordering::Relaxed, less(1));
        let _ = self.bytes.fetch_update(Ordering::Relaxed, Ordering::Relaxed, less(bytes));
    }

    fn status(&self) -> Value {
        json!({
            "lists": self.lists.load(Ordering::Relaxed),
            "bytes": self.bytes.load(Ordering::Relaxed),
            "peakLists": self.peak_lists.load(Ordering::Relaxed),
            "peakBytes": self.peak_bytes.load(Ordering::Relaxed),
        })
    }
}

/// How many recent samples a [`Latencies`] ring keeps.
pub const LATENCY_RING: usize = 1024;

/// The last [`LATENCY_RING`] latencies of one kind, in microseconds: a fixed ring of atomics, so
/// a sample is one `fetch_add` and one store (no lock, no allocation) and `daemon status` reads
/// it while samples land. A read racing a store may see that one slot's old or new value.
///
/// Leo, 2026-11-19: "a couple thousand f***ing sessions across VMs talking to [the hub machine]": these
/// rings say whether opening a chat and fanning a chat's change out stay flat as sessions and
/// connections grow (`gauges.attach`, `gauges.fanout`).
pub struct Latencies {
    samples: [AtomicU32; LATENCY_RING],
    /// Every sample taken; the next slot is this modulo the ring.
    taken: AtomicU64,
}

impl Default for Latencies {
    fn default() -> Self {
        Self { samples: std::array::from_fn(|_| AtomicU32::new(0)), taken: AtomicU64::new(0) }
    }
}

impl Latencies {
    pub fn record(&self, took: Duration) {
        let micros = u32::try_from(took.as_micros()).unwrap_or(u32::MAX);
        let slot = self.taken.fetch_add(1, Ordering::Relaxed) % LATENCY_RING as u64;
        if let Some(sample) = self.samples.get(slot as usize) {
            sample.store(micros, Ordering::Relaxed);
        }
    }

    /// `{count, window, p50Ms, p95Ms, maxMs}`: `count` is every sample taken, `window` how many
    /// of the latest the quantiles cover (at most [`LATENCY_RING`]); the quantiles are
    /// nearest-rank over that window, null before the first sample.
    pub fn status(&self) -> Value {
        let taken = self.taken.load(Ordering::Relaxed);
        let window = usize::try_from(taken).unwrap_or(usize::MAX).min(LATENCY_RING);
        let mut sorted = [0u32; LATENCY_RING];
        for (to, from) in sorted.iter_mut().zip(&self.samples).take(window) {
            *to = from.load(Ordering::Relaxed);
        }
        let sorted = sorted.get_mut(..window).unwrap_or_default();
        sorted.sort_unstable();
        let ms = |micros: u32| f64::from(micros) / 1000.0;
        let rank = |q: f64| -> Option<f64> {
            let n = sorted.len();
            let at = ((q * n as f64).ceil() as usize).clamp(1, n.max(1)) - 1;
            sorted.get(at).map(|&m| ms(m))
        };
        json!({
            "count": taken,
            "window": window,
            "p50Ms": rank(0.50),
            "p95Ms": rank(0.95),
            "maxMs": sorted.last().map(|&m| ms(m)),
        })
    }
}

/// `gauges.attach`: a client opening a chat (`_acpmux/attach`, `session/load`, this daemon's or
/// a peer's chat through its link), from its request read to its reply queued on the connection
/// (`server::serve_connection_from`).
pub fn attach_latency() -> &'static Latencies {
    static RING: OnceLock<Latencies> = OnceLock::new();
    RING.get_or_init(Latencies::default)
}

/// A request that opens a chat's view, timed in [`attach_latency`].
pub fn opens_a_chat(method: &str) -> bool {
    matches!(method, crate::rpc::method::MUX_ATTACH | crate::rpc::method::SESSION_LOAD)
}

/// `gauges.fanout`: one hub event (a chat's update, a row change), from its send to the last
/// connection's fan-out task queuing what it owes for it ([`FanoutClock`]).
pub fn fanout_latency() -> &'static Latencies {
    static RING: OnceLock<Latencies> = OnceLock::new();
    RING.get_or_init(Latencies::default)
}

/// Hub events a connection's fan-out task lagged past (the broadcast channel dropped them for
/// it) and how many times one lagged, each followed by a resync: what the latency leaves out.
static FANOUT_DROPPED: AtomicU64 = AtomicU64::new(0);
static FANOUT_RESYNCS: AtomicU64 = AtomicU64::new(0);

/// A connection's fan-out task lagged past `events` hub events: it never queues them, so none
/// of them is a latency sample; each counts in `gauges.fanout.dropped`.
pub fn fanout_lagged(events: u64) {
    FANOUT_DROPPED.fetch_add(events, Ordering::Relaxed);
    FANOUT_RESYNCS.fetch_add(1, Ordering::Relaxed);
}

/// `gauges.fanout`: the latency ring's fields, with `dropped` (events a connection lagged past,
/// summed over connections) and `resyncs` (times a connection lagged).
fn fanout_status() -> Value {
    let mut status = fanout_latency().status();
    if let Some(fields) = status.as_object_mut() {
        fields.insert("dropped".into(), json!(FANOUT_DROPPED.load(Ordering::Relaxed)));
        fields.insert("resyncs".into(), json!(FANOUT_RESYNCS.load(Ordering::Relaxed)));
    }
    status
}

/// One hub event's fan-out: when it was sent and how many connections' fan-out tasks have yet to
/// take it. It lives in the event's shared cells (`HubEvent::row`), so it costs no allocation of
/// its own. The last task to take it records the time since the send in [`fanout_latency`]. An
/// event a task lagged past, or whose connection closed before taking it, is no sample.
#[derive(Debug, Default)]
pub struct FanoutClock {
    /// Nanoseconds from the gauges' birth to the send, at least 1; 0 until sent.
    sent_ns: AtomicU64,
    left: AtomicUsize,
}

impl FanoutClock {
    /// The event goes to `connections` fan-out tasks now.
    pub fn arm(&self, connections: usize) {
        let since = u64::try_from(global().born.elapsed().as_nanos()).unwrap_or(u64::MAX);
        self.sent_ns.store(since.max(1), Ordering::Relaxed);
        self.left.store(connections, Ordering::Release);
    }

    /// One connection's fan-out task queued the event; the last one records the sample.
    pub fn taken(&self) {
        self.taken_into(fanout_latency());
    }

    /// Connections' fan-out tasks yet to take the event.
    #[cfg(test)]
    pub fn owed(&self) -> usize {
        self.left.load(Ordering::Acquire)
    }

    #[cfg(test)]
    pub fn sent(&self) -> bool {
        self.sent_ns.load(Ordering::Relaxed) > 0
    }

    fn taken_into(&self, ring: &Latencies) {
        let less = |left: usize| left.checked_sub(1);
        if self.left.fetch_update(Ordering::AcqRel, Ordering::Acquire, less) == Ok(1) {
            let sent = Duration::from_nanos(self.sent_ns.load(Ordering::Relaxed));
            if !sent.is_zero() {
                ring.record(global().born.elapsed().saturating_sub(sent));
            }
        }
    }
}

/// `gauges` in `_acpmux/status`: [`Gauges::status`] with each connection's queue.
pub fn daemon_status() -> Value {
    let mut status = global().status();
    if let Some(fields) = status.as_object_mut() {
        fields.insert("queues".into(), crate::server::queue_gauge::status());
    }
    status
}

/// This process's resident bytes now and at its peak; null where unknown.
pub fn memory() -> Value {
    json!({"rssBytes": rss_bytes(), "peakRssBytes": peak_rss_bytes()})
}

#[cfg(target_os = "linux")]
fn rss_bytes() -> Option<u64> {
    let status = std::fs::read_to_string("/proc/self/status").ok()?;
    let line = status.lines().find(|l| l.starts_with("VmRSS:"))?;
    let kib: u64 = line.split_whitespace().nth(1)?.parse().ok()?;
    Some(kib * 1024)
}

#[cfg(target_os = "macos")]
fn rss_bytes() -> Option<u64> {
    // SAFETY: proc_taskinfo is plain integers; proc_pidinfo fills at most `size` bytes of it.
    let mut info: libc::proc_taskinfo = unsafe { std::mem::zeroed() };
    let size = std::mem::size_of::<libc::proc_taskinfo>() as libc::c_int;
    // SAFETY: the pointer is to a live local of `size` bytes.
    let got = unsafe {
        libc::proc_pidinfo(
            std::process::id() as libc::c_int,
            libc::PROC_PIDTASKINFO,
            0,
            (&mut info as *mut libc::proc_taskinfo).cast(),
            size,
        )
    };
    (got == size).then_some(info.pti_resident_size)
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
fn rss_bytes() -> Option<u64> {
    None
}

#[cfg(unix)]
fn peak_rss_bytes() -> Option<u64> {
    // SAFETY: rusage is plain integers, for which all zeroes is a valid value.
    let mut usage: libc::rusage = unsafe { std::mem::zeroed() };
    // SAFETY: the pointer is to a live local that getrusage fills in.
    if unsafe { libc::getrusage(libc::RUSAGE_SELF, &mut usage) } != 0 {
        return None;
    }
    // KiB on Linux, bytes on macOS.
    let unit = if cfg!(target_os = "macos") { 1 } else { 1024 };
    u64::try_from(usage.ru_maxrss).ok().map(|v| v * unit)
}

#[cfg(not(unix))]
fn peak_rss_bytes() -> Option<u64> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_phase_reports_its_length_and_a_mark_only_its_first_time() {
        let gauges: &'static Gauges = Box::leak(Box::new(Gauges::new()));
        {
            let _phase = gauges.phase("store load");
            std::thread::sleep(Duration::from_millis(5));
        }
        gauges.mark("socket ready");
        gauges.mark("socket ready");
        let status = gauges.status();
        let phases = status["startup"].as_array().unwrap();
        assert_eq!(phases.len(), 2, "{status}");
        assert_eq!(phases[0]["name"], "store load");
        assert!(phases[0]["ms"].as_u64().unwrap() >= 5, "{status}");
        assert_eq!(phases[1]["name"], "socket ready");
        assert_eq!(phases[1]["ms"], 0);
        #[cfg(any(target_os = "linux", target_os = "macos"))]
        assert!(status["memory"]["rssBytes"].as_u64().unwrap() > 0, "{status}");
        assert!(status["attach"].get("p95Ms").is_some(), "{status}");
        assert!(status["fanout"].get("p95Ms").is_some(), "{status}");
    }

    #[test]
    fn a_lag_counts_its_events_as_dropped_and_one_resync() {
        let before = fanout_status();
        fanout_lagged(7);
        let after = fanout_status();
        let grew = |field: &str| after[field].as_u64().unwrap() - before[field].as_u64().unwrap();
        // Other tests in this process may lag too: at least this one's.
        assert!(grew("dropped") >= 7, "{before} {after}");
        assert!(grew("resyncs") >= 1, "{before} {after}");
    }

    #[test]
    fn an_empty_ring_reports_no_quantiles() {
        let status = Latencies::default().status();
        let none = json!({"count": 0, "window": 0, "p50Ms": null, "p95Ms": null, "maxMs": null});
        assert_eq!(status, none);
    }

    #[test]
    fn the_ring_reports_nearest_rank_quantiles_of_its_window() {
        let ring = Latencies::default();
        // 1..=100 ms, shuffled by a stride coprime to 100.
        for i in 0..100u64 {
            ring.record(Duration::from_millis((i * 37) % 100 + 1));
        }
        let status = ring.status();
        assert_eq!(status["count"], 100);
        assert_eq!(status["window"], 100);
        assert_eq!(status["p50Ms"], 50.0);
        assert_eq!(status["p95Ms"], 95.0);
        assert_eq!(status["maxMs"], 100.0);
    }

    #[test]
    fn the_ring_keeps_only_its_last_samples() {
        let ring = Latencies::default();
        // A slow start the ring has since overwritten, then a whole ring of 2 ms.
        for _ in 0..10 {
            ring.record(Duration::from_secs(9));
        }
        for _ in 0..LATENCY_RING {
            ring.record(Duration::from_millis(2));
        }
        let status = ring.status();
        assert_eq!(status["count"], (LATENCY_RING + 10) as u64);
        assert_eq!(status["window"], LATENCY_RING);
        assert_eq!(status["p95Ms"], 2.0);
        assert_eq!(status["maxMs"], 2.0);
    }

    #[test]
    fn a_sample_is_whole_microseconds_and_saturates() {
        let ring = Latencies::default();
        ring.record(Duration::from_micros(1500));
        assert_eq!(ring.status()["p50Ms"], 1.5);
        ring.record(Duration::from_secs(u64::MAX / 4));
        assert_eq!(ring.status()["maxMs"], f64::from(u32::MAX) / 1000.0);
    }

    #[test]
    fn a_fanout_records_once_when_its_last_connection_takes_it() {
        let ring = Latencies::default();
        let clock = FanoutClock::default();
        clock.arm(3);
        clock.taken_into(&ring);
        clock.taken_into(&ring);
        assert_eq!(ring.status()["count"], 0);
        clock.taken_into(&ring);
        assert_eq!(ring.status()["count"], 1);
        // A task that subscribed after the send takes it too: no second sample, no wrap.
        clock.taken_into(&ring);
        assert_eq!(ring.status()["count"], 1);
        // An event built but never sent records nothing.
        FanoutClock::default().taken_into(&ring);
        assert_eq!(ring.status()["count"], 1);
    }
}
