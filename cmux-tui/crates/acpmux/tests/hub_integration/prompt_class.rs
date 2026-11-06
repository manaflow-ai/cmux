//! `_meta.acpmux.class` on `session/prompt` (`acpmux send --class`, `prompt_class.rs`): what
//! another agent's message asks of the chat. It is stored on the queued prompt (its `queued`
//! record, so a restart keeps it) and shown in each queue row as `class`: `result` for an agent's
//! message that named none, null for the person's own prompt. An edit makes the prompt the
//! person's and drops it. Anything but the four classes is refused.

use super::*;

/// What `acpmux send --from AGENT [--class CLASS]` sends.
fn from_agent(id: &str, prompt_id: &str, agent: &str, class: Option<&str>) -> Value {
    let mut mux = json!({"promptId": prompt_id, "fromAgent": agent});
    if let Some(class) = class {
        mux["class"] = json!(class);
    }
    json!({"sessionId": id, "prompt": [{"type": "text", "text": format!("from {agent}")}], "_meta": {"acpmux": mux}})
}

/// A session running an "until-cancel" turn.
async fn busy(c: &mut TestClient) -> String {
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    c.send(method::SESSION_PROMPT, prompt(&id, "until-cancel", Some("p-turn"))).await;
    c.wait_for(method::SESSION_UPDATE, |p| p["update"]["content"]["text"] == "running").await;
    id
}

/// Sends `params` on `c` and waits until it is queued.
async fn queue(c: &mut TestClient, params: Value) {
    let prompt_id = params["_meta"]["acpmux"]["promptId"].as_str().unwrap().to_owned();
    c.send(method::SESSION_PROMPT, params).await;
    c.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == *prompt_id && p["queued"] == true)
        .await;
}

/// Each queue row's `promptId` and `class`, in run order.
async fn classes(c: &mut TestClient, id: &str) -> Vec<(String, Value)> {
    let attached =
        c.request(method::MUX_ATTACH, json!({"sessionId": id, "limit": 0})).await.unwrap();
    let rows = attached["session"]["queue"].as_array().unwrap().clone();
    rows.iter().map(|q| (q["promptId"].as_str().unwrap().to_owned(), q["class"].clone())).collect()
}

fn rows(expected: &[(&str, Value)]) -> Vec<(String, Value)> {
    expected.iter().map(|(id, class)| ((*id).to_owned(), class.clone())).collect()
}

#[tokio::test]
async fn a_class_is_stored_on_the_queued_prompt_and_shown_in_its_row() {
    let (hub, mut c) = setup_queue(PermissionPolicy::ApproveAll).await;
    let id = busy(&mut c).await;
    queue(&mut c, from_agent(&id, "p-block", "lane-a", Some("block"))).await;
    queue(&mut c, from_agent(&id, "p-plain", "lane-b", None)).await;
    queue(&mut c, from_agent(&id, "p-fyi", "lane-c", Some("fyi"))).await;
    // The person's own prompt has no class, whatever it says.
    let mut mine = prompt(&id, "mine", Some("p-me"));
    mine["_meta"]["acpmux"]["class"] = json!("question");
    queue(&mut c, mine).await;

    let expected = rows(&[
        ("p-me", Value::Null),
        ("p-block", json!("block")),
        ("p-plain", json!("result")),
        ("p-fyi", json!("fyi")),
    ]);
    assert_eq!(classes(&mut c, &id).await, expected);
    // The composers' queue says the same.
    let composers =
        c.request(method::MUX_COMPOSERS, json!({"sessionId": id})).await.unwrap()["queue"].clone();
    let listed: Vec<_> = composers.as_array().unwrap().iter().map(|q| q["class"].clone()).collect();
    assert_eq!(listed, [Value::Null, json!("block"), json!("result"), json!("fyi")]);
    // Each `queued` record carries it, so a restart rebuilds it.
    let events = hub.events(&id, 0, 1000).unwrap();
    let recorded: Vec<_> = find(&events, "queued")
        .into_iter()
        .map(|e| (e.msg["promptId"].as_str().unwrap().to_owned(), e.msg["class"].clone()))
        .collect();
    let mut sent = expected.clone();
    sent.rotate_left(1);
    assert_eq!(recorded, sent);

    // An edit makes it the person's: its class goes with its sender.
    let edit = json!({"sessionId": id, "promptId": "p-block", "op": "update", "text": "rewritten"});
    let edited = c.request(method::MUX_QUEUE_EDIT, edit).await.unwrap();
    assert_eq!(edited["ok"], true, "{edited}");
    let after = classes(&mut c, &id).await;
    assert_eq!(after.iter().find(|(p, _)| p == "p-block").unwrap().1, Value::Null, "{after:?}");
    c.send(method::SESSION_CANCEL, json!({"sessionId": id})).await;
}

#[tokio::test]
async fn a_class_that_is_not_one_of_the_four_is_refused() {
    let (_hub, mut c) = setup_queue(PermissionPolicy::ApproveAll).await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    for bad in [json!("urgent"), json!("Block"), json!(3)] {
        let mut p = from_agent(&id, "p-x", "lane-a", None);
        p["_meta"]["acpmux"]["class"] = bad.clone();
        let refused = c.request(method::SESSION_PROMPT, p).await;
        assert!(
            refused.as_ref().is_err_and(|e| e.contains("class must be one of")),
            "{bad}: {refused:?}"
        );
    }
    // A send handed to the outbox is checked when it is handed over, not when it is delivered,
    // and so is one to a peer's session (checked before it is forwarded).
    let mut later = from_agent(&id, "p-y", "lane-a", None);
    later["_meta"]["acpmux"]["class"] = json!("urgent");
    let refused = c.request(method::MUX_SEND_QUEUE, json!({"request": later})).await;
    assert!(refused.as_ref().is_err_and(|e| e.contains("class must be one of")), "{refused:?}");
}

/// A hub whose log lives in `dir`, so a second one there is the same daemon restarted.
fn durable_hub(dir: &std::path::Path) -> Arc<Hub> {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all"
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Local;
    // The queue path before the inbox (`hub/inbox.rs`), which these tests cover.
    cfg.agent_inbox = Some(false);
    Hub::new(cfg.clone(), acpmux::store::open(&cfg.store, dir).unwrap())
}

#[tokio::test]
async fn a_queued_messages_class_survives_a_restart() {
    let dir = std::env::temp_dir().join(format!("acpmux-class-{}", uuid::Uuid::now_v7()));
    let hub = durable_hub(&dir);
    let mut c = connect(&hub).await;
    let id = busy(&mut c).await;
    queue(&mut c, from_agent(&id, "p-q", "lane-a", Some("question"))).await;
    queue(&mut c, from_agent(&id, "p-r", "lane-b", None)).await;
    hub.shutdown_all().await;
    drop(c);
    drop(hub);

    // Restored but not yet resumed: they still wait, each with its class.
    let hub = durable_hub(&dir);
    let mut c = connect(&hub).await;
    let after = classes(&mut c, &id).await;
    for (prompt_id, class) in [("p-q", json!("question")), ("p-r", json!("result"))] {
        let row = after.iter().find(|(p, _)| p == prompt_id);
        assert_eq!(row.map(|r| &r.1), Some(&class), "{prompt_id}: {after:?}");
    }
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&dir);
}
