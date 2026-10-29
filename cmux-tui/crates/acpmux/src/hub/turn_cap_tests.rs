//! The turn cap (`turn_cap.rs`) against the fake agent steering as Claude Code does: a prompt
//! while a turn runs is read into it at once ("steer: <text>"), and the turn runs on until the
//! test opens its gate.

use super::*;
use std::time::Duration;
use tokio::sync::oneshot;

const WAIT: Duration = Duration::from_secs(20);
const NOTICE: &str = "Turn cap reached";

struct Fixture {
    hub: Arc<Hub>,
    session: Arc<Session>,
    events: tokio::sync::broadcast::Receiver<HubEvent>,
    dir: std::path::PathBuf,
}

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
    let dir = std::env::temp_dir().join(format!("acpmux-turn-cap-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&dir).unwrap();
    let session = hub
        .new_session(NewRequest { cwd: Some(std::env::temp_dir()), ..Default::default() })
        .await
        .unwrap();
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
    async fn gated_turn(&mut self, name: &str) -> tokio::task::JoinHandle<Result<Value, RpcError>> {
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

    /// Sends `text`, from agent `from` or (`None`) the person, as a steer when `steer`; answers
    /// with its acceptance (`queued`, `steer`) and its task.
    async fn send(
        &self,
        text: &str,
        from: Option<&str>,
        steer: bool,
        steer_only: bool,
    ) -> (Result<Value, RpcError>, tokio::task::JoinHandle<Result<Value, RpcError>>) {
        let (tx, rx) = oneshot::channel();
        let opts = PromptOptions {
            agent: from.map(str::to_owned),
            steer_only,
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
        match tokio::time::timeout(WAIT, rx).await.expect("accepted or refused in time") {
            Ok(accepted) => (Ok(accepted), task),
            // Refused: its options, and the acceptance with them, went unused.
            Err(_) => {
                let refused = task.await.unwrap().expect_err("refused before its acceptance");
                (Err(refused.clone()), tokio::spawn(async move { Err(refused) }))
            }
        }
    }

    /// Makes the running turn `cap` ms old, plus one.
    fn age_turn(&self, cap: u64) {
        let mut turn = self.session.turn.lock().unwrap();
        let turn = turn.as_mut().expect("a running turn");
        turn.started_at = turn.started_at.saturating_sub(cap + 1);
    }

    /// The notices the agent got, by the turn their provenance names.
    fn notices(&self) -> Vec<String> {
        let records = self.hub.events(&self.session.id, 0, 100_000).unwrap();
        let sent = records
            .iter()
            .filter(|r| r.dir == "out" && r.kind == "session/prompt")
            .filter(|r| r.msg["params"]["prompt"].to_string().contains(NOTICE))
            .count();
        let logged: Vec<String> = records
            .iter()
            .filter(|r| r.kind == "user_message")
            .filter(|r| r.msg["_meta"]["provenance"]["kind"] == NOTICE_KIND)
            .map(|r| r.msg["_meta"]["provenance"]["turnId"].as_str().unwrap_or("").to_owned())
            .collect();
        assert_eq!(sent, logged.len(), "every notice logged is one the agent got");
        logged
    }
}

#[tokio::test]
async fn a_sessions_own_cap_wins_and_zero_turns_it_off() {
    let f = fixture().await;
    let mut meta = f.session.meta();
    assert_eq!(turn_cap_ms(&meta), None, "no cap by default");
    meta.turn_cap_ms = Some(60_000);
    assert_eq!(turn_cap_ms(&meta), Some(60_000));
    meta.turn_cap_ms = Some(0);
    assert_eq!(turn_cap_ms(&meta), None);
    // A coordinator's default is 20 minutes; its own cap, or 0, still wins.
    meta.coordinator = true;
    assert_eq!(turn_cap_ms(&meta), None);
    meta.turn_cap_ms = None;
    assert_eq!(turn_cap_ms(&meta), Some(COORDINATOR_TURN_CAP_MS));
    assert_eq!(
        notice_text(COORDINATOR_TURN_CAP_MS),
        "Turn cap reached (20 min): finish the current step and end your turn; your inbox digest comes next turn."
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn under_the_cap_an_agent_message_steers_in_as_before() {
    let mut f = fixture().await;
    f.hub.set_turn_cap(&f.session, Some(3_600_000));
    let turn = f.gated_turn("g").await;
    let (accepted, _) = f.send("from lane a", Some("lane-a"), true, false).await;
    assert_eq!(accepted.unwrap()["steer"], true);
    f.heard("steer: from lane a").await;
    f.open("g").await;
    tokio::time::timeout(WAIT, turn).await.unwrap().unwrap().unwrap();
    assert!(f.notices().is_empty(), "no notice under the cap");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn past_the_cap_agent_messages_wait_one_notice_goes_in_and_the_persons_steer_still_does() {
    let mut f = fixture().await;
    let cap = 600_000;
    f.hub.set_turn_cap(&f.session, Some(cap));
    let turn = f.gated_turn("g").await;
    let turn_id = f.session.turn().unwrap().turn_id;
    f.age_turn(cap);
    let (first, _) = f.send("from lane a", Some("lane-a"), true, false).await;
    let first = first.unwrap();
    assert_eq!(first["queued"], true, "held for the next turn: {first}");
    assert_ne!(first["steer"], true);
    f.heard(&format!("steer: {}", notice_text(cap))).await;
    let (second, _) = f.send("from lane b", Some("lane-b"), true, false).await;
    assert_eq!(second.unwrap()["queued"], true);
    // Steer-only cannot wait: refused, and it says why.
    let (only, _) = f.send("steer or nothing", Some("lane-c"), true, true).await;
    let only = only.expect_err("a steer-only agent message past the cap");
    assert!(only.message.contains("turn cap"), "{}", only.message);
    // The person's own steer still goes in.
    let (person, _) = f.send("from the person", None, true, false).await;
    assert_eq!(person.unwrap()["steer"], true);
    f.heard("steer: from the person").await;
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert_eq!(f.notices(), [turn_id], "exactly one notice, into the capped turn");
    assert!(f.session.turn().is_some(), "the hub never ends the turn itself");
    f.open("g").await;
    tokio::time::timeout(WAIT, turn).await.unwrap().unwrap().unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn held_messages_reach_the_next_turn_and_the_next_turn_has_its_own_cap() {
    let mut f = fixture().await;
    let cap = 600_000;
    f.hub.set_turn_cap(&f.session, Some(cap));
    let turn = f.gated_turn("g1").await;
    f.age_turn(cap);
    let (_, a) = f.send("held from lane a", Some("lane-a"), true, false).await;
    let (_, b) = f.send("held from lane b", Some("lane-b"), true, false).await;
    f.heard(&format!("steer: {}", notice_text(cap))).await;
    f.open("g1").await;
    tokio::time::timeout(WAIT, turn).await.unwrap().unwrap().unwrap();
    // The next turn takes both, together (`digest.rs`), as one prompt.
    let a = tokio::time::timeout(WAIT, a).await.unwrap().unwrap().unwrap();
    let b = tokio::time::timeout(WAIT, b).await.unwrap().unwrap().unwrap();
    assert_eq!(a["_meta"]["acpmux"]["turnId"], b["_meta"]["acpmux"]["turnId"]);
    let records = f.hub.events(&f.session.id, 0, 100_000).unwrap();
    let joined: Vec<_> = records
        .iter()
        .filter(|r| r.dir == "out" && r.kind == "session/prompt")
        .map(|r| r.msg["params"]["prompt"].to_string())
        .filter(|p| p.contains("held from lane a"))
        .collect();
    assert_eq!(joined.len(), 1, "delivered once: {joined:?}");
    assert!(joined[0].contains("held from lane b"));
    assert!(!records.iter().any(|r| {
        r.msg["params"]["update"]["content"]["text"]
            .as_str()
            .is_some_and(|t| t.starts_with("steer: held from"))
    }));
    // A new turn is under its cap again, and past it gets a notice of its own.
    let turn = f.gated_turn("g2").await;
    let second_turn = f.session.turn().unwrap().turn_id;
    let (under, _) = f.send("fresh from lane a", Some("lane-a"), true, false).await;
    assert_eq!(under.unwrap()["steer"], true);
    f.age_turn(cap);
    let (_, _held) = f.send("late from lane a", Some("lane-a"), true, false).await;
    f.heard(&format!("steer: {}", notice_text(cap))).await;
    let notices = f.notices();
    assert_eq!(notices.len(), 2, "{notices:?}");
    assert_eq!(notices[1], second_turn);
    f.open("g2").await;
    tokio::time::timeout(WAIT, turn).await.unwrap().unwrap().unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_timer_sends_the_notice_at_the_cap_only_when_a_message_waits() {
    let mut f = fixture().await;
    f.hub.set_turn_cap(&f.session, Some(400));
    // Nothing waits: the cap passes with no notice.
    let turn = f.gated_turn("quiet").await;
    tokio::time::sleep(Duration::from_millis(1_200)).await;
    assert!(f.notices().is_empty());
    f.open("quiet").await;
    tokio::time::timeout(WAIT, turn).await.unwrap().unwrap().unwrap();
    // An agent message queued under the cap (no steer): the timer sends the notice at the cap.
    f.hub.set_turn_cap(&f.session, Some(3_000));
    let turn = f.gated_turn("busy").await;
    let turn_id = f.session.turn().unwrap().turn_id;
    let (queued, _) = f.send("report from lane a", Some("lane-a"), false, false).await;
    assert_eq!(queued.unwrap()["queued"], true);
    assert!(f.notices().is_empty(), "nothing before the cap");
    f.heard(&format!("steer: {}", notice_text(3_000))).await;
    assert_eq!(f.notices(), [turn_id]);
    f.open("busy").await;
    tokio::time::timeout(WAIT, turn).await.unwrap().unwrap().unwrap();
}
