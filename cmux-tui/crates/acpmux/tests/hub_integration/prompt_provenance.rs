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
use acpmux::server::{Origin, serve_connection_with};
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
    // With the sending session's id and harness family, bound from its caller token.
    let stamped = json!({"kind": "session_message", "from": sender, "fromName": name, "to": receiver,
                         "fromSessionId": sender, "fromHarness": "codex"});
    assert_eq!(from_lane.pointer("/_meta/provenance"), Some(&stamped), "{from_lane}");
    let own = person.user_message(&sender, "p-self").await;
    assert!(own.pointer("/_meta/provenance").is_none(), "{own}");
    let theirs = person.user_message(&receiver, "p-person").await;
    assert!(theirs.pointer("/_meta/provenance").is_none(), "{theirs}");
    let kept = person.user_message(&receiver, "p-given").await;
    let mut bound = given.clone();
    bound["fromSessionId"] = json!(sender);
    bound["fromHarness"] = json!("codex");
    assert_eq!(kept.pointer("/_meta/provenance"), Some(&bound), "{kept}");
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

    for (id, from) in
        [("p-peer", "codex-lane"), ("p-cli", "codex-lane-2"), ("p-namesake", own.as_str())]
    {
        let message = person.user_message(&receiver, id).await;
        let stamped =
            json!({"kind": "agent_message", "from": "fromAgent", "fromName": from, "to": receiver});
        assert_eq!(message.pointer("/_meta/provenance"), Some(&stamped), "{message}");
    }
    // A note a session addresses to itself, and the person's own prompt, are no one else's message.
    for id in ["p-self", "p-person"] {
        let message = person.user_message(&receiver, id).await;
        assert!(message.pointer("/_meta/provenance").is_none(), "{message}");
    }
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
        assert_eq!(message.pointer("/_meta/provenance"), Some(&anas()), "{origin:?}: {message}");
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
    assert_eq!(queued.pointer("/_meta/provenance"), Some(&anas()), "{queued}");
    c.cancel(&session).await;
    c.reply_to(waiting).await;
    let ran = c.user_message(&session, "p-q").await;
    assert_eq!(ran.pointer("/_meta/provenance"), Some(&anas()), "{ran}");

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
    assert_eq!(steered.pointer("/_meta/provenance"), Some(&anas()), "{steered}");
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
    assert_eq!(anas_edit.pointer("/_meta/provenance"), Some(&anas()), "{anas_edit}");
    let remove =
        by(json!({"sessionId": session, "promptId": "p-owner", "_meta": {"acpmux": {}}}), None);
    assert_eq!(c.call("_acpmux/queue_remove", remove).await["removed"], true);

    // The turn stops, and the two left run in order: p-agent's answer comes last.
    c.cancel(&session).await;
    c.reply_to(waits[2]).await;
    let ran = c.user_message(&session, "p-ana").await;
    assert_eq!(ran["text"], "rewrite", "{ran}");
    assert_eq!(ran.pointer("/_meta/provenance"), Some(&anas()), "her edit lost her name: {ran}");
    let theirs = c.user_message(&session, "p-agent").await;
    assert!(
        theirs.pointer("/_meta/provenance").is_none(),
        "the owner's edit kept the agent's: {theirs}"
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
