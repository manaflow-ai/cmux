//! What the daemon pays for each remote session attached to it, at 50, 200 and 2,000 (2026-11-19).
//! Leo: "a couple thousand fucking sessions across VMs talking to Cosmic Gray ... Whatever's
//! missing, whatever tools should be built, you build them." The goal: at 2,000 remote sessions
//! the daemon's attach p95, fan-out p95, CPU and RSS within 1.2x of their value at 50.
//!
//! For each N in `ACPMUX_SCALE_NS` (default `50,200,2000`), a real daemon over a small home is
//! linked to `ceil(N / ACPMUX_SCALE_PER_PEER)` peers (default 10 rows a peer, as a lane VM carries
//! a few sessions; `ACPMUX_SCALE_PEERS` fixes the peer count instead), each a hub in this process
//! served over WebSocket, N rows in all. A client watches the list as the app does, reading every
//! notice. Then:
//!
//! - `listMs`: from the daemon's spawn until every peer is linked and every row listed;
//! - an idle window (`ACPMUX_SCALE_IDLE_SECS`, default 10): the daemon's CPU with no row
//!   changing, what per-session timers cost (`idleCpuPct`);
//! - a churn window (`ACPMUX_SCALE_SECS`, default 30): every row changes once every
//!   [`CHURN_EVERY_MS`] (a `tags` record on its peer's hub, as a live agent's row changes), the
//!   same rate per session at every N, so the total rate grows with N. Over it: the daemon's CPU
//!   (`churnCpuPct`, and per row change `cpuUsPerChange`), its RSS each second (`rssSteady`: the
//!   median, `peakRss`: VmHWM), the fan-out latency of probe changes (a `rules` record on one
//!   row, from the peer hub's call until the watching client reads its `_acpmux/session_changed`:
//!   `fanoutUs`), the attach of a local chat (`attachLocalUs`) and of a remote row
//!   (`attachRemoteUs`) on another connection, `ACPMUX_SCALE_PROBES` times each (default 30);
//! - a whole-list read on a fresh connection after the churn (`relistMs`, `relistBytes`): what
//!   each `acpmux ls`-style re-read costs at N.
//!
//! It prints one `SCALE-ROW {json}` per N, then a table and `SCALE-RATIO` lines against the first
//! N. Manual, on Linux CI:
//! `cargo test -p acpmux --release --test sessions_scale -- --ignored --nocapture`.
//! `ACPMUX_GOD_DAEMON_BIN` runs another daemon binary (a before/after control).
// The results' `json!` has more keys than the default limit expands, as in `god_daemon.rs`.
#![recursion_limit = "256"]
#![cfg(target_os = "linux")]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// No prompt is sent; the knobs hold no credential.
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in().keep(&[
    "ACPMUX_SCALE_NS",
    "ACPMUX_SCALE_PER_PEER",
    "ACPMUX_SCALE_PEERS",
    "ACPMUX_SCALE_SECS",
    "ACPMUX_SCALE_IDLE_SECS",
    "ACPMUX_SCALE_PROBES",
    "ACPMUX_GOD_DAEMON_BIN",
]);

use acpmux::config::{Config, StoreMode};
use acpmux::god_fixture::{self, Shape};
use acpmux::hub::{Hub, Session};
use acpmux::server::peer_auth::PeerAuth;
use acpmux::server::{WsAuth, bind_ws, serve_ws_with};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::io::{BufRead, BufReader, ErrorKind, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// Each remote session's row changes once this often, at every N: a live agent's turn, status
/// or title. The total rate is N / this.
const CHURN_EVERY_MS: u64 = 3_000;

/// How long any one step may take before the run says so.
const STEP: Duration = Duration::from_secs(600);

/// A page as the pane asks for one.
const PAGE_LIMIT: u64 = 400;
const PAGE_BYTES: u64 = 131072;

fn env_or<T: std::str::FromStr>(name: &str, default: T) -> T {
    std::env::var(name).ok().and_then(|v| v.parse().ok()).unwrap_or(default)
}

/// p50, p95 and max of `samples`, null when there are none.
fn spread(samples: &[u64]) -> Value {
    if samples.is_empty() {
        return Value::Null;
    }
    let mut sorted = samples.to_vec();
    sorted.sort_unstable();
    let at = |q: f64| sorted[((sorted.len() - 1) as f64 * q).round() as usize];
    json!({"n": sorted.len(), "p50": at(0.5), "p95": at(0.95), "max": sorted[sorted.len() - 1]})
}

/// A line client on the daemon's socket for requests; notifications it reads are dropped.
struct Rpc {
    reader: BufReader<UnixStream>,
    writer: UnixStream,
    next: u64,
    read_bytes: u64,
}

impl Rpc {
    fn connect(path: &Path, name: &str) -> Self {
        let s = UnixStream::connect(path).expect("connect to the daemon's socket");
        s.set_read_timeout(Some(STEP)).unwrap();
        let reader = BufReader::new(s.try_clone().unwrap());
        let mut rpc = Self { reader, writer: s, next: 0, read_bytes: 0 };
        rpc.call("initialize", json!({"protocolVersion": 1, "clientInfo": {"name": name}}))
            .unwrap();
        rpc
    }

    fn call(&mut self, method: &str, params: Value) -> Result<Value, Value> {
        self.next += 1;
        let id = self.next;
        let line = json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params});
        self.writer.write_all(format!("{line}\n").as_bytes()).unwrap();
        let mut buf = Vec::new();
        loop {
            buf.clear();
            let n = self.reader.read_until(b'\n', &mut buf).unwrap();
            assert!(n > 0, "the daemon closed the socket");
            self.read_bytes += n as u64;
            let v: Value = serde_json::from_slice(&buf).unwrap();
            if v.get("method").is_none() && v.get("id") == Some(&json!(id)) {
                return match v.get("error") {
                    Some(e) => Err(e.clone()),
                    None => Ok(v["result"].clone()),
                };
            }
        }
    }
}

/// The watching client's counts, shared with the thread that reads its connection.
#[derive(Default)]
struct Watched {
    /// Probe rows changed and not yet heard, by session id: when the change was made.
    probes: Mutex<HashMap<String, Instant>>,
    fanout_us: Mutex<Vec<u64>>,
    notices: AtomicU64,
    notice_bytes: AtomicU64,
    dropped: AtomicU64,
    stop: AtomicBool,
}

/// The app's list: a connection that watches and reads every line until `stop`. Returns once its
/// watch is answered, with the reply's bytes.
fn watch(socket: &Path, watched: Arc<Watched>) -> (std::thread::JoinHandle<()>, u64) {
    let s = UnixStream::connect(socket).unwrap();
    s.set_read_timeout(Some(Duration::from_millis(200))).unwrap();
    let mut writer = s.try_clone().unwrap();
    let mut reader = BufReader::new(s);
    for (id, method, params) in [
        (1, "initialize", json!({"protocolVersion": 1, "clientInfo": {"name": "scale-watch"}})),
        (2, "_acpmux/watch", json!({"enabled": true})),
    ] {
        let line = json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params});
        writer.write_all(format!("{line}\n").as_bytes()).unwrap();
    }
    let started = Instant::now();
    let mut buf = Vec::new();
    let reply_bytes = loop {
        match reader.read_until(b'\n', &mut buf) {
            Ok(0) => panic!("the daemon closed the watch"),
            Ok(_) if buf.ends_with(b"\n") => {
                let len = buf.len() as u64;
                let v: Value = serde_json::from_slice(&buf).unwrap();
                buf.clear();
                if v.get("method").is_none() && v["id"] == 2 {
                    break len;
                }
            }
            Ok(_) => {}
            Err(e) if matches!(e.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut) => {
                assert!(started.elapsed() < STEP, "no watch reply");
            }
            Err(e) => panic!("watch: {e}"),
        }
    };
    let thread = std::thread::spawn(move || {
        let mut buf = Vec::new();
        while !watched.stop.load(Ordering::Relaxed) {
            match reader.read_until(b'\n', &mut buf) {
                Ok(0) => return,
                Ok(_) if buf.ends_with(b"\n") => {
                    let heard = Instant::now();
                    let len = buf.len() as u64;
                    let v: Value = serde_json::from_slice(&buf).unwrap_or_default();
                    buf.clear();
                    if v["method"] == "_acpmux/lagged" {
                        let n = v["params"]["dropped"].as_u64().unwrap_or(0);
                        watched.dropped.fetch_add(n, Ordering::Relaxed);
                        continue;
                    }
                    if v["method"] != "_acpmux/session_changed" || v["params"]["peer"].is_null() {
                        continue;
                    }
                    watched.notices.fetch_add(1, Ordering::Relaxed);
                    watched.notice_bytes.fetch_add(len, Ordering::Relaxed);
                    if v["params"]["recordKind"] == "rules"
                        && let Some(id) = v["params"]["sessionId"].as_str()
                        && let Some(at) = watched.probes.lock().unwrap().remove(id)
                    {
                        let us = heard.duration_since(at).as_micros() as u64;
                        watched.fanout_us.lock().unwrap().push(us);
                    }
                }
                Ok(_) => {}
                Err(e) if matches!(e.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut) => {}
                Err(_) => return,
            }
        }
    });
    (thread, reply_bytes)
}

/// One peer: its hub (rows in memory, served over WebSocket) and its rows.
struct Peer {
    name: String,
    hub: Arc<Hub>,
    rows: Vec<Arc<Session>>,
}

/// `counts.len()` peers, peer `p` listing `counts[p]` rows: the daemon's `peers` config and them.
async fn peers(counts: &[usize], scratch: &Path) -> (Value, Vec<Peer>) {
    let (mut config, mut peers) = (serde_json::Map::new(), vec![]);
    for (p, &rows) in counts.iter().enumerate() {
        let name = format!("peer{p:03}");
        let mut cfg = Config::default();
        cfg.store.mode = StoreMode::Memory;
        let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
        for i in 0..rows {
            store.save(&serde_json::from_value(god_fixture::peer_meta(&name, i)).unwrap()).unwrap();
        }
        let hub = Hub::new(cfg, store);
        let home = scratch.join(format!("peer-{p}"));
        std::fs::create_dir_all(&home).unwrap();
        let auth = PeerAuth::create(&home).unwrap();
        let token = std::fs::read_to_string(acpmux::server::peer_auth::token_path(&home)).unwrap();
        let listener = bind_ws("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let auth = WsAuth { local_app: None, peer: Some(Arc::new(auth)) };
        tokio::spawn(serve_ws_with(hub.clone(), listener, "tok".into(), auth));
        config.insert(
            name.clone(),
            json!({"url": format!("ws://127.0.0.1:{port}"), "token": "tok",
                   "peerToken": token.trim()}),
        );
        let mut sessions = hub.sessions();
        sessions.sort_by(|a, b| a.id.cmp(&b.id));
        peers.push(Peer { name, hub, rows: sessions });
    }
    (Value::Object(config), peers)
}

struct Daemon {
    child: Child,
    socket: PathBuf,
    spawned: Instant,
}

impl Daemon {
    fn start(scratch: &Path, home: &Path) -> Self {
        let socket = scratch.join("s.sock");
        let mut command = match std::env::var_os("ACPMUX_GOD_DAEMON_BIN") {
            Some(bin) => {
                daemon_env::command_at(Path::new(&bin), scratch, daemon_env::Agents::StandIn, &[])
            }
            None => daemon_env::command(scratch, daemon_env::Agents::StandIn, &[]),
        };
        command
            .args(["daemon", "run", "--log", "warn"])
            .env("ACPMUX_HOME", home)
            .env("ACPMUX_SOCKET", &socket)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::inherit());
        let spawned = Instant::now();
        let mut child = command.spawn().unwrap();
        while UnixStream::connect(&socket).is_err() {
            if spawned.elapsed() >= STEP || child.try_wait().unwrap().is_some() {
                let _ = child.kill();
                let _ = child.wait();
                panic!("the daemon did not bind its socket");
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        Self { child, socket, spawned }
    }

    /// User and system CPU seconds so far (`/proc/PID/stat` fields 14 and 15).
    fn cpu_seconds(&self) -> f64 {
        let stat =
            std::fs::read_to_string(format!("/proc/{}/stat", self.child.id())).unwrap_or_default();
        let rest = stat.rsplit_once(')').map_or("", |(_, r)| r);
        let fields: Vec<&str> = rest.split_whitespace().collect();
        let field = |n: usize| fields.get(n - 3).and_then(|f| f.parse::<u64>().ok()).unwrap_or(0);
        // SAFETY: sysconf reads a constant.
        let hz = unsafe { libc::sysconf(libc::_SC_CLK_TCK) }.max(1);
        (field(14) + field(15)) as f64 / hz as f64
    }

    /// `VmRSS` and `VmHWM`, in bytes.
    fn rss(&self) -> (u64, u64) {
        let status = std::fs::read_to_string(format!("/proc/{}/status", self.child.id()))
            .unwrap_or_default();
        let field = |name: &str| {
            status
                .lines()
                .find(|l| l.starts_with(name))
                .and_then(|l| l.split_whitespace().nth(1))
                .and_then(|kib| kib.parse::<u64>().ok())
                .map_or(0, |kib| kib * 1024)
        };
        (field("VmRSS:"), field("VmHWM:"))
    }

    fn threads(&self) -> u64 {
        std::fs::read_dir(format!("/proc/{}/task", self.child.id())).map_or(0, |d| d.count() as u64)
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// Every peer linked and `rows` remote sessions listed.
fn listed(rpc: &mut Rpc, peers: usize, rows: usize) -> bool {
    let Ok(status) = rpc.call("_acpmux/status", json!({})) else { return false };
    let connected = status["peers"]
        .as_array()
        .map_or(0, |p| p.iter().filter(|p| p["connected"] == true).count());
    connected == peers && status["remoteSessions"].as_u64().unwrap_or(0) as usize >= rows
}

fn write_config(home: &Path, peers: Value) {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let config = json!({
        "peers": peers,
        "harnesses": {"claude": {"argv": ["python3", fake]}},
        "defaultHarness": "claude",
        "permissionPolicy": "approve-all",
    });
    std::fs::write(home.join("config.json"), config.to_string()).unwrap();
}

/// Rows per peer for `n` rows: `ACPMUX_SCALE_PEERS` peers, or `ACPMUX_SCALE_PER_PEER` rows each.
fn shape(n: usize) -> Vec<usize> {
    let peers = match std::env::var("ACPMUX_SCALE_PEERS").ok().and_then(|v| v.parse().ok()) {
        Some(p) => p,
        None => n.div_ceil(env_or("ACPMUX_SCALE_PER_PEER", 10usize).max(1)),
    };
    let peers: usize = peers.clamp(1, n.max(1));
    (0..peers).map(|p| n / peers + usize::from(p < n % peers)).collect()
}

/// One N's run.
async fn run(n: usize) -> Value {
    let idle_secs: u64 = env_or("ACPMUX_SCALE_IDLE_SECS", 10);
    let churn_secs: u64 = env_or("ACPMUX_SCALE_SECS", 30);
    let probes: usize = env_or("ACPMUX_SCALE_PROBES", 30);
    let scratch = daemon_env::Scratch::new(&format!("scale-{n}"));
    let home = scratch.join("acpmux");
    let claude = daemon_env::home(&scratch).join(".claude");
    let small = Shape { name: "scale", peers: 0, ..Shape::small() };
    let made = god_fixture::write_home(&home, &claude, &scratch.join("work"), &small).unwrap();
    let counts = shape(n);
    let (config, peers) = peers(&counts, &scratch).await;
    write_config(&home, config);
    let peers = Arc::new(peers);
    let peer_count = counts.len();

    let daemon = Daemon::start(&scratch, &home);
    let watched = Arc::new(Watched::default());
    let (watcher, first_list_bytes) = watch(&daemon.socket, watched.clone());
    let socket = daemon.socket.clone();
    let god = made.god.clone();
    let list_ms = {
        let spawned = daemon.spawned;
        tokio::task::spawn_blocking(move || {
            let mut rpc = Rpc::connect(&socket, "scale-control");
            while spawned.elapsed() < STEP {
                if listed(&mut rpc, peer_count, n) {
                    return Some(spawned.elapsed().as_millis() as u64);
                }
                std::thread::sleep(Duration::from_millis(100));
            }
            None
        })
        .await
        .unwrap()
    };
    // The lists' flood ends before the windows start.
    tokio::time::sleep(Duration::from_secs(5)).await;
    let listed_notices = watched.notices.load(Ordering::Relaxed);

    // Idle: no row changes.
    let (rss_listed, _) = daemon.rss();
    let cpu0 = daemon.cpu_seconds();
    tokio::time::sleep(Duration::from_secs(idle_secs)).await;
    let idle_cpu = daemon.cpu_seconds() - cpu0;

    // Churn: each peer changes its rows round robin, one every CHURN_EVERY_MS / rows.
    let stop = Arc::new(AtomicBool::new(false));
    let changes = Arc::new(AtomicU64::new(0));
    let churners: Vec<_> = (0..peers.len())
        .map(|p| {
            let (peers, stop, changes) = (peers.clone(), stop.clone(), changes.clone());
            tokio::spawn(async move {
                let peer = &peers[p];
                if peer.rows.is_empty() {
                    return;
                }
                let every = Duration::from_micros(CHURN_EVERY_MS * 1000 / peer.rows.len() as u64);
                // Peers start spread over one interval, not all at once.
                let offset = every.mul_f64(p as f64 / peers.len() as f64);
                tokio::time::sleep(offset).await;
                let mut tick = tokio::time::interval(every);
                tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
                let mut i = 0u64;
                while !stop.load(Ordering::Relaxed) {
                    tick.tick().await;
                    let row = &peer.rows[i as usize % peer.rows.len()];
                    let mut set = serde_json::Map::new();
                    set.insert("tick".into(), json!(i));
                    peer.hub.set_tags(row, Some(&set), &[], None);
                    changes.fetch_add(1, Ordering::Relaxed);
                    i += 1;
                }
            })
        })
        .collect();
    let cpu1 = daemon.cpu_seconds();
    let changes0 = changes.load(Ordering::Relaxed);
    let notices0 = watched.notices.load(Ordering::Relaxed);
    let churn_started = Instant::now();

    // Probes, attaches and RSS samples, spread over the window.
    let socket = daemon.socket.clone();
    let pid = daemon.child.id();
    let (probe_peers, probe_watched) = (peers.clone(), watched.clone());
    let sampled = tokio::task::spawn_blocking(move || {
        let mut rpc = Rpc::connect(&socket, "scale-attach");
        let gap = Duration::from_secs(churn_secs) / probes.max(1) as u32;
        let (mut local, mut remote, mut rss) = (vec![], vec![], vec![]);
        let (mut local_errors, mut remote_errors, mut remote_error) = (0u64, 0u64, Value::Null);
        for k in 0..probes {
            let round = Instant::now();
            // A change of one row, on peer k, never the same row twice in a row.
            let peer = &probe_peers[k % probe_peers.len()];
            let row = &peer.rows[(k / probe_peers.len()) % peer.rows.len()];
            probe_watched.probes.lock().unwrap().insert(row.id.clone(), Instant::now());
            peer.hub.set_rules(row, Some(json!({"probe": k})));
            let at = Instant::now();
            let reply = rpc.call(
                "_acpmux/attach",
                json!({"sessionId": god, "waitLogs": false, "limit": PAGE_LIMIT,
                       "maxBytes": PAGE_BYTES}),
            );
            match reply {
                Ok(_) => local.push(at.elapsed().as_micros() as u64),
                Err(_) => local_errors += 1,
            }
            let id = format!("{}/{}", peer.name, row.id);
            let at = Instant::now();
            let reply = rpc.call(
                "_acpmux/attach",
                json!({"sessionId": id, "waitLogs": false, "limit": PAGE_LIMIT,
                       "maxBytes": PAGE_BYTES, "visible": false}),
            );
            match reply {
                Ok(_) => remote.push(at.elapsed().as_micros() as u64),
                Err(e) => {
                    remote_errors += 1;
                    if remote_error.is_null() {
                        remote_error = e;
                    }
                }
            }
            let status = std::fs::read_to_string(format!("/proc/{pid}/status")).unwrap_or_default();
            if let Some(kib) = status
                .lines()
                .find(|l| l.starts_with("VmRSS:"))
                .and_then(|l| l.split_whitespace().nth(1)?.parse::<u64>().ok())
            {
                rss.push(kib * 1024);
            }
            std::thread::sleep(gap.saturating_sub(round.elapsed()));
        }
        (rpc, local, remote, local_errors, remote_errors, remote_error, rss)
    })
    .await
    .unwrap();
    let (mut rpc, local, remote, local_errors, remote_errors, remote_error, rss_samples) = sampled;
    let churn_s = churn_started.elapsed().as_secs_f64();
    let churn_cpu = daemon.cpu_seconds() - cpu1;
    let churn_changes = changes.load(Ordering::Relaxed) - changes0;
    stop.store(true, Ordering::Relaxed);
    for c in churners {
        let _ = c.await;
    }
    // Probes still in flight a second on are lost.
    tokio::time::sleep(Duration::from_secs(1)).await;
    let churn_notices = watched.notices.load(Ordering::Relaxed) - notices0;
    let lost_probes = watched.probes.lock().unwrap().len();

    // A fresh client reads the whole list, as `acpmux ls` does.
    let relist = {
        let socket = daemon.socket.clone();
        tokio::task::spawn_blocking(move || {
            let mut fresh = Rpc::connect(&socket, "scale-relist");
            let before = fresh.read_bytes;
            let at = Instant::now();
            let reply = fresh.call("_acpmux/sessions", json!({}));
            let ms = at.elapsed().as_millis() as u64;
            let rows = reply.as_ref().ok().and_then(|r| r["sessions"].as_array().map(Vec::len));
            (ms, fresh.read_bytes - before, rows)
        })
        .await
        .unwrap()
    };
    let status = rpc.call("_acpmux/status", json!({})).unwrap_or_default();
    let (rss_end, peak_rss) = daemon.rss();
    let threads = daemon.threads();
    watched.stop.store(true, Ordering::Relaxed);
    drop(daemon);
    let _ = watcher.join();

    let mut steady = rss_samples.clone();
    steady.sort_unstable();
    let rss_steady = steady.get(steady.len() / 2).copied().unwrap_or(rss_end);
    let fanout = watched.fanout_us.lock().unwrap().clone();
    let pct = |cpu: f64, secs: f64| (cpu / secs * 1000.0).round() / 10.0;
    json!({
        "n": n, "peers": peer_count, "rowsPerPeer": counts.iter().max(),
        "churnEveryMs": CHURN_EVERY_MS, "churnSecs": churn_s,
        "listMs": list_ms, "firstListBytes": first_list_bytes,
        "listedNotices": listed_notices,
        "idleCpuPct": pct(idle_cpu, idle_secs as f64),
        "churnCpuPct": pct(churn_cpu, churn_s),
        "churnChanges": churn_changes,
        "changesPerSec": (churn_changes as f64 / churn_s).round(),
        "cpuUsPerChange": (churn_cpu * 1e6 / churn_changes.max(1) as f64).round(),
        "churnNotices": churn_notices,
        "noticesDropped": watched.dropped.load(Ordering::Relaxed),
        "noticeBytes": watched.notice_bytes.load(Ordering::Relaxed),
        "rssListed": rss_listed, "rssSteady": rss_steady, "rssEnd": rss_end, "peakRss": peak_rss,
        "threads": threads,
        "fanoutUs": spread(&fanout), "lostProbes": lost_probes,
        "attachLocalUs": spread(&local), "attachLocalErrors": local_errors,
        "attachRemoteUs": spread(&remote), "attachRemoteErrors": remote_errors,
        "attachRemoteError": remote_error,
        "relistMs": relist.0, "relistBytes": relist.1, "relistRows": relist.2,
        "listReplies": status["listReplies"],
        "peerLists": status["gauges"]["peerLists"],
    })
}

/// One N's row in the shape the multi-VM fan-in bench (`coord-sim fanin`) prints too.
fn row_line(r: &Value, base: Option<&Value>) -> Value {
    let mb = |v: &Value| v.as_f64().map(|b| (b / 1_048_576.0 * 10.0).round() / 10.0);
    let ms = |v: &Value| v.as_f64().map(|us| (us / 100.0).round() / 10.0);
    let mut line = json!({
        "n": r["n"],
        "peers": r["peers"],
        "rows_per_peer": r["rowsPerPeer"],
        "churn_every_ms": CHURN_EVERY_MS,
        "daemon_rss_mb": {"steady": mb(&r["rssSteady"]), "peak": mb(&r["peakRss"])},
        "daemon_cpu_pct": r["churnCpuPct"],
        "daemon_idle_cpu_pct": r["idleCpuPct"],
        "cpu_us_per_change": r["cpuUsPerChange"],
        "attach_p95_ms": ms(&r["attachLocalUs"]["p95"]),
        "attach_remote_p95_ms": ms(&r["attachRemoteUs"]["p95"]),
        "fanout_p95_ms": ms(&r["fanoutUs"]["p95"]),
        "relist_ms": r["relistMs"],
        "relist_bytes": r["relistBytes"],
    });
    if let Some(b) = base {
        let ratio = |k: &str| match (
            line.pointer(k).and_then(Value::as_f64),
            b.pointer(k).and_then(Value::as_f64),
        ) {
            (Some(x), Some(y)) if y > 0.0 => json!((x / y * 100.0).round() / 100.0),
            _ => Value::Null,
        };
        let keys = [
            "/daemon_rss_mb/steady",
            "/daemon_rss_mb/peak",
            "/daemon_cpu_pct",
            "/daemon_idle_cpu_pct",
            "/cpu_us_per_change",
            "/attach_p95_ms",
            "/attach_remote_p95_ms",
            "/fanout_p95_ms",
            "/relist_ms",
            "/relist_bytes",
        ];
        let ratios: serde_json::Map<String, Value> =
            keys.iter().map(|k| (k[1..].replace('/', "."), ratio(k))).collect();
        line["ratio_vs_50"] = Value::Object(ratios);
    }
    line
}

#[tokio::test(flavor = "multi_thread", worker_threads = 8)]
#[ignore = "manual: minutes of churn over thousands of rows; run on Linux CI"]
async fn daemon_cost_per_attached_remote_session() {
    let ns = std::env::var("ACPMUX_SCALE_NS").unwrap_or_else(|_| "50,200,2000".to_owned());
    let mut results = vec![];
    for n in ns.split(',').map(|n| n.trim().parse::<usize>().expect("ACPMUX_SCALE_NS")) {
        let result = run(n).await;
        println!("SCALE-RESULT {result}");
        results.push(result);
    }
    let mut lines = vec![];
    for r in &results {
        let base = lines.first().map(|l: &Value| l.clone());
        let line = row_line(r, base.as_ref());
        println!("SCALE-ROW {line}");
        lines.push(line);
    }
    println!(
        "SCALE-TABLE {:>5} {:>5} {:>8} {:>8} {:>7} {:>7} {:>8} {:>9} {:>9} {:>9} {:>9}",
        "n",
        "peers",
        "rssMB",
        "peakMB",
        "cpu%",
        "idle%",
        "us/chg",
        "attachP95",
        "remoteP95",
        "fanoutP95",
        "relistMs"
    );
    for l in &lines {
        println!(
            "SCALE-TABLE {:>5} {:>5} {:>8} {:>8} {:>7} {:>7} {:>8} {:>9} {:>9} {:>9} {:>9}",
            l["n"],
            l["peers"],
            l["daemon_rss_mb"]["steady"],
            l["daemon_rss_mb"]["peak"],
            l["daemon_cpu_pct"],
            l["daemon_idle_cpu_pct"],
            l["cpu_us_per_change"],
            l["attach_p95_ms"],
            l["attach_remote_p95_ms"],
            l["fanout_p95_ms"],
            l["relist_ms"],
        );
    }
    for l in lines.iter().skip(1) {
        println!("SCALE-RATIO n={} {}", l["n"], l["ratio_vs_50"]);
    }
}
