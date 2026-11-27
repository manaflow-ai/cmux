//! The duress bench's host150 leg, its peerscale legs and the measures every leg's row gains
//! (included by `duress_daemon.rs`; see its header for how to run it).
//!
//! Why (Leo, 2026-11-23): his Mac at load 89-154 on 15 cores, swap 21.5 of 22.5 GB used, the
//! daemon holding ~40 peer links, each with its own heartbeat and silence budget; under load every
//! link's longest wait for an answer rose to 3-4 s together, peers dropped ("peer stopped
//! answering (6-13 s without a frame)"), and agents spawned 30-45 short tool processes a second.
//!
//! - `host150`: busy loops sized to a 1-minute load of [`HOST150_LOAD_X`] x cores (the clock
//!   starts once the load reaches 90% of that, or after [`RAMP_MAX`], and the load reached is
//!   recorded either way), the daemon under `MemoryHigh` ([`host150_memory_high`]) and, where the
//!   host has swap, a hog in its own memory-capped scope pushing its pages to swap, at least
//!   [`HOST150_PEERS`] peers, and a fork storm of about [`SPAWN_RATE`] short processes a second.
//! - `peerscale` (expands to `peerscale1`, `peerscale10`, `peerscale20`, `peerscale40`): the
//!   baseline leg at N peers, with a quiet span of [`QUIET`] before the window that reads the
//!   daemon's idle CPU and the heartbeat frames per second on the wire.
//!
//! Every leg's row gains: `presenceGapMs` (per peer and worst: the longest time a peer that was
//! up read anything but connected or degraded in `_acpmux/peers`, or was missing, sampled at 4 Hz
//! over one socket connection), `linkDrops` (per peer: drops seen by that sampler, dials through
//! the proxies, and the daemon log's "stopped answering", "silence budget" and "link open"
//! lines), `peerLinks` (the daemon's established TCP connections to the proxies and all its
//! sockets), `wire` (frames through the proxies, by kind, per second), `peerNotices` (the
//! `_acpmux/status` gauges at the window's start and end), `spawns` (forks per second from
//! `/proc/stat`, and the daemon's descendants seen), `daemonCpu`, `memory` and `phoneLink`.
use super::*;
use std::sync::atomic::AtomicUsize;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

#[path = "duress_starved.rs"]
mod starved;

#[path = "duress_cgroup.rs"]
mod cgroup;

/// Legs beside `ALL_LEGS` that a run names on purpose (`all` does not take them).
pub(super) const EXTRA_LEGS: [&str; 5] =
    ["host150", "peerscale", starved::LEG, BURST_LEG, super::rfd0050::LEG];
/// All ready peer links cut in one instant, then let redial (`peer_burst`).
pub(super) const BURST_LEG: &str = "peerburst";
/// The peer counts of `peerscale`.
pub(super) const PEERSCALE: [usize; 4] = [1, 10, 20, 40];
/// Peers in the host150 leg, at least (Leo's Mac held ~40 links).
pub(super) const HOST150_PEERS: usize = 40;
/// host150's 1-minute load target, in multiples of the host's cores (his Mac: 150 on 15).
pub(super) const HOST150_LOAD_X: f64 = 10.0;
/// The longest the host150 leg waits for its load before the clock starts anyway.
pub(super) const RAMP_MAX: Duration = Duration::from_secs(90);
/// Short processes a second the host150 fork storm aims for (the agents' 30-45).
pub(super) const SPAWN_RATE: u32 = 40;
/// The peerscale legs' quiet span before the window: idle CPU and heartbeat frames.
pub(super) const QUIET: Duration = Duration::from_secs(15);
/// How often the presence sampler reads `_acpmux/peers`: 4 Hz, so a 2 s gap is 8 samples.
const SAMPLE_EVERY: Duration = Duration::from_millis(250);
/// A presence gap over this is counted (`peersOver2s`).
const GAP_OVER_MS: f64 = 2000.0;
/// The swap hog's own memory ceiling: whatever it holds past this is pushed out to swap.
const HOG_MEMORY_HIGH: &str = "256M";
/// The swap hog's size at most.
const HOG_MAX_BYTES: u64 = 16 << 30;

pub(super) fn is_extra(leg: &str) -> bool {
    leg == "host150"
        || leg == starved::LEG
        || leg == BURST_LEG
        || leg == super::rfd0050::LEG
        || peerscale_n(leg).is_some()
}

/// `peerscale` names four legs; the rest pass through.
pub(super) fn expand(legs: Vec<String>) -> Vec<String> {
    legs.into_iter()
        .flat_map(|l| {
            if l == "peerscale" {
                PEERSCALE.iter().map(|n| format!("peerscale{n}")).collect()
            } else {
                vec![l]
            }
        })
        .collect()
}

fn peerscale_n(leg: &str) -> Option<usize> {
    leg.strip_prefix("peerscale")?.parse().ok()
}

/// The leg's peer count: peerscale's N, host150's [`HOST150_PEERS`] at least, else the knob.
pub(super) fn peers_for(leg: &str, knob: usize) -> usize {
    match leg {
        "host150" => knob.max(HOST150_PEERS),
        starved::LEG => knob.max(starved::PEERS),
        BURST_LEG => knob.max(HOST150_PEERS),
        _ => peerscale_n(leg).unwrap_or(knob),
    }
}

/// What the leg's stressors may run past the knobs' cap: host150's ramp, peerscale's quiet span.
pub(super) fn extra_cap(leg: &str) -> Duration {
    if leg == "host150" {
        RAMP_MAX
    } else if peerscale_n(leg).is_some() {
        QUIET
    } else if leg == starved::LEG {
        starved::SETTLE
    } else if leg == BURST_LEG {
        BURST_READY + BURST_WATCH
    } else if leg == super::rfd0050::LEG {
        // The longer window, and the 30 s the RAM hog may take to hold its pages.
        super::rfd0050::WINDOW_MIN + Duration::from_secs(30)
    } else {
        Duration::ZERO
    }
}

/// host150's ceiling on the daemon's memory (`ACPMUX_DURESS_MEMORY_HIGH`, default 192M): low
/// enough that a daemon holding 40 peers' lists is reclaimed from, not just capped on paper.
pub(super) fn host150_memory_high() -> String {
    std::env::var("ACPMUX_DURESS_MEMORY_HIGH")
        .ok()
        .filter(|v| !v.trim().is_empty())
        .unwrap_or_else(|| "192M".into())
}

// ---------------------------------------------------------------------------------------------
// peerburst: every ready link cut at once.

/// The longest peerburst waits for every peer's link to be open before the cut.
const BURST_READY: Duration = Duration::from_secs(60);
/// How long peerburst watches the redials after the cut.
const BURST_WATCH: Duration = Duration::from_secs(15);

/// The 2026-11-23 shape (one relay cut or one daemon stall drops every link together): wait for
/// every proxy to hold an open link, cut them all in one instant while still accepting, and read
/// the proxies' accepts: dials in the first 250 ms and first second, the most dialing in any
/// 100 ms, and how long until every peer dialed again and every link is open again.
pub(super) fn peer_burst(proxies: &[Proxy]) -> Value {
    let ready_by = Instant::now() + BURST_READY;
    let all_open = || proxies.iter().all(|p| p.wire.open.load(Ordering::Relaxed) >= 1);
    while !all_open() && Instant::now() < ready_by {
        std::thread::sleep(Duration::from_millis(50));
    }
    let ready_before = proxies.iter().filter(|p| p.wire.open.load(Ordering::Relaxed) >= 1).count();
    // Let the first dials' own burst window pass so the cut starts a fresh one.
    std::thread::sleep(Duration::from_secs(3));
    let base: Vec<u64> = proxies.iter().map(|p| p.wire.accepts.load(Ordering::Relaxed)).collect();
    let t0 = Instant::now();
    for p in proxies {
        p.cut(false);
    }
    let new_dials = || -> Vec<u64> {
        proxies
            .iter()
            .zip(&base)
            .map(|(p, b)| p.wire.accepts.load(Ordering::Relaxed).saturating_sub(*b))
            .collect()
    };
    let mut timeline: Vec<(u128, u64)> = vec![];
    let (mut all_dialed_ms, mut all_open_ms) = (None, None);
    while t0.elapsed() < BURST_WATCH {
        std::thread::sleep(Duration::from_millis(10));
        let ms = t0.elapsed().as_millis();
        let d = new_dials();
        timeline.push((ms, d.iter().sum()));
        if all_dialed_ms.is_none() && d.iter().all(|n| *n >= 1) {
            all_dialed_ms = Some(ms);
        }
        if all_dialed_ms.is_some() && all_open_ms.is_none() && all_open() {
            all_open_ms = Some(ms);
            break;
        }
    }
    let at = |limit: u128| timeline.iter().filter(|(ms, _)| *ms <= limit).map(|(_, n)| *n).max();
    // The most new dials inside any 100 ms of the timeline.
    let mut most_100ms = 0u64;
    for (i, (ms, n)) in timeline.iter().enumerate() {
        let before =
            timeline[..i].iter().rev().find(|(m, _)| *m + 100 <= *ms).map_or(0, |(_, n0)| *n0);
        most_100ms = most_100ms.max(n - before);
    }
    let v = json!({
        "peers": proxies.len(),
        "readyBeforeCut": ready_before,
        "dialsFirst250ms": at(250).unwrap_or(0),
        "dialsFirst1s": at(1000).unwrap_or(0),
        "mostDialsIn100ms": most_100ms,
        "allDialedMs": all_dialed_ms,
        "allOpenMs": all_open_ms,
        "dialsTotal": new_dials().iter().sum::<u64>(),
    });
    println!("DURESS-PEERBURST {v}");
    v
}

// ---------------------------------------------------------------------------------------------
// The wire: frames through the proxies.

/// What went through every proxy: dials accepted, and WebSocket frames by opcode both ways.
#[derive(Default)]
pub(super) struct Wire {
    pub accepts: AtomicU64,
    pub frames: AtomicU64,
    pub pings: AtomicU64,
    pub pongs: AtomicU64,
    pub data: AtomicU64,
    pub closes: AtomicU64,
    pub bytes: AtomicU64,
    /// Links open now (pumps running).
    pub open: AtomicUsize,
}

impl Wire {
    fn snapshot(&self) -> [u64; 6] {
        [
            self.accepts.load(Ordering::Relaxed),
            self.frames.load(Ordering::Relaxed),
            self.pings.load(Ordering::Relaxed),
            self.pongs.load(Ordering::Relaxed),
            self.data.load(Ordering::Relaxed),
            self.bytes.load(Ordering::Relaxed),
        ]
    }
}

/// Counts WebSocket frames in one direction of a stream, after its HTTP upgrade.
#[derive(Default)]
struct FrameCounter {
    /// The upgrade's header is done (its blank line seen).
    upgraded: bool,
    /// The last four bytes of the upgrade, to find its blank line across reads.
    tail: u32,
    header: Vec<u8>,
    skip: u64,
}

impl FrameCounter {
    fn feed(&mut self, mut buf: &[u8], wire: &Wire) {
        while !buf.is_empty() {
            if !self.upgraded {
                self.tail = (self.tail << 8) | u32::from(buf[0]);
                buf = &buf[1..];
                if self.tail == 0x0d0a_0d0a {
                    self.upgraded = true;
                }
                continue;
            }
            if self.skip > 0 {
                let n = self.skip.min(buf.len() as u64) as usize;
                self.skip -= n as u64;
                buf = &buf[n..];
                continue;
            }
            self.header.push(buf[0]);
            buf = &buf[1..];
            if let Some((len, payload, opcode)) = frame_header(&self.header)
                && self.header.len() == len
            {
                wire.frames.fetch_add(1, Ordering::Relaxed);
                let kind = match opcode {
                    0x9 => &wire.pings,
                    0xA => &wire.pongs,
                    0x8 => &wire.closes,
                    _ => &wire.data,
                };
                kind.fetch_add(1, Ordering::Relaxed);
                self.header.clear();
                self.skip = payload;
            }
        }
    }
}

/// A frame header's length, its payload's length and its opcode, once enough of it is read to
/// know them (RFC 6455 5.2).
fn frame_header(h: &[u8]) -> Option<(usize, u64, u8)> {
    if h.len() < 2 {
        return None;
    }
    let masked = h[1] & 0x80 != 0;
    let short = u64::from(h[1] & 0x7f);
    let ext = match short {
        126 => 2,
        127 => 8,
        _ => 0,
    };
    if h.len() < 2 + ext {
        return None;
    }
    let payload =
        if ext == 0 { short } else { h[2..2 + ext].iter().fold(0u64, |a, b| (a << 8) | *b as u64) };
    Some((2 + ext + if masked { 4 } else { 0 }, payload, h[0] & 0x0f))
}

/// One proxied link, both ways, counting frames: `copy_bidirectional` with eyes.
pub(super) async fn pump(
    client: tokio::net::TcpStream,
    server: tokio::net::TcpStream,
    wire: Arc<Wire>,
) {
    wire.open.fetch_add(1, Ordering::Relaxed);
    let (cr, cw) = client.into_split();
    let (sr, sw) = server.into_split();
    tokio::join!(copy_counting(cr, sw, wire.clone()), copy_counting(sr, cw, wire.clone()));
    wire.open.fetch_sub(1, Ordering::Relaxed);
}

async fn copy_counting(
    mut from: tokio::net::tcp::OwnedReadHalf,
    mut to: tokio::net::tcp::OwnedWriteHalf,
    wire: Arc<Wire>,
) {
    let mut buf = vec![0u8; 16 << 10];
    let mut frames = FrameCounter::default();
    loop {
        let n = match from.read(&mut buf).await {
            Ok(0) | Err(_) => break,
            Ok(n) => n,
        };
        wire.bytes.fetch_add(n as u64, Ordering::Relaxed);
        frames.feed(&buf[..n], &wire);
        // The starved leg's distance: delay, jitter, and the stall of every peer at once.
        let hold = starved::hold();
        if !hold.is_zero() {
            tokio::time::sleep(hold).await;
        }
        if to.write_all(&buf[..n]).await.is_err() {
            break;
        }
    }
    let _ = to.shutdown().await;
}

// ---------------------------------------------------------------------------------------------
// The host and the daemon, read from /proc.

/// `processes` in /proc/stat: forks since boot.
fn forks() -> Option<u64> {
    std::fs::read_to_string("/proc/stat")
        .ok()?
        .lines()
        .find_map(|l| l.strip_prefix("processes ")?.trim().parse().ok())
}

/// A process's CPU time (user + system) in seconds.
fn cpu_secs(pid: u32) -> Option<f64> {
    let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    let rest = &stat[stat.rfind(')')? + 2..];
    let f: Vec<&str> = rest.split_whitespace().collect();
    // Fields 14 and 15 (utime, stime) are 11 and 12 after the state (field 3).
    let ticks: u64 = f.get(11)?.parse::<u64>().ok()? + f.get(12)?.parse::<u64>().ok()?;
    // SAFETY: sysconf reads a constant.
    let hz = unsafe { libc::sysconf(libc::_SC_CLK_TCK) }.max(1) as f64;
    Some(ticks as f64 / hz)
}

fn rss_kib(pid: u32) -> Option<u64> {
    std::fs::read_to_string(format!("/proc/{pid}/status"))
        .ok()?
        .lines()
        .find_map(|l| l.strip_prefix("VmRSS:")?.trim().trim_end_matches("kB").trim().parse().ok())
}

fn meminfo_kib(key: &str) -> Option<u64> {
    std::fs::read_to_string("/proc/meminfo").ok()?.lines().find_map(|l| {
        let v = l.strip_prefix(key)?.strip_prefix(':')?;
        v.trim().trim_end_matches("kB").trim().parse().ok()
    })
}

/// The cgroup v2 folder of `pid`.
fn cgroup_dir(pid: u32) -> Option<PathBuf> {
    let text = std::fs::read_to_string(format!("/proc/{pid}/cgroup")).ok()?;
    let rel = text.lines().find_map(|l| l.strip_prefix("0::"))?;
    Some(PathBuf::from(format!("/sys/fs/cgroup{rel}")))
}

/// `key` in the cgroup's `memory.events` (`high`: times it was over MemoryHigh and reclaimed).
fn memory_event(dir: &Path, key: &str) -> Option<u64> {
    std::fs::read_to_string(dir.join("memory.events"))
        .ok()?
        .lines()
        .find_map(|l| l.strip_prefix(key)?.strip_prefix(' ')?.trim().parse().ok())
}

/// The cgroup's `memory.pressure` `some avg10`.
fn memory_pressure(dir: &Path) -> Option<f64> {
    let text = std::fs::read_to_string(dir.join("memory.pressure")).ok()?;
    let some = text.lines().find(|l| l.starts_with("some"))?;
    some.split_whitespace().find_map(|f| f.strip_prefix("avg10=")?.parse().ok())
}

/// Socket inodes `pid` holds open.
fn socket_inodes(pid: u32) -> BTreeSet<u64> {
    let Ok(dir) = std::fs::read_dir(format!("/proc/{pid}/fd")) else { return BTreeSet::new() };
    dir.flatten()
        .filter_map(|e| {
            let link = std::fs::read_link(e.path()).ok()?;
            link.to_str()?.strip_prefix("socket:[")?.strip_suffix(']')?.parse().ok()
        })
        .collect()
}

/// The daemon's sockets: all of them, and its established TCP connections to `ports`.
fn daemon_links(pid: u32, ports: &BTreeSet<u16>) -> (usize, usize) {
    let mine = socket_inodes(pid);
    let mut to_proxies = 0;
    for table in ["tcp", "tcp6"] {
        let Ok(text) = std::fs::read_to_string(format!("/proc/{pid}/net/{table}")) else {
            continue;
        };
        for line in text.lines().skip(1) {
            let f: Vec<&str> = line.split_whitespace().collect();
            let (Some(rem), Some(st), Some(inode)) = (f.get(2), f.get(3), f.get(9)) else {
                continue;
            };
            let port = rem.rsplit(':').next().and_then(|p| u16::from_str_radix(p, 16).ok());
            if *st == "01"
                && port.is_some_and(|p| ports.contains(&p))
                && inode.parse::<u64>().is_ok_and(|i| mine.contains(&i))
            {
                to_proxies += 1;
            }
        }
    }
    (mine.len(), to_proxies)
}

/// Pids under `root` (its children, theirs, ...), from one read of /proc.
fn descendants(root: u32) -> BTreeSet<i32> {
    let parent: BTreeMap<i32, i32> = procs()
        .into_iter()
        .filter_map(|(pid, f)| Some((pid, f.get(1)?.parse::<i32>().ok()?)))
        .collect();
    let mut out = BTreeSet::new();
    let mut frontier = vec![root as i32];
    while let Some(p) = frontier.pop() {
        for (child, _) in parent.iter().filter(|(_, pp)| **pp == p) {
            if out.insert(*child) {
                frontier.push(*child);
            }
        }
    }
    out
}

/// The first value named `key` anywhere in a status reply.
fn find_key<'a>(v: &'a Value, key: &str) -> Option<&'a Value> {
    match v {
        Value::Object(m) => m.get(key).or_else(|| m.values().find_map(|x| find_key(x, key))),
        Value::Array(a) => a.iter().find_map(|x| find_key(x, key)),
        _ => None,
    }
}

fn notices(socket: &Path) -> Result<Value, String> {
    let mut r = Rpc::connect(socket)?;
    let v = r.call("_acpmux/status", json!({}), CALL_LIMIT)?;
    find_key(&v, "peerNotices").cloned().ok_or_else(|| "no peerNotices in _acpmux/status".into())
}

/// `_acpmux/status`'s `gauges.links` (the object holding `linkDials`), when the daemon has it.
fn link_gauges(socket: &Path) -> Option<Value> {
    let mut r = Rpc::connect(socket).ok()?;
    let v = r.call("_acpmux/status", json!({}), CALL_LIMIT).ok()?;
    holding(&v, "linkDials").cloned()
}

/// The first object anywhere in `v` that has `key`.
fn holding<'a>(v: &'a Value, key: &str) -> Option<&'a Value> {
    match v {
        Value::Object(m) if m.contains_key(key) => Some(v),
        Value::Object(m) => m.values().find_map(|x| holding(x, key)),
        Value::Array(a) => a.iter().find_map(|x| holding(x, key)),
        _ => None,
    }
}

/// Daemon log lines from `offset` on that name `peer` ("peer=NAME" or "peer: NAME").
fn log_counts(log: &Path, offset: u64, peers: &[String]) -> BTreeMap<String, [u64; 3]> {
    let mut out: BTreeMap<String, [u64; 3]> = peers.iter().map(|p| (p.clone(), [0; 3])).collect();
    let Ok(bytes) = std::fs::read(log) else { return out };
    let text = String::from_utf8_lossy(&bytes[(offset as usize).min(bytes.len())..]).into_owned();
    for line in text.lines() {
        let which = if line.contains("stopped answering") {
            0
        } else if line.contains("silence budget") {
            1
        } else if line.contains("link open to") {
            2
        } else {
            continue;
        };
        if let Some(peer) = peers.iter().find(|p| {
            line.contains(&format!("peer={p}")) || line.contains(&format!("peer=\"{p}\""))
        }) {
            out.get_mut(peer).unwrap()[which] += 1;
        }
    }
    out
}

// ---------------------------------------------------------------------------------------------
// The presence sampler: `_acpmux/peers` at 4 Hz.

#[derive(Default)]
struct PeerTrack {
    down_since: Option<f64>,
    worst_ms: f64,
    gaps_over: u64,
    drops: u64,
    states: BTreeMap<String, u64>,
}

#[derive(Default)]
struct PresenceOut {
    peers: BTreeMap<String, PeerTrack>,
    reads: u64,
    read_errors: BTreeMap<String, u64>,
    read_ms: Vec<f64>,
    /// Daemon descendants seen at any sample (a lower bound on what it spawned).
    seen: BTreeSet<i32>,
    load1: Vec<f64>,
    swap_used_kib_max: u64,
    daemon_rss_kib_max: u64,
    memory_psi_max: Option<f64>,
    /// The daemon's cgroup and the host's pressure, once a second (`duress_cgroup.rs`).
    cg: cgroup::Track,
}

pub(super) struct Presence {
    thread: std::thread::JoinHandle<PresenceOut>,
}

impl Presence {
    /// Samples until `until`. Peers in `cut` are down on purpose and not tracked.
    pub(super) fn start(
        socket: &Path,
        names: &[String],
        cut: &BTreeSet<String>,
        daemon_pid: u32,
        until: Instant,
    ) -> Self {
        let socket = socket.to_path_buf();
        let tracked: Vec<String> = names.iter().filter(|n| !cut.contains(*n)).cloned().collect();
        let started = Instant::now();
        let cgroup = cgroup_dir(daemon_pid);
        let thread = std::thread::spawn(move || {
            let mut out =
                PresenceOut { cg: cgroup::Track::new(cgroup.clone()), ..Default::default() };
            let mut read_ms_since: Option<f64> = None;
            for n in &tracked {
                out.peers.insert(n.clone(), PeerTrack::default());
            }
            let mut rpc: Option<Rpc> = None;
            let mut tick_n = 0u64;
            while Instant::now() < until {
                let tick = Instant::now();
                let at = started.elapsed().as_secs_f64() * 1000.0;
                if rpc.is_none() {
                    match Rpc::connect(&socket) {
                        Ok(r) => rpc = Some(r),
                        Err(e) => *out.read_errors.entry(e).or_default() += 1,
                    }
                }
                if let Some(r) = rpc.as_mut() {
                    let asked = Instant::now();
                    match r.call("_acpmux/peers", json!({}), Duration::from_secs(5)) {
                        Ok(v) => {
                            out.reads += 1;
                            let took = ms_f(asked.elapsed());
                            out.read_ms.push(took);
                            read_ms_since = Some(read_ms_since.map_or(took, |m: f64| m.max(took)));
                            let states: BTreeMap<String, String> = v["peers"]
                                .as_array()
                                .into_iter()
                                .flatten()
                                .filter_map(|p| {
                                    let name = p["name"].as_str()?.to_owned();
                                    let state = p["state"].as_str().map_or_else(
                                        || {
                                            if p["connected"].as_bool() == Some(true) {
                                                "connected".into()
                                            } else {
                                                "offline".into()
                                            }
                                        },
                                        str::to_owned,
                                    );
                                    Some((name, state))
                                })
                                .collect();
                            for (name, t) in &mut out.peers {
                                let state =
                                    states.get(name).cloned().unwrap_or_else(|| "missing".into());
                                let up = state == "connected" || state == "degraded";
                                *t.states.entry(state).or_default() += 1;
                                match (up, t.down_since) {
                                    (false, None) => {
                                        t.down_since = Some(at);
                                        t.drops += 1;
                                    }
                                    (true, Some(since)) => {
                                        let gap = at - since;
                                        t.worst_ms = t.worst_ms.max(gap);
                                        if gap > GAP_OVER_MS {
                                            t.gaps_over += 1;
                                        }
                                        t.down_since = None;
                                    }
                                    _ => {}
                                }
                            }
                        }
                        Err(e) => {
                            *out.read_errors.entry(e).or_default() += 1;
                            rpc = None;
                        }
                    }
                }
                // Once a second: the daemon's tree, the load, swap, RSS and memory pressure.
                if tick_n.is_multiple_of(4) {
                    out.seen.extend(descendants(daemon_pid));
                    if let Some(l) = load1() {
                        out.load1.push(l);
                    }
                    if let (Some(t), Some(f)) = (meminfo_kib("SwapTotal"), meminfo_kib("SwapFree"))
                    {
                        out.swap_used_kib_max = out.swap_used_kib_max.max(t.saturating_sub(f));
                    }
                    if let Some(r) = rss_kib(daemon_pid) {
                        out.daemon_rss_kib_max = out.daemon_rss_kib_max.max(r);
                    }
                    if let Some(p) = cgroup.as_deref().and_then(memory_pressure) {
                        out.memory_psi_max = Some(out.memory_psi_max.map_or(p, |m: f64| m.max(p)));
                    }
                    out.cg.sample(daemon_pid, read_ms_since.take());
                }
                tick_n += 1;
                if let Some(rest) = SAMPLE_EVERY.checked_sub(tick.elapsed()) {
                    std::thread::sleep(rest);
                }
            }
            // A gap still open at the end is a gap to the end.
            let end = started.elapsed().as_secs_f64() * 1000.0;
            for t in out.peers.values_mut() {
                if let Some(since) = t.down_since.take() {
                    let gap = end - since;
                    t.worst_ms = t.worst_ms.max(gap);
                    if gap > GAP_OVER_MS {
                        t.gaps_over += 1;
                    }
                }
            }
            out
        });
        Self { thread }
    }
}

// ---------------------------------------------------------------------------------------------
// The leg's extras: host150's stressors, the window's start, and the row's fields.

/// What a leg reads at its window's start, to subtract at its end.
pub(super) struct Window {
    at: Instant,
    forks: Option<u64>,
    cpu: Option<f64>,
    wire: [u64; 6],
    notices: Result<Value, String>,
    links: Option<Value>,
    log_offset: u64,
    memory_high_events: Option<u64>,
    cgroup: Option<PathBuf>,
}

pub(super) struct Extras {
    stressors: Vec<Stressor>,
    pub notes: Vec<String>,
    pub stress: serde_json::Map<String, Value>,
    /// peerscale's quiet span: idle CPU % of one core and frames per second.
    quiet: Option<Value>,
    load_at_clock: Option<f64>,
    swap_before_kib: Option<u64>,
    ramp_secs: Option<f64>,
    /// The starved leg's pinning, cgroup and network shaping.
    starved: Option<starved::Starved>,
}

/// The hog: `bytes` touched a page at a time, then touched again every 5 s, so its pages that
/// went to swap keep coming back (swap churn, as on his Mac).
fn hog_script(bytes: u64) -> String {
    let py = format!(
        "import time\nchunks=[]\nleft={bytes}\nwhile left>0:\n n=min(left,64<<20)\n b=bytearray(n)\n \
         b[::4096]=b'\\x01'*len(range(0,n,4096))\n chunks.append(b)\n left-=n\nwhile True:\n \
         time.sleep(5)\n for b in chunks[::8]:\n  b[::4096]=b'\\x02'*len(range(0,len(b),4096))\n"
    );
    format!(
        "exec /usr/bin/systemd-run --user --scope --quiet -p MemoryHigh={HOG_MEMORY_HIGH} -- \
         python3 -c \"$(printf '%s' '{}' | base64 -d)\"",
        base64_encode(py.as_bytes())
    )
}

fn base64_encode(bytes: &[u8]) -> String {
    const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut s = String::new();
    for c in bytes.chunks(3) {
        let n = (u32::from(c[0]) << 16)
            | (u32::from(*c.get(1).unwrap_or(&0)) << 8)
            | u32::from(*c.get(2).unwrap_or(&0));
        for i in 0..4 {
            if i <= c.len() {
                s.push(T[((n >> (18 - 6 * i)) & 63) as usize] as char);
            } else {
                s.push('=');
            }
        }
    }
    s
}

/// About [`SPAWN_RATE`] processes a second: two `/bin/true` and one `sleep` per round.
fn spawn_script() -> String {
    let pause = 3.0 / f64::from(SPAWN_RATE);
    format!("while :; do /bin/true; /bin/true; /bin/sleep {pause:.3}; done")
}

impl Extras {
    /// host150: starts its stressors and waits (deadline [`RAMP_MAX`]) for its load; peerscale:
    /// its quiet span. Other legs: nothing.
    ///
    /// `wire` sums the proxies' counters at the call: the quiet span reads it before and after.
    pub(super) fn start(
        leg: &str,
        daemon_pid: u32,
        wire: &dyn Fn() -> Wire,
        cap: Duration,
    ) -> Self {
        let mut x = Extras {
            stressors: vec![],
            notes: vec![],
            stress: serde_json::Map::new(),
            quiet: None,
            load_at_clock: None,
            swap_before_kib: None,
            ramp_secs: None,
            starved: None,
        };
        if leg == starved::LEG {
            x.starved =
                Some(starved::Starved::start(daemon_pid, cap, &mut x.stressors, &mut x.notes));
            return x;
        }
        if peerscale_n(leg).is_some() {
            let (cpu0, w0, t0) = (cpu_secs(daemon_pid), wire().snapshot(), Instant::now());
            std::thread::sleep(QUIET);
            let secs = t0.elapsed().as_secs_f64();
            let w1 = wire().snapshot();
            let per_s = |i: usize| (w1[i] - w0[i]) as f64 / secs;
            x.quiet = Some(json!({
                "secs": secs,
                "daemonCpuPct": cpu0.zip(cpu_secs(daemon_pid)).map(|(a, b)| (b - a) / secs * 100.0),
                "framesPerSec": per_s(1), "pingsPerSec": per_s(2), "pongsPerSec": per_s(3),
                "bytesPerSec": per_s(5),
            }));
        }
        if leg != "host150" {
            return x;
        }
        let cores = cores();
        let target = HOST150_LOAD_X * cores as f64;
        // Each loop adds one to the load; the bench's own work and the host's add the rest.
        let loops = target.round() as usize;
        match Stressor::spawn("host150-cpu", &cpu_script(loops), cap) {
            Ok(s) => x.stressors.push(s),
            Err(e) => x.notes.push(format!("host150 cpu: spawn failed: {e}")),
        }
        match Stressor::spawn("host150-spawns", &spawn_script(), cap) {
            Ok(s) => x.stressors.push(s),
            Err(e) => x.notes.push(format!("host150 spawns: spawn failed: {e}")),
        }
        x.stress.insert("cpuLoops".into(), json!(loops));
        x.stress.insert("loadTarget".into(), json!(target));
        x.stress.insert("spawnTargetPerSec".into(), json!(SPAWN_RATE));
        // Swap: a hog in its own capped scope, so what it holds past its ceiling goes to swap
        // (never the host's other jobs' memory: the cap is the hog's).
        let swap_total = meminfo_kib("SwapTotal").unwrap_or(0);
        let swap_free = meminfo_kib("SwapFree").unwrap_or(0);
        x.swap_before_kib = Some(swap_total.saturating_sub(swap_free));
        if swap_total == 0 {
            x.notes.push(
                "memory: no swap on this host, so no swap hog; pressure is the daemon's \
                 MemoryHigh only"
                    .into(),
            );
            x.stress.insert("swapHog".into(), json!("not run: no swap"));
        } else {
            match memory_ceiling_works() {
                Ok(()) => {
                    let bytes = (swap_free * 1024 * 8 / 10).min(HOG_MAX_BYTES) + (256 << 20);
                    match Stressor::spawn("host150-swap-hog", &hog_script(bytes), cap) {
                        Ok(s) => {
                            x.stressors.push(s);
                            x.stress.insert(
                                "swapHog".into(),
                                json!(format!(
                                    "{} MiB under MemoryHigh={HOG_MEMORY_HIGH}; swap {} of {} MiB used before",
                                    bytes >> 20,
                                    swap_total.saturating_sub(swap_free) >> 10,
                                    swap_total >> 10
                                )),
                            );
                        }
                        Err(e) => x.notes.push(format!("memory: swap hog spawn failed: {e}")),
                    }
                }
                Err(why) => {
                    x.notes.push(format!("memory: no swap hog: {why}"));
                    x.stress.insert("swapHog".into(), json!(format!("not run: {why}")));
                }
            }
        }
        // The load: the clock starts at 90% of the target or at RAMP_MAX, whichever is first.
        let ramp = Instant::now();
        let by = ramp + RAMP_MAX;
        loop {
            let l = load1();
            if l.is_some_and(|l| l >= target * 0.9) || Instant::now() >= by {
                x.load_at_clock = l;
                break;
            }
            std::thread::sleep(Duration::from_secs(1));
        }
        x.ramp_secs = Some(ramp.elapsed().as_secs_f64());
        if x.load_at_clock.is_none_or(|l| l < target * 0.9) {
            x.notes.push(format!(
                "load: {} of target {target:.0} after {:.0}s ramp; the window ran at the load reached",
                x.load_at_clock.map_or("-".into(), |l| format!("{l:.1}")),
                RAMP_MAX.as_secs_f64()
            ));
        }
        x
    }

    pub(super) fn stop(&mut self) -> Vec<String> {
        let mut errs: Vec<String> =
            self.stressors.iter_mut().filter_map(|s| s.stop().err()).collect();
        if let Some(st) = self.starved.as_mut() {
            errs.extend(st.stop().1);
        }
        errs
    }
}

impl Window {
    pub(super) fn open(socket: &Path, daemon_pid: u32, wire: &Wire, log: &Path) -> Self {
        let cgroup = cgroup_dir(daemon_pid);
        Self {
            at: Instant::now(),
            forks: forks(),
            cpu: cpu_secs(daemon_pid),
            wire: wire.snapshot(),
            notices: notices(socket),
            links: link_gauges(socket),
            log_offset: std::fs::metadata(log).map_or(0, |m| m.len()),
            memory_high_events: cgroup.as_deref().and_then(|d| memory_event(d, "high")),
            cgroup,
        }
    }
}

/// Everything the window measured beside the ops, as fields for the leg's row.
#[allow(clippy::too_many_arguments)]
pub(super) fn close(
    w: Window,
    x: &Extras,
    presence: Presence,
    socket: &Path,
    daemon_pid: u32,
    wire: &Wire,
    proxy_ports: &BTreeSet<u16>,
    peer_names: &[String],
    log: &Path,
) -> serde_json::Map<String, Value> {
    let secs = w.at.elapsed().as_secs_f64().max(0.001);
    let (sockets, to_proxies) = daemon_links(daemon_pid, proxy_ports);
    let w1 = wire.snapshot();
    let cpu1 = cpu_secs(daemon_pid);
    let forks1 = forks();
    let notices_end = notices(socket);
    let logs = log_counts(log, w.log_offset, peer_names);
    let p = presence.thread.join().unwrap_or_default();
    let mut f = serde_json::Map::new();

    // Presence.
    let worst = p.peers.values().map(|t| t.worst_ms).fold(0.0, f64::max);
    let over: usize = p.peers.values().filter(|t| t.worst_ms > GAP_OVER_MS).count();
    let mut read_ms = p.read_ms.clone();
    read_ms.sort_by(f64::total_cmp);
    let q = |s: &[f64], at: f64| {
        (!s.is_empty()).then(|| s[((s.len() - 1) as f64 * at).round() as usize])
    };
    f.insert(
        "presenceGapMs".into(),
        json!({
            "worst": worst,
            "peersTracked": p.peers.len(),
            "peersOver2s": over,
            "sampleHz": p.reads as f64 / secs,
            "reads": p.reads,
            "readErrors": p.read_errors,
            "readP50Ms": q(&read_ms, 0.5), "readP95Ms": q(&read_ms, 0.95), "readMaxMs": read_ms.last(),
            "perPeer": p.peers.iter().map(|(n, t)| (n.clone(), json!({
                "worstMs": t.worst_ms, "gapsOver2s": t.gaps_over, "states": t.states,
            }))).collect::<serde_json::Map<_, _>>(),
        }),
    );
    // Drops and redials.
    let dials = w1[0] - w.wire[0];
    let per_peer: serde_json::Map<String, Value> = p
        .peers
        .iter()
        .map(|(n, t)| {
            let l = logs.get(n).copied().unwrap_or_default();
            (
                n.clone(),
                json!({"sampledDrops": t.drops, "stoppedAnswering": l[0], "silenceBudget": l[1],
                       "linkOpens": l[2]}),
            )
        })
        .collect();
    let sum = |i: usize| logs.values().map(|l| l[i]).sum::<u64>();
    f.insert(
        "linkDrops".into(),
        json!({
            "sampledDrops": p.peers.values().map(|t| t.drops).sum::<u64>(),
            "stoppedAnswering": sum(0), "silenceBudget": sum(1), "linkOpens": sum(2),
            "proxyDials": dials,
            "perPeer": per_peer,
        }),
    );
    // Links.
    f.insert(
        "peerLinks".into(),
        json!({
            "peers": peer_names.len(),
            "daemonTcpToProxies": to_proxies,
            "daemonSockets": sockets,
            "proxyLinksOpen": wire.open.load(Ordering::Relaxed),
            "proxyDialsTotal": w1[0],
        }),
    );
    let per_s = |i: usize| (w1[i] - w.wire[i]) as f64 / secs;
    f.insert(
        "wire".into(),
        json!({"framesPerSec": per_s(1), "pingsPerSec": per_s(2), "pongsPerSec": per_s(3),
               "dataPerSec": per_s(4), "bytesPerSec": per_s(5), "quiet": x.quiet}),
    );
    if let Some(st) = &x.starved {
        f.insert("starved".into(), st.report());
    }
    // Notices.
    let notices_json = match (&w.notices, &notices_end) {
        (Ok(a), Ok(b)) => {
            let d = |k: &str| b[k].as_u64().zip(a[k].as_u64()).map(|(b, a)| b.saturating_sub(a));
            json!({"applied": d("applied"), "busyMs": d("busyMs"), "maxUsEnd": b["maxUs"],
                   "peakQueuedStart": a["peakQueued"], "peakQueuedEnd": b["peakQueued"]})
        }
        (a, b) => json!({"error": format!("{:?} / {:?}", a.as_ref().err(), b.as_ref().err())}),
    };
    f.insert("peerNotices".into(), notices_json);
    // The daemon's own link gauges (cmux `gauges.links`), when this build has them.
    f.insert(
        "statusLinks".into(),
        match (&w.links, link_gauges(socket)) {
            (Some(a), Some(b)) => {
                let delta: serde_json::Map<String, Value> = b
                    .as_object()
                    .into_iter()
                    .flatten()
                    .filter_map(|(k, v)| {
                        Some((k.clone(), json!(v.as_i64()? - a.get(k)?.as_i64()?)))
                    })
                    .collect();
                json!({"start": a, "end": b, "delta": delta})
            }
            _ => json!("not in this build's _acpmux/status (no gauges.links)"),
        },
    );
    // Spawns.
    f.insert(
        "spawns".into(),
        json!({
            "hostPerSec": w.forks.zip(forks1).map(|(a, b)| (b - a) as f64 / secs),
            "daemonTreeSeen": p.seen.len(),
            "daemonTreeSeenNote": "descendants of the daemon seen at 1 Hz: a lower bound",
        }),
    );
    f.insert(
        "daemonCpu".into(),
        json!({"windowPct": w.cpu.zip(cpu1).map(|(a, b)| (b - a) / secs * 100.0)}),
    );
    let mut loads = p.load1.clone();
    loads.sort_by(f64::total_cmp);
    f.insert(
        "load".into(),
        json!({
            "target": x.stress.get("loadTarget"),
            "atClock": x.load_at_clock,
            "rampSecs": x.ramp_secs,
            "min": loads.first(), "p50": q(&loads, 0.5), "max": loads.last(),
        }),
    );
    let high_end = w.cgroup.as_deref().and_then(|d| memory_event(d, "high"));
    f.insert(
        "memory".into(),
        json!({
            "daemonRssKibMax": p.daemon_rss_kib_max,
            "daemonCgroup": w.cgroup.as_ref().map(|c| c.display().to_string()),
            "memoryHighEvents": w.memory_high_events.zip(high_end).map(|(a, b)| b.saturating_sub(a)),
            "daemonCgroupMemoryPsiAvg10Max": p.memory_psi_max,
            "swapUsedKibBefore": x.swap_before_kib,
            "swapUsedKibMax": p.swap_used_kib_max,
            "swapTotalKib": meminfo_kib("SwapTotal"),
        }),
    );
    f.insert("cgroup".into(), p.cg.report());
    f.insert(
        "phoneLink".into(),
        json!(
            "not measured: the hub carrier needs a platform ticket (POST /v1/mesh/carrier), the \
             Cloud relay and Noise node keys; no hermetic stand-in exists in this crate yet"
        ),
    );
    f
}

/// One agent tool call as an agent's Bash tool makes it: a shell running a short pipeline in
/// the work folder, timed from spawn to exit. The stand-in agent (`fake_agent.py`) reports tool
/// calls without running a process, so this is the bench's stand-in for one.
pub(super) fn tool_call(cwd: &Path) -> Ran {
    let mut cmd = Command::new("/bin/sh");
    cmd.args(["-c", "ls -a . | head -n 5 >/dev/null && cat /proc/loadavg >/dev/null"])
        .current_dir(cwd);
    run_command(cmd)
}

/// The peer rows a leg can send to: up to five, from distinct peers not cut, as
/// (`peerNN/NAME` for the CLI, its session id for the socket).
pub(super) fn peer_targets(
    before: &BTreeMap<String, Value>,
    cut: &BTreeSet<String>,
) -> Vec<(String, String)> {
    let mut seen = BTreeSet::new();
    before
        .values()
        .filter_map(|r| {
            let peer = r["peer"].as_str().filter(|p| !p.is_empty() && !cut.contains(*p))?;
            let name = r["name"].as_str()?;
            let id = r["sessionId"].as_str()?;
            seen.insert(peer.to_owned()).then(|| (format!("{peer}/{name}"), id.to_owned()))
        })
        .take(5)
        .collect()
}

fn pct(row: &Value, op: &str, via: &str, key: &str) -> Option<f64> {
    row["ops"].as_array()?.iter().find(|o| o["op"] == op && o["via"] == via)?[key].as_f64()
}

/// The new numbers in one line, appended to the leg's `summary`.
pub(super) fn summary_tail(row: &Value) -> String {
    let ms = |v: Option<f64>| v.map_or("-".into(), |m| format!("{m:.0}ms"));
    let n = |v: &Value| v.as_f64().map_or("-".into(), |m| format!("{m:.1}"));
    format!(
        "; load max {} (target {}); presence gap worst {} ({} of {} peers over 2s); link drops \
         {} (stopped-answering {}, dials {}); send p50/p95 local {}/{} peer {}/{}; peer links {} \
         ({} frames/s); notices peak queue {}; spawns {}/s; tool call p95 {}{}",
        n(&row["load"]["max"]),
        n(&row["load"]["target"]),
        ms(row["presenceGapMs"]["worst"].as_f64()),
        row["presenceGapMs"]["peersOver2s"],
        row["presenceGapMs"]["peersTracked"],
        row["linkDrops"]["sampledDrops"],
        row["linkDrops"]["stoppedAnswering"],
        row["linkDrops"]["proxyDials"],
        ms(pct(row, "send", "cli", "p50Ms")),
        ms(pct(row, "send", "cli", "p95Ms")),
        ms(pct(row, "send-peer", "cli", "p50Ms")),
        ms(pct(row, "send-peer", "cli", "p95Ms")),
        row["peerLinks"]["daemonTcpToProxies"],
        n(&row["wire"]["framesPerSec"]),
        row["peerNotices"]["peakQueuedEnd"],
        n(&row["spawns"]["hostPerSec"]),
        ms(pct(row, "toolcall", "cli", "p95Ms")),
        row.get("starved").map_or(String::new(), |s| format!(
            "; starved: {} on {} cpus, {} loops/core, daemon run-queue wait {} ms/s, memory.high {} ({} events), stall {}ms every {}s",
            s["cpu"]["how"].as_str().unwrap_or("-"),
            s["cpu"]["cpus"].as_array().map_or(0, Vec::len),
            n(&s["cpu"]["loopsPerDaemonCore"]),
            n(&s["daemonRunqueueWaitMsPerSec"]),
            if s["cgroup"]["applied"].as_bool() == Some(true) { s["cgroup"]["memoryHigh"].as_str().unwrap_or("-") } else { "not applied" },
            s["cgroup"]["memoryHighEvents"],
            s["network"]["stallMs"],
            s["network"]["stallEverySecs"],
        )),
    )
}

/// The duress measures table, one row a leg.
pub(super) fn markdown(report: &Value) -> String {
    let mut md = String::from(
        "\n| leg | peers | load max (target) | presence gap worst ms | peers >2s | drops (stopped-answering, dials) | send p50/p95 local | send p50/p95 peer | daemon TCP to peers | frames/s (quiet) | idle cpu % | notices applied, peak queue | spawns/s | tool call p50/p95 | swap used max MiB | memory.high events | phone link |\n|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|\n",
    );
    let f = |v: &Value| v.as_f64().map_or("-".into(), |m| format!("{m:.0}"));
    let f1 = |v: &Value| v.as_f64().map_or("-".into(), |m| format!("{m:.1}"));
    for leg in report["legs"].as_array().into_iter().flatten() {
        if leg.get("error").is_some() || leg.get("presenceGapMs").is_none() {
            continue;
        }
        let pp = |op: &str| {
            format!(
                "{}/{}",
                pct(leg, op, "cli", "p50Ms").map_or("-".into(), |m| format!("{m:.0}")),
                pct(leg, op, "cli", "p95Ms").map_or("-".into(), |m| format!("{m:.0}"))
            )
        };
        let quiet = &leg["wire"]["quiet"];
        md.push_str(&format!(
            "| {} | {} | {} ({}) | {} | {} | {} ({}, {}) | {} | {} | {} | {} ({}) | {} | {}, {} | {} | {} | {} | {} | {} |\n",
            leg["leg"].as_str().unwrap_or(""),
            leg["peerLinks"]["peers"],
            f1(&leg["load"]["max"]),
            f(&leg["load"]["target"]),
            f(&leg["presenceGapMs"]["worst"]),
            leg["presenceGapMs"]["peersOver2s"],
            leg["linkDrops"]["sampledDrops"],
            leg["linkDrops"]["stoppedAnswering"],
            leg["linkDrops"]["proxyDials"],
            pp("send"),
            pp("send-peer"),
            leg["peerLinks"]["daemonTcpToProxies"],
            f1(&leg["wire"]["framesPerSec"]),
            f1(&quiet["framesPerSec"]),
            f1(&quiet["daemonCpuPct"]),
            leg["peerNotices"]["applied"],
            leg["peerNotices"]["peakQueuedEnd"],
            f1(&leg["spawns"]["hostPerSec"]),
            pp("toolcall"),
            leg["memory"]["swapUsedKibMax"].as_u64().map_or("-".into(), |k| (k >> 10).to_string()),
            leg["memory"]["memoryHighEvents"],
            leg["phoneLink"].as_str().map_or("-", |s| if s.starts_with("not measured") { "not measured" } else { s }),
        ));
    }
    md
}

#[cfg(test)]
#[path = "duress_host150_unit_tests.rs"]
mod unit;
