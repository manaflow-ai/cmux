//! `_acpmux/protocol`: the daemon serves the protocol IR it was built with
//! (`protocol::ir()`, committed as `spec/acpmux-protocol.json`), so a client
//! or a peer reads the surface of the daemon it talks to; and the ACP
//! capabilities `initialize` advertises match what the daemon serves.

use super::*;

#[tokio::test]
async fn the_daemon_serves_its_protocol_ir() {
    let (_hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let ir = c.request("_acpmux/protocol", json!({})).await.unwrap();
    assert_eq!(ir, acpmux::protocol::ir());
    let names: Vec<&str> =
        ir["methods"].as_array().unwrap().iter().filter_map(|m| m["name"].as_str()).collect();
    for name in ["_acpmux/protocol", "_acpmux/sessions", method::SESSION_PROMPT] {
        assert!(names.contains(&name), "{name} missing from the served IR");
    }
}

/// A request's answer and the `session/update` notices this connection got before it.
async fn request_seeing_updates(c: &mut TestClient, m: &str, params: Value) -> (Value, Vec<Value>) {
    c.next += 1;
    let id = c.next;
    c.tx.send(Message::request(id, m, params).to_line()).await.unwrap();
    let mut updates = Vec::new();
    loop {
        let line = tokio::time::timeout(Duration::from_secs(20), c.rx.recv())
            .await
            .expect("timeout waiting for response")
            .expect("connection closed");
        match Message::parse(&line).unwrap() {
            Message::Response { id: rid, result, error } if rid == id => {
                assert!(error.is_none(), "{m}: {error:?}");
                return (result.unwrap_or(Value::Null), updates);
            }
            Message::Notification { method: got, params } if got == method::SESSION_UPDATE => {
                updates.push(params.unwrap_or(Value::Null));
            }
            _ => {}
        }
    }
}

/// ACP's session setup: a client calls `session/resume` only when `initialize`
/// advertises `sessionCapabilities.resume`; acpmux serves it, so it says so.
#[tokio::test]
async fn initialize_advertises_session_resume() {
    let (hub, _c) = setup(PermissionPolicy::ApproveAll).await;
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection(hub.clone(), in_rx, out_tx));
    let mut fresh = TestClient { tx: in_tx, rx: out_rx, next: 0 };
    let init = fresh
        .request(method::INITIALIZE, json!({"protocolVersion": 1, "clientInfo": {"name": "acp"}}))
        .await
        .unwrap();
    let caps = &init["agentCapabilities"];
    assert_eq!(caps["sessionCapabilities"]["resume"], json!({}), "{caps}");
    assert_eq!(caps["loadSession"], json!(true), "{caps}");
}

/// `session/resume` reattaches a new connection with no history replayed ("the Agent
/// MUST NOT replay the conversation history"), and the connection hears the session
/// live from then on; `session/load` still replays the whole conversation first.
#[tokio::test]
async fn session_resume_reattaches_without_replay_and_load_still_replays() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut c, "resumable").await;
    c.request(
        method::SESSION_PROMPT,
        json!({"sessionId": id, "prompt": [{"type": "text", "text": "before"}]}),
    )
    .await
    .unwrap();

    let mut resumed = connect(&hub).await;
    let (r, updates) = request_seeing_updates(
        &mut resumed,
        method::SESSION_RESUME,
        json!({"sessionId": id, "cwd": cwd(), "mcpServers": []}),
    )
    .await;
    assert!(updates.is_empty(), "session/resume replayed history: {updates:?}");
    assert_eq!(r["modes"]["currentModeId"], "normal", "{r}");
    assert_eq!(r["_meta"]["acpmux"]["name"], "resumable", "{r}");

    // Attached: the next turn's updates reach the resumed connection, live.
    c.request(
        method::SESSION_PROMPT,
        json!({"sessionId": id, "prompt": [{"type": "text", "text": "after"}]}),
    )
    .await
    .unwrap();
    let live = resumed
        .wait_for(method::SESSION_UPDATE, |p| {
            p["sessionId"] == id.as_str()
                && p["update"]["sessionUpdate"] == "agent_message_chunk"
                && p["_meta"]["acpmux"]["replay"] != true
        })
        .await;
    assert_eq!(live["update"]["content"]["text"], "echo: after", "{live}");

    let mut loaded = connect(&hub).await;
    let (_, updates) = request_seeing_updates(
        &mut loaded,
        method::SESSION_LOAD,
        json!({"sessionId": id, "cwd": cwd(), "mcpServers": []}),
    )
    .await;
    let replayed_user = updates.iter().any(|p| {
        p["update"]["sessionUpdate"] == "user_message_chunk"
            && p["update"]["content"]["text"] == "before"
            && p["_meta"]["acpmux"]["replay"] == true
    });
    assert!(replayed_user, "session/load did not replay the first prompt: {updates:?}");
}
