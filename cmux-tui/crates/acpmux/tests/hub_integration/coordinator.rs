//! `_acpmux/set_coordinator` (`hub/coordinator.rs`): the person makes a chat a coordinator, and
//! other agents' messages to it wait in its inbox (`inbox` on their queue rows) for one digest. A
//! restart keeps the setting, the inbox and how long each item has waited.

use super::*;

/// What `acpmux send --from AGENT [--class CLASS]` sends.
fn from_agent(id: &str, prompt_id: &str, agent: &str, class: Option<&str>) -> Value {
    let mut mux = json!({"promptId": prompt_id, "fromAgent": agent});
    if let Some(class) = class {
        mux["class"] = json!(class);
    }
    json!({"sessionId": id, "prompt": [{"type": "text", "text": format!("from {agent}")}], "_meta": {"acpmux": mux}})
}

/// Sends `params` on `c` and waits until it is queued.
async fn queue(c: &mut TestClient, params: Value) {
    let prompt_id = params["_meta"]["acpmux"]["promptId"].as_str().unwrap().to_owned();
    c.send(method::SESSION_PROMPT, params).await;
    c.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == *prompt_id && p["queued"] == true)
        .await;
}

/// The session's queue rows.
async fn rows(c: &mut TestClient, id: &str) -> Vec<Value> {
    let attached =
        c.request(method::MUX_ATTACH, json!({"sessionId": id, "limit": 0})).await.unwrap();
    attached["session"]["queue"].as_array().unwrap().clone()
}

/// A connection that proved it runs in chat `id`: its agent's tools.
async fn agent_of(hub: &Arc<Hub>, id: &str) -> TestClient {
    let (tx, in_rx) = mpsc::channel(64);
    let (out_tx, rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection(hub.clone(), in_rx, out_tx));
    let mut c = TestClient { tx, rx, next: 0 };
    let token = acpmux::hub::person::caller_token(id);
    let caller = json!({"callerSession": {"sessionId": id, "token": token}});
    c.request("initialize", json!({"protocolVersion": 1, "_meta": {"acpmux": caller}}))
        .await
        .unwrap();
    c
}

async fn new_chat(c: &mut TestClient) -> String {
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    s["sessionId"].as_str().unwrap().to_owned()
}

#[tokio::test]
async fn only_the_person_makes_a_chat_a_coordinator_and_its_inbox_rows_say_so() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_chat(&mut c).await;
    let lane = new_chat(&mut c).await;
    let set = method::MUX_SET_COORDINATOR;

    // A session's agent reads the setting but never changes it.
    let mut agent = agent_of(&hub, &lane).await;
    let read = agent.request(set, json!({"sessionId": id})).await.unwrap();
    assert_eq!(read["coordinator"], false, "{read}");
    let refused = agent.request(set, json!({"sessionId": id, "coordinator": true})).await;
    assert!(refused.as_ref().is_err_and(|e| e.contains("cmux app")), "{refused:?}");
    for bad in [
        json!({"coordinator": "yes"}),
        json!({"inboxFlushMs": 10}),
        json!({"digestIntervalMs": -1}),
    ] {
        let mut params = bad.clone();
        params["sessionId"] = json!(id);
        assert!(c.request(set, params).await.is_err(), "{bad}");
    }
    let read = c.request(set, json!({"sessionId": id})).await.unwrap();
    assert_eq!(read["coordinator"], false, "a refused change changed nothing: {read}");

    let on = c
        .request(set, json!({"sessionId": id, "coordinator": true, "inboxFlushMs": 900_000}))
        .await;
    let on = on.unwrap();
    assert_eq!(on["coordinator"], true, "{on}");
    assert_eq!(on["inboxFlushMs"], 900_000);
    assert_eq!(on["effectiveInboxFlushMs"], 900_000);
    assert_eq!(on["effectiveDigestIntervalMs"], 300_000, "the default interval");
    assert_eq!(on["effectiveTurnCapMs"], 1_200_000, "a coordinator's default turn cap");

    // Idle, an agent's result waits in the inbox; its row says so.
    queue(&mut c, from_agent(&id, "p-r", "lane-a", None)).await;
    let rows = rows(&mut c, &id).await;
    assert_eq!(rows.len(), 1, "{rows:?}");
    assert_eq!(
        (rows[0]["inbox"].clone(), rows[0]["class"].clone()),
        (json!(true), json!("result"))
    );
    let read = c.request(set, json!({"sessionId": id})).await.unwrap();
    assert_eq!(read["inbox"], 1, "{read}");

    // Off: released, it runs as another agent's message does.
    let off = c.request(set, json!({"sessionId": id, "coordinator": false})).await.unwrap();
    assert_eq!(off["inbox"], 0, "{off}");
    assert!(off["effectiveTurnCapMs"].is_null(), "{off}");
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
    Hub::new(cfg.clone(), acpmux::store::open(&cfg.store, dir).unwrap())
}

#[tokio::test]
async fn a_restart_keeps_the_inbox_and_how_long_each_item_waited() {
    let dir = std::env::temp_dir().join(format!("acpmux-coordinator-{}", uuid::Uuid::now_v7()));
    let hub = durable_hub(&dir);
    let mut c = connect(&hub).await;
    let id = new_chat(&mut c).await;
    let on = json!({"sessionId": id, "coordinator": true});
    c.request(method::MUX_SET_COORDINATOR, on).await.unwrap();
    queue(&mut c, from_agent(&id, "p-1", "lane-a", None)).await;
    queue(&mut c, from_agent(&id, "p-2", "lane-b", Some("fyi"))).await;
    let before = rows(&mut c, &id).await;
    hub.shutdown_all().await;
    drop(c);
    drop(hub);
    // Long enough that a wait counted from the restart would show.
    tokio::time::sleep(Duration::from_millis(1_500)).await;

    let hub = durable_hub(&dir);
    let mut c = connect(&hub).await;
    let read = c.request(method::MUX_SET_COORDINATOR, json!({"sessionId": id})).await.unwrap();
    assert_eq!(read["coordinator"], true, "{read}");
    let after = rows(&mut c, &id).await;
    let ids =
        |rows: &[Value]| -> Vec<Value> { rows.iter().map(|q| q["promptId"].clone()).collect() };
    assert_eq!(ids(&after), ids(&before), "{after:?}");
    assert!(after.iter().all(|q| q["inbox"] == true), "{after:?}");
    // Each waits from when it was queued (its record's time), not from the restart.
    for (b, a) in before.iter().zip(&after) {
        let (b, a) = (b["queuedAt"].as_u64().unwrap(), a["queuedAt"].as_u64().unwrap());
        assert!(a.abs_diff(b) < 500, "queued at {b}, restored as {a}");
    }
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn an_inbox_item_the_person_edits_is_theirs_and_runs() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_chat(&mut c).await;
    let on = json!({"sessionId": id, "coordinator": true});
    c.request(method::MUX_SET_COORDINATOR, on).await.unwrap();
    queue(&mut c, from_agent(&id, "p-r", "lane-a", None)).await;
    let edit = json!({"sessionId": id, "promptId": "p-r", "op": "update", "text": "mine now"});
    let edited = c.request(method::MUX_QUEUE_EDIT, edit).await.unwrap();
    assert_eq!(edited["ok"], true, "{edited}");
    // No inbox item now: it runs as the person's prompt, with no digest.
    let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
    let ran = loop {
        let events = hub.events(&id, 0, 10_000).unwrap();
        let ran: Vec<Value> =
            find(&events, "user_message").into_iter().map(|e| e.msg.clone()).collect();
        if !ran.is_empty() {
            break ran;
        }
        assert!(tokio::time::Instant::now() < deadline, "the edited prompt never ran");
        tokio::time::sleep(Duration::from_millis(50)).await;
    };
    assert_eq!(ran.len(), 1, "{ran:?}");
    assert_eq!(ran[0]["promptId"], "p-r", "{ran:?}");
    assert_eq!(ran[0]["text"], "mine now", "{ran:?}");
}
