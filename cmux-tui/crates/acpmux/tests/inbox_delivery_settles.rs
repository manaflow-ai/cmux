//! A message the receiver's inbox took ends its `session/prompt` request once it is delivered
//! (`hub/inbox.rs`), and no request of it stays open in the daemon.
//!
//! On 2026-11-19 every `acpmux send --no-wait <coordinator>` that the coordinator's inbox held
//! left its delivery's `session/prompt` open until a notice carried it, which for a held message
//! is a flush ten minutes on or never: the daemon grew 160 MB per 1000 sends (93 MB to 657 MB
//! over 4000) and its CPU per round grew sevenfold, and the live heap was those requests'
//! futures. A coordinator takes thousands of lane reports an hour.
//!
//! A caller that reads the reply (`readsReply`, `acpmux send` that waits) still waits for the
//! notice's answer, but only while its connection is open: its request ends with its client.

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, HarnessProfile, PermissionPolicy, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::{Message, method};
use acpmux::server::{Origin, serve_connection, serve_connection_with};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const SEND_QUEUE: &str = "_acpmux/send_queue";
const SEND_STATUS: &str = "_acpmux/send_status";

fn hub() -> Arc<Hub> {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut agents = BTreeMap::new();
    agents.insert(
        "fake".to_owned(),
        HarnessProfile {
            kind: Default::default(),
            argv: vec!["python3".into(), fake.into()],
            env: BTreeMap::new(),
            description: None,
            fallback: None,
            family: None,
            models: vec![],
            model: None,
            effort: None,
            policy: None,
        },
    );
    let mut cfg =
        Config { harnesses: agents, default_harness: Some("fake".into()), ..Default::default() };
    cfg.store.mode = StoreMode::Memory;
    cfg.permission_policy = PermissionPolicy::ApproveAll;
    let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

struct C {
    tx: mpsc::Sender<String>,
    rx: mpsc::Receiver<String>,
    next: i64,
}

impl C {
    async fn person(h: Arc<Hub>) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(h, in_rx, out_tx, Origin::Local));
        let mut c = C { tx: in_tx, rx: out_rx, next: 0 };
        c.call(method::INITIALIZE, json!({"protocolVersion": 1, "clientInfo": {"name": "t"}}))
            .await
            .unwrap();
        c
    }

    /// The connection a session's own tools open: `initialize` with its caller token.
    async fn as_session(h: Arc<Hub>, id: &str) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection(h, in_rx, out_tx));
        let mut c = C { tx: in_tx, rx: out_rx, next: 0 };
        let token = acpmux::hub::person::caller_token(id);
        c.call(
            method::INITIALIZE,
            json!({"protocolVersion": 1,
                   "_meta": {"acpmux": {"callerSession": {"sessionId": id, "token": token}}}}),
        )
        .await
        .unwrap();
        c
    }

    async fn send(&mut self, m: &str, p: Value) -> i64 {
        self.next += 1;
        self.tx.send(Message::request(self.next, m, p).to_line()).await.unwrap();
        self.next
    }

    async fn response(&mut self, id: i64, within: Duration) -> Option<Result<Value, String>> {
        let deadline = tokio::time::Instant::now() + within;
        loop {
            let line = tokio::time::timeout_at(deadline, self.rx.recv()).await.ok()??;
            if let Ok(Message::Response { id: rid, result, error }) = Message::parse(&line)
                && rid == id
            {
                return Some(match error {
                    Some(e) => Err(e.message),
                    None => Ok(result.unwrap_or(Value::Null)),
                });
            }
        }
    }

    async fn call(&mut self, m: &str, p: Value) -> Result<Value, String> {
        let id = self.send(m, p).await;
        self.response(id, Duration::from_secs(30)).await.expect("an answer within 30 s")
    }

    async fn notified(&mut self, m: &str, within: Duration, pred: impl Fn(&Value) -> bool) -> bool {
        let deadline = tokio::time::Instant::now() + within;
        loop {
            let Ok(Some(line)) = tokio::time::timeout_at(deadline, self.rx.recv()).await else {
                return false;
            };
            if let Ok(Message::Notification { method: got, params }) = Message::parse(&line)
                && got == m
                && pred(&params.unwrap_or(Value::Null))
            {
                return true;
            }
        }
    }
}

fn prompt(session: &str, text: &str, prompt_id: &str) -> Value {
    json!({
        "sessionId": session,
        "prompt": [{"type": "text", "text": text}],
        "_meta": {"acpmux": {"promptId": prompt_id}},
    })
}

/// A sending session and a receiver that ran a turn: another agent's result to it goes to its
/// inbox and is held there (it neither wakes the idle chat nor is due), as a coordinator's lane
/// reports from sessions that did not start it are.
async fn held_inbox(h: &Arc<Hub>) -> (C, String, String) {
    let mut person = C::person(h.clone()).await;
    let new = |name: &str| json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"harness": "fake", "name": name}}});
    let sender = person.call(method::SESSION_NEW, new("lane")).await.unwrap()["sessionId"]
        .as_str()
        .unwrap()
        .to_owned();
    let receiver = person.call(method::SESSION_NEW, new("coordinator")).await.unwrap()["sessionId"]
        .as_str()
        .unwrap()
        .to_owned();
    person.call(method::SESSION_PROMPT, prompt(&receiver, "hello", "p-hello")).await.unwrap();
    (person, sender, receiver)
}

/// Requests open in the hub, once they settle (at most `within`): what `baseline` it comes back to.
async fn in_flight_settles(h: &Hub, baseline: usize, within: Duration) -> usize {
    let deadline = tokio::time::Instant::now() + within;
    while h.requests_in_flight() > baseline && tokio::time::Instant::now() < deadline {
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    h.requests_in_flight()
}

/// This process's resident memory, in KiB (Linux).
fn rss_kib() -> Option<u64> {
    let status = std::fs::read_to_string("/proc/self/status").ok()?;
    let line = status.lines().find(|l| l.starts_with("VmRSS:"))?;
    line.split_whitespace().nth(1)?.parse().ok()
}

/// `N` outbox deliveries (`send --no-wait`) into a held inbox: every one is delivered, and the
/// requests they sent end with that, so the hub's open requests come back to what they were and
/// the memory held per send stays small.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn no_wait_sends_into_a_held_inbox_leave_no_request_open() {
    let n: usize = std::env::var("ACPMUX_INBOX_SETTLE_SENDS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(2000);
    let h = hub();
    let (_person, _sender, receiver) = held_inbox(&h).await;
    // As `acpmux send --from lane-N --no-wait` from a shell: many lanes, each its own words
    // (one sender's near-identical messages in a row would pause the pair, `agent_pairs.rs`).
    let mut lane = C::person(h.clone()).await;
    let baseline = in_flight_settles(&h, 0, Duration::from_secs(5)).await;
    // A first round warms up what a daemon allocates once (pools, maps, the outbox's file).
    let warm = 50;
    let send_round = async |lane: &mut C, from: usize, to: usize| {
        let mut ids = vec![];
        for i in from..to {
            let words = ["tests pass", "CI is red on lint", "review asked for a rename", "merged"];
            let text = format!("report {i}: {}, PR #{}", words[i % words.len()], 1000 + i % 97);
            let mut request = prompt(&receiver, &text, &format!("p-{i}"));
            request["_meta"]["acpmux"]["fromAgent"] = json!(format!("lane-{:03}", i % 64));
            let queued = lane.call(SEND_QUEUE, json!({"request": request})).await.unwrap();
            ids.push(queued["deliveryId"].as_str().unwrap().to_owned());
        }
        for id in ids {
            let status =
                lane.call(SEND_STATUS, json!({"deliveryId": id, "waitMs": 10000})).await.unwrap();
            assert_eq!(status["status"], "delivered", "{status}");
        }
    };
    send_round(&mut lane, 0, warm).await;
    let rss0 = rss_kib();
    send_round(&mut lane, warm, warm + n).await;
    let open = in_flight_settles(&h, baseline, Duration::from_secs(10)).await;
    assert!(
        open <= baseline,
        "{open} requests still open after {n} delivered sends (baseline {baseline}): a delivered \
         message's session/prompt waits on in the daemon"
    );
    // Each kept message holds its inbox item and log record; an open request held ~110 KB more.
    if let (Some(before), Some(after)) = (rss0, rss_kib()) {
        let per_send = after.saturating_sub(before) as f64 / n as f64;
        assert!(
            per_send < 48.0,
            "{per_send:.1} KiB of RSS per delivered send ({before} -> {after} KiB)"
        );
    }
    let info = lane.call(method::MUX_INFO, json!({"sessionId": receiver})).await.unwrap();
    assert_eq!(info["status"], "ready", "held messages started no turn: {info}");
}

/// A sender that waits for the reply (`readsReply`) still waits while it is connected, and its
/// request ends with its connection: the daemon never waits on for it.
#[tokio::test]
async fn a_waiting_senders_request_ends_with_its_connection() {
    let h = hub();
    let (_person, sender, receiver) = held_inbox(&h).await;
    let baseline = in_flight_settles(&h, 0, Duration::from_secs(5)).await;
    let mut lane = C::as_session(h.clone(), &sender).await;
    let mut request = prompt(&receiver, "tests pass", "p-wait");
    request["_meta"]["acpmux"]["readsReply"] = json!(true);
    let id = lane.send(method::SESSION_PROMPT, request).await;
    assert!(
        lane.notified(method::MUX_PROMPT_ACCEPTED, Duration::from_secs(10), |p| {
            p["promptId"] == "p-wait" && p["inbox"] == true
        })
        .await,
        "the inbox took it"
    );
    // Connected, it waits for the notice's answer, which a held message does not have yet.
    assert!(lane.response(id, Duration::from_millis(500)).await.is_none(), "it still waits");
    assert_eq!(h.requests_in_flight(), baseline + 1);
    drop(lane);
    let open = in_flight_settles(&h, baseline, Duration::from_secs(10)).await;
    assert_eq!(open, baseline, "the waiting send's request outlived its connection");
}

/// A waiting sender whose message wakes the receiver (a question) still gets that turn's answer.
#[tokio::test]
async fn a_waiting_sender_still_reads_the_turn_that_answers() {
    let h = hub();
    let (_person, sender, receiver) = held_inbox(&h).await;
    let mut lane = C::as_session(h.clone(), &sender).await;
    let mut request = prompt(&receiver, "which branch?", "p-ask");
    request["_meta"]["acpmux"]["readsReply"] = json!(true);
    request["_meta"]["acpmux"]["class"] = json!("question");
    let id = lane.send(method::SESSION_PROMPT, request).await;
    let answer = lane.response(id, Duration::from_secs(30)).await.expect("answered").unwrap();
    assert_eq!(answer["stopReason"], "end_turn", "{answer}");
    assert_eq!(answer["_meta"]["acpmux"]["inbox"], true, "{answer}");
}
