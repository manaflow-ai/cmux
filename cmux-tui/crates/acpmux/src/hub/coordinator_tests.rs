//! A coordinator's inbox (`coordinator.rs`) against the fake agent steering as Claude Code does:
//! a prompt while a turn runs is read into it at once, and a gated turn runs on until the test
//! opens its gate.

use super::*;
use crate::prompt_class::PromptClass as Class;
use std::sync::atomic::Ordering;
use std::time::Duration;
use tokio::sync::oneshot;

const WAIT: Duration = Duration::from_secs(20);

struct Fixture {
    hub: Arc<Hub>,
    session: Arc<Session>,
    events: tokio::sync::broadcast::Receiver<HubEvent>,
    dir: std::path::PathBuf,
}

type Task = tokio::task::JoinHandle<Result<Value, RpcError>>;

/// A coordinator session (its default 20-minute turn cap) on a steering fake agent.
async fn fixture() -> Fixture {
    use crate::config::{Config, StoreMode};
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["/usr/bin/env", "FAKE_CLAUDE_STEER=1", "python3", fake]}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let dir = std::env::temp_dir().join(format!("acpmux-coordinator-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&dir).unwrap();
    let session = hub
        .new_session(NewRequest { cwd: Some(std::env::temp_dir()), ..Default::default() })
        .await
        .unwrap();
    hub.set_coordinator(&session, Some(true), None, None);
    let events = hub.subscribe();
    Fixture { hub, session, events, dir }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

impl Fixture {
    /// Waits for the agent to stream `text` in this session.
    async fn heard(&mut self, text: &str) {
        let id = self.session.id.clone();
        let events = &mut self.events;
        tokio::time::timeout(WAIT, async {
            loop {
                let event = events.recv().await.unwrap();
                if event.session_id == id
                    && event.record.msg["params"]["update"]["content"]["text"] == text
                {
                    return;
                }
            }
        })
        .await
        .unwrap_or_else(|_| panic!("the agent never said {text:?}"));
    }

    /// Starts a turn of the person's that runs until [`Fixture::open`] opens gate `name`.
    async fn gated_turn(&mut self, name: &str) -> Task {
        let fifo = self.dir.join(name);
        let path = std::ffi::CString::new(fifo.to_str().unwrap()).unwrap();
        assert_eq!(unsafe { libc::mkfifo(path.as_ptr(), 0o600) }, 0);
        let (hub, session) = (self.hub.clone(), self.session.clone());
        let text = format!("gate: {}", fifo.display());
        let turn = tokio::spawn(async move {
            hub.prompt(&session, vec![json!({"type": "text", "text": text})], "test", false).await
        });
        self.heard("before-gate").await;
        turn
    }

    /// Opens gate `name`: its turn ends.
    async fn open(&self, name: &str) {
        let fifo = self.dir.join(name);
        tokio::task::spawn_blocking(move || std::fs::write(fifo, b"go")).await.unwrap().unwrap();
    }

    /// Sends `text` as `prompt_id`, from agent `from` with `class` or (`None`) the person, as a
    /// steer when `steer`; answers with its acceptance and its task.
    async fn send(
        &self,
        prompt_id: &str,
        text: &str,
        from: Option<&str>,
        class: Option<Class>,
        steer: bool,
    ) -> (Value, Task) {
        let (tx, rx) = oneshot::channel();
        let opts = PromptOptions {
            prompt_id: Some(prompt_id.to_owned()),
            agent: from.map(str::to_owned),
            class,
            on_accepted: Some(Box::new(move |v| {
                let _ = tx.send(v);
            })),
            ..PromptOptions::default()
        };
        let (hub, session) = (self.hub.clone(), self.session.clone());
        let blocks = vec![json!({"type": "text", "text": text})];
        let task =
            tokio::spawn(
                async move { hub.prompt_with(&session, blocks, "test", steer, opts).await },
            );
        let accepted = tokio::time::timeout(WAIT, rx).await.expect("accepted in time");
        (accepted.expect("accepted, not refused"), task)
    }

    /// The session's `user_message` records.
    fn prompts(&self) -> Vec<Value> {
        let records = self.hub.events(&self.session.id, 0, 100_000).unwrap();
        records.into_iter().filter(|r| r.kind == "user_message").map(|r| r.msg).collect()
    }

    /// The `user_message` records of inbox digests.
    fn digests(&self) -> Vec<Value> {
        let kind = |m: &Value| {
            m["_meta"]["provenance"]["kind"] == super::super::digest::inbox_digest::KIND
        };
        self.prompts().into_iter().filter(kind).collect()
    }

    /// Waits until `done` holds.
    async fn until(&self, what: &str, done: impl Fn(&Self) -> bool) {
        let deadline = tokio::time::Instant::now() + WAIT;
        while !done(self) {
            assert!(tokio::time::Instant::now() < deadline, "never: {what}");
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    }

    /// Waits until the chat is idle with nothing queued.
    async fn settled(&self) {
        self.until("idle with an empty queue", |f| {
            f.session.turn().is_none() && f.session.queue().is_empty()
        })
        .await;
    }

    fn timer_armed(&self) -> bool {
        self.session.inbox_timer.lock().unwrap().is_some()
    }

    /// Makes the running turn `ms` old, plus one.
    fn age_turn(&self, ms: u64) {
        let mut turn = self.session.turn.lock().unwrap();
        let turn = turn.as_mut().expect("a running turn");
        turn.started_at = turn.started_at.saturating_sub(ms + 1);
    }
}

/// The prompt ids a digest's provenance lists, in its order.
fn parts(digest: &Value) -> Vec<String> {
    let parts = digest["_meta"]["provenance"]["parts"].as_array().unwrap();
    parts.iter().map(|p| p["promptId"].as_str().unwrap().to_owned()).collect()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_idle_coordinator_is_not_woken_by_a_result_or_an_fyi_but_is_by_a_block() {
    let f = fixture().await;
    let (result, result_task) = f.send("p-r", "merged #1", Some("lane-a"), None, true).await;
    assert_eq!(result["queued"], true, "{result}");
    let (fyi, _) = f.send("p-f", "fyi: CI is slow", Some("lane-b"), Some(Class::Fyi), true).await;
    assert_eq!(fyi["queued"], true, "{fyi}");
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert!(f.prompts().is_empty(), "no turn: {:?}", f.prompts());
    assert!(f.session.turn().is_none());
    assert_eq!(f.session.inbox_len(), 2);
    assert!(f.timer_armed(), "the flush timer waits for them");
    // Each row says it waits in the inbox, and the queue still counts it.
    let rows = f.hub.session_summary(&f.session)["queue"].clone();
    let inbox: Vec<_> = rows.as_array().unwrap().iter().map(|q| q["inbox"].clone()).collect();
    assert_eq!(inbox, [json!(true), json!(true)], "{rows}");

    // A block wakes it: one digest turn takes all three, listed as they came.
    let (block, _) =
        f.send("p-b", "blocked on review", Some("lane-c"), Some(Class::Block), true).await;
    assert_eq!(block["queued"], true, "{block}");
    f.until("a digest turn", |f| !f.digests().is_empty()).await;
    f.settled().await;
    let prompts = f.prompts();
    assert_eq!(prompts.len(), 1, "one turn: {prompts:?}");
    assert_eq!(parts(&prompts[0]), ["p-r", "p-f", "p-b"]);
    // Each original answers with the digest's turn.
    let answer = tokio::time::timeout(WAIT, result_task).await.unwrap().unwrap().unwrap();
    assert_eq!(answer["_meta"]["acpmux"]["turnId"], prompts[0]["turnId"], "{answer}");
    assert!(!f.timer_armed(), "an empty inbox arms no timer");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_question_wakes_an_idle_coordinator_too() {
    let f = fixture().await;
    f.send("p-q", "which branch?", Some("lane-a"), Some(Class::Question), true).await;
    f.until("a digest turn", |f| f.digests().len() == 1).await;
    f.settled().await;
    assert_eq!(parts(&f.digests()[0]), ["p-q"]);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn one_digest_per_turn_end_and_the_persons_prompt_is_never_an_inbox_item() {
    let mut f = fixture().await;
    let turn = f.gated_turn("g").await;
    let mut tasks = Vec::new();
    for i in 0..50 {
        let (accepted, task) = f
            .send(&format!("p-{i}"), &format!("result {i}"), Some(&format!("lane-{i}")), None, true)
            .await;
        assert_eq!(accepted["queued"], true, "{accepted}");
        assert_ne!(accepted["steer"], true, "an inbox item never steers in: {accepted}");
        tasks.push(task);
    }
    // The person's own prompt waits as a prompt of theirs, ahead of the inbox.
    let (mine, mine_task) = f.send("p-me", "the person's", None, None, false).await;
    assert_eq!(mine["queued"], true, "{mine}");
    assert_eq!(f.session.inbox_len(), 50);
    let queue = f.session.queue();
    assert_eq!(queue[0].prompt_id, "p-me");
    assert!(!queue[0].inbox);
    // No digest steers in under the interval (the turn just started).
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert!(f.digests().is_empty());

    // The turn ran past its cap: its end brings ONE digest, after the person's prompt.
    f.age_turn(super::super::turn_cap::COORDINATOR_TURN_CAP_MS);
    f.open("g").await;
    tokio::time::timeout(WAIT, turn).await.unwrap().unwrap().unwrap();
    tokio::time::timeout(WAIT, mine_task).await.unwrap().unwrap().unwrap();
    for task in tasks {
        tokio::time::timeout(WAIT, task).await.unwrap().unwrap().unwrap();
    }
    f.settled().await;
    let prompts = f.prompts();
    assert_eq!(prompts.len(), 3, "the gated turn, the person's, one digest: {prompts:?}");
    assert_eq!(prompts[1]["promptId"], "p-me");
    let digests = f.digests();
    assert_eq!(digests.len(), 1);
    assert_eq!(parts(&digests[0]).len(), 50);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_turn_end_under_the_cap_with_only_results_brings_no_digest() {
    let mut f = fixture().await;
    let turn = f.gated_turn("g").await;
    f.send("p-r", "merged", Some("lane-a"), None, true).await;
    f.open("g").await;
    tokio::time::timeout(WAIT, turn).await.unwrap().unwrap().unwrap();
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert!(f.digests().is_empty(), "the result waits for the flush");
    assert_eq!(f.session.inbox_len(), 1);
    assert!(f.timer_armed());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_block_during_a_running_turn_steers_in_as_one_digest() {
    let mut f = fixture().await;
    let turn = f.gated_turn("g").await;
    let running = f.session.turn().unwrap().turn_id;
    let (result, _) = f.send("p-r", "merged #2", Some("lane-a"), None, true).await;
    assert_eq!(result["queued"], true, "{result}");
    f.send("p-b", "blocked: need a rebase", Some("lane-b"), Some(Class::Block), true).await;
    f.until("the digest steered in", |f| f.digests().len() == 1).await;
    let digest = f.digests().remove(0);
    assert_eq!(digest["steer"], true, "{digest}");
    assert_eq!(parts(&digest), ["p-r", "p-b"]);
    assert_eq!(f.session.turn().map(|t| t.turn_id), Some(running), "the turn runs on");
    f.open("g").await;
    tokio::time::timeout(WAIT, turn).await.unwrap().unwrap().unwrap();
    f.settled().await;
    assert_eq!(f.prompts().len(), 2, "no turn of its own: {:?}", f.prompts());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn past_its_cap_a_block_waits_for_the_turn_end() {
    let mut f = fixture().await;
    let turn = f.gated_turn("g").await;
    f.age_turn(super::super::turn_cap::COORDINATOR_TURN_CAP_MS);
    f.send("p-b", "blocked", Some("lane-a"), Some(Class::Block), true).await;
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert!(f.digests().is_empty(), "nothing steers into a capped turn");
    assert!(!f.timer_armed(), "the turn's end decides");
    f.open("g").await;
    tokio::time::timeout(WAIT, turn).await.unwrap().unwrap().unwrap();
    f.until("the digest turn", |f| f.digests().len() == 1).await;
    assert_ne!(f.digests()[0]["steer"], true);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_flush_timer_brings_results_to_an_idle_coordinator_and_ends() {
    let f = fixture().await;
    f.hub.set_coordinator(&f.session, None, Some(Some(1_000)), None);
    let sent = std::time::Instant::now();
    f.send("p-r", "merged", Some("lane-a"), None, true).await;
    assert!(f.timer_armed());
    f.until("the flush", |f| f.digests().len() == 1).await;
    assert!(sent.elapsed() >= Duration::from_millis(900), "{:?}", sent.elapsed());
    f.settled().await;
    assert!(!f.timer_armed(), "fired once and ended");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_interval_timer_steers_results_into_a_running_turn() {
    let mut f = fixture().await;
    f.hub.set_coordinator(&f.session, None, None, Some(Some(1_000)));
    let turn = f.gated_turn("g").await;
    f.send("p-r", "merged", Some("lane-a"), None, true).await;
    assert!(f.digests().is_empty());
    f.until("the interval digest", |f| f.digests().len() == 1).await;
    assert_eq!(f.digests()[0]["steer"], true);
    f.open("g").await;
    tokio::time::timeout(WAIT, turn).await.unwrap().unwrap().unwrap();
    f.settled().await;
    assert!(!f.timer_armed());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn turning_it_off_stops_the_timer_and_releases_the_inbox_in_order() {
    let f = fixture().await;
    let mut tasks = Vec::new();
    for id in ["p-1", "p-2", "p-3"] {
        tasks.push(f.send(id, &format!("from {id}"), Some(id), None, true).await.1);
    }
    assert!(f.timer_armed());
    f.hub.set_coordinator(&f.session, Some(false), None, None);
    assert!(!f.timer_armed());
    assert_eq!(f.session.inbox_len(), 0);
    for task in tasks {
        tokio::time::timeout(WAIT, task).await.unwrap().unwrap().unwrap();
    }
    f.settled().await;
    assert!(f.digests().is_empty(), "released as other agents' messages, no inbox digest");
    // They ran in the order they came, together (`digest.rs` fan-in) or one by one.
    let ran: Vec<String> = f
        .prompts()
        .iter()
        .flat_map(|m| match m["_meta"]["provenance"]["messages"].as_array() {
            Some(joined) => joined.iter().map(|j| j["promptId"].clone()).collect(),
            None => vec![m["promptId"].clone()],
        })
        .filter_map(|id| id.as_str().map(str::to_owned))
        .collect();
    assert_eq!(ran, ["p-1", "p-2", "p-3"]);
    // Off, the default turn cap goes too.
    assert_eq!(super::super::turn_cap::turn_cap_ms(&f.session.meta()), None);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_item_the_digest_cannot_take_leaves_the_inbox_at_the_digest() {
    let f = fixture().await;
    let (_, image) = {
        let (tx, rx) = oneshot::channel();
        let opts = PromptOptions {
            prompt_id: Some("p-img".into()),
            agent: Some("lane-a".into()),
            on_accepted: Some(Box::new(move |v| {
                let _ = tx.send(v);
            })),
            ..PromptOptions::default()
        };
        let (hub, session) = (f.hub.clone(), f.session.clone());
        let blocks = vec![
            json!({"type": "text", "text": "see this"}),
            json!({"type": "image", "mimeType": "image/png", "data": "iVBORw0KGgo="}),
        ];
        let task =
            tokio::spawn(
                async move { hub.prompt_with(&session, blocks, "test", true, opts).await },
            );
        (tokio::time::timeout(WAIT, rx).await.unwrap().unwrap(), task)
    };
    assert_eq!(f.session.inbox_len(), 1);
    f.send("p-q", "a question", Some("lane-b"), Some(Class::Question), true).await;
    tokio::time::timeout(WAIT, image).await.unwrap().unwrap().unwrap();
    f.settled().await;
    let prompts = f.prompts();
    assert_eq!(f.digests().len(), 1, "{prompts:?}");
    assert_eq!(parts(&f.digests()[0]), ["p-q"]);
    assert!(prompts.iter().any(|m| m["promptId"] == "p-img"), "it ran by itself: {prompts:?}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_block_that_arrives_while_a_digest_is_made_goes_in_once_it_is() {
    let f = fixture().await;
    // A digest in flight: the block's own wake finds it and leaves it to that digest's end.
    f.session.inbox_digesting.store(true, Ordering::SeqCst);
    f.send("p-b", "blocked", Some("lane-a"), Some(Class::Block), true).await;
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert!(f.digests().is_empty());
    f.hub.digest_done(&f.session, true);
    f.until("the block's digest", |f| f.digests().len() == 1).await;
    assert_eq!(parts(&f.digests()[0]), ["p-b"]);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn turned_off_a_coordinator_digest_takes_nothing() {
    let f = fixture().await;
    let (_, task) = f.send("p-r", "merged", Some("lane-a"), None, true).await;
    // The setting goes off as a digest is about to take the inbox.
    f.session.inbox_digesting.store(true, Ordering::SeqCst);
    f.hub.set_coordinator(&f.session, Some(false), None, None);
    let made = f.hub.digest_waiting(&f.session, DIGEST_CLIENT, false, true).await.unwrap();
    assert_eq!(made["digested"], 0, "{made}");
    f.session.inbox_digesting.store(false, Ordering::SeqCst);
    tokio::time::timeout(WAIT, task).await.unwrap().unwrap().unwrap();
    f.settled().await;
    assert!(f.digests().is_empty(), "it ran as an agent's message: {:?}", f.prompts());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn changing_the_times_alone_parks_no_item_again() {
    let mut f = fixture().await;
    let turn = f.gated_turn("g").await;
    f.send("p-r", "merged", Some("lane-a"), None, true).await;
    // An item a digest released waits in the ordinary queue.
    f.session.queue.lock().unwrap().iter_mut().for_each(|q| q.inbox = false);
    f.hub.set_coordinator(&f.session, None, Some(Some(2_000)), Some(Some(2_000)));
    assert_eq!(f.session.inbox_len(), 0, "a change of times touches no item");
    f.hub.set_coordinator(&f.session, Some(true), None, None);
    assert_eq!(f.session.inbox_len(), 0, "on already: nothing to mark");
    f.open("g").await;
    tokio::time::timeout(WAIT, turn).await.unwrap().unwrap().unwrap();
}

#[test]
fn a_digest_waiting_at_a_restart_holds_its_originals() {
    let record = |prompt: &str, turn: &str, provenance: Option<Value>| {
        let mut msg = json!({"promptId": prompt, "turnId": turn});
        if let Some(p) = provenance {
            msg["_meta"] = json!({"provenance": p});
        }
        crate::store::EventRecord {
            seq: 0,
            at: 0,
            dir: "mux".into(),
            kind: "queued".into(),
            msg,
            host_seq: None,
        }
    };
    let digest = json!({"kind": super::super::digest::inbox_digest::KIND, "parts": [{"promptId": "p-1"}, {"promptId": "p-gone"}]});
    let waiting =
        [record("p-1", "t-1", None), record("p-2", "t-2", None), record("d", "t-d", Some(digest))];
    let held = super::super::digest::inbox_digest::digested_originals(&waiting);
    assert_eq!(held.len(), 1, "{held:?}");
    assert_eq!(held["p-1"], ("t-1".to_owned(), "d".to_owned(), "t-d".to_owned()));
}
