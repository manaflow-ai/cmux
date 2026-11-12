//! The real daemon over a god home and a small one, in one harness (W0, 2026-11-12). On Leo's Mac
//! the daemon grew to 11 GB within 15 minutes of its start, a CLI round trip took 20 s, and it
//! took 93 s from socket-ready to "agents may spawn". Leo: "even if a chat is long, there should
//! be no percievable difference ... so that's our goal".
//!
//! Each home is `god_fixture::Shape` (`ACPMUX_GOD_SHAPES`, default `small,god`;
//! `ACPMUX_GOD_SCALE` shrinks the god one): its chats in the store and in Claude's projects
//! folder, and its peers, each a hub in this process with `peer_rows` chats, served over
//! WebSocket behind a proxy this test can cut. The test measures, for each home:
//!
//! - `first_list_ms`: from the daemon's spawn to its first `_acpmux/watch` reply (the app's list);
//! - `peers_ms`: from the spawn until every peer's rows are listed;
//! - `attachUs`: the pane's attach to the god chat (`waitLogs: false`, 400 records, 128 KiB),
//!   [`ROUNDS`] times: p50, p95 and max;
//! - `scrollPageUs`: the pane's scroll up through the god chat, [`ROUNDS`] older pages
//!   (`_acpmux/events` before the oldest seq held, 400 records, 128 KiB); `deepScrollUs`: a jump
//!   to the middle of its history, [`DEEP_ROUNDS`] times;
//! - `firstSendFirstTokenMs`, `sendFirstTokenUs`: a prompt to the god chat to its first streamed
//!   chunk (a stand-in agent answers), the first one (which starts the agent) and the rest;
//! - `allLogsMs`: from the daemon's start until its "all chat logs" phase ends, waited for;
//! - `reconnect_ms`: every peer link cut at once, until every peer is listed again (three times),
//!   and their median;
//! - `rss` and `peak_rss`: the daemon's resident bytes after all that, and at its peak;
//! - the daemon's own gauges (`daemon status` `gauges`), its startup phases flat
//!   (`startupPhasesMs`) and its marks (`marksMs`: socket ready, first list reply, agents may spawn);
//! - `homeBytes`: the home's bytes on disk after the daemon stops; file by file against what the
//!   fixture wrote, `daemonAddedBytes` (files new or grown) and `daemonRemovedBytes` (files gone
//!   or shrunk, such as the journal segment the fixture's store left live, which the daemon's
//!   checkpoint retires), and the largest removals (`daemonRemoved`).
//!
//! A settled attach, scroll or prompt that fails is counted, not timed, and fails the test once
//! every home has printed its numbers.
//!
//! With `ACPMUX_GOD_DHAT=1` and a binary built with `--features dhat-heap`, the daemon records
//! its heap (dhat) and the test prints its allocation sites: the bytes each held at the heap's
//! peak and in total, grouped by the first acpmux frame, and the sites of its 640-byte blocks
//! (serde_json's BTreeMap leaves). Manual, on Linux CI:
//! `cargo test -p acpmux --release --test god_daemon -- --ignored --nocapture`, and the profile:
//! `CARGO_PROFILE_RELEASE_DEBUG=line-tables-only ACPMUX_GOD_DHAT=1 cargo test -p acpmux --release
//! --features dhat-heap --test god_daemon -- --ignored --nocapture` (line tables name inlined frames).
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// The prompt goes to tests/fake_agent.py; the sizes and the profile switch hold no credential.
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in().keep(&[
    "ACPMUX_GOD_SHAPES",
    "ACPMUX_GOD_SCALE",
    "ACPMUX_GOD_DHAT",
    "ACPMUX_GOD_DHAT_TOP",
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
use std::time::{Duration, Instant};

/// How long any one step may take before the run says so and moves on.
const STEP: Duration = Duration::from_secs(600);

/// Times each repeated step (attach, send, scroll) is measured.
const ROUNDS: usize = 20;

/// Times the jump to the middle of the god chat is measured.
const DEEP_ROUNDS: usize = 5;

/// A page as the pane asks for one: its records and bytes.
const PAGE_LIMIT: u64 = 400;
const PAGE_BYTES: u64 = 131072;

/// How long the run waits for every chat log to be read, and how often it asks.
const ALL_LOGS: Duration = Duration::from_secs(120);
const ALL_LOGS_POLL: Duration = Duration::from_millis(50);

/// The startup points kept as marks, not phases (`gauges.rs`).
const MARKS: [&str; 3] = ["socket ready", "first list reply", "agents may spawn"];

fn ms(since: Instant) -> u64 {
    since.elapsed().as_millis() as u64
}

fn micros(since: Instant) -> u64 {
    since.elapsed().as_micros() as u64
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

/// The middle value of `samples`, null when there are none.
fn median(samples: &[u64]) -> Value {
    if samples.is_empty() {
        return Value::Null;
    }
    let mut sorted = samples.to_vec();
    sorted.sort_unstable();
    json!(sorted[sorted.len() / 2])
}

/// The bytes of each file under `dir`, links not followed, into `files`; a folder that can't be
/// read adds none.
fn file_bytes(dir: &Path, files: &mut BTreeMap<PathBuf, u64>) {
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    for e in entries.flatten() {
        match e.path().symlink_metadata() {
            Ok(m) if m.is_dir() => file_bytes(&e.path(), files),
            Ok(m) if m.is_file() => {
                files.insert(e.path(), m.len());
            }
            _ => {}
        }
    }
}

/// Every file under `dir` and its bytes.
fn home_files(dir: &Path) -> BTreeMap<PathBuf, u64> {
    let mut files = BTreeMap::new();
    file_bytes(dir, &mut files);
    files
}

/// What the daemon did to the home, file by file: the bytes of files new or grown, of files gone
/// or shrunk, and the largest of those removals, by path under `home`.
fn disk_change(
    home: &Path,
    before: &BTreeMap<PathBuf, u64>,
    after: &BTreeMap<PathBuf, u64>,
) -> (u64, u64, Value) {
    let added = after.iter().map(|(p, b)| b.saturating_sub(*before.get(p).unwrap_or(&0))).sum();
    let mut removed: Vec<(&PathBuf, u64)> = before
        .iter()
        .map(|(p, b)| (p, b.saturating_sub(*after.get(p).unwrap_or(&0))))
        .filter(|(_, b)| *b > 0)
        .collect();
    let removed_bytes = removed.iter().map(|(_, b)| b).sum();
    removed.sort_by_key(|(_, b)| std::cmp::Reverse(*b));
    let top = removed
        .into_iter()
        .take(5)
        .map(|(p, b)| json!([p.strip_prefix(home).unwrap_or(p).display().to_string(), b]))
        .collect::<Vec<_>>();
    (added, removed_bytes, json!(top))
}

/// The oldest seq of a page's records, if it has any.
fn oldest_seq(page: &Value) -> Option<u64> {
    page["events"].as_array()?.iter().filter_map(|e| e["seq"].as_u64()).min()
}

/// The status gauges' startup as two flat objects, by name: each phase's ms (null while it
/// runs; a name seen twice adds up) and each mark's atMs.
fn startup_axes(gauges: &Value) -> (Value, Value) {
    let (mut phases, mut marks) = (serde_json::Map::new(), serde_json::Map::new());
    for p in gauges["startup"].as_array().into_iter().flatten() {
        let Some(name) = p["name"].as_str() else { continue };
        if MARKS.contains(&name) {
            marks.insert(name.to_owned(), p["atMs"].clone());
            continue;
        }
        let sum = match (phases.get(name).and_then(Value::as_u64), p["ms"].as_u64()) {
            (Some(a), Some(b)) => json!(a + b),
            (_, Some(b)) => json!(b),
            (_, None) => Value::Null,
        };
        phases.insert(name.to_owned(), sum);
    }
    (Value::Object(phases), Value::Object(marks))
}

/// When the "all chat logs" phase ended, in ms from the daemon's start: none while it runs.
fn all_logs_end(gauges: &Value) -> Option<u64> {
    let phase = gauges["startup"].as_array()?.iter().find(|p| p["name"] == "all chat logs")?;
    Some(phase["atMs"].as_u64()? + phase["ms"].as_u64()?)
}

/// Asks `_acpmux/status` until every chat log is read: when it ended, or why it is not known.
/// No call waits past [`ALL_LOGS`], so the wait ends at most a poll after it.
fn wait_all_logs(rpc: &mut Rpc) -> Result<u64, Value> {
    let deadline = Instant::now() + ALL_LOGS;
    let mut last = Value::Null;
    while Instant::now() < deadline {
        match rpc.call_until("_acpmux/status", json!({}), Some(deadline)) {
            Ok(status) => {
                if let Some(end) = all_logs_end(&status["gauges"]) {
                    return Ok(end);
                }
            }
            Err(e) => last = e,
        }
        rpc.notes.clear();
        std::thread::sleep(ALL_LOGS_POLL);
    }
    Err(json!({"timeoutMs": ALL_LOGS.as_millis() as u64, "lastError": last}))
}

/// One older page of the god chat, as the pane asks when it scrolls up: its time and reply.
fn older_page(rpc: &mut Rpc, god: &str, before: u64) -> (u64, Result<Value, Value>) {
    let asked = Instant::now();
    let page = rpc.call(
        "_acpmux/events",
        json!({"sessionId": god, "beforeSeq": before, "limit": PAGE_LIMIT, "maxBytes": PAGE_BYTES}),
    );
    let us = micros(asked);
    rpc.notes.clear();
    (us, page)
}

/// A line client on the daemon's socket that keeps the lines it reads and has not asked for yet:
/// notifications, and responses to requests it has not waited on.
struct Rpc {
    reader: BufReader<UnixStream>,
    writer: UnixStream,
    next: u64,
    notes: Vec<Value>,
    /// The part of a line a read's timeout cut short, which the next read finishes.
    line: String,
    /// Bytes read so far, and the longest line: what a prompt's notices weigh.
    read_bytes: u64,
    longest_line: u64,
}

impl Rpc {
    fn connect(path: &Path) -> Self {
        let s = UnixStream::connect(path).expect("connect to the daemon's socket");
        s.set_read_timeout(Some(STEP)).unwrap();
        let reader = BufReader::new(s.try_clone().unwrap());
        Self {
            reader,
            writer: s,
            next: 0,
            notes: vec![],
            line: String::new(),
            read_bytes: 0,
            longest_line: 0,
        }
    }

    fn call(&mut self, method: &str, params: Value) -> Result<Value, Value> {
        let id = self.request(method, params);
        self.response(id)
    }

    /// [`Rpc::call`] that waits for its response until `deadline` at most: past it, an error.
    fn call_until(
        &mut self,
        method: &str,
        params: Value,
        deadline: Option<Instant>,
    ) -> Result<Value, Value> {
        let id = self.request(method, params);
        let got = self.wait_note_until(|v| is_response(v, id), deadline);
        self.writer.set_read_timeout(Some(STEP)).unwrap();
        let v = got.map_err(|e| json!({"method": method, "io": e.to_string()}))?;
        match v.get("error") {
            Some(e) => Err(e.clone()),
            None => Ok(v["result"].clone()),
        }
    }

    /// Writes a request without waiting for its response: its id.
    fn request(&mut self, method: &str, params: Value) -> u64 {
        self.next += 1;
        let line = json!({"jsonrpc": "2.0", "id": self.next, "method": method, "params": params});
        self.writer.write_all(format!("{line}\n").as_bytes()).unwrap();
        self.next
    }

    /// The response to request `id`, kept or read now: its result, or its error.
    fn response(&mut self, id: u64) -> Result<Value, Value> {
        let v = self.wait_note(|v| is_response(v, id));
        match v.get("error") {
            Some(e) => Err(e.clone()),
            None => Ok(v["result"].clone()),
        }
    }

    /// The next line; a timeout keeps what it read of the line for the next read.
    fn read(&mut self) -> std::io::Result<Value> {
        let n = self.reader.read_line(&mut self.line)?;
        assert!(n > 0, "the daemon closed the socket");
        self.read_bytes += n as u64;
        self.longest_line = self.longest_line.max(self.line.len() as u64);
        Ok(serde_json::from_str(&std::mem::take(&mut self.line)).unwrap())
    }

    /// The first line, kept or read now, that `pred` takes; the others read meanwhile are kept.
    fn wait_note(&mut self, pred: impl Fn(&Value) -> bool) -> Value {
        self.wait_note_until(pred, None).unwrap()
    }

    /// [`Rpc::wait_note`] until `deadline` at most (each read's timeout is the time left), or
    /// [`STEP`] for each read. The caller restores the timeout.
    fn wait_note_until(
        &mut self,
        pred: impl Fn(&Value) -> bool,
        deadline: Option<Instant>,
    ) -> std::io::Result<Value> {
        if let Some(at) = self.notes.iter().position(&pred) {
            return Ok(self.notes.remove(at));
        }
        loop {
            if let Some(deadline) = deadline {
                let left = deadline.saturating_duration_since(Instant::now());
                if left.is_zero() {
                    return Err(std::io::ErrorKind::TimedOut.into());
                }
                self.writer.set_read_timeout(Some(left))?;
            }
            let v = self.read()?;
            if pred(&v) {
                return Ok(v);
            }
            self.notes.push(v);
        }
    }
}

/// `v` answers request `id` (a response has no method; a request from the daemon may share ids).
fn is_response(v: &Value, id: u64) -> bool {
    v.get("method").is_none() && v.get("id") == Some(&json!(id))
}

/// A TCP proxy in front of one peer's WebSocket listener: [`Proxy::cut`] closes every
/// connection through it at once, and new ones are taken as before.
struct Proxy {
    port: u16,
    links: Arc<std::sync::Mutex<Vec<tokio::task::AbortHandle>>>,
}

impl Proxy {
    async fn start(backend: u16) -> Self {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let links: Arc<std::sync::Mutex<Vec<tokio::task::AbortHandle>>> = Arc::default();
        let held = links.clone();
        tokio::spawn(async move {
            while let Ok((mut client, _)) = listener.accept().await {
                let task = tokio::spawn(async move {
                    let Ok(mut server) =
                        tokio::net::TcpStream::connect(("127.0.0.1", backend)).await
                    else {
                        return;
                    };
                    let _ = tokio::io::copy_bidirectional(&mut client, &mut server).await;
                });
                held.lock().unwrap().push(task.abort_handle());
            }
        });
        Self { port, links }
    }

    fn cut(&self) {
        for link in self.links.lock().unwrap().drain(..) {
            link.abort();
        }
    }
}

/// `shape.peers` hubs in this process, each listing `shape.peer_rows` chats, served with a peer
/// token behind a [`Proxy`]: the `peers` of the daemon's config and the proxies.
async fn peers(shape: &Shape, scratch: &Path) -> (Value, Vec<Proxy>, Vec<Arc<Hub>>) {
    let (mut config, mut proxies, mut hubs) = (serde_json::Map::new(), vec![], vec![]);
    for p in 0..shape.peers {
        let name = format!("peer{p:02}");
        let mut cfg = Config::default();
        cfg.store.mode = StoreMode::Memory;
        let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
        for i in 0..shape.peer_rows {
            store.save(&serde_json::from_value(god_fixture::peer_meta(&name, i)).unwrap()).unwrap();
        }
        let hub = Hub::new(cfg, store);
        let home = scratch.join(format!("peer-{p}"));
        std::fs::create_dir_all(&home).unwrap();
        let auth = PeerAuth::create(&home).unwrap();
        let token = std::fs::read_to_string(acpmux::server::peer_auth::token_path(&home)).unwrap();
        let listener = bind_ws("127.0.0.1:0").await.unwrap();
        let backend = listener.local_addr().unwrap().port();
        let auth = WsAuth { local_app: None, peer: Some(Arc::new(auth)) };
        tokio::spawn(serve_ws_with(hub.clone(), listener, "tok".into(), auth));
        let proxy = Proxy::start(backend).await;
        config.insert(
            name,
            json!({"url": format!("ws://127.0.0.1:{}", proxy.port), "token": "tok",
                   "peerToken": token.trim()}),
        );
        proxies.push(proxy);
        hubs.push(hub);
    }
    (Value::Object(config), proxies, hubs)
}

struct Daemon {
    child: Child,
    socket: PathBuf,
    spawned: Instant,
}

impl Daemon {
    fn start(scratch: &Path, home: &Path, dhat: Option<&Path>) -> Self {
        let socket = scratch.join("s.sock");
        let mut command = daemon_env::command(scratch, daemon_env::Agents::StandIn, &[]);
        command
            .args(["daemon", "run", "--ready-fd", "1", "--log", "warn"])
            .env("ACPMUX_HOME", home)
            .env("ACPMUX_SOCKET", &socket)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit());
        if let Some(out) = dhat {
            command.env(acpmux::heap_profile::OUT_ENV, out);
        }
        let spawned = Instant::now();
        let mut child = command.spawn().unwrap();
        let stdout = child.stdout.take().unwrap();
        for line in BufReader::new(stdout).lines() {
            if let Ok(v) = serde_json::from_str::<Value>(&line.unwrap())
                && v["ready"] == true
            {
                return Self { child, socket, spawned };
            }
        }
        let _ = child.kill();
        let _ = child.wait();
        panic!("the daemon exited without a readiness line");
    }

    /// `VmRSS` and `VmHWM` of the daemon, in bytes.
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

    /// SIGTERM, then the exit: the daemon writes its heap profile on the way out.
    fn stop(mut self) {
        // SAFETY: the pid is this test's own child, not yet reaped.
        unsafe { libc::kill(self.child.id() as i32, libc::SIGTERM) };
        let _ = self.child.wait();
    }
}

/// Every peer connected and its rows listed: `peers` connected and `rows` remote sessions.
fn peers_listed(rpc: &mut Rpc, peers: usize, rows: usize) -> bool {
    let Ok(status) = rpc.call("_acpmux/status", json!({})) else { return false };
    let connected = status["peers"]
        .as_array()
        .map_or(0, |p| p.iter().filter(|p| p["connected"] == true).count());
    connected == peers && status["remoteSessions"].as_u64().unwrap_or(0) as usize >= rows
}

fn wait_listed(rpc: &mut Rpc, peers: usize, rows: usize) -> Option<u64> {
    let started = Instant::now();
    while started.elapsed() < STEP {
        if peers_listed(rpc, peers, rows) {
            return Some(ms(started));
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    None
}

/// The daemon's config: the peers, and `claude` as the stand-in agent.
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

/// One home's run: its numbers, and its heap profile's path when one was asked for.
async fn run(shape: Shape, dhat: bool) -> Value {
    let scratch = std::env::temp_dir().join(format!("god-{}-{}", shape.name, std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).unwrap();
    let home = scratch.join("acpmux");
    let claude = daemon_env::home(&scratch).join(".claude");
    let written = Instant::now();
    let made = god_fixture::write_home(&home, &claude, &scratch.join("work"), &shape).unwrap();
    let write_ms = ms(written);
    let (peer_config, proxies, _hubs) = peers(&shape, &scratch).await;
    let proxies = Arc::new(proxies);
    write_config(&home, peer_config);
    // What the fixture (and the config) put in the home, before the daemon starts.
    let fixture_files = home_files(&home);
    let fixture_bytes: u64 = fixture_files.values().sum();
    let rows = shape.peers * shape.peer_rows;
    let profile = dhat.then(|| scratch.join("dhat-heap.json"));

    let shape_name = shape.name;
    let god = made.god.clone();
    let cutter = proxies.clone();
    let result = tokio::task::spawn_blocking(move || {
        let daemon = Daemon::start(&scratch, &home, profile.as_deref());
        let ready_ms = ms(daemon.spawned);
        let mut rpc = Rpc::connect(&daemon.socket);
        rpc.call("initialize", json!({"protocolVersion": 1, "clientInfo": {"name": "god-bench"}}))
            .unwrap();
        let list = rpc.call("_acpmux/watch", json!({"enabled": true}));
        let first_list_ms = ms(daemon.spawned);
        let listed =
            list.as_ref().map(|l| l["sessions"].as_array().map_or(0, Vec::len)).unwrap_or(0);
        let peers_ms = wait_listed(&mut rpc, shape.peers, rows).map(|_| ms(daemon.spawned));

        // The pane's open of the god chat, again and again: a page of its newest records. One
        // that fails is counted, not timed.
        let (mut attaches, mut attach) = (vec![], Ok(Value::Null));
        let (mut attach_errors, mut attach_error) = (0u64, Value::Null);
        for _ in 0..ROUNDS {
            let attached = Instant::now();
            attach = rpc.call(
                "_acpmux/attach",
                json!({"sessionId": god, "waitLogs": false, "limit": PAGE_LIMIT,
                       "maxBytes": PAGE_BYTES}),
            );
            let us = micros(attached);
            match &attach {
                Ok(_) => attaches.push(us),
                Err(e) => {
                    attach_errors += 1;
                    if attach_error.is_null() {
                        attach_error = e.clone();
                    }
                }
            }
            rpc.notes.clear();
        }

        // The pane's scroll up: each page the one before the oldest record held. At the chat's
        // start it begins again from the attach's page, so a short chat gives as many pages.
        let (mut scrolls, mut scroll_error, mut scroll_wraps) = (vec![], Value::Null, 0u64);
        let newest_oldest = attach.as_ref().ok().and_then(oldest_seq);
        match newest_oldest {
            None => scroll_error = json!("the attach gave no page to scroll up from"),
            Some(start) => {
                let mut before = start;
                for _ in 0..ROUNDS {
                    let (us, page) = older_page(&mut rpc, &god, before);
                    let page = match page {
                        Ok(page) => page,
                        Err(e) => {
                            scroll_error = e;
                            break;
                        }
                    };
                    scrolls.push(us);
                    match oldest_seq(&page).filter(|_| page["hasMore"] == true) {
                        Some(oldest) => before = oldest,
                        None => {
                            before = start;
                            scroll_wraps += 1;
                        }
                    }
                }
            }
        }

        // A jump to the middle of the god chat's history: before half its last seq, a page
        // further back each round so no round reads the one before it.
        let (mut deeps, mut deep_error) = (vec![], Value::Null);
        match attach.as_ref().ok().and_then(|a| a["lastSeq"].as_u64()) {
            None => deep_error = json!("the attach gave no lastSeq"),
            Some(last) => {
                for round in 0..DEEP_ROUNDS as u64 {
                    let before = (last / 2).saturating_sub(round * PAGE_LIMIT).max(1);
                    let (us, page) = older_page(&mut rpc, &god, before);
                    if let Err(e) = page {
                        deep_error = e;
                        break;
                    }
                    deeps.push(us);
                }
            }
        }

        // A prompt to the god chat until its first streamed chunk, not its turn's end (the
        // prompt's response); the first starts its agent. A prompt that fails ends the rounds.
        let (mut sends, mut send) = (vec![], Ok(()));
        for round in 0..ROUNDS {
            let sent = Instant::now();
            let text = format!("hello {round}");
            let prompt = json!({"sessionId": god, "prompt": [{"type": "text", "text": text}]});
            let id = rpc.request("session/prompt", prompt);
            let first = rpc.wait_note(|v| {
                (is_response(v, id) && v.get("error").is_some())
                    || (v["method"] == "session/update"
                        && v["params"]["sessionId"] == json!(god)
                        && v["params"]["update"]["sessionUpdate"] == "agent_message_chunk"
                        && v["params"]["update"]["content"]["text"]
                            .as_str()
                            .is_some_and(|t| t.contains(&text)))
            });
            if let Some(error) = first.get("error").filter(|_| is_response(&first, id)) {
                send = Err(error.clone());
                break;
            }
            sends.push(micros(sent));
            send = rpc.response(id).map(|_| ());
            if send.is_err() {
                break;
            }
            rpc.notes.clear();
        }
        let first_send_ms = sends.first().map(|us| us / 1000);
        // None past the first when the first prompt failed.
        let later_sends = sends.get(1..).unwrap_or_default();

        // Every chat log read, however long after the steps above it ends.
        let all_logs = wait_all_logs(&mut rpc);

        // The same attaches, scroll and prompts once every log is read: what a long chat costs
        // on its own, apart from the startup load it shares the machine with above. A step that
        // fails is counted, its first error kept, and not timed.
        let (mut settled_attaches, mut settled_attach) = (vec![], None);
        let (mut settled_attach_errors, mut settled_attach_error) = (0u64, Value::Null);
        for _ in 0..ROUNDS {
            let attached = Instant::now();
            let reply = rpc.call(
                "_acpmux/attach",
                json!({"sessionId": god, "waitLogs": false, "limit": PAGE_LIMIT,
                       "maxBytes": PAGE_BYTES}),
            );
            let us = micros(attached);
            match reply {
                Ok(reply) => {
                    settled_attaches.push(us);
                    settled_attach = Some(reply);
                }
                Err(e) => {
                    settled_attach_errors += 1;
                    if settled_attach_error.is_null() {
                        settled_attach_error = e;
                    }
                }
            }
            rpc.notes.clear();
        }
        // From the last settled attach's page, as the pane would scroll from it.
        let mut settled_scrolls = vec![];
        let (mut settled_scroll_errors, mut settled_scroll_error) = (0u64, Value::Null);
        match settled_attach.as_ref().and_then(oldest_seq) {
            None => {
                settled_scroll_errors += 1;
                settled_scroll_error = json!("the settled attach gave no page to scroll up from");
            }
            Some(start) => {
                let mut before = start;
                for _ in 0..ROUNDS {
                    let (us, page) = older_page(&mut rpc, &god, before);
                    let page = match page {
                        Ok(page) => page,
                        Err(e) => {
                            settled_scroll_errors += 1;
                            if settled_scroll_error.is_null() {
                                settled_scroll_error = e;
                            }
                            continue;
                        }
                    };
                    settled_scrolls.push(us);
                    before = oldest_seq(&page).filter(|_| page["hasMore"] == true).unwrap_or(start);
                }
            }
        }
        let (mut settled_sends, mut settled_send_error) = (vec![], Value::Null);
        // The bytes each prompt's turn sends this client, from the request to its response.
        let (mut settled_send_bytes, mut settled_send_longest) = (vec![], 0);
        for round in 0..ROUNDS {
            let sent = Instant::now();
            let (bytes_before, longest_before) = (rpc.read_bytes, rpc.longest_line);
            rpc.longest_line = 0;
            let text = format!("settled {round}");
            let prompt = json!({"sessionId": god, "prompt": [{"type": "text", "text": text}]});
            let id = rpc.request("session/prompt", prompt);
            let first = rpc.wait_note(|v| {
                (is_response(v, id) && v.get("error").is_some())
                    || (v["method"] == "session/update"
                        && v["params"]["sessionId"] == json!(god)
                        && v["params"]["update"]["sessionUpdate"] == "agent_message_chunk"
                        && v["params"]["update"]["content"]["text"]
                            .as_str()
                            .is_some_and(|t| t.contains(&text)))
            });
            if is_response(&first, id) {
                settled_send_error = first["error"].clone();
                break;
            }
            settled_sends.push(micros(sent));
            if let Err(e) = rpc.response(id) {
                settled_send_error = e;
                break;
            }
            settled_send_bytes.push(rpc.read_bytes - bytes_before);
            settled_send_longest = settled_send_longest.max(rpc.longest_line);
            rpc.longest_line = rpc.longest_line.max(longest_before);
            rpc.notes.clear();
        }

        // From the cut until every peer is listed again.
        let mut reconnect_ms = vec![];
        for _ in 0..3 {
            let cut = Instant::now();
            for proxy in cutter.iter() {
                proxy.cut();
            }
            // The links notice the cut, then list again.
            std::thread::sleep(Duration::from_millis(200));
            reconnect_ms.push(wait_listed(&mut rpc, shape.peers, rows).map(|_| ms(cut)));
        }
        let reconnect_median_ms =
            median(&reconnect_ms.iter().flatten().copied().collect::<Vec<_>>());
        let status = rpc.call("_acpmux/status", json!({})).unwrap_or_default();
        let (startup_phases_ms, marks_ms) = startup_axes(&status["gauges"]);
        let (rss, peak_rss) = daemon.rss();
        drop(rpc);
        daemon.stop();
        let home_files = home_files(&home);
        let home_bytes: u64 = home_files.values().sum();
        let (daemon_added, daemon_removed, daemon_removed_top) =
            disk_change(&home, &fixture_files, &home_files);
        let heap = profile.as_deref().map(attribute);
        json!({
            "shape": shape_name, "chats": shape.chats, "godMessages": shape.god_messages,
            "godLogBytes": made.god_log_bytes, "godJsonlBytes": made.god_jsonl_bytes,
            "peers": shape.peers, "peerRows": shape.peer_rows, "listed": listed,
            "writeMs": write_ms, "readyMs": ready_ms, "firstListMs": first_list_ms,
            "peersMs": peers_ms, "attachUs": spread(&attaches), "attachOk": attach.is_ok(),
            "attachErrors": attach_errors, "attachError": attach_error,
            "scrollPageUs": spread(&scrolls), "scrollWraps": scroll_wraps,
            "scrollError": scroll_error,
            "deepScrollUs": spread(&deeps), "deepScrollError": deep_error,
            "firstSendFirstTokenMs": first_send_ms, "sendFirstTokenUs": spread(later_sends),
            "sendError": send.err(),
            "allLogsMs": all_logs.as_ref().ok(), "allLogsError": all_logs.as_ref().err(),
            "settledAttachUs": spread(&settled_attaches),
            "settledAttachErrors": settled_attach_errors,
            "settledAttachError": settled_attach_error,
            "settledScrollPageUs": spread(&settled_scrolls),
            "settledScrollErrors": settled_scroll_errors,
            "settledScrollError": settled_scroll_error,
            "settledSendFirstTokenUs": spread(&settled_sends),
            "settledSendError": settled_send_error,
            "settledSendBytes": spread(&settled_send_bytes),
            "settledSendLongestLine": settled_send_longest,
            "reconnectMs": reconnect_ms, "reconnectMedianMs": reconnect_median_ms,
            "rss": rss, "peakRss": peak_rss,
            "fixtureBytes": fixture_bytes, "homeBytes": home_bytes,
            "daemonAddedBytes": daemon_added, "daemonRemovedBytes": daemon_removed,
            "daemonRemoved": daemon_removed_top,
            "startupPhasesMs": startup_phases_ms, "marksMs": marks_ms,
            "gauges": status["gauges"], "heap": heap,
        })
    })
    .await
    .unwrap();
    for proxy in proxies.iter() {
        proxy.cut();
    }
    result
}

/// The frame a dhat site is named by: the first one in acpmux's own code below the allocator,
/// with the function and its file and line.
/// With line tables, a generic frame (`poll<acpmux::...>`, `call_mut<...>`) names acpmux in its
/// type and a std file as its place: only a frame whose file is under `acpmux/src/` is acpmux's.
/// The site is the first three such frames, innermost first.
fn acpmux_frame(frames: &[&str]) -> String {
    let own: Vec<String> =
        frames.iter().filter(|f| own_file(f)).take(3).map(|f| place(f)).collect();
    if own.is_empty() {
        return frames.get(1).map_or_else(|| "[unknown]".to_owned(), |f| short_frame(f));
    }
    own.join(" < ")
}

/// A frame in acpmux's own source, not the allocator hook in `main.rs` or the profiler's.
fn own_file(frame: &str) -> bool {
    frame.contains("acpmux/src/")
        && !frame.contains("acpmux/src/main.rs")
        && !frame.contains("heap_profile")
}

/// A frame as `function (file:line)`: the function's last two path segments, its generics cut.
fn place(frame: &str) -> String {
    let frame = short_frame(frame);
    let (name, file) = frame.rsplit_once(" (").map_or((frame.as_str(), ""), |(n, f)| (n, f));
    let name = name.split('<').next().unwrap_or(name);
    let name: Vec<&str> = name.rsplit("::").take(2).collect();
    let file = file.trim_end_matches(')').split("acpmux/src/").last().unwrap_or(file);
    format!("{} ({file})", name.into_iter().rev().collect::<Vec<_>>().join("::"))
}

/// `0x1234: acpmux::watch_delta::Known::patched (src/watch_delta.rs:107:9)` without the address
/// and the hash.
fn short_frame(frame: &str) -> String {
    let frame = frame.split_once(": ").map_or(frame, |(_, f)| f);
    let frame = frame.replace("/home/runner/", "").replace("cmux-tui/crates/acpmux/", "");
    let hashless: String = frame.split("::h").next().unwrap_or(&frame).to_owned();
    if hashless.len() < frame.len() {
        // `::h<hash>` came before the file: keep the file.
        let file = frame.rsplit_once(" (").map(|(_, f)| format!(" ({f}")).unwrap_or_default();
        return format!("{hashless}{file}");
    }
    frame
}

/// The dhat profile at `path`, by acpmux site: bytes and blocks at the heap's peak and in total,
/// the largest first; and the sites of blocks of 600 to 700 bytes (serde_json's BTreeMap leaf
/// nodes are 640) at the peak.
fn attribute(path: &Path) -> Value {
    let Ok(text) = std::fs::read_to_string(path) else {
        return json!({"error": format!("no profile at {}", path.display())});
    };
    let doc: Value = serde_json::from_str(&text).unwrap();
    let ftbl: Vec<&str> =
        doc["ftbl"].as_array().unwrap().iter().map(|f| f.as_str().unwrap_or("")).collect();
    let top = std::env::var("ACPMUX_GOD_DHAT_TOP").ok().and_then(|v| v.parse().ok()).unwrap_or(30);
    #[derive(Default)]
    struct Site {
        gb: u64,
        gbk: u64,
        tb: u64,
        tbk: u64,
        leaf_gb: u64,
        leaf_gbk: u64,
        inner: BTreeMap<String, u64>,
    }
    let mut sites: BTreeMap<String, Site> = BTreeMap::new();
    let (mut peak, mut leaves) = (0u64, 0u64);
    for pp in doc["pps"].as_array().unwrap() {
        let frames: Vec<&str> = pp["fs"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(|i| ftbl.get(i.as_u64()? as usize).copied())
            .collect();
        let gb = pp["gb"].as_u64().unwrap_or(0);
        let gbk = pp["gbk"].as_u64().unwrap_or(0);
        let site = sites.entry(acpmux_frame(&frames)).or_default();
        site.gb += gb;
        site.gbk += gbk;
        site.tb += pp["tb"].as_u64().unwrap_or(0);
        site.tbk += pp["tbk"].as_u64().unwrap_or(0);
        // The library frame that asked (serde_json, imbl, String), below the allocator's own.
        let inner = frames
            .iter()
            .find(|f| !f.contains("alloc::") && !f.contains("dhat") && !f.contains("[root]"))
            .map_or_else(|| "[unknown]".to_owned(), |f| short_frame(f));
        *site.inner.entry(inner).or_default() += gb;
        peak += gb;
        if gbk > 0 && (600..=700).contains(&(gb / gbk)) {
            site.leaf_gb += gb;
            site.leaf_gbk += gbk;
            leaves += gb;
        }
    }
    let row = |(name, s): (&String, &Site)| {
        let mut inner: Vec<(&String, &u64)> = s.inner.iter().collect();
        inner.sort_by_key(|(_, b)| std::cmp::Reverse(**b));
        json!({"site": name, "peakBytes": s.gb, "peakBlocks": s.gbk, "totalBytes": s.tb,
               "totalBlocks": s.tbk, "leafPeakBytes": s.leaf_gb, "leafPeakBlocks": s.leaf_gbk,
               "via": inner.into_iter().take(3).map(|(f, b)| json!([f, b])).collect::<Vec<_>>()})
    };
    let mut by_peak: Vec<(&String, &Site)> = sites.iter().collect();
    by_peak.sort_by_key(|(_, s)| std::cmp::Reverse(s.gb));
    let mut by_total: Vec<(&String, &Site)> = sites.iter().collect();
    by_total.sort_by_key(|(_, s)| std::cmp::Reverse(s.tb));
    let mut by_leaf: Vec<(&String, &Site)> = sites.iter().filter(|(_, s)| s.leaf_gb > 0).collect();
    by_leaf.sort_by_key(|(_, s)| std::cmp::Reverse(s.leaf_gb));
    json!({
        "peakBytes": peak,
        "leafPeakBytes": leaves,
        "byPeak": by_peak.into_iter().take(top).map(row).collect::<Vec<_>>(),
        "byTotal": by_total.into_iter().take(top).map(row).collect::<Vec<_>>(),
        "leavesBySite": by_leaf.into_iter().take(top).map(row).collect::<Vec<_>>(),
    })
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "manual: the god home is 2 GB on disk; run on Linux CI"]
async fn god_and_small_homes_in_one_harness() {
    let shapes = std::env::var("ACPMUX_GOD_SHAPES").unwrap_or_else(|_| "small,god".to_owned());
    let dhat = std::env::var("ACPMUX_GOD_DHAT").is_ok_and(|v| v == "1");
    let mut results = vec![];
    for name in shapes.split(',') {
        let shape = match name.trim() {
            "small" => Shape::small(),
            "god" => Shape::god_from_env(),
            other => panic!("ACPMUX_GOD_SHAPES: no shape {other}"),
        };
        let result = run(shape, dhat).await;
        println!("GOD-BASELINE {result}");
        results.push(result);
    }
    // The comparison the bar reads: god over small, for each number both have.
    if let [small, god] = &results[..] {
        let ratio = |k: &str| match (
            small.pointer(k).and_then(Value::as_f64),
            god.pointer(k).and_then(Value::as_f64),
        ) {
            (Some(s), Some(g)) if s > 0.0 => json!(g / s),
            _ => Value::Null,
        };
        // A JSON pointer escapes '~' as ~0 and '/' as ~1; a space stays as it is.
        let keys = [
            "/readyMs",
            "/firstListMs",
            "/peersMs",
            "/attachUs/p50",
            "/attachUs/p95",
            "/attachUs/max",
            "/scrollPageUs/p95",
            "/deepScrollUs/p95",
            "/settledAttachUs/p95",
            "/settledAttachUs/max",
            "/settledScrollPageUs/p95",
            "/settledSendFirstTokenUs/p95",
            "/settledSendBytes/p50",
            "/settledSendLongestLine",
            "/firstSendFirstTokenMs",
            "/sendFirstTokenUs/p95",
            "/reconnectMedianMs",
            "/allLogsMs",
            "/marksMs/agents may spawn",
            "/rss",
            "/peakRss",
            "/daemonAddedBytes",
            "/heap/peakBytes",
        ];
        // A number missing in either home (no heap profile, a step that failed) is left out.
        let ratios: serde_json::Map<String, Value> = keys
            .iter()
            .map(|k| ((*k).to_owned(), ratio(k)))
            .filter(|(_, r)| !r.is_null())
            .collect();
        println!("GOD-RATIO {}", Value::Object(ratios));
    }
    // A settled step that failed reads as no time at all: the run fails, every home printed.
    for r in &results {
        assert!(
            r["settledAttachErrors"] == 0
                && r["settledScrollErrors"] == 0
                && r["settledSendError"].is_null(),
            "{}: a settled step failed: attach {} {}, scroll {} {}, send {}",
            r["shape"],
            r["settledAttachErrors"],
            r["settledAttachError"],
            r["settledScrollErrors"],
            r["settledScrollError"],
            r["settledSendError"],
        );
    }
}
