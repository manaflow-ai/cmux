//! The daemon's resident memory under synthetic load, round by round (2026-11-19). On huge-blue the
//! production daemon reached 25 GB RSS and 110% CPU after 19 h while its host drained sessions:
//! about 700 sessions on disk, heavy `acpmux send` traffic between sessions (lanes reporting to
//! coordinators), peer daemons reading its list and GUI clients watching. Growth there follows
//! operations or uptime, not sessions; this harness names which operations.
//!
//! The real daemon runs over a `god_fixture` home of `ACPMUX_RSS_SESSIONS` chats (200), with
//! `ACPMUX_RSS_PEERS` peers it reads (in-process hubs of `ACPMUX_RSS_PEER_ROWS` rows), one peer
//! configured but down (`gone`), `ACPMUX_RSS_READERS` in-process hubs that read *its* list over its
//! WebSocket listener with its peer token, and `ACPMUX_RSS_WATCHERS` unix clients watching the
//! list and draining what they get (`ACPMUX_RSS_STALLED` more that never read). Then
//! `ACPMUX_RSS_ROUNDS` rounds, each of:
//!
//! - `ACPMUX_RSS_SENDS` `acpmux send --from lane-N --no-wait <coordinator> TEXT` (the CLI, one
//!   process each), to `ACPMUX_RSS_COORDS` coordinators whose inbox nobody marks read;
//! - `ACPMUX_RSS_RETRIES` such sends to `gone/lane-N`, a session on the peer that is down, which
//!   the outbox keeps and retries;
//! - `ACPMUX_RSS_PEER_CHANGES` row changes on the peers the daemon reads (fanned out to the
//!   watchers and readers as `session_changed`);
//! - `ACPMUX_RSS_PROMPTS` prompts to `ACPMUX_RSS_PROMPT_TARGETS` chats whose stand-in agent
//!   streams `ACPMUX_RSS_CHUNKS` chunks each.
//!
//! Every `ACPMUX_RSS_EVERY` rounds it prints a `RSS-ROW` line: the round, VmRSS, the outbox's
//! deliveries and pending ones, the coordinators' inbox items, the peer-list gauge and the ops
//! so far; at the end a slope (MB per 1000 operations of the run's mix). With `ACPMUX_RSS_DHAT=1`
//! and a `--features dhat-heap` build the daemon writes its heap on exit and the run prints the
//! sites holding the most bytes at that moment (`RSS-HEAP-END`), grouped by first acpmux frame.
//!
//! Manual, on Linux:
//! `CARGO_PROFILE_RELEASE_DEBUG=line-tables-only cargo test -p acpmux --release --features dhat-heap
//! --test daemon_rss_growth -- --ignored --nocapture`.

#![cfg(target_os = "linux")]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// Stand-in agents only (tests/fake_agent.py); the knobs hold no credential.
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in().keep(&[
    "ACPMUX_RSS_SESSIONS",
    "ACPMUX_RSS_ROUNDS",
    "ACPMUX_RSS_EVERY",
    "ACPMUX_RSS_SENDS",
    "ACPMUX_RSS_RETRIES",
    "ACPMUX_RSS_PEER_CHANGES",
    "ACPMUX_RSS_PROMPTS",
    "ACPMUX_RSS_PROMPT_TARGETS",
    "ACPMUX_RSS_CHUNKS",
    "ACPMUX_RSS_COORDS",
    "ACPMUX_RSS_PEERS",
    "ACPMUX_RSS_PEER_ROWS",
    "ACPMUX_RSS_READERS",
    "ACPMUX_RSS_WATCHERS",
    "ACPMUX_RSS_STALLED",
    "ACPMUX_RSS_BYTES",
    "ACPMUX_RSS_PAR",
    "ACPMUX_RSS_SETTLE_SECS",
    "ACPMUX_RSS_DHAT",
    "ACPMUX_RSS_DHAT_TOP",
    "ACPMUX_RSS_ARENAS",
    "ACPMUX_RSS_LISTS",
    "ACPMUX_RSS_CHAT_MESSAGES",
    "ACPMUX_RSS_DAEMON_BIN",
]);

use acpmux::config::{Config, StoreMode};
use acpmux::god_fixture::{self, Shape};
use acpmux::hub::Hub;
use acpmux::server::peer_auth::PeerAuth;
use acpmux::server::{WsAuth, bind_ws, serve_ws_with};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Stdio};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::{Duration, Instant};

const STEP: Duration = Duration::from_secs(300);

fn env_or<T: std::str::FromStr>(name: &str, default: T) -> T {
    std::env::var(name).ok().and_then(|v| v.parse().ok()).unwrap_or(default)
}

/// A line client on the daemon's socket.
struct Rpc {
    reader: BufReader<UnixStream>,
    writer: UnixStream,
    next: u64,
}

impl Rpc {
    fn connect(path: &Path) -> Self {
        let s = UnixStream::connect(path).expect("connect to the daemon's socket");
        s.set_read_timeout(Some(STEP)).unwrap();
        Self { reader: BufReader::new(s.try_clone().unwrap()), writer: s, next: 0 }
    }

    fn init(path: &Path, name: &str) -> Self {
        let mut rpc = Self::connect(path);
        rpc.call("initialize", json!({"protocolVersion": 1, "clientInfo": {"name": name}}))
            .unwrap();
        rpc
    }

    fn request(&mut self, method: &str, params: Value) -> u64 {
        self.next += 1;
        let line = json!({"jsonrpc": "2.0", "id": self.next, "method": method, "params": params});
        self.writer.write_all(format!("{line}\n").as_bytes()).unwrap();
        self.next
    }

    /// The response to `id`; every other line read meanwhile is dropped.
    fn response(&mut self, id: u64) -> Result<Value, Value> {
        let mut line = String::new();
        loop {
            line.clear();
            let n = self.reader.read_line(&mut line).map_err(|e| json!(e.to_string()))?;
            if n == 0 {
                return Err(json!("the daemon closed the socket"));
            }
            let Ok(v) = serde_json::from_str::<Value>(&line) else { continue };
            if v.get("method").is_none() && v.get("id") == Some(&json!(id)) {
                return match v.get("error") {
                    Some(e) => Err(e.clone()),
                    None => Ok(v["result"].clone()),
                };
            }
        }
    }

    fn call(&mut self, method: &str, params: Value) -> Result<Value, Value> {
        let id = self.request(method, params);
        self.response(id)
    }
}

struct Daemon {
    child: Child,
    socket: PathBuf,
}

impl Daemon {
    fn start(scratch: &Path, home: &Path, dhat: Option<&Path>) -> Self {
        let socket = scratch.join("s.sock");
        // A copied control binary (a base build) for before/after runs; same hermetic env.
        let binary = std::env::var_os("ACPMUX_RSS_DAEMON_BIN")
            .map(PathBuf::from)
            .unwrap_or_else(|| daemon_env::bin().to_path_buf());
        let mut command =
            daemon_env::command_at(&binary, scratch, daemon_env::Agents::StandIn, &[]);
        command
            .args(["daemon", "run", "--log", "warn"])
            .env("ACPMUX_HOME", home)
            .env("ACPMUX_SOCKET", &socket)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::from(std::fs::File::create(scratch.join("daemon.err")).unwrap()));
        if let Some(out) = dhat {
            command.env(acpmux::heap_profile::OUT_ENV, out);
        }
        if let Ok(arenas) = std::env::var("ACPMUX_RSS_ARENAS") {
            command.env("MALLOC_ARENA_MAX", arenas);
        }
        let spawned = Instant::now();
        let mut child = command.spawn().unwrap();
        while UnixStream::connect(&socket).is_err() {
            if spawned.elapsed() >= STEP || child.try_wait().unwrap().is_some() {
                let _ = child.kill();
                panic!("the daemon did not bind its socket");
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        Self { child, socket }
    }

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

    fn threads(&self) -> usize {
        std::fs::read_dir(format!("/proc/{}/task", self.child.id())).map_or(0, |d| d.count())
    }

    fn fds(&self) -> usize {
        std::fs::read_dir(format!("/proc/{}/fd", self.child.id())).map_or(0, |d| d.count())
    }

    fn stop(&mut self) {
        // SAFETY: the pid is this test's own child, not yet reaped.
        unsafe { libc::kill(self.child.id() as i32, libc::SIGTERM) };
        let _ = self.child.wait();
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// Peers the daemon reads: in-process hubs of `rows` rows served over WebSocket with a peer token.
async fn read_peers(
    n: usize,
    rows: usize,
    scratch: &Path,
) -> (serde_json::Map<String, Value>, Vec<Arc<Hub>>) {
    let (mut config, mut hubs) = (serde_json::Map::new(), vec![]);
    for p in 0..n {
        let name = format!("peer{p:02}");
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
            name,
            json!({"url": format!("ws://127.0.0.1:{port}"), "token": "tok", "peerToken": token.trim()}),
        );
        hubs.push(hub);
    }
    (config, hubs)
}

fn free_port() -> u16 {
    std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port()
}

/// A watching client that drains every line on its own thread: the bytes it read.
fn watcher(socket: &Path, name: &str, stop: Arc<AtomicBool>) -> Arc<AtomicU64> {
    let mut rpc = Rpc::init(socket, name);
    rpc.call("_acpmux/watch", json!({"enabled": true})).unwrap();
    rpc.writer.set_read_timeout(Some(Duration::from_millis(500))).unwrap();
    let bytes = Arc::new(AtomicU64::new(0));
    let counted = bytes.clone();
    std::thread::spawn(move || {
        let mut line = String::new();
        while !stop.load(Ordering::Relaxed) {
            line.clear();
            match rpc.reader.read_line(&mut line) {
                Ok(0) => break,
                Ok(n) => {
                    counted.fetch_add(n as u64, Ordering::Relaxed);
                }
                Err(_) => {}
            }
        }
    });
    bytes
}

/// Runs `jobs` CLI commands, `par` at a time: how many exited 0.
fn run_cli(scratch: &Path, socket: &Path, home: &Path, jobs: Vec<Vec<String>>, par: usize) -> u64 {
    let jobs = Arc::new(std::sync::Mutex::new(jobs));
    let ok = Arc::new(AtomicU64::new(0));
    let first_err = Arc::new(std::sync::Mutex::new(None::<String>));
    std::thread::scope(|s| {
        for _ in 0..par.max(1) {
            let (jobs, ok, first_err) = (jobs.clone(), ok.clone(), first_err.clone());
            s.spawn(move || {
                loop {
                    let Some(args) = jobs.lock().unwrap().pop() else { break };
                    let out = daemon_env::acpmux(scratch)
                        .args(&args)
                        .env("ACPMUX_SOCKET", socket)
                        .env("ACPMUX_HOME", home)
                        .stdin(Stdio::null())
                        .output()
                        .unwrap();
                    if out.status.success() {
                        ok.fetch_add(1, Ordering::Relaxed);
                    } else {
                        let mut e = first_err.lock().unwrap();
                        if e.is_none() {
                            *e = Some(format!(
                                "{args:?}: {} {}",
                                String::from_utf8_lossy(&out.stdout),
                                String::from_utf8_lossy(&out.stderr)
                            ));
                        }
                    }
                }
            });
        }
    });
    if let Some(e) = first_err.lock().unwrap().take() {
        static SAID: AtomicU64 = AtomicU64::new(0);
        if SAID.fetch_add(1, Ordering::Relaxed) < 5 {
            println!("RSS-CLI-ERROR {e}");
        }
    }
    ok.load(Ordering::Relaxed)
}

/// Items in `session`'s inbox, all threads (`_acpmux/inbox_threads`).
fn inbox_items(rpc: &mut Rpc, session: &str) -> u64 {
    let Ok(v) = rpc.call("_acpmux/inbox_threads", json!({"sessionId": session})) else { return 0 };
    let threads = v["threads"].as_array().cloned().unwrap_or_default();
    threads
        .iter()
        .map(|t| {
            ["count", "items", "total", "messages"]
                .iter()
                .find_map(|k| t[*k].as_u64().or_else(|| t[*k].as_array().map(|a| a.len() as u64)))
                .unwrap_or(1)
        })
        .sum()
}

#[derive(Default, Clone, Copy)]
struct Ops {
    sends: u64,
    retries: u64,
    peer_changes: u64,
    prompts: u64,
    lists: u64,
}

impl Ops {
    fn total(&self) -> u64 {
        self.sends + self.retries + self.peer_changes + self.prompts + self.lists
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "manual: a load lab; minutes of real daemon"]
async fn daemon_rss_under_synthetic_load() {
    let sessions: usize = env_or("ACPMUX_RSS_SESSIONS", 200);
    let rounds: u64 = env_or("ACPMUX_RSS_ROUNDS", 100);
    let every: u64 = env_or("ACPMUX_RSS_EVERY", 10);
    let sends: usize = env_or("ACPMUX_RSS_SENDS", 20);
    let retries: usize = env_or("ACPMUX_RSS_RETRIES", 5);
    let peer_changes: usize = env_or("ACPMUX_RSS_PEER_CHANGES", 20);
    let prompts: usize = env_or("ACPMUX_RSS_PROMPTS", 2);
    let lists: usize = env_or("ACPMUX_RSS_LISTS", 0);
    let chat_messages: usize = env_or("ACPMUX_RSS_CHAT_MESSAGES", 40);
    let prompt_targets: usize = env_or("ACPMUX_RSS_PROMPT_TARGETS", 4);
    let chunks: usize = env_or("ACPMUX_RSS_CHUNKS", 50);
    let coords: usize = env_or("ACPMUX_RSS_COORDS", 4);
    let peers: usize = env_or("ACPMUX_RSS_PEERS", 2);
    let peer_rows: usize = env_or("ACPMUX_RSS_PEER_ROWS", 200);
    let readers: usize = env_or("ACPMUX_RSS_READERS", 2);
    let watchers: usize = env_or("ACPMUX_RSS_WATCHERS", 2);
    let stalled: usize = env_or("ACPMUX_RSS_STALLED", 0);
    let text_bytes: usize = env_or("ACPMUX_RSS_BYTES", 400);
    let par: usize = env_or("ACPMUX_RSS_PAR", 8);
    let settle = Duration::from_secs(env_or("ACPMUX_RSS_SETTLE_SECS", 5));
    let dhat = std::env::var("ACPMUX_RSS_DHAT").is_ok_and(|v| v == "1");

    let scratch_dir = daemon_env::Scratch::new("rss-growth");
    let scratch = scratch_dir.to_path_buf();
    let home = scratch.join("acpmux");
    let claude = daemon_env::home(&scratch).join(".claude");
    let shape = Shape {
        name: "rss",
        chats: sessions,
        god_messages: 200,
        god_bytes: 1 << 20,
        chat_messages,
        peers,
        peer_rows,
        row_keys: 75,
    };
    let made = god_fixture::write_home(&home, &claude, &scratch.join("work"), &shape).unwrap();
    let (mut peer_config, peer_hubs) = read_peers(peers, peer_rows, &scratch).await;
    // A peer that is down for the whole run: sends to it stay in the outbox and are retried.
    peer_config.insert(
        "gone".into(),
        json!({"url": format!("ws://127.0.0.1:{}", free_port()), "token": "tok"}),
    );
    let ws_port = free_port();
    let ws_token = "t".repeat(32);
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let config = json!({
        "peers": peer_config,
        "harnesses": {"claude": {"argv": ["python3", fake]}},
        "defaultHarness": "claude",
        "permissionPolicy": "approve-all",
        "websocket": {"listen": format!("127.0.0.1:{ws_port}"), "token": ws_token},
    });
    std::fs::write(home.join("config.json"), config.to_string()).unwrap();
    let profile = dhat.then(|| scratch.join("dhat-heap.json"));

    let daemon = Daemon::start(&scratch, &home, profile.as_deref());
    let socket = daemon.socket.clone();
    let mut rpc = Rpc::init(&socket, "rss-sampler");
    // Wait for the peers the daemon reads to be listed.
    let started = Instant::now();
    while started.elapsed() < Duration::from_secs(60) {
        let st = rpc.call("_acpmux/status", json!({})).unwrap_or_default();
        if st["remoteSessions"].as_u64().unwrap_or(0) as usize >= peers * peer_rows {
            break;
        }
        std::thread::sleep(Duration::from_millis(100));
    }

    // Hubs that read this daemon's list as its peers, over its WebSocket listener.
    let peer_token = std::fs::read_to_string(acpmux::server::peer_auth::token_path(&home))
        .map(|t| t.trim().to_owned())
        .ok();
    // The daemon may rotate the listener's token at its first start (`tokenRotated`): read it back.
    let ws_token = std::fs::read_to_string(home.join("config.json"))
        .ok()
        .and_then(|t| serde_json::from_str::<Value>(&t).ok())
        .and_then(|c| c["websocket"]["token"].as_str().map(str::to_owned))
        .unwrap_or(ws_token);
    let mut reader_hubs = vec![];
    for r in 0..readers {
        let mut cfg = Config::default();
        cfg.store.mode = StoreMode::Memory;
        let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
        let hub = Hub::new(cfg, store);
        let added = hub
            .add_peer(
                "hut",
                &format!("ws://127.0.0.1:{ws_port}"),
                Some(ws_token.clone()),
                peer_token.clone(),
                true,
            )
            .await;
        let p = hub.peers();
        println!(
            "RSS-READER {r} added={:?} connected={} error={}",
            added.as_ref().err(),
            p[0]["connected"],
            p[0]["error"]
        );
        reader_hubs.push(hub);
    }

    let stop = Arc::new(AtomicBool::new(false));
    let watched: Vec<Arc<AtomicU64>> =
        (0..watchers).map(|w| watcher(&socket, &format!("gui-{w}"), stop.clone())).collect();
    // Clients that watch and never read: their queues fill.
    let stalled_clients: Vec<Rpc> = (0..stalled)
        .map(|w| {
            let mut c = Rpc::init(&socket, &format!("stalled-{w}"));
            c.call("_acpmux/watch", json!({"enabled": true})).unwrap();
            c
        })
        .collect();

    let coord_ids: Vec<String> = (1..=coords).map(god_fixture::chat_id).collect();
    let prompt_ids: Vec<String> =
        (coords + 1..=coords + prompt_targets).map(god_fixture::chat_id).collect();
    let header = "round rssMB hwmMB cpuS thr fds outboxN pending inboxN peerListsB ops sends retries peerChg prompts lists watchMB";
    println!(
        "RSS-CONFIG {}",
        json!({
            "sessions": sessions, "rounds": rounds, "every": every, "sends": sends, "retries": retries,
            "peerChanges": peer_changes, "prompts": prompts, "promptTargets": prompt_targets,
            "chunks": chunks, "coords": coords, "peers": peers, "peerRows": peer_rows,
            "readers": readers, "watchers": watchers, "stalled": stalled, "bytes": text_bytes,
            "par": par, "dhat": dhat, "god": made.god, "lists": lists,
            "chatMessages": chat_messages,
        })
    );
    println!("RSS-HEAD {header}");

    let home2 = home.clone();
    let scratch2 = scratch.clone();
    let socket2 = socket.clone();
    let watched2 = watched.clone();
    let (rows, ops, mut rpc, mut daemon) = tokio::task::spawn_blocking(move || {
        let mut ops = Ops::default();
        let mut rows: Vec<(u64, u64, Ops)> = vec![];
        let mut prompter = Rpc::init(&socket2, "rss-prompter");
        let filler: String = "x".repeat(text_bytes);
        let sample = |round: u64, ops: &Ops, rpc: &mut Rpc, daemon: &Daemon| -> u64 {
            let (rss, hwm) = daemon.rss();
            let list = rpc
                .call("_acpmux/send_status", json!({"list": true, "limit": 100000}))
                .unwrap_or_default();
            let outbox = list["deliveries"].as_array().map_or(0, Vec::len);
            let pending = &list["pending"];
            let inbox: u64 = coord_ids.iter().map(|c| inbox_items(rpc, c)).sum();
            let st = rpc.call("_acpmux/status", json!({})).unwrap_or_default();
            let watch_mb = watched2.iter().map(|b| b.load(Ordering::Relaxed)).sum::<u64>() >> 20;
            println!(
                "RSS-ROW {round} {} {} {:.1} {} {} {outbox} {pending} {inbox} {} {} {} {} {} {} {} {watch_mb}",
                rss >> 20,
                hwm >> 20,
                daemon.cpu_seconds(),
                daemon.threads(),
                daemon.fds(),
                st["gauges"]["peerLists"]["bytes"],
                ops.total(),
                ops.sends,
                ops.retries,
                ops.peer_changes,
                ops.prompts,
                ops.lists,
            );
            rss
        };
        let rss0 = sample(0, &ops, &mut rpc, &daemon);
        rows.push((0, rss0, ops));
        let mut seq = 0u64;
        for round in 1..=rounds {
            // Sends and retries, one CLI process each.
            let mut jobs = vec![];
            for i in 0..sends {
                seq += 1;
                let coord = &coord_ids[i % coord_ids.len().max(1)];
                jobs.push(vec![
                    "send".into(),
                    "--from".into(),
                    format!("lane-{:03}", seq % 64),
                    "--no-wait".into(),
                    coord.clone(),
                    format!("report {seq} PR #{} {filler}", 1000 + seq % 97),
                ]);
            }
            for _ in 0..retries {
                seq += 1;
                jobs.push(vec![
                    "send".into(),
                    "--from".into(),
                    format!("lane-{:03}", seq % 64),
                    "--no-wait".into(),
                    format!("gone/lane-{:03}", seq % 32),
                    format!("report {seq} {filler}"),
                ]);
            }
            let sent = run_cli(&scratch2, &socket2, &home2, jobs, par);
            let _ = sent;
            ops.sends += sends as u64;
            ops.retries += retries as u64;
            // Row changes on the peers the daemon reads.
            for i in 0..if peer_hubs.is_empty() { 0 } else { peer_changes } {
                let hub = &peer_hubs[i % peer_hubs.len().max(1)];
                let name = format!("peer{:02}", i % peer_hubs.len().max(1));
                let row = format!("{name}-{:05}", (seq as usize + i * 7) % peer_rows.max(1));
                if let Some(s) = hub.sessions().into_iter().find(|s| s.id == row) {
                    hub.set_rules(&s, Some(json!({"default": "approve", "n": seq + i as u64})));
                    ops.peer_changes += 1;
                }
            }
            // Session lists with usage and single-chat info reads, as fleet tools poll: all of
            // the round's at once, each on its own connection, while the prompts below end turns.
            let all_ids: Vec<String> = (0..sessions).map(god_fixture::chat_id).collect();
            let listers: Vec<_> = (0..lists)
                .map(|i| {
                    let socket = socket2.clone();
                    let id = all_ids[(seq as usize + i * 13) % all_ids.len()].clone();
                    std::thread::spawn(move || {
                        let mut c = Rpc::init(&socket, "rss-lister");
                        let r = if i % 2 == 0 {
                            c.call("_acpmux/sessions", json!({"usage": true}))
                        } else {
                            c.call("_acpmux/info", json!({"sessionId": id, "waitLogs": false}))
                        };
                        r.is_ok()
                    })
                })
                .collect();
            // Prompts that stream output.
            for i in 0..prompts {
                let target = &prompt_ids[(round as usize * prompts + i) % prompt_ids.len().max(1)];
                let p = json!({"sessionId": target,
                               "prompt": [{"type": "text", "text": format!("chunks: {chunks}")}]});
                if let Err(e) = prompter.call("session/prompt", p) {
                    println!("RSS-PROMPT-ERROR {e}");
                }
                ops.prompts += 1;
            }
            for l in listers {
                let _ = l.join();
                ops.lists += 1;
            }
            if round % every == 0 || round == rounds {
                let rss = sample(round, &ops, &mut rpc, &daemon);
                rows.push((round, rss, ops));
            }
        }
        std::thread::sleep(settle);
        let rss = sample(rounds + 1, &ops, &mut rpc, &daemon);
        rows.push((rounds + 1, rss, ops));
        (rows, ops, rpc, daemon)
    })
    .await
    .unwrap();

    // The slope over the second half of the run (past the warm-up), in MB per 1000 operations.
    let half = &rows[rows.len() / 2..];
    let (first, last) = (half.first().unwrap(), half.last().unwrap());
    let d_ops = last.2.total().saturating_sub(first.2.total()).max(1);
    let d_mb = (last.1 as f64 - first.1 as f64) / 1_048_576.0;
    let all_mb = (rows.last().unwrap().1 as f64 - rows[0].1 as f64) / 1_048_576.0;
    println!(
        "RSS-SLOPE {}",
        json!({"mbPer1000OpsSecondHalf": d_mb / d_ops as f64 * 1000.0, "mbSecondHalf": d_mb,
               "opsSecondHalf": d_ops, "mbWholeRun": all_mb, "opsWholeRun": ops.total(),
               "mbPer1000OpsWholeRun": all_mb / ops.total().max(1) as f64 * 1000.0})
    );
    let _ = rpc.call("_acpmux/status", json!({}));
    stop.store(true, Ordering::Relaxed);
    drop(stalled_clients);
    drop(rpc);
    daemon.stop();
    if let Some(profile) = profile.as_deref() {
        let heap = attribute(profile);
        println!(
            "RSS-HEAP {}",
            json!({"endBytes": heap["endBytes"], "peakBytes": heap["peakBytes"]})
        );
        for (list, key) in [("END", "byEnd"), ("PEAK", "byPeak")] {
            for row in heap[key].as_array().into_iter().flatten() {
                println!(
                    "RSS-HEAP-{list} end={} blocks={} peak={} {} via {}",
                    row["endBytes"], row["endBlocks"], row["peakBytes"], row["site"], row["via"]
                );
            }
        }
    }
    for h in reader_hubs {
        drop(h);
    }
}

/// The frame a dhat site is named by: the first three frames in acpmux's own source, innermost
/// first (as `tests/god_daemon.rs`).
fn acpmux_frame(frames: &[&str]) -> String {
    let own: Vec<String> =
        frames.iter().filter(|f| own_file(f)).take(3).map(|f| place(f)).collect();
    if own.is_empty() {
        return frames.get(1).map_or_else(|| "[unknown]".to_owned(), |f| short_frame(f));
    }
    own.join(" < ")
}

fn own_file(frame: &str) -> bool {
    frame.contains("acpmux/src/")
        && !frame.contains("acpmux/src/main.rs")
        && !frame.contains("heap_profile")
}

fn place(frame: &str) -> String {
    let frame = short_frame(frame);
    let (name, file) = frame.rsplit_once(" (").map_or((frame.as_str(), ""), |(n, f)| (n, f));
    let name = name.split('<').next().unwrap_or(name);
    let name: Vec<&str> = name.rsplit("::").take(2).collect();
    let file = file.trim_end_matches(')').split("acpmux/src/").last().unwrap_or(file);
    format!("{} ({file})", name.into_iter().rev().collect::<Vec<_>>().join("::"))
}

fn short_frame(frame: &str) -> String {
    let frame = frame.split_once(": ").map_or(frame, |(_, f)| f);
    let hashless: String = frame.split("::h").next().unwrap_or(frame).to_owned();
    if hashless.len() < frame.len() {
        let file = frame.rsplit_once(" (").map(|(_, f)| format!(" ({f}")).unwrap_or_default();
        return format!("{hashless}{file}");
    }
    frame.to_owned()
}

/// The dhat profile at `path` by acpmux site, the largest held at the profile's write (the
/// daemon's exit) first.
fn attribute(path: &Path) -> Value {
    let Ok(text) = std::fs::read_to_string(path) else {
        return json!({"error": format!("no profile at {}", path.display())});
    };
    let doc: Value = serde_json::from_str(&text).unwrap();
    let ftbl: Vec<&str> =
        doc["ftbl"].as_array().unwrap().iter().map(|f| f.as_str().unwrap_or("")).collect();
    let top = env_or("ACPMUX_RSS_DHAT_TOP", 25usize);
    #[derive(Default)]
    struct Site {
        eb: u64,
        ebk: u64,
        gb: u64,
        inner: BTreeMap<String, u64>,
    }
    let mut sites: BTreeMap<String, Site> = BTreeMap::new();
    let mut peak = 0;
    for pp in doc["pps"].as_array().unwrap() {
        let frames: Vec<&str> = pp["fs"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(|i| ftbl.get(i.as_u64()? as usize).copied())
            .collect();
        let site = sites.entry(acpmux_frame(&frames)).or_default();
        let eb = pp["eb"].as_u64().unwrap_or(0);
        site.eb += eb;
        site.ebk += pp["ebk"].as_u64().unwrap_or(0);
        site.gb += pp["gb"].as_u64().unwrap_or(0);
        peak += pp["gb"].as_u64().unwrap_or(0);
        let inner = frames
            .iter()
            .find(|f| !f.contains("alloc::") && !f.contains("dhat") && !f.contains("[root]"))
            .map_or_else(|| "[unknown]".to_owned(), |f| short_frame(f));
        *site.inner.entry(inner).or_default() += eb;
    }
    let row = |(name, s): (&String, &Site)| {
        let mut inner: Vec<(&String, &u64)> = s.inner.iter().collect();
        inner.sort_by_key(|(_, b)| std::cmp::Reverse(**b));
        json!({"site": name, "endBytes": s.eb, "endBlocks": s.ebk, "peakBytes": s.gb,
               "via": inner.first().map(|(f, _)| f.as_str())})
    };
    let mut by_end: Vec<(&String, &Site)> = sites.iter().collect();
    by_end.sort_by_key(|(_, s)| std::cmp::Reverse(s.eb));
    // The daemon frees its sessions and connections as it stops, before the profile is written:
    // memory a growing run held is at the heap's peak (its last moments), not at its end.
    let mut by_peak: Vec<(&String, &Site)> = sites.iter().collect();
    by_peak.sort_by_key(|(_, s)| std::cmp::Reverse(s.gb));
    json!({"endBytes": sites.values().map(|s| s.eb).sum::<u64>(), "peakBytes": peak,
           "byEnd": by_end.into_iter().take(top).map(row).collect::<Vec<_>>(),
           "byPeak": by_peak.into_iter().take(top).map(row).collect::<Vec<_>>()})
}
