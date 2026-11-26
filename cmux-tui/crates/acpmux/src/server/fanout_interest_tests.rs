//! Which connections a hub event wakes (cmuxterm-hq#13493 item 3; Leo, 2026-11-18: "Why should
//! non visible thing even affect the renderer thread anyways?"). Each connection's fan-out task
//! read the hub's one broadcast and dropped what it did not need, so every record of every chat
//! woke every connection: O(events x connections). A connection that is not attached to a chat
//! and does not watch is never woken by that chat's records; a watcher is woken only by the
//! records a watcher is sent anything for (`interest.rs`).
//!
//! The cost harness is manual:
//! `cargo test -p acpmux --lib fanout_wake_cost -- --ignored --nocapture --test-threads=1`.

use super::fanout::tests::{WAKE_PREFIX, wakes};
use crate::config::{Config, StoreMode};
use crate::rpc::{Message, method};
use serde_json::{Value, json};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::mpsc;

const WAIT: Duration = Duration::from_secs(60);

fn sid(i: usize) -> String {
    format!("s-{i:05}")
}

fn hub_of(n: usize) -> Arc<crate::hub::Hub> {
    let mut config = Config::default();
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = crate::hub::Hub::new(config, store);
    for i in 0..n {
        let meta: crate::store::SessionMeta = serde_json::from_value(json!({
            "schema": crate::store::META_SCHEMA, "id": sid(i), "name": sid(i),
            "harness": "claude", "family": "claude", "cwd": "/w", "status": "idle",
            "createdAt": 1, "updatedAt": i + 1, "preview": "A short synthetic reply",
        }))
        .unwrap();
        hub.insert_test_session(meta);
    }
    hub
}

fn name(tag: &str) -> String {
    format!("{WAKE_PREFIX}{tag}-{}", uuid::Uuid::now_v7().simple())
}

/// One connection's input (kept open: a closed request stream ends the fan-out) and its lines.
struct Client {
    name: String,
    input: mpsc::Sender<String>,
    out: mpsc::Receiver<String>,
    next_id: u64,
}

impl Client {
    async fn connect(hub: &Arc<crate::hub::Hub>, tag: &str) -> Self {
        let (input, incoming) = mpsc::channel(8);
        let (output, out) = mpsc::channel(65_536);
        tokio::spawn(super::serve_connection_with(
            hub.clone(),
            incoming,
            output,
            super::Origin::Local,
        ));
        let mut client = Self { name: name(tag), input, out, next_id: 0 };
        let hello =
            json!({"protocolVersion": 1, "clientInfo": {"name": client.name, "version": "0"}});
        client.call(method::INITIALIZE, hello).await;
        client
    }

    /// Sends a request and reads lines until its answer, which must not be an error; returns its result.
    async fn call(&mut self, m: &str, params: Value) -> Value {
        self.next_id += 1;
        let id = self.next_id;
        self.input.send(Message::request(id, m, params).to_line()).await.unwrap();
        let out = &mut self.out;
        tokio::time::timeout(WAIT, async {
            loop {
                let reply: Value = serde_json::from_str(&out.recv().await.unwrap()).unwrap();
                if reply["id"] == id {
                    assert!(reply.get("error").is_none(), "{m}: {reply}");
                    return reply["result"].clone();
                }
            }
        })
        .await
        .unwrap_or_else(|_| panic!("{m} answers"))
    }

    async fn attach(&mut self, id: &str) {
        self.call(method::MUX_ATTACH, json!({"sessionId": id, "waitLogs": false, "limit": 0}))
            .await;
    }

    async fn watch(&mut self, on: bool) -> Value {
        self.call(method::MUX_WATCH, json!({"enabled": on})).await
    }

    /// Reads lines until one contains `needle`; returns the lines read before it, and it.
    async fn until(&mut self, needle: &str) -> Vec<String> {
        let out = &mut self.out;
        tokio::time::timeout(WAIT, async {
            let mut seen = Vec::new();
            loop {
                let line = out.recv().await.unwrap();
                let done = line.contains(needle);
                seen.push(line);
                if done {
                    return seen;
                }
            }
        })
        .await
        .unwrap_or_else(|_| panic!("no line with {needle}"))
    }

    fn wakes(&self) -> u64 {
        wakes(&self.name)
    }
}

fn chunk(id: &str, text: &str) -> Value {
    json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": id,
        "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text}}}})
}

fn session(hub: &crate::hub::Hub, id: &str) -> Arc<crate::hub::Session> {
    hub.resolve(id).unwrap()
}

fn changed_of(lines: &[String], id: &str, record_kind: &str) -> usize {
    lines
        .iter()
        .filter_map(|line| serde_json::from_str::<Value>(line).ok())
        .filter(|v| {
            v["method"] == method::MUX_SESSION_CHANGED
                && v["params"]["sessionId"] == id
                && v["params"]["recordKind"] == record_kind
        })
        .count()
}

const STREAMED: usize = 200;
const CHANGES: usize = 5;

/// The detector: a connection attached to chat T, not watching, is never woken by chat S's
/// records, streamed or changes; a watcher is woken by S's changes and not by its streamed text;
/// a connection attached to S still gets every record of it, in order.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_connection_not_attached_and_not_watching_is_never_woken_by_other_chats() {
    let hub = hub_of(2);
    let (s, t) = (sid(0), sid(1));
    let mut quiet = Client::connect(&hub, "quiet").await;
    quiet.attach(&t).await;
    let mut reader = Client::connect(&hub, "reader").await;
    reader.attach(&s).await;
    let mut watcher = Client::connect(&hub, "watcher").await;
    watcher.attach(&t).await;
    watcher.watch(true).await;
    let (quiet_before, watcher_before) = (quiet.wakes(), watcher.wakes());

    let busy = session(&hub, &s);
    for n in 0..STREAMED {
        hub.append(&busy, "in", "agent_message_chunk", chunk(&s, &format!("w{n} ")));
        if n % (STREAMED / CHANGES) == 0 {
            hub.append(&busy, "mux", "titled", json!({"title": format!("t{n}")}));
        }
    }
    hub.append(&session(&hub, &t), "in", "agent_message_chunk", chunk(&t, "end-of-t"));

    quiet.until("end-of-t").await;
    let watched = watcher.until("end-of-t").await;
    let read = reader.until(&format!("w{} ", STREAMED - 1)).await;

    let quiet_woke = quiet.wakes() - quiet_before;
    assert_eq!(
        quiet_woke, 1,
        "a connection attached to {t} only woke {quiet_woke} times for {STREAMED} streamed records \
         and {CHANGES} changes of {s} and one record of {t}"
    );
    let watcher_woke = watcher.wakes() - watcher_before;
    assert!(
        watcher_woke < (STREAMED / 4) as u64,
        "a watcher woke {watcher_woke} times: {s}'s streamed text wakes it"
    );
    assert_eq!(changed_of(&watched, &s, "titled"), CHANGES, "a watcher hears every change of {s}");
    let texts: Vec<String> = read
        .iter()
        .filter_map(|line| serde_json::from_str::<Value>(line).ok())
        .filter(|v| v["method"] == method::SESSION_UPDATE)
        .filter_map(|v| {
            v.pointer("/params/update/content/text").and_then(Value::as_str).map(str::to_owned)
        })
        .collect();
    let expected: Vec<String> = (0..STREAMED).map(|n| format!("w{n} ")).collect();
    assert_eq!(texts, expected, "the connection attached to {s} gets each record once, in order");
}

/// `_acpmux/watch {enabled: false}` is the per-connection pause: a page that turns its watch off
/// is not woken by other chats' changes, and turned on again it hears the next one.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_watch_turned_off_stops_waking_for_other_chats_changes() {
    let hub = hub_of(2);
    let (s, t) = (sid(0), sid(1));
    let mut page = Client::connect(&hub, "page").await;
    page.attach(&t).await;
    page.watch(true).await;
    // The pause builds no list: the page keeps its rows and follows from its cursor when it turns
    // the watch on again (webviews sessionPages.ts `pause`).
    assert_eq!(page.watch(false).await, json!({}), "a paused watch answers without the list");
    let before = page.wakes();
    let busy = session(&hub, &s);
    for n in 0..CHANGES {
        hub.append(&busy, "mux", "titled", json!({"title": format!("off{n}")}));
    }
    hub.append(&session(&hub, &t), "in", "agent_message_chunk", chunk(&t, "paused-end"));
    let paused = page.until("paused-end").await;
    assert_eq!(page.wakes() - before, 1, "a paused watch woke for {s}'s changes");
    assert_eq!(changed_of(&paused, &s, "titled"), 0);

    page.watch(true).await;
    hub.append(&busy, "mux", "renamed", json!({"name": "back"}));
    hub.append(&session(&hub, &t), "in", "agent_message_chunk", chunk(&t, "resumed-end"));
    let resumed = page.until("resumed-end").await;
    assert_eq!(changed_of(&resumed, &s, "renamed"), 1, "a resumed watch hears the next change");
}

#[cfg(not(unix))]
fn cpu_now() -> Duration {
    unimplemented!("CPU time is read through libc on unix only")
}

#[cfg(unix)]
fn cpu_now() -> Duration {
    // SAFETY: getrusage writes the struct it is given and reads nothing else.
    let mut usage: libc::rusage = unsafe { std::mem::zeroed() };
    unsafe { libc::getrusage(libc::RUSAGE_SELF, &mut usage) };
    let tv = |t: libc::timeval| Duration::new(t.tv_sec as u64, (t.tv_usec as u32) * 1000);
    tv(usage.ru_utime) + tv(usage.ru_stime)
}

const SESSIONS: usize = 10_000;
const EVENTS: usize = 4_000;

/// What each hub event costs the fan-out at 4, 16 and 64 connections over 10,000 chats: one
/// watcher (a sidebar) and the rest each attached to one chat (an open pane), while records land
/// across all the chats (one in ten a change a watcher hears, the rest streamed text). Prints the
/// fan-out wakes per event and the process's CPU and wall time per event, from the first record
/// to the last connection reading its last.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "manual per-event cost measurement"]
async fn fanout_wake_cost() {
    for connections in [4usize, 16, 64] {
        let hub = hub_of(SESSIONS);
        let mut watcher = Client::connect(&hub, "cost-watcher").await;
        watcher.watch(true).await;
        let mut panes = Vec::new();
        for i in 1..connections {
            let mut pane = Client::connect(&hub, "cost-pane").await;
            pane.attach(&sid(i)).await;
            panes.push(pane);
        }
        let before: u64 = watcher.wakes() + panes.iter().map(Client::wakes).sum::<u64>();
        let sessions: Vec<_> = (0..SESSIONS).map(|i| session(&hub, &sid(i))).collect();
        let (cpu, wall) = (cpu_now(), Instant::now());
        for k in 0..EVENTS {
            let at = (k * 7_919 + 13) % SESSIONS;
            if k % 10 == 0 {
                hub.append(&sessions[at], "mux", "titled", json!({"title": format!("t{k}")}));
            } else {
                hub.append(&sessions[at], "in", "agent_message_chunk", chunk(&sid(at), "w "));
            }
        }
        for (i, pane_session) in sessions.iter().enumerate().take(connections).skip(1) {
            hub.append(pane_session, "in", "agent_message_chunk", chunk(&sid(i), "cost-end"));
        }
        hub.append(&sessions[0], "mux", "renamed", json!({"name": "cost-end"}));
        watcher.until("\"recordKind\":\"renamed\"").await;
        for pane in &mut panes {
            pane.until("cost-end").await;
        }
        let (cpu, wall) = (cpu_now() - cpu, wall.elapsed());
        let woke: u64 = watcher.wakes() + panes.iter().map(Client::wakes).sum::<u64>() - before;
        let sent = (EVENTS + connections) as f64;
        eprintln!(
            "FANOUT-WAKE connections {connections} sessions {SESSIONS} events {EVENTS} \
             wakes/event {:.2} cpu_us/event {:.1} wall_us/event {:.1}",
            woke as f64 / sent,
            cpu.as_secs_f64() * 1e6 / sent,
            wall.as_secs_f64() * 1e6 / sent,
        );
    }
}
