//! Fan-in (`hub/digest.rs`): the person's prompt goes ahead of the agent messages waiting for a
//! busy chat, and those messages go in together as one turn, each as it was sent, oldest first.
//! A coordinator had 121 queued messages, each its own turn, with the person's behind them all
//! (2026-10-20).

use super::*;

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
    let (_hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
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
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
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
    let (_hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = busy(&mut c).await;
    queue(&mut c, from_agent(&id, "p-a", "lane-a", "only one")).await;
    c.send(method::SESSION_CANCEL, json!({"sessionId": id})).await;
    assert_eq!(echoes_until(&mut c, "only one").await, ["echo: only one"]);
}

#[tokio::test]
async fn a_persons_prompt_between_agent_messages_ends_their_turn() {
    let (_hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
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
    c.send(method::SESSION_CANCEL, json!({"sessionId": id})).await;
    assert_eq!(
        echoes_until(&mut c, "from b").await,
        ["echo: from a", "echo: mine", "echo: from b"]
    );
}

#[tokio::test]
async fn from_agent_must_be_one_short_line() {
    let (_hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let refused =
        c.request(method::SESSION_PROMPT, from_agent(&id, "p-x", "two\nlines", "hello")).await;
    assert!(refused.as_ref().is_err_and(|e| e.contains("fromAgent")), "{refused:?}");
}
