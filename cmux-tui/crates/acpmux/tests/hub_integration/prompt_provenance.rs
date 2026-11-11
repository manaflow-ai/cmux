//! A prompt's provenance at the daemon boundary (cx-55d27): `_meta.acpmux.provenance` on
//! `session/prompt` names the agent that sent it (`cmux agent message`). The recorded
//! `user_message` carries it as `_meta.provenance`, a queued prompt keeps it until it runs, a
//! steer records it, and an edit of the waiting prompt drops it. Only the unix socket may
//! send it. The app pane's reply in place is no prompt: `_acpmux/app_reply` checks it (from a
//! chat this connection shows, to the chat that sent it the message `replyTo` names) and answers
//! it signed, and the app sends it as that chat's cmux agent message (`server/app_reply.rs`;
//! cmux-tui tests/agent_message_reply_in_place.rs covers the daemon side).
//! A prompt from inside another session that names none gets that session as its sender
//! (`session_message`). One that names its sender (`fromAgent`: `--from`, `ACPMUX_FROM`, a peer
//! daemon's forwarded caller) records it as that agent's message.
//! A person's prompt (`_meta.acpmux.author`, chat multiplayer) records `person_message`, and only
//! that person changes it while it waits (`queue.not_author`).

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::Message;
use acpmux::server::{ConnAuth, Origin, serve_connection_authed, serve_connection_with};
use serde_json::{Value, json};
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

pub(super) fn hub_env(env: Value) -> Arc<Hub> {
    hub_policy(env, "approve-all")
}

fn hub_policy(env: Value, policy: &str) -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE], "family": "codex", "env": env}},
        "defaultHarness": "fake",
        "permissionPolicy": policy
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    // The queue path before the inbox (`hub/inbox.rs`), which these tests cover.
    cfg.agent_inbox = Some(false);
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

pub(super) fn hub() -> Arc<Hub> {
    hub_env(json!({}))
}

/// What `cmux agent message` sends with a message to session `to`.
fn provenance(to: &str) -> Value {
    json!({"kind": "agent_message", "from": "acp:sender-1", "fromName": "builder", "to": format!("acp:{to}"),
           "msgId": "msg-1", "threadId": "thread-1", "replyTo": "msg-0"})
}

/// `p` as the daemon records it (`prompt_provenance.rs`): how it came, `verified` false unless
/// the daemon set it, and a peer's forward named beside the sender.
pub(super) fn seen(mut p: Value, transport: &str) -> Value {
    let fields = p.as_object_mut().unwrap();
    fields.entry("verified").or_insert(json!(false));
    fields.insert("transport".into(), json!(transport));
    if transport == "peer" {
        fields.insert("forwardedBy".into(), json!({"actor": "peer"}));
    }
    p
}

pub(super) fn prompt(
    session: &str,
    prompt_id: &str,
    text: &str,
    provenance: Option<&Value>,
) -> Value {
    let mut mux = json!({"promptId": prompt_id});
    if let Some(p) = provenance {
        mux["provenance"] = p.clone();
    }
    json!({"sessionId": session, "prompt": [{"type": "text", "text": text}], "_meta": {"acpmux": mux}})
}

pub(super) struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

impl Client {
    pub(super) fn open(hub: &Arc<Hub>) -> Self {
        Self::open_as(hub, Origin::Local)
    }

    fn open_as(hub: &Arc<Hub>, origin: Origin) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, origin));
        Self(in_tx, out_rx, 0)
    }

    /// A connection with the proof its transport checked (`serve_connection_authed`).
    fn open_authed(hub: &Arc<Hub>, origin: Origin, auth: ConnAuth) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_authed(hub.clone(), in_rx, out_tx, origin, auth));
        Self(in_tx, out_rx, 0)
    }

    /// Sends a request without waiting for its reply; returns its id.
    pub(super) async fn send(&mut self, method: &str, params: Value) -> i64 {
        self.2 += 1;
        self.0.send(Message::request(self.2, method, params).to_line()).await.unwrap();
        self.2
    }

    /// The first message that matches `pred`; every other one is dropped.
    pub(super) async fn until(&mut self, pred: impl Fn(&Value) -> bool) -> Value {
        loop {
            let line = tokio::time::timeout(Duration::from_secs(30), self.1.recv())
                .await
                .expect("timed out")
                .expect("connection closed");
            let value: Value = serde_json::from_str(&line).unwrap();
            if pred(&value) {
                return value;
            }
        }
    }

    /// The raw reply to request `id` (an error is returned, not asserted).
    pub(super) async fn reply_to(&mut self, id: i64) -> Value {
        self.until(|v| v.get("id") == Some(&json!(id))).await
    }

    pub(super) async fn reply(&mut self, method: &str, params: Value) -> Value {
        let id = self.send(method, params).await;
        self.reply_to(id).await
    }

    pub(super) async fn call(&mut self, method: &str, params: Value) -> Value {
        let value = self.reply(method, params).await;
        assert!(value.get("error").is_none(), "{method}: {value}");
        value["result"].clone()
    }

    pub(super) async fn new_session(&mut self, mux: Value) -> String {
        let created = self
            .call(
                "session/new",
                json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": mux}}),
            )
            .await;
        created["sessionId"].as_str().unwrap().to_owned()
    }

    /// The session's records of `kind`, oldest first (their `msg`).
    pub(super) async fn records(&mut self, session: &str, kind: &str) -> Vec<Value> {
        let page =
            self.call("_acpmux/events", json!({"sessionId": session, "kinds": [kind]})).await;
        page["events"].as_array().unwrap().iter().map(|e| e["msg"].clone()).collect()
    }

    pub(super) async fn user_message(&mut self, session: &str, prompt_id: &str) -> Value {
        let found = self.records(session, "user_message").await;
        found.into_iter().find(|m| m["promptId"] == prompt_id).expect("its user_message")
    }

    /// Starts an "until-cancel" turn and waits until it runs.
    pub(super) async fn busy(&mut self, session: &str) {
        self.send("session/prompt", prompt(session, "p-run", "until-cancel", None)).await;
        self.until(|v| v.pointer("/params/update/content/text") == Some(&json!("running"))).await;
    }

    /// Queues a prompt behind the running turn; returns its request id.
    pub(super) async fn queue(&mut self, params: Value) -> i64 {
        let prompt_id = params["_meta"]["acpmux"]["promptId"].clone();
        let id = self.send("session/prompt", params).await;
        self.until(|v| {
            v["method"] == "_acpmux/prompt_accepted"
                && v["params"]["promptId"] == prompt_id
                && v["params"]["queued"] == true
        })
        .await;
        id
    }

    pub(super) async fn cancel(&mut self, session: &str) {
        let note = Message::notification("session/cancel", json!({"sessionId": session}));
        self.0.send(note.to_line()).await.unwrap();
    }
}

#[tokio::test]
async fn a_local_prompt_records_its_provenance_on_its_user_message() {
    let hub = hub();
    let mut c = Client::open(&hub);
    let session = c.new_session(json!({"harness": "fake"})).await;
    let p = provenance(&session);
    // A field acpmux does not know is not recorded.
    let mut sent = p.clone();
    sent["extra"] = json!("dropped");
    c.call("session/prompt", prompt(&session, "p-a", "hello from builder", Some(&sent))).await;
    c.call("session/prompt", prompt(&session, "p-b", "the person's own words", None)).await;

    let first = c.user_message(&session, "p-a").await;
    assert_eq!(first["text"], "hello from builder", "{first}");
    assert_eq!(first.pointer("/_meta/provenance"), Some(&seen(p.clone(), "unix")), "{first}");
    // The owner's own terminal send (a plain unix client claiming no sender, harness or relay)
    // is the person's prompt, as before #37497 (`requests.rs` `owner_terminal`).
    let second = c.user_message(&session, "p-b").await;
    assert_eq!(second.pointer("/_meta/provenance"), None, "{second}");
    assert_eq!(second.pointer("/_meta/origin/actor"), Some(&json!("person")), "{second}");
}

/// The owner's own `acpmux send` from a plain terminal of their machine is
/// their prompt, drawn as their bubble (regression of #37497, manaflow-ai/cmux#37497 comment
/// 6716711734: it drew as "Unverified sender"). Only what the daemon checks or the CLI declares
/// tells an agent from them (`requests.rs` `owner_terminal`): a harness claim, a named sender, a
/// relay label, a caller token proven or not, or the app's transport without its proof each keep
/// the prompt off the person.
#[tokio::test]
async fn the_owners_plain_terminal_send_is_theirs_and_every_claim_keeps_one_off_them() {
    let hub = hub();
    let mut owner = Client::open(&hub);
    let receiver = owner.new_session(json!({"harness": "fake"})).await;
    let sender = owner.new_session(json!({"harness": "fake"})).await;
    let with = |id: &str, fields: Value| {
        let mut p = prompt(&receiver, id, "ship it", None);
        for (key, value) in fields.as_object().unwrap() {
            p["_meta"]["acpmux"][key] = value.clone();
        }
        p
    };
    // What `acpmux send` stamps at a plain shell: only the machine it ran on.
    owner.call("session/prompt", with("p-owner", json!({"cliHost": "my-mac"}))).await;
    // An agent harness's shell (`cli/sender.rs`): its name and harness, or the harness alone.
    let named = json!({"fromAgent": "Claude Code on my-mac", "fromHarness": "claude"});
    owner.call("session/prompt", with("p-named", named)).await;
    owner.call("session/prompt", with("p-harness", json!({"fromHarness": "codex"}))).await;
    // A send whose process chain shows a harness but names no one (`sender_harness.rs`).
    let found = json!({"senderHarness": {"harness": "claude-code", "source": "process"}});
    owner.call("session/prompt", with("p-chain", found)).await;
    // A relay's label: it passes on another client's prompt (`remote_guard::mark_forwarded`).
    owner.call("session/prompt", with("p-via", json!({"via": "device"}))).await;
    // A caller token the daemon could not prove: an agent's shell that kept a stale token.
    let mut stale = Client::open(&hub);
    let caller = json!({"callerSession": {"sessionId": sender, "token": "not-its-token"}});
    stale.call("initialize", json!({"protocolVersion": 1, "_meta": {"acpmux": caller}})).await;
    stale.call("session/prompt", with("p-stale", json!({}))).await;
    // The app's own transport without the person's proof.
    let mut app = Client::open_as(&hub, Origin::LocalApp);
    app.call("session/prompt", with("p-app", json!({}))).await;
    // A proven session's send.
    let mut lane = open_in_session(&hub, &sender).await;
    lane.call("session/prompt", with("p-lane", json!({}))).await;

    let mine = owner.user_message(&receiver, "p-owner").await;
    assert_eq!(mine.pointer("/_meta/provenance"), None, "{mine}");
    assert_eq!(mine.pointer("/_meta/origin/actor"), Some(&json!("person")), "{mine}");
    let client = mine["client"].as_str().unwrap();
    assert!(client.ends_with("@my-mac"), "{mine}");

    let named = owner.user_message(&receiver, "p-named").await;
    assert_eq!(named.pointer("/_meta/provenance/kind"), Some(&json!("agent_message")), "{named}");
    assert_eq!(named.pointer("/_meta/provenance/verified"), Some(&json!(false)), "{named}");
    for (id, transport) in [
        ("p-harness", "unix"),
        ("p-chain", "unix"),
        ("p-via", "unix"),
        ("p-stale", "unix"),
        ("p-app", "app"),
    ] {
        let message = owner.user_message(&receiver, id).await;
        assert_eq!(
            message.pointer("/_meta/provenance/kind"),
            Some(&json!("unverified")),
            "{id}: {message}"
        );
        assert_eq!(
            message.pointer("/_meta/provenance/transport"),
            Some(&json!(transport)),
            "{id}: {message}"
        );
        assert_eq!(message.pointer("/_meta/origin"), None, "{id}: {message}");
    }
    let harness = owner.user_message(&receiver, "p-harness").await;
    assert_eq!(
        harness.pointer("/_meta/provenance/claimed/fromHarness"),
        Some(&json!("codex")),
        "{harness}"
    );
    let from_lane = owner.user_message(&receiver, "p-lane").await;
    assert_eq!(
        from_lane.pointer("/_meta/provenance/kind"),
        Some(&json!("session_message")),
        "{from_lane}"
    );
    assert_eq!(from_lane.pointer("/_meta/provenance/verified"), Some(&json!(true)), "{from_lane}");
}

/// A send the daemon keeps and delivers later (`_acpmux/send_queue`, the CLI's `--no-wait` and
/// retry path) is replayed on the outbox's own fresh unix connection (`server/outbox.rs`
/// `attempt_once`). What kept the prompt off the owner at send time goes with it: a caller token
/// the daemon could not prove (an agent's shell holding a stale session's token) stays unproven
/// on replay, and a harness claim stays in the request (manaflow-ai/cmux#38260 F1). The owner's
/// own queued send is still theirs.
#[tokio::test]
async fn a_queued_send_keeps_what_kept_it_off_the_owner_through_delivery() {
    let hub = hub();
    let mut owner = Client::open(&hub);
    let receiver = owner.new_session(json!({"harness": "fake"})).await;
    let sender = owner.new_session(json!({"harness": "fake"})).await;
    let queued = |id: &str, fields: Value| {
        let mut p = prompt(&receiver, id, "ship it", None);
        for (key, value) in fields.as_object().unwrap() {
            p["_meta"]["acpmux"][key] = value.clone();
        }
        json!({"request": p})
    };
    async fn delivered(c: &mut Client, queued: Value) {
        let ack = c.call("_acpmux/send_queue", queued).await;
        let delivery = ack["deliveryId"].as_str().expect("a delivery id").to_owned();
        let status =
            c.call("_acpmux/send_status", json!({"deliveryId": delivery, "waitMs": 20000})).await;
        assert_eq!(status["status"], "delivered", "{status}");
    }
    // Delivered means the receiver took the prompt; its turn (and so its user_message) may start a
    // moment later, behind the one before it.
    async fn recorded(c: &mut Client, session: &str, id: &str) -> Value {
        let deadline = std::time::Instant::now() + Duration::from_secs(10);
        loop {
            let found = c.records(session, "user_message").await;
            if let Some(message) = found.into_iter().find(|m| m["promptId"] == id) {
                return message;
            }
            assert!(std::time::Instant::now() < deadline, "{id}: no user_message within 10 s");
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
    }
    let mut stale = Client::open(&hub);
    let caller = json!({"callerSession": {"sessionId": sender, "token": "not-its-token"}});
    stale.call("initialize", json!({"protocolVersion": 1, "_meta": {"acpmux": caller}})).await;
    delivered(&mut stale, queued("p-queued-stale", json!({}))).await;
    delivered(&mut owner, queued("p-queued-harness", json!({"fromHarness": "codex"}))).await;
    delivered(&mut owner, queued("p-queued-owner", json!({"cliHost": "my-mac"}))).await;

    for id in ["p-queued-stale", "p-queued-harness"] {
        let message = recorded(&mut owner, &receiver, id).await;
        assert_eq!(
            message.pointer("/_meta/provenance/kind"),
            Some(&json!("unverified")),
            "{id}: {message}"
        );
        assert_eq!(message.pointer("/_meta/origin"), None, "{id}: {message}");
    }
    let mine = recorded(&mut owner, &receiver, "p-queued-owner").await;
    assert_eq!(mine.pointer("/_meta/provenance"), None, "{mine}");
    assert_eq!(mine.pointer("/_meta/origin/actor"), Some(&json!("person")), "{mine}");
}

/// A send the daemon delivers whose target already holds that prompt id in its queue (the first
/// attempt's acceptance never reached the sender: a cut link, an attempt that timed out) is
/// delivered: the resend hears the turn the queued prompt was given. A notice that named no turn
/// read as "may yet be refused" (`server/outbox.rs` `attempt_once`), so every attempt waited out
/// its two minutes until the queued prompt's own turn ended, and the delivery failed after a day.
#[tokio::test]
async fn a_queued_send_of_a_prompt_its_target_already_queued_is_delivered() {
    let hub = hub();
    let mut c = Client::open(&hub);
    let receiver = c.new_session(json!({"harness": "fake"})).await;
    c.busy(&receiver).await;
    let first = prompt(&receiver, "p-again", "ship it", None);
    c.send("session/prompt", first.clone()).await;
    let queued = c
        .until(|v| v["method"] == "_acpmux/prompt_accepted" && v["params"]["promptId"] == "p-again")
        .await;
    assert_eq!(queued["params"]["queued"], true, "{queued}");

    let ack = c.call("_acpmux/send_queue", json!({"request": first})).await;
    let delivery = ack["deliveryId"].as_str().expect("a delivery id").to_owned();
    let status =
        c.call("_acpmux/send_status", json!({"deliveryId": delivery, "waitMs": 10000})).await;
    let queue = hub.session_summary(&hub.resolve(&receiver).unwrap())["queue"].clone();
    c.cancel(&receiver).await;
    assert_eq!(status["status"], "delivered", "{status}");
    assert_eq!(queue.as_array().map(Vec::len), Some(1), "the resend queued a second copy: {queue}");
}

/// The same for the turn that runs: a resend of the running turn's own prompt id names that turn.
#[tokio::test]
async fn a_resend_of_the_running_turns_prompt_names_its_turn() {
    let hub = hub();
    let mut c = Client::open(&hub);
    let receiver = c.new_session(json!({"harness": "fake"})).await;
    let running = prompt(&receiver, "p-run", "until-cancel", None);
    c.send("session/prompt", running.clone()).await;
    let first = c
        .until(|v| v["method"] == "_acpmux/prompt_accepted" && v["params"]["promptId"] == "p-run")
        .await;
    c.until(|v| v.pointer("/params/update/content/text") == Some(&json!("running"))).await;
    let mut again = Client::open(&hub);
    again.send("session/prompt", running).await;
    let dup = again
        .until(|v| v["method"] == "_acpmux/prompt_accepted" && v["params"]["promptId"] == "p-run")
        .await;
    c.cancel(&receiver).await;
    assert_eq!(dup["params"]["duplicate"], true, "{dup}");
    assert!(first["params"]["turnId"].is_string(), "{first}");
    assert_eq!(dup["params"]["turnId"], first["params"]["turnId"], "{dup}");
}

/// A Web connection is the person's only by a paired device's proof (`pairing.rs` `origin_of`:
/// the phone's `client` credential): the listener token a dashboard or browser socket holds
/// proves no person (`hub/person.rs`), so its unnamed prompt is unverified.
#[tokio::test]
async fn an_unnamed_web_prompt_is_the_persons_only_from_a_paired_device() {
    // A paired device prompts only a session that asks before it acts: an asking mode
    // (`remote.mode_not_asking`) and policy (`remote.policy_not_asking`, `hub/web_control.rs`).
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE]}},
        "defaultHarness": "fake",
        "permissionPolicy": "ask",
        "webAskingModes": {"fake": ["normal"]},
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let mut local = Client::open(&hub);
    let session = local.new_session(json!({"harness": "fake"})).await;
    for (auth, id, kind) in [
        (ConnAuth::ListenerToken, "p-dashboard", Some(json!("unverified"))),
        (ConnAuth::Device, "p-phone", None),
    ] {
        let mut web = Client::open_authed(&hub, Origin::Web, auth);
        web.call("session/prompt", prompt(&session, id, "hi", None)).await;
        let message = local.user_message(&session, id).await;
        assert_eq!(message.pointer("/_meta/provenance/kind").cloned(), kind, "{auth:?}: {message}");
    }
}

#[tokio::test]
async fn only_a_peer_daemon_names_a_messages_sender() {
    // A paired `client` device is served as a peer (`pairing::origin_of`), but only the peer
    // token proves a daemon that stamps `messageSender` itself; the device could name any agent.
    let hub = hub();
    let mut local = Client::open(&hub);
    let session = local.new_session(json!({"harness": "fake"})).await;
    let victim = local.new_session(json!({"harness": "fake"})).await;
    for (auth, id, kind) in [
        (ConnAuth::Device, "p-device", Some(json!("unverified"))),
        (ConnAuth::PeerToken, "p-peer", Some(json!("agent_message"))),
    ] {
        let mut peer = Client::open_authed(&hub, Origin::Peer, auth);
        let mut params = prompt(&session, id, "hi", None);
        params["_meta"]["acpmux"]["messageSender"] =
            json!({"name": "builder", "sessionId": victim, "host": "peer-host"});
        peer.call("session/prompt", params).await;
        let message = local.user_message(&session, id).await;
        assert_eq!(message.pointer("/_meta/provenance/kind").cloned(), kind, "{auth:?}: {message}");
    }
    let messages = local.records(&session, "_acpmux/message").await;
    assert_eq!(messages.len(), 1, "only the peer daemon's prompt is a message: {messages:#?}");
}

#[tokio::test]
async fn a_malformed_provenance_is_refused() {
    let hub = hub();
    let mut c = Client::open(&hub);
    let session = c.new_session(json!({"harness": "fake"})).await;
    let p = provenance(&session);
    let mut no_sender = p.clone();
    no_sender.as_object_mut().unwrap().remove("from");
    let mut long_name = p.clone();
    long_name["fromName"] = json!("n".repeat(65));
    // A name that reads backwards or breaks the line shows a sender it is not.
    let mut bidi_name = p.clone();
    bidi_name["fromName"] = json!("builder\u{202E}nimda");
    let mut split_sender = p.clone();
    split_sender["from"] = json!("acp:a\u{2028}acp:b");
    let malformed = [json!("acp:x"), json!({"kind": "person"}), no_sender, long_name];
    for bad in malformed.into_iter().chain([bidi_name, split_sender]) {
        let value = c.reply("session/prompt", prompt(&session, "p-bad", "hi", Some(&bad))).await;
        assert_eq!(
            value.pointer("/error/data/reason"),
            Some(&json!("provenance.value_refused")),
            "{bad}: {value}"
        );
    }
    assert!(c.records(&session, "user_message").await.is_empty(), "a refused prompt ran");
}

#[tokio::test]
async fn a_provenance_from_any_origin_but_the_unix_socket_is_refused() {
    let hub = hub();
    let mut local = Client::open(&hub);
    let session = local.new_session(json!({"harness": "fake"})).await;
    let p = provenance(&session);
    for (origin, via) in [
        (Origin::Web, None),
        (Origin::LocalApp, None),
        (Origin::Peer, None),
        (Origin::Peer, Some("web")),
    ] {
        let mut remote = Client::open_as(&hub, origin);
        let mut params = prompt(&session, "p-remote", "hi", Some(&p));
        if let Some(via) = via {
            params["_meta"]["acpmux"]["via"] = json!(via);
        }
        let value = remote.reply("session/prompt", params).await;
        assert_eq!(
            value.pointer("/error/data/reason"),
            Some(&json!("provenance.origin_refused")),
            "{origin:?} via {via:?}: {value}"
        );
    }
    assert!(local.records(&session, "user_message").await.is_empty(), "a refused prompt ran");
}

/// The app pane's reply in place (IncomingMessageCard.tsx, direct.ts `reply`): chat `from`
/// answers message `msg-0` of thread `thread-1`, which chat `to` sent it, with no name: acpmux
/// signs it with the chat's own.
fn app_reply(from: &str, to: &str) -> Value {
    json!({"sessionId": from, "to": to, "replyTo": "msg-0", "threadId": "thread-1",
           "text": "  Rebased; tests pass.\n", "replyId": "m-reply"})
}

/// The old reply in place (#22310): a `session/prompt` to the sender's chat with an
/// `agent_message` provenance.
fn prompted_reply(from: &str, to: &str) -> Value {
    json!({"kind": "agent_message", "from": format!("acp:{from}"), "to": format!("acp:{to}"),
           "msgId": "m-reply", "threadId": "thread-1", "replyTo": "msg-0"})
}

#[tokio::test]
async fn the_app_pane_reply_in_place_is_checked_and_signed_and_never_prompted() {
    let hub = hub();
    let mut local = Client::open(&hub);
    let sender = local.new_session(json!({"harness": "fake"})).await;
    let replier = local.new_session(json!({"harness": "fake"})).await;
    // The message the reply answers: `sender`'s agent message `msg-0` to `replier`, as
    // `cmux agent message` addresses one.
    let message = json!({"kind": "agent_message", "from": format!("acp:{sender}"), "fromName": "builder",
                         "to": format!("acp:{replier}"), "msgId": "msg-0", "threadId": "thread-1"});
    local
        .call("session/prompt", prompt(&replier, "msg-0", "Rebase on main.", Some(&message)))
        .await;
    let mut app = Client::open_as(&hub, Origin::LocalApp);
    // The pane shows the chat the message came to.
    app.call("_acpmux/attach", json!({"sessionId": replier, "limit": 0})).await;

    // A reply from the chat the message came to, to the chat that sent it: acpmux answers it as
    // it checked it, signed with the chat's own name, for the app to send as that chat's cmux
    // agent message. Nothing is prompted here.
    let signed = app.call("_acpmux/app_reply", app_reply(&replier, &sender)).await;
    let reply = &signed["reply"];
    assert_eq!(reply["from"], format!("acp:{replier}"), "{signed}");
    assert_eq!(reply["to"], format!("acp:{sender}"), "{signed}");
    assert_eq!(reply["replyTo"], "msg-0", "{signed}");
    assert_eq!(reply["threadId"], "thread-1", "{signed}");
    assert_eq!(reply["text"], "Rebased; tests pass.", "{signed}");
    let name = reply["fromName"].as_str().unwrap_or_default();
    assert!(!name.is_empty() && name != "builder", "{signed}");
    let key = reply["idempotencyKey"].as_str().unwrap_or_default().to_owned();
    assert!(key.starts_with("acpmux-reply-"), "{signed}");
    let again = app.call("_acpmux/app_reply", app_reply(&replier, &sender)).await;
    assert_eq!(again["reply"]["idempotencyKey"], key.as_str(), "the same reply, the same key");
    assert!(local.records(&sender, "user_message").await.is_empty(), "a reply was prompted here");

    // The old way, a `session/prompt` with a provenance from the app, is refused: it put the
    // reply in the sender's chat behind the cmux agent message store's back.
    let mut held = Client::open_as(&hub, Origin::LocalApp);
    held.call("_acpmux/attach", json!({"sessionId": replier, "limit": 0})).await;
    held.call("_acpmux/attach", json!({"sessionId": sender, "limit": 0, "visible": false})).await;
    let old = prompted_reply(&replier, &sender);
    let value = held.reply("session/prompt", prompt(&sender, "p-reply", "hi", Some(&old))).await;
    assert_eq!(
        value.pointer("/error/data/reason"),
        Some(&json!("provenance.origin_refused")),
        "{value}"
    );

    // A reply to a message the chat never got, in a thread that is not the message's, from a
    // sender that is no chat here or is named by its `acp:` address, to the replying chat itself
    // or to a chat that did not send the message, or with no text: refused.
    let mut unknown_message = app_reply(&replier, &sender);
    unknown_message["replyTo"] = json!("msg-never-sent");
    let mut wrong_thread = app_reply(&replier, &sender);
    wrong_thread["threadId"] = json!("thread-other");
    let mut acp_from = app_reply(&replier, &sender);
    acp_from["sessionId"] = json!(format!("acp:{replier}"));
    let mut no_text = app_reply(&replier, &sender);
    no_text["text"] = json!(" \n");
    let mut control = app_reply(&replier, &sender);
    control["text"] = json!("Rebased.\r\nShip it.");
    let mut too_long = app_reply(&replier, &sender);
    too_long["text"] = json!("x".repeat(32 * 1024 + 1));
    let bystander = local.new_session(json!({"harness": "fake"})).await;
    let refused = [
        ("reply.refused", unknown_message),
        ("reply.refused", wrong_thread),
        ("reply.refused", app_reply("nobody", &sender)),
        ("reply.refused", acp_from),
        ("reply.refused", app_reply(&replier, &replier)),
        ("reply.refused", app_reply(&replier, &bystander)),
        ("reply.text_required", no_text),
        ("reply.text_required", control),
        ("reply.text_required", too_long),
    ];
    for (reason, bad) in refused {
        let value = app.reply("_acpmux/app_reply", bad.clone()).await;
        assert_eq!(value.pointer("/error/data/reason"), Some(&json!(reason)), "{bad}: {value}");
    }

    // Default deny for what the pane signs (cx-kybz1 review): a chat this connection does not
    // show (not attached, or only held unseen) got the message too, and may not answer from here.
    let message_to = |to: &str| {
        json!({"kind": "agent_message", "from": format!("acp:{sender}"), "fromName": "builder",
               "to": format!("acp:{to}"), "msgId": "msg-0", "threadId": "thread-1"})
    };
    let unattached = local.new_session(json!({"harness": "fake"})).await;
    let unseen = local.new_session(json!({"harness": "fake"})).await;
    for chat in [&unattached, &unseen] {
        let got = message_to(chat);
        local.call("session/prompt", prompt(chat, "msg-0", "Rebase on main.", Some(&got))).await;
    }
    app.call("_acpmux/attach", json!({"sessionId": unseen, "limit": 0, "visible": false})).await;
    for chat in [&unattached, &unseen] {
        let value = app.reply("_acpmux/app_reply", app_reply(chat, &sender)).await;
        assert_eq!(
            value.pointer("/error/data/reason"),
            Some(&json!("reply.refused")),
            "{chat}: {value}"
        );
    }

    // Only the app's own pane: never the unix socket (an agent there sends with `cmux agent
    // message` itself), a remote browser or a peer.
    for origin in [Origin::Local, Origin::Web, Origin::Peer] {
        let mut other = Client::open_as(&hub, origin);
        let _ = other.reply("_acpmux/attach", json!({"sessionId": replier, "limit": 0})).await;
        let value = other.reply("_acpmux/app_reply", app_reply(&replier, &sender)).await;
        assert_eq!(
            value.pointer("/error/data/reason"),
            Some(&json!("reply.origin_refused")),
            "{origin:?}: {value}"
        );
    }
    let ran = local.records(&sender, "user_message").await;
    assert!(ran.is_empty(), "a reply ran in the sender's chat: {ran:?}");
}

#[tokio::test]
async fn a_queued_prompt_keeps_its_provenance_until_it_runs() {
    let hub = hub();
    let mut c = Client::open(&hub);
    let session = c.new_session(json!({"harness": "fake"})).await;
    let p = provenance(&session);
    c.busy(&session).await;
    let waiting = c.queue(prompt(&session, "p-q", "queued message", Some(&p))).await;
    let queued = c.records(&session, "queued").await;
    let queued = queued.iter().find(|m| m["promptId"] == "p-q").expect("its queued record");
    assert_eq!(queued.pointer("/_meta/provenance"), Some(&seen(p.clone(), "unix")), "{queued}");

    c.cancel(&session).await;
    let done = c.reply_to(waiting).await;
    assert_eq!(done.pointer("/result/stopReason"), Some(&json!("end_turn")), "{done}");
    let ran = c.user_message(&session, "p-q").await;
    assert_eq!(ran["text"], "queued message", "{ran}");
    assert_eq!(ran.pointer("/_meta/provenance"), Some(&seen(p.clone(), "unix")), "{ran}");
}

#[tokio::test]
async fn an_edit_of_a_queued_prompt_keeps_its_sender_and_names_its_editor() {
    let hub = hub();
    let mut c = Client::open(&hub);
    let session = c.new_session(json!({"harness": "fake"})).await;
    let p = provenance(&session);
    c.busy(&session).await;
    let waiting = c.queue(prompt(&session, "p-e", "from builder", Some(&p))).await;
    let edit = json!({"sessionId": session, "promptId": "p-e", "op": "update", "text": "the person's rewrite"});
    let edited = c.call("_acpmux/queue_edit", edit).await;
    assert_eq!(edited["ok"], true, "{edited}");

    c.cancel(&session).await;
    c.reply_to(waiting).await;
    let ran = c.user_message(&session, "p-e").await;
    assert_eq!(ran["text"], "the person's rewrite", "{ran}");
    // Still the builder's message, never the editor's own words; the edit is named beside it.
    assert_eq!(ran.pointer("/_meta/provenance/kind"), Some(&json!("agent_message")), "{ran}");
    assert_eq!(ran.pointer("/_meta/provenance/from"), p.get("from"), "{ran}");
    assert_eq!(
        ran.pointer("/_meta/provenance/editedBy"),
        Some(&json!({"actor": "owner"})),
        "{ran}"
    );
}

#[tokio::test]
async fn a_steer_records_its_provenance() {
    let hub = hub_env(json!({"FAKE_CODEX_STEER": "1"}));
    let mut c = Client::open(&hub);
    let session = c.new_session(json!({"harness": "fake"})).await;
    let p = provenance(&session);
    let turn = c.send("session/prompt", prompt(&session, "p-turn", "work", None)).await;
    c.until(|v| {
        v.pointer("/params/update/content/text")
            .and_then(Value::as_str)
            .is_some_and(|t| t.starts_with("turn: "))
    })
    .await;
    let mut params = prompt(&session, "p-steer", "a message mid-turn", Some(&p));
    params["_meta"]["acpmux"]["steer"] = json!(true);
    let steer = c.send("session/prompt", params).await;
    // Both prompts are answered, in either order.
    let mut answered = Vec::new();
    while answered.len() < 2 {
        let value = c
            .until(|v| v.get("id") == Some(&json!(turn)) || v.get("id") == Some(&json!(steer)))
            .await;
        assert!(value.get("error").is_none(), "{value}");
        answered.push(value);
    }

    let steered = c.user_message(&session, "p-steer").await;
    assert_eq!(steered["steer"], true, "{steered}");
    assert_eq!(steered.pointer("/_meta/provenance"), Some(&seen(p.clone(), "unix")), "{steered}");
    // The turn it steered into is the owner's own terminal send: the person's prompt.
    let own = c.user_message(&session, "p-turn").await;
    assert_eq!(own.pointer("/_meta/provenance"), None, "{own}");
    assert_eq!(own.pointer("/_meta/origin/actor"), Some(&json!("person")), "{own}");
}

/// A connection that proved it runs inside session `id` with the caller token acpmux put in that
/// session's env (`hub/person.rs` (a)): the agent there running `acpmux send`.
async fn open_in_session(hub: &Arc<Hub>, id: &str) -> Client {
    let mut c = Client::open(hub);
    let token = acpmux::hub::person::caller_token(id);
    let caller = json!({"callerSession": {"sessionId": id, "token": token}});
    c.call("initialize", json!({"protocolVersion": 1, "_meta": {"acpmux": caller}})).await;
    c
}

#[tokio::test]
async fn a_prompt_sent_from_inside_another_session_records_that_session_as_its_sender() {
    let hub = hub();
    let mut person = Client::open(&hub);
    let sender = person.new_session(json!({"harness": "fake"})).await;
    let receiver = person.new_session(json!({"harness": "fake"})).await;
    let name = hub.resolve(&sender).unwrap().meta().name;
    let mut lane = open_in_session(&hub, &sender).await;
    lane.call("session/prompt", prompt(&receiver, "p-lane", "report from the lane", None)).await;
    // A prompt to the sender's own session, and the person's prompt, are no one else's message.
    lane.call("session/prompt", prompt(&sender, "p-self", "a note to itself", None)).await;
    person
        .call("session/prompt", prompt(&receiver, "p-person", "the person's own words", None))
        .await;
    // A provenance the sender gives is checked as before and is the one recorded.
    let given = provenance(&receiver);
    lane.call("session/prompt", prompt(&receiver, "p-given", "hi", Some(&given))).await;

    let from_lane = person.user_message(&receiver, "p-lane").await;
    assert_eq!(from_lane["text"], "report from the lane", "{from_lane}");
    // With the sending session's id and harness family, bound from its caller token.
    let stamped = json!({"kind": "session_message", "from": sender, "fromName": name, "to": receiver,
                         "fromSessionId": sender, "fromHarness": "codex", "verified": true});
    assert_eq!(from_lane.pointer("/_meta/provenance"), Some(&seen(stamped, "unix")), "{from_lane}");
    // A note to itself is that session's, as its caller token proves; never the person's.
    let own = person.user_message(&sender, "p-self").await;
    assert_eq!(own.pointer("/_meta/provenance/kind"), Some(&json!("session_message")), "{own}");
    assert_eq!(own.pointer("/_meta/provenance/verified"), Some(&json!(true)), "{own}");
    // The owner's own terminal send, outside any session, is the person's prompt again.
    let theirs = person.user_message(&receiver, "p-person").await;
    assert_eq!(theirs.pointer("/_meta/provenance"), None, "{theirs}");
    assert_eq!(theirs.pointer("/_meta/origin/actor"), Some(&json!("person")), "{theirs}");
    let kept = person.user_message(&receiver, "p-given").await;
    let mut bound = given.clone();
    bound["fromSessionId"] = json!(sender);
    bound["fromHarness"] = json!("codex");
    // Its caller token proved the sending session: the daemon bound who sent it.
    bound["verified"] = json!(true);
    assert_eq!(kept.pointer("/_meta/provenance"), Some(&seen(bound, "unix")), "{kept}");
}

/// A queued agent message shows its sender's session and harness on its queue row, and reads back
/// whole by its prompt id (`_acpmux/queue_text`): the row carries a 200-character preview only.
/// Leo, 2026-10-29: "If I expand it, I expect to see the whole thing" and "why are some of these
/// icons still only placeholders?"
#[tokio::test]
async fn a_queued_agent_message_reads_whole_and_names_its_senders_session_and_harness() {
    let hub = hub();
    let mut person = Client::open(&hub);
    let sender = person.new_session(json!({"harness": "fake"})).await;
    let receiver = person.new_session(json!({"harness": "fake"})).await;
    person.busy(&receiver).await;
    let whole = format!("report: {}end", "x".repeat(1200));
    let mut lane = open_in_session(&hub, &sender).await;
    let waiting = lane.queue(prompt(&receiver, "p-long", &whole, None)).await;

    let s = hub.resolve(&receiver).unwrap();
    let rows = hub.session_summary(&s)["queue"].clone();
    let row = rows.as_array().unwrap().iter().find(|q| q["promptId"] == "p-long").unwrap();
    assert!(row["prompt"].as_str().unwrap().chars().count() < whole.len(), "{row}");
    assert_eq!(row["fromSessionId"], json!(sender), "{row}");
    assert_eq!(row["fromHarness"], "codex", "{row}");
    let composers = hub.composers_view(&s)["queue"][0].clone();
    assert_eq!(
        (&composers["fromSessionId"], &composers["fromHarness"]),
        (&json!(sender), &json!("codex"))
    );

    let read = person
        .call("_acpmux/queue_text", json!({"sessionId": receiver, "promptId": "p-long"}))
        .await;
    assert_eq!(read["text"], json!(whole), "{read}");
    assert_eq!(read["prompt"][0]["text"], json!(whole), "{read}");
    assert_eq!(read["turnId"], row["turnId"], "{read}");
    assert_eq!((&read["fromSessionId"], &read["fromHarness"]), (&json!(sender), &json!("codex")));
    let queued = person.records(&receiver, "queued").await;
    let queued = queued.iter().find(|m| m["promptId"] == "p-long").expect("its queued record");
    assert_eq!(queued.pointer("/_meta/provenance/fromHarness"), Some(&json!("codex")), "{queued}");
    let missing = person
        .reply("_acpmux/queue_text", json!({"sessionId": receiver, "promptId": "p-none"}))
        .await;
    assert_eq!(reason(&missing), "queue.not_found", "{missing}");
    assert_eq!(missing.pointer("/error/code"), Some(&json!(-32002)), "{missing}");

    person.cancel(&receiver).await;
    lane.reply_to(waiting).await;
    let ran = person.user_message(&receiver, "p-long").await;
    assert_eq!(ran.pointer("/_meta/provenance/fromSessionId"), Some(&json!(sender)), "{ran}");
    assert_eq!(ran.pointer("/_meta/provenance/fromHarness"), Some(&json!("codex")), "{ran}");
    // Once it ran it waits no more: its user_message has the text.
    let gone = person
        .reply("_acpmux/queue_text", json!({"sessionId": receiver, "promptId": "p-long"}))
        .await;
    assert_eq!(reason(&gone), "queue.not_found", "{gone}");
}

/// The sender's session and harness are the daemon's word, never a client's: bound from the
/// caller token, else taken from a peer link for a prompt the peer sent as its own (no `via`).
/// A claim from anywhere else is dropped, and a bound value replaces a claimed one.
#[tokio::test]
async fn a_senders_session_and_harness_come_from_a_proven_caller_or_a_peer_link_only() {
    let hub = hub();
    let mut person = Client::open(&hub);
    let sender = person.new_session(json!({"harness": "fake"})).await;
    let receiver = person.new_session(json!({"harness": "fake"})).await;
    let claimed = |id: &str, via: Option<&str>| {
        let mut p = prompt(&receiver, id, "report", None);
        let mux = &mut p["_meta"]["acpmux"];
        mux["fromAgent"] = json!("codex-lane");
        mux["fromSessionId"] = json!("s-remote");
        mux["fromHarness"] = json!("claude");
        if let Some(via) = via {
            mux["via"] = json!(via);
        }
        p
    };
    for (origin, id, via) in [
        (Origin::Peer, "p-peer", None),
        (Origin::Peer, "p-peer-app", Some("app")),
        (Origin::Local, "p-cli", None),
    ] {
        let mut c = Client::open_as(&hub, origin);
        c.call("session/prompt", claimed(id, via)).await;
    }
    let mut lane = open_in_session(&hub, &sender).await;
    lane.call("session/prompt", claimed("p-lane", None)).await;

    let p = |m: &Value| m["_meta"]["provenance"].clone();
    let peer = p(&person.user_message(&receiver, "p-peer").await);
    assert_eq!(
        (&peer["fromSessionId"], &peer["fromHarness"]),
        (&json!("s-remote"), &json!("claude")),
        "{peer}"
    );
    for id in ["p-peer-app", "p-cli"] {
        let other = p(&person.user_message(&receiver, id).await);
        assert_eq!(other["fromName"], "codex-lane", "{id}: {other}");
        assert!(
            other.get("fromSessionId").is_none() && other.get("fromHarness").is_none(),
            "{id}: {other}"
        );
    }
    let bound = p(&person.user_message(&receiver, "p-lane").await);
    assert_eq!(
        (&bound["fromSessionId"], &bound["fromHarness"]),
        (&json!(sender), &json!("codex")),
        "{bound}"
    );
}

/// A relay's word on where a message came from (`fromRelay`: the lane-gh broker's `acpmux send
/// --relay lane-gh --relayed-from VM/LANE`) is taken from a send on this machine's unix socket that
/// proved no session, and over a peer link; an agent's own send drops it, so no session can pass
/// as a relayed, verified sender (Leo, 2026-11-07: "Why does it say it's self-declared if we can
/// just detect the thing?").
#[tokio::test]
async fn a_relayed_sender_comes_from_a_relay_outside_any_session_or_a_peer_link_only() {
    let hub = hub();
    let mut person = Client::open(&hub);
    let sender = person.new_session(json!({"harness": "fake"})).await;
    let receiver = person.new_session(json!({"harness": "fake"})).await;
    let relayed = |id: &str| {
        let mut p = prompt(&receiver, id, "report", None);
        let mux = &mut p["_meta"]["acpmux"];
        mux["fromAgent"] = json!("gcp-agent-lane-2/lock-proof-routes");
        mux["fromRelay"] =
            json!({"by": "lane-gh", "machine": "gcp-agent-lane-2", "session": "lock-proof-routes"});
        mux["fromHarness"] = json!("claude");
        p
    };
    for (origin, id) in [(Origin::Local, "p-relay"), (Origin::Peer, "p-peer")] {
        let mut c = Client::open_as(&hub, origin);
        c.call("session/prompt", relayed(id)).await;
    }
    let mut lane = open_in_session(&hub, &sender).await;
    lane.call("session/prompt", relayed("p-lane")).await;
    // A relay record that is not one names nobody.
    let mut odd = relayed("p-odd");
    odd["_meta"]["acpmux"]["fromRelay"] = json!({"by": "lane gh", "machine": "x"});
    Client::open(&hub).call("session/prompt", odd).await;

    let p = |m: &Value| m["_meta"]["provenance"].clone();
    let want =
        json!({"by": "lane-gh", "machine": "gcp-agent-lane-2", "session": "lock-proof-routes"});
    for id in ["p-relay", "p-peer"] {
        let got = p(&person.user_message(&receiver, id).await);
        assert_eq!(
            (&got["fromRelay"], &got["fromHarness"]),
            (&want, &json!("claude")),
            "{id}: {got}"
        );
        assert!(got.get("fromSessionId").is_none(), "a relay proves no session here: {got}");
        let record = acpmux::prompt_provenance::sender_record(Some(&got), None, None);
        assert_eq!(
            (&record["authenticated"], &record["verification"], &record["relay"]),
            (&json!(true), &json!("verified"), &want),
            "{id}: {record}"
        );
    }
    // The agent's own send: its proven session is the sender, its relay claim is dropped.
    let lane_said = p(&person.user_message(&receiver, "p-lane").await);
    assert!(lane_said.get("fromRelay").is_none(), "{lane_said}");
    assert_eq!(lane_said["fromSessionId"], json!(sender), "{lane_said}");
    let odd_said = p(&person.user_message(&receiver, "p-odd").await);
    assert!(
        odd_said.get("fromRelay").is_none() && odd_said.get("fromHarness").is_none(),
        "{odd_said}"
    );
    let record = acpmux::prompt_provenance::sender_record(Some(&odd_said), None, None);
    assert_eq!(record["verification"], "declared", "{record}");
}

/// claude-sr2, 2026-10-24: lanes on other machines reached its daemon over the peer link, or ran
/// `acpmux send --from` there over ssh, naming themselves only in `fromAgent`; each report
/// recorded no provenance and read as the person's own words.
#[tokio::test]
async fn a_prompt_that_names_its_sender_records_it_as_that_agents_message() {
    let hub = hub();
    let mut person = Client::open(&hub);
    let receiver = person.new_session(json!({"harness": "fake"})).await;
    let own = hub.resolve(&receiver).unwrap().meta().name;
    let named = |id: &str, from: &str| {
        let mut p = prompt(&receiver, id, "report", None);
        p["_meta"]["acpmux"]["fromAgent"] = json!(from);
        p
    };
    for (origin, id, from) in [
        (Origin::Peer, "p-peer", "codex-lane"),
        (Origin::Local, "p-cli", "codex-lane-2"),
        (Origin::Local, "p-self", own.as_str()),
        // Names are each daemon's own: a peer's session of the same name is another one.
        (Origin::Peer, "p-namesake", own.as_str()),
    ] {
        let mut c = Client::open_as(&hub, origin);
        c.call("session/prompt", named(id, from)).await;
    }
    person.call("session/prompt", prompt(&receiver, "p-person", "my own words", None)).await;

    for (id, from, transport) in [
        ("p-peer", "codex-lane", "peer"),
        ("p-cli", "codex-lane-2", "unix"),
        ("p-namesake", own.as_str(), "peer"),
    ] {
        let message = person.user_message(&receiver, id).await;
        let stamped =
            json!({"kind": "agent_message", "from": "fromAgent", "fromName": from, "to": receiver});
        assert_eq!(
            message.pointer("/_meta/provenance"),
            Some(&seen(stamped, transport)),
            "{message}"
        );
    }
    // Its own name from a unix client names no one else, but it named a sender: unverified, never
    // the person's.
    let own_name = person.user_message(&receiver, "p-self").await;
    assert_eq!(
        own_name.pointer("/_meta/provenance/kind"),
        Some(&json!("unverified")),
        "{own_name}"
    );
    // An unnamed prompt claiming nothing is the owner's own terminal send: the person's again.
    let theirs = person.user_message(&receiver, "p-person").await;
    assert_eq!(theirs.pointer("/_meta/provenance"), None, "{theirs}");
    assert_eq!(theirs.pointer("/_meta/origin/actor"), Some(&json!("person")), "{theirs}");
}

/// The person's own `acpmux send` from a terminal names the machine it ran on: the recorded client
/// says it, so the pane shows "via CLI on big-red" under their prompt (Leo, 2026-10-24). An agent's
/// message names its sender instead, and a value that is no host name is dropped.
#[tokio::test]
async fn the_persons_own_cli_send_records_the_machine_it_ran_on() {
    let hub = hub();
    let mut person = Client::open(&hub);
    let receiver = person.new_session(json!({"harness": "fake"})).await;
    let sent = |id: &str, host: &str, from: Option<&str>| {
        let mut p = prompt(&receiver, id, "ship it", None);
        p["_meta"]["acpmux"]["cliHost"] = json!(host);
        if let Some(from) = from {
            p["_meta"]["acpmux"]["fromAgent"] = json!(from);
        }
        p
    };
    for (origin, params) in [
        (Origin::Local, sent("p-cli", "big-red", None)),
        (Origin::Peer, sent("p-peer", "big-red", None)),
        (Origin::Local, sent("p-agent", "huge-blue", Some("codex-lane"))),
        (Origin::Local, sent("p-odd", "big red\nX", None)),
    ] {
        let mut c = Client::open_as(&hub, origin);
        c.call("session/prompt", params).await;
    }
    let client = |m: &Value| m["client"].as_str().unwrap().to_owned();
    let cli = client(&person.user_message(&receiver, "p-cli").await);
    assert!(cli.ends_with("@big-red"), "{cli}");
    let peer = client(&person.user_message(&receiver, "p-peer").await);
    assert!(peer.ends_with("@big-red"), "{peer}");
    for id in ["p-agent", "p-odd"] {
        let other = client(&person.user_message(&receiver, id).await);
        assert!(!other.contains('@'), "{id}: {other}");
    }
}

// A steer names its pasted blocks (`_meta.cmux.pasted`) as a prompt does: UTF-16 ranges of its
// text.
#[tokio::test]
async fn a_steer_records_its_pasted_ranges() {
    let hub = hub_env(json!({"FAKE_CODEX_STEER": "1"}));
    let mut c = Client::open(&hub);
    let session = c.new_session(json!({"harness": "fake"})).await;
    let turn = c.send("session/prompt", prompt(&session, "p-turn", "work", None)).await;
    c.until(|v| {
        v.pointer("/params/update/content/text")
            .and_then(Value::as_str)
            .is_some_and(|t| t.starts_with("turn: "))
    })
    .await;
    let mut params = prompt(&session, "p-steer", "🦀 also", None);
    params["prompt"]
        .as_array_mut()
        .unwrap()
        .push(json!({"type": "text", "text": "a log", "_meta": {"cmux": {"pasted": true}}}));
    params["_meta"]["acpmux"]["steer"] = json!(true);
    let steer = c.send("session/prompt", params).await;
    let mut answered = Vec::new();
    while answered.len() < 2 {
        let value = c
            .until(|v| v.get("id") == Some(&json!(turn)) || v.get("id") == Some(&json!(steer)))
            .await;
        assert!(value.get("error").is_none(), "{value}");
        answered.push(value);
    }

    let steered = c.user_message(&session, "p-steer").await;
    assert_eq!(steered["steer"], true, "{steered}");
    assert_eq!(steered["text"], "🦀 also\na log", "{steered}");
    // 🦀 is two UTF-16 units: "🦀 also" is 7, and the paste starts after its "\n".
    assert_eq!(steered["pasted"], json!([{"start": 8, "end": 13}]), "{steered}");
}

fn ana() -> Value {
    json!({"id": "tailnet:ana@example.com", "name": "Ana", "login": "ana@example.com", "node": "ana-mbp"})
}

fn bo() -> Value {
    json!({"id": "user_bo", "name": "Bo"})
}

/// The provenance acpmux stamps for [`ana`].
fn anas() -> Value {
    json!({"kind": "person_message", "from": "tailnet:ana@example.com", "fromName": "Ana",
           "login": "ana@example.com", "node": "ana-mbp"})
}

/// `params` with `author` in `_meta.acpmux`.
pub(super) fn by(mut params: Value, author: Option<&Value>) -> Value {
    if let Some(author) = author {
        params["_meta"]["acpmux"]["author"] = author.clone();
    }
    params
}

pub(super) fn reason(value: &Value) -> &Value {
    value.pointer("/error/data/reason").unwrap_or(&Value::Null)
}

/// Chat multiplayer (hq#4389): a person's name rides as `_meta.acpmux.author`, from the unix
/// socket or a peer that forwards one; the app's pane, a Web client and a peer forwarding for
/// its own Web client may not name anyone.
#[tokio::test]
async fn an_author_is_taken_from_the_unix_socket_and_a_forwarding_peer_only() {
    let hub = hub();
    let mut local = Client::open(&hub);
    let session = local.new_session(json!({"harness": "fake"})).await;
    for (origin, id) in [(Origin::Local, "p-unix"), (Origin::Peer, "p-peer")] {
        let mut c = Client::open_as(&hub, origin);
        c.call("session/prompt", by(prompt(&session, id, "hi", None), Some(&ana()))).await;
        let message = local.user_message(&session, id).await;
        let transport = if origin == Origin::Peer { "peer" } else { "unix" };
        assert_eq!(
            message.pointer("/_meta/provenance"),
            Some(&seen(anas(), transport)),
            "{origin:?}: {message}"
        );
    }
    for (origin, via) in
        [(Origin::Web, None), (Origin::LocalApp, None), (Origin::Peer, Some("web"))]
    {
        let mut remote = Client::open_as(&hub, origin);
        let mut params = by(prompt(&session, "p-remote", "hi", None), Some(&ana()));
        let mut remove = by(
            json!({"sessionId": session, "promptId": "p-x", "_meta": {"acpmux": {}}}),
            Some(&ana()),
        );
        if let Some(via) = via {
            params["_meta"]["acpmux"]["via"] = json!(via);
            remove["_meta"]["acpmux"]["via"] = json!(via);
        }
        let value = remote.reply("session/prompt", params).await;
        assert_eq!(reason(&value), "author.origin_refused", "{origin:?} via {via:?}: {value}");
        let value = remote.reply("_acpmux/queue_remove", remove).await;
        assert_eq!(reason(&value), "author.origin_refused", "{origin:?} via {via:?}: {value}");
    }
    let ran = local.records(&session, "user_message").await;
    assert!(ran.iter().all(|m| m["promptId"] != "p-remote"), "a refused prompt ran: {ran:?}");
    let bad = by(prompt(&session, "p-bad", "hi", None), Some(&json!({"id": "ana", "name": "Ana"})));
    assert_eq!(reason(&local.reply("session/prompt", bad).await), "author.value_refused");
}

#[tokio::test]
async fn a_persons_queued_prompt_and_steer_record_who_sent_them() {
    let hub = hub();
    let mut c = Client::open(&hub);
    let session = c.new_session(json!({"harness": "fake"})).await;
    c.busy(&session).await;
    let waiting = c.queue(by(prompt(&session, "p-q", "queued words", None), Some(&ana()))).await;
    let queued = c.records(&session, "queued").await;
    let queued = queued.iter().find(|m| m["promptId"] == "p-q").expect("its queued record");
    assert_eq!(queued.pointer("/_meta/provenance"), Some(&seen(anas(), "unix")), "{queued}");
    c.cancel(&session).await;
    c.reply_to(waiting).await;
    let ran = c.user_message(&session, "p-q").await;
    assert_eq!(ran.pointer("/_meta/provenance"), Some(&seen(anas(), "unix")), "{ran}");

    let hub = hub_env(json!({"FAKE_CODEX_STEER": "1"}));
    let mut c = Client::open(&hub);
    let session = c.new_session(json!({"harness": "fake"})).await;
    let turn = c.send("session/prompt", prompt(&session, "p-turn", "work", None)).await;
    c.until(|v| {
        v.pointer("/params/update/content/text")
            .and_then(Value::as_str)
            .is_some_and(|t| t.starts_with("turn: "))
    })
    .await;
    let mut steer = by(prompt(&session, "p-steer", "mid-turn words", None), Some(&ana()));
    steer["_meta"]["acpmux"]["steer"] = json!(true);
    let steer = c.send("session/prompt", steer).await;
    for _ in 0..2 {
        let value = c
            .until(|v| v.get("id") == Some(&json!(turn)) || v.get("id") == Some(&json!(steer)))
            .await;
        assert!(value.get("error").is_none(), "{value}");
    }
    let steered = c.user_message(&session, "p-steer").await;
    assert_eq!(steered["steer"], true, "{steered}");
    assert_eq!(steered.pointer("/_meta/provenance"), Some(&seen(anas(), "unix")), "{steered}");
}

/// Only who sent a waiting prompt edits, moves, sends or removes it: another person, or the owner
/// for a person's prompt, gets `queue.not_author`. No author is the owner, and an agent's message
/// counts as the owner's. The sender's own edit keeps their name on it.
#[tokio::test]
async fn only_the_sender_changes_a_waiting_prompt() {
    let hub = hub();
    let mut c = Client::open(&hub);
    let session = c.new_session(json!({"harness": "fake"})).await;
    c.busy(&session).await;
    let agent = provenance(&session);
    let mut waits = Vec::new();
    for (id, author, p) in
        [("p-ana", Some(ana()), None), ("p-owner", None, None), ("p-agent", None, Some(&agent))]
    {
        waits.push(c.queue(by(prompt(&session, id, id, p), author.as_ref())).await);
    }
    let edit = |id: &str, op: &str, author: Option<&Value>| {
        let params = json!({"sessionId": session, "promptId": id, "op": op, "text": "rewrite",
                            "index": 0, "_meta": {"acpmux": {}}});
        by(params, author)
    };
    let refused = [
        ("p-ana", Some(bo())),
        ("p-ana", None),
        ("p-owner", Some(ana())),
        ("p-agent", Some(ana())),
    ];
    for (id, author) in refused {
        for op in ["update", "move", "send_now", "interrupt"] {
            let value = c.reply("_acpmux/queue_edit", edit(id, op, author.as_ref())).await;
            assert_eq!(reason(&value), "queue.not_author", "{id} {op} by {author:?}: {value}");
        }
        let remove = by(
            json!({"sessionId": session, "promptId": id, "_meta": {"acpmux": {}}}),
            author.as_ref(),
        );
        let value = c.reply("_acpmux/queue_remove", remove).await;
        assert_eq!(reason(&value), "queue.not_author", "{id} remove by {author:?}: {value}");
        // Asked for agents' messages only (`session queue clear --from-agents`): still refused,
        // never a "kept" that tells them whose prompt it is.
        let agents_only = by(
            json!({"sessionId": session, "promptId": id, "fromAgentsOnly": true,
                   "_meta": {"acpmux": {}}}),
            author.as_ref(),
        );
        let value = c.reply("_acpmux/queue_remove", agents_only).await;
        assert_eq!(reason(&value), "queue.not_author", "{id} agents-only by {author:?}: {value}");
    }
    // `resume` changes no one prompt.
    c.call("_acpmux/queue_edit", edit("p-ana", "resume", Some(&bo()))).await;
    for (id, author) in [("p-ana", Some(ana())), ("p-owner", None), ("p-agent", None)] {
        let edited = c.call("_acpmux/queue_edit", edit(id, "update", author.as_ref())).await;
        assert_eq!(edited["ok"], true, "{id}: {edited}");
    }
    let updated = c.records(&session, "queue_updated").await;
    let anas_edit = updated.iter().find(|m| m["promptId"] == "p-ana").expect("p-ana's edit");
    let mut her_edit = seen(anas(), "unix");
    her_edit["editedBy"] = json!({"actor": "person", "id": "tailnet:ana@example.com"});
    assert_eq!(anas_edit.pointer("/_meta/provenance"), Some(&her_edit), "{anas_edit}");
    let remove =
        by(json!({"sessionId": session, "promptId": "p-owner", "_meta": {"acpmux": {}}}), None);
    assert_eq!(c.call("_acpmux/queue_remove", remove).await["removed"], true);

    // The turn stops, and the two left run in order: p-agent's answer comes last.
    c.cancel(&session).await;
    c.reply_to(waits[2]).await;
    let ran = c.user_message(&session, "p-ana").await;
    assert_eq!(ran["text"], "rewrite", "{ran}");
    assert_eq!(ran.pointer("/_meta/provenance"), Some(&her_edit), "her edit lost her name: {ran}");
    // The owner's edit keeps the agent's message the agent's, and names the owner as its editor.
    let theirs = c.user_message(&session, "p-agent").await;
    assert_eq!(
        theirs.pointer("/_meta/provenance/editedBy"),
        Some(&json!({"actor": "owner"})),
        "the owner's edit dropped the agent's: {theirs}"
    );
}

/// The queue list names a teammate's waiting prompt's author (`author {id, name}`), so a pane that
/// opens the chat cold, past the `queued` record, still knows the row is theirs: in the session
/// summary and in `_acpmux/composers`, kept by her own edit. The owner's and an agent's list null.
#[tokio::test]
async fn the_queue_list_names_a_persons_prompt_and_no_one_else() {
    let hub = hub();
    let mut c = Client::open(&hub);
    let session = c.new_session(json!({"harness": "fake"})).await;
    c.busy(&session).await;
    let agent = provenance(&session);
    let mut waits = Vec::new();
    for (id, author, p) in
        [("p-ana", Some(ana()), None), ("p-owner", None, None), ("p-agent", None, Some(&agent))]
    {
        waits.push(c.queue(by(prompt(&session, id, id, p), author.as_ref())).await);
    }
    let listed = |hub: &Arc<Hub>| {
        let s = hub.resolve(&session).unwrap();
        (hub.session_summary(&s)["queue"].clone(), hub.composers_view(&s)["queue"].clone())
    };
    let her = json!({"id": "tailnet:ana@example.com", "name": "Ana"});
    for (summary, composers) in [listed(&hub), {
        let edit = json!({"sessionId": session, "promptId": "p-ana", "op": "update",
                          "text": "her rewrite", "_meta": {"acpmux": {}}});
        c.call("_acpmux/queue_edit", by(edit, Some(&ana()))).await;
        listed(&hub)
    }] {
        for queue in [&summary, &composers] {
            let ids: Vec<&Value> =
                queue.as_array().unwrap().iter().map(|q| &q["promptId"]).collect();
            assert_eq!(ids, [&json!("p-ana"), &json!("p-owner"), &json!("p-agent")], "{queue}");
            assert_eq!(queue[0]["author"], her, "{queue}");
            assert_eq!(queue[1]["author"], Value::Null, "the owner's: {queue}");
            assert_eq!(queue[2]["author"], Value::Null, "an agent's: {queue}");
            assert_eq!(queue[2]["fromAgent"], "builder", "{queue}");
        }
    }
    c.cancel(&session).await;
    c.reply_to(waits[2]).await;
}

/// First answer wins: Ana's answer is recorded with her name, and Bo's, which came second, is
/// told who answered and how. A name never stands in for the person's proof: an allow from a
/// client that is not the person is refused whoever it names.
#[tokio::test]
async fn a_losing_answer_is_told_who_answered_first() {
    let hub = hub_policy(json!({}), "ask");
    let mut c = Client::open(&hub);
    let session = c.new_session(json!({"harness": "fake"})).await;
    // The answers come over another connection, so `c` hears every reply to its prompts.
    let mut a = Client::open(&hub);
    let asked =
        c.send("session/prompt", prompt(&session, "p-ask", "ask: rm -rf /tmp/x", None)).await;
    let pending = c.until(|v| v["method"] == "_acpmux/permission_pending").await;
    let permission = pending["params"]["permissionId"].as_str().unwrap().to_owned();
    let answer = |option: &str, author: Option<&Value>| {
        let params = json!({"sessionId": session, "permissionId": permission, "optionId": option,
                            "_meta": {"acpmux": {}}});
        by(params, author)
    };
    let allow = a.reply("_acpmux/permission_respond", answer("yes", Some(&ana()))).await;
    assert_eq!(reason(&allow), "permission.person_required", "{allow}");
    a.call("_acpmux/permission_respond", answer("no", Some(&ana()))).await;
    let lost = a.reply("_acpmux/permission_respond", answer("no", Some(&bo()))).await;
    assert_eq!(
        lost.pointer("/error/data"),
        Some(&json!({"answeredBy": {"id": "tailnet:ana@example.com", "name": "Ana"},
                     "outcome": {"outcome": "selected", "optionId": "no"}})),
        "{lost}"
    );
    // A losing answer that carries a question's annotations (#24356) is told the same, not
    // refused for the annotations first.
    let mut annotated = answer("no", Some(&bo()));
    annotated["answers"] = json!({"Go?": "yes"});
    annotated["annotations"] = json!({"Go?": {"notes": "x"}});
    let lost_annotated = a.reply("_acpmux/permission_respond", annotated).await;
    assert_eq!(
        lost_annotated.pointer("/error/data"),
        lost.pointer("/error/data"),
        "{lost_annotated}"
    );
    c.reply_to(asked).await;
    let decided = a.records(&session, "permission_decision").await;
    assert_eq!(
        decided[0]["answeredBy"],
        json!({"id": "tailnet:ana@example.com", "name": "Ana"}),
        "{decided:?}"
    );

    // The owner's answer names no one.
    let asked =
        c.send("session/prompt", prompt(&session, "p-ask-2", "ask: rm -rf /tmp/y", None)).await;
    let pending = c
        .until(|v| {
            v["method"] == "_acpmux/permission_pending"
                && v["params"]["permissionId"] != permission.as_str()
        })
        .await;
    let second = pending["params"]["permissionId"].as_str().unwrap().to_owned();
    let respond = |author: Option<&Value>| {
        by(
            json!({"sessionId": session, "permissionId": second, "optionId": "no", "_meta": {"acpmux": {}}}),
            author,
        )
    };
    a.call("_acpmux/permission_respond", respond(None)).await;
    let lost = a.reply("_acpmux/permission_respond", respond(Some(&bo()))).await;
    assert_eq!(lost.pointer("/error/data/answeredBy"), Some(&Value::Null), "{lost}");
    c.reply_to(asked).await;
}

/// A supersede key (`supersede.rs`) knows agents and the owner only: a person's keyed prompt
/// neither replaces the owner's waiting one nor is replaced by it.
#[tokio::test]
async fn a_persons_prompt_neither_supersedes_nor_is_superseded() {
    let hub = hub();
    let mut c = Client::open(&hub);
    let session = c.new_session(json!({"harness": "fake"})).await;
    c.busy(&session).await;
    for (id, author) in [("p-owner", None), ("p-ana", Some(ana())), ("p-owner-2", None)] {
        let mut keyed = by(prompt(&session, id, id, None), author.as_ref());
        keyed["_meta"]["acpmux"]["supersede"] = json!("status");
        c.queue(keyed).await;
    }
    let removed = c.records(&session, "queue_removed").await;
    let gone: Vec<&Value> = removed.iter().map(|m| &m["promptId"]).collect();
    assert_eq!(gone, [&json!("p-owner")], "{removed:?}");
    c.cancel(&session).await;
}

/// An answer to an ask a Stop cancelled is told no one answered: the cancel goes in the settled
/// store with the drain (`permission_settled.rs`), before the asking task logs it.
#[tokio::test]
async fn an_answer_after_a_stop_is_told_the_ask_was_cancelled() {
    let hub = hub_policy(json!({}), "ask");
    let mut c = Client::open(&hub);
    let session = c.new_session(json!({"harness": "fake"})).await;
    let mut a = Client::open(&hub);
    let asked =
        c.send("session/prompt", prompt(&session, "p-ask", "ask: rm -rf /tmp/z", None)).await;
    let pending = c.until(|v| v["method"] == "_acpmux/permission_pending").await;
    let permission = pending["params"]["permissionId"].clone();
    c.cancel(&session).await;
    c.reply_to(asked).await;
    let late = by(
        json!({"sessionId": session, "permissionId": permission, "optionId": "no",
                         "_meta": {"acpmux": {}}}),
        Some(&bo()),
    );
    let lost = a.reply("_acpmux/permission_respond", late).await;
    assert_eq!(
        lost.pointer("/error/data"),
        Some(&json!({"answeredBy": null, "outcome": {"outcome": "cancelled"}})),
        "{lost}"
    );
}

/// A prompt is a person's or another sender's, never both: an author beside a provenance is
/// refused, so it never runs as an agent's message under the owner's queue rules.
#[tokio::test]
async fn an_author_beside_a_provenance_is_refused() {
    let hub = hub();
    let mut c = Client::open(&hub);
    let session = c.new_session(json!({"harness": "fake"})).await;
    let both = by(prompt(&session, "p-both", "hi", Some(&provenance(&session))), Some(&ana()));
    assert_eq!(reason(&c.reply("session/prompt", both).await), "author.value_refused");
    assert!(c.records(&session, "user_message").await.is_empty(), "a refused prompt ran");
}

/// A tool's notice (`_meta.acpmux.notice`, manaflow-ai/cmux notice prompt kind).
fn fire_notice() -> Value {
    json!({"sender": "base-red-watch", "host": "ci-mini-3", "severity": "fire",
           "title": "cmux-next fast tier failed on 3 PRs",
           "links": [{"url": "https://github.com/manaflow-ai/cmux/pull/32827", "label": "#32827"}]})
}

fn noticed(session: &str, prompt_id: &str, notice: &Value) -> Value {
    let mut p = prompt(session, prompt_id, "[notice from base-red-watch] body", None);
    p["_meta"]["acpmux"]["notice"] = notice.clone();
    p
}

/// What the daemon stamps for [`fire_notice`] to `to`.
fn stamped_notice(to: &str) -> Value {
    json!({"kind": "notice", "from": "fromAgent", "fromName": "base-red-watch", "to": to,
           "notice": fire_notice()})
}

/// Leo, 2026-11-03, on a base-red-watch page drawn as the person's bubble: "acpmux/cmux-next
/// should be able to allow you guys to make (and subsequently nicely render) this sort of thing".
/// A notice from the unix socket or a peer is recorded as one, run or queued, its unknown fields
/// dropped and its blocks as sent.
#[tokio::test]
async fn a_notice_is_recorded_on_its_user_message_and_its_queued_record() {
    let hub = hub();
    let mut c = Client::open(&hub);
    let session = c.new_session(json!({"harness": "fake"})).await;
    let mut sent = fire_notice();
    sent["extra"] = json!("dropped");
    for (origin, id) in [(Origin::Local, "n-unix"), (Origin::Peer, "n-peer")] {
        let mut from = Client::open_as(&hub, origin);
        from.call("session/prompt", noticed(&session, id, &sent)).await;
        let message = c.user_message(&session, id).await;
        let transport = if origin == Origin::Peer { "peer" } else { "unix" };
        assert_eq!(
            message.pointer("/_meta/provenance"),
            Some(&seen(stamped_notice(&session), transport)),
            "{origin:?}: {message}"
        );
        assert_eq!(message["text"], "[notice from base-red-watch] body", "{message}");
    }
    // Queued behind a running turn, it keeps its notice until it runs.
    c.busy(&session).await;
    let waiting = c.queue(noticed(&session, "n-q", &fire_notice())).await;
    let queued = c.records(&session, "queued").await;
    let queued = queued.iter().find(|m| m["promptId"] == "n-q").expect("its queued record");
    assert_eq!(
        queued.pointer("/_meta/provenance"),
        Some(&seen(stamped_notice(&session), "unix")),
        "{queued}"
    );
    c.cancel(&session).await;
    c.reply_to(waiting).await;
    let ran = c.user_message(&session, "n-q").await;
    assert_eq!(
        ran.pointer("/_meta/provenance"),
        Some(&seen(stamped_notice(&session), "unix")),
        "{ran}"
    );
}

/// A notice is a tool's, never the person's: one sent from inside a session names that session
/// for display (`fromSessionId`) and stays a notice, and one beside a person's author is still a
/// notice.
#[tokio::test]
async fn a_notice_from_inside_a_session_or_beside_an_author_stays_a_notice() {
    let hub = hub();
    let mut person = Client::open(&hub);
    let receiver = person.new_session(json!({"harness": "fake"})).await;
    let sender = person.new_session(json!({"harness": "fake"})).await;
    let mut inside = open_in_session(&hub, &sender).await;
    inside.call("session/prompt", noticed(&receiver, "n-in", &fire_notice())).await;
    let message = person.user_message(&receiver, "n-in").await;
    let provenance = message.pointer("/_meta/provenance").unwrap();
    assert_eq!(provenance["kind"], "notice", "{message}");
    assert_eq!(provenance["fromName"], "base-red-watch", "{message}");
    assert_eq!(provenance["fromSessionId"], json!(sender), "{message}");
    assert_eq!(provenance["notice"], fire_notice(), "{message}");

    let authored = by(noticed(&receiver, "n-author", &fire_notice()), Some(&ana()));
    person.call("session/prompt", authored).await;
    let message = person.user_message(&receiver, "n-author").await;
    assert_eq!(
        message.pointer("/_meta/provenance"),
        Some(&seen(stamped_notice(&receiver), "unix")),
        "{message}"
    );
}

/// No Web client, app pane or peer forwarding for its Web client may dress text up as a fire.
#[tokio::test]
async fn a_notice_from_a_web_client_is_refused() {
    let hub = hub();
    let mut local = Client::open(&hub);
    let session = local.new_session(json!({"harness": "fake"})).await;
    for (origin, via) in
        [(Origin::Web, None), (Origin::LocalApp, None), (Origin::Peer, Some("web"))]
    {
        let mut remote = Client::open_as(&hub, origin);
        let mut params = noticed(&session, "n-remote", &fire_notice());
        if let Some(via) = via {
            params["_meta"]["acpmux"]["via"] = json!(via);
        }
        let value = remote.reply("session/prompt", params).await;
        assert_eq!(reason(&value), "notice.origin_refused", "{origin:?} via {via:?}: {value}");
    }
    let ran = local.records(&session, "user_message").await;
    assert!(ran.iter().all(|m| m["promptId"] != "n-remote"), "a refused notice ran: {ran:?}");
}

/// A bad field refuses the prompt and names the field; nothing is dropped silently, and a notice
/// beside a caller's own provenance is refused too.
#[tokio::test]
async fn a_malformed_notice_is_refused_naming_its_field() {
    let hub = hub();
    let mut c = Client::open(&hub);
    let session = c.new_session(json!({"harness": "fake"})).await;
    let with = |key: &str, value: Value| {
        let mut n = fire_notice();
        n[key] = value;
        n
    };
    for (notice, field) in [
        (with("severity", json!("critical")), "severity"),
        (with("title", json!("a\nb")), "title"),
        (with("sender", json!("")), "sender"),
        (with("links", json!([{"url": "http://insecure.dev"}])), "links.url"),
        (json!(["not", "an", "object"]), "notice"),
    ] {
        let value = c.reply("session/prompt", noticed(&session, "n-bad", &notice)).await;
        assert_eq!(reason(&value), "notice.value_refused", "{notice}: {value}");
        assert_eq!(value.pointer("/error/data/field"), Some(&json!(field)), "{notice}: {value}");
    }
    let mut both = noticed(&session, "n-both", &fire_notice());
    both["_meta"]["acpmux"]["provenance"] = provenance(&session);
    let value = c.reply("session/prompt", both).await;
    assert_eq!(reason(&value), "notice.value_refused", "{value}");
    assert!(c.records(&session, "user_message").await.is_empty(), "a refused notice ran");
}

/// Review of #37497 (P1): a paired machine's `client` credential is served as Peer
/// (`pairing.rs` `origin_of`, `ConnAuth::Device`), but it is a client, not a peer daemon: its own
/// `personVerified` proves nothing, so its prompt is unverified. Only a peer daemon's own link
/// (`ConnAuth::PeerToken`) says of its connection that it proved the person.
#[tokio::test]
async fn only_a_peer_daemons_link_says_the_person_proved_a_prompt() {
    let hub = hub();
    let mut local = Client::open(&hub);
    let session = local.new_session(json!({"harness": "fake"})).await;
    for (auth, id) in [(ConnAuth::Device, "p-device"), (ConnAuth::PeerToken, "p-daemon")] {
        let mut c = Client::open_authed(&hub, Origin::Peer, auth);
        let mut params = prompt(&session, id, "hi", None);
        params["_meta"]["acpmux"]["personVerified"] = json!(true);
        c.call("session/prompt", params).await;
        let message = local.user_message(&session, id).await;
        match auth {
            ConnAuth::Device => assert_eq!(
                message.pointer("/_meta/provenance/kind"),
                Some(&json!("unverified")),
                "a paired client's own claim: {message}"
            ),
            _ => assert!(
                message.pointer("/_meta/provenance").is_none(),
                "a peer daemon's word is the person's: {message}"
            ),
        }
    }
}

/// What a script's own unix connection sends (`a_named_sender_is_verified_by_the_host_token`): an
/// acpmux CLI's `initialize` at a plain terminal (caller protocol 1, `terminal`, no caller
/// token), then one `session/prompt`.
#[cfg(unix)]
const SENDER_SCRIPT: &str = r#"
import json, socket, sys
path, params = sys.argv[1], json.loads(sys.argv[2])
s = socket.socket(socket.AF_UNIX)
s.connect(path)
f = s.makefile("rw")
def call(i, method, p):
    f.write(json.dumps({"jsonrpc": "2.0", "id": i, "method": method, "params": p}) + "\n")
    f.flush()
    for line in f:
        m = json.loads(line)
        if m.get("id") == i:
            return m
call(1, "initialize", {"protocolVersion": 1, "clientCapabilities": {},
     "clientInfo": {"name": "acpmux-cli", "version": "9.9.9"},
     "_meta": {"acpmux": {"callerProtocol": 1, "callerKind": "terminal"}}})
print(json.dumps(call(2, "session/prompt", params)))
"#;

/// Leo, 2026-11-11, on our own outbox relay's notice drawn as "Unverified sender": "generally the
/// "unverified sender" things should be more verified". Our own tools prove themselves with this
/// host's sender token (`sender_token.rs`, `~/.acpmux/sender-token`): a named sender (`--from`, a
/// notice's) whose local unix send carries it is `verified` by it. A wrong token, none, one from
/// the Web and a forged check are not. A token with no name changes nothing: it is the same send
/// as one without. The token is never stored.
#[cfg(unix)]
#[tokio::test]
async fn a_named_sender_is_verified_by_the_host_token() {
    // A session the Web may prompt (an asking mode and policy, `hub/web_control.rs`), so the
    // Web's send below reaches it.
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE]}},
        "defaultHarness": "fake",
        "permissionPolicy": "ask",
        "webAskingModes": {"fake": ["normal"]},
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    cfg.agent_inbox = Some(false);
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let mut owner = Client::open(&hub);
    let receiver = owner.new_session(json!({"harness": "fake"})).await;
    // `/tmp`, not the temp dir: a worker's can be too long for a socket path.
    let socket = std::path::PathBuf::from("/tmp")
        .join(format!("acpmux-sender-token-{}.sock", std::process::id()));
    let listener = acpmux::server::bind_unix(&socket).await.unwrap();
    tokio::spawn(acpmux::server::serve_unix(hub.clone(), listener));
    let dir = tempfile::tempdir().unwrap();
    let script = dir.path().join("sender.py");
    std::fs::write(&script, SENDER_SCRIPT).unwrap();
    // The host token, as the daemon makes it at start, in this process's daemon home.
    let home = acpmux::config::home();
    std::fs::create_dir_all(&home).unwrap();
    acpmux::sender_token::ensure(&home).unwrap();
    let token = acpmux::sender_token::read_trusted(&acpmux::sender_token::path_in(&home))
        .expect("the daemon's token");
    let wrong = "0".repeat(64);

    let send = |id: &'static str, fields: Value| {
        let mut params = prompt(&receiver, id, "#40611 conflicts with feat-cmux-next", None);
        for (key, value) in fields.as_object().unwrap() {
            params["_meta"]["acpmux"][key] = value.clone();
        }
        let (socket, script) = (socket.clone(), script.clone());
        async move {
            let out = tokio::process::Command::new("python3")
                .arg(&script)
                .arg(&socket)
                .arg(params.to_string())
                .output()
                .await
                .expect("run the sender script");
            let reply = String::from_utf8_lossy(&out.stdout).into_owned();
            assert!(out.status.success() && reply.contains("\"result\""), "{id}: {reply} {out:?}");
        }
    };
    let notice =
        |sender: &str| json!({"sender": sender, "severity": "warn", "title": "#40611 conflicts"});
    send("p-named", json!({"fromAgent": "outbox-relay", "senderToken": token})).await;
    send("p-notice", json!({"notice": notice("outbox-relay"), "senderToken": token})).await;
    send("p-unnamed", json!({"senderToken": token})).await;
    send("p-unnamed-plain", json!({})).await;
    // The outbox relay's own send as the CLI makes it under Xcode's python: no app, but the tool it
    // ran under (`sender_harness::from_chain`, review of #41064 at 8cc17ed2, F1).
    let tool = json!({"harness": "Python", "source": "process"});
    send("p-tool", json!({"senderToken": token, "senderHarness": tool})).await;
    send("p-wrong", json!({"fromAgent": "outbox-relay", "senderToken": wrong})).await;
    send("p-none", json!({"fromAgent": "outbox-relay"})).await;
    // The Web's token is dropped unread: a page cannot verify a name.
    let mut web = Client::open_authed(&hub, Origin::Web, ConnAuth::ListenerToken);
    let mut from_web = prompt(&receiver, "p-web", "hi", None);
    from_web["_meta"]["acpmux"]["fromAgent"] = json!("outbox-relay");
    from_web["_meta"]["acpmux"]["senderToken"] = json!(token);
    web.call("session/prompt", from_web).await;
    // Nor can an in-process connection with no socket peer, nor a forged check.
    let mut forged = prompt(&receiver, "p-forged", "hi", None);
    forged["_meta"]["acpmux"]["fromAgent"] = json!("outbox-relay");
    forged["_meta"]["acpmux"]["senderToken"] = json!(token);
    forged["_meta"]["acpmux"]["senderTokenChecked"] = json!(true);
    owner.call("session/prompt", forged).await;

    for (id, kind) in [("p-named", "agent_message"), ("p-notice", "notice")] {
        let message = owner.user_message(&receiver, id).await;
        let p = &message["_meta"]["provenance"];
        assert_eq!(p["kind"], kind, "{id}: {message}");
        assert_eq!(p["fromName"], "outbox-relay", "{id}: {message}");
        assert_eq!(p["verified"], true, "{id}: {message}");
        assert_eq!(p["verifiedBy"], "host-token", "{id}: {message}");
        // Verified by the token, it names no proven session: the sender record says how.
        let record = acpmux::prompt_provenance::sender_record(Some(p), None, None);
        assert_eq!(
            (&record["verification"], &record["verifiedBy"], &record["authenticated"]),
            (&json!("verified"), &json!("host-token"), &json!(false)),
            "{id}: {record}"
        );
    }
    // A name is needed: the token alone changes nothing about the send.
    let unnamed = owner.user_message(&receiver, "p-unnamed").await;
    let plain = owner.user_message(&receiver, "p-unnamed-plain").await;
    assert_eq!(
        unnamed.pointer("/_meta/origin"),
        plain.pointer("/_meta/origin"),
        "{unnamed} vs {plain}"
    );
    assert_eq!(
        unnamed.pointer("/_meta/provenance/kind"),
        plain.pointer("/_meta/provenance/kind"),
        "{unnamed} vs {plain}"
    );
    assert!(unnamed.pointer("/_meta/provenance/verifiedBy").is_none(), "{unnamed}");
    let tool = owner.user_message(&receiver, "p-tool").await;
    assert_eq!(tool.pointer("/_meta/provenance/verified"), Some(&json!(false)), "{tool}");
    assert!(tool.pointer("/_meta/provenance/verifiedBy").is_none(), "{tool}");
    for id in ["p-wrong", "p-none", "p-web", "p-forged"] {
        let message = owner.user_message(&receiver, id).await;
        let p = &message["_meta"]["provenance"];
        assert_ne!(p["verified"], true, "{id}: {message}");
        assert!(p.get("verifiedBy").is_none(), "{id}: {message}");
        let record = acpmux::prompt_provenance::sender_record(Some(p), None, None);
        assert_ne!(record["verification"], "verified", "{id}: {record}");
    }
    // None of the named ones is the person's, verified or not, nor a tool's unnamed send.
    for id in ["p-named", "p-notice", "p-wrong", "p-none", "p-web", "p-tool"] {
        let message = owner.user_message(&receiver, id).await;
        assert_eq!(message.pointer("/_meta/origin"), None, "{id}: {message}");
        assert!(message.pointer("/_meta/provenance").is_some(), "{id}: {message}");
    }
    // The token is in no record or event of the chat.
    let events = owner.call("_acpmux/events", json!({"sessionId": receiver})).await;
    let all = events.to_string();
    assert!(all.contains("p-named"), "the events were read");
    assert!(!all.contains(&token), "the token was stored");
    assert!(!all.contains("\"senderToken\""), "the token's key was stored");
    let _ = std::fs::remove_file(&socket);
}
