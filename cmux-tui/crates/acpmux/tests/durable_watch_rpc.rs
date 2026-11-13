//! Watch RPC authority and actionable validation, through real connection dispatch.
#![cfg(unix)]
#[path = "support/daemon_env.rs"]
mod daemon_env;
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();
use acpmux::{config::Config, hub::Hub, server::Origin};
use serde_json::json;

#[path = "durable_watch_lifecycle/connection.rs"]
mod connection;
use connection::Connection;

#[tokio::test]
async fn watch_rpc_refuses_remote_origins_self_and_invalid_parameters() {
    let dir = cmux_unix_socket::short_test_dir("watch-rpc");
    let cfg: Config = serde_json::from_value(json!({"store": {"mode": "memory"},
        "harnesses": {"fake": {"argv": ["python3", concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py")]}},
        "defaultHarness": "fake"})).unwrap();
    let store = acpmux::store::open(&cfg.store, dir.path()).unwrap();
    let hub = Hub::new(cfg, store);
    let mut local = Connection::new(&hub, Origin::Local);
    let chat = local.call("session/new", json!({"cwd": dir.path(), "mcpServers": []})).await;
    let id = chat["result"]["sessionId"].as_str().expect("session created");
    for origin in [Origin::Web, Origin::Peer] {
        let mut remote = Connection::new(&hub, origin);
        for (method, params) in [
            ("_acpmux/watch_add", json!({"to": id, "sessions": [id]})),
            ("_acpmux/watch_ls", json!({})),
            ("_acpmux/watch_rm", json!({"id": "missing"})),
        ] {
            let reply = remote.call(method, params).await;
            assert!(reply["error"].is_object(), "{origin:?} {method}: {reply}");
        }
    }
    for (params, expected) in [
        (
            json!({"to": id, "sessions": [id], "once": false}),
            "recurring watches are not supported yet",
        ),
        (json!({"to": id, "sessions": [id]}), "cannot watch itself"),
        (json!({"to": id, "sessions": []}), "at least one session"),
        (json!({"sessions": [id]}), "to is required"),
        (json!({"to": id, "sessions": [id], "until": ["oops"]}), "until accepts"),
        // A watch on a peer chat keeps only this much of a long reply's ends (`hub::MAX_MATCH_BYTES`).
        (
            json!({"to": id, "sessions": ["other"], "match": "m".repeat(2 * 1024 + 1)}),
            "match is at most 2048 bytes",
        ),
    ] {
        let reply = local.call("_acpmux/watch_add", params).await;
        assert!(reply["error"]["message"].as_str().unwrap().contains(expected), "{reply}");
    }
    let missing = local.call("_acpmux/watch_rm", json!({"id": "missing"})).await;
    assert!(missing["error"]["message"].as_str().unwrap().contains("_acpmux/watch_ls"));
    let list = local.result("_acpmux/watch_ls", json!({})).await;
    assert_eq!(list["watches"], json!([]));
    hub.end_agents_at_shutdown(Default::default()).unwrap();
    hub.shutdown_all().await;
}

#[tokio::test]
async fn a_completion_watch_wakes_its_idle_recipient_when_the_job_finishes() {
    let dir = cmux_unix_socket::short_test_dir("watch-own-result");
    let cfg: Config = serde_json::from_value(json!({"store": {"mode": "memory"},
        "agentInbox": true,
        "harnesses": {"fake": {"argv": ["python3", concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py")]}},
        "defaultHarness": "fake"})).unwrap();
    let store = acpmux::store::open(&cfg.store, dir.path()).unwrap();
    let hub = Hub::new(cfg, store);
    let mut app = Connection::new(&hub, Origin::Local);
    let recipient = app.result("session/new", json!({"cwd": dir.path(), "mcpServers": []})).await;
    let recipient = recipient["sessionId"].as_str().unwrap().to_owned();
    let source = app.result("session/new", json!({"cwd": dir.path(), "mcpServers": []})).await;
    let source = source["sessionId"].as_str().unwrap().to_owned();
    app.result(
        "session/prompt",
        json!({"sessionId": recipient,
        "prompt": [{"type": "text", "text": "I will collect the child result."}]}),
    )
    .await;
    let mut owner = Connection::new(&hub, Origin::Local);
    let token = acpmux::hub::person::caller_token(&recipient);
    owner
        .result(
            "initialize",
            json!({"protocolVersion": 1,
        "_meta": {"acpmux": {"callerSession": {"sessionId": recipient, "token": token}}}}),
        )
        .await;
    let watch =
        owner.result("_acpmux/watch_add", json!({"sessions": [source], "match": "finished"})).await;
    let mut events = hub.subscribe();
    app.result(
        "session/prompt",
        json!({"sessionId": source,
        "prompt": [{"type": "text", "text": "child finished"}]}),
    )
    .await;
    let result = tokio::time::timeout(std::time::Duration::from_secs(20), async {
        loop {
            let event = events.recv().await.unwrap();
            if event.session_id == recipient && event.record.kind == "turn_result" {
                break event.record.msg.clone();
            }
        }
    })
    .await
    .expect("the completed watch must resume its idle parent without the ten-minute inbox flush");
    assert_eq!(result["status"], "completed", "{result}");
    let page = app.result("_acpmux/events", json!({"sessionId": recipient, "limit": 200})).await;
    assert!(
        page["events"].as_array().unwrap().iter().any(|event| event["kind"] == "inbox"
            && event["msg"]["text"]
                .as_str()
                .is_some_and(|text| text.contains(watch["id"].as_str().unwrap()))),
        "{page}"
    );
    hub.end_agents_at_shutdown(Default::default()).unwrap();
    hub.shutdown_all().await;
}
