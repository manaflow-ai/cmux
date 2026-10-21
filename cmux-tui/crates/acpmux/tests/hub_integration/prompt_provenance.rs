//! A prompt's provenance at the daemon boundary (cx-55d27): `_meta.acpmux.provenance` on
//! `session/prompt` names the agent that sent it (`cmux agent message`). The recorded
//! `user_message` carries it as `_meta.provenance`, a queued prompt keeps it until it runs, a
//! steer records it, and an edit of the waiting prompt drops it. Only the unix socket may
//! send it. The app pane's reply in place is no prompt: `_acpmux/app_reply` checks it (from a
//! chat this connection shows, to the chat that sent it the message `replyTo` names) and answers
//! it signed, and the app sends it as that chat's cmux agent message (`server/app_reply.rs`;
//! cmux-tui tests/agent_message_reply_in_place.rs covers the daemon side).
//! A prompt from inside another session that names none gets that session as its sender
//! (`session_message`).

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

fn hub_env(env: Value) -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE], "family": "codex", "env": env}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all"
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

fn hub() -> Arc<Hub> {
    hub_env(json!({}))
}

/// What `cmux agent message` sends with a message to session `to`.
fn provenance(to: &str) -> Value {
    json!({"kind": "agent_message", "from": "acp:sender-1", "fromName": "builder", "to": format!("acp:{to}"),
           "msgId": "msg-1", "threadId": "thread-1", "replyTo": "msg-0"})
}

fn prompt(session: &str, prompt_id: &str, text: &str, provenance: Option<&Value>) -> Value {
    let mut mux = json!({"promptId": prompt_id});
    if let Some(p) = provenance {
        mux["provenance"] = p.clone();
    }
    json!({"sessionId": session, "prompt": [{"type": "text", "text": text}], "_meta": {"acpmux": mux}})
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

    /// Sends a request without waiting for its reply; returns its id.
    async fn send(&mut self, method: &str, params: Value) -> i64 {
        self.2 += 1;
        self.0.send(Message::request(self.2, method, params).to_line()).await.unwrap();
        self.2
    }

    /// The first message that matches `pred`; every other one is dropped.
    async fn until(&mut self, pred: impl Fn(&Value) -> bool) -> Value {
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
    async fn reply_to(&mut self, id: i64) -> Value {
        self.until(|v| v.get("id") == Some(&json!(id))).await
    }

    async fn reply(&mut self, method: &str, params: Value) -> Value {
        let id = self.send(method, params).await;
        self.reply_to(id).await
    }

    async fn call(&mut self, method: &str, params: Value) -> Value {
        let value = self.reply(method, params).await;
        assert!(value.get("error").is_none(), "{method}: {value}");
        value["result"].clone()
    }

    async fn new_session(&mut self, mux: Value) -> String {
        let created = self
            .call(
                "session/new",
                json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": mux}}),
            )
            .await;
        created["sessionId"].as_str().unwrap().to_owned()
    }

    /// The session's records of `kind`, oldest first (their `msg`).
    async fn records(&mut self, session: &str, kind: &str) -> Vec<Value> {
        let page =
            self.call("_acpmux/events", json!({"sessionId": session, "kinds": [kind]})).await;
        page["events"].as_array().unwrap().iter().map(|e| e["msg"].clone()).collect()
    }

    async fn user_message(&mut self, session: &str, prompt_id: &str) -> Value {
        let found = self.records(session, "user_message").await;
        found.into_iter().find(|m| m["promptId"] == prompt_id).expect("its user_message")
    }

    /// Starts an "until-cancel" turn and waits until it runs.
    async fn busy(&mut self, session: &str) {
        self.send("session/prompt", prompt(session, "p-run", "until-cancel", None)).await;
        self.until(|v| v.pointer("/params/update/content/text") == Some(&json!("running"))).await;
    }

    /// Queues a prompt behind the running turn; returns its request id.
    async fn queue(&mut self, params: Value) -> i64 {
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

    async fn cancel(&mut self, session: &str) {
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
    assert_eq!(first.pointer("/_meta/provenance"), Some(&p), "{first}");
    let second = c.user_message(&session, "p-b").await;
    assert!(second.pointer("/_meta/provenance").is_none(), "{second}");
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
    assert_eq!(queued.pointer("/_meta/provenance"), Some(&p), "{queued}");

    c.cancel(&session).await;
    let done = c.reply_to(waiting).await;
    assert_eq!(done.pointer("/result/stopReason"), Some(&json!("end_turn")), "{done}");
    let ran = c.user_message(&session, "p-q").await;
    assert_eq!(ran["text"], "queued message", "{ran}");
    assert_eq!(ran.pointer("/_meta/provenance"), Some(&p), "{ran}");
}

#[tokio::test]
async fn an_edit_of_a_queued_prompt_drops_its_provenance() {
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
    assert!(ran.pointer("/_meta/provenance").is_none(), "an edited prompt kept it: {ran}");
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
    assert_eq!(steered.pointer("/_meta/provenance"), Some(&p), "{steered}");
    let own = c.user_message(&session, "p-turn").await;
    assert!(own.pointer("/_meta/provenance").is_none(), "{own}");
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
    let stamped =
        json!({"kind": "session_message", "from": sender, "fromName": name, "to": receiver});
    assert_eq!(from_lane.pointer("/_meta/provenance"), Some(&stamped), "{from_lane}");
    let own = person.user_message(&sender, "p-self").await;
    assert!(own.pointer("/_meta/provenance").is_none(), "{own}");
    let theirs = person.user_message(&receiver, "p-person").await;
    assert!(theirs.pointer("/_meta/provenance").is_none(), "{theirs}");
    let kept = person.user_message(&receiver, "p-given").await;
    assert_eq!(kept.pointer("/_meta/provenance"), Some(&given), "{kept}");
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
