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
            "peerNotices": peer_notices().status(),
            "recordWrites": record_writes().status(),
            "attach": attach_latency().status(),
            "fanout": fanout_status(),
            "links": links().status(),
            "workerLag": worker_lag().status(),
        })
    }
}

/// The time chats' records take to be written (`Hub::write_record_locked`): the store's append
/// alone, and the whole write from its sequence number to its event on the hub's channel. Totals
/// only, so a reader takes the difference across a window (the turn bench,
/// `benches/turn_overhead.rs`, reads it around each turn).
pub fn record_writes() -> &'static RecordWrites {
    static WRITES: OnceLock<RecordWrites> = OnceLock::new();
    WRITES.get_or_init(RecordWrites::default)
}

#[derive(Default)]
pub struct RecordWrites {
    records: AtomicU64,
    store_ns: AtomicU64,
    write_ns: AtomicU64,
}

impl RecordWrites {
    /// One record written: `store` in the store's append, `write` in all.
    pub fn note(&self, store: Duration, write: Duration) {
        let nanos = |d: Duration| u64::try_from(d.as_nanos()).unwrap_or(u64::MAX);
        self.records.fetch_add(1, Ordering::Relaxed);
        self.store_ns.fetch_add(nanos(store), Ordering::Relaxed);
        self.write_ns.fetch_add(nanos(write), Ordering::Relaxed);
    }

    fn status(&self) -> Value {
        json!({
            "records": self.records.load(Ordering::Relaxed),
            "storeNs": self.store_ns.load(Ordering::Relaxed),
            "writeNs": self.write_ns.load(Ordering::Relaxed),
        })
    }
}

/// The hub's one notice loop (`hub/peer_grace.rs`): how many notices it applied, the time it
/// spent applying them, the longest one, and the deepest its queue was when it took one. A link
/// holds its notices back on a full queue (`peer_notice_outbox.rs`), so a loop slower than the
/// notices coming in holds back every peer's chat updates behind them.
pub fn peer_notices() -> &'static PeerNotices {
    static NOTICES: OnceLock<PeerNotices> = OnceLock::new();
    NOTICES.get_or_init(PeerNotices::default)
}

#[derive(Default)]
pub struct PeerNotices {
    applied: AtomicU64,
    busy_us: AtomicU64,
    max_us: AtomicU64,
    peak_queued: AtomicU64,
    /// Links' own backlogs while the hub's queue was full (`peer_notice_outbox.rs`): the deepest
    /// one, the changed rows a later change of the same row replaced there, and the times a link
    /// waited because its backlog was full.
    link_peak: AtomicU64,
    link_merged: AtomicU64,
    link_waits: AtomicU64,
    /// Notices by `PeerNotice::label`, at most `KINDS_KEPT` labels: how many, and the µs they took.
    kinds: Mutex<std::collections::BTreeMap<String, (u64, u64)>>,
    /// Peer snapshot copies read back from disk (`peer_snapshot::Store::read_in`).
    pub snapshot_reads: AtomicU64,
    /// Loaded copies unloaded to keep the store's memory bound (`Store::trim_memory`).
    pub snapshot_unloads: AtomicU64,
}

const KINDS_KEPT: usize = 64;

impl PeerNotices {
    /// One notice of `label` took `us` to apply, with `queued` more behind it.
    pub fn applied(&self, label: String, us: u64, queued: u64) {
        let mut kinds = self.kinds.lock().unwrap_or_else(PoisonError::into_inner);
        let full = kinds.len() >= KINDS_KEPT;
        let kind = if kinds.contains_key(&label) || !full {
            kinds.entry(label).or_default()
        } else {
            kinds.entry("other".into()).or_default()
        };
        kind.0 += 1;
        kind.1 += us;
        drop(kinds);
        self.applied.fetch_add(1, Ordering::Relaxed);
        self.busy_us.fetch_add(us, Ordering::Relaxed);
        self.max_us.fetch_max(us, Ordering::Relaxed);
        self.peak_queued.fetch_max(queued, Ordering::Relaxed);
    }

    /// A link held a notice back, `depth` deep, `merged` when it replaced an earlier change.
    pub fn link_held(&self, depth: u64, merged: bool) {
        self.link_peak.fetch_max(depth, Ordering::Relaxed);
        if merged {
            self.link_merged.fetch_add(1, Ordering::Relaxed);
        }
    }

    /// A link waited for room in its full backlog.
    pub fn link_waited(&self) {
        self.link_waits.fetch_add(1, Ordering::Relaxed);
    }

    fn status(&self) -> Value {
        let kinds = self.kinds.lock().unwrap_or_else(PoisonError::into_inner).clone();
        json!({
            "applied": self.applied.load(Ordering::Relaxed),
            "busyMs": self.busy_us.load(Ordering::Relaxed) / 1000,
            "maxUs": self.max_us.load(Ordering::Relaxed),
            "peakQueued": self.peak_queued.load(Ordering::Relaxed),
            "linkPeak": self.link_peak.load(Ordering::Relaxed),
            "linkMerged": self.link_merged.load(Ordering::Relaxed),
            "linkWaits": self.link_waits.load(Ordering::Relaxed),
            "kinds": kinds.iter().map(|(k, (n, _))| (k.clone(), *n)).collect::<std::collections::BTreeMap<_, _>>(),
            "kindsMs": kinds.iter().map(|(k, (_, us))| (k.clone(), us / 1000)).collect::<std::collections::BTreeMap<_, _>>(),
            "snapshotReads": self.snapshot_reads.load(Ordering::Relaxed),
            "snapshotUnloads": self.snapshot_unloads.load(Ordering::Relaxed),
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

/// `gauges.links`: the network connections this daemon holds for its peers, and the dials it
/// started, since its start. Totals count up; the `open` fields count what is held now, each by
/// a [`Held`] that the thing it counts owns, so a link, probe or circuit that ends any way at all
/// gives its count back.
///
/// Leo's Mac at load 89 to 154 held about 40 peer links that went quiet together, dropped and
/// redialed (2026-11-23), and nothing the daemon answered said how many connections or dials
/// that was. These say it, per peer count, for the duress harness (`tests/duress_daemon.rs`).
pub fn links() -> &'static Links {
    static LINKS: OnceLock<Links> = OnceLock::new();
    LINKS.get_or_init(Links::default)
}

#[derive(Default)]
pub struct Links {
    /// Peer links with a connection open (`Peer::connect_once` past its dial).
    pub links_open: AtomicU64,
    /// Path probes with a connection of their own open (`Peer::probe_link`).
    pub probes_open: AtomicU64,
    /// Plain relay circuits (one stream each) carried now, dialed or accepted.
    pub hub_plain_open: AtomicU64,
    /// Kept, multiplexed relay circuits open now (either end), and the streams riding them.
    pub hub_kept_open: AtomicU64,
    pub kept_streams_open: AtomicU64,
    /// Every peer link connect attempt; of those, the ones started at once after a ready link
    /// dropped (no backoff).
    pub link_dials: AtomicU64,
    pub link_redials: AtomicU64,
    /// Every probe dial of a path.
    pub probe_dials: AtomicU64,
    /// Relay circuits this daemon dialed: plain ones, kept ones, and streams opened on a kept one.
    pub hub_plain_dials: AtomicU64,
    pub hub_kept_dials: AtomicU64,
    pub kept_stream_opens: AtomicU64,
}

/// One held thing in a `Links` count: counted up when made, down when dropped.
#[derive(Debug)]
pub struct Held(&'static AtomicU64);

impl Held {
    pub fn on(count: &'static AtomicU64) -> Self {
        count.fetch_add(1, Ordering::Relaxed);
        Self(count)
    }
}

impl Drop for Held {
    fn drop(&mut self) {
        let less = |v: u64| Some(v.saturating_sub(1));
        let _ = self.0.fetch_update(Ordering::Relaxed, Ordering::Relaxed, less);
    }
}

/// Count one more of `count`.
pub fn bump(count: &AtomicU64) {
    count.fetch_add(1, Ordering::Relaxed);
}

impl Links {
    pub fn status(&self) -> Value {
        let n = |c: &AtomicU64| c.load(Ordering::Relaxed);
        json!({
            "linksOpen": n(&self.links_open),
            "probesOpen": n(&self.probes_open),
            "hubPlainOpen": n(&self.hub_plain_open),
            "hubKeptOpen": n(&self.hub_kept_open),
            "keptStreamsOpen": n(&self.kept_streams_open),
            "linkDials": n(&self.link_dials),
            "linkRedials": n(&self.link_redials),
            "probeDials": n(&self.probe_dials),
            "hubPlainDials": n(&self.hub_plain_dials),
            "hubKeptDials": n(&self.hub_kept_dials),
            "keptStreamOpens": n(&self.kept_stream_opens),
            "dialGateInFlight": crate::peer_dial_gate::global().in_flight(),
            "dialGateWaited": crate::peer_dial_gate::global().waited(),
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

/// How often the worker-lag canary wakes while the runtime works ([`worker_lag_canary`]).
pub const CANARY_PERIOD: Duration = Duration::from_millis(10);

/// The longest the canary sleeps while the runtime is quiet: an idle daemon pays 0.25 wakes a
/// second for it, not the 100 a fixed 10 ms period cost (ask-66b237e9ad, "brilliant fucking idle
/// resource usage"). A block that starts while it sleeps this long still shows: the wake comes
/// late by the block's length, and the next one is back at [`CANARY_PERIOD`].
pub const CANARY_IDLE_PERIOD: Duration = Duration::from_secs(4);

/// How long the runtime stays quiet before the canary starts to back off.
pub const CANARY_QUIET_BEFORE_BACKOFF: Duration = Duration::from_secs(1);

/// The canary's next sleep after a wake that slept `slept` and came `late`, while the runtime's
/// workers were busy for `busy` of it, and the runtime has been quiet for `quiet` before it. Work
/// (workers busy over 1% of the time slept) or a late wake (over 2 ms plus 2% of the sleep, so a
/// coalesced idle timer is not read as a block) puts it back at [`CANARY_PERIOD`]; a second of
/// quiet starts doubling it to [`CANARY_IDLE_PERIOD`]. Returns the sleep and the new quiet span.
pub fn canary_next(
    slept: Duration,
    late: Duration,
    busy: Duration,
    quiet: Duration,
) -> (Duration, Duration) {
    let worked = busy > slept / 100;
    let held = late > Duration::from_millis(2) + slept / 50;
    if worked || held {
        return (CANARY_PERIOD, Duration::ZERO);
    }
    let quiet = quiet.saturating_add(slept);
    if quiet < CANARY_QUIET_BEFORE_BACKOFF {
        return (CANARY_PERIOD, quiet);
    }
    ((slept.max(CANARY_PERIOD) * 2).min(CANARY_IDLE_PERIOD), quiet)
}

/// The span `gauges.workerLag` summarizes, in seconds.
pub const WORKER_LAG_WINDOW_S: u64 = 60;

/// Slots in the worker-lag ring: a minute of 10 ms wakes (6000) with room to spare, so the window
/// is whole while the canary keeps time. A canary held back or backed off on a quiet runtime
/// ([`canary_next`]) wakes less often, so then the ring holds more than a minute and the window
/// still reads only its last minute.
pub const WORKER_LAG_RING: usize = 8192;

/// How late the daemon's runtime wakes a task that asked to wake: what a request queued behind a
/// busy worker waits before its first poll (a `std` lock or a blocking read held on a worker,
/// hq `docs/handbook/request-read-holds-a-runtime-worker.md`). A fixed ring of atomics, each slot
/// the second it was taken (from this ring's birth, plus 1 so 0 is empty) over its lateness in
/// microseconds, so a sample is one `fetch_add` and one store and the memory never grows.
///
/// hq `docs/reading/2026-11-21-tokio-coop-budget.md`, row 2: "a canary task that sleeps 10 ms in a
/// loop and records how late it wakes (scheduling delay p50/p99, max in last minute), published
/// in `acpmux daemon status`".
pub struct WorkerLag {
    born: Instant,
    samples: Box<[AtomicU64]>,
    /// Every sample taken; the next slot is this modulo the ring.
    taken: AtomicU64,
    /// The canary's sleep before its last wake, in ms (`periodMs`).
    period_ms: AtomicU64,
}

impl Default for WorkerLag {
    fn default() -> Self {
        Self {
            born: Instant::now(),
            samples: (0..WORKER_LAG_RING).map(|_| AtomicU64::new(0)).collect(),
            taken: AtomicU64::new(0),
            period_ms: AtomicU64::new(CANARY_PERIOD.as_millis() as u64),
        }
    }
}

impl WorkerLag {
    /// A wake `late` past its deadline, now.
    pub fn record(&self, late: Duration) {
        self.record_at(self.born.elapsed().as_secs(), late);
    }

    fn record_at(&self, at_s: u64, late: Duration) {
        let micros = u32::try_from(late.as_micros()).unwrap_or(u32::MAX);
        let at = u32::try_from(at_s.saturating_add(1)).unwrap_or(u32::MAX);
        let slot = self.taken.fetch_add(1, Ordering::Relaxed) % self.samples.len() as u64;
        if let Some(sample) = self.samples.get(slot as usize) {
            sample.store((u64::from(at) << 32) | u64::from(micros), Ordering::Relaxed);
        }
    }

    /// `gauges.workerLag`: [`Self::summary_at`] now.
    pub fn status(&self) -> Value {
        self.summary_at(self.born.elapsed().as_secs())
    }

    /// `{periodMs, windowS, samples, p50Ms, p99Ms, maxMs}` over the samples taken in the last
    /// [`WORKER_LAG_WINDOW_S`] seconds before `now_s`: nearest-rank quantiles of how late the
    /// canary woke, null when no sample is that recent (no canary runs, or it has not woken in a
    /// minute: a runtime held that long says so in `status` not answering at all).
    fn summary_at(&self, now_s: u64) -> Value {
        let since = now_s.saturating_sub(WORKER_LAG_WINDOW_S - 1).saturating_add(1);
        let mut recent = [0u32; WORKER_LAG_RING];
        let mut count = 0;
        for sample in self.samples.iter().map(|sample| sample.load(Ordering::Relaxed)) {
            if sample >> 32 < since {
                continue;
            }
            if let Some(to) = recent.get_mut(count) {
                *to = (sample & u64::from(u32::MAX)) as u32;
                count += 1;
            }
        }
        let recent = recent.get_mut(..count).unwrap_or_default();
        recent.sort_unstable();
        let ms = |micros: u32| f64::from(micros) / 1000.0;
        let rank = |q: f64| -> Option<f64> {
            let at = ((q * count as f64).ceil() as usize).clamp(1, count.max(1)) - 1;
            recent.get(at).map(|&m| ms(m))
        };
        json!({
            "periodMs": self.period_ms.load(Ordering::Relaxed),
            "windowS": WORKER_LAG_WINDOW_S,
            "samples": count,
            "p50Ms": rank(0.50),
            "p99Ms": rank(0.99),
            "maxMs": recent.last().map(|&m| ms(m)),
        })
    }
}

/// `gauges.workerLag`: the daemon's canary ([`worker_lag_canary`]).
pub fn worker_lag() -> &'static WorkerLag {
    static RING: OnceLock<WorkerLag> = OnceLock::new();
    RING.get_or_init(WorkerLag::default)
}

/// Sleeps on the runtime it is spawned on, forever, and records in `ring` how far past its sleep
/// each wake came: [`CANARY_PERIOD`] while the runtime works, backing off to
/// [`CANARY_IDLE_PERIOD`] while it is quiet ([`canary_next`]). Its cost is one timer, one atomic
/// store and one read of the workers' busy time per wake.
pub async fn worker_lag_canary(ring: &'static WorkerLag) {
    let metrics = tokio::runtime::Handle::current().metrics();
    let busy = || -> Duration {
        (0..metrics.num_workers()).map(|w| metrics.worker_total_busy_duration(w)).sum()
    };
    let (mut period, mut quiet) = (CANARY_PERIOD, Duration::ZERO);
    loop {
        let (asked, busy_before) = (Instant::now(), busy());
        tokio::time::sleep(period).await;
        let late = asked.elapsed().saturating_sub(period);
        ring.record(late);
        ring.period_ms
            .store(u64::try_from(period.as_millis()).unwrap_or(u64::MAX), Ordering::Relaxed);
        (period, quiet) = canary_next(period, late, busy().saturating_sub(busy_before), quiet);
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
    fn a_held_count_goes_back_down_when_dropped_and_never_below_zero() {
        static COUNT: AtomicU64 = AtomicU64::new(0);
        let a = Held::on(&COUNT);
        let b = Held::on(&COUNT);
        assert_eq!(COUNT.load(Ordering::Relaxed), 2);
        drop(a);
        assert_eq!(COUNT.load(Ordering::Relaxed), 1);
        COUNT.store(0, Ordering::Relaxed);
        drop(b);
        assert_eq!(COUNT.load(Ordering::Relaxed), 0);
        assert!(global().status()["links"].get("linkRedials").is_some());
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

    #[test]
    fn an_empty_worker_lag_reports_no_quantiles() {
        let status = WorkerLag::default().summary_at(0);
        assert_eq!(status["samples"], 0, "{status}");
        assert_eq!(status["p50Ms"], Value::Null, "{status}");
        assert_eq!(status["p99Ms"], Value::Null, "{status}");
        assert_eq!(status["maxMs"], Value::Null, "{status}");
        assert_eq!(status["periodMs"], 10);
        assert_eq!(status["windowS"], 60);
    }

    #[test]
    fn worker_lag_reports_nearest_rank_quantiles_of_its_last_minute() {
        let ring = WorkerLag::default();
        // A 900 ms stall 61 s before the read: out of the window.
        ring.record_at(39, Duration::from_millis(900));
        // 1..=200 ms over the last minute, shuffled by a stride coprime to 200.
        for i in 0..200u64 {
            ring.record_at(41 + i % 60, Duration::from_millis((i * 37) % 200 + 1));
        }
        let status = ring.summary_at(100);
        assert_eq!(status["samples"], 200, "{status}");
        assert_eq!(status["p50Ms"], 100.0, "{status}");
        assert_eq!(status["p99Ms"], 198.0, "{status}");
        assert_eq!(status["maxMs"], 200.0, "{status}");
        // A minute later every one of them has aged out.
        assert_eq!(ring.summary_at(160)["samples"], 0);
        // The edge: a sample taken at second 41 is in a read at 100, not at 101.
        assert_eq!(ring.summary_at(101)["samples"], 200 - 4, "{}", ring.summary_at(101));
    }

    #[test]
    fn worker_lag_memory_is_fixed_and_keeps_only_its_last_samples() {
        let ring = WorkerLag::default();
        for _ in 0..10 {
            ring.record_at(5, Duration::from_secs(9));
        }
        for _ in 0..WORKER_LAG_RING {
            ring.record_at(5, Duration::from_micros(1500));
        }
        let status = ring.summary_at(5);
        assert_eq!(status["samples"], WORKER_LAG_RING, "{status}");
        assert_eq!(status["maxMs"], 1.5, "{status}");
        ring.record_at(5, Duration::from_secs(u64::MAX / 4));
        assert_eq!(ring.summary_at(5)["maxMs"], f64::from(u32::MAX) / 1000.0);
    }

    /// The canary on a one-worker runtime for `run`, with a task that blocks that worker for
    /// `block` (a `std` sleep, as a `std` lock or a blocking read would) after 50 ms.
    fn canary_max_ms(block: Option<Duration>, run: Duration) -> f64 {
        let ring: &'static WorkerLag = Box::leak(Box::default());
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(1)
            .enable_time()
            .build()
            .unwrap();
        runtime.spawn(worker_lag_canary(ring));
        runtime.block_on(async {
            tokio::time::sleep(Duration::from_millis(50)).await;
            if let Some(block) = block {
                runtime_spawn_blocker(block);
            }
            tokio::time::sleep(run).await;
        });
        runtime.shutdown_background();
        let status = ring.status();
        assert!(status["samples"].as_u64().unwrap() > 5, "{status}");
        status["maxMs"].as_f64().unwrap()
    }

    fn runtime_spawn_blocker(block: Duration) {
        tokio::spawn(async move { std::thread::sleep(block) });
    }

    #[test]
    fn the_canary_backs_off_only_after_a_quiet_second_and_snaps_back_on_work() {
        let ms = Duration::from_millis;
        let mut period = CANARY_PERIOD;
        let mut quiet = Duration::ZERO;
        let mut wakes = 0;
        // Quiet: 10 ms wakes for the first second, then doubling to the idle period.
        while quiet < Duration::from_secs(120) {
            (period, quiet) = canary_next(period, Duration::ZERO, Duration::from_micros(20), quiet);
            wakes += 1;
            if quiet < CANARY_QUIET_BEFORE_BACKOFF {
                assert_eq!(period, CANARY_PERIOD, "backed off after {quiet:?} of quiet");
            }
        }
        assert_eq!(period, CANARY_IDLE_PERIOD);
        // Two minutes of quiet cost about 100 + 9 + 29 wakes, not 12,000.
        assert!(wakes < 150, "{wakes} wakes in two quiet minutes");
        // A coalesced idle timer (40 ms late on a 4 s sleep) is not a block.
        let (next, _) = canary_next(CANARY_IDLE_PERIOD, ms(40), Duration::ZERO, quiet);
        assert_eq!(next, CANARY_IDLE_PERIOD);
        // A late wake or busy workers put it back at 10 ms with no quiet left.
        assert_eq!(
            canary_next(CANARY_IDLE_PERIOD, ms(200), Duration::ZERO, quiet),
            (CANARY_PERIOD, Duration::ZERO)
        );
        assert_eq!(
            canary_next(CANARY_IDLE_PERIOD, Duration::ZERO, ms(50), quiet),
            (CANARY_PERIOD, Duration::ZERO)
        );
        // Steady work keeps it at 10 ms.
        assert_eq!(
            canary_next(CANARY_PERIOD, Duration::ZERO, ms(1), Duration::ZERO).0,
            CANARY_PERIOD
        );
    }

    #[test]
    fn a_blocked_worker_shows_in_the_worker_lag_max() {
        let max = canary_max_ms(Some(Duration::from_millis(200)), Duration::from_millis(400));
        assert!(max >= 150.0, "the canary woke at most {max} ms late behind a 200 ms block");
    }

    #[test]
    fn an_idle_worker_keeps_the_worker_lag_small() {
        let max = canary_max_ms(None, Duration::from_millis(400));
        // Timer granularity is 1 ms; the bound leaves a loaded CI host room.
        assert!(max < 100.0, "the canary woke {max} ms late on an idle runtime");
    }
}
