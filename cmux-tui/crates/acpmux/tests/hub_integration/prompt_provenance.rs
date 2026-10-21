//! A prompt's provenance at the daemon boundary (cx-55d27): `_meta.acpmux.provenance` on
//! `session/prompt` names the agent that sent it (`cmux agent message`). The recorded
//! `user_message` carries it as `_meta.provenance`, a queued prompt keeps it until it runs, a
//! steer records it, and an edit of the waiting prompt drops it. Only the unix socket may
//! send it, except the app pane's reply in place: from a chat here, to the chat that sent it
//! the message `replyTo` names.

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

/// The app pane's reply in place (IncomingMessageCard.tsx): chat `from` answers message `msg-0`
/// of thread `thread-1`, which chat `to` sent it, under the addresses `cmux agent message` uses
/// (`acp:<id>`) and with no name: acpmux signs it with the chat's own.
fn app_reply(from: &str, to: &str) -> Value {
    json!({"kind": "agent_message", "from": format!("acp:{from}"), "to": format!("acp:{to}"),
           "msgId": "m-reply", "threadId": "thread-1", "replyTo": "msg-0"})
}

#[tokio::test]
async fn the_app_pane_may_send_a_reply_from_a_chat_here_and_nothing_else() {
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
    // The pane shows the chat the message came to; it holds the sender's chat unseen to reply.
    let shown = app.call("_acpmux/attach", json!({"sessionId": replier, "limit": 0})).await;
    app.call("_acpmux/attach", json!({"sessionId": sender, "limit": 0, "visible": false})).await;

    // A reply from the chat the message came to, to the chat that sent it: recorded with the
    // replying chat's address, so the sender's chat links it back, and signed with its name.
    let reply = app_reply(&replier, &sender);
    app.call("session/prompt", prompt(&sender, "p-reply", "Rebased; tests pass.", Some(&reply)))
        .await;
    let ran = local.user_message(&sender, "p-reply").await;
    assert_eq!(ran["text"], "Rebased; tests pass.", "{ran}");
    // Signed with the replying chat's own name: its title, its name or its id.
    let own_name = ran.pointer("/_meta/provenance/fromName").cloned().unwrap_or_default();
    let info = local.call("_acpmux/info", json!({"sessionId": replier})).await;
    let names: Vec<&str> =
        [&shown["session"]["title"], &shown["session"]["name"], &info["title"], &info["name"]]
            .into_iter()
            .filter_map(Value::as_str)
            .map(str::trim)
            .chain([replier.as_str()])
            .collect();
    assert!(own_name.as_str().is_some_and(|n| names.contains(&n)), "{own_name} not in {names:?}");
    let mut signed = reply.clone();
    signed["fromName"] = own_name.clone();
    assert_eq!(ran.pointer("/_meta/provenance"), Some(&signed), "{ran}");

    // Not a reply, a reply to a message the chat never got, a sender that is no chat here, the
    // prompt's own chat as its sender, a `to` that is not the prompt's chat, or a bare id for
    // either address: refused.
    let mut no_reply_to = app_reply(&replier, &sender);
    no_reply_to.as_object_mut().unwrap().remove("replyTo");
    let mut unknown_message = app_reply(&replier, &sender);
    unknown_message["replyTo"] = json!("msg-never-sent");
    let mut bare_from = app_reply(&replier, &sender);
    bare_from["from"] = json!(replier);
    let mut bare_to = app_reply(&replier, &sender);
    bare_to["to"] = json!(sender);
    let refused = [
        no_reply_to,
        unknown_message,
        app_reply("nobody", &sender),
        app_reply(&sender, &sender),
        app_reply(&replier, &replier),
        bare_from,
        bare_to,
    ];
    for bad in refused {
        let value = app.reply("session/prompt", prompt(&sender, "p-bad", "hi", Some(&bad))).await;
        assert_eq!(
            value.pointer("/error/data/reason"),
            Some(&json!("provenance.origin_refused")),
            "{bad}: {value}"
        );
    }
    let ran = local.records(&sender, "user_message").await;
    assert_eq!(ran.len(), 1, "a refused reply ran: {ran:?}");

    // Default deny for what the pane signs (cx-kybz1 review): a `from` chat this pane does not
    // show (not attached, or only held unseen), or a thread that is not the message's.
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
    let mut wrong_thread = app_reply(&replier, &sender);
    wrong_thread["threadId"] = json!("thread-other");
    let unscoped = [app_reply(&unattached, &sender), app_reply(&unseen, &sender), wrong_thread];
    for bad in unscoped {
        let value = app.reply("session/prompt", prompt(&sender, "p-bad", "hi", Some(&bad))).await;
        assert_eq!(
            value.pointer("/error/data/reason"),
            Some(&json!("provenance.origin_refused")),
            "{bad}: {value}"
        );
    }
    let ran = local.records(&sender, "user_message").await;
    assert_eq!(ran.len(), 1, "a refused reply ran: {ran:?}");

    // A name the pane picks never signs the reply: acpmux records the chat's own instead, so a
    // stale title after a rename is not refused either.
    let mut posing = app_reply(&replier, &sender);
    posing["fromName"] = json!("Chief");
    app.call("session/prompt", prompt(&sender, "p-posing", "Named.", Some(&posing))).await;
    let ran = local.user_message(&sender, "p-posing").await;
    assert_eq!(ran.pointer("/_meta/provenance/fromName"), Some(&own_name), "{ran}");

    // A remote browser may not send even a reply.
    let mut web = Client::open_as(&hub, Origin::Web);
    let value = web.reply("session/prompt", prompt(&sender, "p-web", "hi", Some(&reply))).await;
    assert_eq!(
        value.pointer("/error/data/reason"),
        Some(&json!("provenance.origin_refused")),
        "{value}"
    );
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
