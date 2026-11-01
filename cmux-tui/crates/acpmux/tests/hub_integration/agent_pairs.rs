//! The runaway guard for agent-to-agent messages (`hub/agent_pairs.rs`): two sessions that keep
//! messaging each other with no tool call or file change in between, or one that keeps sending
//! the same message, are paused as a pair. A paused pair's messages are held, not delivered, and
//! both transcripts say so; `_acpmux/agent_pair_resume` (or the person prompting either session)
//! delivers them in order. Sessions whose turns do work are paused only by the cap: more than 20
//! messages within 10 minutes with no prompt from the person (`0` turns it off).

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::Message;
use acpmux::server::{Origin, serve_connection_with};
use serde_json::{Value, json};
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
const RESUME: &str = "_acpmux/agent_pair_resume";
const SUBSESSION_START: &str = "_acpmux/subsession/start";
const SUBSESSION_SEND: &str = "_acpmux/subsession/send";

/// The person key the hubs of these tests hold, as a daemon the app started does.
const PERSON_KEY: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

fn config(dir: Option<&Path>) -> Config {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE], "family": "codex"}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all"
    }))
    .unwrap();
    cfg.store.mode = if dir.is_some() { StoreMode::Local } else { StoreMode::Memory };
    // The queue path before the inbox (`hub/inbox.rs`), which these tests cover.
    cfg.agent_inbox = Some(false);
    cfg
}

fn hub_in(dir: Option<&Path>) -> Arc<Hub> {
    let cfg = config(dir);
    let store = acpmux::store::open(&cfg.store, dir.unwrap_or(Path::new("/nonexistent"))).unwrap();
    let hub = Hub::new(cfg, store);
    let _ = hub.person.install_spawn_key(PERSON_KEY);
    hub
}

fn hub() -> Arc<Hub> {
    hub_in(None)
}

/// A daemon's hub after a restart (`Hub::new_deferred`): it reads each chat's log only when a
/// request needs it, until `load_logs` (`hub/log_load.rs`).
fn deferred_hub_in(dir: &Path) -> Arc<Hub> {
    let cfg = config(Some(dir));
    let store = acpmux::store::open(&cfg.store, dir).unwrap();
    let mailbox = acpmux::mailbox::Mailbox::memory();
    let hub = Hub::new_deferred(cfg, store, mailbox);
    let _ = hub.person.install_spawn_key(PERSON_KEY);
    hub
}

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

impl Client {
    fn open(hub: &Arc<Hub>) -> Self {
        Self::open_as(hub, Origin::Local)
    }

    fn open_as(hub: &Arc<Hub>, origin: Origin) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, origin));
        Self(in_tx, out_rx, 0)
    }

    async fn reply(&mut self, method: &str, params: Value) -> Value {
        self.2 += 1;
        let id = self.2;
        self.0.send(Message::request(id, method, params).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(30), self.1.recv())
                .await
                .expect("timed out")
                .expect("connection closed");
            let value: Value = serde_json::from_str(&line).unwrap();
            if value.get("id") == Some(&json!(id)) {
                return value;
            }
        }
    }

    /// The app's handshake: `initialize`, then the person proof (`hub/person.rs`).
    async fn person(hub: &Arc<Hub>) -> Self {
        let mut c = Self::open(hub);
        let init = c.call("initialize", json!({"protocolVersion": 1})).await;
        let challenge = &init["_meta"]["acpmux"]["personChallenge"];
        let proof = acpmux::hub::person::person_proof(
            PERSON_KEY,
            acpmux::hub::person::TRANSPORT_UNIX,
            challenge["nonce"].as_str().unwrap(),
            challenge["connection"].as_str().unwrap(),
        )
        .unwrap();
        let proved = c.call("_acpmux/person_prove", json!({"proof": proof})).await;
        assert_eq!(proved["person"], true, "{proved}");
        c
    }

    /// The connection a session's own tools open (its cmux-subsessions MCP server): `initialize`
    /// with the session's caller token (`hub/person.rs`).
    async fn as_session(hub: &Arc<Hub>, id: &str) -> Self {
        let mut c = Self::open(hub);
        let token = acpmux::hub::person::caller_token(id);
        c.call(
            "initialize",
            json!({"protocolVersion": 1,
                   "_meta": {"acpmux": {"callerSession": {"sessionId": id, "token": token}}}}),
        )
        .await;
        c
    }

    /// The cmux-subsessions `send_message` tool from this connection's session to `to`: the
    /// whole `_acpmux/subsession/send` reply.
    async fn send_message(
        &mut self,
        to: &str,
        prompt_id: &str,
        text: &str,
        interrupt: bool,
    ) -> Value {
        let params = json!({"sessionId": to, "text": text, "promptId": prompt_id,
                            "interrupt": interrupt});
        self.reply(SUBSESSION_SEND, params).await
    }

    async fn call(&mut self, method: &str, params: Value) -> Value {
        let value = self.reply(method, params).await;
        assert!(value.get("error").is_none(), "{method}: {value}");
        value["result"].clone()
    }

    async fn new_session(&mut self) -> String {
        let new = json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"harness": "fake"}}});
        self.call("session/new", new).await["sessionId"].as_str().unwrap().to_owned()
    }

    /// `from` messages `to` as `cmux agent message` does, and waits for the turn it starts (or
    /// the refusal): the whole `session/prompt` reply.
    async fn message(&mut self, from: &str, to: &str, msg_id: &str, text: &str) -> Value {
        self.message_as(&format!("acp:{from}"), to, msg_id, text, json!({})).await
    }

    /// A message from the sender address `from` (`acp:<session>`, `cli`, a terminal id), with
    /// `extra` merged into `_meta.acpmux`.
    async fn message_as(
        &mut self,
        from: &str,
        to: &str,
        msg_id: &str,
        text: &str,
        extra: Value,
    ) -> Value {
        let provenance = json!({"kind": "agent_message", "from": from,
            "fromName": "agent", "to": format!("acp:{to}"), "msgId": msg_id, "threadId": "t-1"});
        let mut mux = json!({"promptId": msg_id, "provenance": provenance});
        for (k, v) in extra.as_object().unwrap() {
            mux[k] = v.clone();
        }
        let params = json!({"sessionId": to, "prompt": [{"type": "text", "text": text}],
            "_meta": {"acpmux": mux}});
        self.reply("session/prompt", params).await
    }

    /// The prompt ids of `session`'s `user_message` records, in order. A turn of agent messages
    /// that waited together (`hub/digest.rs`) counts every message in it, oldest first.
    async fn ran_ids(&mut self, session: &str) -> Vec<String> {
        let records = self.records(session, "user_message").await;
        let ids = |m: &Value| match m["_meta"]["provenance"]["messages"].as_array() {
            Some(joined) if m["_meta"]["provenance"]["kind"] == "agent_digest" => joined.clone(),
            _ => vec![json!({"promptId": m["promptId"]})],
        };
        let ids = records.iter().flat_map(ids);
        ids.filter_map(|m| m["promptId"].as_str().map(str::to_owned)).collect()
    }

    async fn records(&mut self, session: &str, kind: &str) -> Vec<Value> {
        let page =
            self.call("_acpmux/events", json!({"sessionId": session, "kinds": [kind]})).await;
        page["events"].as_array().unwrap().iter().map(|e| e["msg"].clone()).collect()
    }

    async fn ran(&mut self, session: &str, prompt_id: &str) -> bool {
        self.ran_ids(session).await.iter().any(|id| id == prompt_id)
    }

    /// Waits until `session`'s log has a `user_message` for `prompt_id` (a spawned release).
    async fn wait_ran(&mut self, session: &str, prompt_id: &str) {
        let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
        while !self.ran(session, prompt_id).await {
            assert!(tokio::time::Instant::now() < deadline, "{prompt_id} never ran");
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
    }
}

fn held(reply: &Value) -> bool {
    reply.pointer("/error/data/reason") == Some(&json!("agent_pair.paused"))
}

/// Ten pure-text replies back and forth, nine of them going back and forth.
const CHATTER: [&str; 10] = [
    "what should we do next",
    "you decide",
    "no you pick one",
    "either works for me",
    "fine by me",
    "your call then",
    "alright let us wait",
    "waiting sounds good",
    "still waiting here",
    "same on this side",
];

/// Ten exchanges back and forth whose turns make no tool call: the tenth is held, both
/// transcripts record the pause, and the person's resume delivers what was held.
#[tokio::test]
async fn sessions_that_message_back_and_forth_without_progress_are_paused() {
    let hub = hub();
    let mut c = Client::open(&hub);
    let (a, b) = (c.new_session().await, c.new_session().await);
    for (i, text) in CHATTER[..9].iter().enumerate() {
        let (from, to) = if i % 2 == 0 { (&a, &b) } else { (&b, &a) };
        let reply = c.message(from, to, &format!("m{i}"), text).await;
        assert!(reply.get("error").is_none(), "exchange {i} was delivered: {reply}");
    }
    // The tenth exchange in a row with no progress trips the guard.
    let tenth = c.message(&b, &a, "m9", CHATTER[9]).await;
    assert!(held(&tenth), "the tenth exchange is held: {tenth}");
    let text = tenth.pointer("/error/message").and_then(Value::as_str).unwrap_or("");
    assert!(text.contains("resume"), "the sender reads that the user resumes it: {text}");
    assert!(!c.ran(&a, "m9").await, "a held message does not run");
    for session in [&a, &b] {
        let paused = c.records(session, "agent_pair_paused").await;
        assert_eq!(paused.len(), 1, "{session}: {paused:?}");
        assert_eq!(paused[0]["reason"], "alternating", "{paused:?}");
    }
    let held_records = c.records(&a, "agent_pair_held").await;
    assert_eq!(held_records.len(), 1, "{held_records:?}");
    assert_eq!(held_records[0]["promptId"], "m9", "{held_records:?}");
    // While paused, the pair's later messages are held too, either way.
    let later = c.message(&a, &b, "m10", "ok").await;
    assert!(held(&later), "{later}");

    let mut person = Client::person(&hub).await;
    let resumed = person.call(RESUME, json!({"sessionId": a})).await;
    assert_eq!(resumed["resumed"], 1, "{resumed}");
    assert_eq!(resumed["delivered"], 2, "{resumed}");
    c.wait_ran(&a, "m9").await;
    c.wait_ran(&b, "m10").await;
    for session in [&a, &b] {
        let records = c.records(session, "agent_pair_resumed").await;
        assert_eq!(records.len(), 1, "{session}: {records:?}");
        assert_eq!(records[0]["by"], "request", "{records:?}");
    }
    // A resumed pair starts counting again.
    let after = c.message(&a, &b, "m11", "thanks").await;
    assert!(after.get("error").is_none(), "{after}");
}

/// The same message three times from one sender to one receiver: the third is held.
#[tokio::test]
async fn a_sender_repeating_the_same_message_is_paused() {
    let hub = hub();
    let mut c = Client::open(&hub);
    let (a, b) = (c.new_session().await, c.new_session().await);
    let first = c.message(&a, &b, "r1", "Please check the build, run 1").await;
    assert!(first.get("error").is_none(), "{first}");
    let second = c.message(&a, &b, "r2", "please  check the BUILD, run 2").await;
    assert!(second.get("error").is_none(), "{second}");
    let third = c.message(&a, &b, "r3", "Please check the build, run 3").await;
    assert!(held(&third), "the third near-identical message is held: {third}");
    let paused = c.records(&b, "agent_pair_paused").await;
    assert_eq!(paused.len(), 1, "{paused:?}");
    assert_eq!(paused[0]["reason"], "repeating", "{paused:?}");

    // The person prompting either session resumes the pair and delivers what it held.
    let mut person = Client::person(&hub).await;
    person
        .call(
            "session/prompt",
            json!({"sessionId": a, "prompt": [{"type": "text", "text": "stop and summarize"}]}),
        )
        .await;
    c.wait_ran(&b, "r3").await;
    let resumed = c.records(&b, "agent_pair_resumed").await;
    assert_eq!(resumed.len(), 1, "{resumed:?}");
    assert_eq!(resumed[0]["by"], "person", "{resumed:?}");
}

/// Two sessions whose turns each make a tool call are not paused as a loop, however alike their
/// messages are.
#[tokio::test]
async fn sessions_whose_turns_do_work_are_never_paused() {
    let hub = hub();
    let mut c = Client::open(&hub);
    let (a, b) = (c.new_session().await, c.new_session().await);
    for i in 0..12 {
        let (from, to) = if i % 2 == 0 { (&a, &b) } else { (&b, &a) };
        let reply = c.message(from, to, &format!("w{i}"), "do-work on the next step").await;
        assert!(reply.get("error").is_none(), "exchange {i} was delivered: {reply}");
    }
    assert!(c.records(&a, "agent_pair_paused").await.is_empty());
    assert!(c.records(&b, "agent_pair_paused").await.is_empty());
}

/// A worker that does work between its status reports to an idle coordinator is never paused,
/// though the reports read alike: progress in the sender counts too.
#[tokio::test]
async fn a_worker_doing_work_between_alike_reports_is_never_paused() {
    let hub = hub();
    let mut c = Client::open(&hub);
    let (worker, coordinator, other) =
        (c.new_session().await, c.new_session().await, c.new_session().await);
    for (i, chatter) in CHATTER.iter().enumerate().take(5) {
        let report = c
            .message(&worker, &coordinator, &format!("s{i}"), &format!("CI run {i} pending"))
            .await;
        assert!(report.get("error").is_none(), "report {i} was delivered: {report}");
        // The worker's next turn makes a tool call before its next report.
        let work = c
            .message(&other, &worker, &format!("k{i}"), &format!("do-work step {i} {chatter}"))
            .await;
        assert!(work.get("error").is_none(), "{work}");
    }
    assert!(c.records(&coordinator, "agent_pair_paused").await.is_empty());
}

/// A message whose sender is no acpmux session (the person's `cmux agent message`, which the
/// cmux daemon stamps `cli`, or a terminal) is never counted or paused.
#[tokio::test]
async fn a_sender_that_is_no_session_is_never_paused() {
    let hub = hub();
    let mut c = Client::open(&hub);
    let b = c.new_session().await;
    for from in ["cli", "term_1234"] {
        for i in 0..4 {
            let reply = c
                .message_as(from, &b, &format!("{from}-{i}"), "please check the build", json!({}))
                .await;
            assert!(reply.get("error").is_none(), "{from} message {i} was delivered: {reply}");
        }
    }
    assert!(c.records(&b, "agent_pair_paused").await.is_empty());
}

/// Only the person resumes a pair: an agent's own unix-socket client may neither call the
/// resume nor resume it by prompting a session of the pair.
#[tokio::test]
async fn an_agent_cannot_resume_its_own_pair() {
    let hub = hub();
    let mut c = Client::open(&hub);
    let (a, b) = (c.new_session().await, c.new_session().await);
    for i in 0..2 {
        c.message(&a, &b, &format!("x{i}"), "please check the build").await;
    }
    assert!(held(&c.message(&a, &b, "x2", "please check the build").await));
    let refused = c.reply(RESUME, json!({"sessionId": a})).await;
    assert!(refused.get("error").is_some(), "a resume that is not the person's: {refused}");
    c.call(
        "session/prompt",
        json!({"sessionId": a, "prompt": [{"type": "text", "text": "go on"}]}),
    )
    .await;
    assert!(held(&c.message(&a, &b, "x3", "something else entirely").await), "still paused");
    assert!(!c.ran(&b, "x2").await);
}

/// A message the agent's session refuses before it is recorded is no exchange: retrying it is
/// never what pauses the pair.
#[tokio::test]
async fn a_refused_message_is_not_counted() {
    let hub = hub();
    let mut c = Client::open(&hub);
    let (a, b) = (c.new_session().await, c.new_session().await);
    for i in 0..3 {
        // `steerOnly` into a session with no running turn: refused unrecorded.
        let reply = c
            .message_as(
                &format!("acp:{a}"),
                &b,
                &format!("f{i}"),
                "please check the build",
                json!({"steer": true, "steerOnly": true}),
            )
            .await;
        assert_eq!(
            reply.pointer("/error/data/reason"),
            Some(&json!("steer.unavailable")),
            "refusal {i}: {reply}"
        );
    }
    let reply = c.message(&a, &b, "f3", "please check the build").await;
    assert!(reply.get("error").is_none(), "{reply}");
}

/// What a pause held survives a daemon restart, and a resume then delivers it.
#[tokio::test]
async fn held_messages_survive_a_restart() {
    let dir = std::env::temp_dir().join(format!("acpmux-pairs-{}", uuid::Uuid::now_v7()));
    let hub = hub_in(Some(&dir));
    let mut c = Client::open(&hub);
    let (a, b) = (c.new_session().await, c.new_session().await);
    for i in 0..2 {
        c.message(&a, &b, &format!("h{i}"), "please check the build").await;
    }
    assert!(held(&c.message(&a, &b, "h2", "please check the build").await));
    hub.shutdown_all().await;
    drop(c);
    drop(hub);

    let hub = hub_in(Some(&dir));
    let mut c = Client::open(&hub);
    assert!(held(&c.message(&a, &b, "h3", "something else").await), "still paused");
    let mut person = Client::person(&hub).await;
    let resumed = person.call(RESUME, json!({"sessionId": b})).await;
    assert_eq!(resumed["delivered"], 2, "{resumed}");
    c.wait_ran(&b, "h2").await;
    c.wait_ran(&b, "h3").await;
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&dir);
}

/// While a resume delivers what a pair held, a new message in the pair waits behind it.
#[tokio::test]
async fn a_new_message_never_overtakes_held_ones() {
    let hub = hub();
    let mut c = Client::open(&hub);
    let (a, b) = (c.new_session().await, c.new_session().await);
    for i in 0..2 {
        c.message(&a, &b, &format!("o{i}"), "please check the build").await;
    }
    for (i, chatter) in CHATTER.iter().enumerate().take(6).skip(2) {
        let text = if i == 2 { "please check the build" } else { chatter };
        assert!(held(&c.message(&a, &b, &format!("o{i}"), text).await));
    }
    let mut person = Client::person(&hub).await;
    person.call(RESUME, json!({"sessionId": a})).await;
    c.message(&a, &b, "o6", "new after resume").await;
    c.wait_ran(&b, "o5").await;
    c.wait_ran(&b, "o6").await;
    let ids = c.ran_ids(&b).await;
    let at = |id: &str| ids.iter().position(|x| x == id).unwrap();
    assert!(at("o5") < at("o6"), "held first: {ids:?}");
}

/// The Debug Settings toggle off (`ACPMUX_AGENT_PAIR_GUARD=0`): nothing is paused.
#[tokio::test]
async fn the_guard_turned_off_pauses_nothing() {
    let hub = hub();
    hub.set_agent_pair_guard(acpmux::hub::PairGuard { enabled: false, ..Default::default() });
    let mut c = Client::open(&hub);
    let (a, b) = (c.new_session().await, c.new_session().await);
    for i in 0..12 {
        let (from, to) = if i % 2 == 0 { (&a, &b) } else { (&b, &a) };
        let reply = c.message(from, to, &format!("o{i}"), "same words again").await;
        assert!(reply.get("error").is_none(), "exchange {i} was delivered: {reply}");
    }
    assert!(c.records(&a, "agent_pair_paused").await.is_empty());
}

/// Resuming is the person's on this machine: a remote web client or a peer is refused.
#[tokio::test]
async fn a_remote_client_cannot_resume_a_pair() {
    let hub = hub();
    let mut c = Client::open(&hub);
    let a = c.new_session().await;
    for origin in [Origin::Web, Origin::Peer] {
        let mut remote = Client::open_as(&hub, origin);
        let reply = remote.reply(RESUME, json!({"sessionId": a})).await;
        assert!(reply.get("error").is_some(), "{origin:?}: {reply}");
    }
}

/// Sessions doing work are still paused past the cap: more than 20 messages within the window
/// with no prompt from the person. A person's prompt into either session starts the count over.
#[tokio::test]
async fn a_pair_past_the_cap_is_paused_until_the_person_steps_in() {
    let hub = hub();
    let mut c = Client::open(&hub);
    let (a, b) = (c.new_session().await, c.new_session().await);
    for i in 0..15 {
        let reply = work(&mut c, &a, &b, i).await;
        assert!(reply.get("error").is_none(), "message {i} was delivered: {reply}");
    }
    let mut person = Client::person(&hub).await;
    person
        .call(
            "session/prompt",
            json!({"sessionId": a, "prompt": [{"type": "text", "text": "carry on"}]}),
        )
        .await;
    for i in 15..35 {
        let reply = work(&mut c, &a, &b, i).await;
        assert!(
            reply.get("error").is_none(),
            "message {i} after the person was delivered: {reply}"
        );
    }
    let over = work(&mut c, &a, &b, 35).await;
    assert!(held(&over), "the 21st since the person is held: {over}");
    assert_eq!(over.pointer("/error/data/trip"), Some(&json!("cap")), "{over}");
    let paused = c.records(&a, "agent_pair_paused").await;
    assert_eq!(paused.len(), 1, "{paused:?}");
    assert_eq!(
        (paused[0]["reason"].clone(), paused[0]["count"].clone()),
        (json!("cap"), json!(21))
    );
    person.call(RESUME, json!({"sessionId": a})).await;
    c.wait_ran(&a, "c35").await;
}

/// Message `i` of a working pair, alternating: each turn makes a tool call.
async fn work(c: &mut Client, a: &str, b: &str, i: usize) -> Value {
    let (from, to) = if i.is_multiple_of(2) { (a, b) } else { (b, a) };
    c.message(from, to, &format!("c{i}"), &format!("do-work step {i}")).await
}

/// The cap set to 0 (`ACPMUX_AGENT_PAIR_MAX_MESSAGES=0`): working sessions are never paused.
#[tokio::test]
async fn a_cap_of_zero_pauses_nothing() {
    let hub = hub();
    hub.set_agent_pair_guard(acpmux::hub::PairGuard { max_messages: 0, ..Default::default() });
    let mut c = Client::open(&hub);
    let (a, b) = (c.new_session().await, c.new_session().await);
    for i in 0..25 {
        let (from, to) = if i % 2 == 0 { (&a, &b) } else { (&b, &a) };
        let reply = c.message(from, to, &format!("z{i}"), &format!("do-work step {i}")).await;
        assert!(reply.get("error").is_none(), "message {i} was delivered: {reply}");
    }
    assert!(c.records(&a, "agent_pair_paused").await.is_empty());
}

/// A steer-only message the receiver cannot take is refused as such, even when it would have
/// tripped the pair: a refused attempt never pauses anyone.
#[tokio::test]
async fn a_refused_attempt_never_pauses_the_pair() {
    let hub = hub();
    let mut c = Client::open(&hub);
    let (a, b) = (c.new_session().await, c.new_session().await);
    for i in 0..2 {
        c.message(&a, &b, &format!("s{i}"), "please check the build").await;
    }
    let steer = json!({"steer": true, "steerOnly": true});
    let reply = c.message_as(&format!("acp:{a}"), &b, "s2", "please check the build", steer).await;
    assert_eq!(reply.pointer("/error/data/reason"), Some(&json!("steer.unavailable")), "{reply}");
    assert!(c.records(&b, "agent_pair_paused").await.is_empty());
}

/// Messages held both ways come back from a restart in the order they were held, not grouped
/// by receiver.
#[tokio::test]
async fn held_messages_keep_their_order_across_a_restart() {
    let dir = std::env::temp_dir().join(format!("acpmux-pairs-{}", uuid::Uuid::now_v7()));
    let hub = hub_in(Some(&dir));
    let mut c = Client::open(&hub);
    let (a, b) = (c.new_session().await, c.new_session().await);
    for i in 0..2 {
        c.message(&a, &b, &format!("q{i}"), "please check the build").await;
    }
    assert!(held(&c.message(&a, &b, "q2", "please check the build").await));
    assert!(held(&c.message(&b, &a, "q3", "checking now").await));
    assert!(held(&c.message(&a, &b, "q4", "thanks").await));
    hub.shutdown_all().await;
    drop(c);
    drop(hub);

    let hub = hub_in(Some(&dir));
    let mut c = Client::open(&hub);
    let mut person = Client::person(&hub).await;
    let resumed = person.call(RESUME, json!({"sessionId": a})).await;
    assert_eq!(resumed["delivered"], 3, "{resumed}");
    c.wait_ran(&b, "q4").await;
    let mut released = Vec::new();
    for session in [&a, &b] {
        let page = c
            .call("_acpmux/events", json!({"sessionId": session, "kinds": ["agent_pair_released"]}))
            .await;
        for e in page["events"].as_array().unwrap() {
            released.push((
                e["at"].as_u64().unwrap(),
                e["msg"]["promptId"].as_str().unwrap().to_owned(),
            ));
        }
    }
    released.sort();
    let ids: Vec<&str> = released.iter().map(|(_, id)| id.as_str()).collect();
    assert_eq!(ids, ["q2", "q3", "q4"], "released in the order held");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&dir);
}

/// A parent and the sub-session it started, talking through cmux-subsessions `send_message`
/// (both ways) and `cmux agent message` (`agents_chat_send`): every exchange counts toward the
/// same pair, whichever path carried it. The tenth in a row with no progress is held, and
/// the person's resume delivers it to the parent.
#[tokio::test]
async fn a_sub_session_and_its_parent_messaging_through_send_message_are_paused() {
    let hub = hub();
    let mut c = Client::open(&hub);
    let parent = c.new_session().await;
    let mut p = Client::as_session(&hub, &parent).await;
    // `start_session`'s first prompt is the first exchange, parent to child.
    let child = p.call(SUBSESSION_START, json!({"prompt": CHATTER[0]})).await["sessionId"]
        .as_str()
        .unwrap()
        .to_owned();
    let mut k = Client::as_session(&hub, &child).await;
    for (i, text) in CHATTER.iter().enumerate().take(9).skip(1) {
        let reply = if i % 2 == 1 {
            c.message(&child, &parent, &format!("c{i}"), text).await
        } else {
            p.send_message(&child, &format!("c{i}"), text, false).await
        };
        assert!(reply.get("error").is_none(), "exchange {i} was delivered: {reply}");
    }
    // The tenth exchange in a row, the child's `send_message` to its parent, trips the guard.
    let tenth = k.send_message(&parent, "c9", CHATTER[9], false).await;
    assert!(held(&tenth), "the tenth exchange is held: {tenth}");
    assert!(!c.ran(&parent, "c9").await, "a held message does not run");
    for session in [&parent, &child] {
        let paused = c.records(session, "agent_pair_paused").await;
        assert_eq!(paused.len(), 1, "{session}: {paused:?}");
        assert_eq!(paused[0]["reason"], "alternating", "{paused:?}");
    }
    let held_records = c.records(&parent, "agent_pair_held").await;
    assert_eq!(held_records.len(), 1, "{held_records:?}");
    assert_eq!(held_records[0]["promptId"], "c9", "{held_records:?}");
    assert_eq!(held_records[0]["provenance"]["kind"], "subsession_message", "{held_records:?}");

    let mut person = Client::person(&hub).await;
    let resumed = person.call(RESUME, json!({"sessionId": child})).await;
    assert_eq!(resumed["delivered"], 1, "{resumed}");
    c.wait_ran(&parent, "c9").await;
    let ran = c.records(&parent, "user_message").await;
    let released = ran.iter().find(|m| m["promptId"] == "c9").unwrap();
    assert_eq!(released["_meta"]["provenance"]["kind"], "subsession_message", "{released}");
    // A resumed pair starts counting again.
    let after = p.send_message(&child, "c10", "thanks", false).await;
    assert!(after.get("error").is_none(), "{after}");
}

/// `send_message` with `interrupt` into a paused pair is held, and it stops nothing: the
/// child's running turn goes on, both for the message that trips the pair and for one sent
/// while it is paused.
#[tokio::test]
async fn a_held_send_message_with_interrupt_does_not_stop_the_receivers_turn() {
    let hub = hub();
    let mut c = Client::open(&hub);
    let parent = c.new_session().await;
    let mut p = Client::as_session(&hub, &parent).await;
    let child = p.call(SUBSESSION_START, json!({"prompt": "until-cancel"})).await["sessionId"]
        .as_str()
        .unwrap()
        .to_owned();
    let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
    while c.records(&child, "turn_started").await.is_empty() {
        assert!(tokio::time::Instant::now() < deadline, "the child's turn never started");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    for i in 1..3 {
        let reply = p.send_message(&child, &format!("i{i}"), "please check the build", false).await;
        assert!(reply.get("error").is_none(), "message {i} was queued: {reply}");
    }
    // The third near-identical message trips the pair; the fourth finds it paused.
    for id in ["i3", "i4"] {
        let reply = p.send_message(&child, id, "please check the build", true).await;
        assert!(held(&reply), "{id} is held: {reply}");
    }
    tokio::time::sleep(Duration::from_millis(1500)).await;
    let ended = c.records(&child, "turn_result").await;
    assert!(ended.is_empty(), "a held interrupt stopped the child's turn: {ended:?}");
    assert!(!c.ran(&child, "i1").await, "the queued messages still wait behind the turn");
}

/// A daemon that stops after the person resumed a pair but before it delivered what the pair
/// held: the next daemon keeps delivering it, in order, without another resume and without
/// pausing the pair again behind a transcript that already reads "resumed".
#[tokio::test]
async fn a_restart_during_a_resume_keeps_delivering_what_was_held() {
    let dir = std::env::temp_dir().join(format!("acpmux-pairs-{}", uuid::Uuid::now_v7()));
    let hub = hub_in(Some(&dir));
    let mut c = Client::open(&hub);
    let (a, b) = (c.new_session().await, c.new_session().await);
    for i in 0..2 {
        c.message(&a, &b, &format!("d{i}"), "please check the build").await;
    }
    assert!(held(&c.message(&a, &b, "d2", "please check the build").await));
    assert!(held(&c.message(&a, &b, "d3", "something else").await));
    hub.shutdown_all().await;
    drop(c);
    drop(hub);

    // The resume's records, as the stopped daemon wrote them before its first delivery.
    let store = acpmux::store::open(&config(Some(&dir)).store, &dir).unwrap();
    for (session, peer) in [(&b, &a), (&a, &b)] {
        let last = store.events(session, 0, usize::MAX).unwrap().last().map_or(0, |r| r.seq);
        let record = acpmux::store::EventRecord {
            seq: last + 1,
            at: acpmux::store::now_ms(),
            dir: "mux".into(),
            kind: "agent_pair_resumed".into(),
            msg: json!({"peer": peer, "by": "request", "delivered": 2}),
            host_seq: None,
        };
        store.append(session, &record).unwrap();
    }
    store.flush().unwrap();
    drop(store);

    let hub = hub_in(Some(&dir));
    hub.resume_queues();
    let mut c = Client::open(&hub);
    c.wait_ran(&b, "d2").await;
    c.wait_ran(&b, "d3").await;
    let ids = c.ran_ids(&b).await;
    let at = |id: &str| ids.iter().position(|x| x == id).unwrap();
    assert!(at("d2") < at("d3"), "in order: {ids:?}");
    assert_eq!(c.records(&b, "agent_pair_paused").await.len(), 1, "not paused again");
    // Delivered, the pair starts over.
    let after = c.message(&a, &b, "d4", "new after the restart").await;
    assert!(after.get("error").is_none(), "{after}");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&dir);
}

/// `peerSessionId` only picks one of the named session's pairs: a resume naming a session that
/// is not in the paused pair resumes nothing, whichever peer it names.
#[tokio::test]
async fn a_resume_acts_only_on_the_named_sessions_pairs() {
    let hub = hub();
    let mut c = Client::open(&hub);
    let (a, b, other) = (c.new_session().await, c.new_session().await, c.new_session().await);
    for i in 0..2 {
        c.message(&a, &b, &format!("p{i}"), "please check the build").await;
    }
    assert!(held(&c.message(&a, &b, "p2", "please check the build").await));
    let mut person = Client::person(&hub).await;
    for peer in [&a, &b] {
        let resumed = person.call(RESUME, json!({"sessionId": other, "peerSessionId": peer})).await;
        assert_eq!(resumed["resumed"], 0, "{resumed}");
    }
    assert!(held(&c.message(&a, &b, "p3", "something else").await), "still paused");
    assert!(!c.ran(&b, "p2").await);
    // The pair's own session with its peer resumes it.
    let resumed = person.call(RESUME, json!({"sessionId": b, "peerSessionId": a})).await;
    assert_eq!(resumed["resumed"], 1, "{resumed}");
    c.wait_ran(&b, "p2").await;
}

/// `acpmux send` run inside a session (its caller token, no provenance of its own) is that
/// session's message (`session_message`), so a lane repeating itself to another is paused too.
#[tokio::test]
async fn a_session_repeating_itself_with_acpmux_send_is_paused() {
    let hub = hub();
    let mut c = Client::open(&hub);
    let (a, b) = (c.new_session().await, c.new_session().await);
    let mut lane = Client::as_session(&hub, &a).await;
    let send = |id: &str, text: &str| {
        json!({"sessionId": &b, "prompt": [{"type": "text", "text": text}],
               "_meta": {"acpmux": {"promptId": id}}})
    };
    let first = lane.reply("session/prompt", send("s1", "Please check the build, run 1")).await;
    assert!(first.get("error").is_none(), "{first}");
    let second = lane.reply("session/prompt", send("s2", "please  check the BUILD, run 2")).await;
    assert!(second.get("error").is_none(), "{second}");
    let third = lane.reply("session/prompt", send("s3", "Please check the build, run 3")).await;
    assert!(held(&third), "the third near-identical message is held: {third}");
    assert!(!c.ran(&b, "s3").await, "a held message does not run");
}

/// After a restart that reads the chat logs lazily, a pause the restart keeps holds both ways
/// even when only the sender's log has it: the message `a` sent was held for `b`, in `b`'s log,
/// and `b`'s reply to `a` reads `a`'s log for its delivery. The sender's log is read too.
#[tokio::test]
async fn a_lazy_restart_keeps_a_pause_only_the_senders_log_holds() {
    let dir = std::env::temp_dir().join(format!("acpmux-pairs-{}", uuid::Uuid::now_v7()));
    let hub = hub_in(Some(&dir));
    let mut c = Client::open(&hub);
    let (a, b) = (c.new_session().await, c.new_session().await);
    for i in 0..2 {
        c.message(&a, &b, &format!("l{i}"), "please check the build").await;
    }
    assert!(held(&c.message(&a, &b, "l2", "please check the build").await));
    hub.shutdown_all().await;
    drop(c);
    drop(hub);

    let hub = deferred_hub_in(&dir);
    let mut c = Client::open(&hub);
    let reply = c.message(&b, &a, "l3", "checking now").await;
    assert!(held(&reply), "the pair is still paused: {reply}");
    hub.load_logs_async().await;
    let mut person = Client::person(&hub).await;
    let resumed = person.call(RESUME, json!({"sessionId": a})).await;
    assert_eq!(resumed["delivered"], 2, "{resumed}");
    c.wait_ran(&b, "l2").await;
    c.wait_ran(&a, "l3").await;
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&dir);
}

/// A pair the person resumed before a restart, holding messages both ways: after a lazy
/// restart, reading one side's log first still delivers all of them in the order they were
/// held, the other side's included.
#[tokio::test]
async fn a_lazy_restart_drains_both_sides_in_the_order_held() {
    let dir = std::env::temp_dir().join(format!("acpmux-pairs-{}", uuid::Uuid::now_v7()));
    let hub = hub_in(Some(&dir));
    let mut c = Client::open(&hub);
    let (a, b) = (c.new_session().await, c.new_session().await);
    for i in 0..2 {
        c.message(&a, &b, &format!("w{i}"), "please check the build").await;
    }
    assert!(held(&c.message(&a, &b, "w2", "please check the build").await));
    assert!(held(&c.message(&b, &a, "w3", "checking now").await));
    assert!(held(&c.message(&a, &b, "w4", "thanks").await));
    hub.shutdown_all().await;
    drop(c);
    drop(hub);

    // The resume's records, as the stopped daemon wrote them before its first delivery.
    let store = acpmux::store::open(&config(Some(&dir)).store, &dir).unwrap();
    for (session, peer) in [(&b, &a), (&a, &b)] {
        let last = store.events(session, 0, usize::MAX).unwrap().last().map_or(0, |r| r.seq);
        let record = acpmux::store::EventRecord {
            seq: last + 1,
            at: acpmux::store::now_ms(),
            dir: "mux".into(),
            kind: "agent_pair_resumed".into(),
            msg: json!({"peer": peer, "by": "request", "delivered": 3}),
            host_seq: None,
        };
        store.append(session, &record).unwrap();
    }
    store.flush().unwrap();
    drop(store);

    let hub = deferred_hub_in(&dir);
    hub.resume_queues();
    let mut c = Client::open(&hub);
    // Only `b`'s log is asked for.
    c.call("_acpmux/info", json!({"sessionId": b})).await;
    c.wait_ran(&b, "w4").await;
    c.wait_ran(&a, "w3").await;
    let page = |s: &str| json!({"sessionId": s, "kinds": ["agent_pair_released"]});
    let mut at = Vec::new();
    for session in [&a, &b] {
        let events = c.call("_acpmux/events", page(session)).await;
        for e in events["events"].as_array().unwrap() {
            at.push((e["at"].as_u64().unwrap(), e["msg"]["promptId"].as_str().unwrap().to_owned()));
        }
    }
    at.sort();
    let ids: Vec<&str> = at.iter().map(|(_, id)| id.as_str()).collect();
    assert_eq!(ids, ["w2", "w3", "w4"], "released in the order held");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&dir);
}

/// After a lazy restart, the person's prompt into `a` resumes a pause whose held messages are
/// only in the peer's log (`a`'s messages held for `b`): `b`'s log is read first, the resume is
/// written to both logs (it holds across another restart), and the held messages run, the
/// oldest first even though `a`'s own log holds a newer one (`b` to `a`).
#[tokio::test]
async fn a_lazy_restart_resumes_a_pause_the_person_prompts_from_either_side_in_order() {
    let dir = std::env::temp_dir().join(format!("acpmux-pairs-{}", uuid::Uuid::now_v7()));
    let hub = hub_in(Some(&dir));
    let mut c = Client::open(&hub);
    let (a, b) = (c.new_session().await, c.new_session().await);
    for i in 0..2 {
        c.message(&a, &b, &format!("v{i}"), "please check the build").await;
    }
    assert!(held(&c.message(&a, &b, "v2", "please check the build").await));
    assert!(held(&c.message(&b, &a, "v3", "checking now").await));
    hub.shutdown_all().await;
    drop(c);
    drop(hub);

    let hub = deferred_hub_in(&dir);
    let mut person = Client::person(&hub).await;
    person
        .call(
            "session/prompt",
            json!({"sessionId": a, "prompt": [{"type": "text", "text": "carry on"}]}),
        )
        .await;
    let mut c = Client::open(&hub);
    c.wait_ran(&b, "v2").await;
    c.wait_ran(&a, "v3").await;
    assert_eq!(c.records(&b, "agent_pair_resumed").await.len(), 1, "the resume is in b's log");
    let page = |s: &str| json!({"sessionId": s, "kinds": ["agent_pair_released"]});
    let mut at = Vec::new();
    for session in [&a, &b] {
        let events = c.call("_acpmux/events", page(session)).await;
        for e in events["events"].as_array().unwrap() {
            at.push((e["at"].as_u64().unwrap(), e["msg"]["promptId"].as_str().unwrap().to_owned()));
        }
    }
    at.sort();
    let ids: Vec<&str> = at.iter().map(|(_, id)| id.as_str()).collect();
    assert_eq!(ids, ["v2", "v3"], "released in the order held");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&dir);
}

/// `session`'s queue row for `prompt_id`, once it waits there.
async fn queued_row(c: &mut Client, session: &str, prompt_id: &str) -> Value {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
    loop {
        let attached = c.call("_acpmux/attach", json!({"sessionId": session, "limit": 0})).await;
        let rows = attached["session"]["queue"].as_array().cloned().unwrap_or_default();
        if let Some(row) = rows.into_iter().find(|q| q["promptId"] == prompt_id) {
            return row;
        }
        assert!(tokio::time::Instant::now() < deadline, "{prompt_id} never queued: {attached}");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

/// A message another session sent (`acpmux send` from inside it: `session_message`) that a
/// paused pair held and a resume released is still that session's message, with the class it was
/// sent with (`prompt_class.rs`): its queue row behind the receiver's running turn says both.
#[tokio::test]
async fn a_released_message_keeps_its_sender_and_its_class() {
    let hub = hub();
    let mut c = Client::open(&hub);
    let (a, b) = (c.new_session().await, c.new_session().await);
    let sender = hub.resolve(&a).unwrap().meta().name;
    let mut from_a = Client::as_session(&hub, &a).await;
    let send = |id: &str, run: u32, class: Option<&str>| {
        let mut mux = json!({"promptId": id});
        if let Some(class) = class {
            mux["class"] = json!(class);
        }
        let text = format!("Please check the build, run {run}");
        json!({"sessionId": b, "prompt": [{"type": "text", "text": text}], "_meta": {"acpmux": mux}})
    };
    for run in 1..=2 {
        let sent = from_a.reply("session/prompt", send(&format!("k{run}"), run, None)).await;
        assert!(sent.get("error").is_none(), "{sent}");
    }
    let third = from_a.reply("session/prompt", send("k3", 3, Some("block"))).await;
    assert!(held(&third), "the third near-identical message is held: {third}");

    // The receiver busy with a turn that is not the person's (it resumes nothing), so the
    // released message waits in its queue.
    let busy = json!({"sessionId": b, "prompt": [{"type": "text", "text": "until-cancel"}],
                      "_meta": {"acpmux": {"promptId": "k-busy"}}});
    c.0.send(Message::request(9_999, "session/prompt", busy).to_line()).await.unwrap();
    c.wait_ran(&b, "k-busy").await;
    let mut person = Client::person(&hub).await;
    let resumed = person.call(RESUME, json!({"sessionId": b})).await;
    assert_eq!(resumed["delivered"], 1, "{resumed}");

    let row = queued_row(&mut c, &b, "k3").await;
    assert_eq!(row["fromAgent"], sender.as_str(), "{row}");
    assert_eq!(row["class"], "block", "{row}");
    c.0.send(Message::notification("session/cancel", json!({"sessionId": b})).to_line())
        .await
        .unwrap();
}

const HOLD: &str = "_acpmux/agent_hold";

/// The person takes over a chat a Chief started (`mux.parent`): the Chief turn's messages to it
/// are held (reason `taken_over`), the person's own prompts into it run and release nothing,
/// another agent's message passes, a manager cannot lift the hold with `_acpmux/tag`, and Hand
/// back delivers what was held, in order.
#[tokio::test]
async fn a_taken_over_chat_holds_its_managers_messages_until_handed_back() {
    let hub = hub();
    let mut c = Client::open(&hub);
    let (chief, kid, other) = (c.new_session().await, c.new_session().await, c.new_session().await);
    c.call("_acpmux/tag", json!({"sessionId": chief, "set": {"cmux.chief": "home1"}})).await;
    c.call("_acpmux/tag", json!({"sessionId": kid, "set": {"mux.parent": "optchat-chief:home1"}}))
        .await;

    // Before Take over, the Chief's message goes in.
    let before = c.message(&chief, &kid, "c0", "start on the tests").await;
    assert!(before.get("error").is_none(), "{before}");

    // Only the person takes a chat over.
    let refused = c.reply(HOLD, json!({"sessionId": kid, "held": true})).await;
    assert!(refused.get("error").is_some(), "an agent's connection may not take over: {refused}");
    let mut person = Client::person(&hub).await;
    let took = person.call(HOLD, json!({"sessionId": kid, "held": true})).await;
    assert_eq!(took["held"], true, "{took}");

    // The Chief's next messages are held, with the reason.
    let first = c.message(&chief, &kid, "c1", "also fix the lint").await;
    assert!(held(&first), "{first}");
    assert_eq!(first.pointer("/error/data/trip"), Some(&json!("taken_over")), "{first}");
    let second = c.message(&chief, &kid, "c2", "and update the docs").await;
    assert!(held(&second), "{second}");
    assert!(!c.ran(&kid, "c1").await && !c.ran(&kid, "c2").await);
    let paused = c.records(&kid, "agent_pair_paused").await;
    assert_eq!(paused.last().unwrap()["reason"], "taken_over", "{paused:?}");

    // Another agent that does not manage the chat still reaches it.
    let passes = c.message(&other, &kid, "o1", "fyi the base is green").await;
    assert!(passes.get("error").is_none(), "{passes}");

    // The person's own prompt runs and releases nothing.
    let mine = person
        .reply("session/prompt", json!({"sessionId": kid, "prompt": [{"type": "text", "text": "I'll take it from here"}]}))
        .await;
    assert!(mine.get("error").is_none(), "{mine}");
    assert!(!c.ran(&kid, "c1").await, "a person prompt does not release a taken-over chat's hold");

    // The manager cannot lift the hold through tags.
    let lift = c.reply("_acpmux/tag", json!({"sessionId": kid, "remove": ["acpmux.agentHold"]})).await;
    assert!(lift.get("error").is_some(), "{lift}");
    let after_lift = c.message(&chief, &kid, "c3", "ok continuing").await;
    assert!(held(&after_lift), "{after_lift}");

    // Hand back delivers what was held, in order.
    let back = person.call(HOLD, json!({"sessionId": kid, "held": false})).await;
    assert_eq!(back["held"], false, "{back}");
    assert_eq!(back["delivered"], 3, "{back}");
    c.wait_ran(&kid, "c3").await;
    let ran = c.ran_ids(&kid).await;
    let order: Vec<&str> =
        ran.iter().map(String::as_str).filter(|id| ["c1", "c2", "c3"].contains(id)).collect();
    assert_eq!(order, ["c1", "c2", "c3"], "{ran:?}");

    // Once handed back, the Chief's messages go in again.
    let later = c.message(&chief, &kid, "c4", "thanks").await;
    assert!(later.get("error").is_none(), "{later}");
}

/// A Chief of another home does not manage the chat: its message passes a hold.
#[tokio::test]
async fn another_chiefs_turn_is_not_the_manager() {
    let hub = hub();
    let mut c = Client::open(&hub);
    let (chief, kid) = (c.new_session().await, c.new_session().await);
    c.call("_acpmux/tag", json!({"sessionId": chief, "set": {"cmux.chief": "home2"}})).await;
    c.call("_acpmux/tag", json!({"sessionId": kid, "set": {"mux.parent": "optchat-chief:home1"}}))
        .await;
    let mut person = Client::person(&hub).await;
    // The person gives the chat its first work, so the other Chief is not its delegator either.
    let first = person
        .reply("session/prompt", json!({"sessionId": kid, "prompt": [{"type": "text", "text": "start"}]}))
        .await;
    assert!(first.get("error").is_none(), "{first}");
    person.call(HOLD, json!({"sessionId": kid, "held": true})).await;
    let reply = c.message(&chief, &kid, "x1", "hello").await;
    assert!(reply.get("error").is_none(), "{reply}");
}
