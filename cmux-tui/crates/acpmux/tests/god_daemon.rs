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

#[path = "support/chat_size_seed.rs"]
mod chat_size_seed;
#[path = "god_daemon/cold_home.rs"]
mod cold_home;
#[path = "support/daemon_env.rs"]
mod daemon_env;
#[path = "support/dhat_sites.rs"]
mod dhat_sites;
// The prompt goes to tests/fake_agent.py; the sizes and the profile switch hold no credential.
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in().keep(&[
    "ACPMUX_GOD_SHAPES",
    "ACPMUX_GOD_SCALE",
    // The chat size sweep's sizes (`chat_size_sweep`).
    "ACPMUX_CHAT_SIZES",
    "ACPMUX_CHAT_SIM_BIN",
    // The fleet's output directory, not a credential: keep the bounded daemon-log artifacts.
    "FAST_CHECKS_OUT",
    "ACPMUX_GOD_DHAT",
    "ACPMUX_GOD_DHAT_TOP",
    "ACPMUX_GOD_DHAT_FRAMES",
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

use acpmux::chat_size_fixture;
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
use std::io::{BufRead, BufReader, Read, Seek, SeekFrom, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Stdio};
use std::sync::Arc;
use std::time::{Duration, Instant};
use wait_timeout::ChildExt;

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
/// When, after the restarted daemon was spawned, the sweep sends again (`restartSendAfterUs`):
/// past startup's background passes, so a slower first send names startup work, not size.
const RESTART_SEND_AFTER_MS: [u64; 2] = [1500, 4000];

/// The longest a size sweep waits for a chat's adoption checkpoint before its restart.
const ADOPTION_CHECKPOINT_WITHIN: Duration = Duration::from_secs(300);

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
    wait_all_logs_within(rpc, ALL_LOGS)
}

/// [`wait_all_logs`] for at most `limit` (a 4 GB chat's first load may take longer than
/// [`ALL_LOGS`]).
fn wait_all_logs_within(rpc: &mut Rpc, limit: Duration) -> Result<u64, Value> {
    let deadline = Instant::now() + limit;
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
    Err(json!({"timeoutMs": limit.as_millis() as u64, "lastError": last}))
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
    log: PathBuf,
    spawned: Instant,
    socket_connect_us: u64,
}

impl Daemon {
    fn start(scratch: &Path, home: &Path, dhat: Option<&Path>) -> Self {
        let socket = scratch.join("s.sock");
        let log = scratch.join("daemon.log");
        // The daemon logs to its stdout (`log_sink.rs`); its stderr carries a panic. Both go to
        // the log, so a failed run prints why the daemon did what it did.
        let stderr = std::fs::OpenOptions::new().create(true).append(true).open(&log).unwrap();
        let stdout = stderr.try_clone().unwrap();
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
            .stdout(Stdio::from(stdout))
            .stderr(Stdio::from(stderr));
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
                print_daemon_log(&log);
                panic!("the daemon did not bind its socket");
            }
            std::thread::sleep(Duration::from_millis(1));
        }
        let socket_connect_us = micros(spawned);
        Self { child, socket, log, spawned, socket_connect_us }
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

    /// `RssAnon` and `RssFile` of the daemon, in bytes: heap against mapped file pages.
    fn rss_split(&self) -> (u64, u64) {
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
        (field("RssAnon:"), field("RssFile:"))
    }

    /// The daemon's largest resident mappings (`/proc/PID/smaps`): `[name or path, rss bytes,
    /// size bytes]`, anonymous ones named `[anon]`, so a size's extra memory has a place.
    fn rss_maps(&self) -> Value {
        let smaps =
            std::fs::read_to_string(format!("/proc/{}/smaps", self.child.id())).unwrap_or_default();
        let mut maps: Vec<(String, u64, u64)> = Vec::new();
        for line in smaps.lines() {
            let mut words = line.split_whitespace();
            let first = words.next().unwrap_or_default();
            if first.contains('-') && first.chars().all(|c| c.is_ascii_hexdigit() || c == '-') {
                let (lo, hi) = first.split_once('-').unwrap_or_default();
                let size = u64::from_str_radix(hi, 16)
                    .unwrap_or(0)
                    .saturating_sub(u64::from_str_radix(lo, 16).unwrap_or(0));
                let name = words.nth(4).map_or("[anon]".to_owned(), str::to_owned);
                maps.push((name, 0, size));
            } else if first == "Rss:"
                && let Some(last) = maps.last_mut()
            {
                last.1 = words.next().and_then(|k| k.parse::<u64>().ok()).unwrap_or(0) * 1024;
            }
        }
        maps.sort_by_key(|m| std::cmp::Reverse(m.1));
        maps.truncate(12);
        json!(maps)
    }

    /// SIGTERM, then the exit: the daemon writes its heap profile on the way out.
    fn stop(&mut self) {
        if self.child.try_wait().unwrap().is_some() {
            return;
        }
        // SAFETY: the pid is this test's own child, not yet reaped.
        unsafe { libc::kill(self.child.id() as i32, libc::SIGTERM) };
        if self.child.wait_timeout(Duration::from_secs(30)).unwrap().is_none() {
            print_daemon_log(&self.log);
            let _ = self.child.kill();
            let _ = self.child.wait_timeout(Duration::from_secs(5));
            panic!("daemon {} did not stop within 30 seconds", self.child.id());
        }
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
        // A daemon that went away by itself (a panic, an abort, the OOM killer's SIGKILL) says how before the kill.
        if std::thread::panicking()
            && let Ok(Some(status)) = self.child.try_wait()
        {
            eprintln!("daemon exited by itself: {status:?}");
        }
        let _ = self.child.kill();
        let _ = self.child.wait_timeout(Duration::from_secs(5));
        if std::thread::panicking() {
            print_daemon_log(&self.log);
        }
    }
}

/// Keep failure evidence bounded even if a daemon repeatedly logs the same error.
fn print_daemon_log(path: &Path) {
    let Ok(mut file) = std::fs::File::open(path) else { return };
    let len = file.metadata().map_or(0, |m| m.len());
    let _ = file.seek(SeekFrom::Start(len.saturating_sub(16 * 1024)));
    let mut tail = Vec::new();
    let _ = file.take(16 * 1024).read_to_end(&mut tail);
    eprintln!(
        "daemon log {} (last {} bytes):\n{}",
        path.display(),
        tail.len(),
        String::from_utf8_lossy(&tail)
    );
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
        let heap = profile.as_deref().map(|p| dhat_sites::attribute(p, dhat_top()));
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
            // The god chat in a home of 50, 500 or 5,000 chats: the app's attach and list at
            // each size, one harness (Leo, 2026-11-19: the GUI too coupled to load, size and
            // history).
            "sessions50" => Shape { name: "sessions50", chats: 50, ..Shape::god_from_env() },
            "sessions500" => Shape { name: "sessions500", chats: 500, ..Shape::god_from_env() },
            "sessions5000" => Shape { name: "sessions5000", chats: 5000, ..Shape::god_from_env() },
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
    let heap = profile.as_deref().map(|p| dhat_sites::attribute(p, dhat_top()));
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

/// How many sites each list of a heap profile names (`ACPMUX_GOD_DHAT_TOP`, default 30).
fn dhat_top() -> usize {
    std::env::var("ACPMUX_GOD_DHAT_TOP").ok().and_then(|v| v.parse().ok()).unwrap_or(30)
}

// The chat size sweep (infinite chats, 2026-11-19). Leo: "we need to be able to have infinite
// chats, infinitely long chats ... on current day hardware". The goal (cmuxterm-hq#14331): a
// chat's open, scroll, typing and memory at 100 MB, 1 GB and 4 GB stay within 1.2x of a 1 MB
// chat's. One home per size, one chat in it ([`acpmux::chat_size_fixture`], millions of small
// records at 1 GB as a real coordinator chat), written here and removed after its size runs, so
// nothing of it is stored and the runner holds one size at a time.

/// The sizes, as `ACPMUX_CHAT_SIZES` names them (`1M,100M,1G,4G`, binary units).
const CHAT_SIZES: &str = "1M,100M,1G,4G";

/// Cold opens per size, each paired with a cold open of a `COLD_FLOOR_BYTES` chat.
const COLD_SAMPLES: usize = 5;

/// The chat the cold opens are paired with.
const COLD_FLOOR_BYTES: u64 = 1 << 20;

/// One cold open of `id` on a daemon of its own, stopped after its attach, with the home put back
/// to `cold` after: the time from spawn to the attach's reply, ms, and of the attach itself, us.
fn cold_open(
    scratch: &Path,
    home: &Path,
    id: &str,
    cold: &cold_home::HomeSnapshot,
) -> Result<(u64, u64), Value> {
    let mut probe = Daemon::start(scratch, home, None);
    let mut rpc = Rpc::connect(&probe.socket);
    rpc.call("initialize", json!({"protocolVersion": 1, "clientInfo": {"name": "size-sweep"}}))
        .unwrap();
    let asked = Instant::now();
    let reply = rpc.call("_acpmux/attach", app_attach(id));
    let taken = (ms(probe.spawned), micros(asked));
    drop(rpc);
    probe.stop();
    // A home left changed would make every later open warm, so this stops the sweep.
    if let Err(e) = cold.restore() {
        panic!("a cold open left {} changed: {e}", home.display());
    }
    reply.map(|_| taken)
}

/// The floor's fastest open plus the median of each pair's difference, null with no pairs.
fn paired_floor(sized: &[(u64, u64)], floor: &[(u64, u64)], at: fn(&(u64, u64)) -> u64) -> Value {
    let Some(fastest) = floor.iter().map(at).min() else { return Value::Null };
    let mut diffs: Vec<i64> =
        sized.iter().zip(floor).map(|(s, f)| at(s) as i64 - at(f) as i64).collect();
    diffs.sort_unstable();
    json!((fastest as i64 + diffs[diffs.len() / 2]).max(0))
}

/// How long the first load of a chat's log may take (it parses a log with no kind copies whole).
const SIZE_ALL_LOGS: Duration = Duration::from_secs(1800);

/// An older page as the pane asks for one on scroll-up (direct.ts `olderPage`: 2,000 records,
/// 1 MiB, transcript records and the local preset approvals).
const OLDER_PAGE_BYTES: u64 = 1 << 20;

/// The bytes a measured page asks for. A 1 MB chat's whole transcript is 452 KB of JSON, so at
/// the app's 1 MiB budget its pages held 565 records and 452 KB against 1,200 records and 945 KB
/// at 100 MB and 1 GB: the 2x of every page row was the page's size (the daemon reads 16 to 20 ms
/// per 452 KB at 1 MB and 22 to 34 ms per 945 KB at 1 GB). 256 KiB is full at every size.
const SWEEP_PAGE_BYTES: u64 = 256 << 10;

/// The records a measured page asks for: fewer than any size's 256 KiB page holds, so each size
/// reads the same rows. A byte-capped page's row count is its content's: the 1 MB chat's deep page
/// (its oldest) held 237 records and 198 KB against 306 and 314 at 100 MB and 1 GB, 1682 against
/// 2130 and 2225 us, a 1.27x and 1.32x that was 7.0 to 7.1 us a record at every size. Every page
/// row read 6.4 to 7.8 us a record at every size, its ratio the row count's (cmux#61742's ladder).
const SWEEP_PAGE_ROWS: u64 = 150;

/// The repeated settled turns after a coord-sim chat's settlement (a quarter of the history when
/// that is less). A page counts only transcript kinds' bytes, so 1 MiB of them reaches back past
/// several MiB of log: at 2 MiB the 1 GB and 4 GB newest pages were 26% and 37% settlement
/// records. 16 MiB keeps every newest page ordinary history.
const TAIL_BYTES: u64 = 16 * OLDER_PAGE_BYTES;

/// The kinds the pane's attach asks a local acpmux for (attachParams.ts `plainAttach`).
fn app_attach(id: &str) -> Value {
    json!({"sessionId": id, "waitLogs": false, "settled": true, "limit": PAGE_LIMIT,
           "maxBytes": PAGE_BYTES, "eventStream": true, "visible": true,
           "kinds": ["transcript", "available_commands_update", "usage_update",
                     "config_option_update", "bookmarks", "secret_request", "secret_decision",
                     "subsession", "queue_order", "queue_updated", "prompt_refused",
                     "elevation_request", "elevation_decision", "preset_approval_request",
                     "preset_approval_decision"]})
}

fn older_params(id: &str, before: u64) -> Value {
    json!({"sessionId": id, "beforeSeq": before, "limit": SWEEP_PAGE_ROWS,
           "maxBytes": SWEEP_PAGE_BYTES,
           "kinds": ["transcript", "preset_approval_request", "preset_approval_decision"]})
}

/// The first `beforeSeq` whose older page is full: the seq after the chat's oldest page of
/// [`older_params`]' kinds and bytes, read forward from the start. A chat that holds less than one
/// such page has none: `last + 1`, its newest page, which is all of it.
fn full_page_before(rpc: &mut Rpc, id: &str, last: u64) -> u64 {
    let oldest = rpc.call(
        "_acpmux/events",
        json!({"sessionId": id, "afterSeq": 0, "limit": SWEEP_PAGE_ROWS,
               "maxBytes": SWEEP_PAGE_BYTES,
               "kinds": ["transcript", "preset_approval_request", "preset_approval_decision"]}),
    );
    rpc.notes.clear();
    oldest
        .ok()
        .filter(|page| page["hasMore"].as_bool() == Some(true))
        .and_then(|page| page["events"].as_array()?.iter().filter_map(|e| e["seq"].as_u64()).max())
        .map_or(last + 1, |newest| newest + 1)
}

/// `4G`, `100M`, `1M`, `512K` or bytes.
fn parse_size(text: &str) -> u64 {
    let text = text.trim();
    let (digits, unit) = match text.char_indices().find(|(_, c)| !c.is_ascii_digit()) {
        Some((at, _)) => text.split_at(at),
        None => (text, ""),
    };
    let n: u64 = digits.parse().unwrap_or_else(|_| panic!("ACPMUX_CHAT_SIZES: {text}"));
    n << match unit.to_ascii_uppercase().as_str() {
        "" | "B" => 0,
        "K" => 10,
        "M" => 20,
        "G" => 30,
        other => panic!("ACPMUX_CHAT_SIZES: no unit {other}"),
    }
}

/// Bytes free for an unprivileged writer on the file system holding `path`.
fn free_bytes(path: &Path) -> u64 {
    use std::os::unix::ffi::OsStrExt;
    let c = std::ffi::CString::new(path.as_os_str().as_bytes()).unwrap();
    // SAFETY: statvfs fills the struct it is given from a NUL-terminated path.
    let mut st: libc::statvfs = unsafe { std::mem::zeroed() };
    if unsafe { libc::statvfs(c.as_ptr(), &mut st) } != 0 {
        return u64::MAX;
    }
    st.f_bavail as u64 * st.f_frsize as u64
}

/// The records fixture preparation wrote (the settlement's completions and the repeated turns'),
/// as inclusive seq ranges from `fixturePreparation.preparationSeqs`.
fn preparation_seqs(preparation: &Value) -> Vec<(u64, u64)> {
    preparation["preparationSeqs"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|r| Some((r[0].as_u64()?, r[1].as_u64()?)))
        .collect()
}

/// Completion records must not become the measured workload of a page: the records of `reply`
/// that are history, not preparation.
fn original_page_records(reply: &Value, prepared: &[(u64, u64)]) -> usize {
    reply["events"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|e| {
            e["seq"].as_u64().is_some_and(|seq| {
                seq > 0 && !prepared.iter().any(|&(from, to)| (from..=to).contains(&seq))
            })
        })
        .count()
}

/// `rounds` calls of `method`, the params of each from its round: their times, how many records
/// the last returned, and the first error.
fn timed_rounds(
    rpc: &mut Rpc,
    method: &str,
    rounds: u64,
    prepared: &[(u64, u64)],
    params: impl Fn(u64) -> Value,
) -> (Value, Value, Value) {
    let (mut times, mut records, mut error) = (vec![], Value::Null, Value::Null);
    let mut returned_records = vec![];
    let mut original_records = vec![];
    let mut page_bytes = vec![];
    for round in 0..rounds {
        let asked = Instant::now();
        let reply = rpc.call_until(method, params(round), Some(asked + STEP));
        let us = micros(asked);
        rpc.notes.clear();
        match reply {
            Ok(reply) => {
                let count = reply["events"].as_array().map_or(0, Vec::len);
                let original = original_page_records(&reply, prepared);
                if count == 0 || original * 2 < count {
                    error = json!({"method": method, "round": round,
                        "reason": "page is empty or dominated by fixture completions",
                        "records": count, "originalRecords": original});
                    break;
                }
                times.push(us);
                records = json!(count);
                returned_records.push(count);
                original_records.push(original);
                page_bytes.push(reply.to_string().len());
            }
            Err(e) => {
                error = e;
                break;
            }
        }
    }
    let mut timing = spread(&times);
    if let Some(timing) = timing.as_object_mut() {
        timing.insert("returnedRecords".into(), json!(returned_records));
        timing.insert("originalRecords".into(), json!(original_records));
        timing.insert("pageBytes".into(), json!(page_bytes));
    }
    (timing, records, error)
}

/// How long a prompt may take to its first token, and to its turn's end, before the sweep counts
/// it failed (and reads on) instead of waiting [`STEP`].
const SEND_WAIT: Duration = Duration::from_secs(120);

/// An `agent_message_chunk` notice in either envelope the daemon sends it (server/mod.rs
/// `deliver`): its chat and text. A connection whose attach asked for `eventStream` (the
/// pane's, [`app_attach`]) hears the logged record as `_acpmux/event`, with the record's `kind`
/// and the agent's raw message in `msg`; any other hears ACP's `session/update`.
fn streamed_chunk(v: &Value) -> Option<(&str, &str)> {
    let params = &v["params"];
    let update = match v["method"].as_str()? {
        "session/update" => &params["update"],
        "_acpmux/event" if params["kind"] == "agent_message_chunk" => {
            &params["msg"]["params"]["update"]
        }
        _ => return None,
    };
    if update["sessionUpdate"] != "agent_message_chunk" {
        return None;
    }
    Some((params["sessionId"].as_str()?, update["content"]["text"].as_str()?))
}

/// A prompt to `id` until its first streamed chunk (the stand-in agent echoes it), then its
/// turn's end: the time to the chunk. Past [`SEND_WAIT`] an error that names the notices read
/// meanwhile (a prompt queued behind a turn the log left open shows as `queued`).
fn send_first_token(rpc: &mut Rpc, id: &str, text: &str) -> Result<u64, Value> {
    let sent = Instant::now();
    let prompt = json!({"sessionId": id, "prompt": [{"type": "text", "text": text}]});
    let req = rpc.request("session/prompt", prompt);
    let seen = rpc.notes.len();
    let first = rpc.wait_note_until(
        |v| {
            (is_response(v, req) && v.get("error").is_some())
                || streamed_chunk(v).is_some_and(|(chat, t)| chat == id && t.contains(text))
        },
        Some(sent + SEND_WAIT),
    );
    rpc.writer.set_read_timeout(Some(STEP)).unwrap();
    let read_meanwhile = |rpc: &Rpc| {
        let mut kinds: BTreeMap<String, u64> = BTreeMap::new();
        for v in rpc.notes.iter().skip(seen) {
            let kind = v["params"]["update"]["sessionUpdate"]
                .as_str()
                .or_else(|| v["params"]["kind"].as_str())
                .or_else(|| v["method"].as_str())
                .unwrap_or("response");
            *kinds.entry(kind.to_owned()).or_default() += 1;
        }
        // The chunks that did not match: whose they were and the start of their text.
        let chunks: Vec<Value> = rpc
            .notes
            .iter()
            .skip(seen)
            .filter_map(streamed_chunk)
            .take(4)
            .map(|(chat, text)| {
                json!({"sessionId": chat, "text": text.chars().take(160).collect::<String>()})
            })
            .collect();
        json!({"kinds": kinds, "chunks": chunks})
    };
    let first = match first {
        Ok(first) => first,
        Err(e) => {
            let error = json!({"waitedMs": ms(sent), "io": e.to_string(), "stage": "first token",
                               "readMeanwhile": read_meanwhile(rpc)});
            rpc.notes.clear();
            return Err(error);
        }
    };
    if is_response(&first, req) {
        return Err(first["error"].clone());
    }
    let us = micros(sent);
    let end = rpc.wait_note_until(|v| is_response(v, req), Some(sent + SEND_WAIT));
    rpc.writer.set_read_timeout(Some(STEP)).unwrap();
    let error = match end {
        Ok(v) => v.get("error").cloned(),
        Err(e) => Some(json!({"waitedMs": ms(sent), "io": e.to_string(), "stage": "turn end",
                              "readMeanwhile": read_meanwhile(rpc)})),
    };
    rpc.notes.clear();
    match error {
        Some(e) => Err(e),
        None => Ok(us),
    }
}

/// The chat of `bytes` in a home under `scratch`: coord-sim's (`ACPMUX_CHAT_SIM_BIN`, the
/// coordinator stress sim's generator, `cmux-tui/crates/coord-sim`, one Claude coordinator drawn
/// from real sessions' histograms), else [`chat_size_fixture`]'s. Its home, what was written, and
/// which source wrote it.
fn write_size_chat(
    scratch: &Path,
    bytes: u64,
) -> (PathBuf, chat_size_fixture::Written, &'static str, Value) {
    let Some(sim) = std::env::var_os("ACPMUX_CHAT_SIM_BIN").filter(|s| !s.is_empty()) else {
        let home = scratch.join("acpmux");
        let w = chat_size_fixture::write_chat(&home, &scratch.join("work"), bytes).unwrap();
        return (home, w, "chat_size_fixture", Value::Null);
    };
    let out = scratch.join("gen");
    let made = std::process::Command::new(&sim)
        .args(["gen", "--format", "acpmux", "--coordinators", "1", "--harness", "claude"])
        // The generator otherwise increases its record cap with the target size. Keep
        // the distribution fixed across this sweep; large single outputs are a separate workload.
        .args(["--max-line", "20K"])
        .args(["--seed", "1", "--target-bytes", &bytes.to_string()])
        .arg("--out")
        .arg(&out)
        .stdin(Stdio::null())
        .stderr(Stdio::inherit())
        .output()
        .expect("run coord-sim");
    assert!(made.status.success(), "coord-sim gen: {}", String::from_utf8_lossy(&made.stdout));
    let manifest: Value =
        serde_json::from_slice(&std::fs::read(out.join("manifest.json")).unwrap()).unwrap();
    let chat = &manifest["coordinators"][0];
    let id = chat["id"].as_str().expect("the manifest names its chat").to_owned();
    let home = out.join("acpmux-home");
    let settled = chat_size_seed::settle(&home, &id).expect("settle generated offline seed");
    let history_end = settled.last_seq - settled.appended;
    // The settlement's completions end the log; the history's own latest turns, repeated after
    // them, make the newest pages ordinary history again.
    let tail = chat_size_seed::append_settled_turns(&home, &id, history_end, TAIL_BYTES)
        .expect("repeat settled turns after the settlement");
    let mut prepared = vec![];
    if settled.appended > 0 {
        prepared.push(json!([history_end + 1, settled.last_seq]));
    }
    prepared.extend(tail.completion_seqs.iter().map(|seq| json!([seq, seq])));
    let preparation = json!({
        "appended": settled.appended, "historyEndSeq": history_end,
        "removedPrompts": settled.removed_prompts,
        "removedInbox": settled.removed_inbox, "settledTurns": settled.settled_turns,
        "transcriptSeq": settled.transcript_seq,
        "tail": {"from": tail.from, "through": tail.through, "records": tail.records,
                 "bytes": tail.bytes, "turns": tail.turns,
                 "completions": tail.completion_seqs.len()},
        "preparationSeqs": prepared,
    });
    let w = chat_size_fixture::Written {
        id,
        bytes: tail.log_bytes,
        records: tail.log_records,
        turns: tail.log_turns,
        last_seq: tail.last_seq,
        tool_outputs: 0,
        largest_output: 0,
    };
    (home, w, "coord-sim", preparation)
}

/// One size's run: write the chat, open it on a daemon that never read it (cold), measure every
/// read once its log is loaded, then restart the daemon with the chat's agent host running and
/// open it again (the adoption pass).
fn size_run(label: &str, bytes: u64) -> Value {
    let scratch_dir = daemon_env::Scratch::new(&format!("size-{label}"));
    let scratch = scratch_dir.to_path_buf();
    let free = free_bytes(scratch.parent().unwrap_or(&scratch));
    // The log, its kind copies and the daemon's own files, with room to spare.
    if free < bytes + bytes / 4 + (1 << 30) {
        return json!({"size": label, "bytes": bytes, "skipped": "disk",
                      "freeBytes": free});
    }
    let written_at = Instant::now();
    let (home, w, source, preparation) = write_size_chat(&scratch, bytes);
    let write_ms = ms(written_at);
    let prepared = preparation_seqs(&preparation);
    write_config(&home, json!({}));
    let id = w.id.clone();
    let segments =
        std::fs::read_dir(home.join("sessions").join(&id).join("events")).map_or(0, |d| d.count());

    // Cold: a daemon that has never read this chat, so no kind copy, restore point or settled
    // view exists. The open is the pane's attach, as soon as the socket answers. With
    // `ACPMUX_GOD_DHAT=1` (a `dhat-heap` build) this daemon records its heap until its stop.
    // One cold open moves by tens of ms between runs: on Actions the opens fall in a ~57 ms band
    // and an 85-120 ms one, and the runner sits in the slow one for stretches of tens of seconds,
    // so a median or minimum of this chat's opens alone still moved 0.98x-1.49x at 1G. Each of
    // `COLD_SAMPLES` opens is paired with a cold open of a 1 MiB chat on its own daemon just
    // before it, in the same runner state, and the fields hold the floor chat's fastest open plus
    // the median of the pairs' differences: what this size adds to opening any chat. The first
    // opens run on daemons stopped right after their attach, with the home put back after each
    // (cold_home.rs); the last is the run's own daemon.
    let profile = std::env::var("ACPMUX_GOD_DHAT")
        .is_ok_and(|v| v == "1")
        .then(|| scratch.join("dhat-heap.json"));
    let floor_scratch = scratch.join("floor");
    std::fs::create_dir_all(&floor_scratch).unwrap();
    let (floor_home, floor_chat, _, _) = write_size_chat(&floor_scratch, COLD_FLOOR_BYTES);
    write_config(&floor_home, json!({}));
    let floor_cold = cold_home::HomeSnapshot::take(&floor_home);
    let before_cold = cold_home::HomeSnapshot::take(&home);
    let (mut sized, mut floor) = (vec![], vec![]);
    let mut cold_samples_error = Value::Null;
    for _ in 1..COLD_SAMPLES {
        match (
            cold_open(&floor_scratch, &floor_home, &floor_chat.id, &floor_cold),
            cold_open(&scratch, &home, &id, &before_cold),
        ) {
            (Ok(f), Ok(o)) => {
                floor.push(f);
                sized.push(o);
            }
            (f, o) => {
                cold_samples_error = json!({"floor": f.err(), "attach": o.err()});
                break;
            }
        }
    }
    let last_floor = cold_open(&floor_scratch, &floor_home, &floor_chat.id, &floor_cold);
    let mut daemon = Daemon::start(&scratch, &home, profile.as_deref());
    let mut rpc = Rpc::connect(&daemon.socket);
    rpc.call("initialize", json!({"protocolVersion": 1, "clientInfo": {"name": "size-sweep"}}))
        .unwrap();
    let asked = Instant::now();
    let cold = rpc.call("_acpmux/attach", app_attach(&id));
    let last = (ms(daemon.spawned), micros(asked));
    match last_floor {
        Ok(f) if cold.is_ok() => {
            floor.push(f);
            sized.push(last);
        }
        Ok(_) => {}
        Err(e) => cold_samples_error = json!({"floor": e}),
    }
    let cold_attach_ms = paired_floor(&sized, &floor, |s| s.0);
    let cold_attach_us = paired_floor(&sized, &floor, |s| s.1);
    let (cold_ms_samples, cold_us_samples): (Vec<u64>, Vec<u64>) = sized.iter().copied().unzip();
    let (floor_ms_samples, floor_us_samples): (Vec<u64>, Vec<u64>) = floor.iter().copied().unzip();
    let cold_records = cold.as_ref().ok().and_then(|a| a["events"].as_array().map(Vec::len));
    rpc.notes.clear();
    let cold_all_logs = wait_all_logs_within(&mut rpc, SIZE_ALL_LOGS);
    let (rss_after_load, _) = daemon.rss();

    // Metadata saying idle is not enough: startup can restore queued work from the log.
    // Reject that workload instead of attributing its work to opening a settled history.
    let initial = rpc.call("_acpmux/attach", app_attach(&id));
    let initial_state_error = match &initial {
        Ok(reply)
            if reply["session"]["status"] == "idle"
                && reply["session"]["queued"].as_u64() == Some(0)
                && reply["session"]["turn"].is_null() =>
        {
            Value::Null
        }
        Ok(reply) => json!({"reason": "fixture restored pending work", "session": {
            "status": reply["session"]["status"], "queued": reply["session"]["queued"],
            "turn": reply["session"]["turn"]}}),
        Err(error) => error.clone(),
    };
    let last = initial.as_ref().ok().and_then(|r| r["lastSeq"].as_u64()).unwrap_or(w.last_seq);
    rpc.notes.clear();

    // Settled: the log is read; what a long chat costs on its own.
    let rounds = ROUNDS as u64;
    let (attach_us, attach_records, attach_error) =
        timed_rounds(&mut rpc, "_acpmux/attach", rounds, &prepared, |_| app_attach(&id));
    let (rss_idle, _) = daemon.rss();
    let (rss_idle_anon, rss_idle_file) = daemon.rss_split();
    let rss_idle_maps = daemon.rss_maps();
    let (newest_us, newest_records, newest_error) =
        timed_rounds(&mut rpc, "_acpmux/events", rounds, &prepared, |_| {
            older_params(&id, last + 1)
        });
    // Warm pages at fixed proportional depths, as the repeated newest/attach reads above.
    // Moving 2,000 raw sequences every round exhausted the 1 MB baseline (empty pages and
    // future forward cursors) while large chats still returned content. Keep each workload
    // nonempty and report its returned record counts alongside its latency distribution.
    // Every depth reads a full page where the chat holds one: a 1 MB chat's page before
    // `last / 20` held 30 records (595 us) against 1,180 in a 100 MB or 1 GB chat (19 to 22 ms),
    // a 36x that was the page's size, not the chat's. A cursor nearer the start than a full
    // page reaches reads the oldest full page instead (`full_page_before`).
    let full_from = full_page_before(&mut rpc, &id, last);
    let depth = |seq: u64| seq.max(full_from).min(last + 1);
    let (recent_before, mid_before, deep_before) =
        (depth(last * 9 / 10), depth(last / 2), depth(last / 20));
    let (recent_us, _, recent_error) =
        timed_rounds(&mut rpc, "_acpmux/events", rounds, &prepared, |_| {
            older_params(&id, recent_before)
        });
    let (mid_us, _, mid_error) =
        timed_rounds(&mut rpc, "_acpmux/events", rounds, &prepared, |_| {
            older_params(&id, mid_before)
        });
    let (deep_us, _, deep_error) =
        timed_rounds(&mut rpc, "_acpmux/events", rounds, &prepared, |_| {
            older_params(&id, deep_before)
        });
    // The rail's prompt index (direct.ts `readPromptIndex`): its first bounded page, reported.
    let (prompt_index_us, prompt_index_rows, prompt_index_error) =
        timed_rounds(&mut rpc, "_acpmux/events", rounds, &prepared, |_| {
            json!({"sessionId": id, "beforeSeq": last + 1, "promptIndex": true,
                   "kinds": ["user_message"], "limit": 5000, "maxBytes": 256 << 10})
        });
    // The same index read for a fixed number of prompts, the one compared across sizes. The page
    // above holds every prompt up to 256 KB: 5 rows in the 1 MB chat (220 us) against 492 in
    // 100 MB and 538 in 1 GB (2.0 to 2.2 ms, about 4 us a row at every size), a 10x that was the
    // reply's row count, not the chat's size (the scroll depths' full page, `full_page_before`).
    let (prompt_page_us, prompt_page_rows, prompt_page_error) =
        timed_rounds(&mut rpc, "_acpmux/events", rounds, &prepared, |_| {
            json!({"sessionId": id, "beforeSeq": last + 1, "promptIndex": true,
                   "kinds": ["user_message"], "limit": PROMPT_PAGE_ROWS, "maxBytes": 256 << 10})
        });
    // A forward read from the middle (a reconnect's catch-up, a rail jump's `loadThrough`).
    let (forward_us, _, forward_error) =
        timed_rounds(&mut rpc, "_acpmux/events", rounds, &prepared, |_| {
            json!({"sessionId": id, "afterSeq": last / 2,
               "limit": SWEEP_PAGE_ROWS, "maxBytes": SWEEP_PAGE_BYTES})
        });
    let (rss_after_reads, _) = daemon.rss();

    // Typing: a prompt to its first token; the first starts the agent host.
    let (mut sends, mut send_error) = (vec![], Value::Null);
    for round in 0..ROUNDS {
        match send_first_token(&mut rpc, &id, &format!("size {label} {round}")) {
            Ok(us) => sends.push(us),
            Err(e) => {
                send_error = e;
                break;
            }
        }
    }
    let first_send_ms = sends.first().map(|us| us / 1000);
    let later_sends = sends.get(1..).unwrap_or_default();
    let (rss, peak_rss) = daemon.rss();
    let last_before_restart =
        rpc.call("_acpmux/attach", app_attach(&id)).ok().and_then(|a| a["lastSeq"].as_u64());
    drop(rpc);
    // Its host up, the chat's adoption checkpoint is folded in the background
    // (`hosts/checkpoint.rs` `prime_adoption_checkpoint`): how long after the sends it is there.
    // A long chat's host has been up that long; a restart before it reads the whole log at
    // adoption. A daemon that writes none waits the whole bound and restarts without one.
    let checkpoint = home.join("sessions").join(&id).join("adoption-checkpoint.json");
    let checkpoint_wait = Instant::now();
    while !checkpoint.exists() && checkpoint_wait.elapsed() < ADOPTION_CHECKPOINT_WITHIN {
        std::thread::sleep(ALL_LOGS_POLL);
    }
    let adoption_checkpoint_ms = checkpoint.exists().then(|| ms(checkpoint_wait));
    // What the restart reads back of it: its bytes, and each field's (two levels into the
    // folds), so a checkpoint that grows with the chat says which fold keeps what.
    let checkpoint_bytes = std::fs::read(&checkpoint).ok();
    let adoption_checkpoint_bytes = checkpoint_bytes.as_ref().map(Vec::len);
    let adoption_checkpoint_fields =
        // The file's first line is the compaction digest it was saved under (`store.rs`).
        checkpoint_bytes
            .as_deref()
            .and_then(|b| b.iter().position(|&c| c == b'\n').map(|nl| &b[nl + 1..]))
            .and_then(|b| serde_json::from_slice::<Value>(b).ok())
            .map(|point| {
            let mut sizes = serde_json::Map::new();
            let len = |v: &Value| serde_json::to_vec(v).map_or(0, |b| b.len());
            for (key, value) in point.as_object().into_iter().flatten() {
                sizes.insert(key.clone(), len(value).into());
                for (inner, value) in value.as_object().into_iter().flatten() {
                    sizes.insert(format!("{key}.{inner}"), len(value).into());
                    for (leaf, value) in value.as_object().into_iter().flatten() {
                        sizes.insert(format!("{key}.{inner}.{leaf}"), len(value).into());
                    }
                }
            }
            Value::Object(sizes)
        });

    // Restart with the agent host up: the new daemon adopts it (hub/hosts/journal.rs) and the
    // pane opens the chat again.
    let stopped = Instant::now();
    daemon.stop();
    let shutdown_ms = ms(stopped);
    let heap = profile.as_deref().map(|p| dhat_sites::attribute(p, dhat_top()));
    let restart_profile = profile.as_ref().map(|_| scratch.join("dhat-restart-heap.json"));
    let mut daemon = Daemon::start(&scratch, &home, restart_profile.as_deref());
    let mut rpc = Rpc::connect(&daemon.socket);
    rpc.call("initialize", json!({"protocolVersion": 1, "clientInfo": {"name": "size-sweep"}}))
        .unwrap();
    let restart_attach = rpc.call("_acpmux/attach", app_attach(&id));
    let restart_attach_ms = ms(daemon.spawned);
    rpc.notes.clear();
    let restart_all_logs = wait_all_logs_within(&mut rpc, SIZE_ALL_LOGS);
    let adopted = rpc
        .call(
            "_acpmux/events",
            json!({"sessionId": id, "beforeSeq": u64::MAX / 2, "limit": 1, "kinds": ["host_adopted"]}),
        )
        .ok()
        .and_then(|p| oldest_seq(&p))
        .zip(last_before_restart)
        .is_some_and(|(seq, before)| seq > before);
    let restart_send = send_first_token(&mut rpc, &id, &format!("size {label} restarted"));
    let (restart_rss, restart_peak_rss) = daemon.rss();
    let restart_maps = daemon.rss_maps();
    // The same send again once startup's background passes (cold segments, retention, packs)
    // have had time to run: a first send slower than these waited on startup work, not on size.
    let restart_send_after: Vec<(u64, Result<u64, Value>)> = RESTART_SEND_AFTER_MS
        .iter()
        .map(|&after| {
            let since = daemon.spawned.elapsed().as_millis() as u64;
            std::thread::sleep(Duration::from_millis(after.saturating_sub(since)));
            let at = daemon.spawned.elapsed().as_millis() as u64;
            (at, send_first_token(&mut rpc, &id, &format!("size {label} restarted +{after}")))
        })
        .collect();
    // The restarted daemon's own startup phases (`gauges.rs`): where its time to adopt went.
    let restart_startup =
        rpc.call("_acpmux/status", json!({})).ok().map(|s| s["gauges"]["startup"].clone());
    drop(rpc);
    daemon.stop();
    let restart_heap = restart_profile.as_deref().map(|p| dhat_sites::attribute(p, dhat_top()));

    // A second restart: the first adoption left whatever it saves for the next one, so this
    // reads what a chat costs on every restart after its first.
    let mut daemon = Daemon::start(&scratch, &home, None);
    let mut rpc = Rpc::connect(&daemon.socket);
    rpc.call("initialize", json!({"protocolVersion": 1, "clientInfo": {"name": "size-sweep"}}))
        .unwrap();
    let second_attach = rpc.call("_acpmux/attach", app_attach(&id));
    let second_attach_ms = ms(daemon.spawned);
    rpc.notes.clear();
    let second_all_logs = wait_all_logs_within(&mut rpc, SIZE_ALL_LOGS);
    let second_send = send_first_token(&mut rpc, &id, &format!("size {label} restarted twice"));
    let (_, second_peak_rss) = daemon.rss();
    drop(rpc);
    daemon.stop();
    let home_bytes: u64 = home_files(&home).values().sum();
    let result = json!({
        "size": label, "source": source, "bytes": bytes, "logBytes": w.bytes, "records": w.records,
        "turns": w.turns, "lastSeq": w.last_seq, "segments": segments,
        "loadedLastSeq": last, "generatorMaxLineBytes": (source == "coord-sim").then_some(20 << 10),
        "initialStateError": initial_state_error, "fixturePreparation": preparation,
        "bytesPerRecord": w.bytes / w.records.max(1), "recordsPerTurn": w.records / w.turns.max(1),
        "largestToolOutput": w.largest_output, "writeMs": write_ms,
        "coldAttachMs": cold_attach_ms, "coldAttachUs": cold_attach_us,
        "coldAttachSamples": {"ms": cold_ms_samples, "us": cold_us_samples,
                              "floorMs": floor_ms_samples, "floorUs": floor_us_samples,
                              "floorBytes": COLD_FLOOR_BYTES, "error": cold_samples_error},
        "coldAttachRecords": cold_records, "coldAttachError": cold.as_ref().err(),
        "coldAllLogsMs": cold_all_logs.as_ref().ok(), "coldAllLogsError": cold_all_logs.as_ref().err(),
        "rssAfterLoad": rss_after_load,
        "attachUs": attach_us, "attachRecords": attach_records, "attachError": attach_error,
        "newestPageUs": newest_us, "newestPageRecords": newest_records, "newestPageError": short_rows(&newest_us, newest_error),
        "scrollRecentUs": recent_us, "scrollRecentError": short_rows(&recent_us, recent_error),
        "scrollMidUs": mid_us, "scrollMidError": short_rows(&mid_us, mid_error),
        "scrollDeepUs": deep_us, "scrollDeepError": short_rows(&deep_us, deep_error),
        "fullPageFromSeq": full_from,
        "scrollBeforeSeqs": {"recent": recent_before, "mid": mid_before, "deep": deep_before},
        "promptIndexUs": prompt_index_us, "promptIndexRows": prompt_index_rows,
        "promptIndexError": prompt_index_error,
        "promptPageUs": prompt_page_us, "promptPageRows": prompt_page_rows,
        "promptPageError": prompt_page_error,
        "forwardPageUs": forward_us, "forwardPageError": short_rows(&forward_us, forward_error),
        "rssIdle": rss_idle, "rssIdleAnon": rss_idle_anon, "rssIdleFile": rss_idle_file,
        "rssIdleMaps": rss_idle_maps,
        "rssAfterReads": rss_after_reads, "heap": heap,
        "firstSendFirstTokenMs": first_send_ms, "sendFirstTokenUs": spread(later_sends),
        "sendError": send_error,
        "rss": rss, "peakRss": peak_rss, "shutdownMs": shutdown_ms,
        "adoptionCheckpointMs": adoption_checkpoint_ms, "adoptionCheckpointBytes": adoption_checkpoint_bytes,
        "adoptionCheckpointFields": adoption_checkpoint_fields,
        "restartAttachMs": restart_attach_ms, "restartAttachError": restart_attach.as_ref().err(),
        "restartAllLogsMs": restart_all_logs.as_ref().ok(),
        "restartAllLogsError": restart_all_logs.as_ref().err(), "restartAdopted": adopted,
        "restartSendFirstTokenUs": restart_send.as_ref().ok(),
        "restartSendError": restart_send.as_ref().err(),
        "restartSendAfterUs": restart_send_after.iter()
            .map(|(after, r)| json!({"afterMs": after, "us": r.as_ref().ok(), "error": r.as_ref().err()}))
            .collect::<Vec<_>>(),
        "restartRss": restart_rss, "restartPeakRss": restart_peak_rss,
        "restartStartup": restart_startup,
        "restartMaps": restart_maps, "restartHeap": restart_heap,
        "secondRestartAttachMs": second_attach_ms,
        "secondRestartAttachError": second_attach.as_ref().err(),
        "secondRestartAllLogsMs": second_all_logs.as_ref().ok(),
        "secondRestartSendFirstTokenUs": second_send.as_ref().ok(),
        "secondRestartSendError": second_send.as_ref().err(),
        "secondRestartPeakRss": second_peak_rss,
        "homeBytes": home_bytes, "freeBytes": free,
    });
    if let Some(out) = std::env::var_os("FAST_CHECKS_OUT") {
        let out = PathBuf::from(out);
        std::fs::create_dir_all(&out).unwrap();
        let destination = out.join(format!("chat-size-{}-daemon.log", bytes));
        // The sweep owns this artifact; preserve only the tail, never the generated chat.
        if let Ok(mut file) = std::fs::File::open(&daemon.log) {
            let len = file.metadata().map_or(0, |m| m.len());
            let _ = file.seek(SeekFrom::Start(len.saturating_sub(64 * 1024)));
            let mut tail = Vec::new();
            file.take(64 * 1024).read_to_end(&mut tail).unwrap();
            std::fs::write(&destination, tail).unwrap();
            eprintln!("chat size {label}: daemon log {}", destination.display());
        }
    }
    if size_failure(&result).is_some() {
        print_daemon_log(&daemon.log);
    }
    result
}

/// One compact line of what a page is at this size (records and JSON bytes of the last round, the
/// p50 time), so a time that differs between sizes can be told from a page that does.
fn page_cost_line(label: &str, result: &Value) -> String {
    let rows: Vec<String> = [
        ("newest", "newestPageUs"),
        ("recent", "scrollRecentUs"),
        ("mid", "scrollMidUs"),
        ("deep", "scrollDeepUs"),
    ]
    .iter()
    .map(|(name, key)| {
        let at = |field: &str| result[*key][field].as_array().and_then(|a| a.last()).cloned();
        format!(
            "{name}={}rec/{}B/{}orig/{}us",
            at("returnedRecords").unwrap_or(Value::Null),
            at("pageBytes").unwrap_or(Value::Null),
            at("originalRecords").unwrap_or(Value::Null),
            result[*key]["p50"]
        )
    })
    .collect();
    format!("CHAT-SIZE-PAGE {label} bytesPerRecord={} {}", result["bytesPerRecord"], rows.join(" "))
}

fn size_failure(result: &Value) -> Option<String> {
    if !result["skipped"].is_null() {
        return Some(format!("skipped: {}", result["skipped"]));
    }
    if let Some(object) = result.as_object() {
        for (key, value) in object {
            if key.ends_with("Error") && !value.is_null() {
                return Some(format!("{key}: {value}"));
            }
        }
    }
    for key in SIZE_RATIO_KEYS {
        if result.pointer(key).and_then(Value::as_f64).is_none() {
            return Some(format!("missing metric {key}"));
        }
    }
    None
}

/// A measured page's error, or one when a round returned other than [`SWEEP_PAGE_ROWS`]: a short
/// page's time is its row count's, and the sizes' ratio would be too.
fn short_rows(timing: &Value, error: Value) -> Value {
    if !error.is_null() {
        return error;
    }
    let rows = timing["returnedRecords"].as_array().cloned().unwrap_or_default();
    match rows.iter().find(|n| n.as_u64() != Some(SWEEP_PAGE_ROWS)) {
        Some(n) => json!({"reason": "page held other than the measured rows",
                          "records": n, "wanted": SWEEP_PAGE_ROWS}),
        None => Value::Null,
    }
}

#[test]
fn a_short_measured_page_is_an_error() {
    let full = json!({"p50": 10, "returnedRecords": [SWEEP_PAGE_ROWS, SWEEP_PAGE_ROWS]});
    assert!(short_rows(&full, Value::Null).is_null());
    let short = json!({"p50": 10, "returnedRecords": [SWEEP_PAGE_ROWS, SWEEP_PAGE_ROWS - 1]});
    assert!(!short_rows(&short, Value::Null).is_null());
    assert_eq!(short_rows(&full, json!("rpc")), json!("rpc"));
}

/// Prompts in the size sweep's fixed prompt-index page: as many as the 1 MB fixture holds.
const PROMPT_PAGE_ROWS: u64 = 5;

/// What each size costs against the first (1 MB): the numbers of the goal (open, scroll,
/// typing, memory), and the startup loads beside them, which are not in the max.
const SIZE_RATIO_KEYS: [&str; 16] = [
    "/coldAttachMs",
    "/attachUs/p50",
    "/attachUs/p95",
    "/newestPageUs/p50",
    "/scrollRecentUs/p50",
    "/scrollMidUs/p50",
    "/scrollDeepUs/p50",
    "/promptPageUs/p50",
    "/forwardPageUs/p50",
    "/sendFirstTokenUs/p50",
    "/sendFirstTokenUs/p95",
    "/restartAttachMs",
    "/restartSendFirstTokenUs",
    "/rssIdle",
    "/peakRss",
    "/restartPeakRss",
];
const SIZE_LOAD_KEYS: [&str; 5] = [
    "/coldAllLogsMs",
    "/restartAllLogsMs",
    "/secondRestartAttachMs",
    "/secondRestartSendFirstTokenUs",
    "/secondRestartPeakRss",
];

/// Each size's numbers against the first size's, and the largest ratio of [`SIZE_RATIO_KEYS`].
fn size_ratios(base: &Value, size: &Value) -> (Value, Option<(String, f64)>) {
    let mut ratios = serde_json::Map::new();
    let mut max: Option<(String, f64)> = None;
    for (key, counted) in
        SIZE_RATIO_KEYS.iter().map(|k| (k, true)).chain(SIZE_LOAD_KEYS.iter().map(|k| (k, false)))
    {
        let (Some(b), Some(s)) =
            (base.pointer(key).and_then(Value::as_f64), size.pointer(key).and_then(Value::as_f64))
        else {
            continue;
        };
        if b <= 0.0 {
            continue;
        }
        let r = s / b;
        ratios.insert((*key).to_owned(), json!((r * 100.0).round() / 100.0));
        if counted && max.as_ref().is_none_or(|(_, m)| r > *m) {
            max = Some(((*key).to_owned(), r));
        }
    }
    (Value::Object(ratios), max)
}

/// The sweep: `CHAT-SIZE {...}` per size, `CHAT-SIZE-RATIO {...}` per size against the first,
/// and `infinite_chat_size_ratio_max <ratio> <key> <size>` (the daemon's part of the goal).
/// Manual, on Linux CI (release): `ACPMUX_CHAT_SIZES=1M,100M,1G,4G cargo test -p acpmux --release
/// --test god_daemon chat_size_sweep -- --ignored --nocapture`.
#[test]
#[ignore = "manual: writes chats up to 4 GB; run on Linux CI"]
fn chat_size_sweep() {
    let sizes = std::env::var("ACPMUX_CHAT_SIZES").unwrap_or_else(|_| CHAT_SIZES.to_owned());
    assert_eq!(sizes.split(',').next().map(parse_size), Some(1 << 20), "the baseline must be 1 MB");
    let mut results: Vec<Value> = vec![];
    let mut worst: Option<(String, f64, String)> = None;
    for label in sizes.split(',').map(str::trim).filter(|s| !s.is_empty()) {
        let result = size_run(label, parse_size(label));
        println!("CHAT-SIZE {result}");
        println!("{}", page_cost_line(label, &result));
        // Its own line: the result above is cut short in a CI log, and these say which fold
        // of the adoption checkpoint grows with the chat.
        // One field a line, largest first: a CI log cuts a long line short.
        println!(
            "CHAT-SIZE-CHECKPOINT {label} {} {}",
            result["adoptionCheckpointBytes"], result["restartStartup"]
        );
        let mut fields: Vec<(&String, u64)> = result["adoptionCheckpointFields"]
            .as_object()
            .into_iter()
            .flatten()
            .map(|(k, v)| (k, v.as_u64().unwrap_or(0)))
            .collect();
        fields.sort_by_key(|f| std::cmp::Reverse(f.1));
        for (field, bytes) in fields.into_iter().take(16) {
            println!("CHAT-SIZE-FIELD {label} {field} {bytes}");
        }
        if let Some(base) = results
            .first()
            .filter(|base| size_failure(base).is_none() && size_failure(&result).is_none())
        {
            let (ratios, max) = size_ratios(base, &result);
            println!(
                "CHAT-SIZE-RATIO {}",
                json!({"size": label, "vs": base["size"], "ratios": ratios,
                     "max": max.as_ref().map(|(k, r)| json!({"key": k, "ratio": r}))})
            );
            if let Some((key, r)) = max
                && worst.as_ref().is_none_or(|(_, w, _)| r > *w)
            {
                worst = Some((key, r, label.to_owned()));
            }
        }
        results.push(result);
    }
    let failures: Vec<_> = results
        .iter()
        .filter_map(|r| size_failure(r).map(|why| format!("{}: {why}", r["size"])))
        .collect();
    if !failures.is_empty() {
        println!("infinite_chat_size_ratio_max null incomplete");
        panic!("incomplete size sweep: {}", failures.join("; "));
    }
    match &worst {
        Some((key, r, label)) => println!("infinite_chat_size_ratio_max {r:.2} {key} {label}"),
        None => println!("infinite_chat_size_ratio_max null"),
    }
    println!("CHAT-SIZE-TABLE-BEGIN");
    println!(
        "| Metric (Us = microseconds, Ms = milliseconds, RSS = bytes) | {} |",
        results.iter().map(|r| r["size"].as_str().unwrap()).collect::<Vec<_>>().join(" | ")
    );
    println!("|---|{}", "---|".repeat(results.len()));
    for key in SIZE_RATIO_KEYS {
        let base = results[0].pointer(key).and_then(Value::as_f64).unwrap();
        let cells: Vec<_> = results
            .iter()
            .map(|r| {
                let value = r.pointer(key).and_then(Value::as_f64).unwrap();
                if base > 0.0 {
                    format!("{value:.0} ({:.2}x)", value / base)
                } else {
                    format!("{value:.0} (ratio unavailable)")
                }
            })
            .collect();
        println!("| {key} | {} |", cells.join(" | "));
    }
    println!("CHAT-SIZE-TABLE-END");
}

#[test]
fn incomplete_chat_sizes_cannot_be_reported_as_success() {
    let complete = json!({"size": "4G", "coldAttachMs": 10,
        "attachUs": {"p50": 20, "p95": 30}, "newestPageUs": {"p50": 20},
        "scrollRecentUs": {"p50": 20}, "scrollMidUs": {"p50": 20},
        "scrollDeepUs": {"p50": 20}, "promptPageUs": {"p50": 20},
        "forwardPageUs": {"p50": 20}, "sendFirstTokenUs": {"p50": 20, "p95": 30},
        "restartAttachMs": 10, "restartSendFirstTokenUs": 20,
        "rssIdle": 100, "peakRss": 200, "restartPeakRss": 200});
    assert!(size_failure(&complete).is_none());
    for (key, value) in [
        ("skipped", json!("disk")),
        ("coldAllLogsError", json!({"timeoutMs": 1800000})),
        ("restartAllLogsError", json!({"timeoutMs": 1800000})),
        ("sendError", json!({"stage": "first token"})),
        ("initialStateError", json!({"queued": 1})),
        ("attachUs", json!({"p50": 20})),
    ] {
        let mut result = complete.clone();
        result[key] = value;
        assert!(size_failure(&result).is_some(), "incomplete result: {result}");
    }
}

#[test]
fn chat_size_ratios_use_the_same_metric_and_baseline() {
    let base = json!({"attachUs": {"p50": 20, "p95": 40}, "rssIdle": 100});
    let larger = json!({"attachUs": {"p50": 30, "p95": 42}, "rssIdle": 200});
    let (ratios, max) = size_ratios(&base, &larger);
    assert_eq!(ratios["/attachUs/p50"], 1.5);
    assert_eq!(ratios["/attachUs/p95"], 1.05);
    assert_eq!(max, Some(("/rssIdle".into(), 2.0)));
}

#[test]
fn chat_size_page_coverage_excludes_preparation_and_missing_sequences() {
    let reply = json!({"events": [{"seq": 99}, {"seq": 100}, {"seq": 101}, {}, {"seq": 0},
                                  {"seq": 103}, {"seq": 104}]});
    // Settlement 101..=102, one repeated-turn completion at 104: 99, 100 and 103 are history.
    let prepared = preparation_seqs(&json!({"preparationSeqs": [[101, 102], [104, 104]]}));
    assert_eq!(prepared, vec![(101, 102), (104, 104)]);
    assert_eq!(original_page_records(&reply, &prepared), 3);
    assert_eq!(original_page_records(&json!({"events": [{"seq": 101}]}), &prepared), 0);
    assert_eq!(original_page_records(&json!({}), &prepared), 0);
    assert_eq!(original_page_records(&json!({"events": [{"seq": 101}]}), &[]), 1);
}

#[test]
fn a_streamed_chunk_is_read_from_either_envelope() {
    // As server/mod.rs `deliver` sends one to a connection with and without `eventStream`.
    let update = json!({"sessionUpdate": "agent_message_chunk",
                        "content": {"type": "text", "text": "turn: size 1M 0"}});
    let event = json!({"jsonrpc": "2.0", "method": "_acpmux/event", "params": {
        "sessionId": "chat", "seq": 9, "at": 1, "dir": "in", "kind": "agent_message_chunk",
        "msg": {"jsonrpc": "2.0", "method": "session/update",
                "params": {"sessionId": "agent-session", "update": update}}}});
    assert_eq!(streamed_chunk(&event), Some(("chat", "turn: size 1M 0")));
    let acp = json!({"jsonrpc": "2.0", "method": "session/update",
                     "params": {"sessionId": "chat", "update": update}});
    assert_eq!(streamed_chunk(&acp), Some(("chat", "turn: size 1M 0")));
    let thought = json!({"method": "_acpmux/event", "params": {"sessionId": "chat",
        "kind": "agent_thought_chunk", "msg": {"params": {"update": {
            "sessionUpdate": "agent_thought_chunk", "content": {"text": "size 1M 0"}}}}}});
    assert_eq!(streamed_chunk(&thought), None);
}
