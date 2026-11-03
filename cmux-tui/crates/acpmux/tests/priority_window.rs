//! rust-migration A6: acpmux owns the sidebar's Priority view. A client opens a window over the
//! sessions' lanes (`_acpmux/priority_window`) and gets its rows ranked by acpmux; each lane change
//! then reaches it as a row diff with the next revision (`_acpmux/priority_window_changed`), and
//! a mark (`_acpmux/priority_mark`) changes the rows at once. The Mac app ranked every lane on its
//! main thread at each change until now.
//!
//! Stand-in agents (fake_agent.py) in an in-memory store.

#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::Message;
use acpmux::server::{Origin, serve_connection_with};
use serde_json::{Value, json};
use std::collections::VecDeque;
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
const CHANGED: &str = "_acpmux/priority_window_changed";

fn hub() -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE]}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

/// The connection, the last request id, and the notifications read while waiting for an answer.
struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64, VecDeque<Value>);

fn client(hub: &Arc<Hub>, origin: Origin) -> Client {
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, origin));
    Client(in_tx, out_rx, 0, VecDeque::new())
}

impl Client {
    async fn next(&mut self) -> Value {
        if let Some(v) = self.3.pop_front() {
            return v;
        }
        let line = tokio::time::timeout(Duration::from_secs(30), self.1.recv())
            .await
            .expect("a message within 30 s")
            .expect("connection open");
        serde_json::from_str(&line).unwrap()
    }

    /// The whole reply to `m`; the notifications that came first stay queued, in order.
    async fn call(&mut self, m: &str, params: Value) -> Value {
        self.2 += 1;
        let id = self.2;
        self.0.send(Message::request(id, m, params).to_line()).await.unwrap();
        let mut held = VecDeque::new();
        loop {
            let v = self.next().await;
            if v.get("id") == Some(&json!(id)) {
                held.extend(self.3.drain(..));
                self.3 = held;
                return v;
            }
            held.push_back(v);
        }
    }

    async fn ok(&mut self, m: &str, params: Value) -> Value {
        let v = self.call(m, params).await;
        assert!(v.get("error").is_none(), "{m}: {v}");
        v["result"].clone()
    }

    /// The next window message that `done` accepts; the ones before it are dropped.
    async fn window_until(&mut self, done: impl Fn(&Value) -> bool) -> Value {
        loop {
            let v = self.next().await;
            if v["method"] == CHANGED && done(&v["params"]) {
                return v["params"].clone();
            }
        }
    }
}

fn keys(message: &Value) -> Vec<String> {
    message["keys"].as_array().unwrap().iter().map(|k| k.as_str().unwrap().to_owned()).collect()
}

fn row<'a>(message: &'a Value, id: &str) -> Option<&'a Value> {
    message["rows"].as_array().unwrap().iter().find(|row| row["id"] == id)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_priority_window_hears_a_lane_change_as_a_row_diff_and_a_mark_at_once() {
    let hub = hub();
    let mut sidebar = client(&hub, Origin::Local);
    let mut agent = client(&hub, Origin::Local);

    // A chat another owner reports (the Chief home's acpmux): ranked with this daemon's lanes.
    let chief = json!({"sessionId": "chief-sub", "name": "chief-sub",
                       "lane": {"state": "input", "since": 1_000}});
    let ack = sidebar.ok("_acpmux/priority_window", json!({"window": "p", "lanes": [chief]})).await;
    assert_eq!(ack, json!({"window": "p", "ready": true}));
    let full = sidebar.window_until(|_| true).await;
    assert_eq!(full["full"], true);
    assert_eq!(full["revision"], 1);
    assert_eq!(keys(&full), ["chief-sub"]);
    assert_eq!(full["needingInput"], json!(["chief-sub"]));

    // A new chat here, and a turn on it: the window hears of it with no new request.
    let params = json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {}}});
    let id = agent.ok("session/new", params).await["sessionId"].as_str().unwrap().to_owned();
    let prompt = json!({"sessionId": id, "prompt": [{"type": "text", "text": "hello"}]});
    agent.ok("session/prompt", prompt).await;
    let diff = sidebar.window_until(|m| keys(m).contains(&id)).await;
    assert_eq!(diff["full"], false);
    assert!(diff["revision"].as_u64().unwrap() > 1);
    assert_eq!(keys(&diff)[0], "chief-sub", "a question outranks a chat here: {diff}");
    // Only rows whose value changed are sent: the Chief home's row was sent already.
    assert!(row(&diff, "chief-sub").is_none(), "{diff}");

    // The person pins the chat here: only its row is sent again, and the reply carries the marks.
    // A pin leads its tier only; the question stays on top.
    let pin = json!({"window": "p", "op": "pin", "id": id});
    let marked = sidebar.ok("_acpmux/priority_mark", pin).await;
    assert_eq!(marked["marks"]["pinned"], json!([id]));
    let pinned = sidebar.window_until(|m| row(m, &id).is_some_and(|r| r["pinned"] == true)).await;
    assert_eq!(keys(&pinned), ["chief-sub".to_owned(), id.clone()], "{pinned}");
    assert_eq!(pinned["rows"].as_array().map(Vec::len), Some(1), "{pinned}");
    // The person drags it to the top: it stays there.
    let order = json!([id, "chief-sub"]);
    let place = json!({"window": "p", "op": "place", "id": id, "order": order});
    sidebar.ok("_acpmux/priority_mark", place).await;
    let placed = sidebar.window_until(|m| keys(m).first() == Some(&id)).await;
    assert_eq!(keys(&placed), [id.clone(), "chief-sub".to_owned()], "{placed}");
    let next = sidebar.ok("_acpmux/priority_next", json!({"window": "p"})).await;
    assert_eq!(next["id"], "chief-sub", "only a chat that asks is a stop");

    // A mark on a chat no owner lists is refused; an older spec of the window is stale.
    let refused = sidebar
        .call("_acpmux/priority_mark", json!({"window": "p", "op": "read", "id": "x"}))
        .await;
    assert!(refused.get("error").is_some(), "{refused}");
    sidebar.ok("_acpmux/priority_window", json!({"window": "p", "gen": 2})).await;
    let stale = sidebar.ok("_acpmux/priority_window", json!({"window": "p", "gen": 1})).await;
    assert_eq!(stale["stale"], true);
    let closed = sidebar.ok("_acpmux/priority_window_close", json!({"window": "p"})).await;
    assert_eq!(closed["closed"], true);

    // Served on the local socket only: a WebSocket client gets no window.
    let mut web = client(&hub, Origin::Web);
    let refused = web.call("_acpmux/priority_window", json!({"window": "w"})).await;
    assert!(
        refused["error"]["message"].as_str().is_some_and(|m| m.contains("local unix socket")),
        "{refused}"
    );
}

/// The marks are the daemon's, one copy: a mark through one connection's window shows in
/// another connection's window, and a snooze ends by the clock alone, with no other change.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_mark_shows_in_every_window_and_a_snooze_ends_by_the_clock() {
    let hub = hub();
    let mut one = client(&hub, Origin::Local);
    let mut two = client(&hub, Origin::Local);
    let asks =
        json!({"sessionId": "asks", "name": "asks", "lane": {"state": "input", "since": 1_000}});
    let spec = json!({"window": "p", "lanes": [asks]});
    one.ok("_acpmux/priority_window", spec.clone()).await;
    two.ok("_acpmux/priority_window", spec).await;
    assert_eq!(keys(&one.window_until(|_| true).await), ["asks"]);
    assert_eq!(keys(&two.window_until(|_| true).await), ["asks"]);

    // A snooze of 3 s through the first window: both windows drop the row (each has time to see
    // it before it ends, however slow the runner).
    let snooze = json!({"window": "p", "op": "snooze", "id": "asks", "durationMs": 3_000});
    let marked = one.ok("_acpmux/priority_mark", snooze).await;
    assert!(marked["marks"]["snoozed"]["asks"]["untilMs"].is_i64(), "{marked}");
    let hidden = two.window_until(|m| keys(m).is_empty()).await;
    assert_eq!(hidden["needingInput"], json!([]));
    assert!(hidden["nextChangeMs"].is_i64(), "the window says when it wakes: {hidden}");
    one.window_until(|m| keys(m).is_empty()).await;

    // Nothing else happens: the clock brings the row back to both.
    let back = two.window_until(|m| keys(m) == ["asks"]).await;
    assert_eq!(back["needingInput"], json!(["asks"]));
    one.window_until(|m| keys(m) == ["asks"]).await;
}

/// A mark through one connection shows in another connection's window while this daemon's
/// sessions keep writing records that change no lane (a tag here; usage, tools and git records
/// in a working daemon). Such a record arriving in the same turn as the mark must not swallow it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_mark_shows_in_another_window_while_records_that_change_no_lane_arrive() {
    let hub = hub();
    let mut agent = client(&hub, Origin::Local);
    let params = json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {}}});
    let id = agent.ok("session/new", params).await["sessionId"].as_str().unwrap().to_owned();
    let mut one = client(&hub, Origin::Local);
    let mut two = client(&hub, Origin::Local);
    one.ok("_acpmux/priority_window", json!({"window": "p"})).await;
    two.ok("_acpmux/priority_window", json!({"window": "p"})).await;
    one.window_until(|m| keys(m).contains(&id)).await;
    two.window_until(|m| keys(m).contains(&id)).await;

    // Tags that change no lane, back to back from four connections, while the first connection
    // pins and unpins the chat twenty times: each mark must reach the second window.
    let stop = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let writers: Vec<_> = (0..4)
        .map(|w| {
            let (id, stop, mut writer) = (id.clone(), stop.clone(), client(&hub, Origin::Local));
            tokio::spawn(async move {
                let mut n = 0u64;
                while !stop.load(std::sync::atomic::Ordering::Relaxed) {
                    n += 1;
                    let tag = json!({"sessionId": id, "set": {format!("priority-test-{w}"): n.to_string()}});
                    writer.ok("_acpmux/tag", tag).await;
                }
            })
        })
        .collect();
    tokio::time::sleep(Duration::from_millis(50)).await;
    for round in 0..20 {
        let pinned = round % 2 == 0;
        one.ok("_acpmux/priority_mark", json!({"window": "p", "op": "pin", "id": id})).await;
        two.window_until(|m| row(m, &id).is_some_and(|r| r["pinned"] == pinned)).await;
    }
    stop.store(true, std::sync::atomic::Ordering::Relaxed);
    for writer in writers {
        writer.await.unwrap();
    }
}
