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
        summary: json!({"sessionId": "peer-review-1", "name": "hb/review", "status": "running"})
            .into(),
        receipt: SessionReceipt {
            host_id: "hb".into(),
            mux_session_id: "peer-review-1".into(),
            agent_session_id: None,
            generation: 1,
        },
    };
    hub.remote_sessions.write().insert("hb/peer-review-1".into(), row);
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
        summary: json!({"sessionId": "peer-child-1", "name": "hb/review/child", "status": "idle"})
            .into(),
        receipt: SessionReceipt {
            host_id: "hb".into(),
            mux_session_id: "peer-child-1".into(),
            agent_session_id: None,
            generation: 1,
        },
    };
    hub.remote_sessions.write().insert("hb/peer-child-1".into(), row);
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

/// Review of #38112: `local/ID`, a session's qualified id here, names that session through the
/// dispatcher, never another session whose whole name is the same text.
#[tokio::test]
async fn a_local_qualified_id_beats_a_session_named_like_it() {
    let hub = setup_with(&[("local-a-1", "a"), ("local-b-1", "local/local-a-1")]);
    let reply = call(&hub, method::MUX_INFO, json!({"sessionId": "local/local-a-1"})).await;
    assert_eq!(reply["result"]["sessionId"], "local-a-1", "{reply}");
    let found = hub.locate("local/local-a-1", false, true).unwrap();
    assert_eq!(found["session"]["sessionId"], "local-a-1", "{found}");
}

/// Review of #38112: with configured peer hb, `hb/ID` whose row is gone (a stale qualified id)
/// stays in hb's namespace and is refused, never handed to a session here named `hb/ID`.
#[tokio::test]
async fn a_stale_peer_qualified_id_never_picks_a_local_session_named_like_it() {
    let hub = setup_with(&[("local-d-1", "hb/peer-gone-1")]);
    let (tx, _rx) = mpsc::channel(8);
    let peer = crate::peer::Peer::new("hb", "ws://127.0.0.1:9", None, None, tx);
    hub.peers.lock().unwrap().insert("hb".to_owned(), peer);
    let reply = call(&hub, method::MUX_INFO, json!({"sessionId": "hb/peer-gone-1"})).await;
    assert_ne!(reply["result"]["sessionId"], "local-d-1", "{reply}");
}

#[tokio::test]
async fn spoken_handles_resolve_rename_and_send_through_the_socket() {
    let hub = setup_with(&[("lane-a", "ci-fleet"), ("lane-b", "docs")]);
    let info = call(&hub, method::MUX_INFO, json!({"sessionId": "lane-a"})).await;
    let generated = info["result"]["handle"].as_str().expect("the old record has a handle");
    let lookup = call(&hub, method::MUX_INFO, json!({"sessionId": generated})).await;
    assert_eq!(lookup["result"]["sessionId"], "lane-a", "{lookup}");

    let renamed =
        call(&hub, method::MUX_RENAME, json!({"sessionId": generated, "newHandle": "Mango"})).await;
    assert_eq!(renamed["result"]["handle"], "Mango", "{renamed}");
    assert_eq!(renamed["result"]["name"], "ci-fleet", "{renamed}");
    let found = call(&hub, method::MUX_RESOLVE, json!({"query": "local/mango"})).await;
    assert_eq!(found["result"]["session"]["sessionId"], "lane-a", "{found}");
    let link = "https://cmux.com/deeplink/agent?harness=fake&session=handle%3AMango";
    let found = call(&hub, method::MUX_RESOLVE, json!({"query": link})).await;
    assert_eq!(found["result"]["session"]["sessionId"], "lane-a", "{found}");
    let id_link = "https://cmux.com/deeplink/agent?harness=fake&session=Mango";
    let missing = call(&hub, method::MUX_RESOLVE, json!({"query": id_link})).await;
    assert!(missing.get("error").is_some(), "{missing}");

    let collision =
        call(&hub, method::MUX_RENAME, json!({"sessionId": "lane-b", "newHandle": "mango"})).await;
    assert_eq!(collision["error"]["data"]["reason"], "handle.taken", "{collision}");

    let request = json!({"sessionId": "Mango", "prompt": [{"type": "text", "text": "hi"}]});
    let sent = call(&hub, method::MUX_SEND_QUEUE, json!({"request": request})).await;
    assert!(sent.get("result").is_some(), "{sent}");
}

#[tokio::test]
async fn spoken_handles_refuse_a_duplicate_peer_handle() {
    let hub = setup_with(&[("lane-a", "ci-fleet")]);
    call(&hub, method::MUX_RENAME, json!({"sessionId": "lane-a", "newHandle": "Mango"})).await;
    let mut rows = hub.remote_sessions.write();
    let mut row = rows.get("hb/peer-review-1").unwrap().as_ref().clone();
    let mut summary = row.summary.value();
    summary["handle"] = json!("mango");
    row.summary = summary.into();
    rows.insert("hb/peer-review-1".into(), row);
    drop(rows);

    let refused = call(&hub, method::MUX_INFO, json!({"sessionId": "Mango"})).await;
    assert_eq!(refused["error"]["data"]["reason"], "session_ambiguous", "{refused}");
    let found = call(&hub, method::MUX_INFO, json!({"sessionId": "local/Mango"})).await;
    assert_eq!(found["result"]["sessionId"], "lane-a", "{found}");
}

/// A hub with these local sessions (id, name, status) and no peer.
fn setup_statuses(local: &[(&str, &str, &str)]) -> Arc<Hub> {
    let mut config: Config = serde_json::from_value(json!({})).unwrap();
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    for (id, name, status) in local {
        let meta = serde_json::from_value(json!({
            "schema": crate::store::META_SCHEMA, "id": id, "name": name,
            "harness": "fake", "cwd": "/tmp", "status": status, "createdAt": 1, "updatedAt": 1,
        }))
        .unwrap();
        store.save(&meta).unwrap();
    }
    Hub::new(config, store)
}

/// Repro (interim-coord, 2026-11-21: "The name "interim-coord" couldn't be moved over"): a closed
/// registered chat kept a coordinator's call name, and no rename moved it. A live registered chat
/// still refuses; a closed one is renamed, and its name is free for the revived session.
#[tokio::test]
async fn a_closed_registered_chat_gives_its_name_back() {
    let hub = setup_statuses(&[
        ("old-coord", "interim-coord", "closed"),
        ("live-chat", "desktop-leo", "idle"),
        ("new-coord", "interim-coord-2", "idle"),
    ]);
    crate::hub::register::mark_registered_for_test("old-coord");
    crate::hub::register::mark_registered_for_test("live-chat");
    let live =
        call(&hub, method::MUX_RENAME, json!({"sessionId": "live-chat", "newName": "x"})).await;
    assert_eq!(live["error"]["data"]["reason"], "rename.registered", "{live}");
    let taken = call(
        &hub,
        method::MUX_RENAME,
        json!({"sessionId": "new-coord", "newName": "interim-coord"}),
    )
    .await;
    assert!(taken.get("error").is_some(), "{taken}");
    let moved = call(
        &hub,
        method::MUX_RENAME,
        json!({"sessionId": "old-coord", "newName": "interim-coord-retired"}),
    )
    .await;
    assert_eq!(moved["result"]["name"], "interim-coord-retired", "{moved}");
    let back = call(
        &hub,
        method::MUX_RENAME,
        json!({"sessionId": "new-coord", "newName": "interim-coord"}),
    )
    .await;
    assert_eq!(back["result"]["name"], "interim-coord", "{back}");
}
