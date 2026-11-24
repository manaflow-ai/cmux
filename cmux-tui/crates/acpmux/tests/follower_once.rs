//! A client that follows a chat's live stream (`_acpmux/attach` with `eventStream: true`, as
//! the NEXT chat pane and the iPhone app attach) gets each agent update once, in order, while
//! other clients open, read and leave the same chat beside it. coord-sim (cmux#47266) measured
//! 1,726 of 37,689 agent updates (3 coordinators) and 7,046 of 251,260 (20) arriving twice or
//! more at such followers, a plan update up to 84 times, with no copy in the store.
#![cfg(unix)]

use crate::HERMETIC;
use crate::daemon_env;

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::Message;
use acpmux::server::{Origin, serve_connection_with};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
/// The kinds coord-sim's follower asks for (`coord-sim/src/drive/readers.rs`).
const FOLLOW_KINDS: &[&str] = &[
    "transcript",
    "usage_update",
    "available_commands_update",
    "current_mode_update",
    "config_option_update",
];
const ROUNDS: usize = 150;

fn hub(work: &Path, mode: StoreMode) -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE]}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all",
        "webRoots": [work],
        "autoResumeDelaysMs": [],
    }))
    .unwrap();
    cfg.path = Some(work.join("config.json"));
    let store_dir = work.join("store");
    std::fs::create_dir_all(&store_dir).unwrap();
    cfg.store.mode = mode;
    let store = acpmux::store::open(&cfg.store, &store_dir).unwrap();
    Hub::new(cfg, store)
}

struct Client {
    tx: mpsc::Sender<String>,
    rx: mpsc::Receiver<String>,
    next: i64,
}

impl Client {
    fn new(hub: &Arc<Hub>) -> Self {
        let (tx, in_rx) = mpsc::channel(64);
        let (out_tx, rx) = mpsc::channel(1 << 16);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));
        Self { tx, rx, next: 0 }
    }

    /// The reply to one call; `notes` gets every other line read before it.
    async fn call(&mut self, method: &str, params: Value, notes: &mut Vec<String>) -> Value {
        self.next += 1;
        let id = self.next;
        self.tx.send(Message::request(id, method, params).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(60), self.rx.recv())
                .await
                .unwrap_or_else(|_| panic!("{method}: no reply"))
                .expect("connection closed");
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) && v.get("method").is_none() {
                assert!(v.get("error").is_none(), "{method} failed: {v}");
                return v["result"].clone();
            }
            notes.push(line);
        }
    }
}

/// Each `[[t:ROUND:KIND]]` tag in `line`, once.
fn tags(line: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    let mut rest = line;
    while let Some(i) = rest.find("[[t:") {
        rest = &rest[i..];
        let Some(end) = rest.find("]]") else { break };
        let tag = rest[..end + 2].to_owned();
        if !out.contains(&tag) {
            out.push(tag);
        }
        rest = &rest[end + 2..];
    }
    out
}

/// What a notification line is, for the failure message.
fn what(line: &str) -> String {
    let v: Value = serde_json::from_str(line).unwrap_or(Value::Null);
    let method = v["method"].as_str().unwrap_or("?");
    let kind = v["params"]["kind"]
        .as_str()
        .or_else(|| v["params"]["update"]["sessionUpdate"].as_str())
        .unwrap_or("");
    let seq = v["params"]["seq"].as_u64().map(|s| format!(" seq {s}")).unwrap_or_default();
    format!("{method} {kind}{seq}")
}

async fn follower_hears_each_update_once(mode: StoreMode, tag: &str) {
    let _ = HERMETIC;
    let scratch = daemon_env::Scratch::new(tag);
    let work = std::fs::canonicalize(scratch.path()).unwrap();
    let hub = hub(&work, mode);
    let mut control = Client::new(&hub);
    let mut ignored = Vec::new();
    let created =
        control.call("session/new", json!({"cwd": work, "mcpServers": []}), &mut ignored).await;
    let sid = created["sessionId"].as_str().expect("sessionId").to_owned();

    // The follower: attached once, for the whole turn, as coord-sim's.
    let mut follower = Client::new(&hub);
    let mut heard = Vec::new();
    follower
        .call(
            "_acpmux/attach",
            json!({"sessionId": sid, "waitLogs": false, "limit": 400, "maxBytes": 128 * 1024,
                "kinds": FOLLOW_KINDS, "eventStream": true, "visible": true}),
            &mut heard,
        )
        .await;
    let heard = Arc::new(Mutex::new(heard));
    let sink = heard.clone();
    let mut follower_rx = follower.rx;
    let drain = tokio::spawn(async move {
        while let Some(line) = follower_rx.recv().await {
            sink.lock().unwrap().push(line);
        }
    });

    // Other clients open the chat, read older pages and leave, over and over, as coord-sim's
    // switching readers (and the app's chat switcher) do.
    let stop = Arc::new(AtomicBool::new(false));
    let mut switchers = Vec::new();
    for _ in 0..2 {
        let (hub, sid, stop) = (hub.clone(), sid.clone(), stop.clone());
        switchers.push(tokio::spawn(async move {
            let mut c = Client::new(&hub);
            let mut notes = Vec::new();
            let mut opens = 0u32;
            while !stop.load(Ordering::SeqCst) {
                let page = c
                    .call(
                        "_acpmux/attach",
                        json!({"sessionId": sid, "waitLogs": false, "limit": 400,
                            "maxBytes": 128 * 1024, "kinds": ["transcript"],
                            "eventStream": true, "visible": true}),
                        &mut notes,
                    )
                    .await;
                if let Some(first) = page["events"].get(0).and_then(|e| e["seq"].as_u64()) {
                    c.call(
                        "_acpmux/events",
                        json!({"sessionId": sid, "beforeSeq": first, "limit": 2000,
                            "maxBytes": 1 << 20, "kinds": ["transcript"]}),
                        &mut notes,
                    )
                    .await;
                }
                c.call("_acpmux/detach", json!({"sessionId": sid}), &mut notes).await;
                notes.clear();
                opens += 1;
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
            opens
        }));
    }

    let prompt = json!({"sessionId": sid, "prompt": [{"type": "text", "text": format!("tagged:{ROUNDS}:10")}]});
    let reply = control.call("session/prompt", prompt, &mut ignored).await;
    assert_eq!(reply["stopReason"], "end_turn", "{reply}");
    tokio::time::sleep(Duration::from_millis(500)).await;
    stop.store(true, Ordering::SeqCst);
    let mut opens = 0;
    for s in switchers {
        opens += s.await.unwrap();
    }
    drain.abort();
    assert!(opens > 10, "the other clients opened the chat only {opens} times");

    let lines = heard.lock().unwrap().clone();
    let mut by_tag: BTreeMap<String, Vec<String>> = BTreeMap::new();
    let mut order: Vec<String> = Vec::new();
    // Only the stream's own frames: a chat's row (`_acpmux/session_changed`) quotes its newest
    // reply, tool and plan step, and is not a second copy of the update.
    for line in lines.iter().filter(|l| l.contains(r#""method":"_acpmux/event""#)) {
        for t in tags(line) {
            let seen = by_tag.entry(t.clone()).or_default();
            if seen.is_empty() {
                order.push(t.clone());
            }
            seen.push(what(line));
        }
    }
    // Every agent update a transcript stream carries (the thought, the tool call's end and the
    // plan included) reaches the follower exactly once.
    let mut expected = Vec::new();
    for i in 0..ROUNDS {
        for k in ["m", "th", "tc", "tu", "p"] {
            expected.push(format!("[[t:{i}:{k}]]"));
        }
    }
    let missing: Vec<&String> = expected.iter().filter(|t| !by_tag.contains_key(*t)).collect();
    let twice: Vec<String> = by_tag
        .iter()
        .filter(|(_, w)| w.len() > 1)
        .map(|(t, w)| format!("{t} x{}: {}", w.len(), w.join(" | ")))
        .collect();
    assert!(
        twice.is_empty(),
        "{} of {} updates reached the follower more than once ({} lines, {opens} opens beside it):\n{}",
        twice.len(),
        expected.len(),
        lines.len(),
        twice.iter().take(40).cloned().collect::<Vec<_>>().join("\n")
    );
    assert!(missing.is_empty(), "never reached the follower: {missing:?}");
    assert_eq!(order, expected, "the follower heard the updates out of order");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_follower_hears_each_update_once_while_others_open_the_chat_on_disk() {
    follower_hears_each_update_once(StoreMode::Local, "follower-once-disk").await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_follower_hears_each_update_once_while_others_open_the_chat_in_memory() {
    follower_hears_each_update_once(StoreMode::Memory, "follower-once-mem").await;
}
