//! `_acpmux/connections/chatgpt.import` through the actual daemon dispatcher: refused until the
//! daemon's environment sets `ACPMUX_CI_CHATGPT_IMPORT=1`, refused on the web listener (where the
//! remote relay arrives) even with it set, and on the local socket it stores a `chatgpt-plan`
//! connection that lists as Cloud-serving. One test: the switch is process environment.

use super::*;
use crate::chatgpt;
use crate::config::{Config, StoreMode};
use std::time::Duration;

fn hub(root: &std::path::Path) -> Arc<Hub> {
    let mut config = Config::default();
    config.store.mode = StoreMode::Memory;
    config.path = Some(root.join("config.json"));
    config.profile_sources.cmux_json = Some(root.join("cmux.json"));
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(config, store)
}

async fn call(hub: &Arc<Hub>, origin: Origin, params: Value) -> Value {
    let (input, incoming) = mpsc::channel(64);
    let (output, mut outgoing) = mpsc::channel(64);
    tokio::spawn(serve_connection_with(hub.clone(), incoming, output, origin));
    let hello = json!({"protocolVersion": 1, "clientCapabilities": {}});
    input.send(Message::request(1, method::INITIALIZE, hello).to_line()).await.unwrap();
    let ask = Message::request(2, method::MUX_CONNECTIONS_CHATGPT_IMPORT, params);
    input.send(ask.to_line()).await.unwrap();
    // timeout: test-only bound; a lost reply fails the test instead of hanging it.
    tokio::time::timeout(Duration::from_secs(10), async {
        loop {
            let reply: Value = serde_json::from_str(&outgoing.recv().await.unwrap()).unwrap();
            if reply["id"] == 2 {
                return reply;
            }
        }
    })
    .await
    .expect("RPC answered")
}

#[tokio::test]
async fn chatgpt_import_needs_the_switch_the_local_socket_and_a_codex_login() {
    let root = tempfile::tempdir().unwrap();
    let file = root.path().join("auth.json");
    std::fs::write(&file, chatgpt::import_test_auth(chatgpt::CODEX_CLIENT_ID, Some("rt"), true))
        .unwrap();
    let params = json!({"secret_file": file});
    let hub = hub(root.path());
    let stored = || chatgpt::store::all(root.path()).len();

    // SAFETY: the only test that touches this variable, and the daemon reads it at each call.
    unsafe { std::env::remove_var(chatgpt::CI_IMPORT_ENV) };
    let reply = call(&hub, Origin::Local, params.clone()).await;
    assert_eq!(reply["error"]["data"]["reason"], "chatgpt.import_disabled", "{reply}");

    // SAFETY: as above.
    unsafe { std::env::set_var(chatgpt::CI_IMPORT_ENV, "1") };
    for origin in [Origin::Web, Origin::Peer, Origin::LocalApp] {
        let reply = call(&hub, origin, params.clone()).await;
        assert!(reply.get("error").is_some(), "{origin:?}: {reply}");
        assert!(reply.get("result").is_none(), "{origin:?}: {reply}");
    }
    assert_eq!(stored(), 0, "a remote origin stored nothing");

    let reply = call(&hub, Origin::Local, json!({})).await;
    assert!(reply["error"]["message"].as_str().is_some_and(|m| m.contains("secret_file")));
    let reply = call(&hub, Origin::Local, params).await;
    // SAFETY: as above.
    unsafe { std::env::remove_var(chatgpt::CI_IMPORT_ENV) };
    let connection = &reply["result"]["connection"];
    assert_eq!(connection["id"], "chatgpt", "{reply}");
    assert_eq!(connection["kind"], "chatgpt-plan", "{reply}");
    assert_eq!(connection["serves_cloud"], true, "{reply}");
    assert_eq!(stored(), 1);
}
