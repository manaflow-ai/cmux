//! What each caller of the session list is sent, at 1,000 and at 10,000 chats. Leo, 2026-11-04:
//! interaction cost stays constant as sessions grow, "never ... acceptable ... linear time growth
//! degradation". A trace on cosmic-gray (about 10,000 chats, 2026-11-18) found 1.9 GB of list
//! replies in 7.7 min, in pages of about 1 MB, each page sized by the number of chats: from
//! `acpmux-ls-paged` (617), `acpmux-cli` (586), `acpmux-peer` (323) and the agent pane (217).
//!
//! Each caller's reads are played over one connection as it made them (`before`) and as it makes
//! them now (`after`): a script's census follows the list from its cursor; `ensure` and
//! `new --host auto` ask for one name; `session move --all-idle`, `send --tag` and the roster ask
//! for open chats only; a peer that lagged follows from where the hole began; a pane mount follows
//! from the shared cursor. Between two reads one chat changes, as on a busy machine.
//!
//! - Detector (runs in CI): [`no_list_caller_is_sent_more_as_chats_grow`] fails if what any caller
//!   is sent at 5,000 chats is more than at 500 (20% and 1 KiB of slack).
//! - Bench (by hand, one harness for before and after):
//!   `cargo test --release -p acpmux --lib list_caller_scale_bench -- --ignored --nocapture`.
//!   Prints bytes and CPU per call and per minute at the trace's rates, at 1,000 and 10,000.

use crate::config::{Config, StoreMode};
use crate::rpc::{Message, method};
use serde_json::{Value, json};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

/// About this many chats are open, however many there are: the rest are closed, as on a machine
/// that has run for weeks (what a machine runs at once does not grow with what it ran before).
const OPEN: usize = 40;

/// A hub with `chats` chats of its own: about [`OPEN`] idle, running or waiting, spread through
/// the list, the rest closed; chat 7 (open) is named `coord`.
fn hub(chats: usize) -> Arc<crate::hub::Hub> {
    let mut config = Config::default();
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    let stride = (chats / OPEN).max(8);
    for i in 0..chats {
        let open = i % stride == 7;
        let status = match (open, i % 3) {
            (false, _) => "closed",
            (true, 0) => "idle",
            (true, 1) => "running",
            (true, _) => "waiting",
        };
        let name = if i == 7 { "coord".to_owned() } else { format!("chat {i}") };
        let meta = serde_json::from_value(json!({
            "schema": crate::store::META_SCHEMA, "id": format!("own-{i:05}"), "name": name,
            "harness": "fake", "cwd": format!("/work/{}", i % 40), "status": status,
            "createdAt": i + 1, "updatedAt": i + 1
        }))
        .unwrap();
        store.save(&meta).unwrap();
    }
    crate::hub::Hub::new(config, store)
}

/// One connection's requests, each reply's bytes counted.
struct Conn {
    input: mpsc::Sender<String>,
    output: mpsc::Receiver<String>,
    task: tokio::task::JoinHandle<()>,
    next: u64,
    bytes: usize,
}

impl Conn {
    async fn open(hub: &Arc<crate::hub::Hub>) -> Self {
        let (input, incoming) = mpsc::channel(64);
        let (outgoing, output) = mpsc::channel(4096);
        let task = tokio::spawn(super::serve_connection(hub.clone(), incoming, outgoing));
        let mut conn = Self { input, output, task, next: 1, bytes: 0 };
        conn.ask(method::INITIALIZE, json!({"protocolVersion": 1})).await;
        conn.bytes = 0;
        conn
    }

    /// The result of `m` with `params`; its reply's bytes are counted.
    async fn ask(&mut self, m: &str, params: Value) -> Value {
        let id = self.next;
        self.next += 1;
        self.input.send(Message::request(id, m, params).to_line()).await.unwrap();
        let (reply, bytes) = tokio::time::timeout(Duration::from_secs(60), async {
            loop {
                let line = self.output.recv().await.expect("the connection stays open");
                let reply: Value = serde_json::from_str(&line).unwrap();
                if reply["id"] == id {
                    return (reply, line.len());
                }
            }
        })
        .await
        .expect("the reply comes");
        assert!(reply.get("error").is_none(), "{m}: {}", reply["error"]);
        self.bytes += bytes;
        reply["result"].clone()
    }

    /// `first`'s reply and every `_acpmux/sessions` page after it, by its `nextCursor`, with
    /// `page` added to each page's request.
    async fn walk(&mut self, m: &str, first: Value, page: Value) -> usize {
        let mut reply = self.ask(m, first).await;
        let mut rows = reply["sessions"].as_array().map_or(0, Vec::len);
        while let Some(cursor) = reply["nextCursor"].as_str().map(str::to_owned) {
            let mut params = page.clone();
            params["cursor"] = json!(cursor);
            reply = self.ask(method::MUX_SESSIONS, params).await;
            rows += reply["sessions"].as_array().map_or(0, Vec::len);
        }
        rows
    }

    /// A follow from `cursor` (`hub/row_log.rs`), each reply while `more`; the cursor moves on.
    async fn follow(&mut self, cursor: &mut (String, u64), extra: Value) {
        loop {
            let mut params = json!({"enabled": true, "afterSeq": cursor.1, "listEpoch": cursor.0});
            for (k, v) in extra.as_object().into_iter().flatten() {
                params[k] = v.clone();
            }
            let reply = self.ask(method::MUX_WATCH, params).await;
            assert_eq!(reply["follow"], true, "a follow, not a reset: {reply}");
            cursor.1 = reply["listSeq"].as_u64().unwrap();
            if reply["more"] != true {
                return;
            }
        }
    }
}

impl Drop for Conn {
    fn drop(&mut self) {
        self.task.abort();
    }
}

/// The list position a whole read is current to, from its first page.
async fn cursor_of(hub: &Arc<crate::hub::Hub>) -> (String, u64) {
    let mut conn = Conn::open(hub).await;
    let first = conn.ask(method::MUX_WATCH, json!({"enabled": true, "limit": 1})).await;
    (first["listEpoch"].as_str().unwrap().to_owned(), first["listSeq"].as_u64().unwrap())
}

/// The callers of the trace, and the reply rate each had there (replies a minute).
#[derive(Clone, Copy, Debug)]
enum Caller {
    LsPaged,
    CliEnsure,
    CliMoveIdle,
    CliTag,
    Peer,
    Pane,
}

impl Caller {
    const ALL: [Self; 6] =
        [Self::LsPaged, Self::CliEnsure, Self::CliMoveIdle, Self::CliTag, Self::Peer, Self::Pane];

    fn label(self) -> &'static str {
        match self {
            Self::LsPaged => "acpmux-ls-paged census",
            Self::CliEnsure => "acpmux-cli ensure / new --host auto",
            Self::CliMoveIdle => "acpmux-cli session move --all-idle",
            Self::CliTag => "acpmux-cli send --tag (v1), roster",
            Self::Peer => "acpmux-peer relink after lagged",
            Self::Pane => "agent pane mount",
        }
    }

    /// Replies a minute in the trace (its calls over 7.7 min; the CLI's 586 split evenly).
    fn per_minute(self) -> f64 {
        match self {
            Self::LsPaged => 617.0 / 7.7,
            Self::CliEnsure | Self::CliMoveIdle | Self::CliTag => 586.0 / 7.7 / 3.0,
            Self::Peer => 323.0 / 7.7,
            Self::Pane => 217.0 / 7.7,
        }
    }

    /// The bytes this caller is sent for one call, `after` the fix or before it. One chat changes
    /// first, as between two calls on a busy machine; `cursor` is where a follower's last call
    /// left it.
    async fn call(
        self,
        hub: &Arc<crate::hub::Hub>,
        after: bool,
        cursor: &mut (String, u64),
    ) -> usize {
        hub.own_row_changed_for_test("own-00027", "renamed");
        let mut conn = Conn::open(hub).await;
        let all = json!({});
        match (self, after) {
            // `acpmux_ls_paged.py`: pages of 2,048 rows to the end, then a catch-up page.
            (Self::LsPaged, false) => {
                let page = json!({"limit": 2048});
                conn.walk(method::MUX_SESSIONS, page.clone(), page.clone()).await;
                conn.ask(method::MUX_SESSIONS, page).await;
            }
            (Self::LsPaged | Self::Peer, true) => conn.follow(cursor, json!({})).await,
            (Self::CliEnsure, false) | (Self::CliMoveIdle, false) | (Self::CliTag, false) => {
                conn.walk(method::MUX_SESSIONS, all.clone(), all).await;
            }
            (Self::CliEnsure, true) => {
                let rows = conn.walk(method::MUX_SESSIONS, json!({"name": "coord"}), all).await;
                assert_eq!(rows, 1, "one chat is named coord");
            }
            (Self::CliMoveIdle, true) => {
                let open =
                    json!({"localOnly": true, "excludeStatus": ["closed", "running", "waiting"]});
                conn.walk(method::MUX_SESSIONS, open.clone(), open).await;
            }
            (Self::CliTag, true) => {
                let live = json!({"excludeStatus": ["closed"]});
                conn.walk(method::MUX_SESSIONS, live.clone(), live).await;
            }
            // A cleared cursor: the whole list without tools, in its pages.
            (Self::Peer, false) => {
                let watch = json!({"enabled": true, "withTools": false});
                conn.walk(method::MUX_WATCH, watch, json!({"withTools": false})).await;
            }
            // A new pane with no cursor: pages of 200 rows to the end.
            (Self::Pane, false) => {
                let first = json!({"enabled": true, "limit": 200});
                conn.walk(method::MUX_WATCH, first, json!({"limit": 200})).await;
            }
            (Self::Pane, true) => conn.follow(cursor, json!({"limit": 200})).await,
        }
        conn.bytes
    }
}

/// This process's CPU time so far.
fn cpu() -> Duration {
    // SAFETY: getrusage fills a zeroed struct owned here.
    let mut usage: libc::rusage = unsafe { std::mem::zeroed() };
    // SAFETY: RUSAGE_SELF with a valid pointer.
    unsafe { libc::getrusage(libc::RUSAGE_SELF, &mut usage) };
    let tv = |t: libc::timeval| Duration::new(t.tv_sec as u64, t.tv_usec as u32 * 1000);
    tv(usage.ru_utime) + tv(usage.ru_stime)
}

/// Each caller's bytes and CPU for one call (the mean of `calls`), at `chats` chats.
async fn costs(chats: usize, after: bool, calls: usize) -> Vec<(Caller, usize, Duration)> {
    let hub = hub(chats);
    let mut out = Vec::new();
    for caller in Caller::ALL {
        let mut cursor = cursor_of(&hub).await;
        // A first call settles what a cold one builds once (closed rows' cached bytes).
        caller.call(&hub, after, &mut cursor).await;
        let (mut bytes, started) = (0, cpu());
        for _ in 0..calls {
            bytes += caller.call(&hub, after, &mut cursor).await;
        }
        let used = cpu().saturating_sub(started);
        out.push((caller, bytes / calls, used / calls as u32));
    }
    out
}

/// Detector: no caller is sent more for a call as the chats grow tenfold, now that each reads
/// what it shows, one name, the open chats, or what changed since its cursor. The same callers'
/// reads from before the fix grow with the list, so the harness can see growth.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn no_list_caller_is_sent_more_as_chats_grow() {
    let (small, large) = (500, 5_000);
    let after_small = costs(small, true, 2).await;
    let after_large = costs(large, true, 2).await;
    for ((caller, few, _), (_, many, _)) in after_small.iter().zip(&after_large) {
        println!("LIST-CALLER after {caller:?}: {small} chats {few} B, {large} chats {many} B");
        assert!(
            *many <= few * 6 / 5 + 1024,
            "{} is sent {many} B a call at {large} chats, {few} B at {small}: it grows with the list",
            caller.label()
        );
    }
    let before_small = costs(small, false, 1).await;
    let before_large = costs(large, false, 1).await;
    for ((caller, few, _), (_, many, _)) in before_small.iter().zip(&before_large) {
        assert!(*many > few * 5, "{caller:?} before the fix: {few} B then {many} B");
    }
}

/// Bench: before and after, at 1,000 and 10,000 chats, bytes and CPU per call and per minute at
/// the trace's rates (module docs).
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "a harness, run by hand"]
async fn list_caller_scale_bench() {
    let calls = std::env::var("ACPMUX_LIST_BENCH_CALLS").ok().and_then(|v| v.parse().ok());
    let calls = calls.unwrap_or(5);
    println!(
        "| caller | chats | before B/call | after B/call | before MB/min | after KB/min | before CPU ms/min | after CPU ms/min |"
    );
    println!("|---|---|---|---|---|---|---|---|");
    let mut totals = [(0.0, 0.0); 2];
    for (at, chats) in [1_000, 10_000].into_iter().enumerate() {
        let before = costs(chats, false, calls).await;
        let after = costs(chats, true, calls).await;
        for ((caller, b, bc), (_, a, ac)) in before.iter().zip(&after) {
            let rate = caller.per_minute();
            let ms = |d: &Duration| d.as_secs_f64() * 1000.0 * rate;
            totals[at].0 += *b as f64 * rate;
            totals[at].1 += *a as f64 * rate;
            println!(
                "| {} | {chats} | {b} | {a} | {:.1} | {:.1} | {:.0} | {:.0} |",
                caller.label(),
                *b as f64 * rate / 1e6,
                *a as f64 * rate / 1e3,
                ms(bc),
                ms(ac),
            );
        }
    }
    for (at, chats) in [1_000, 10_000].into_iter().enumerate() {
        let (b, a) = totals[at];
        println!(
            "LIST-CALLER total at {chats} chats: before {:.1} MB/min, after {:.1} KB/min",
            b / 1e6,
            a / 1e3
        );
    }
}
