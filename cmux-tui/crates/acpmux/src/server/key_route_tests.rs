//! A bare name on this machine's socket, through the real dispatcher (`hub/key_route.rs`): a name
//! a session here and a peer's session share is refused, never given to the one here.

use super::*;
use crate::config::{Config, StoreMode};
use crate::session_identity::SessionReceipt;
use std::time::Duration;
use tokio::sync::mpsc;

/// A hub with a local `review`, and peer hb listing a live `review` of its own.
fn setup() -> Arc<Hub> {
    setup_with(&[("local-review-1", "review")])
}

/// A hub with these local sessions (id, name), and peer hb listing a live `review`.
fn setup_with(local: &[(&str, &str)]) -> Arc<Hub> {
    let mut config: Config = serde_json::from_value(json!({})).unwrap();
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    for (id, name) in local {
        let meta = serde_json::from_value(json!({
            "schema": crate::store::META_SCHEMA, "id": id, "name": name,
            "harness": "fake", "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1,
        }))
        .unwrap();
        store.save(&meta).unwrap();
    }
    let hub = Hub::new(config, store);
    let row = crate::hub::RemoteSession {
        peer: "hb".into(),
        summary: json!({"sessionId": "peer-review-1", "name": "hb/review", "status": "running"}),
        receipt: SessionReceipt {
            host_id: "hb".into(),
            mux_session_id: "peer-review-1".into(),
            agent_session_id: None,
            generation: 1,
        },
    };
    hub.remote_sessions.lock().unwrap().insert("hb/peer-review-1".into(), row);
    hub
}

async fn call(hub: &Arc<Hub>, method: &str, params: Value) -> Value {
    let (input, incoming) = mpsc::channel(64);
    let (output, mut outgoing) = mpsc::channel(64);
    tokio::spawn(serve_connection_with(hub.clone(), incoming, output, Origin::Local));
    let hello = json!({"protocolVersion": 1, "clientCapabilities": {}});
    for (id, (m, p)) in [(1, ("initialize", hello)), (2, (method, params))] {
        input.send(Message::request(id, m, p).to_line()).await.unwrap();
        let reply = tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                let reply: Value = serde_json::from_str(&outgoing.recv().await.unwrap()).unwrap();
                if reply["id"] == id {
                    return reply;
                }
            }
        })
        .await
        .unwrap();
        if id == 2 {
            return reply;
        }
    }
    unreachable!()
}

#[tokio::test]
async fn info_by_a_name_here_and_on_a_peer_is_refused_with_both() {
    let hub = setup();
    let reply = call(&hub, method::MUX_INFO, json!({"sessionId": "review"})).await;
    let data = &reply["error"]["data"];
    assert_eq!(data["reason"], "session_ambiguous", "{reply}");
    let routes: Vec<&str> =
        data["choices"].as_array().unwrap().iter().filter_map(|c| c["route"].as_str()).collect();
    assert!(routes.contains(&"local-review-1") && routes.contains(&"hb/peer-review-1"), "{reply}");
    // The id and `HOST/NAME` still name the one here.
    let by_id = call(&hub, method::MUX_INFO, json!({"sessionId": "local-review-1"})).await;
    assert_eq!(by_id["result"]["sessionId"], "local-review-1", "{by_id}");
}

#[tokio::test]
async fn a_send_to_a_shared_name_is_refused_not_queued_for_the_one_here() {
    let hub = setup();
    let request = json!({"sessionId": "review", "prompt": [{"type": "text", "text": "hi"}]});
    let reply = call(&hub, method::MUX_SEND_QUEUE, json!({"request": request})).await;
    assert_eq!(reply["error"]["data"]["reason"], "session_ambiguous", "{reply}");
}

/// Review of #28000: a sub-session named `parent/child` here and on a peer is refused too.
#[tokio::test]
async fn a_sub_sessions_whole_name_here_and_on_a_peer_is_refused() {
    let hub = setup_with(&[("local-review-1", "review"), ("local-child-1", "review/child")]);
    let row = crate::hub::RemoteSession {
        peer: "hb".into(),
        summary: json!({"sessionId": "peer-child-1", "name": "hb/review/child", "status": "idle"}),
        receipt: SessionReceipt {
            host_id: "hb".into(),
            mux_session_id: "peer-child-1".into(),
            agent_session_id: None,
            generation: 1,
        },
    };
    hub.remote_sessions.lock().unwrap().insert("hb/peer-child-1".into(), row);
    let reply = call(&hub, method::MUX_INFO, json!({"sessionId": "review/child"})).await;
    assert_eq!(reply["error"]["data"]["reason"], "session_ambiguous", "{reply}");
    let uses: Vec<&str> = reply["error"]["data"]["choices"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|c| c["route"].as_str())
        .collect();
    assert!(uses.contains(&"local-child-1") && uses.contains(&"hb/peer-child-1"), "{reply}");
}
