//! An agent asks the person for a secret (cx-ncc.42, `hub/secrets.rs`): the
//! pane shows a private card, the person types the value, and the agent gets
//! a one-use, project-scoped `secretRef`, never the value. The value never
//! reaches the session's records, and spending the ref runs a command with
//! the value in its environment and the value masked in what it prints.

use super::*;
use acpmux::server::{Origin, serve_connection_with};

const VALUE: &str = "sk-live-4f9a2c7e1b";

/// A connection that never proved the person key: the agent, through its
/// `request_secret` tool on the unix socket, or a remote device.
async fn unproven(hub: &Arc<Hub>, origin: Origin) -> TestClient {
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, origin));
    let mut client = TestClient { tx: in_tx, rx: out_rx, next: 0 };
    client
        .request(method::INITIALIZE, json!({"protocolVersion": 1, "clientInfo": {"name": "agent"}}))
        .await
        .unwrap();
    client
}

async fn session_in(c: &mut TestClient, cwd: &str) -> String {
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd, "mcpServers": []})).await.unwrap();
    s["sessionId"].as_str().unwrap().to_owned()
}

/// Sends `request` without waiting, so the caller can answer the card first.
async fn send(c: &mut TestClient, m: &str, params: Value) -> i64 {
    c.next += 1;
    c.tx.send(Message::request(c.next, m, params).to_line()).await.unwrap();
    c.next
}

async fn reply(c: &mut TestClient, id: i64) -> Result<Value, String> {
    loop {
        let line = tokio::time::timeout(Duration::from_secs(20), c.rx.recv())
            .await
            .expect("timeout waiting for response")
            .expect("connection closed");
        if let Message::Response { id: rid, result, error } = Message::parse(&line).unwrap()
            && rid == id
        {
            return match error {
                Some(e) => Err(e.message),
                None => Ok(result.unwrap_or(Value::Null)),
            };
        }
    }
}

#[tokio::test]
async fn secrets_the_agent_gets_a_one_use_project_ref_never_the_value() {
    let (hub, mut person) = setup(PermissionPolicy::Ask).await;
    let id = session_in(&mut person, &cwd()).await;
    let mut agent = unproven(&hub, Origin::Local).await;

    // The agent asks; the person's pane gets a card with the name and the
    // reason, and the chat waits on the person.
    let asked = send(
        &mut agent,
        "_acpmux/secret_request",
        json!({"sessionId": id, "name": "STRIPE_API_KEY", "reason": "Create the test webhook"}),
    )
    .await;
    let card = person.wait_for(method::MUX_EVENT, |p| p["kind"] == "secret_request").await;
    let secret_id = card["msg"]["secretId"].as_str().unwrap().to_owned();
    assert_eq!(card["msg"]["name"], "STRIPE_API_KEY");
    assert_eq!(card["msg"]["reason"], "Create the test webhook");
    let session = hub.resolve(&id).unwrap();
    assert_eq!(hub.session_summary(&session)["status"], "waiting");

    // Only the person fills the card: the agent cannot answer its own ask.
    let forged = agent
        .request(
            "_acpmux/secret_submit",
            json!({"sessionId": id, "secretId": secret_id, "value": "forged"}),
        )
        .await;
    assert!(forged.is_err(), "the agent filled its own card: {forged:?}");

    person
        .request(
            "_acpmux/secret_submit",
            json!({"sessionId": id, "secretId": secret_id, "value": VALUE}),
        )
        .await
        .unwrap();
    let granted = reply(&mut agent, asked).await.unwrap();
    let secret_ref = granted["secretRef"].as_str().unwrap().to_owned();
    assert!(!granted.to_string().contains(VALUE), "the agent got the value: {granted}");
    assert!(!secret_ref.is_empty());

    // No record of the session holds the value: not the card, not the answer.
    let events = hub.events(&id, 0, 10_000).unwrap();
    assert!(events.iter().any(|e| e.kind == "secret_decision"));
    for event in &events {
        let text = serde_json::to_string(&event.msg).unwrap();
        assert!(!text.contains(VALUE), "record {} holds the value: {text}", event.kind);
    }

    // A session in another project cannot spend the ref.
    let elsewhere =
        std::env::temp_dir().join(format!("acpmux-secret-other-{}", std::process::id()));
    std::fs::create_dir_all(&elsewhere).unwrap();
    let other = session_in(&mut person, &elsewhere.to_string_lossy()).await;
    let run = |session: &str| {
        json!({
            "sessionId": session,
            "secretRef": secret_ref,
            "env": "STRIPE_API_KEY",
            "argv": ["sh", "-c", "test \"$STRIPE_API_KEY\" = 'sk-live-4f9a2c7e1b' && printf 'key=%s' \"$STRIPE_API_KEY\""],
        })
    };
    let refused = agent.request("_acpmux/secret_run", run(&other)).await;
    assert!(refused.is_err(), "another project spent the ref: {refused:?}");

    // Its own session spends it once: the command sees the value, and what it
    // prints comes back masked.
    let ran = agent.request("_acpmux/secret_run", run(&id)).await.unwrap();
    assert_eq!(ran["exitCode"], 0, "{ran}");
    assert!(!ran.to_string().contains(VALUE), "the run printed the value: {ran}");
    assert!(ran["stdout"].as_str().unwrap().starts_with("key="), "{ran}");
    let again = agent.request("_acpmux/secret_run", run(&id)).await;
    assert!(again.is_err(), "the ref was spent twice: {again:?}");
}

#[tokio::test]
async fn secrets_a_declined_card_gives_the_agent_no_ref() {
    let (hub, mut person) = setup(PermissionPolicy::Ask).await;
    let id = session_in(&mut person, &cwd()).await;
    let mut agent = unproven(&hub, Origin::Local).await;
    let asked = send(
        &mut agent,
        "_acpmux/secret_request",
        json!({"sessionId": id, "name": "GITHUB_TOKEN", "reason": "Open the PR"}),
    )
    .await;
    let card = person.wait_for(method::MUX_EVENT, |p| p["kind"] == "secret_request").await;
    let secret_id = card["msg"]["secretId"].as_str().unwrap().to_owned();
    person
        .request("_acpmux/secret_submit", json!({"sessionId": id, "secretId": secret_id}))
        .await
        .unwrap();
    let declined = reply(&mut agent, asked).await.unwrap();
    assert_eq!(declined["declined"], true, "{declined}");
    assert!(declined.get("secretRef").is_none(), "{declined}");
    let session = hub.resolve(&id).unwrap();
    assert_ne!(hub.session_summary(&session)["status"], "waiting");
}

#[tokio::test]
async fn secrets_a_remote_device_can_neither_ask_answer_nor_spend() {
    let (hub, mut person) = setup(PermissionPolicy::Ask).await;
    let id = session_in(&mut person, &cwd()).await;
    let mut web = unproven(&hub, Origin::Web).await;
    for m in ["_acpmux/secret_request", "_acpmux/secret_submit", "_acpmux/secret_run"] {
        let r = web
            .request(
                m,
                json!({"sessionId": id, "name": "X", "reason": "r", "secretId": "s", "value": "v", "secretRef": "r", "env": "X", "argv": ["true"]}),
            )
            .await;
        assert!(r.is_err(), "a remote device ran {m}: {r:?}");
    }
}
