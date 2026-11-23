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
//! - the attach flood, which no timing moves (`GOD-FLOOD`, [`flood_json`]): the peer rows'
//!   `_acpmux/session_changed` notices queued for the test's client from the peers' lists to the
//!   end of those attaches (`attachNoticesAhead`), the most one list queued
//!   (`attachNoticesAheadMax`), and their bytes per list (`noticeBytesPerPeerList`). The peers'
//!   proxies carry no link until the client watches, and a change of one peer row after the
//!   attaches ends the window ([`flood_end`]). `attachUs` waits on these notices: with none ahead
//!   an attach takes about 1 ms. With `ACPMUX_GOD_PEER_ROW_BATCHES=1` the client asks for peer
//!   row batches (`peerRowBatches`): each peer's list is one `_acpmux/peer_rows_changed`
//!   (`batchNotices`, counted in `attachNoticesAhead`), and once the window ends the client reads
//!   the rows with one paged follow of the list (`catchUp`, [`catch_up`]);
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

// The baseline's `json!` has more keys than the default limit expands, as in `lib.rs`.
#![recursion_limit = "256"]
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// The prompt goes to tests/fake_agent.py; the sizes and the profile switch hold no credential.
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in().keep(&[
    "ACPMUX_GOD_SHAPES",
    "ACPMUX_GOD_SCALE",
    "ACPMUX_GOD_DHAT",
    "ACPMUX_GOD_DHAT_TOP",
    // A control artifact for differential runs; the child still uses the hermetic environment.
    "ACPMUX_GOD_DAEMON_BIN",
    // `1`: the test client asks for peer row batches (`peerRowBatches`, `run_with`).
    "ACPMUX_GOD_PEER_ROW_BATCHES",
    // The churn lab's knobs (`whole_lists_of_a_peer_that_cannot_follow_under_churn`).
    "ACPMUX_CHURN_ROWS",
    "ACPMUX_CHURN_SECS",
    "ACPMUX_CHURN_EVERY_MS",
    "ACPMUX_CHURN_CPUS",
    "ACPMUX_CHURN_BUSY",
    "ACPMUX_CHURN_FOLLOW",
    "ACPMUX_CHURN_ARENAS",
    // The growth lab's knobs (`god_daemon/growth.rs`).
    "ACPMUX_GROWTH_SECS",
    "ACPMUX_GROWTH_ROWS",
    "ACPMUX_GROWTH_STABLE",
    "ACPMUX_GROWTH_CHURN",
    "ACPMUX_GROWTH_SSH_DOWN",
    "ACPMUX_GROWTH_CUT_MS",
    "ACPMUX_GROWTH_CHATS",
    "ACPMUX_GROWTH_CLIENTS",
    "ACPMUX_GROWTH_CLIENT_MS",
    "ACPMUX_GROWTH_SLOW",
    "ACPMUX_GROWTH_STACKS",
]);

/// The growth lab: a daemon with many sessions under a mesh of peers that come and go.
#[cfg(target_os = "linux")]
#[path = "god_daemon/growth.rs"]
mod growth;

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
const MARKS: [&str; 4] = ["socket ready", "requests ready", "first list reply", "agents may spawn"];

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
    /// The peer rows' `_acpmux/session_changed` notices read, but for the marker's
    /// ([`MARKER_KINDS`]): how many, their bytes, and how many of each peer; and the events
    /// dropped.
    flood: Flood,
    /// The `_acpmux/peer_rows_changed` notices read, as they came: what a client that asked for
    /// batches follows the list for ([`catch_up`]).
    batch_notes: Vec<Value>,
}

/// `_acpmux/session_changed` notices of peer rows (`peer` set) a client read, and the hub events
/// its connection's fan-out dropped instead (`_acpmux/lagged`'s `dropped`): the hub's broadcast
/// holds 8,192 events, and 26 lists of 400 rows announced at once overrun it. A client that asked
/// for peer row batches (`peerRowBatches`) reads one `_acpmux/peer_rows_changed` per list instead
/// (`batches`). Its fan-out still takes every row's hub event, and when it falls behind it hears
/// one `_acpmux/lagged` with `watch: true` (`watch_lags`) and follows the list for what it missed:
/// those dropped events were never its notices, so they are not `dropped` (2 of 24 god runs).
#[derive(Clone, Default)]
struct Flood {
    notices: u64,
    bytes: u64,
    by_peer: BTreeMap<String, u64>,
    dropped: u64,
    batches: u64,
    batch_bytes: u64,
    watch_lags: u64,
}

impl Flood {
    /// What was read since `before`, a copy of this taken earlier.
    fn since(&self, before: &Flood) -> Flood {
        let by_peer = self
            .by_peer
            .iter()
            .map(|(p, n)| (p.clone(), n - before.by_peer.get(p).unwrap_or(&0)))
            .filter(|(_, n)| *n > 0)
            .collect();
        Flood {
            notices: self.notices - before.notices,
            bytes: self.bytes - before.bytes,
            by_peer,
            dropped: self.dropped - before.dropped,
            batches: self.batches - before.batches,
            batch_bytes: self.batch_bytes - before.batch_bytes,
            watch_lags: self.watch_lags - before.watch_lags,
        }
    }

    /// Every flood notice queued for the client: those it read and those its fan-out dropped,
    /// a batch's one notice included.
    fn queued(&self) -> u64 {
        self.notices + self.dropped + self.batches + self.watch_lags
    }

    /// Their bytes: those read, and the dropped ones at the mean of the row notices read.
    fn queued_bytes(&self) -> u64 {
        let mean = self.bytes as f64 / self.notices.max(1) as f64;
        (self.bytes as f64 + mean * self.dropped as f64).round() as u64 + self.batch_bytes
    }
}

/// The record kind of the change the test makes to one peer row once the attaches are done
/// ([`flood_end`]): the daemon's one notice loop takes it after every list before it, so its
/// notice is the last of theirs this client reads.
const MARKER_KIND: &str = "rules";

/// The records `Hub::set_rules` appends, the marker's last: neither is a flood notice, and no
/// fixture row changes so.
const MARKER_KINDS: [&str; 2] = ["permission_chat_allowance", MARKER_KIND];

/// A peer row's `_acpmux/session_changed`: its peer and record kind.
fn peer_change(v: &Value) -> Option<(&str, &str)> {
    if v["method"] != "_acpmux/session_changed" {
        return None;
    }
    let params = &v["params"];
    let peer = params["peer"].as_str()?;
    let kind = params["recordKind"].as_str().or_else(|| params["kind"].as_str()).unwrap_or("");
    Some((peer, kind))
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
            flood: Flood::default(),
            batch_notes: vec![],
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
        let line = std::mem::take(&mut self.line);
        let v: Value = serde_json::from_str(&line).unwrap();
        if let Some((peer, kind)) = peer_change(&v)
            && !MARKER_KINDS.contains(&kind)
        {
            self.flood.notices += 1;
            self.flood.bytes += line.len() as u64;
            *self.flood.by_peer.entry(peer.to_owned()).or_default() += 1;
        }
        if v["method"] == "_acpmux/lagged" {
            if v["params"]["watch"] == true {
                self.flood.watch_lags += 1;
            } else {
                self.flood.dropped += v["params"]["dropped"].as_u64().unwrap_or(0);
            }
        }
        if v["method"] == "_acpmux/peer_rows_changed" {
            self.flood.batches += 1;
            self.flood.batch_bytes += line.len() as u64;
            let peer = v["params"]["peer"].as_str().unwrap_or_default().to_owned();
            *self.flood.by_peer.entry(peer).or_default() += 1;
            self.batch_notes.push(v["params"].clone());
        }
        Ok(v)
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
    /// The listener new connections go to: [`Proxy::repoint`] moves it to a restarted peer.
    backend: Arc<std::sync::atomic::AtomicU16>,
    /// Connections it carried to the peer: each is one link, which reads the peer's list.
    carried: Arc<std::sync::atomic::AtomicU64>,
}

/// Held shut, a [`Proxy`] takes connections but carries none to its peer until it opens: no
/// peer's list reaches the daemon before the test's client watches the list.
type Gate = tokio::sync::watch::Receiver<bool>;

impl Proxy {
    async fn start(backend: u16) -> Self {
        Self::gated(backend, tokio::sync::watch::channel(true).1).await
    }

    async fn gated(backend: u16, gate: Gate) -> Self {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let links: Arc<std::sync::Mutex<Vec<tokio::task::AbortHandle>>> = Arc::default();
        let backend = Arc::new(std::sync::atomic::AtomicU16::new(backend));
        let carried = Arc::new(std::sync::atomic::AtomicU64::new(0));
        let (held, to, count) = (links.clone(), backend.clone(), carried.clone());
        tokio::spawn(async move {
            while let Ok((mut client, _)) = listener.accept().await {
                let (to, count, mut gate) = (to.clone(), count.clone(), gate.clone());
                let task = tokio::spawn(async move {
                    // A gate whose sender is gone stays as it was: shut, it carries nothing.
                    if gate.wait_for(|open| *open).await.is_err() {
                        return;
                    }
                    let backend = to.load(std::sync::atomic::Ordering::SeqCst);
                    let Ok(mut server) =
                        tokio::net::TcpStream::connect(("127.0.0.1", backend)).await
                    else {
                        return;
                    };
                    count.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                    let _ = tokio::io::copy_bidirectional(&mut client, &mut server).await;
                });
                held.lock().unwrap().push(task.abort_handle());
            }
        });
        Self { port, links, backend, carried }
    }

    /// Connections carried to the peer so far.
    fn carried(&self) -> u64 {
        self.carried.load(std::sync::atomic::Ordering::SeqCst)
    }

    // Only the churn lab (Linux) moves a proxy.
    #[cfg_attr(not(target_os = "linux"), allow(dead_code))]
    fn repoint(&self, backend: u16) {
        self.backend.store(backend, std::sync::atomic::Ordering::SeqCst);
    }

    fn cut(&self) {
        for link in self.links.lock().unwrap().drain(..) {
            link.abort();
        }
    }
}

/// `shape.peers` hubs in this process, each listing `shape.peer_rows` chats, served with a peer
/// token behind a [`Proxy`] held shut by `gate`: the `peers` of the daemon's config, the proxies
/// and the hubs.
async fn peers(shape: &Shape, scratch: &Path, gate: Gate) -> (Value, Vec<Proxy>, Vec<Arc<Hub>>) {
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
        let proxy = Proxy::gated(backend, gate.clone()).await;
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
    socket_connect_us: u64,
}

impl Daemon {
    fn start(scratch: &Path, home: &Path, dhat: Option<&Path>) -> Self {
        let socket = scratch.join("s.sock");
        let binary = std::env::var_os("ACPMUX_GOD_DAEMON_BIN")
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
            .stderr(Stdio::inherit());
        if let Some(out) = dhat {
            command.env(acpmux::heap_profile::OUT_ENV, out);
        }
        // glibc malloc's arena count for the daemon (the churn lab's `ACPMUX_CHURN_ARENAS`): RSS
        // that a cap shrinks is memory the allocator kept, not memory the daemon holds.
        if let Ok(arenas) = std::env::var("ACPMUX_CHURN_ARENAS") {
            command.env("MALLOC_ARENA_MAX", arenas);
        }
        let spawned = Instant::now();
        let mut child = command.spawn().unwrap();
        // Observe bind from a client too: moving an internal gauge alone cannot improve this
        // measurement. This probe is identical for a control binary and the changed daemon.
        loop {
            if UnixStream::connect(&socket).is_ok() {
                break;
            }
            if spawned.elapsed() >= STEP || child.try_wait().unwrap().is_some() {
                let _ = child.kill();
                let _ = child.wait();
                panic!("the daemon did not bind its socket");
            }
            std::thread::sleep(Duration::from_millis(1));
        }
        let socket_connect_us = micros(spawned);
        Self { child, socket, spawned, socket_connect_us }
    }

    /// The daemon's CPU time so far, user and system, in seconds (`/proc/PID/stat`).
    #[cfg(target_os = "linux")]
    fn cpu_seconds(&self) -> f64 {
        let stat =
            std::fs::read_to_string(format!("/proc/{}/stat", self.child.id())).unwrap_or_default();
        // The fields after the command name, which is in parentheses and may hold spaces, taken
        // by position: some before utime are negative (`tpgid` is -1 with no terminal).
        let rest = stat.rsplit_once(')').map_or("", |(_, r)| r);
        let fields: Vec<&str> = rest.split_whitespace().collect();
        // utime and stime are fields 14 and 15; `rest` starts at field 3, the state.
        let field = |n: usize| fields.get(n - 3).and_then(|f| f.parse::<u64>().ok()).unwrap_or(0);
        // SAFETY: sysconf reads a constant.
        let hz = unsafe { libc::sysconf(libc::_SC_CLK_TCK) }.max(1);
        (field(14) + field(15)) as f64 / hz as f64
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
    fn stop(&mut self) {
        // SAFETY: the pid is this test's own child, not yet reaped.
        unsafe { libc::kill(self.child.id() as i32, libc::SIGTERM) };
        let _ = self.child.wait();
    }

    /// The daemon's one-stop handoff through a cache-first attach (not an app render). The new
    /// daemon is allowed to bind and answer the local chat while peer links and bulk log loading
    /// continue in the background.
    fn restart_to_chat_attach(
        &mut self,
        scratch: &Path,
        home: &Path,
        profile: Option<&Path>,
        session: &str,
    ) -> (u64, u64) {
        let started = Instant::now();
        self.stop();
        let shutdown_ms = ms(started);
        *self = Self::start(scratch, home, profile);
        let mut rpc = Rpc::connect(&self.socket);
        rpc.call(
            "initialize",
            json!({"protocolVersion": 1, "clientInfo": {"name": "restart-bench"}}),
        )
        .unwrap();
        let attached = rpc.call(
            "_acpmux/attach",
            json!({"sessionId": session, "waitLogs": false, "limit": PAGE_LIMIT,
                   "maxBytes": PAGE_BYTES}),
        );
        let attached = attached.expect("selected chat attached after restart");
        assert!(
            attached["events"].as_array().is_some_and(|events| !events.is_empty()),
            "attach must return a usable transcript page: {attached}"
        );
        (ms(started), shutdown_ms)
    }
}

/// A run that panics does not leave its daemon writing into a scratch folder being removed.
impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// How long the client waits for the marker's notice after the attaches.
const MARKER_WAIT: Duration = Duration::from_secs(120);

/// The end of the attach-flood window: a change of `peer`'s first row on its hub, whose
/// `_acpmux/session_changed` the client then reads up to. The daemon's one notice loop applies
/// the peers' lists and announces each list's rows before it takes the next notice, and every
/// list was taken before this (the caller saw every row listed), so every notice the lists queued
/// for this connection comes before the marker's: what the client read from the window's start
/// (`from`) to the marker does not depend on when it read them. None, and why, when no marker
/// came.
fn flood_end(rpc: &mut Rpc, hub: &Hub, peer: &str, from: &Flood) -> Result<Flood, Value> {
    let id = format!("{peer}-00000");
    let Some(row) = hub.sessions().into_iter().find(|s| s.id == id) else {
        return Err(json!(format!("no row {id} on {peer}'s hub")));
    };
    hub.set_rules(&row, Some(json!({"default": "approve"})));
    let deadline = Some(Instant::now() + MARKER_WAIT);
    let got = rpc.wait_note_until(|v| peer_change(v) == Some((peer, MARKER_KIND)), deadline);
    rpc.writer.set_read_timeout(Some(STEP)).unwrap();
    rpc.notes.clear();
    got.map_err(|e| json!({"marker": MARKER_KIND, "io": e.to_string()}))?;
    Ok(rpc.flood.since(from))
}

/// The attach-flood numbers of one start, which no timing changes: the peer rows'
/// `_acpmux/session_changed` notices queued for the client from the first peer list's arrival to
/// the end of the attach loop (`attachNoticesAhead`: every one an attach in that loop can wait
/// behind), the most of them one peer's list queued (`attachNoticesAheadMax`: what an attach that
/// lands just after that list waits behind), and their bytes over the lists that arrived
/// (`noticeBytesPerPeerList`, `peerLists`: links the proxies carried to a peer, one list each).
/// Queued counts the ones the connection's fan-out dropped when it fell behind the hub's
/// broadcast (`noticesDropped`, told as `_acpmux/lagged`): which of them are dropped moves with
/// timing, their sum with the ones read does not. Dropped ones are weighed at the mean of those
/// read.
fn flood_json(window: &Result<Flood, Value>, lists: u64) -> Value {
    let Ok(w) = window else {
        return json!({"attachNoticesAhead": null, "attachNoticesAheadMax": null,
                      "noticeBytes": null, "noticeBytesPerPeerList": null, "peerLists": lists,
                      "noticesRead": null, "noticesDropped": null, "rowNotices": null,
                      "batchNotices": null, "watchLags": null,
                      "floodError": window.as_ref().err()});
    };
    let bytes = w.queued_bytes();
    json!({
        "attachNoticesAhead": w.queued(),
        "attachNoticesAheadMax": w.by_peer.values().max().copied().unwrap_or(0),
        "noticeBytes": bytes,
        "noticeBytesPerPeerList": bytes.checked_div(lists),
        "peerLists": lists,
        "noticesRead": w.notices,
        "noticesDropped": w.dropped,
        // Peer rows told one notice each (read or dropped), and peer lists told as one batch.
        "rowNotices": w.notices + w.dropped,
        "batchNotices": w.batches,
        // Falls behind told to a batch watcher, which follows the list for them.
        "watchLags": w.watch_lags,
        "floodError": null,
    })
}

/// What a client that asked for peer row batches does with the `_acpmux/peer_rows_changed` it
/// read: one follow of the list (`_acpmux/watch {afterSeq, listEpoch}`, `hub/row_log.rs`) from
/// below every batch (`cursor`, the watch reply's position, or a batch's `afterSeq` if lower), read
/// page by page while acpmux says `more`. Its numbers: the peer rows it read (by peer and id), the
/// fewest and most of one peer, the follow pages, their bytes and the time they took.
fn catch_up(rpc: &mut Rpc, cursor: Option<(u64, String)>) -> Value {
    let Some((seq, epoch)) = cursor else {
        return json!({"error": "the watch's reply named no list position"});
    };
    let after = rpc.batch_notes.iter().filter_map(|b| b["afterSeq"].as_u64()).fold(seq, u64::min);
    let started = Instant::now();
    let bytes_before = rpc.read_bytes;
    let mut rows: std::collections::BTreeSet<(String, String)> = Default::default();
    let (mut at, mut pages) = (after, 0u64);
    loop {
        pages += 1;
        let reply = match rpc
            .call("_acpmux/watch", json!({"enabled": true, "afterSeq": at, "listEpoch": epoch}))
        {
            Ok(reply) => reply,
            Err(e) => return json!({"error": e, "pages": pages}),
        };
        if reply["follow"] != true {
            return json!({"error": "acpmux could not follow the cursor", "reply": reply["reset"]});
        }
        for row in reply["sessions"].as_array().into_iter().flatten() {
            if let (Some(peer), Some(id)) = (row["peer"].as_str(), row["sessionId"].as_str()) {
                rows.insert((peer.to_owned(), id.to_owned()));
            }
        }
        let Some(next) = reply["listSeq"].as_u64() else {
            return json!({"error": "a follow named no list position", "pages": pages});
        };
        at = next;
        if reply["more"] != true {
            break;
        }
    }
    rpc.notes.clear();
    let mut by_peer: BTreeMap<&str, u64> = BTreeMap::new();
    for (peer, _) in &rows {
        *by_peer.entry(peer.as_str()).or_default() += 1;
    }
    json!({
        "rows": rows.len(),
        "peers": by_peer.len(),
        "fewestRowsOfAPeer": by_peer.values().min(),
        "mostRowsOfAPeer": by_peer.values().max(),
        "pages": pages,
        "bytes": rpc.read_bytes - bytes_before,
        "ms": ms(started),
        "error": null,
    })
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

/// [`attach_rounds`]' attaches: the time of each that answered, the last reply, the failures
/// and the first one's error, and the flood notices read ahead of each reply.
struct Attaches {
    attaches: Vec<u64>,
    attach: Result<Value, Value>,
    attach_errors: u64,
    attach_error: Value,
    read_ahead: Vec<u64>,
}

/// The pane's open of the god chat, [`ROUNDS`] times: a page of its newest records. One that
/// fails is counted, not timed.
fn attach_rounds(rpc: &mut Rpc, god: &str) -> Attaches {
    let mut a = Attaches {
        attaches: vec![],
        attach: Ok(Value::Null),
        attach_errors: 0,
        attach_error: Value::Null,
        read_ahead: vec![],
    };
    for _ in 0..ROUNDS {
        let before = rpc.flood.notices;
        let attached = Instant::now();
        a.attach = rpc.call(
            "_acpmux/attach",
            json!({"sessionId": god, "waitLogs": false, "limit": PAGE_LIMIT,
                   "maxBytes": PAGE_BYTES}),
        );
        let us = micros(attached);
        a.read_ahead.push(rpc.flood.notices - before);
        match &a.attach {
            Ok(_) => a.attaches.push(us),
            Err(e) => {
                a.attach_errors += 1;
                if a.attach_error.is_null() {
                    a.attach_error = e.clone();
                }
            }
        }
        rpc.notes.clear();
    }
    a
}

/// One home's run: its numbers, and its heap profile's path when one was asked for. The client
/// asks for peer row batches when `ACPMUX_GOD_PEER_ROW_BATCHES=1` ([`run_with`]).
async fn run(shape: Shape, dhat: bool) -> Value {
    let batches = std::env::var("ACPMUX_GOD_PEER_ROW_BATCHES").is_ok_and(|v| v == "1");
    run_with(shape, dhat, batches).await
}

/// [`run`], its client asking for peer row batches (`initialize` `_meta.acpmux.peerRowBatches`)
/// when `batches`: each peer's list then reaches it as one `_acpmux/peer_rows_changed`, and once
/// the attach-flood window ends it reads the rows with a follow of the list ([`catch_up`]). Its
/// scratch (2 GB for the god shape, a 1 GB daemon log of it) is removed when it returns or panics,
/// so runs do not pile up one per pid (they filled pool VMs, 2026-11-17); `"scratch"` names it, and
/// `ACPMUX_KEEP_SCRATCH=1` keeps it.
async fn run_with(shape: Shape, dhat: bool, batches: bool) -> Value {
    // Declared first, so dropped last: after the daemon, the peers' hubs and their proxies.
    let scratch_dir = daemon_env::Scratch::new(&format!("god-{}", shape.name));
    let scratch = scratch_dir.to_path_buf();
    let home = scratch.join("acpmux");
    let claude = daemon_env::home(&scratch).join(".claude");
    let written = Instant::now();
    let made = god_fixture::write_home(&home, &claude, &scratch.join("work"), &shape).unwrap();
    let write_ms = ms(written);
    let (gate, shut) = tokio::sync::watch::channel(false);
    let (peer_config, proxies, hubs) = peers(&shape, &scratch, shut).await;
    // peer00's hub, whose row change marks the end of the attach-flood window (`flood_end`).
    let marker = hubs.first().cloned();
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
        let mut daemon = Daemon::start(&scratch, &home, profile.as_deref());
        let ready_ms = ms(daemon.spawned);
        let socket_connect_us = daemon.socket_connect_us;
        let mut rpc = Rpc::connect(&daemon.socket);
        let meta = if batches { json!({"acpmux": {"peerRowBatches": true}}) } else { json!({}) };
        rpc.call(
            "initialize",
            json!({"protocolVersion": 1, "clientInfo": {"name": "god-bench"}, "_meta": meta}),
        )
        .unwrap();
        let list = rpc.call("_acpmux/watch", json!({"enabled": true}));
        // The list position the watch's reply is current to: a batch client follows from it.
        let list_cursor = list
            .as_ref()
            .ok()
            .and_then(|l| l["listSeq"].as_u64().zip(l["listEpoch"].as_str().map(str::to_owned)));
        let first_list_ms = ms(daemon.spawned);
        let listed =
            list.as_ref().map(|l| l["sessions"].as_array().map_or(0, Vec::len)).unwrap_or(0);
        // The peers' lists reach the daemon only now that this client watches, so every notice
        // they queue is this client's to read.
        let flood_from = rpc.flood.clone();
        gate.send_replace(true);
        let peers_ms = wait_listed(&mut rpc, shape.peers, rows).map(|_| ms(daemon.spawned));

        let Attaches { attaches, attach, attach_errors, attach_error, read_ahead } =
            attach_rounds(&mut rpc, &god);
        let window = match &marker {
            Some(hub) => flood_end(&mut rpc, hub, "peer00", &flood_from),
            None => Err(json!("no peer to mark the window's end")),
        };
        let lists = cutter.iter().map(Proxy::carried).sum::<u64>();
        let mut flood = flood_json(&window, lists);
        flood["peerRowBatches"] = json!(batches);
        flood["catchUp"] = if batches { catch_up(&mut rpc, list_cursor) } else { Value::Null };

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
        let (restart_chat_attach_ms, shutdown_ms) =
            daemon.restart_to_chat_attach(&scratch, &home, profile.as_deref(), &god);
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
            "socketConnectUs": socket_connect_us,
            "peersMs": peers_ms, "attachUs": spread(&attaches), "attachOk": attach.is_ok(),
            "attachErrors": attach_errors, "attachError": attach_error,
            "attachNoticesAhead": flood["attachNoticesAhead"],
            "attachNoticesAheadMax": flood["attachNoticesAheadMax"],
            "noticeBytesPerPeerList": flood["noticeBytesPerPeerList"],
            "flood": flood,
            // Timed, for reading beside `attachUs`: the notices read ahead of each attach's reply,
            // summed and the most for one. They move with when the loop starts.
            "attachNoticesReadAhead": read_ahead.iter().sum::<u64>(),
            "attachNoticesReadAheadMax": read_ahead.iter().max(),
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
            "restartChatAttachMs": restart_chat_attach_ms, "shutdownMs": shutdown_ms,
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
    let mut result = result;
    result["scratch"] = json!(scratch_dir.display().to_string());
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
        // Held when the profile was written (the daemon's exit): what a run left behind.
        eb: u64,
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
        site.eb += pp["eb"].as_u64().unwrap_or(0);
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
        json!({"site": name, "peakBytes": s.gb, "peakBlocks": s.gbk, "endBytes": s.eb, "totalBytes": s.tb,
               "totalBlocks": s.tbk, "leafPeakBytes": s.leaf_gb, "leafPeakBlocks": s.leaf_gbk,
               "via": inner.into_iter().take(3).map(|(f, b)| json!([f, b])).collect::<Vec<_>>()})
    };
    let mut by_peak: Vec<(&String, &Site)> = sites.iter().collect();
    by_peak.sort_by_key(|(_, s)| std::cmp::Reverse(s.gb));
    let mut by_total: Vec<(&String, &Site)> = sites.iter().collect();
    by_total.sort_by_key(|(_, s)| std::cmp::Reverse(s.tb));
    let mut by_leaf: Vec<(&String, &Site)> = sites.iter().filter(|(_, s)| s.leaf_gb > 0).collect();
    by_leaf.sort_by_key(|(_, s)| std::cmp::Reverse(s.leaf_gb));
    let mut by_end: Vec<(&String, &Site)> = sites.iter().collect();
    by_end.sort_by_key(|(_, s)| std::cmp::Reverse(s.eb));
    json!({
        "peakBytes": peak,
        "leafPeakBytes": leaves,
        "byPeak": by_peak.into_iter().take(top).map(row).collect::<Vec<_>>(),
        "byTotal": by_total.into_iter().take(top).map(row).collect::<Vec<_>>(),
        "leavesBySite": by_leaf.into_iter().take(top).map(row).collect::<Vec<_>>(),
        "endBytes": sites.values().map(|s| s.eb).sum::<u64>(),
        "byEnd": by_end.into_iter().take(top).map(row).collect::<Vec<_>>(),
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
        println!("GOD-FLOOD {}", flood_line(&result));
        let restart_ms = result["restartChatAttachMs"].as_u64().unwrap_or(u64::MAX);
        assert!(
            restart_ms <= 2_000,
            "Daemon restart -> chat attach exceeded 2 s: {restart_ms} ms; result={result}"
        );
        assert!(
            result["shutdownMs"].as_u64().unwrap_or(u64::MAX) <= 1_000,
            "daemon shutdown exceeded 1 s: {result}"
        );
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
            "/socketConnectUs",
            "/marksMs/socket ready",
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

/// One home's `GOD-FLOOD` line: its shape and [`flood_json`]'s numbers, which no timing moves.
fn flood_line(result: &Value) -> Value {
    let mut line = json!({"shape": result["shape"], "peers": result["peers"],
                          "peerRows": result["peerRows"]});
    for (k, v) in result["flood"].as_object().into_iter().flatten() {
        line[k] = v.clone();
    }
    line
}

/// The attach flood of the god home's peers (26 x 400 rows) over a small home, pinned: each row
/// of each peer's list reaches the watching client as one `_acpmux/session_changed` ahead of the
/// attaches, none twice, one list per peer. A change that sends more or fewer of them fails
/// here; one that means to (a list sent as one notice, say) moves these numbers with it.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_attach_flood_is_one_notice_per_peer_row() {
    let god = Shape::god();
    let shape =
        Shape { name: "flood", peers: god.peers, peer_rows: god.peer_rows, ..Shape::small() };
    // A client that does not ask for peer row batches, as every one before them: unchanged.
    let result = run_with(shape.clone(), false, false).await;
    let line = flood_line(&result);
    println!("GOD-FLOOD {line}");
    let (peers, rows) = (shape.peers as u64, shape.peer_rows as u64);
    assert_eq!(line["batchNotices"], json!(0), "no batch for a client that did not ask: {line}");
    assert_eq!(line["floodError"], Value::Null, "{line}");
    assert_eq!(line["peerLists"], json!(peers), "one list per peer: {line}");
    // A lag's `dropped` counts every hub event the fan-out missed, a few not peer rows among them
    // (10,402 and 10,404 with 1,514 dropped, 3 of 18 god runs): exact only when none was dropped.
    let ahead = line["attachNoticesAhead"].as_u64().expect("attachNoticesAhead");
    if line["noticesDropped"] == json!(0) {
        assert_eq!(ahead, peers * rows, "one notice per row: {line}");
    } else {
        assert!((peers * rows..=peers * rows + 32).contains(&ahead), "one notice per row: {line}");
    }
    // The most of one peer counts the notices read: a dropped one is of no peer.
    let most = line["attachNoticesAheadMax"].as_u64().expect("attachNoticesAheadMax");
    if line["noticesDropped"] == json!(0) {
        assert_eq!(most, rows, "one list's rows: {line}");
    } else {
        assert!(most <= rows, "one list's rows: {line}");
    }
    // Each notice carries its row's summary, 3,327 bytes of the fixture's 75 keys: 1,330,733 a
    // list on the Linux pool, every run. Within 1%: dropped notices are weighed at the mean.
    let per_list = line["noticeBytesPerPeerList"].as_u64().unwrap_or(0);
    assert!(
        (1_317_426..=1_344_040).contains(&per_list),
        "a list's notices are {per_list} bytes, not 1,330,733 (1%): {line}"
    );
}

/// The god home's peers (26 x 400 rows) over a small home, the client asking for peer row
/// batches: run once, read by the two tests below.
static BATCH_RUN: tokio::sync::OnceCell<Value> = tokio::sync::OnceCell::const_new();

async fn batch_run() -> Value {
    let god = Shape::god();
    // Its own name: the scratch folder is the shape's, and the tests run side by side.
    let shape = Shape {
        name: "flood-batches",
        peers: god.peers,
        peer_rows: god.peer_rows,
        ..Shape::small()
    };
    let result = BATCH_RUN.get_or_init(|| run_with(shape, false, true)).await;
    flood_line(result)
}

/// The attach flood of a client that asked for peer row batches, pinned: each peer's list
/// reaches it as one `_acpmux/peer_rows_changed` ahead of the attaches, and no peer row as its own
/// `session_changed` (read or dropped). 26 notices where the client before them had 10,400, and
/// one more for each time its fan-out fell behind and it followed the list instead.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_attach_flood_is_one_batch_notice_per_peer_list() {
    let line = batch_run().await;
    println!("GOD-FLOOD {line}");
    let god = Shape::god();
    assert_eq!(line["floodError"], Value::Null, "{line}");
    assert_eq!(line["peerLists"], json!(god.peers), "one list per peer: {line}");
    assert_eq!(line["rowNotices"], json!(0), "no row's own notice: {line}");
    // When its fan-out falls behind (`watchLags`), a list's batch can be among the events it
    // missed: the lag's one note tells it to follow the list instead.
    let lags = line["watchLags"].as_u64().expect("watchLags");
    let batches = line["batchNotices"].as_u64().expect("batchNotices");
    assert!(
        batches <= god.peers as u64 && batches + lags >= god.peers as u64,
        "a batch per list: {line}"
    );
    let ahead = line["attachNoticesAhead"].as_u64().expect("attachNoticesAhead");
    assert!(ahead <= god.peers as u64 + lags, "one notice per list: {line}");
    assert_eq!(line["attachNoticesAheadMax"], json!(1), "one notice per list: {line}");
}

/// A client that asked for peer row batches still holds every peer row: one follow of the list
/// from below the batches, paged, reads all 10,400 rows (400 of each of 26 peers).
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_batch_client_reads_every_peer_row_with_one_follow() {
    let line = batch_run().await;
    let god = Shape::god();
    let caught = &line["catchUp"];
    assert_eq!(caught["error"], Value::Null, "{line}");
    assert_eq!(caught["rows"], json!(god.peers * god.peer_rows), "every peer row: {line}");
    assert_eq!(caught["peers"], json!(god.peers), "{line}");
    assert_eq!(caught["fewestRowsOfAPeer"], json!(god.peer_rows), "each peer's rows: {line}");
}

/// CI's Linux budget check uses the same harness and the small shape. It keeps the full god bench
/// ignored while detecting a daemon restart regression. Rendering is measured by the app driver.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn restart_to_chat_attach_is_under_two_seconds() {
    let result = run(Shape::small(), false).await;
    let elapsed = result["restartChatAttachMs"].as_u64().unwrap_or(u64::MAX);
    assert!(elapsed <= 2_000, "Daemon restart -> chat attach took {elapsed} ms: {result}");
    let shutdown = result["shutdownMs"].as_u64().unwrap_or(u64::MAX);
    assert!(shutdown <= 1_000, "Daemon shutdown took {shutdown} ms: {result}");
    // The run's scratch went with it (a run that panics: `tests/scratch_guard.rs`).
    let scratch = Path::new(result["scratch"].as_str().expect("run names its scratch"));
    assert!(
        std::env::var(daemon_env::KEEP_SCRATCH).is_ok() || !scratch.exists(),
        "run() left its scratch {}",
        scratch.display()
    );
}

/// The chats [`a_kill_mid_replay_of_every_open_chat_repaints_each_from_its_log`] keeps open: more
/// than the 875 of cmux#42185.
const OPEN_CHATS: usize = 900;
/// The attaches of the replay in flight at once: 64 pages of at most [`PAGE_BYTES`], 8 MiB.
const IN_FLIGHT: usize = 64;

/// F6 of cmuxterm-hq `docs/design/remote-cloud-durability.md` (cmux#42185: "Agent chats show empty
/// history after the daemon restarts", fixed in the pane host by #42197, #42206 and #42326): a
/// regression guard at the issue's scale, which passes before and after. [`OPEN_CHATS`] chats are
/// open; each pane's attach (`settled: true`, as the page sends it since #41760) is answered once.
/// Then every pane attaches again at once (the replay of every open chat), the daemon is killed
/// with SIGKILL once half of them are answered, and a new daemon starts on the same home. Every
/// pane's attach to it answers with no error, within the bound, and with the history it had
/// before: as many events, ending at the same seq.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_kill_mid_replay_of_every_open_chat_repaints_each_from_its_log() {
    let _ = HERMETIC;
    let scratch = std::env::temp_dir().join(format!("god-replay-kill-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).unwrap();
    let home = scratch.join("acpmux");
    let claude = daemon_env::home(&scratch).join(".claude");
    let shape =
        Shape { name: "replay-kill", chats: OPEN_CHATS, god_messages: 40, ..Shape::small() };
    let made = god_fixture::write_home(&home, &claude, &scratch.join("work"), &shape).unwrap();
    write_config(&home, json!({}));
    let chats: Vec<String> = std::iter::once(made.god).chain(made.others).collect();
    assert_eq!(chats.len(), OPEN_CHATS);

    let attach = |id: &str| {
        json!({"sessionId": id, "settled": true, "waitLogs": false, "limit": PAGE_LIMIT,
               "maxBytes": PAGE_BYTES})
    };
    // What a page shows: its events, and the seq of its newest.
    let shown = |page: &Value| {
        let events = page["events"].as_array().cloned().unwrap_or_default();
        let last = events.iter().filter_map(|e| e["seq"].as_u64()).max();
        (events.len(), last)
    };
    let result = tokio::task::spawn_blocking(move || {
        let mut daemon = Daemon::start(&scratch, &home, None);
        let hello = json!({"protocolVersion": 1, "clientInfo": {"name": "replay-kill"}});
        let mut rpc = Rpc::connect(&daemon.socket);
        rpc.call("initialize", hello.clone()).unwrap();
        let before: Vec<(usize, Option<u64>)> = chats
            .iter()
            .map(|id| {
                let page = rpc.call("_acpmux/attach", attach(id)).expect("an attach before");
                rpc.notes.clear();
                shown(&page)
            })
            .collect();
        assert!(before.iter().all(|(n, last)| *n > 0 && last.is_some()), "every chat has history");

        // Every open pane attaches again, [`IN_FLIGHT`] at a time (all 900 pages at once are past
        // a connection's outbound bound, which ends a reader that falls behind); the daemon dies
        // with half of them answered and the next ones in flight.
        let mut replay = Rpc::connect(&daemon.socket);
        replay.call("initialize", hello.clone()).unwrap();
        let mut asked = std::collections::VecDeque::new();
        let (mut sent, mut answered) = (0, 0);
        while answered < OPEN_CHATS / 2 {
            while sent < OPEN_CHATS && asked.len() < IN_FLIGHT {
                asked.push_back(replay.request("_acpmux/attach", attach(&chats[sent])));
                sent += 1;
            }
            let _ = replay.response(asked.pop_front().expect("an attach in flight"));
            answered += 1;
        }
        // SAFETY: the pid is this test's own child, not yet reaped.
        unsafe { libc::kill(daemon.child.id() as i32, libc::SIGKILL) };
        let _ = daemon.child.wait();

        let restarted = Instant::now();
        daemon = Daemon::start(&scratch, &home, None);
        let mut rpc = Rpc::connect(&daemon.socket);
        rpc.call("initialize", hello).unwrap();
        let deadline = Instant::now() + Duration::from_secs(120);
        let mut wrong = Vec::new();
        for (id, was) in chats.iter().zip(&before) {
            match rpc.call_until("_acpmux/attach", attach(id), Some(deadline)) {
                Ok(page) if shown(&page) == *was => {}
                Ok(page) => wrong.push(format!("{id}: {:?}, was {was:?}", shown(&page))),
                Err(e) => wrong.push(format!("{id}: {e}")),
            }
            rpc.notes.clear();
        }
        let all_ms = ms(restarted);
        daemon.stop();
        let _ = std::fs::remove_dir_all(&scratch);
        (wrong, all_ms)
    })
    .await
    .unwrap();
    let (wrong, all_ms) = result;
    println!("replay-kill: {OPEN_CHATS} chats repainted {} ms after the kill", all_ms);
    assert!(
        wrong.is_empty(),
        "{} of {OPEN_CHATS} chats did not repaint their history after a kill mid-replay: {:?}",
        wrong.len(),
        &wrong[..wrong.len().min(10)]
    );
}

/// One peer's hub, restartable: each start is a new daemon run (a new list epoch) over the same
/// rows and the same peer token, so the link that reconnects to it cannot follow its cursor and
/// reads the whole list, as from a peer that restarted or an older daemon without the follow.
#[cfg(target_os = "linux")]
struct RestartingPeer {
    name: String,
    rows: usize,
    auth: Arc<PeerAuth>,
    serving: Option<tokio::task::AbortHandle>,
}

#[cfg(target_os = "linux")]
impl RestartingPeer {
    /// A new run of the peer's hub on a new port: the port.
    async fn start(&mut self) -> u16 {
        if let Some(old) = self.serving.take() {
            old.abort();
        }
        let mut cfg = Config::default();
        cfg.store.mode = StoreMode::Memory;
        let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
        for i in 0..self.rows {
            let meta = god_fixture::peer_meta(&self.name, i);
            store.save(&serde_json::from_value(meta).unwrap()).unwrap();
        }
        let hub = Hub::new(cfg, store);
        let listener = bind_ws("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let auth = WsAuth { local_app: None, peer: Some(self.auth.clone()) };
        self.serving =
            Some(tokio::spawn(serve_ws_with(hub, listener, "tok".into(), auth)).abort_handle());
        port
    }
}

#[cfg(target_os = "linux")]
fn env_or<T: std::str::FromStr>(name: &str, default: T) -> T {
    std::env::var(name).ok().and_then(|v| v.parse().ok()).unwrap_or(default)
}

/// Pins thread `pid` (0: the calling thread) to the first `cpus` CPUs.
#[cfg(target_os = "linux")]
fn pin(pid: i32, cpus: usize) {
    // SAFETY: a zeroed cpu_set_t is an empty set; CPU_SET writes within it.
    unsafe {
        let mut set: libc::cpu_set_t = std::mem::zeroed();
        for cpu in 0..cpus {
            libc::CPU_SET(cpu, &mut set);
        }
        libc::sched_setaffinity(pid, std::mem::size_of::<libc::cpu_set_t>(), &set);
    }
}

/// Pins every thread of process `pid` to the first `cpus` CPUs: `sched_setaffinity` on a pid
/// sets only its main thread, and a thread started later inherits from the thread that starts it,
/// so each running thread is set (`/proc/PID/task`), twice in case one started during the first.
#[cfg(target_os = "linux")]
fn pin_process(pid: u32, cpus: usize) {
    for _ in 0..2 {
        let tasks = std::fs::read_dir(format!("/proc/{pid}/task")).into_iter().flatten().flatten();
        for tid in tasks.filter_map(|t| t.file_name().to_str()?.parse::<i32>().ok()) {
            pin(tid, cpus);
        }
    }
}

/// The hub's notice channel under a peer that cannot follow (2026-11-15, after cmux#42095 closed):
/// bounded by notices (4,096), not bytes. Each of its links reads its whole list again, and the
/// hub's one notice loop applies lists one at a time. Measured: the bytes of lists the loop had not
/// taken yet (`gauges.peerLists`, now and at peak) and the daemon's RSS, while the peer's link is
/// cut and the peer restarted every `ACPMUX_CHURN_EVERY_MS` for `ACPMUX_CHURN_SECS`, with the
/// daemon alone pinned to `ACPMUX_CHURN_CPUS` CPUs shared with `ACPMUX_CHURN_BUSY` busy threads
/// (a starved daemon, as at a load average of 125-256 on Leo's Mac); the peer runs free.
/// `ACPMUX_CHURN_FOLLOW=1` cuts without a restart, so the link follows: the control.
/// Manual, on Linux CI:
/// `cargo test -p acpmux --release --test god_daemon whole_lists -- --ignored --nocapture`.
#[cfg(target_os = "linux")]
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "manual: a churn lab; run on Linux CI"]
async fn whole_lists_of_a_peer_that_cannot_follow_under_churn() {
    let rows: usize = env_or("ACPMUX_CHURN_ROWS", 4_000);
    let secs: u64 = env_or("ACPMUX_CHURN_SECS", 60);
    let every = Duration::from_millis(env_or("ACPMUX_CHURN_EVERY_MS", 500));
    let cpus: usize = env_or("ACPMUX_CHURN_CPUS", 1);
    let busy: usize = env_or("ACPMUX_CHURN_BUSY", 8);
    let follow = std::env::var("ACPMUX_CHURN_FOLLOW").is_ok_and(|v| v == "1");

    // Removed when the lab ends, passing or not (`ACPMUX_KEEP_SCRATCH=1` keeps it).
    let scratch = daemon_env::Scratch::new("god-churn");
    let home = scratch.join("acpmux");
    let claude = daemon_env::home(&scratch).join(".claude");
    let shape = Shape { peers: 0, ..Shape::small() };
    god_fixture::write_home(&home, &claude, &scratch.join("work"), &shape).unwrap();
    let peer_home = scratch.join("peer-0");
    std::fs::create_dir_all(&peer_home).unwrap();
    let auth = Arc::new(PeerAuth::create(&peer_home).unwrap());
    let token = std::fs::read_to_string(acpmux::server::peer_auth::token_path(&peer_home)).unwrap();
    let mut peer = RestartingPeer { name: "peer00".into(), rows, auth, serving: None };
    let proxy = Arc::new(Proxy::start(peer.start().await).await);
    write_config(
        &home,
        json!({"peer00": {"url": format!("ws://127.0.0.1:{}", proxy.port), "token": "tok",
                          "peerToken": token.trim()}}),
    );

    let profile = std::env::var("ACPMUX_GOD_DHAT")
        .is_ok_and(|v| v == "1")
        .then(|| scratch.join("dhat-heap.json"));
    let mut daemon = Daemon::start(&scratch, &home, profile.as_deref());
    let mut rpc = Rpc::connect(&daemon.socket);
    rpc.call("initialize", json!({"protocolVersion": 1, "clientInfo": {"name": "churn-bench"}}))
        .unwrap();
    assert!(wait_listed(&mut rpc, 1, rows).is_some(), "the peer was never listed");
    let (rss_listed, _) = daemon.rss();
    let cpu_listed = daemon.cpu_seconds();

    // The daemon starved: pinned with busy threads on its CPUs.
    pin_process(daemon.child.id(), cpus);
    let stop = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let spinners: Vec<_> = (0..busy)
        .map(|_| {
            let stop = stop.clone();
            std::thread::spawn(move || {
                pin(0, cpus);
                while !stop.load(std::sync::atomic::Ordering::Relaxed) {
                    std::hint::spin_loop();
                }
            })
        })
        .collect();

    // The churn: cut (and restart) the peer every `every`; sample the gauge meanwhile.
    let cuts = {
        let proxy = proxy.clone();
        let stop = stop.clone();
        tokio::spawn(async move {
            let mut cuts = 0u64;
            while !stop.load(std::sync::atomic::Ordering::Relaxed) {
                if !follow {
                    proxy.repoint(peer.start().await);
                }
                proxy.cut();
                cuts += 1;
                tokio::time::sleep(every).await;
            }
            (cuts, peer)
        })
    };
    let sampled = tokio::task::spawn_blocking(move || {
        let started = Instant::now();
        let (mut peak_bytes, mut peak_lists, mut samples) = (0u64, 0u64, 0u64);
        while started.elapsed() < Duration::from_secs(secs) {
            std::thread::sleep(Duration::from_millis(500));
            let Ok(status) = rpc.call("_acpmux/status", json!({})) else { continue };
            let lists = &status["gauges"]["peerLists"];
            peak_bytes = peak_bytes.max(lists["bytes"].as_u64().unwrap_or(0));
            peak_lists = peak_lists.max(lists["lists"].as_u64().unwrap_or(0));
            let rss = status["gauges"]["memory"]["rssBytes"].as_u64().unwrap_or(0);
            let at = started.elapsed().as_millis() as u64;
            // One short line per sample, as it is read: a CI log cuts long lines, and a run that
            // stalls still shows where.
            println!("CHURN-RSS {at} {} {} {}", lists["lists"], lists["bytes"], rss / 1_048_576);
            samples += 1;
        }
        (rpc, peak_bytes, peak_lists, samples)
    })
    .await
    .unwrap();
    let (mut rpc, sampled_bytes, sampled_lists, samples) = sampled;
    let (rss_churned, _) = daemon.rss();
    let cpu_churn = daemon.cpu_seconds() - cpu_listed;
    stop.store(true, std::sync::atomic::Ordering::Relaxed);
    for spinner in spinners {
        spinner.join().unwrap();
    }
    let (cuts, _peer) = cuts.await.unwrap();

    // Unstarved: until every list waiting is taken.
    let drained = Instant::now();
    let (mut drain_ms, mut reads) = (None, 0u64);
    while drained.elapsed() < STEP {
        let status = rpc.call("_acpmux/status", json!({})).unwrap_or_default();
        let rss = status["gauges"]["memory"]["rssBytes"].as_u64().unwrap_or(0);
        // About one line a second.
        if reads % 10 == 0 {
            println!(
                "CHURN-DRAIN {} {} {}",
                ms(drained),
                status["gauges"]["peerLists"]["lists"],
                rss / 1_048_576
            );
        }
        reads += 1;
        if status["gauges"]["peerLists"]["lists"] == 0 && peers_listed(&mut rpc, 1, rows) {
            drain_ms = Some(ms(drained));
            break;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    let status = rpc.call("_acpmux/status", json!({})).unwrap_or_default();
    let (rss_end, peak_rss) = daemon.rss();
    drop(rpc);
    daemon.stop();
    let heap = profile.as_deref().map(attribute);
    let lists = &status["gauges"]["peerLists"];
    let result = json!({
        "rows": rows, "secs": secs, "everyMs": every.as_millis() as u64, "cpus": cpus,
        "busy": busy, "follow": follow, "cuts": cuts,
        "peakLists": lists["peakLists"], "peakBytes": lists["peakBytes"],
        "sampledPeakLists": sampled_lists, "sampledPeakBytes": sampled_bytes,
        "drainMs": drain_ms,
        "rssListed": rss_listed, "rssChurned": rss_churned, "rssEnd": rss_end, "peakRss": peak_rss,
        // The daemon's CPU seconds over the churn (with no busy threads, its cost; with them, its share).
        "cpuChurnS": cpu_churn,
        "samples": samples,
        "arenas": std::env::var("ACPMUX_CHURN_ARENAS").ok(),
        "heapEndBytes": heap.as_ref().map(|h| h["endBytes"].clone()),
        "heapPeakBytes": heap.as_ref().map(|h| h["peakBytes"].clone()),
    });
    println!("CHURN {result}");
    for (list, rows) in heap.iter().flat_map(|h| [("END", &h["byEnd"]), ("PEAK", &h["byPeak"])]) {
        for row in rows.as_array().into_iter().flatten() {
            println!(
                "CHURN-HEAP-{list} {} {} {} {}",
                row["endBytes"], row["peakBytes"], row["totalBytes"], row["site"]
            );
        }
    }
}
