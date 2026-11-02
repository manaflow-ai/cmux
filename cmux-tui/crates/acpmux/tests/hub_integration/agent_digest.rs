//! Fan-in (`hub/digest.rs`): the person's prompt goes ahead of the agent messages waiting for a
//! busy chat, and those messages go in together as one turn, each as it was sent, oldest first.
//! A coordinator had 121 queued messages, each its own turn, with the person's behind them all
//! (2026-10-20).

use super::*;
use acpmux::server::{Origin, serve_connection_with};

/// A prompt `fromAgent` names as `agent`'s message (`acpmux send --from`).
fn from_agent(id: &str, prompt_id: &str, agent: &str, text: &str) -> Value {
    json!({"sessionId": id, "prompt": [{"type": "text", "text": text}], "_meta": {"acpmux": {"promptId": prompt_id, "fromAgent": agent}}})
}

fn person(id: &str, prompt_id: &str, text: &str) -> Value {
    prompt(id, text, Some(prompt_id))
}

/// A session running an "until-cancel" turn.
async fn busy(c: &mut TestClient) -> String {
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    c.send(method::SESSION_PROMPT, person(&id, "p-turn", "until-cancel")).await;
    c.wait_for(method::SESSION_UPDATE, |p| p["update"]["content"]["text"] == "running").await;
    id
}

/// Ends the busy turn with an agent's Stop (`Hub::cancel`), so the agent messages queued behind
/// it go in next. The person's Stop holds them (`hub/cancel.rs`, `stop.rs`).
async fn end_busy(hub: &Arc<Hub>, id: &str) {
    hub.cancel(&hub.resolve(id).unwrap()).await.unwrap();
}

/// Sends `params` on `c` and waits until it is queued; returns its request id.
async fn queue(c: &mut TestClient, params: Value) -> i64 {
    let prompt_id = params["_meta"]["acpmux"]["promptId"].as_str().unwrap().to_owned();
    let rid = c.send(method::SESSION_PROMPT, params).await;
    c.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == *prompt_id && p["queued"] == true)
        .await;
    rid
}

async fn queue_order(c: &mut TestClient, id: &str) -> Vec<String> {
    let attached =
        c.request(method::MUX_ATTACH, json!({"sessionId": id, "limit": 0})).await.unwrap();
    attached["session"]["queue"]
        .as_array()
        .unwrap()
        .iter()
        .map(|q| q["promptId"].as_str().unwrap().to_owned())
        .collect()
}

/// The answers to the requests `ids` on `c`, in whatever order they come.
async fn answers(c: &mut TestClient, ids: &[i64]) -> BTreeMap<i64, Value> {
    let mut answered = BTreeMap::new();
    let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
    while answered.len() < ids.len() {
        let line = tokio::time::timeout_at(deadline, c.rx.recv())
            .await
            .unwrap_or_else(|_| panic!("unanswered: answered only {:?}", answered.keys()))
            .expect("connection closed");
        if let Message::Response { id, result, error } = Message::parse(&line).unwrap()
            && let Some(id) = id.as_i64().filter(|id| ids.contains(id))
        {
            assert!(error.is_none(), "request {id}: {error:?}");
            answered.insert(id, result.unwrap_or(Value::Null));
        }
    }
    answered
}

/// The agent's replies ("echo: <prompt>") up to the one that contains `last`.
async fn echoes_until(c: &mut TestClient, last: &str) -> Vec<String> {
    let seen = c
        .collect_until(|m, p| {
            m == method::SESSION_UPDATE
                && p["update"]["content"]["text"]
                    .as_str()
                    .is_some_and(|t| t.starts_with("echo: ") && t.contains(last))
        })
        .await;
    seen.iter()
        .filter(|(m, _)| m == method::SESSION_UPDATE)
        .filter_map(|(_, p)| p["update"]["content"]["text"].as_str())
        .filter(|t| t.starts_with("echo: "))
        .map(str::to_owned)
        .collect()
}

#[tokio::test]
async fn the_persons_prompt_goes_ahead_of_agent_messages_waiting() {
    let (_hub, mut c) = setup_queue(PermissionPolicy::ApproveAll).await;
    let id = busy(&mut c).await;
    queue(&mut c, from_agent(&id, "p-a", "lane-a", "from a")).await;
    queue(&mut c, from_agent(&id, "p-b", "lane-b", "from b")).await;
    queue(&mut c, person(&id, "p-me", "mine")).await;
    queue(&mut c, person(&id, "p-me2", "mine too")).await;
    queue(&mut c, from_agent(&id, "p-c", "lane-a", "from c")).await;
    // The person's prompts in the order sent, then the agents' in the order sent.
    assert_eq!(queue_order(&mut c, &id).await, ["p-me", "p-me2", "p-a", "p-b", "p-c"]);
}

#[tokio::test]
async fn agent_messages_waiting_go_in_together_as_one_turn_after_the_persons() {
    let (hub, mut c) = setup_queue(PermissionPolicy::ApproveAll).await;
    let mut agents = connect(&hub).await;
    let id = busy(&mut c).await;
    let a = queue(&mut agents, from_agent(&id, "p-a", "lane-a", "first from a")).await;
    // A `cmux agent message` (its provenance names the sender) is another agent's too.
    let mut message = from_agent(&id, "p-b", "unused", "second from b");
    message["_meta"]["acpmux"] = json!({"promptId": "p-b", "provenance": {"kind": "agent_message", "from": "acp:lane-b-id", "fromName": "lane-b", "to": format!("acp:{id}"), "msgId": "m-b", "threadId": "t-b"}});
    let b = queue(&mut agents, message).await;
    queue(&mut c, person(&id, "p-me", "mine")).await;
    let a2 = queue(&mut agents, from_agent(&id, "p-a2", "lane-a", "third from a")).await;

    c.send(method::SESSION_CANCEL, json!({"sessionId": id})).await;
    let echoes = echoes_until(&mut c, "third from a").await;
    assert_eq!(echoes.len(), 2, "the person's turn, then one turn of agent messages: {echoes:?}");
    assert_eq!(echoes[0], "echo: mine");
    let digest = &echoes[1];
    let at = |s: &str| digest.find(s).unwrap_or_else(|| panic!("{s:?} missing from {digest}"));
    assert!(digest.contains("3 messages from other agents arrived while you were busy"));
    assert!(at("[agent message 1 of 3] from lane-a") < at("first from a"));
    assert!(at("first from a") < at("[agent message 2 of 3] from lane-b"));
    assert!(at("[agent message 2 of 3] from lane-b") < at("second from b"));
    assert!(at("second from b") < at("[agent message 3 of 3] from lane-a"));
    assert!(at("[agent message 3 of 3] from lane-a") < at("third from a"));

    // Every agent's prompt is answered: the joined ones with the turn they went in with.
    let answered = answers(&mut agents, &[a, b, a2]).await;
    let first = &answered[&a];
    let turn = first["_meta"]["acpmux"]["turnId"].clone();
    assert_eq!(first["_meta"]["acpmux"]["promptId"], "p-a", "{first}");
    for (rid, prompt_id) in [(b, "p-b"), (a2, "p-a2")] {
        let answer = &answered[&rid];
        assert_eq!(answer["stopReason"], first["stopReason"], "{answer}");
        assert_eq!(answer["_meta"]["acpmux"]["promptId"], prompt_id, "{answer}");
        assert_eq!(answer["_meta"]["acpmux"]["joinedPromptId"], "p-a", "{answer}");
        assert_eq!(answer["_meta"]["acpmux"]["turnId"], turn, "{answer}");
    }

    // The log keeps who sent each message, and that the joined ones left the queue for it.
    let events = hub.events(&id, 0, 1000).unwrap();
    let digest = find(&events, "user_message")
        .into_iter()
        .find(|e| e.msg["promptId"] == "p-a")
        .expect("the digest's user_message");
    let provenance = &digest.msg["_meta"]["provenance"];
    assert_eq!(provenance["kind"], "agent_digest", "{provenance}");
    let senders: Vec<&str> = provenance["messages"]
        .as_array()
        .unwrap()
        .iter()
        .map(|m| m["from"].as_str().unwrap())
        .collect();
    assert_eq!(senders, ["lane-a", "lane-b", "lane-a"]);
    assert_eq!(provenance["messages"][1]["provenance"]["msgId"], "m-b", "{provenance}");
    let joined: Vec<&str> = find(&events, "dequeued")
        .into_iter()
        .filter(|e| e.msg["joinedPromptId"] == "p-a")
        .map(|e| e.msg["promptId"].as_str().unwrap())
        .collect();
    assert_eq!(joined, ["p-b", "p-a2"]);
}

#[tokio::test]
async fn one_agent_message_waiting_runs_as_it_was_sent() {
    let (hub, mut c) = setup_queue(PermissionPolicy::ApproveAll).await;
    let id = busy(&mut c).await;
    queue(&mut c, from_agent(&id, "p-a", "lane-a", "only one")).await;
    end_busy(&hub, &id).await;
    assert_eq!(echoes_until(&mut c, "only one").await, ["echo: only one"]);
}

#[tokio::test]
async fn a_persons_prompt_between_agent_messages_ends_their_turn() {
    let (hub, mut c) = setup_queue(PermissionPolicy::ApproveAll).await;
    let id = busy(&mut c).await;
    queue(&mut c, from_agent(&id, "p-a", "lane-a", "from a")).await;
    queue(&mut c, from_agent(&id, "p-b", "lane-b", "from b")).await;
    queue(&mut c, person(&id, "p-me", "mine")).await;
    // The person moved their prompt behind lane-a's: lane-b's message stays behind it.
    let moved = c
        .request(
            "_acpmux/queue_edit",
            json!({"sessionId": id, "promptId": "p-me", "op": "move", "index": 1}),
        )
        .await
        .unwrap();
    assert_eq!(moved["ok"], true, "{moved}");
    assert_eq!(queue_order(&mut c, &id).await, ["p-a", "p-me", "p-b"]);
    end_busy(&hub, &id).await;
    assert_eq!(
        echoes_until(&mut c, "from b").await,
        ["echo: from a", "echo: mine", "echo: from b"]
    );
}

#[tokio::test]
async fn from_agent_must_be_one_short_line() {
    let (_hub, mut c) = setup_queue(PermissionPolicy::ApproveAll).await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let refused =
        c.request(method::SESSION_PROMPT, from_agent(&id, "p-x", "two\nlines", "hello")).await;
    assert!(refused.as_ref().is_err_and(|e| e.contains("fromAgent")), "{refused:?}");
}

/// A failed turn holds the prompts behind it. The person's wait for the person; agent messages
/// go in once the chat completes a turn again (coord-deputy held 121 after one "agent process
/// closed", 2026-10-21, behind every newer message).
#[tokio::test]
async fn agent_messages_a_failed_turn_held_go_in_after_the_next_completed_turn() {
    let (hub, mut c) = setup_queue(PermissionPolicy::ApproveAll).await;
    // Their own retry (10 s by default) must not come first on a loaded machine.
    hub.config.write().await.auto_resume_delays_ms = Some(vec![120_000]);
    let id = busy(&mut c).await;
    queue(&mut c, person(&id, "p-f", "fail-streamed: boom")).await;
    queue(&mut c, from_agent(&id, "p-a", "lane-a", "held from a")).await;
    queue(&mut c, from_agent(&id, "p-b", "lane-b", "held from b")).await;
    queue(&mut c, person(&id, "p-me", "mine")).await;
    assert_eq!(queue_order(&mut c, &id).await, ["p-f", "p-me", "p-a", "p-b"]);
    c.send(method::SESSION_CANCEL, json!({"sessionId": id})).await;
    c.wait_for(method::SESSION_UPDATE, |p| p["update"]["content"]["text"] == "boom").await;
    let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    loop {
        let attached =
            c.request(method::MUX_ATTACH, json!({"sessionId": id, "limit": 0})).await.unwrap();
        // The turn ends a moment before its failure holds the queue (`finish_turn`).
        if attached["session"]["turn"].is_null() && attached["session"]["queuePaused"] == true {
            break;
        }
        assert!(tokio::time::Instant::now() < deadline, "the queue was never held: {attached}");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert_eq!(queue_order(&mut c, &id).await, ["p-me", "p-a", "p-b"]);

    // A new prompt completes: the held agent messages go in together; the person's still waits.
    c.send(method::SESSION_PROMPT, person(&id, "p-next", "next")).await;
    let echoes = echoes_until(&mut c, "held from b").await;
    assert_eq!(echoes.len(), 2, "{echoes:?}");
    assert_eq!(echoes[0], "echo: next");
    assert!(echoes[1].contains("held from a") && echoes[1].contains("[agent message 2 of 2]"));
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(queue_order(&mut c, &id).await, ["p-me"], "the person's held prompt still waits");
}

/// A turn of agent messages that fails puts the messages that joined it back, held, in order:
/// none is lost to a turn the agent may never have read. The next completed turn releases them.
#[tokio::test]
async fn a_failed_turn_of_agent_messages_puts_the_joined_ones_back() {
    let (hub, mut c) = setup_queue(PermissionPolicy::ApproveAll).await;
    let mut agents = connect(&hub).await;
    let id = busy(&mut c).await;
    let a = queue(&mut agents, from_agent(&id, "p-a", "lane-a", "from a")).await;
    let b = queue(&mut agents, from_agent(&id, "p-b", "lane-b", "[fail-digest-once] from b")).await;
    let d = queue(&mut agents, from_agent(&id, "p-c", "lane-c", "from c")).await;
    end_busy(&hub, &id).await;
    // The head's sender hears the failure, as for any failed prompt.
    let failed = agents.response(a).await.0;
    assert!(failed.is_err(), "{failed:?}");
    let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    loop {
        let attached =
            c.request(method::MUX_ATTACH, json!({"sessionId": id, "limit": 0})).await.unwrap();
        if attached["session"]["turn"].is_null() && queue_order(&mut c, &id).await.len() == 2 {
            break;
        }
        assert!(tokio::time::Instant::now() < deadline, "not put back: {attached}");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert_eq!(queue_order(&mut c, &id).await, ["p-b", "p-c"]);

    c.send(method::SESSION_PROMPT, person(&id, "p-next", "next")).await;
    let echoes = echoes_until(&mut c, "from c").await;
    assert_eq!(echoes.len(), 2, "{echoes:?}");
    assert_eq!(echoes[0], "echo: next");
    assert!(echoes[1].contains("[agent message 1 of 2] from lane-b"), "{echoes:?}");
    assert!(echoes[1].contains("[agent message 2 of 2] from lane-c"), "{echoes:?}");
    // p-b led the second turn; p-c went in with it.
    let answered = answers(&mut agents, &[b, d]).await;
    assert_eq!(answered[&b]["_meta"]["acpmux"]["promptId"], "p-b", "{answered:?}");
    assert_eq!(answered[&d]["_meta"]["acpmux"]["promptId"], "p-c", "{answered:?}");
    assert_eq!(answered[&d]["_meta"]["acpmux"]["joinedPromptId"], "p-b", "{answered:?}");
    assert!(queue_order(&mut c, &id).await.is_empty());
}

/// A message a failed turn of agent messages put back is queued again with its pasted ranges
/// (`_meta.cmux.pasted`), as when it was first queued.
#[tokio::test]
async fn a_message_a_failed_turn_put_back_keeps_its_pasted_ranges() {
    let (hub, mut c) = setup_queue(PermissionPolicy::ApproveAll).await;
    let mut agents = connect(&hub).await;
    let id = busy(&mut c).await;
    let a = queue(&mut agents, from_agent(&id, "p-a", "lane-a", "from a")).await;
    queue(&mut agents, from_agent(&id, "p-b", "lane-b", "[fail-digest-once] from b")).await;
    let mut pasted = from_agent(&id, "p-c", "lane-c", "🦀 from c");
    pasted["prompt"]
        .as_array_mut()
        .unwrap()
        .push(json!({"type": "text", "text": "a log", "_meta": {"cmux": {"pasted": true}}}));
    queue(&mut agents, pasted).await;
    end_busy(&hub, &id).await;
    assert!(agents.response(a).await.0.is_err());
    let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    let requeued = loop {
        let page = c
            .request(method::MUX_EVENTS, json!({"sessionId": id, "afterSeq": 0, "limit": 5000}))
            .await
            .unwrap();
        let found = page["events"].as_array().unwrap().iter().find(|e| {
            e["kind"] == "queued" && e["msg"]["promptId"] == "p-c" && e["msg"]["requeued"] == true
        });
        if let Some(e) = found {
            break e["msg"].clone();
        }
        assert!(tokio::time::Instant::now() < deadline, "p-c not put back: {page}");
        tokio::time::sleep(Duration::from_millis(50)).await;
    };
    assert_eq!(requeued["text"], "🦀 from c\na log", "{requeued}");
    // 🦀 is two UTF-16 units: "🦀 from c" is 9, and the paste starts after its "\n".
    assert_eq!(requeued["pasted"], json!([{"start": 10, "end": 15}]), "{requeued}");
}

/// Another agent's message after a failed turn of agent messages put some back waits behind
/// them and goes in with them, in the order sent: it never overtakes them.
#[tokio::test]
async fn a_new_agent_message_goes_in_behind_the_ones_a_failed_turn_put_back() {
    let (hub, mut c) = setup_queue(PermissionPolicy::ApproveAll).await;
    let mut agents = connect(&hub).await;
    let id = busy(&mut c).await;
    let a = queue(&mut agents, from_agent(&id, "p-a", "lane-a", "from a")).await;
    queue(&mut agents, from_agent(&id, "p-b", "lane-b", "[fail-digest-once] from b")).await;
    queue(&mut agents, from_agent(&id, "p-c", "lane-c", "from c")).await;
    end_busy(&hub, &id).await;
    assert!(agents.response(a).await.0.is_err());
    let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    loop {
        let attached =
            c.request(method::MUX_ATTACH, json!({"sessionId": id, "limit": 0})).await.unwrap();
        if attached["session"]["turn"].is_null() && queue_order(&mut c, &id).await.len() == 2 {
            break;
        }
        assert!(tokio::time::Instant::now() < deadline, "not put back: {attached}");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }

    // From the sender of one put back, too: it still goes last.
    queue(&mut agents, from_agent(&id, "p-d", "lane-b", "from d")).await;
    let echoes = echoes_until(&mut c, "from d").await;
    assert_eq!(echoes.len(), 1, "{echoes:?}");
    let text = &echoes[0];
    let at = |s: &str| text.find(s).unwrap_or_else(|| panic!("{s:?} missing from {text}"));
    assert!(at("[agent message 1 of 3] from lane-b") < at("from b"));
    assert!(at("from b") < at("[agent message 2 of 3] from lane-c"));
    assert!(at("[agent message 2 of 3] from lane-c") < at("from c"));
    assert!(at("from c") < at("[agent message 3 of 3] from lane-b"));
    assert!(at("[agent message 3 of 3] from lane-b") < at("from d"));
}

/// The app pane's reply in place (IncomingMessageCard.tsx) answers a message that went in with
/// other agents' messages, as it answers one that went in alone.
#[tokio::test]
async fn a_message_that_went_in_with_others_takes_a_reply_in_place() {
    let (hub, mut c) = setup_queue(PermissionPolicy::ApproveAll).await;
    let sender = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await;
    let sender = sender.unwrap()["sessionId"].as_str().unwrap().to_owned();
    let id = busy(&mut c).await;
    // `cmux agent message` from `sender`'s chat, twice.
    let message = |prompt_id: &str, msg_id: &str, text: &str| {
        let provenance = json!({"kind": "agent_message", "from": format!("acp:{sender}"), "fromName": "builder",
                                "to": format!("acp:{id}"), "msgId": msg_id, "threadId": "thread-1"});
        json!({"sessionId": id, "prompt": [{"type": "text", "text": text}],
               "_meta": {"acpmux": {"promptId": prompt_id, "provenance": provenance}}})
    };
    queue(&mut c, message("p-0", "msg-0", "first")).await;
    queue(&mut c, message("p-1", "msg-1", "second")).await;
    end_busy(&hub, &id).await;
    let echoes = echoes_until(&mut c, "second").await;
    assert!(echoes.last().unwrap().contains("[agent message 2 of 2] from builder"), "{echoes:?}");

    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::LocalApp));
    let mut app = TestClient { tx: in_tx, rx: out_rx, next: 0 };
    let init = json!({"protocolVersion": 1, "clientInfo": {"name": "test"}});
    app.request(method::INITIALIZE, init).await.unwrap();
    app.request(method::MUX_ATTACH, json!({"sessionId": id, "limit": 0})).await.unwrap();
    // A reply to the second, which joined the first's turn (`server/app_reply.rs`).
    let params = json!({"sessionId": id, "to": sender, "replyTo": "msg-1", "threadId": "thread-1",
                        "text": "Got it.", "replyId": "m-reply"});
    let answered = app.request(method::MUX_APP_REPLY, params).await;
    let reply_to = answered.as_ref().ok().map(|a| a["reply"]["replyTo"].clone());
    assert_eq!(reply_to, Some(json!("msg-1")), "{answered:?}");
}

/// An agent's slash command (`/compact`) runs only as a turn's first words: it goes in alone,
/// and the agent messages around it go in together before and after it.
#[tokio::test]
async fn an_agent_slash_command_goes_in_alone() {
    let (hub, mut c) = setup_queue(PermissionPolicy::ApproveAll).await;
    let id = busy(&mut c).await;
    queue(&mut c, from_agent(&id, "p-a", "lane-a", "from a")).await;
    queue(&mut c, from_agent(&id, "p-b", "lane-b", "from b")).await;
    queue(&mut c, from_agent(&id, "p-cmd", "lane-a", "/compact")).await;
    queue(&mut c, from_agent(&id, "p-c", "lane-c", "from c")).await;
    end_busy(&hub, &id).await;
    let echoes = echoes_until(&mut c, "from c").await;
    assert_eq!(echoes.len(), 3, "{echoes:?}");
    assert!(echoes[0].contains("[agent message 2 of 2] from lane-b"), "{echoes:?}");
    assert_eq!(echoes[1], "echo: /compact");
    assert_eq!(echoes[2], "echo: from c");
}

/// Agent messages a failed turn held never wait for a person, nor for a turn that may never come
/// (an agent that died does not complete one): they go in again by themselves after the
/// `autoResumeDelaysMs` wait, with no Resume. The person's held prompt still waits for them.
#[tokio::test]
async fn agent_messages_a_failed_turn_held_go_in_by_themselves() {
    let (hub, mut c) = setup_queue(PermissionPolicy::ApproveAll).await;
    hub.config.write().await.auto_resume_delays_ms = Some(vec![50]);
    let id = busy(&mut c).await;
    queue(&mut c, person(&id, "p-f", "fail-streamed: boom")).await;
    queue(&mut c, from_agent(&id, "p-a", "lane-a", "held from a")).await;
    queue(&mut c, from_agent(&id, "p-b", "lane-b", "held from b")).await;
    queue(&mut c, person(&id, "p-me", "mine")).await;
    end_busy(&hub, &id).await;
    c.wait_for(method::SESSION_UPDATE, |p| p["update"]["content"]["text"] == "boom").await;

    // Nobody sends anything: the held agent messages go in together.
    let echoes = echoes_until(&mut c, "held from b").await;
    assert_eq!(echoes.len(), 1, "{echoes:?}");
    assert!(echoes[0].contains("held from a") && echoes[0].contains("[agent message 2 of 2]"));
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(queue_order(&mut c, &id).await, ["p-me"], "the person's held prompt still waits");
}
