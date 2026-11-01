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
        // Agents' messages steer into the person's turn on the queue path before the inbox, which
        // these tests cover; with the inbox on, none goes into the person's turn (`inbox.rs`).
        "agentInbox": false,
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
        let opts = PromptOptions {
            agent: from.map(str::to_owned),
            steer_only,
            ..PromptOptions::default()
        };
        self.send_with(text, steer, opts).await
    }

    /// [`Fixture::send`] with any options.
    async fn send_with(
        &self,
        text: &str,
        steer: bool,
        mut opts: PromptOptions,
    ) -> (Result<Value, RpcError>, tokio::task::JoinHandle<Result<Value, RpcError>>) {
        let (tx, rx) = oneshot::channel();
        opts.on_accepted = Some(Box::new(move |v| {
            let _ = tx.send(v);
        }));
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

    /// The notices logged, by the turn their provenance names.
    fn logged_notices(&self) -> Vec<String> {
        let records = self.hub.events(&self.session.id, 0, 100_000).unwrap();
        records
            .iter()
            .filter(|r| r.kind == "user_message")
            .filter(|r| r.msg["_meta"]["provenance"]["kind"] == NOTICE_KIND)
            .map(|r| r.msg["_meta"]["provenance"]["turnId"].as_str().unwrap_or("").to_owned())
            .collect()
    }

    /// The notices the agent got, by the turn their provenance names: called once every notice
    /// logged has been heard (none may still be on its way).
    fn notices(&self) -> Vec<String> {
        let logged = self.logged_notices();
        let records = self.hub.events(&self.session.id, 0, 100_000).unwrap();
        let sent = records
            .iter()
            .filter(|r| r.dir == "out" && r.kind == "session/prompt")
            .filter(|r| r.msg["params"]["prompt"].to_string().contains(NOTICE))
            .count();
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
    let started = f.session.turn().unwrap().started_at;
    let (queued, _) = f.send("report from lane a", Some("lane-a"), false, false).await;
    assert_eq!(queued.unwrap()["queued"], true);
    // Checked only while the cap is still ahead: a slow machine may already be past it, its
    // notice logged and still on its way to the agent.
    let logged = f.logged_notices();
    if now_ms().saturating_sub(started) < 2_500 {
        assert!(logged.is_empty(), "nothing before the cap");
    }
    f.heard(&format!("steer: {}", notice_text(3_000))).await;
    assert_eq!(f.notices(), [turn_id]);
    f.open("busy").await;
    tokio::time::timeout(WAIT, turn).await.unwrap().unwrap().unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn past_the_cap_send_now_still_steers_a_held_message_in_and_an_agents_interrupt_stops_nothing()
 {
    let mut f = fixture().await;
    let cap = 600_000;
    f.hub.set_turn_cap(&f.session, Some(cap));
    let turn = f.gated_turn("g").await;
    let turn_id = f.session.turn().unwrap().turn_id;
    f.age_turn(cap);
    // An agent's interrupt past the cap waits like any of its messages: the turn runs on.
    let opts =
        PromptOptions { agent: Some("lane-a".into()), interrupt: true, ..PromptOptions::default() };
    let (interrupt, _) = f.send_with("stop for me", true, opts).await;
    assert_eq!(interrupt.unwrap()["queued"], true);
    let (held, held_task) = f.send("held from lane b", Some("lane-b"), true, false).await;
    let prompt_id = held.unwrap()["promptId"].as_str().unwrap().to_owned();
    f.heard(&format!("steer: {}", notice_text(cap))).await;
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(f.session.turn().map(|t| t.turn_id), Some(turn_id.clone()), "nothing stopped it");
    // The queue's Send now is the person's: it steers the held message in, past the cap.
    let edit = json!({"op": "send_now", "promptId": prompt_id});
    let sent = f.hub.queue_edit(&f.session, &edit, Control::default(), false, None).await.unwrap();
    assert_eq!(sent["ok"], true, "{sent}");
    f.heard("steer: held from lane b").await;
    let answer = tokio::time::timeout(WAIT, held_task).await.unwrap().unwrap().unwrap();
    assert_eq!(answer["_meta"]["acpmux"]["steer"], true, "{answer}");
    assert_eq!(f.session.turn().map(|t| t.turn_id), Some(turn_id), "still the same turn");
    f.open("g").await;
    tokio::time::timeout(WAIT, turn).await.unwrap().unwrap().unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_notice_reaches_only_the_turn_it_names_and_a_restored_marker_sends_none() {
    let mut f = fixture().await;
    let cap = 600_000;
    f.hub.set_turn_cap(&f.session, Some(cap));
    let turn = f.gated_turn("g").await;
    let turn_id = f.session.turn().unwrap().turn_id;
    // A notice for a turn that ended never goes into the one that runs now.
    let stale = PromptOptions {
        steer_only: true,
        provenance: Some(json!({"kind": NOTICE_KIND, "turnId": "an-ended-turn", "capMs": cap})),
        ..PromptOptions::default()
    };
    let blocks = vec![json!({"type": "text", "text": notice_text(cap)})];
    let refused = f.hub.prompt_with(&f.session, blocks, "acpmux", true, stale).await;
    let refused = refused.expect_err("a notice for another turn");
    assert!(refused.message.starts_with(crate::claude_stdio::STEER_NO_TURN), "{}", refused.message);
    // The turn already had its notice (a restart adopted it with its saved marker): none again.
    f.session.meta.lock().unwrap().turn_cap_noticed = Some(turn_id.clone());
    f.age_turn(cap);
    let (held, _) = f.send("from lane a", Some("lane-a"), true, false).await;
    assert_eq!(held.unwrap()["queued"], true);
    tokio::time::sleep(Duration::from_millis(500)).await;
    let records = f.hub.events(&f.session.id, 0, 100_000).unwrap();
    let sent = records
        .iter()
        .filter(|r| r.dir == "out" && r.kind == "session/prompt")
        .filter(|r| r.msg["params"]["prompt"].to_string().contains(NOTICE))
        .count();
    assert_eq!(sent, 0, "no notice reached the agent");
    f.open("g").await;
    tokio::time::timeout(WAIT, turn).await.unwrap().unwrap().unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_notice_whose_turn_ends_on_its_way_never_reaches_the_next_turn() {
    let mut f = fixture().await;
    let cap = 600_000;
    let first = f.gated_turn("g1").await;
    let turn_id = f.session.turn().unwrap().turn_id;
    // The notice stops after it is logged, before it is written (its model-sized copies).
    let (arrived_tx, arrived) = oneshot::channel();
    let (release, release_rx) = oneshot::channel();
    *f.hub.copy_seam.lock().unwrap() = Some((arrived_tx, release_rx));
    let opts = PromptOptions {
        prompt_id: Some(format!("turn-cap-{turn_id}")),
        steer_only: true,
        provenance: Some(json!({"kind": NOTICE_KIND, "turnId": turn_id, "capMs": cap})),
        ..PromptOptions::default()
    };
    let (hub, session) = (f.hub.clone(), f.session.clone());
    let notice = tokio::spawn(async move {
        let blocks = vec![json!({"type": "text", "text": notice_text(cap)})];
        hub.prompt_with(&session, blocks, "acpmux", true, opts).await
    });
    tokio::time::timeout(WAIT, arrived).await.unwrap().unwrap();
    // Its turn ends and the next one starts meanwhile.
    f.open("g1").await;
    tokio::time::timeout(WAIT, first).await.unwrap().unwrap().unwrap();
    let second = f.gated_turn("g2").await;
    assert_ne!(f.session.turn().unwrap().turn_id, turn_id);
    release.send(()).unwrap();
    let refused = tokio::time::timeout(WAIT, notice).await.unwrap().unwrap();
    let refused = refused.expect_err("a notice for a turn that ended");
    assert!(refused.message.starts_with(crate::claude_stdio::STEER_NO_TURN), "{}", refused.message);
    let records = f.hub.events(&f.session.id, 0, 100_000).unwrap();
    let written = records
        .iter()
        .filter(|r| r.dir == "out" && r.kind == "session/prompt")
        .filter(|r| r.msg["params"]["prompt"].to_string().contains(NOTICE))
        .count();
    assert_eq!(written, 0, "the next turn's agent never got it");
    let withdrawn = records
        .iter()
        .any(|r| r.kind == "steer_withdrawn" && r.msg["promptId"] == format!("turn-cap-{turn_id}"));
    assert!(withdrawn, "the log says the logged notice never went");
    f.open("g2").await;
    tokio::time::timeout(WAIT, second).await.unwrap().unwrap().unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_notice_the_log_holds_is_not_sent_again_when_its_marker_is_lost() {
    let mut f = fixture().await;
    let cap = 600_000;
    f.hub.set_turn_cap(&f.session, Some(cap));
    let turn = f.gated_turn("g").await;
    let turn_id = f.session.turn().unwrap().turn_id;
    f.age_turn(cap);
    let (_, _a) = f.send("from lane a", Some("lane-a"), true, false).await;
    f.heard(&format!("steer: {}", notice_text(cap))).await;
    // The meta save of its marker was lost (a crash before it reached the disk).
    f.session.meta.lock().unwrap().turn_cap_noticed = None;
    let (_, _b) = f.send("from lane b", Some("lane-b"), true, false).await;
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert_eq!(f.notices(), [turn_id], "the log's notice stands; none is sent again");
    f.open("g").await;
    tokio::time::timeout(WAIT, turn).await.unwrap().unwrap().unwrap();
}

/// An inbox digest marked to steer that finds the turn past its cap when its task steers it
/// (`queue.rs` `steer_queued`) waits for the next turn, as the messages it took would have: the
/// queue's Send now is the person's, a digest is not.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_digest_steered_past_the_cap_waits_for_the_next_turn() {
    let mut f = fixture().await;
    let cap = 600_000;
    f.hub.set_turn_cap(&f.session, Some(cap));
    let turn = f.gated_turn("g").await;
    f.age_turn(cap);
    let run = Arc::new(super::queue::PromptRun {
        size: Default::default(),
        blocks: vec![json!({"type": "text", "text": "[inbox digest] 1 message"})],
        display_parts: None,
        control: Control::default(),
        trust_gate: false,
        provenance: Some(json!({"kind": super::digest::inbox_digest::KIND, "digestId": "d"})),
        agent: Some(super::digest::inbox_digest::SENDER.to_owned()),
        class: None,
        supersede: None,
        full_access_device: None,
        message_id: None,
        message_sender: None,
    });
    let (hub, session) = (f.hub.clone(), f.session.clone());
    let steered =
        tokio::spawn(
            async move { hub.steer_queued(&session, run, "test", "inbox-digest-x").await },
        );
    let deadline = tokio::time::Instant::now() + WAIT;
    while !f.session.queue().iter().any(|q| q.prompt_id == "inbox-digest-x") {
        assert!(!steered.is_finished(), "it ran: {:?}", steered.await);
        assert!(tokio::time::Instant::now() < deadline, "it never queued");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    let records = f.hub.events(&f.session.id, 0, 100_000).unwrap();
    let steer = records.iter().any(|r| {
        r.kind == "user_message" && r.msg["promptId"] == "inbox-digest-x" && r.msg["steer"] == true
    });
    assert!(!steer, "the digest steered into a turn past its cap");
    f.open("g").await;
    tokio::time::timeout(WAIT, turn).await.unwrap().unwrap().unwrap();
    tokio::time::timeout(WAIT, steered).await.unwrap().unwrap().unwrap();
}

/// A turn that started before its timer was armed (one a restart adopts, `hosts.rs`,
/// `carried_turn.rs` `recover_carried`): its cap counts from its own start, not from the arming.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_adopted_turns_timer_counts_from_the_turns_start() {
    let mut f = fixture().await;
    let cap = 600_000;
    f.hub.set_turn_cap(&f.session, Some(cap));
    let turn = f.gated_turn("g").await;
    let turn_id = f.session.turn().unwrap().turn_id;
    let (queued, _) = f.send("report from lane a", Some("lane-a"), false, false).await;
    assert_eq!(queued.unwrap()["queued"], true);
    // Past its cap when it is adopted: the timer wakes at once, not a whole cap later.
    f.age_turn(cap);
    f.hub.arm_turn_cap(&f.session, &turn_id);
    f.heard(&format!("steer: {}", notice_text(cap))).await;
    assert_eq!(f.notices(), [turn_id]);
    f.open("g").await;
    tokio::time::timeout(WAIT, turn).await.unwrap().unwrap().unwrap();
}

/// Another agent's message the inbox holds under the cap (`inbox.rs`: the person's prompt waits,
/// so no inbox notice steers in, and past the cap none does) waits for the turn too: the timer
/// sends the notice at the cap.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_inbox_message_held_under_the_cap_gets_the_notice_at_the_cap() {
    let mut f = fixture().await;
    let cap = 1_500;
    f.hub.set_turn_cap(&f.session, Some(cap));
    let turn = f.gated_turn("g").await;
    let turn_id = f.session.turn().unwrap().turn_id;
    let (person, _next) = f.send("next from the person", None, false, false).await;
    assert_eq!(person.unwrap()["queued"], true);
    let opts =
        PromptOptions { agent: Some("lane-a".into()), inbox: true, ..PromptOptions::default() };
    let (held, _held) = f.send_with("from lane a", false, opts).await;
    held.unwrap();
    let in_inbox = |f: &Fixture| f.session.inbox.lock().unwrap().items.iter().any(|i| !i.noticed);
    assert!(in_inbox(&f), "held in the inbox, no notice carries it");
    f.heard(&format!("steer: {}", notice_text(cap))).await;
    assert_eq!(f.notices(), [turn_id]);
    f.open("g").await;
    tokio::time::timeout(WAIT, turn).await.unwrap().unwrap().unwrap();
}

/// An inbox notice refused as its turn crosses the cap (written to no agent) leaves its message
/// waiting in the inbox, which steers none into a turn past its cap: the turn gets the cap's
/// notice then. The timer, which ran while the notice carried it, saw nothing waiting.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_inbox_notice_refused_past_the_cap_leaves_its_message_waiting_and_sends_the_notice() {
    let mut f = fixture().await;
    let cap = 600_000;
    f.hub.set_turn_cap(&f.session, Some(cap));
    let turn = f.gated_turn("g").await;
    let turn_id = f.session.turn().unwrap().turn_id;
    let ids = vec!["m-1".to_owned()];
    {
        let mut inbox = f.session.inbox.lock().unwrap();
        inbox.items.push(super::inbox::Item::carried("m-1", "lane-a", "from lane a"));
        inbox.in_flight = Some(("n-1".into(), ids.clone()));
    }
    f.age_turn(cap);
    f.hub.inbox_notice_refused(&f.session, "n-1", &ids);
    f.heard(&format!("steer: {}", notice_text(cap))).await;
    assert_eq!(f.notices(), [turn_id]);
    f.open("g").await;
    tokio::time::timeout(WAIT, turn).await.unwrap().unwrap().unwrap();
}
